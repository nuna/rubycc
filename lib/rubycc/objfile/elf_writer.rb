# frozen_string_literal: true

module Rubycc
  module ObjFile
    # Writes a minimal ELF64 relocatable object (ET_REL) for Linux x86_64.
    #
    # Section layout (in this order): NULL, .text, .rodata (only with string
    # literals), .data (only with initialized globals), .bss (only with
    # zero-initialized globals), .rela.text (only when there are text
    # relocations), .rela.data (only when a .data pointer slot needs one),
    # .note.GNU-stack, .symtab, .strtab, .shstrtab. Section indices are not
    # hard-coded: the ordered name list is assembled in #to_binary and a
    # name -> index lookup resolves the cross-references (symtab's sh_link,
    # rela's sh_link/sh_info, and each symbol's st_shndx). Symbol table order is
    # NULL, STT_FILE, the .text section symbol, the .rodata section symbol (when
    # present), then the file-local (`static`) functions and objects — every
    # STB_LOCAL must precede the first STB_GLOBAL — followed by the external
    # symbols (defined functions, then defined file-scope objects, then
    # undefined externals); r_info in .rela.text indexes into that final order.
    #
    # .rela.text carries four machine-independent relocation kinds — :call,
    # :string, :global and :got — each translated through the injected machine
    # description (see MachineDescription) into a concrete ELF relocation type.
    # On the default x86_64 machine that gives: each `call` site as an
    # R_X86_64_PLT32 against its (defined or undefined) symbol, each string
    # reference as an R_X86_64_PC32 against the .rodata section symbol with the
    # string's byte offset (minus 4) as its addend, each global reference as
    # an R_X86_64_PC32 against that global's own object symbol (addend -4), and
    # each PIC GOT reference (a "-fPIC" access to a symbol this unit does not
    # define) as an R_X86_64_REX_GOTPCRELX against that symbol (addend -4).
    #
    # .rela.data carries the absolute R_X86_64_64 relocations that patch a .data
    # pointer slot: one against another object's symbol (addend 0) for a "&other"
    # or a decayed global array, and one against the .rodata section symbol (the
    # string's byte offset as its addend) for a string-literal pointer.
    #
    # .data holds the initialized globals' little-endian bytes; .bss is a NOBITS
    # section that reserves space for the zero-initialized ones without occupying
    # any file bytes. Both are writable (SHF_WRITE | SHF_ALLOC).
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
      EM_AARCH64  = 183

      SHN_UNDEF = 0
      SHN_ABS = 0xFFF1

      # Section header types
      SHT_NULL     = 0
      SHT_PROGBITS = 1
      SHT_SYMTAB   = 2
      SHT_STRTAB   = 3
      SHT_RELA     = 4
      SHT_NOBITS   = 8

      # Section header flags
      SHF_WRITE     = 0x1
      SHF_ALLOC     = 0x2
      SHF_EXECINSTR = 0x4
      SHF_INFO_LINK = 0x40

      # Symbol binding/type (st_info = (bind << 4) | type)
      STB_LOCAL  = 0
      STB_GLOBAL = 1
      STT_NOTYPE  = 0
      STT_OBJECT  = 1
      STT_FUNC    = 2
      STT_SECTION = 3
      STT_FILE    = 4

      # x86_64 relocation types: 64 for an absolute 64-bit address (a pointer
      # slot in .data initialized to another object's address), PC32 for a plain
      # PC-relative reference (e.g. a "lea rip" into .rodata), PLT32 for a near
      # call (PC-relative, PLT-aware) and REX_GOTPCRELX for a PIC data access
      # (a "mov rax, sym@GOTPCREL(rip)" reading the symbol's GOT slot; the "REX"
      # form marks the REX.W-prefixed mov a linker may relax back to a lea).
      R_X86_64_64             = 1
      R_X86_64_PC32           = 2
      R_X86_64_PLT32          = 4
      R_X86_64_REX_GOTPCRELX  = 42

      # aarch64 relocation type: CALL26 patches the 26-bit immediate of a `bl`
      # (or `b`) with the PC-relative word distance to its target — the only
      # relocation the aarch64 A2 core emits (a direct call). Its addend is a
      # fixed 0: a plain `bl sym` names the target with no displacement.
      R_AARCH64_CALL26        = 283

      # Machine description: the injected, target-specific half of the writer.
      # It pairs the ELF e_machine value with a table translating each
      # machine-independent relocation `kind` (the vocabulary the backend
      # records — :call/:string/:global/:got in .text, :symbol/:rodata in .data)
      # into a per-target RelocDesc. `type` is the concrete ELF relocation type
      # (an R_<arch>_* number); `addend` is either a fixed PC-relative bias or
      # :recorded, meaning the relocation carries its own addend; `symbol` is
      # :named to resolve against the relocation's own symbol or :rodata_section
      # to resolve against the .rodata section symbol. `text_padding` is the
      # filler the compiler repeats in the alignment gap between two functions —
      # a no-op encoding of the target, so the gap disassembles cleanly and a
      # stray fall-through lands on nothing harmful. Retargeting the writer is
      # a matter of injecting a different MachineDescription — the section
      # layout and symbol-table logic below is machine-independent.
      RelocDesc = Data.define(:type, :addend, :symbol)
      MachineDescription = Data.define(:e_machine, :relocations, :text_padding)

      # Inter-function padding: x86_64's one-byte `nop` (0x90), and aarch64's
      # four-byte `nop` word 0xD503201F stored little-endian (every aarch64
      # instruction is four bytes, so the unit of padding is a whole word and
      # the 16-byte function alignment is always a whole number of them).
      X86_64_NOP  = "\x90".b
      AARCH64_NOP = [0xD503201F].pack("L<")

      # The default machine: x86_64. Its relocation table fixes the exact ELF
      # types and addend conventions the System V AMD64 psABI defines for each
      # kind (a "call rel32" and a "lea rip" both bias the rel32 field by -4,
      # while a string/data reference carries its own byte offset as the addend).
      X86_64 = MachineDescription.new(
        e_machine: EM_X86_64,
        relocations: {
          call:   RelocDesc.new(type: R_X86_64_PLT32,        addend: -4,        symbol: :named),
          string: RelocDesc.new(type: R_X86_64_PC32,         addend: :recorded, symbol: :rodata_section),
          global: RelocDesc.new(type: R_X86_64_PC32,         addend: -4,        symbol: :named),
          got:    RelocDesc.new(type: R_X86_64_REX_GOTPCRELX, addend: -4,       symbol: :named),
          symbol: RelocDesc.new(type: R_X86_64_64,           addend: :recorded, symbol: :named),
          rodata: RelocDesc.new(type: R_X86_64_64,           addend: :recorded, symbol: :rodata_section)
        }.freeze,
        text_padding: X86_64_NOP
      )

      # The aarch64 machine. The A2 code generator emits only the :call kind (a
      # `bl` site), translated to an R_AARCH64_CALL26 against the call target
      # with a fixed zero addend. Any other relocation kind reaching the writer
      # is not part of the A2 core and raises a clear KeyError from the table
      # lookup rather than being emitted with the wrong type.
      AARCH64 = MachineDescription.new(
        e_machine: EM_AARCH64,
        relocations: {
          call: RelocDesc.new(type: R_AARCH64_CALL26, addend: 0, symbol: :named)
        }.freeze,
        text_padding: AARCH64_NOP
      )

      SYM_ENTSIZE = 24
      RELA_ENTSIZE = 24
      SHDR_ENTSIZE = 64
      EHDR_SIZE = 64

      # `machine` is the injected MachineDescription selecting the target's
      # e_machine value and relocation-type table; it defaults to x86_64 so an
      # existing caller needs no change.
      def initialize(machine: X86_64)
        @machine = machine
        @text_bytes = "".b
        @rodata_bytes = nil
        @data_bytes = nil
        @data_align = 1
        @bss_size = 0
        @bss_align = 1
        @file_symbol = nil
        @func_symbols = []
        @object_symbols = []
        @undefined_symbols = []
        @relocations = []
        @data_relocations = []
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

      # Sets the .data payload (the initialized file-scope variables laid out
      # in order) and the section's alignment. The section, a writable
      # PROGBITS, is emitted only when this is set to a non-empty value.
      def set_data(bytes, align: 1)
        @data_bytes = bytes.b
        @data_align = align
        self
      end

      # Sets the .bss size in bytes (the zero-initialized file-scope variables)
      # and the section's alignment. The section, a writable NOBITS occupying
      # no file space, is emitted only when the size is positive.
      def set_bss(size, align: 1)
        @bss_size = size
        @bss_align = align
        self
      end

      def add_global_func(name, offset, size)
        @func_symbols << { name: name, offset: offset, size: size, bind: STB_GLOBAL }
        self
      end

      # Registers a defined `static` function as a file-local STT_FUNC symbol
      # (STB_LOCAL): private to this object, so a same-named function elsewhere
      # does not collide with it. Laid out in .text like any other function.
      def add_local_func(name, offset, size)
        @func_symbols << { name: name, offset: offset, size: size, bind: STB_LOCAL }
        self
      end

      # Registers a defined file-scope variable as a global STT_OBJECT symbol.
      # `section` is :data or :bss, `offset` its byte offset within that section
      # (st_value) and `size` its storage width (st_size).
      def add_global_object(name, section, offset, size)
        @object_symbols << { name: name, section: section, offset: offset, size: size, bind: STB_GLOBAL }
        self
      end

      # Registers a `static` file-scope variable (or a block-scope `static`
      # lowered to a uniquely named one) as a file-local STT_OBJECT symbol
      # (STB_LOCAL). Placed in .data/.bss exactly like a global object.
      def add_local_object(name, section, offset, size)
        @object_symbols << { name: name, section: section, offset: offset, size: size, bind: STB_LOCAL }
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

      # Records a PC-relative reference from .text to the named file-scope
      # variable `symbol` (a "lea rip" displacement addressing a global).
      # Resolved against that symbol as R_X86_64_PC32 with an addend of -4.
      def add_global_relocation(offset:, symbol:)
        @relocations << { kind: :global, offset: offset, symbol: symbol }
        self
      end

      # Records a PIC reference from .text to the named symbol's Global Offset
      # Table slot (a "mov rax, sym@GOTPCREL(rip)" that loads the symbol's
      # run-time address). `offset` is the rel32 field within .text. Resolved
      # against that symbol as R_X86_64_REX_GOTPCRELX with an addend of -4, the
      # same PC-relative bias a "lea rip" uses.
      def add_got_relocation(offset:, symbol:)
        @relocations << { kind: :got, offset: offset, symbol: symbol }
        self
      end

      # Records an absolute 64-bit reference inside .data to the named file-scope
      # object `symbol` (a pointer global initialized with "&other", a decayed
      # global array, or a computed address constant like "&arr[i]"). `offset` is
      # the pointer slot's byte offset within .data and `addend` the constant byte
      # displacement past the symbol (0 for a bare "&other"). Resolved against that
      # symbol as R_X86_64_64 with that addend.
      def add_data_relocation(offset:, symbol:, addend: 0)
        @data_relocations << { kind: :symbol, offset: offset, symbol: symbol, addend: addend }
        self
      end

      # Records an absolute 64-bit reference inside .data into .rodata (a pointer
      # global initialized with a string literal). `offset` is the pointer slot's
      # byte offset within .data and `addend` the string's byte offset within
      # .rodata. Resolved against the .rodata section symbol as R_X86_64_64.
      def add_data_rodata_relocation(offset:, addend:)
        @data_relocations << { kind: :rodata, offset: offset, addend: addend }
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
        rela_data = data_relocations? ? build_rela_data(symbol_indices, rodata_sym_index) : nil

        sections = section_layout(symtab: symtab, strtab: strtab, rela: rela, rela_data: rela_data)
        assemble(sections)
      end

      private

      def relocations?
        !@relocations.empty?
      end

      def data_relocations?
        !@data_relocations.empty?
      end

      def rodata?
        !@rodata_bytes.nil? && !@rodata_bytes.empty?
      end

      def data?
        !@data_bytes.nil? && !@data_bytes.empty?
      end

      def bss?
        @bss_size.positive?
      end

      # The ordered list of section names (nil for the anonymous NULL section);
      # .rodata/.data appear only with their data, .bss only with a positive
      # size, and .rela.text only when there is something to relocate.
      def build_section_names
        names = [nil, ".text"]
        names << ".rodata" if rodata?
        names << ".data" if data?
        names << ".bss" if bss?
        names << ".rela.text" if relocations?
        names << ".rela.data" if data_relocations?
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
        # ELF requires every STB_LOCAL symbol to precede the first STB_GLOBAL,
        # so the defined symbols are emitted in two passes: the `static`
        # (internal-linkage) functions and objects first, then the external
        # ones. Within each pass functions come before objects, keeping the
        # global-only case's original function-then-object order. sh_info
        # (#first_global_index) then lands on the first external symbol.
        [STB_LOCAL, STB_GLOBAL].each do |bind|
          @func_symbols.each do |sym|
            next unless sym[:bind] == bind

            syms << { name: sym[:name], bind: bind, type: STT_FUNC,
                      shndx: :text, value: sym[:offset], size: sym[:size] }
          end
          @object_symbols.each do |obj|
            next unless obj[:bind] == bind

            syms << { name: obj[:name], bind: bind, type: STT_OBJECT,
                      shndx: obj[:section], value: obj[:offset], size: obj[:size] }
          end
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
        @object_symbols.each { |obj| names << obj[:name] }
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

      # Builds the .rela.text payload, one entry per recorded relocation. Each
      # kind (:call/:string/:global/:got) is translated through the injected
      # machine description into its concrete ELF relocation type, addend and
      # target symbol (see #append_machine_reloc). On x86_64 that yields a
      # :call as R_X86_64_PLT32 (addend -4), a :string as R_X86_64_PC32 against
      # the .rodata section symbol (its own addend), a :global as R_X86_64_PC32
      # against that global's symbol (addend -4), and a :got as
      # R_X86_64_REX_GOTPCRELX against the symbol's GOT slot (addend -4).
      def build_rela(symbol_indices, rodata_sym_index)
        buf = +"".b
        @relocations.each { |reloc| append_machine_reloc(buf, reloc, symbol_indices, rodata_sym_index) }
        buf
      end

      # Builds the .rela.data payload, one entry per recorded data relocation.
      # Both kinds resolve through the machine description; on x86_64 they are
      # absolute R_X86_64_64 relocations. A :symbol reloc points at another
      # object's symbol with its recorded addend (the pointer slot holds that
      # object's address, plus any "&arr[i]" displacement); a :rodata reloc
      # points at the .rodata section symbol with the string's byte offset (plus
      # a cast/computed displacement) as its addend.
      def build_rela_data(symbol_indices, rodata_sym_index)
        buf = +"".b
        @data_relocations.each { |reloc| append_machine_reloc(buf, reloc, symbol_indices, rodata_sym_index) }
        buf
      end

      # Emits one Elf64_Rela entry from a machine-independent relocation record,
      # looking its kind up in the injected machine description: the concrete ELF
      # relocation type, the addend (a fixed PC-relative bias or the record's own
      # recorded addend) and the target symbol (the record's own named symbol, or
      # the .rodata section symbol for a :rodata_section descriptor).
      def append_machine_reloc(buf, reloc, symbol_indices, rodata_sym_index)
        desc = @machine.relocations.fetch(reloc[:kind])
        sym_index = desc.symbol == :rodata_section ? rodata_sym_index : symbol_indices.fetch(reloc[:symbol])
        addend = desc.addend == :recorded ? reloc[:addend] : desc.addend
        append_rela(buf, reloc[:offset], sym_index, desc.type, addend)
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
      def section_layout(symtab:, strtab:, rela:, rela_data:)
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
        if data?
          sections[".data"] = { type: SHT_PROGBITS, flags: SHF_ALLOC | SHF_WRITE, data: @data_bytes,
                                link: 0, info: 0, addralign: @data_align, entsize: 0 }
        end
        if bss?
          sections[".bss"] = { type: SHT_NOBITS, flags: SHF_ALLOC | SHF_WRITE, data: nil,
                               nobits_size: @bss_size, link: 0, info: 0,
                               addralign: @bss_align, entsize: 0 }
        end
        if rela
          sections[".rela.text"] = { type: SHT_RELA, flags: SHF_INFO_LINK,
                                     data: rela, link: :symtab, info: :text,
                                     addralign: 8, entsize: RELA_ENTSIZE }
        end
        if rela_data
          sections[".rela.data"] = { type: SHT_RELA, flags: SHF_INFO_LINK,
                                     data: rela_data, link: :symtab, info: :data,
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
          # A NOBITS section (.bss) occupies no file space: it still gets an
          # aligned sh_offset for tooling, but the running offset does not
          # advance past it.
          if sec[:type] == SHT_NOBITS
            offset = align(offset, [sec[:addralign], 1].max)
            sec[:offset] = offset
            next
          end
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
          [@machine.e_machine].pack("S<") +     # e_machine
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
          size: section_size(section),
          link: resolve_ref(section[:link]),
          info: resolve_ref(section[:info]),
          addralign: section[:addralign],
          entsize: section[:entsize]
        )
      end

      # A section's sh_size: a NOBITS section (.bss) reports its in-memory size
      # although it stores no file bytes; every other section reports the byte
      # length of its payload.
      def section_size(section)
        return section[:nobits_size] || 0 if section[:type] == SHT_NOBITS

        section[:data] ? section[:data].bytesize : 0
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
