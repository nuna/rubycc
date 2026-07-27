# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"

# Exercises Rubycc::ObjFile::ArWriter / ArReader and the exe/rubycc-ar CLI.
# Three concerns are covered: the writer/reader round-trip (including long names,
# member replacement and byte-for-byte determinism), the ranlib symbol index
# built from rubycc-compiled objects, and interoperability with the system `ar`
# in both directions. The interop and CLI cases are skip-guarded when their
# external tools are missing so the suite still runs on a bare host.
class TestArArchive < Minitest::Test
  Reader = Rubycc::ObjFile::ArReader
  Writer = Rubycc::ObjFile::ArWriter

  EXE_PATH = File.expand_path("../exe/rubycc-ar", __dir__)
  LIB_DIR = File.expand_path("../lib", __dir__)

  # Two tiny translation units with a known symbol partition: a.o defines the
  # globals `add` and `shared_counter` and a `static` (local) `helper`; b.o
  # defines `use`/`caller` and leaves `add`/`undefined_ref` undefined.
  SRC_A = "int shared_counter; int add(int x, int y) { return x + y; } " \
          "static int helper(int z) { return z; }"
  SRC_B = "int add(int, int); int use(int a) { return add(a, 1); } " \
          "int undefined_ref(void); int caller(void) { return undefined_ref(); }"

  def compile_object(source, filename)
    Rubycc::Compiler.new.compile(source, filename: filename)
  end

  def ar_available?
    @ar_available ||= system("ar", "--version", out: File::NULL, err: File::NULL) ? :yes : :no
    @ar_available == :yes
  end

  def nm_available?
    @nm_available ||= system("nm", "--version", out: File::NULL, err: File::NULL) ? :yes : :no
    @nm_available == :yes
  end

  # --- writer / reader round-trip ---------------------------------------

  def test_round_trips_short_named_members
    archive = Writer.new
                    .add_member("first.o", "hello".b)
                    .add_member("second.o", "world!".b)
                    .to_binary

    reader = Reader.read(archive)
    members = reader.members.reject(&:special?)
    assert_equal ["first.o", "second.o"], members.map(&:name)
    assert_equal "hello".b, reader.member("first.o").data
    assert_equal "world!".b, reader.member("second.o").data
    # Deterministic metadata: mtime/uid/gid pinned to 0, mode to 0644.
    m = reader.member("first.o")
    assert_equal 0, m.mtime
    assert_equal 0, m.uid
    assert_equal 0, m.gid
    assert_equal 0o644, m.mode
  end

  def test_round_trips_a_name_longer_than_the_inline_field
    long = "a_very_long_member_name_over_fifteen_chars.o"
    archive = Writer.new
                    .add_member("short.o", "x".b)
                    .add_member(long, "payload".b)
                    .to_binary

    # A long name forces a `//` extended-name table member into the image.
    reader = Reader.read(archive)
    assert reader.members.any? { |m| m.special? && m.name == "//" }, "expected a // name table"
    assert_equal ["short.o", long], reader.members.reject(&:special?).map(&:name)
    assert_equal "payload".b, reader.member(long).data
  end

  def test_odd_sized_member_is_padded_and_read_back_exactly
    # A 5-byte (odd) payload needs a `\n` pad byte to keep the next member on an
    # even offset; the reader must return the 5 real bytes, not 6.
    archive = Writer.new
                    .add_member("odd.o", "12345".b)
                    .add_member("next.o", "AB".b)
                    .to_binary

    reader = Reader.read(archive)
    assert_equal "12345".b, reader.member("odd.o").data
    assert_equal "AB".b, reader.member("next.o").data
  end

  def test_writer_output_is_byte_identical_for_identical_inputs
    build = -> { Writer.new.add_member("a.o", "one".b).add_member("b.o", "two".b).to_binary }
    assert_equal build.call, build.call
  end

  def test_a_rebuilt_member_replaces_its_predecessors_bytes
    # The writer lays out exactly what it is given; a caller that re-supplies a
    # member with new bytes (what the CLI's `r` does) round-trips the new data.
    first = Writer.new.add_member("x.o", "old".b).to_binary
    second = Writer.new.add_member("x.o", "brand-new".b).to_binary

    refute_equal first, second
    assert_equal "brand-new".b, Reader.read(second).member("x.o").data
  end

  # --- symbol index -----------------------------------------------------

  def test_symbol_index_maps_defined_globals_to_their_member
    archive = Writer.new
                    .add_member("a.o", compile_object(SRC_A, "a.c"))
                    .add_member("b.o", compile_object(SRC_B, "b.c"))
                    .to_binary

    reader = Reader.read(archive)
    index = reader.symbol_index.transform_values(&:name)

    assert_equal "a.o", index["add"]
    assert_equal "a.o", index["shared_counter"]
    assert_equal "b.o", index["use"]
    assert_equal "b.o", index["caller"]
    # `helper` is `static` (local) and `undefined_ref` is undefined — neither is
    # a definition, so neither appears in the index.
    refute index.key?("helper"), "local symbol must not be indexed"
    refute index.key?("undefined_ref"), "undefined symbol must not be indexed"
  end

  def test_member_defining_answers_the_linkers_query
    archive = Writer.new
                    .add_member("a.o", compile_object(SRC_A, "a.c"))
                    .add_member("b.o", compile_object(SRC_B, "b.c"))
                    .to_binary

    reader = Reader.read(archive)
    assert_equal "a.o", reader.member_defining("add").name
    assert_equal "b.o", reader.member_defining("caller").name
    assert_nil reader.member_defining("undefined_ref")
    assert_nil reader.member_defining("no_such_symbol")
  end

  def test_a_non_elf_member_contributes_no_symbols
    archive = Writer.new
                    .add_member("a.o", compile_object(SRC_A, "a.c"))
                    .add_member("readme.txt", "not an object file".b)
                    .to_binary

    reader = Reader.read(archive)
    assert_equal "a.o", reader.member_defining("add").name
    # The text member is still a member, it just exports nothing.
    assert reader.member("readme.txt"), "non-ELF member should still be present"
  end

  def test_empty_archive_still_carries_a_symbol_table_member
    reader = Reader.read(Writer.new.to_binary)
    assert_equal ["/"], reader.members.map(&:name)
    assert_empty reader.symbols
  end

  # --- interop: our writer -> system ar ---------------------------------

  def test_system_ar_lists_and_extracts_our_archive
    skip "system ar not available" unless ar_available?

    Dir.mktmpdir("rubycc-ar") do |dir|
      long = "a_long_member_name_beyond_the_inline_field.o"
      a_bytes = compile_object(SRC_A, "a.c")
      b_bytes = compile_object(SRC_B, "b.c")
      archive = File.join(dir, "libtest.a")
      File.binwrite(archive, Writer.new
        .add_member("a.o", a_bytes)
        .add_member(long, b_bytes)
        .to_binary)

      names, _err, status = Open3.capture3("ar", "t", archive)
      assert status.success?
      assert_equal ["a.o", long], names.split("\n")

      extract_dir = File.join(dir, "ext")
      Dir.mkdir(extract_dir)
      _out, _err, xstatus = Open3.capture3("ar", "x", archive, chdir: extract_dir)
      assert xstatus.success?
      assert_equal a_bytes, File.binread(File.join(extract_dir, "a.o"))
      assert_equal b_bytes, File.binread(File.join(extract_dir, long))
    end
  end

  def test_system_nm_reads_our_symbol_index
    skip "system nm not available" unless nm_available?

    Dir.mktmpdir("rubycc-ar") do |dir|
      archive = File.join(dir, "libtest.a")
      File.binwrite(archive, Writer.new
        .add_member("a.o", compile_object(SRC_A, "a.c"))
        .add_member("b.o", compile_object(SRC_B, "b.c"))
        .to_binary)

      out, _err, status = Open3.capture3("nm", "-s", archive)
      assert status.success?
      # nm -s prints an "Archive index:" section listing each indexed symbol and
      # the member that defines it.
      assert_match(/Archive index:/, out)
      assert_match(/add in a\.o/, out)
      assert_match(/caller in b\.o/, out)
    end
  end

  # --- interop: system ar -> our reader ---------------------------------

  def test_reads_an_archive_written_by_system_ar
    skip "system ar not available" unless ar_available?

    Dir.mktmpdir("rubycc-ar") do |dir|
      a_bytes = compile_object(SRC_A, "a.c")
      b_bytes = compile_object(SRC_B, "b.c")
      # A member whose name exceeds the 15-char inline field, so `ar` writes a
      # `//` name table our reader must resolve.
      long_name = "member_with_a_long_enough_name.o"
      File.binwrite(File.join(dir, "a.o"), a_bytes)
      File.binwrite(File.join(dir, long_name), b_bytes)
      archive = File.join(dir, "libsys.a")
      _out, err, status = Open3.capture3(
        "ar", "rcsD", archive, "a.o", long_name, chdir: dir
      )
      assert status.success?, err

      reader = Reader.read_file(archive)
      assert_equal ["a.o", long_name], reader.members.reject(&:special?).map(&:name)
      assert_equal a_bytes, reader.member("a.o").data
      assert_equal b_bytes, reader.member(long_name).data
      # The ranlib index `ar s` wrote resolves through our reader too.
      assert_equal "a.o", reader.member_defining("add").name
      assert_equal long_name, reader.member_defining("caller").name
    end
  end

  def test_tolerates_an_archive_without_a_symbol_index
    skip "system ar not available" unless ar_available?

    Dir.mktmpdir("rubycc-ar") do |dir|
      File.binwrite(File.join(dir, "a.o"), compile_object(SRC_A, "a.c"))
      archive = File.join(dir, "libplain.a")
      # The `S` modifier tells `ar` not to build a symbol table, leaving an
      # archive without a `/` index our reader must still handle.
      _out, err, status = Open3.capture3("ar", "rcSD", archive, "a.o", chdir: dir)
      assert status.success?, err

      reader = Reader.read_file(archive)
      assert_equal ["a.o"], reader.members.reject(&:special?).map(&:name)
      assert_empty reader.symbols, "a plain archive has no symbol index"
    end
  end

  # --- malformed input --------------------------------------------------

  def test_bad_global_magic_raises
    err = assert_raises(Rubycc::ObjFile::ArFormatError) { Reader.read("not an archive".b) }
    assert_match(/bad global magic/, err.message)
  end

  def test_truncated_member_header_raises
    # The magic followed by only a partial member header.
    bytes = Rubycc::ObjFile::AR_MAGIC + ("x" * 20).b
    err = assert_raises(Rubycc::ObjFile::ArFormatError) { Reader.read(bytes) }
    assert_match(/truncated member header/, err.message)
  end

  def test_size_running_past_end_of_file_raises
    good = Writer.new.add_member("a.o", "hello".b).to_binary
    # Corrupt the last member's size field (offset 48..57 within its header) to a
    # value far larger than the remaining bytes.
    header_offset = Reader.read(good).member("a.o").header_offset
    corrupt = good.dup
    corrupt[header_offset + 48, 10] = "9999999999"
    err = assert_raises(Rubycc::ObjFile::ArFormatError) { Reader.read(corrupt) }
    assert_match(/past end of file/, err.message)
  end

  def test_missing_header_terminator_raises
    good = Writer.new.add_member("a.o", "hello".b).to_binary
    header_offset = Reader.read(good).member("a.o").header_offset
    corrupt = good.dup
    corrupt[header_offset + 58, 2] = "XX"
    err = assert_raises(Rubycc::ObjFile::ArFormatError) { Reader.read(corrupt) }
    assert_match(/terminator/, err.message)
  end

  # --- CLI (exe/rubycc-ar) ----------------------------------------------

  def run_cli(*args, chdir: nil)
    opts = {}
    opts[:chdir] = chdir if chdir
    Open3.capture3("ruby", "-I#{LIB_DIR}", EXE_PATH, *args, **opts)
  end

  def test_cli_rcs_then_t_lists_members
    Dir.mktmpdir("rubycc-ar-cli") do |dir|
      File.binwrite(File.join(dir, "a.o"), compile_object(SRC_A, "a.c"))
      File.binwrite(File.join(dir, "b.o"), compile_object(SRC_B, "b.c"))

      _out, err, status = run_cli("rcs", "libcli.a", "a.o", "b.o", chdir: dir)
      assert_equal 0, status.exitstatus, err
      assert File.exist?(File.join(dir, "libcli.a"))

      out, _err, tstatus = run_cli("t", "libcli.a", chdir: dir)
      assert_equal 0, tstatus.exitstatus
      assert_equal ["a.o", "b.o"], out.split("\n")
    end
  end

  def test_cli_r_replaces_an_existing_member
    Dir.mktmpdir("rubycc-ar-cli") do |dir|
      File.binwrite(File.join(dir, "a.o"), "first".b)
      run_cli("rcs", "lib.a", "a.o", chdir: dir)

      File.binwrite(File.join(dir, "a.o"), "second".b)
      _out, err, status = run_cli("r", "lib.a", "a.o", chdir: dir)
      assert_equal 0, status.exitstatus, err

      reader = Reader.read_file(File.join(dir, "lib.a"))
      assert_equal ["a.o"], reader.members.reject(&:special?).map(&:name)
      assert_equal "second".b, reader.member("a.o").data
    end
  end

  def test_cli_x_extracts_members_to_cwd
    Dir.mktmpdir("rubycc-ar-cli") do |dir|
      a_bytes = compile_object(SRC_A, "a.c")
      File.binwrite(File.join(dir, "a.o"), a_bytes)
      File.binwrite(File.join(dir, "b.o"), compile_object(SRC_B, "b.c"))
      run_cli("rcs", "lib.a", "a.o", "b.o", chdir: dir)

      # Extract into a fresh subdirectory so the originals are not the ones read.
      ext = File.join(dir, "ext")
      Dir.mkdir(ext)
      FileUtils_cp(File.join(dir, "lib.a"), File.join(ext, "lib.a"))
      _out, err, status = run_cli("x", "lib.a", "a.o", chdir: ext)
      assert_equal 0, status.exitstatus, err

      assert_equal a_bytes, File.binread(File.join(ext, "a.o"))
      refute File.exist?(File.join(ext, "b.o")), "only the named member should be extracted"
    end
  end

  # A member name that carries a path (a "../" segment or an absolute path) is a
  # zip-slip-style attack: `x` must refuse to write it rather than silently
  # escape the extraction directory (Step 118). ArWriter itself does not police
  # member names, so a hostile archive is built with the ordinary writer.
  def test_cli_x_rejects_a_member_name_with_a_path_traversal
    Dir.mktmpdir("rubycc-ar-cli") do |dir|
      ext = File.join(dir, "ext")
      Dir.mkdir(ext)
      File.binwrite(File.join(ext, "evil.a"),
                    Writer.new.add_member("../evil.txt", "pwned".b).to_binary)

      _out, err, status = run_cli("x", "evil.a", chdir: ext)

      refute_equal 0, status.exitstatus
      assert_match(/unsafe name/, err)
      refute File.exist?(File.join(dir, "evil.txt")), "traversal must not escape the extraction directory"
    end
  end

  def test_cli_x_rejects_a_member_name_that_is_an_absolute_path
    Dir.mktmpdir("rubycc-ar-cli") do |dir|
      archive = File.join(dir, "evil2.a")
      File.binwrite(archive, Writer.new.add_member("/tmp/rubycc_ar_absolute_evil.txt", "pwned".b).to_binary)

      _out, err, status = run_cli("x", "evil2.a", chdir: dir)

      refute_equal 0, status.exitstatus
      assert_match(/unsafe name/, err)
      refute File.exist?("/tmp/rubycc_ar_absolute_evil.txt")
    end
  end

  def test_cli_no_arguments_is_a_usage_error
    _out, err, status = run_cli
    assert_equal 1, status.exitstatus
    assert_match(/no operation/, err)
  end

  def test_cli_unknown_operation_is_a_usage_error
    Dir.mktmpdir("rubycc-ar-cli") do |dir|
      _out, err, status = run_cli("z", "lib.a", chdir: dir)
      assert_equal 1, status.exitstatus
      assert_match(/unknown or missing operation/, err)
    end
  end

  def test_cli_missing_archive_reports_an_error
    Dir.mktmpdir("rubycc-ar-cli") do |dir|
      _out, err, status = run_cli("t", "does_not_exist.a", chdir: dir)
      assert_equal 1, status.exitstatus
      assert_match(/No such file/, err)
    end
  end

  private

  # A dependency-free file copy so the test does not require 'fileutils'.
  def FileUtils_cp(src, dst)
    File.binwrite(dst, File.binread(src))
  end
end
