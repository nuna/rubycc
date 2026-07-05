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
