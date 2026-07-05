# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"

class TestElfWriter < Minitest::Test
  # A tiny but valid "main" body: mov eax, 42; leave; ret.
  MAIN_CODE = [0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC9, 0xC3].pack("C*")

  def build_object
    writer = Rubycc::ObjFile::ELFWriter.new
    writer.add_file_symbol("foo.c")
    writer.add_text_section(MAIN_CODE)
    writer.add_global_func("main", 0, MAIN_CODE.bytesize)
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
    assert_equal 5, e_shnum     # NULL, .text, .symtab, .strtab, .shstrtab
    assert_equal 4, e_shstrndx
  end

  def test_main_symbol_in_symtab
    bin = build_object

    e_shoff = bin[40, 8].unpack1("Q<")
    e_shentsize = bin[58, 2].unpack1("S<")

    # Locate the .symtab section header (index 2) and read its layout.
    symtab_shdr = bin[e_shoff + 2 * e_shentsize, e_shentsize]
    sh_offset = symtab_shdr[24, 8].unpack1("Q<")
    sh_size = symtab_shdr[32, 8].unpack1("Q<")
    sh_link = symtab_shdr[40, 4].unpack1("L<")
    sh_info = symtab_shdr[44, 4].unpack1("L<")

    assert_equal 3, sh_link # .strtab is section index 3
    assert_equal 3, sh_info # first global symbol index (NULL, FILE, SECTION are local)

    # .strtab section header (index 3) to resolve symbol names.
    strtab_shdr = bin[e_shoff + 3 * e_shentsize, e_shentsize]
    strtab_off = strtab_shdr[24, 8].unpack1("Q<")

    entsize = 24
    symbol_count = sh_size / entsize
    assert_equal 4, symbol_count # NULL, FILE, SECTION, main

    # The last symbol is `main`.
    main_sym = bin[sh_offset + 3 * entsize, entsize]
    st_name = main_sym[0, 4].unpack1("L<")
    st_info = main_sym[4].unpack1("C")
    st_shndx = main_sym[6, 2].unpack1("S<")
    st_value = main_sym[8, 8].unpack1("Q<")
    st_size = main_sym[16, 8].unpack1("Q<")

    bind = st_info >> 4
    type = st_info & 0xF
    assert_equal 1, bind             # STB_GLOBAL
    assert_equal 2, type             # STT_FUNC
    assert_equal 1, st_shndx         # .text section index
    assert_equal 0, st_value
    assert_equal MAIN_CODE.bytesize, st_size

    name = read_c_string(bin, strtab_off + st_name)
    assert_equal "main", name
  end

  def test_readelf_can_parse_header
    Dir.mktmpdir("rubycc-elf") do |dir|
      path = File.join(dir, "out.o")
      File.binwrite(path, build_object)

      stdout, status = Open3.capture2("readelf", "-h", path)
      assert status.success?, "readelf failed to parse the object"
      assert_match(/ELF64/, stdout)
      assert_match(/REL \(Relocatable file\)/, stdout)
      assert_match(/X86-64/, stdout)
    end
  end

  private

  def read_c_string(bin, offset)
    stop = bin.index("\0", offset)
    bin[offset...stop]
  end
end
