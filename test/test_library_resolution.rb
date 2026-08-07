# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"
require "fiddle"

# Exercises library resolution (Rubycc::Link::LibraryResolver and its embedded
# LinkerScript reader): turning a driver's `-l`/`-L` requests into the shared
# objects imports bind against and the relocatable inputs merged in.
#
# The unit layer works from synthetic fixtures written into a tmpdir — files
# carrying just the ELF or `ar` magic (resolution classifies by leading bytes,
# never linking them) and hand-written linker-script text — so the search order,
# the `.so`/`.a` preference, exact-name and error handling, and the script
# parser are all checked without a host toolchain. The acceptance layer resolves
# the machine's real libraries: `-lz` is resolved, linked with SharedLinker and
# dlopened so zlib functions are actually called, glibc's `libc.so` GROUP script
# is expanded to reach libc, and the DT_NEEDED result is cross-checked against
# gcc's own `-shared` output. Every host-dependent case is skip-guarded.
class TestLibraryResolution < Minitest::Test
  include ExecutionHelper

  Resolver = Rubycc::Link::LibraryResolver
  Script = Rubycc::Link::LinkerScript
  LinkError = Rubycc::Link::LinkError
  Reader = Rubycc::ObjFile::ELFReader

  # --- search order and the .so / .a preference --------------------------------

  # Within one directory a `lib<name>.so` is chosen over a `lib<name>.a`.
  def test_shared_is_preferred_over_archive_in_a_directory
    in_tmpdir do |dir|
      write_shared(File.join(dir, "libfoo.so"))
      write_archive(File.join(dir, "libfoo.a"))
      r = Resolver.resolve(["foo"], search_dirs: [dir])
      assert_equal [File.join(dir, "libfoo.so")], r.needed
      assert_empty r.inputs
    end
  end

  # With no `.so` present the `.a` in the same directory is taken instead.
  def test_archive_is_used_when_no_shared_object_exists
    in_tmpdir do |dir|
      write_archive(File.join(dir, "libfoo.a"))
      r = Resolver.resolve(["foo"], search_dirs: [dir])
      assert_empty r.needed
      assert_equal [File.join(dir, "libfoo.a")], r.inputs
    end
  end

  # A runtime-only installation may keep only the SONAME-bearing shared object
  # (for example libz.so.1) and omit the development symlink libz.so. Plain -l
  # resolution must still find that real file; this fixture deliberately creates
  # no symlink.
  def test_versioned_shared_is_used_for_plain_name
    in_tmpdir do |dir|
      versioned = File.join(dir, "libfoo.so.1")
      write_shared(versioned)
      r = Resolver.resolve(["foo"], search_dirs: [dir])
      assert_equal [versioned], r.needed
      assert_empty r.inputs
    end
  end

  # An unversioned development library remains preferred when both spellings are
  # present, and a versioned shared object still outranks a static archive.
  def test_shared_preference_includes_versioned_runtime_library
    in_tmpdir do |dir|
      unversioned = File.join(dir, "libfoo.so")
      versioned = File.join(dir, "libfoo.so.1")
      archive = File.join(dir, "libfoo.a")
      write_shared(unversioned)
      write_shared(versioned)
      write_archive(archive)
      r = Resolver.resolve(["foo"], search_dirs: [dir])
      assert_equal [unversioned], r.needed
      assert_empty r.inputs
    end
  end

  # The `.so`/`.a` preference does not cross directories: an earlier directory's
  # `.a` settles the request before a later directory's `.so` is considered.
  def test_first_directory_with_either_form_wins
    in_tmpdir do |early|
      in_tmpdir do |late|
        write_archive(File.join(early, "libfoo.a"))
        write_shared(File.join(late, "libfoo.so"))
        r = Resolver.resolve(["foo"], search_dirs: [early, late])
        assert_empty r.needed, "the earlier directory's .a wins over a later .so"
        assert_equal [File.join(early, "libfoo.a")], r.inputs
      end
    end
  end

  # `-L` directories are consulted in command-line order.
  def test_search_directories_are_tried_in_order
    in_tmpdir do |first|
      in_tmpdir do |second|
        write_shared(File.join(first, "libfoo.so"))
        write_shared(File.join(second, "libfoo.so"))
        r = Resolver.resolve(["foo"], search_dirs: [first, second])
        assert_equal [File.join(first, "libfoo.so")], r.needed
      end
    end
  end

  # A `:filename` request looks the exact name up rather than composing lib….so.
  def test_colon_request_matches_an_exact_filename
    in_tmpdir do |dir|
      write_shared(File.join(dir, "libbar.so.1"))
      r = Resolver.resolve([":libbar.so.1"], search_dirs: [dir])
      assert_equal [File.join(dir, "libbar.so.1")], r.needed
    end
  end

  # A glibc-shaped runtime with only versioned DSOs is resolved without relying
  # on development symlinks. The files are bare ELF fixtures, so this remains a
  # host-independent resolution test rather than a test of the host package set.
  def test_versioned_glibc_runtime_libraries_are_resolved
    in_tmpdir do |dir|
      libraries = {
        "m" => "libm.so.6",
        "pthread" => "libpthread.so.0",
        "dl" => "libdl.so.2",
        "c" => "libc.so.6" # platform-literal: synthetic fixture naming a glibc-shaped runtime, not a host assertion
      }
      libraries.each_value { |name| write_shared(File.join(dir, name)) }

      r = Resolver.new(search_dirs: [dir])
      r.instance_variable_set(:@dirs, [dir])
      resolution = r.resolve(libraries.keys)
      assert_equal libraries.values.map { |name| File.join(dir, name) }, resolution.needed
    end
  end

  # musl's runtime image has one libc ELF and no libm/libpthread/libdl/etc.
  # development names. All of those requests must converge on that image, with
  # no artificial development symlink in the fixture.
  def test_musl_libc_provided_libraries_fall_back_to_one_runtime_image
    in_tmpdir do |dir|
      libc = File.join(dir, "libc.musl-x86_64.so.1") # platform-literal: synthetic fixture naming a musl-shaped runtime, not a host assertion
      write_shared(libc)

      r = Resolver.new(search_dirs: [dir])
      r.instance_variable_set(:@dirs, [dir])
      resolution = r.resolve(Resolver::MUSL_LIBC_PROVIDED_LIBRARIES)
      assert_equal [libc], resolution.needed
    end
  end

  # An unsatisfiable request is a hard error naming the missing library.
  def test_missing_library_is_a_clear_error
    in_tmpdir do |dir|
      err = assert_raises(LinkError) { Resolver.resolve(["nope"], search_dirs: [dir]) }
      assert_match(/cannot find -lnope/, err.message)
    end
  end

  # A default system directory is consulted only when it exists on the host, and a
  # non-existent `-L` directory is dropped from the search path.
  def test_search_path_keeps_only_existing_directories
    resolver = Resolver.new(search_dirs: ["/rubycc-nonexistent-dir"])
    resolver.dirs.each { |d| assert File.directory?(d), "#{d} must exist" }
    refute_includes resolver.dirs, "/rubycc-nonexistent-dir"
    default_present = Resolver::DEFAULT_SYSTEM_DIRS.select { |d| File.directory?(d) }
    assert_equal default_present, resolver.dirs
  end

  # A native aarch64 process must search Debian's aarch64 multiarch trees rather
  # than inheriting the x86_64 paths used by the development host.
  def test_aarch64_default_system_directories_use_aarch64_multiarch_paths
    dirs = Resolver.default_system_dirs(target: "aarch64-linux-gnu")

    assert_equal [
      "/usr/lib/aarch64-linux-gnu",
      "/usr/lib",
      "/lib/aarch64-linux-gnu",
      "/lib",
      "/usr/aarch64-linux-gnu/lib",
      "/usr/local/lib"
    ], dirs
    refute_includes dirs, "/usr/lib/x86_64-linux-gnu"
  end

  # --- classification of resolved files ----------------------------------------

  # A resolved file is routed by what it is: a shared object to `needed`, an
  # archive or a relocatable object to `inputs`.
  def test_files_are_dispatched_by_kind
    in_tmpdir do |dir|
      write_shared(File.join(dir, "libdyn.so"))
      write_archive(File.join(dir, "libarc.a"))
      write_relocatable(File.join(dir, "obj.o"))
      r = Resolver.resolve(["dyn", "arc", ":obj.o"], search_dirs: [dir])
      assert_equal [File.join(dir, "libdyn.so")], r.needed
      assert_equal [File.join(dir, "libarc.a"), File.join(dir, "obj.o")], r.inputs
    end
  end

  # A library reached twice (here directly and again through a linker script)
  # contributes a single entry.
  def test_duplicate_resolution_is_recorded_once
    in_tmpdir do |dir|
      shared = File.join(dir, "libfoo.so")
      write_shared(shared)
      File.write(File.join(dir, "libscript.so"), "GROUP ( #{shared} )")
      r = Resolver.resolve(["foo", ":libscript.so"], search_dirs: [dir])
      assert_equal [shared], r.needed
    end
  end

  # --- the linker-script reader ------------------------------------------------

  # A GROUP list yields its files in order, comments are stripped, AS_NEEDED
  # contents are treated as ordinary entries, and OUTPUT_FORMAT is skipped.
  def test_script_parses_group_with_as_needed_and_skips_output_format
    # platform-literal: arbitrary example path text for the script parser, not a host assertion
    group_line = "GROUP ( /lib/libc.so.6 /usr/lib/libc_nonshared.a AS_NEEDED ( /lib64/ld.so.2 ) )"
    text = <<~SCRIPT
      /* GNU ld script
         a multi-line comment */
      OUTPUT_FORMAT(elf64-x86-64)
      #{group_line}
    SCRIPT
    assert_equal ["/lib/libc.so.6", "/usr/lib/libc_nonshared.a", "/lib64/ld.so.2"], # platform-literal: same example text as above
                 Script.parse(text)
  end

  # INPUT is an equivalent file-list command, and `-l` tokens are preserved for
  # the resolver to search recursively.
  def test_script_parses_input_and_keeps_dash_l_tokens
    assert_equal ["-lm", "/abs/libx.a"], Script.parse("INPUT ( -lm /abs/libx.a )")
  end

  # OUTPUT_FORMAT's parenthesized argument is discarded, not mistaken for a file.
  def test_script_discards_output_format_argument
    assert_empty Script.parse("OUTPUT_FORMAT ( elf64-x86-64 )")
  end

  # Comma-separated names and punctuation glued to the parentheses tokenize the
  # same as the spaced form.
  def test_script_tolerates_commas_and_tight_punctuation
    assert_equal ["a.o", "b.o"], Script.parse("GROUP(a.o,b.o)")
  end

  # An unrecognized directive outside a file list is ignored rather than
  # half-interpreted, and does not disturb a following GROUP.
  def test_script_ignores_unsupported_directives
    assert_equal ["/lib/libc.so.6"], # platform-literal: arbitrary example path text for the script parser, not a host assertion
                 # platform-literal: the same example path, as the script text the parser is fed
                 Script.parse("ENTRY(_start)\nGROUP ( /lib/libc.so.6 )")
  end

  # A `-l` token inside a script is resolved recursively against the search path.
  def test_script_dash_l_token_is_resolved_recursively
    in_tmpdir do |dir|
      write_shared(File.join(dir, "libdep.so"))
      File.write(File.join(dir, "libwrap.so"), "GROUP ( -ldep )")
      r = Resolver.resolve([":libwrap.so"], search_dirs: [dir])
      assert_equal [File.join(dir, "libdep.so")], r.needed
    end
  end

  # A libc.so-shaped script expands to a shared object (needed), a static archive
  # (inputs) and an AS_NEEDED shared object (needed), each classified correctly.
  def test_libc_shaped_script_splits_shared_and_archive
    in_tmpdir do |dir|
      so6 = File.join(dir, "libc.so.6") # platform-literal: synthetic fixture naming a glibc-shaped script, not a host assertion
      nonshared = File.join(dir, "libc_nonshared.a")
      loader = File.join(dir, "ld.so.2")
      write_shared(so6)
      write_archive(nonshared)
      write_shared(loader)
      script = File.join(dir, "libc.so")
      File.write(script, "/* GNU ld script */\nGROUP ( #{so6} #{nonshared} AS_NEEDED ( #{loader} ) )")
      r = Resolver.resolve([":libc.so"], search_dirs: [dir])
      assert_equal [so6, loader], r.needed
      assert_equal [nonshared], r.inputs
    end
  end

  # --- acceptance: the host's real libraries -----------------------------------

  # Resolving `-lz`, linking against it and dlopening the result must let zlib's
  # own functions run: crc32 of a known string yields its well-known value and
  # compressBound is the documented bound. libz is skip-guarded.
  def test_resolves_libz_and_calls_it_through_dlopen
    skip "libz unavailable" unless resolvable?("z")

    src = <<~C
      unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len);
      unsigned long compressBound(unsigned long sourceLen);
      unsigned long my_crc(const unsigned char *s, unsigned int n) { return crc32(0, s, n); }
      unsigned long my_bound(unsigned long n) { return compressBound(n); }
    C
    with_linked_so(src, libraries: ["z"], soname: "libztest.so") do |so|
      assert_equal ["libz.so.1"], Reader.read_file(so).needed,
                   "the DT_NEEDED is zlib's SONAME, not the -lz spelling"
      lib = Fiddle.dlopen(so)
      crc = call(lib, "my_crc", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_LONG)
             .call("123456789", 9)
      assert_equal 0xCBF43926, crc & 0xFFFFFFFF, "crc32(\"123456789\") is the standard check value"
      bound = call(lib, "my_bound", [Fiddle::TYPE_LONG], Fiddle::TYPE_LONG).call(100)
      assert_operator bound, :>=, 100, "compressBound never underestimates its input"
    ensure
      lib&.close
    end
  end

  # `-lc` must resolve the host's libc — a GROUP linker script on usual glibc
  # systems, or musl's combined runtime image — so an imported libc function
  # (strlen) binds and runs. The expected DT_NEEDED is taken from the resolved
  # file's own SONAME because glibc and musl use different names.
  def test_resolves_libc_and_binds_a_libc_function
    skip "libc unavailable" unless resolvable?("c")

    src = <<~C
      unsigned long strlen(const char *s);
      unsigned long my_len(const char *s) { return strlen(s); }
    C
    with_linked_so(src, libraries: ["c"], soname: "libctest.so") do |so|
      needed = Reader.read_file(so).needed
      libc_path = Resolver.resolve(["c"]).needed.first
      libc = Reader.read_file(libc_path)
      expected = libc.soname || File.basename(libc_path)
      assert_includes needed, expected, "the resolved libc image supplies strlen"
      lib = Fiddle.dlopen(so)
      len = call(lib, "my_len", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG).call("acceptance")
      assert_equal 10, len, "the imported strlen must run"
    ensure
      lib&.close
    end
  end

  # A resolved static archive is merged through the lazy pull-in: only the member
  # a still-undefined symbol needs is taken. Built with the project's own ArWriter
  # from rubycc-compiled members so no toolchain is required.
  def test_resolved_archive_is_pulled_in_lazily
    in_tmpdir do |dir|
      writer = Rubycc::ObjFile::ArWriter.new
      writer.add_member("used.o", compile("int helper(int x) { return x + 7; }", "used.c"))
      writer.add_member("unused.o", compile("int stray(int x) { return x - 1; }", "unused.c"))
      writer.write(File.join(dir, "libhelp.a"))

      main = compile("int helper(int x); int compute(int x) { return helper(x) * 2; }", "main.c")
      main_o = File.join(dir, "main.o")
      File.binwrite(main_o, main)

      so_bytes = Resolver.link([main_o], libraries: ["help"], search_dirs: [dir],
                               soname: "libc2.so", target: ExecutionHelper::EXECUTION_TARGET)
      reader = Reader.read(so_bytes)
      exported = reader.dynamic_symbols.select { |s| s.defined? }.map(&:name)
      assert_includes exported, "helper", "the needed member is pulled in and its symbol defined"
      refute_includes exported, "stray", "the unused member stays out"
    end
  end

  # gcc's own `-shared -lz` must record the same DT_NEEDED SONAME our resolution
  # does, confirming the library was resolved to the same object.
  def test_matches_gcc_dt_needed_for_libz
    skip "gcc unavailable" unless tool?("gcc")
    skip "libz unavailable" unless resolvable?("z")

    src = <<~C
      unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len);
      unsigned long f(const unsigned char *s, unsigned int n) { return crc32(0, s, n); }
    C
    in_tmpdir do |dir|
      obj = File.join(dir, "u.o")
      File.binwrite(obj, compile(src, "u.c"))
      ours = Resolver.link([obj], libraries: ["z"], soname: "libz-interop.so",
                           target: ExecutionHelper::EXECUTION_TARGET)
      theirs = File.join(dir, "theirs.so")
      out, status = Open3.capture2e(*execution_gcc_command("-shared", "-o", theirs, obj, "-lz"))
      skip "gcc -shared failed:\n#{out}" unless status.success?
      assert_equal Reader.read_file(theirs).needed, Reader.read(ours).needed,
                   "both link results depend on the same zlib SONAME"
    end
  end

  private

  # Compiles one C source with rubycc under -fPIC into an object image.
  def compile(src, name)
    Rubycc::Compiler.new.compile(src, filename: name, pic: true,
                                 target: ExecutionHelper::EXECUTION_TARGET)
  end

  # Compiles `src`, resolves `libraries`, links a shared object to disk and yields
  # its path.
  def with_linked_so(src, libraries:, soname:)
    in_tmpdir do |dir|
      obj = File.join(dir, "u.o")
      File.binwrite(obj, compile(src, "u.c"))
      so = File.join(dir, "libtest.so")
      Resolver.link_to([obj], so, libraries: libraries, soname: soname,
                       target: ExecutionHelper::EXECUTION_TARGET)
      yield so
    end
  end

  def call(lib, name, args, ret)
    Fiddle::Function.new(lib[name], args, ret)
  end

  # Whether a `-l` request resolves against the host's default search path.
  def resolvable?(spec)
    Resolver.resolve([spec], target: ExecutionHelper::EXECUTION_TARGET)
    true
  rescue LinkError
    false
  end

  # A file carrying just enough of an ELF64 header to be classified: the magic and
  # an e_type at offset 16. ET_DYN (3) marks a shared object, ET_REL (1) a
  # relocatable one.
  def write_shared(path) = write_elf_stub(path, 3)
  def write_relocatable(path) = write_elf_stub(path, 1)

  def write_elf_stub(path, e_type)
    File.binwrite(path, "\x7FELF".b + ("\0".b * 12) + [e_type].pack("S<"))
  end

  # A file carrying the `ar` global magic, classified as an archive.
  def write_archive(path)
    File.binwrite(path, "!<arch>\n".b)
  end

  def in_tmpdir(&block)
    Dir.mktmpdir("rubycc-lib", &block)
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
