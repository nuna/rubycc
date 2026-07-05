# frozen_string_literal: true

module Rubycc
  module ObjFile
    # Writes a minimal ELF64 relocatable object (ET_REL) for Linux x86_64.
    #
    # Section layout (in this order): NULL, .text, .symtab, .strtab, .shstrtab.
    # Symbol table order: NULL, STT_FILE, .text section symbol, then the global
    # function symbols. There are no relocations in this slice (no external
    # references), but the symbol/section bookkeeping is kept in plain arrays so
    # a .rela.text section can be slotted in later. Output is fully deterministic
    # (N4): no timestamps or other varying data are embedded.
    class ELFWriter
      # ELF constants
      ELFCLASS64  = 2
      ELFDATA2LSB = 1
      EV_CURRENT  = 1
      ET_REL      = 1
      EM_X86_64   = 62

      SHN_ABS = 0xFFF1

      # Section header types
      SHT_NULL     = 0
      SHT_PROGBITS = 1
      SHT_SYMTAB   = 2
      SHT_STRTAB   = 3

      # Section header flags
      SHF_ALLOC     = 0x2
      SHF_EXECINSTR = 0x4

      # Symbol binding/type (st_info = (bind << 4) | type)
      STB_LOCAL  = 0
      STB_GLOBAL = 1
      STT_NOTYPE  = 0
      STT_FUNC    = 2
      STT_SECTION = 3
      STT_FILE    = 4

      SYM_ENTSIZE = 24
      SHDR_ENTSIZE = 64
      EHDR_SIZE = 64

      # Fixed section indices for this slice.
      SHNDX_TEXT     = 1
      SHNDX_SYMTAB   = 2
      SHNDX_STRTAB   = 3
      SHNDX_SHSTRTAB = 4
      SECTION_COUNT  = 5

      def initialize
        @text_bytes = "".b
        @file_symbol = nil
        @func_symbols = []
      end

      def add_text_section(bytes)
        @text_bytes = bytes.b
        self
      end

      def add_global_func(name, offset, size)
        @func_symbols << { name: name, offset: offset, size: size }
        self
      end

      def add_file_symbol(filename)
        @file_symbol = filename
        self
      end

      # Assembles and returns the ELF object as an ASCII-8BIT String.
      def to_binary
        strtab, sym_name_offsets = build_strtab
        shstrtab, sec_name_offsets = build_shstrtab
        symtab = build_symtab(sym_name_offsets)

        # File layout: [ehdr][.text][.symtab][.strtab][.shstrtab][section headers]
        text_off = EHDR_SIZE # 64 is already 16-aligned
        symtab_off = align(text_off + @text_bytes.bytesize, 8)
        strtab_off = symtab_off + symtab.bytesize
        shstrtab_off = strtab_off + strtab.bytesize
        shoff = align(shstrtab_off + shstrtab.bytesize, 8)

        out = +"".b
        out << build_ehdr(shoff)
        pad_to(out, text_off)
        out << @text_bytes
        pad_to(out, symtab_off)
        out << symtab
        pad_to(out, strtab_off)
        out << strtab
        pad_to(out, shstrtab_off)
        out << shstrtab
        pad_to(out, shoff)
        out << build_section_headers(
          sec_name_offsets,
          text_off: text_off,
          symtab_off: symtab_off, symtab_size: symtab.bytesize,
          strtab_off: strtab_off, strtab_size: strtab.bytesize,
          shstrtab_off: shstrtab_off, shstrtab_size: shstrtab.bytesize
        )
        out
      end

      private

      def build_ehdr(shoff)
        e_ident = [0x7F, 0x45, 0x4C, 0x46, ELFCLASS64, ELFDATA2LSB, EV_CURRENT,
                   0, 0, 0, 0, 0, 0, 0, 0, 0].pack("C16")
        e_ident +
          [ET_REL].pack("S<") +          # e_type
          [EM_X86_64].pack("S<") +       # e_machine
          [EV_CURRENT].pack("L<") +      # e_version
          [0].pack("Q<") +               # e_entry
          [0].pack("Q<") +               # e_phoff
          [shoff].pack("Q<") +           # e_shoff
          [0].pack("L<") +               # e_flags
          [EHDR_SIZE].pack("S<") +       # e_ehsize
          [0].pack("S<") +               # e_phentsize
          [0].pack("S<") +               # e_phnum
          [SHDR_ENTSIZE].pack("S<") +    # e_shentsize
          [SECTION_COUNT].pack("S<") +   # e_shnum
          [SHNDX_SHSTRTAB].pack("S<")    # e_shstrndx
      end

      # Builds the .strtab (symbol names). Returns [bytes, name->offset map].
      def build_strtab
        buf = +"\0".b
        offsets = {}
        names = []
        names << @file_symbol if @file_symbol
        @func_symbols.each { |sym| names << sym[:name] }
        names.uniq.each do |name|
          offsets[name] = buf.bytesize
          buf << name.b << "\0".b
        end
        [buf, offsets]
      end

      # Builds the .shstrtab (section names). Returns [bytes, name->offset map].
      def build_shstrtab
        buf = +"\0".b
        offsets = {}
        %w[.text .symtab .strtab .shstrtab].each do |name|
          offsets[name] = buf.bytesize
          buf << name.b << "\0".b
        end
        [buf, offsets]
      end

      def build_symtab(sym_name_offsets)
        buf = +"".b
        # 0: NULL symbol
        buf << sym_entry(name: 0, info: 0, other: 0, shndx: 0, value: 0, size: 0)
        # 1: STT_FILE
        if @file_symbol
          buf << sym_entry(
            name: sym_name_offsets[@file_symbol],
            info: (STB_LOCAL << 4) | STT_FILE,
            other: 0, shndx: SHN_ABS, value: 0, size: 0
          )
        end
        # 2: .text section symbol
        buf << sym_entry(
          name: 0,
          info: (STB_LOCAL << 4) | STT_SECTION,
          other: 0, shndx: SHNDX_TEXT, value: 0, size: 0
        )
        # 3..: global function symbols
        @func_symbols.each do |sym|
          buf << sym_entry(
            name: sym_name_offsets[sym[:name]],
            info: (STB_GLOBAL << 4) | STT_FUNC,
            other: 0, shndx: SHNDX_TEXT, value: sym[:offset], size: sym[:size]
          )
        end
        buf
      end

      # Number of leading local symbols; equals index of the first global.
      def local_symbol_count
        count = 1 # NULL
        count += 1 if @file_symbol
        count += 1 # .text section symbol
        count
      end

      def sym_entry(name:, info:, other:, shndx:, value:, size:)
        [name].pack("L<") +
          [info].pack("C") +
          [other].pack("C") +
          [shndx].pack("S<") +
          [value].pack("Q<") +
          [size].pack("Q<")
      end

      def build_section_headers(sec_name_offsets, text_off:, symtab_off:,
                                symtab_size:, strtab_off:, strtab_size:,
                                shstrtab_off:, shstrtab_size:)
        buf = +"".b
        # 0: NULL
        buf << shdr(name: 0, type: SHT_NULL, flags: 0, addr: 0, offset: 0,
                    size: 0, link: 0, info: 0, addralign: 0, entsize: 0)
        # 1: .text
        buf << shdr(name: sec_name_offsets[".text"], type: SHT_PROGBITS,
                    flags: SHF_ALLOC | SHF_EXECINSTR, addr: 0, offset: text_off,
                    size: @text_bytes.bytesize, link: 0, info: 0,
                    addralign: 16, entsize: 0)
        # 2: .symtab
        buf << shdr(name: sec_name_offsets[".symtab"], type: SHT_SYMTAB,
                    flags: 0, addr: 0, offset: symtab_off, size: symtab_size,
                    link: SHNDX_STRTAB, info: local_symbol_count,
                    addralign: 8, entsize: SYM_ENTSIZE)
        # 3: .strtab
        buf << shdr(name: sec_name_offsets[".strtab"], type: SHT_STRTAB,
                    flags: 0, addr: 0, offset: strtab_off, size: strtab_size,
                    link: 0, info: 0, addralign: 1, entsize: 0)
        # 4: .shstrtab
        buf << shdr(name: sec_name_offsets[".shstrtab"], type: SHT_STRTAB,
                    flags: 0, addr: 0, offset: shstrtab_off, size: shstrtab_size,
                    link: 0, info: 0, addralign: 1, entsize: 0)
        buf
      end

      def shdr(name:, type:, flags:, addr:, offset:, size:, link:, info:,
               addralign:, entsize:)
        [name].pack("L<") +
          [type].pack("L<") +
          [flags].pack("Q<") +
          [addr].pack("Q<") +
          [offset].pack("Q<") +
          [size].pack("Q<") +
          [link].pack("L<") +
          [info].pack("L<") +
          [addralign].pack("Q<") +
          [entsize].pack("Q<")
      end

      def align(value, alignment)
        (value + alignment - 1) / alignment * alignment
      end

      def pad_to(buffer, target_offset)
        buffer << ("\0" * (target_offset - buffer.bytesize)).b if buffer.bytesize < target_offset
      end
    end
  end
end
