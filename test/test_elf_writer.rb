# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"

class TestElfWriter < Minitest::Test
  # A tiny but valid "main" body: mov eax, 42; leave; ret.
  MAIN_CODE = [0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC9, 0xC3].pack("C*")

  # A body ending in "call rel32" (E8 + zero placeholder) followed by ret; the
  # rel32 field sits at offset 1 and is what a text relocation targets.
  CALL_CODE = [0xE8, 0x00, 0x00, 0x00, 0x00, 0xC3].pack("C*")
  CALL_REL32_OFFSET = 1

  # A body "lea rax, [rip + 0]" (48 8D 05 + zero placeholder) followed by ret;
  # the rel32 displacement sits at offset 3 and is what a .rodata PC32
  # relocation targets.
  LEA_CODE = [0x48, 0x8D, 0x05, 0x00, 0x00, 0x00, 0x00, 0xC3].pack("C*")
  LEA_REL32_OFFSET = 3

  # Two NUL-terminated strings, "hi" at offset 0 and "world" at offset 3.
  RODATA = "hi\0world\0".b
  WORLD_OFFSET = 3

  def build_object
    writer = Rubycc::ObjFile::ELFWriter.new
    writer.add_file_symbol("foo.c")
    writer.add_text_section(MAIN_CODE)
    writer.add_global_func("main", 0, MAIN_CODE.bytesize)
    writer.to_binary
  end

  # Builds an object whose single function calls an undefined external ("abs"),
  # producing one .rela.text entry.
  def build_object_with_relocation
    writer = Rubycc::ObjFile::ELFWriter.new
    writer.add_file_symbol("foo.c")
    writer.add_text_section(CALL_CODE)
    writer.add_global_func("main", 0, CALL_CODE.bytesize)
    writer.add_undefined_symbol("abs")
    writer.add_text_relocation(offset: CALL_REL32_OFFSET, symbol: "abs")
    writer.to_binary
  end

  # Builds an object with a .rodata string pool and one PC32 relocation from a
  # "lea rip" site into it (addressing "world", at .rodata offset 3).
  def build_object_with_rodata
    writer = Rubycc::ObjFile::ELFWriter.new
    writer.add_file_symbol("foo.c")
    writer.add_text_section(LEA_CODE)
    writer.add_global_func("main", 0, LEA_CODE.bytesize)
    writer.set_rodata(RODATA)
    writer.add_rodata_relocation(offset: LEA_REL32_OFFSET, addend: WORLD_OFFSET - 4)
    writer.to_binary
  end

  # An initialized global "base" (int 40) laid out at .data offset 0.
  DATA_BYTES = [40, 0, 0, 0].pack("C*")

  # Builds an object with a .data section holding one initialized int global
  # and its STT_OBJECT symbol.
  def build_object_with_data
    writer = Rubycc::ObjFile::ELFWriter.new
    writer.add_file_symbol("foo.c")
    writer.add_text_section(MAIN_CODE)
    writer.add_global_func("main", 0, MAIN_CODE.bytesize)
    writer.set_data(DATA_BYTES, align: 4)
    writer.add_global_object("base", :data, 0, 4)
    writer.to_binary
  end

  # Builds an object with a .bss section reserving one uninitialized int global
  # and its STT_OBJECT symbol.
  def build_object_with_bss
    writer = Rubycc::ObjFile::ELFWriter.new
    writer.add_file_symbol("foo.c")
    writer.add_text_section(MAIN_CODE)
    writer.add_global_func("main", 0, MAIN_CODE.bytesize)
    writer.set_bss(4, align: 4)
    writer.add_global_object("counter", :bss, 0, 4)
    writer.to_binary
  end

  # Builds an object whose code addresses a global "g" via a "lea rip" site,
  # producing one PC32 relocation against g's own object symbol.
  def build_object_with_global_relocation
    writer = Rubycc::ObjFile::ELFWriter.new
    writer.add_file_symbol("foo.c")
    writer.add_text_section(LEA_CODE)
    writer.add_global_func("main", 0, LEA_CODE.bytesize)
    writer.set_bss(4, align: 4)
    writer.add_global_object("g", :bss, 0, 4)
    writer.add_global_relocation(offset: LEA_REL32_OFFSET, symbol: "g")
    writer.to_binary
  end

  def test_data_section_holds_the_initializer_bytes_little_endian
    bin = build_object_with_data
    data = find_section(bin, ".data")

    refute_nil data, ".data section should be emitted"
    assert_equal 1, data[:type]              # SHT_PROGBITS
    assert_equal 0x2, data[:flags] & 0x2     # SHF_ALLOC
    assert_equal 0x1, data[:flags] & 0x1     # SHF_WRITE
    assert_equal DATA_BYTES, bin[data[:offset], data[:size]]
  end

  def test_object_without_globals_has_no_data_or_bss
    assert_nil find_section(build_object, ".data")
    assert_nil find_section(build_object, ".bss")
  end

  # A global null pointer "int *p = 0;" carries an explicit (folded) initializer
  # of 0, so, like any other explicitly initialized global, it lands in .data —
  # here as eight zero bytes (a 64-bit null address) — rather than .bss.
  def test_global_null_pointer_lands_in_data_as_eight_zero_bytes
    bin = Rubycc::Compiler.new.compile("int *p = 0; int main(void) { return 0; }", filename: "foo.c")
    data = find_section(bin, ".data")

    refute_nil data, ".data section should be emitted"
    assert_equal 8, data[:size]
    assert_equal ("\0".b * 8), bin[data[:offset], data[:size]]
  end

  def test_bss_section_is_nobits_with_a_size_but_no_file_bytes
    bin = build_object_with_bss
    bss = find_section(bin, ".bss")

    refute_nil bss, ".bss section should be emitted"
    assert_equal 8, bss[:type]               # SHT_NOBITS
    assert_equal 0x2, bss[:flags] & 0x2      # SHF_ALLOC
    assert_equal 0x1, bss[:flags] & 0x1      # SHF_WRITE
    assert_equal 4, bss[:size]               # reserves 4 bytes in memory
  end

  def test_global_object_symbol_is_a_defined_stt_object
    bin = build_object_with_bss
    symtab = find_section(bin, ".symtab")
    strtab = find_section(bin, ".strtab")
    count = symtab[:size] / 24

    index = (0...count).find do |i|
      sym = bin[symtab[:offset] + i * 24, 24]
      read_c_string(bin, strtab[:offset] + sym[0, 4].unpack1("L<")) == "counter"
    end
    refute_nil index, "counter object symbol should be present"

    sym = bin[symtab[:offset] + index * 24, 24]
    st_info = sym[4].unpack1("C")
    st_shndx = sym[6, 2].unpack1("S<")
    st_size = sym[16, 8].unpack1("Q<")

    assert_equal 1, st_info >> 4             # STB_GLOBAL
    assert_equal 1, st_info & 0xF            # STT_OBJECT
    assert_equal section_index(bin, ".bss"), st_shndx
    assert_equal 4, st_size
  end

  def test_global_relocation_is_pc32_against_the_object_symbol
    bin = build_object_with_global_relocation
    rela = find_section(bin, ".rela.text")
    refute_nil rela, ".rela.text section should be emitted"
    assert_equal 1, rela[:size] / 24

    r_offset = bin[rela[:offset], 8].unpack1("Q<")
    r_info = bin[rela[:offset] + 8, 8].unpack1("Q<")
    r_addend = bin[rela[:offset] + 16, 8].unpack1("q<")

    assert_equal LEA_REL32_OFFSET, r_offset
    assert_equal 2, r_info & 0xFFFFFFFF      # R_X86_64_PC32
    assert_equal(-4, r_addend)
    assert_equal "g", symbol_name(bin, r_info >> 32)
  end

  def test_readelf_reports_the_bss_object_symbol
    with_object_file(build_object_with_bss) do |path|
      stdout, status = Open3.capture2("readelf", "-s", path)
      assert status.success?, "readelf failed to read symbols"
      assert_match(/OBJECT\s+GLOBAL\s+\S+\s+\S*\s*counter/, stdout)
    end
  end

  def test_readelf_reports_the_bss_and_data_sections
    with_object_file(build_object_with_data) do |path|
      stdout, status = Open3.capture2("readelf", "-S", path)
      assert status.success?, "readelf failed to read sections"
      assert_match(/\.data\s+PROGBITS/, stdout)
    end
    with_object_file(build_object_with_bss) do |path|
      stdout, _status = Open3.capture2("readelf", "-S", path)
      assert_match(/\.bss\s+NOBITS/, stdout)
    end
  end

  def test_rodata_section_holds_the_concatenated_nul_terminated_strings
    bin = build_object_with_rodata
    rodata = find_section(bin, ".rodata")

    refute_nil rodata, ".rodata section should be emitted"
    assert_equal 1, rodata[:type]              # SHT_PROGBITS
    assert_equal 0x2, rodata[:flags] & 0x2     # SHF_ALLOC
    assert_equal RODATA, bin[rodata[:offset], rodata[:size]]
  end

  def test_object_without_strings_has_no_rodata
    assert_nil find_section(build_object, ".rodata")
  end

  def test_rodata_section_symbol_is_local_and_points_at_rodata
    bin = build_object_with_rodata
    symtab = find_section(bin, ".symtab")
    rodata_index = section_index(bin, ".rodata")
    count = symtab[:size] / 24

    section_syms = (0...count).select do |i|
      sym = bin[symtab[:offset] + i * 24, 24]
      st_info = sym[4].unpack1("C")
      (st_info & 0xF) == 3 && sym[6, 2].unpack1("S<") == rodata_index # STT_SECTION into .rodata
    end
    assert_equal 1, section_syms.size, "exactly one .rodata section symbol"

    sym = bin[symtab[:offset] + section_syms.first * 24, 24]
    assert_equal 0, sym[4].unpack1("C") >> 4   # STB_LOCAL
  end

  def test_rodata_relocation_is_pc32_against_the_rodata_section
    bin = build_object_with_rodata
    rela = find_section(bin, ".rela.text")
    refute_nil rela, ".rela.text section should be emitted"
    assert_equal 1, rela[:size] / 24           # the single PC32 entry

    r_offset = bin[rela[:offset], 8].unpack1("Q<")
    r_info = bin[rela[:offset] + 8, 8].unpack1("Q<")
    r_addend = bin[rela[:offset] + 16, 8].unpack1("q<")

    assert_equal LEA_REL32_OFFSET, r_offset
    assert_equal 2, r_info & 0xFFFFFFFF        # R_X86_64_PC32
    assert_equal WORLD_OFFSET - 4, r_addend    # string offset biased by -4

    sym_index = r_info >> 32
    sym = bin[find_section(bin, ".symtab")[:offset] + sym_index * 24, 24]
    assert_equal 3, sym[4].unpack1("C") & 0xF  # the target is a STT_SECTION symbol
    assert_equal section_index(bin, ".rodata"), sym[6, 2].unpack1("S<")
  end

  def test_readelf_reports_the_rodata_relocation
    with_object_file(build_object_with_rodata) do |path|
      stdout, status = Open3.capture2("readelf", "-r", path)
      assert status.success?, "readelf failed to read relocations"
      assert_match(/R_X86_64_PC32/, stdout)
      assert_match(/\.rodata/, stdout)
    end
  end

  def test_elf_magic_and_identification
    bin = build_object

    assert_equal "\x7FELF".b, bin[0, 4]
    assert_equal 2, bin[4].unpack1("C") # EI_CLASS = ELFCLASS64
    assert_equal 1, bin[5].unpack1("C") # EI_DATA = ELFDATA2LSB
    assert_equal 1, bin[6].unpack1("C") # EI_VERSION
    assert_equal 0, bin[7].unpack1("C") # EI_OSABI = System V
  end

  def test_elf_header_fields
    bin = build_object

    e_type = bin[16, 2].unpack1("S<")
    e_machine = bin[18, 2].unpack1("S<")
    e_shnum = bin[60, 2].unpack1("S<")
    e_shstrndx = bin[62, 2].unpack1("S<")

    assert_equal 1, e_type      # ET_REL
    assert_equal 62, e_machine  # EM_X86_64
    # NULL, .text, .note.GNU-stack, .symtab, .strtab, .shstrtab (no .rela.text
    # since this object has no relocations).
    assert_equal 6, e_shnum
    assert_equal 5, e_shstrndx
  end

  def test_note_gnu_stack_section_is_present
    bin = build_object
    shdr = find_section(bin, ".note.GNU-stack")

    refute_nil shdr, ".note.GNU-stack section should be emitted"
    assert_equal 1, shdr[:type]  # SHT_PROGBITS
    assert_equal 0, shdr[:flags] # not executable
    assert_equal 0, shdr[:size]
  end

  def test_object_without_calls_has_no_rela_text
    assert_nil find_section(build_object, ".rela.text")
  end

  def test_main_symbol_in_symtab
    bin = build_object

    symtab = find_section(bin, ".symtab")
    strtab = find_section(bin, ".strtab")

    assert_equal section_index(bin, ".strtab"), symtab[:link]
    assert_equal 3, symtab[:info] # first global (NULL, FILE, SECTION are local)

    entsize = 24
    symbol_count = symtab[:size] / entsize
    assert_equal 4, symbol_count # NULL, FILE, SECTION, main

    # The last symbol is `main`.
    main_sym = bin[symtab[:offset] + 3 * entsize, entsize]
    st_name = main_sym[0, 4].unpack1("L<")
    st_info = main_sym[4].unpack1("C")
    st_shndx = main_sym[6, 2].unpack1("S<")
    st_value = main_sym[8, 8].unpack1("Q<")
    st_size = main_sym[16, 8].unpack1("Q<")

    bind = st_info >> 4
    type = st_info & 0xF
    assert_equal 1, bind                        # STB_GLOBAL
    assert_equal 2, type                        # STT_FUNC
    assert_equal section_index(bin, ".text"), st_shndx
    assert_equal 0, st_value
    assert_equal MAIN_CODE.bytesize, st_size

    name = read_c_string(bin, strtab[:offset] + st_name)
    assert_equal "main", name
  end

  def test_rela_text_section_layout
    bin = build_object_with_relocation
    rela = find_section(bin, ".rela.text")

    refute_nil rela, ".rela.text section should be emitted"
    assert_equal 4, rela[:type]                            # SHT_RELA
    assert_equal 24, rela[:entsize]
    assert_equal 0x40, rela[:flags] & 0x40                 # SHF_INFO_LINK
    assert_equal section_index(bin, ".symtab"), rela[:link]
    assert_equal section_index(bin, ".text"), rela[:info]
    assert_equal 1, rela[:size] / 24                       # a single entry
  end

  def test_rela_text_entry_targets_undefined_symbol
    bin = build_object_with_relocation
    rela = find_section(bin, ".rela.text")

    r_offset = bin[rela[:offset], 8].unpack1("Q<")
    r_info = bin[rela[:offset] + 8, 8].unpack1("Q<")
    r_addend = bin[rela[:offset] + 16, 8].unpack1("q<")

    assert_equal CALL_REL32_OFFSET, r_offset
    assert_equal 4, r_info & 0xFFFFFFFF                    # R_X86_64_PLT32
    assert_equal(-4, r_addend)

    sym_index = r_info >> 32
    assert_equal "abs", symbol_name(bin, sym_index)
  end

  def test_undefined_symbol_is_global_and_undefined
    bin = build_object_with_relocation

    symtab = find_section(bin, ".symtab")
    strtab = find_section(bin, ".strtab")
    count = symtab[:size] / 24

    abs_index = (0...count).find do |i|
      sym = bin[symtab[:offset] + i * 24, 24]
      read_c_string(bin, strtab[:offset] + sym[0, 4].unpack1("L<")) == "abs"
    end
    refute_nil abs_index, "abs symbol should be present"

    sym = bin[symtab[:offset] + abs_index * 24, 24]
    st_info = sym[4].unpack1("C")
    st_shndx = sym[6, 2].unpack1("S<")

    assert_equal 1, st_info >> 4   # STB_GLOBAL
    assert_equal 0, st_info & 0xF  # STT_NOTYPE
    assert_equal 0, st_shndx       # SHN_UNDEF
  end

  def test_readelf_can_parse_header
    with_object_file(build_object) do |path|
      stdout, status = Open3.capture2("readelf", "-h", path)
      assert status.success?, "readelf failed to parse the object"
      assert_match(/ELF64/, stdout)
      assert_match(/REL \(Relocatable file\)/, stdout)
      assert_match(/X86-64/, stdout)
    end
  end

  def test_readelf_reports_the_relocation
    with_object_file(build_object_with_relocation) do |path|
      stdout, status = Open3.capture2("readelf", "-r", path)
      assert status.success?, "readelf failed to read relocations"
      assert_match(/\.rela\.text/, stdout)
      assert_match(/R_X86_64_PLT32/, stdout)
      assert_match(/abs/, stdout)
    end
  end

  private

  def with_object_file(bin)
    Dir.mktmpdir("rubycc-elf") do |dir|
      path = File.join(dir, "out.o")
      File.binwrite(path, bin)
      yield path
    end
  end

  # Parses the section header table into an array of Hashes.
  def section_headers(bin)
    e_shoff = bin[40, 8].unpack1("Q<")
    e_shentsize = bin[58, 2].unpack1("S<")
    e_shnum = bin[60, 2].unpack1("S<")
    (0...e_shnum).map do |i|
      shdr = bin[e_shoff + i * e_shentsize, e_shentsize]
      {
        name_off: shdr[0, 4].unpack1("L<"),
        type: shdr[4, 4].unpack1("L<"),
        flags: shdr[8, 8].unpack1("Q<"),
        offset: shdr[24, 8].unpack1("Q<"),
        size: shdr[32, 8].unpack1("Q<"),
        link: shdr[40, 4].unpack1("L<"),
        info: shdr[44, 4].unpack1("L<"),
        entsize: shdr[56, 8].unpack1("Q<")
      }
    end
  end

  # The offset of the .shstrtab within the file, used to resolve section names.
  def shstrtab_offset(bin)
    e_shstrndx = bin[62, 2].unpack1("S<")
    section_headers(bin)[e_shstrndx][:offset]
  end

  def find_section(bin, name)
    base = shstrtab_offset(bin)
    section_headers(bin).find do |shdr|
      read_c_string(bin, base + shdr[:name_off]) == name
    end
  end

  def section_index(bin, name)
    base = shstrtab_offset(bin)
    section_headers(bin).index do |shdr|
      read_c_string(bin, base + shdr[:name_off]) == name
    end
  end

  def symbol_name(bin, index)
    symtab = find_section(bin, ".symtab")
    strtab = find_section(bin, ".strtab")
    sym = bin[symtab[:offset] + index * 24, 24]
    read_c_string(bin, strtab[:offset] + sym[0, 4].unpack1("L<"))
  end

  def read_c_string(bin, offset)
    stop = bin.index("\0", offset)
    bin[offset...stop]
  end
end
