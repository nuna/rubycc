# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"

# Exercises Rubycc::ObjFile::ELFReader. The core is the round-trip contract
# with ELFWriter (N7): every object the writer can emit is read back and its
# parsed structure asserted against what was written. Alongside that, real
# gcc/rubycc `.o` files and the system libc `.so` are read to prove the parser
# works on artifacts it did not itself produce, and `readelf` is used as an
# independent oracle where available.
class TestElfReader < Minitest::Test
  include ExecutionHelper
  include LibcHelper

  Reader = Rubycc::ObjFile::ELFReader
  Writer = Rubycc::ObjFile::ELFWriter

  # mov eax, 42; leave; ret.
  MAIN_CODE = [0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC9, 0xC3].pack("C*")
  # call rel32 (placeholder) ; ret — the rel32 field at offset 1 is relocated.
  CALL_CODE = [0xE8, 0x00, 0x00, 0x00, 0x00, 0xC3].pack("C*")
  CALL_REL32_OFFSET = 1
  # lea rax, [rip + 0] ; ret — the rel32 displacement at offset 3 is relocated.
  LEA_CODE = [0x48, 0x8D, 0x05, 0x00, 0x00, 0x00, 0x00, 0xC3].pack("C*")
  LEA_REL32_OFFSET = 3
  # mov rax, [rip + 0] ; ret — the PIC GOT-load form (48 8B 05 + placeholder),
  # whose rel32 at offset 3 an R_X86_64_REX_GOTPCRELX relocation targets.
  GOT_CODE = [0x48, 0x8B, 0x05, 0x00, 0x00, 0x00, 0x00, 0xC3].pack("C*")
  GOT_REL32_OFFSET = 3
  # "hi\0world\0": "hi" at .rodata offset 0, "world" at offset 3.
  RODATA = "hi\0world\0".b
  WORLD_OFFSET = 3
  DATA_BYTES = [40, 0, 0, 0].pack("C*")

  # --- round-trip golden tests against ELFWriter -------------------------

  def test_text_only_object_round_trips_header_and_sections
    obj = read_writer do |w|
      w.add_file_symbol("foo.c")
      w.add_text_section(MAIN_CODE)
      w.add_global_func("main", 0, MAIN_CODE.bytesize)
    end

    assert obj.relocatable?, "a writer object is ET_REL"
    assert_equal Reader::EM_X86_64, obj.machine
    # The writer's fixed layout for a plain text object.
    assert_equal ["", ".text", ".note.GNU-stack", ".symtab", ".strtab", ".shstrtab"],
                 obj.sections.map(&:name)

    text = obj.section(".text")
    assert_equal Reader::SHT_PROGBITS, text.type
    assert_equal Reader::EM_X86_64, obj.machine
    assert_equal MAIN_CODE, text.data
    assert_equal MAIN_CODE.bytesize, text.size
    # SHF_ALLOC | SHF_EXECINSTR.
    assert_equal 0x2, text.flags & 0x2
    assert_equal 0x4, text.flags & 0x4
  end

  def test_text_only_object_round_trips_symbols
    obj = read_writer do |w|
      w.add_file_symbol("foo.c")
      w.add_text_section(MAIN_CODE)
      w.add_global_func("main", 0, MAIN_CODE.bytesize)
    end

    file = obj.symbol("foo.c")
    assert_equal :file, file.type
    assert_equal :local, file.bind
    assert file.absolute?, "a FILE symbol carries SHN_ABS"

    main = obj.symbol("main")
    assert_equal :func, main.type
    assert_equal :global, main.bind
    assert_equal 0, main.value
    assert_equal MAIN_CODE.bytesize, main.size
    assert_equal ".text", main.section.name
    refute main.undefined?

    # The section symbol the writer emits for .text points back at .text.
    section_sym = obj.symbols.find { |s| s.type == :section && s.section&.name == ".text" }
    refute_nil section_sym, ".text section symbol should be present"
    assert_equal :local, section_sym.bind
  end

  def test_undefined_symbol_and_plt32_text_relocation_round_trip
    obj = read_writer do |w|
      w.add_file_symbol("foo.c")
      w.add_text_section(CALL_CODE)
      w.add_global_func("main", 0, CALL_CODE.bytesize)
      w.add_undefined_symbol("abs")
      w.add_text_relocation(offset: CALL_REL32_OFFSET, symbol: "abs")
    end

    abs = obj.symbol("abs")
    assert abs.undefined?, "abs is SHN_UNDEF"
    assert_equal :global, abs.bind
    assert_nil abs.section

    relocs = obj.relocations_for(".text")
    assert_equal 1, relocs.size
    reloc = relocs.first
    assert_equal CALL_REL32_OFFSET, reloc.offset
    assert_equal :R_X86_64_PLT32, reloc.type_name
    assert_equal(-4, reloc.addend)
    assert_equal "abs", reloc.symbol.name

    # The RELA section's target is resolved through sh_info.
    rs = obj.relocation_sections.first
    assert_equal ".rela.text", rs.section.name
    assert_equal ".text", rs.target.name
  end

  def test_rodata_and_pc32_relocation_round_trip
    obj = read_writer do |w|
      w.add_file_symbol("foo.c")
      w.add_text_section(LEA_CODE)
      w.add_global_func("main", 0, LEA_CODE.bytesize)
      w.set_rodata(RODATA)
      # The caller passes the string's unbiased .rodata offset; the machine
      # description applies x86_64's -4 rel32 bias on the way out.
      w.add_rodata_relocation(offset: LEA_REL32_OFFSET, addend: WORLD_OFFSET)
    end

    rodata = obj.section(".rodata")
    refute_nil rodata
    assert_equal RODATA, rodata.data

    reloc = obj.relocations_for(".text").first
    assert_equal LEA_REL32_OFFSET, reloc.offset
    assert_equal :R_X86_64_PC32, reloc.type_name
    assert_equal WORLD_OFFSET - 4, reloc.addend
    # The target is the .rodata section symbol (a STT_SECTION), so it resolves
    # back to the .rodata section itself.
    assert_equal :section, reloc.symbol.type
    assert_equal ".rodata", reloc.symbol.section.name
  end

  # A PIC GOT reference (add_got_relocation) round-trips as an
  # R_X86_64_REX_GOTPCRELX (type 42) against its symbol, with the -4 PC-relative
  # bias a "mov rax, sym@GOTPCREL(rip)" needs.
  def test_got_relocation_round_trips
    obj = read_writer do |w|
      w.add_file_symbol("foo.c")
      w.add_text_section(GOT_CODE)
      w.add_global_func("main", 0, GOT_CODE.bytesize)
      w.add_undefined_symbol("x")
      w.add_got_relocation(offset: GOT_REL32_OFFSET, symbol: "x")
    end

    reloc = obj.relocations_for(".text").first
    assert_equal GOT_REL32_OFFSET, reloc.offset
    assert_equal 42, reloc.type
    assert_equal :R_X86_64_REX_GOTPCRELX, reloc.type_name
    assert_equal(-4, reloc.addend)
    assert_equal "x", reloc.symbol.name
    assert reloc.symbol.undefined?, "x is SHN_UNDEF"
  end

  def test_data_section_and_absolute_relocation_round_trip
    # "int g = 41; int *p = &g;" — g in .data, p a pointer slot with an absolute
    # R_X86_64_64 relocation against g, all produced by the real compiler.
    obj = read_compiler("int g = 41; int *p = &g; int main(void) { return 0; }")

    data = obj.section(".data")
    refute_nil data
    assert_equal 0x1, data.flags & 0x1 # SHF_WRITE
    assert_equal 0x2, data.flags & 0x2 # SHF_ALLOC
    assert_equal data.size, data.data.bytesize

    reloc = obj.relocations_for(".data").first
    refute_nil reloc, ".rela.data relocation should be read"
    assert_equal :R_X86_64_64, reloc.type_name
    assert_equal 0, reloc.addend
    assert_equal "g", reloc.symbol.name

    g = obj.symbol("g")
    assert_equal :object, g.type
    assert_equal ".data", g.section.name
  end

  def test_bss_section_round_trips_size_without_file_bytes
    obj = read_writer do |w|
      w.add_file_symbol("foo.c")
      w.add_text_section(MAIN_CODE)
      w.add_global_func("main", 0, MAIN_CODE.bytesize)
      w.set_bss(4, align: 4)
      w.add_global_object("counter", :bss, 0, 4)
    end

    bss = obj.section(".bss")
    refute_nil bss
    assert bss.nobits?, ".bss is SHT_NOBITS"
    assert_equal 4, bss.size, ".bss keeps its in-memory size"
    assert_nil bss.data, "a NOBITS section holds no file bytes"

    counter = obj.symbol("counter")
    assert_equal :object, counter.type
    assert_equal ".bss", counter.section.name
    assert_equal 4, counter.size
  end

  def test_local_and_global_symbol_ordering_round_trips
    obj = read_writer do |w|
      w.add_file_symbol("foo.c")
      w.add_text_section(MAIN_CODE)
      w.add_local_func("helper", 0, MAIN_CODE.bytesize)
      w.add_global_func("main", 0, MAIN_CODE.bytesize)
      w.set_bss(8, align: 4)
      w.add_local_object("priv", :bss, 0, 4)
      w.add_global_object("pub", :bss, 4, 4)
    end

    assert_equal :local, obj.symbol("helper").bind
    assert_equal :local, obj.symbol("priv").bind
    assert_equal :global, obj.symbol("main").bind
    assert_equal :global, obj.symbol("pub").bind

    # Every local precedes the first global (ELF's ordering invariant), which
    # the reader preserves in the parsed order.
    binds = obj.symbols.map(&:bind)
    first_global = binds.index(:global)
    assert(binds[0...first_global].all? { |b| b == :local }, "locals come first")
    assert_operator obj.symbol("helper").index, :<, first_global
    assert_operator obj.symbol("main").index, :>=, first_global
  end

  def test_read_file_reads_from_disk
    bin = build_writer do |w|
      w.add_text_section(MAIN_CODE)
      w.add_global_func("main", 0, MAIN_CODE.bytesize)
    end
    Dir.mktmpdir("rubycc-elf") do |dir|
      path = File.join(dir, "m.o")
      File.binwrite(path, bin)
      obj = Reader.read_file(path)
      assert_equal MAIN_CODE, obj.section(".text").data
    end
  end

  # --- relocation type coverage (32 / 32S / unknown pass-through) ---------

  def test_relocation_types_decode_including_unknown_passthrough
    # The writer only emits 64/PC32/PLT32, so to cover R_X86_64_32 (10),
    # R_X86_64_32S (11) and an unknown type, patch the relocation type nibble of
    # a real .rela.text entry and re-read. The relocation type is the low 32
    # bits of r_info at the entry's byte 8; its low byte carries the value here.
    bin = build_writer do |w|
      w.add_text_section(CALL_CODE)
      w.add_global_func("main", 0, CALL_CODE.bytesize)
      w.add_undefined_symbol("abs")
      w.add_text_relocation(offset: CALL_REL32_OFFSET, symbol: "abs")
    end
    rela_offset = Reader.read(bin).section(".rela.text").offset

    {
      10 => :R_X86_64_32,
      11 => :R_X86_64_32S,
      99 => nil # an unknown type is preserved numerically, not rejected
    }.each do |type, name|
      patched = bin.dup
      patched.setbyte(rela_offset + 8, type)
      reloc = Reader.read(patched).relocations_for(".text").first
      assert_equal type, reloc.type
      if name
        assert_equal name, reloc.type_name
      else
        assert_nil reloc.type_name, "an unknown type has no name"
      end
      assert_equal "abs", reloc.symbol.name, "the symbol still resolves for type #{type}"
    end
  end

  # --- real compiler / gcc .o --------------------------------------------

  def test_reads_rubycc_compiled_object
    obj = read_compiler("int foo(void); int main(void) { return foo(); }")

    main = obj.symbol("main")
    assert_equal :func, main.type
    refute main.undefined?, "main is defined in this object"

    foo = obj.symbol("foo")
    assert foo.undefined?, "foo is an undefined external"

    reloc = obj.relocations_for(".text").find { |r| r.symbol&.name == "foo" }
    refute_nil reloc, "the call to foo produces a .text relocation"
    assert_includes [:R_X86_64_PLT32, :R_X86_64_PC32], reloc.type_name
  end

  def test_reads_gcc_compiled_object
    source = "int helper(int x) { return x + 1; }\nint main(void) { return helper(41); }\n"
    in_tmpdir do |dir|
      path = File.join(dir, "g.o")
      compile_with_gcc(source, path)
      obj = Reader.read_file(path)

      assert obj.relocatable?
      refute_nil obj.section(".text"), "gcc emits a .text section"

      main = obj.symbol("main")
      refute_nil main, "gcc object exports main"
      assert_equal :func, main.type
      assert_equal :global, main.bind

      helper = obj.symbol("helper")
      refute_nil helper, "gcc object defines helper"
      assert_equal :func, helper.type

      # main calls helper; presence and relationship, not a byte offset.
      reloc = obj.relocations_for(".text").find { |r| r.symbol&.name == "helper" }
      refute_nil reloc, "the call to helper produces a .text relocation"
    end
  end

  # --- readelf cross-checks (skipped when readelf is unavailable) ---------

  def test_symbol_list_matches_readelf
    skip "readelf not available" unless readelf?

    bin = build_writer do |w|
      w.add_file_symbol("foo.c")
      w.add_text_section(MAIN_CODE)
      w.add_local_func("helper", 0, MAIN_CODE.bytesize)
      w.add_global_func("main", 0, MAIN_CODE.bytesize)
      w.set_bss(8, align: 4)
      w.add_local_object("priv", :bss, 0, 4)
      w.add_global_object("pub", :bss, 4, 4)
    end
    obj = Reader.read(bin)

    with_object_file(bin) do |path|
      rows = readelf_symbols(path, "-s")
      # Same number of entries, and every entry agrees on name, binding, type
      # and section membership (Ndx) — the reader against an independent oracle.
      assert_equal rows.size, obj.symbols.size
      rows.each do |row|
        sym = obj.symbols[row[:num]]
        # readelf renders a STT_SECTION symbol with its section's name rather
        # than its (empty) st_name, so compare names only for the rest.
        assert_equal row[:name], sym.name, "name at index #{row[:num]}" unless row[:type] == "SECTION"
        assert_equal row[:bind], sym.bind.to_s.upcase, "binding of #{row[:name]}"
        assert_equal row[:type], sym.type.to_s.upcase, "type of #{row[:name]}"
        assert_equal row[:ndx], sym.shndx, "section index of #{row[:name]}"
      end
    end
  end

  # --- shared object (.so) dynamic reading --------------------------------

  # Delegates to LibcHelper so this search is written once for the whole suite.
  def libc_path
    host_libc_path
  end

  def test_reads_libc_dynamic_symbols_and_soname
    path = libc_path
    skip "host libc not found" unless path && File.exist?(path)

    lib = Reader.read_file(path)
    assert lib.shared_object?, "libc is ET_DYN"
    assert_equal host_libc_soname, lib.soname

    %w[printf malloc].each do |name|
      sym = lib.dynamic_symbol(name)
      refute_nil sym, "libc should export #{name}"
      assert sym.defined?, "#{name} is defined (exported) by libc"
      assert_equal :global, sym.bind
      assert_equal :func, sym.type
    end
  end

  def test_libc_soname_and_needed_match_readelf
    skip "readelf not available" unless readelf?
    path = libc_path
    skip "host libc not found" unless path && File.exist?(path)

    lib = Reader.read_file(path)
    stdout, status = Open3.capture2("readelf", "-d", path)
    assert status.success?, "readelf -d failed"

    soname = stdout[/\(SONAME\).*\[(.+?)\]/, 1]
    assert_equal soname, lib.soname
    stdout.scan(/\(NEEDED\).*\[(.+?)\]/).flatten.each do |needed|
      assert_includes lib.needed, needed
    end
  end

  def test_dynamic_symbols_presence_matches_readelf
    skip "readelf not available" unless readelf?
    path = libc_path
    skip "host libc not found" unless path && File.exist?(path)

    lib = Reader.read_file(path)
    stdout, status = Open3.capture2("readelf", "--dyn-syms", path)
    assert status.success?, "readelf --dyn-syms failed"
    # readelf renders versioned names as "printf@@GLIBC_2.2.5"; the bare name in
    # .dynstr is "printf", which is what the reader sees.
    assert(stdout.match?(/\bprintf(@@|\s)/), "sanity: readelf lists printf")
    refute_nil lib.dynamic_symbol("printf")
  end

  # --- malformed-input diagnostics ---------------------------------------

  def test_truncated_header_is_rejected
    err = assert_raises(Rubycc::ObjFile::ELFFormatError) do
      Reader.read("\x7FELF".b)
    end
    assert_match(/too short/, err.message)
  end

  def test_bad_magic_is_rejected
    bin = build_writer { |w| w.add_text_section(MAIN_CODE) }
    bin[0, 4] = "\x00\x00\x00\x00".b
    err = assert_raises(Rubycc::ObjFile::ELFFormatError) { Reader.read(bin) }
    assert_match(/magic/, err.message)
  end

  def test_32bit_class_is_rejected
    bin = build_writer { |w| w.add_text_section(MAIN_CODE) }
    bin.setbyte(Reader::EI_CLASS, 1) # ELFCLASS32
    err = assert_raises(Rubycc::ObjFile::ELFFormatError) { Reader.read(bin) }
    assert_match(/class/, err.message)
  end

  def test_truncated_body_is_rejected
    bin = build_writer do |w|
      w.add_text_section(MAIN_CODE)
      w.add_global_func("main", 0, MAIN_CODE.bytesize)
    end
    # Keep the header (so parsing begins) but cut the section header table off.
    err = assert_raises(Rubycc::ObjFile::ELFFormatError) do
      Reader.read(bin[0, 96])
    end
    assert_match(/past end of file/, err.message)
  end

  private

  def build_writer
    writer = Writer.new
    yield writer
    writer.to_binary
  end

  # Builds an object with the writer, parses it back, and returns the reader.
  def read_writer(&block)
    Reader.read(build_writer(&block))
  end

  # Compiles C with the in-repo compiler and reads the resulting object.
  def read_compiler(source)
    bin = Rubycc::Compiler.new.compile(source, filename: "foo.c")
    Reader.read(bin)
  end

  def with_object_file(bin)
    Dir.mktmpdir("rubycc-elf") do |dir|
      path = File.join(dir, "out.o")
      File.binwrite(path, bin)
      yield path
    end
  end

  def readelf?
    system("which readelf > /dev/null 2>&1")
  end

  # Parses `readelf -s`/`--syms` output into row hashes. Each data row is
  #   Num: Value Size Type Bind Vis Ndx Name
  # with Name optionally empty (section/file boundary symbols).
  def readelf_symbols(path, flag)
    stdout, status = Open3.capture2("readelf", flag, path)
    raise "readelf #{flag} failed" unless status.success?

    stdout.lines.filter_map do |line|
      m = line.match(/^\s*(\d+):\s+([0-9a-fA-F]+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+(.*?))?\s*$/)
      next unless m

      { num: m[1].to_i, type: m[4], bind: m[5], ndx: parse_ndx(m[7]), name: (m[8] || "").strip }
    end
  end

  def parse_ndx(str)
    case str
    when "UND" then Reader::SHN_UNDEF
    when "ABS" then Reader::SHN_ABS
    when "COM" then Reader::SHN_COMMON
    else Integer(str)
    end
  end
end
