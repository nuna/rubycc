# frozen_string_literal: true

module Rubycc
  module ObjFile
    # Writes a minimal ELF64 relocatable object (ET_REL) for Linux x86_64.
    #
    # Section layout (in this order): NULL, .text, .rodata (only when there are
    # string literals), .rela.text (only when there are relocations),
    # .note.GNU-stack, .symtab, .strtab, .shstrtab. Section indices are not
    # hard-coded: the ordered name list is assembled in #to_binary and a
    # name -> index lookup resolves the cross-references (symtab's sh_link,
    # rela's sh_link/sh_info, and each symbol's st_shndx). Symbol table order is
    # NULL, STT_FILE, the .text section symbol, the .rodata section symbol (when
    # present), then the global symbols (defined functions followed by undefined
    # externals); r_info in .rela.text indexes into that final order.
    #
    # .rela.text carries two relocation kinds: each `call` site as an
    # R_X86_64_PLT32 against its (defined or undefined) symbol, and each string
    # reference as an R_X86_64_PC32 against the .rodata section symbol with the
    # string's byte offset (minus 4) as its addend.
    #
    # The empty .note.GNU-stack marks the stack as non-executable so the linker
    # does not warn about a missing GNU_STACK note. Output is fully
    # deterministic (N4): no timestamps or other varying data are embedded.
    class ELFWriter
      # ELF constants
      ELFCLASS64  = 2
      ELFDATA2LSB = 1
      EV_CURRENT  = 1
      ET_REL      = 1
      EM_X86_64   = 62

      SHN_UNDEF = 0
      SHN_ABS = 0xFFF1

      # Section header types
      SHT_NULL     = 0
      SHT_PROGBITS = 1
      SHT_SYMTAB   = 2
      SHT_STRTAB   = 3
      SHT_RELA     = 4

      # Section header flags
      SHF_ALLOC     = 0x2
      SHF_EXECINSTR = 0x4
      SHF_INFO_LINK = 0x40

      # Symbol binding/type (st_info = (bind << 4) | type)
      STB_LOCAL  = 0
      STB_GLOBAL = 1
      STT_NOTYPE  = 0
      STT_FUNC    = 2
      STT_SECTION = 3
      STT_FILE    = 4

      # x86_64 relocation types: PC32 for a plain PC-relative reference (e.g. a
      # "lea rip" into .rodata) and PLT32 for a near call (PC-relative,
      # PLT-aware).
      R_X86_64_PC32  = 2
      R_X86_64_PLT32 = 4

      SYM_ENTSIZE = 24
      RELA_ENTSIZE = 24
      SHDR_ENTSIZE = 64
      EHDR_SIZE = 64

      def initialize
        @text_bytes = "".b
        @rodata_bytes = nil
        @file_symbol = nil
        @func_symbols = []
        @undefined_symbols = []
        @relocations = []
      end

      def add_text_section(bytes)
        @text_bytes = bytes.b
        self
      end

      # Sets the .rodata payload (the NUL-terminated, concatenated string pool).
      # The section, and its section symbol, are emitted only when this is set
      # to a non-empty value.
      def set_rodata(bytes)
        @rodata_bytes = bytes.b
        self
      end

      def add_global_func(name, offset, size)
        @func_symbols << { name: name, offset: offset, size: size }
        self
      end

      # Registers an external symbol (a call target defined elsewhere). Repeated
      # names collapse to a single symbol so several call sites share one entry.
      def add_undefined_symbol(name)
        @undefined_symbols << name unless @undefined_symbols.include?(name)
        self
      end

      def add_text_relocation(offset:, symbol:)
        @relocations << { kind: :call, offset: offset, symbol: symbol }
        self
      end

      # Records a PC-relative reference from .text into .rodata: `offset` is the
      # rel32 field within .text and `addend` is the string's .rodata byte
      # offset minus 4. Resolved against the .rodata section symbol as
      # R_X86_64_PC32.
      def add_rodata_relocation(offset:, addend:)
        @relocations << { kind: :string, offset: offset, addend: addend }
        self
      end

      def add_file_symbol(filename)
        @file_symbol = filename
        self
      end

      # Assembles and returns the ELF object as an ASCII-8BIT String.
      def to_binary
        @symbols = build_symbol_list
        @section_names = build_section_names
        symbol_indices = index_symbols_by_name(@symbols)
        rodata_sym_index = @symbols.index { |sym| sym[:type] == STT_SECTION && sym[:shndx] == :rodata }

        strtab, sym_name_offsets = build_strtab
        symtab = build_symtab(@symbols, sym_name_offsets)
        rela = relocations? ? build_rela(symbol_indices, rodata_sym_index) : nil

        sections = section_layout(symtab: symtab, strtab: strtab, rela: rela)
        assemble(sections)
      end

      private

      def relocations?
        !@relocations.empty?
      end

      def rodata?
        !@rodata_bytes.nil? && !@rodata_bytes.empty?
      end

      # The ordered list of section names (nil for the anonymous NULL section);
      # .rodata appears only with string data, and .rela.text only when there
      # is something to relocate.
      def build_section_names
        names = [nil, ".text"]
        names << ".rodata" if rodata?
        names << ".rela.text" if relocations?
        names.concat([".note.GNU-stack", ".symtab", ".strtab", ".shstrtab"])
      end

      # Resolves a section reference to its index: a Symbol like :text maps to
      # ".text", otherwise the argument is treated as a literal name.
      def section_index(ref)
        name = ref.is_a?(Symbol) ? ".#{ref}" : ref
        @section_names.index(name) or raise "unknown section: #{ref.inspect}"
      end

      # Ordered descriptors for every symbol table entry. Each is a Hash whose
      # :shndx may be the symbol :text (resolved to the .text index at emit
      # time) or a literal section index / SHN_* value.
      def build_symbol_list
        syms = []
        syms << { name: nil, bind: STB_LOCAL, type: STT_NOTYPE, shndx: 0, value: 0, size: 0 }
        if @file_symbol
          syms << { name: @file_symbol, bind: STB_LOCAL, type: STT_FILE,
                    shndx: SHN_ABS, value: 0, size: 0 }
        end
        syms << { name: nil, bind: STB_LOCAL, type: STT_SECTION,
                  shndx: :text, value: 0, size: 0 }
        if rodata?
          syms << { name: nil, bind: STB_LOCAL, type: STT_SECTION,
                    shndx: :rodata, value: 0, size: 0 }
        end
        @func_symbols.each do |sym|
          syms << { name: sym[:name], bind: STB_GLOBAL, type: STT_FUNC,
                    shndx: :text, value: sym[:offset], size: sym[:size] }
        end
        @undefined_symbols.each do |name|
          syms << { name: name, bind: STB_GLOBAL, type: STT_NOTYPE,
                    shndx: SHN_UNDEF, value: 0, size: 0 }
        end
        syms
      end

      # name -> symtab index for every named symbol, so a relocation can point
      # at either a defined function or an undefined external.
      def index_symbols_by_name(symbols)
        indices = {}
        symbols.each_with_index { |sym, i| indices[sym[:name]] = i if sym[:name] }
        indices
      end

      # Index of the first global symbol (= number of leading local symbols),
      # reported as .symtab's sh_info.
      def first_global_index(symbols)
        symbols.index { |sym| sym[:bind] == STB_GLOBAL } || symbols.size
      end

      # Builds the .strtab (symbol names). Returns [bytes, name->offset map].
      def build_strtab
        buf = +"\0".b
        offsets = {}
        names = []
        names << @file_symbol if @file_symbol
        @func_symbols.each { |sym| names << sym[:name] }
        names.concat(@undefined_symbols)
        names.uniq.each do |name|
          offsets[name] = buf.bytesize
          buf << name.b << "\0".b
        end
        [buf, offsets]
      end

      def build_symtab(symbols, sym_name_offsets)
        buf = +"".b
        symbols.each do |sym|
          buf << sym_entry(
            name: sym[:name] ? sym_name_offsets[sym[:name]] : 0,
            info: (sym[:bind] << 4) | sym[:type],
            other: 0,
            shndx: sym[:shndx].is_a?(Symbol) ? section_index(sym[:shndx]) : sym[:shndx],
            value: sym[:value],
            size: sym[:size]
          )
        end
        buf
      end

      # Builds the .rela.text payload, one entry per recorded relocation. A
      # :call points at its symbol with R_X86_64_PLT32 and an addend of -4 (the
      # PC-relative bias for a "call rel32"); a :string points at the .rodata
      # section symbol with R_X86_64_PC32 and the relocation's own addend (the
      # string's .rodata offset minus 4).
      def build_rela(symbol_indices, rodata_sym_index)
        buf = +"".b
        @relocations.each do |reloc|
          case reloc[:kind]
          when :call
            append_rela(buf, reloc[:offset], symbol_indices.fetch(reloc[:symbol]), R_X86_64_PLT32, -4)
          when :string
            append_rela(buf, reloc[:offset], rodata_sym_index, R_X86_64_PC32, reloc[:addend])
          end
        end
        buf
      end

      # Appends a single 24-byte Elf64_Rela entry (r_offset, r_info, r_addend).
      def append_rela(buf, offset, sym_index, type, addend)
        r_info = (sym_index << 32) | type
        buf << [offset].pack("Q<")
        buf << [r_info].pack("Q<")
        buf << [addend].pack("q<")
      end

      # Ordered section descriptors, matching @section_names. sh_link/sh_info
      # are held as section references (:symtab, :strtab, :text) and resolved
      # once every section index is fixed.
      def section_layout(symtab:, strtab:, rela:)
        sections = {}
        sections[nil] = { type: SHT_NULL, flags: 0, data: nil,
                          link: 0, info: 0, addralign: 0, entsize: 0 }
        sections[".text"] = { type: SHT_PROGBITS, flags: SHF_ALLOC | SHF_EXECINSTR,
                              data: @text_bytes, link: 0, info: 0,
                              addralign: 16, entsize: 0 }
        if rodata?
          sections[".rodata"] = { type: SHT_PROGBITS, flags: SHF_ALLOC, data: @rodata_bytes,
                                  link: 0, info: 0, addralign: 8, entsize: 0 }
        end
        if rela
          sections[".rela.text"] = { type: SHT_RELA, flags: SHF_INFO_LINK,
                                     data: rela, link: :symtab, info: :text,
                                     addralign: 8, entsize: RELA_ENTSIZE }
        end
        sections[".note.GNU-stack"] = { type: SHT_PROGBITS, flags: 0, data: "".b,
                                        link: 0, info: 0, addralign: 1, entsize: 0 }
        sections[".symtab"] = { type: SHT_SYMTAB, flags: 0, data: symtab,
                                link: :strtab, info: first_global_index(@symbols),
                                addralign: 8, entsize: SYM_ENTSIZE }
        sections[".strtab"] = { type: SHT_STRTAB, flags: 0, data: strtab,
                                link: 0, info: 0, addralign: 1, entsize: 0 }
        sections[".shstrtab"] = { type: SHT_STRTAB, flags: 0, data: nil,
                                  link: 0, info: 0, addralign: 1, entsize: 0 }
        @section_names.map { |name| sections.fetch(name).merge(name: name) }
      end

      # Computes file offsets, fills in the .shstrtab, and concatenates
      # everything (header, section payloads, section header table).
      def assemble(sections)
        shstrtab, sec_name_offsets = build_shstrtab
        sections.each { |sec| sec[:data] = shstrtab if sec[:name] == ".shstrtab" }

        offset = EHDR_SIZE
        sections.each do |sec|
          next if sec[:data].nil?

          offset = align(offset, [sec[:addralign], 1].max)
          sec[:offset] = offset
          offset += sec[:data].bytesize
        end
        shoff = align(offset, 8)

        out = +"".b
        out << build_ehdr(shoff)
        sections.each do |sec|
          next if sec[:data].nil?

          pad_to(out, sec[:offset])
          out << sec[:data]
        end
        pad_to(out, shoff)
        sections.each { |sec| out << build_shdr(sec, sec_name_offsets) }
        out
      end

      def build_ehdr(shoff)
        e_ident = [0x7F, 0x45, 0x4C, 0x46, ELFCLASS64, ELFDATA2LSB, EV_CURRENT,
                   0, 0, 0, 0, 0, 0, 0, 0, 0].pack("C16")
        e_ident +
          [ET_REL].pack("S<") +                 # e_type
          [EM_X86_64].pack("S<") +              # e_machine
          [EV_CURRENT].pack("L<") +             # e_version
          [0].pack("Q<") +                      # e_entry
          [0].pack("Q<") +                      # e_phoff
          [shoff].pack("Q<") +                  # e_shoff
          [0].pack("L<") +                      # e_flags
          [EHDR_SIZE].pack("S<") +              # e_ehsize
          [0].pack("S<") +                      # e_phentsize
          [0].pack("S<") +                      # e_phnum
          [SHDR_ENTSIZE].pack("S<") +           # e_shentsize
          [@section_names.size].pack("S<") +    # e_shnum
          [section_index(".shstrtab")].pack("S<") # e_shstrndx
      end

      # Builds the .shstrtab (section names). Returns [bytes, name->offset map].
      def build_shstrtab
        buf = +"\0".b
        offsets = {}
        @section_names.each do |name|
          next if name.nil? || offsets.key?(name)

          offsets[name] = buf.bytesize
          buf << name.b << "\0".b
        end
        [buf, offsets]
      end

      def sym_entry(name:, info:, other:, shndx:, value:, size:)
        [name].pack("L<") +
          [info].pack("C") +
          [other].pack("C") +
          [shndx].pack("S<") +
          [value].pack("Q<") +
          [size].pack("Q<")
      end

      def build_shdr(section, sec_name_offsets)
        shdr(
          name: section[:name] ? sec_name_offsets[section[:name]] : 0,
          type: section[:type],
          flags: section[:flags],
          addr: 0,
          offset: section[:offset] || 0,
          size: section[:data] ? section[:data].bytesize : 0,
          link: resolve_ref(section[:link]),
          info: resolve_ref(section[:info]),
          addralign: section[:addralign],
          entsize: section[:entsize]
        )
      end

      # A section's sh_link/sh_info is either a literal integer or a symbolic
      # section reference (:symtab, :strtab, :text) resolved to an index.
      def resolve_ref(value)
        value.is_a?(Symbol) ? section_index(value) : value
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
