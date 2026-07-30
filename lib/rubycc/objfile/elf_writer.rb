# frozen_string_literal: true

require "set"

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
    # .rela.text carries five machine-independent relocation kinds — :call,
    # :func, :string, :global and :got — each translated through the injected
    # machine description (see MachineDescription) into one or more concrete ELF
    # relocation entries. On the default x86_64 machine each kind costs exactly
    # one entry: a `call` site as an R_X86_64_PLT32 against its (defined or
    # undefined) symbol, a taken function address the same way, a string
    # reference as an R_X86_64_PC32 against the .rodata section symbol with the
    # string's byte offset as its addend, a global reference as an
    # R_X86_64_PC32 against that global's own object symbol, and a PIC GOT
    # reference (a "-fPIC" access to a symbol this unit does not define) as an
    # R_X86_64_REX_GOTPCRELX against that symbol — all four PC-relative kinds
    # biased by -4 for the rel32 field's placement. On aarch64 an address-forming
    # kind instead costs a *pair* of entries, one per instruction of the adrp/add
    # (or adrp/ldr) sequence that machine needs; the writer emits whatever the
    # description lists.
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
      # The two array section types the runtime walks: SHT_INIT_ARRAY holds
      # pointers to the constructors it calls at startup/dlopen, SHT_FINI_ARRAY
      # the destructors it calls at exit/dlclose. Distinct types (rather than
      # PROGBITS with a magic name) because the linker groups them by type and
      # advertises each run through DT_INIT_ARRAY / DT_FINI_ARRAY.
      SHT_INIT_ARRAY = 14
      SHT_FINI_ARRAY = 15

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

      # aarch64 relocation types. CALL26 patches the 26-bit immediate of a `bl`
      # (or `b`) with the PC-relative word distance to its target. The remaining
      # four come in pairs, because aarch64 forms a symbol's address in two
      # instructions rather than one: ADR_PREL_PG_HI21 fills the 21-bit
      # page-offset immediate of an `adrp` (the distance from the referring
      # instruction's own 4 KiB page to the symbol's), and ADD_ABS_LO12_NC fills
      # the 12-bit immediate of the following `add` with the symbol's offset
      # within that page. The GOT pair is the same split applied to the symbol's
      # Global Offset Table slot: ADR_GOT_PAGE names the slot's page and
      # LD64_GOT_LO12_NC the scaled 12-bit immediate of the `ldr` reading it.
      # "NC" is "no check": the low half cannot overflow, so the linker does not
      # range-check it. The numbers were read off real `aarch64-linux-gnu-gcc`
      # output rather than transcribed.
      # ABS64 is aarch64's absolute 64-bit pointer slot, the counterpart of
      # R_X86_64_64, used in .data rather than .text.
      R_AARCH64_ABS64            = 257
      R_AARCH64_ADR_PREL_PG_HI21 = 275
      R_AARCH64_ADD_ABS_LO12_NC  = 277
      R_AARCH64_CALL26           = 283
      R_AARCH64_ADR_GOT_PAGE     = 311
      R_AARCH64_LD64_GOT_LO12_NC = 312

      # Machine description: the injected, target-specific half of the writer.
      # It pairs the ELF e_machine value with a table translating each
      # machine-independent relocation `kind` (the vocabulary the backend
      # records — :call/:func/:string/:global/:got in .text, :symbol/:rodata in
      # .data) into that target's ELF relocation entries.
      #
      # A kind maps to an *array* of RelocDesc, not a single one, because how
      # many ELF entries one source-level reference costs is a property of the
      # machine. x86_64 forms an address in a single instruction with a single
      # patched field, so every kind is a one-element array; aarch64 needs two
      # instructions (adrp + add, or adrp + ldr) with a relocation apiece, so its
      # address-forming kinds are two-element arrays. The writer simply emits
      # each descriptor in order.
      #
      # Within a descriptor: `type` is the concrete ELF relocation type (an
      # R_<arch>_* number). `addend` is either a fixed value or :recorded,
      # meaning the relocation record carries its own addend. `addend_bias` is
      # added on top of it and is where a target's field-placement convention
      # lives — x86_64's PC-relative fields are measured from the *end* of the
      # instruction, so a rel32 whose four bytes precede that end needs -4, while
      # aarch64's adrp/add pair is biased by nothing. Keeping the bias here, and
      # not in the caller, lets the compiler hand over a plain unbiased byte
      # offset in the machine-independent vocabulary. `offset_delta` is the byte
      # distance from the offset the backend recorded (always the first
      # instruction of the sequence) to the field this descriptor patches: 0 and
      # 4 for an aarch64 pair, 0 everywhere on x86_64. `symbol` is :named to
      # resolve against the relocation's own symbol or :rodata_section to resolve
      # against the .rodata section symbol.
      #
      # `text_padding` is the filler the compiler repeats in the alignment gap
      # between two functions — a no-op encoding of the target, so the gap
      # disassembles cleanly and a stray fall-through lands on nothing harmful.
      # Retargeting the writer is a matter of injecting a different
      # MachineDescription — the section layout and symbol-table logic below is
      # machine-independent.
      RelocDesc = Data.define(:type, :addend, :symbol, :addend_bias, :offset_delta) do
        def initialize(addend_bias: 0, offset_delta: 0, **rest)
          super
        end
      end
      MachineDescription = Data.define(:e_machine, :relocations, :text_padding)

      # Inter-function padding: x86_64's one-byte `nop` (0x90), and aarch64's
      # four-byte `nop` word 0xD503201F stored little-endian (every aarch64
      # instruction is four bytes, so the unit of padding is a whole word and
      # the 16-byte function alignment is always a whole number of them).
      X86_64_NOP  = "\x90".b
      AARCH64_NOP = [0xD503201F].pack("L<")

      # The default machine: x86_64. Its relocation table fixes the exact ELF
      # types and addend conventions the System V AMD64 psABI defines for each
      # kind. Every .text kind patches a rel32 field measured from the end of the
      # instruction it belongs to, hence the uniform -4 bias; a :call and a taken
      # :func address are both near PC-relative references and share PLT32. A
      # string reference carries the interned string's .rodata byte offset as its
      # recorded addend, which the same -4 then biases.
      X86_64 = MachineDescription.new(
        e_machine: EM_X86_64,
        relocations: {
          call:   [RelocDesc.new(type: R_X86_64_PLT32, addend: 0, symbol: :named, addend_bias: -4)],
          func:   [RelocDesc.new(type: R_X86_64_PLT32, addend: 0, symbol: :named, addend_bias: -4)],
          string: [RelocDesc.new(type: R_X86_64_PC32, addend: :recorded, symbol: :rodata_section,
                                 addend_bias: -4)],
          global: [RelocDesc.new(type: R_X86_64_PC32, addend: 0, symbol: :named, addend_bias: -4)],
          got:    [RelocDesc.new(type: R_X86_64_REX_GOTPCRELX, addend: 0, symbol: :named,
                                 addend_bias: -4)],
          symbol: [RelocDesc.new(type: R_X86_64_64, addend: :recorded, symbol: :named)],
          rodata: [RelocDesc.new(type: R_X86_64_64, addend: :recorded, symbol: :rodata_section)]
        }.freeze,
        text_padding: X86_64_NOP
      )

      # The aarch64 machine. A direct :call is a single `bl` and so a single
      # CALL26; every other .text kind forms an address across two instructions
      # and therefore takes two entries, the second four bytes past the first.
      #
      # :string, :global and :func all use the adrp/add pair, differing only in
      # what they resolve against — the .rodata section symbol for a string
      # (biased by the string's own byte offset, which the linker folds into the
      # page computation for both halves alike) and the named symbol otherwise.
      # :got uses the adrp/ldr pair addressing the symbol's GOT slot. None of
      # them takes a bias: aarch64's relocations name the symbol directly rather
      # than a displacement from the end of a field.
      #
      # The .data kinds (:symbol, :rodata) are absolute 64-bit pointer slots and
      # so are not machine-shaped at all beyond the type number; ABS64 is
      # aarch64's spelling of the same thing R_X86_64_64 does.
      AARCH64 = MachineDescription.new(
        e_machine: EM_AARCH64,
        relocations: {
          call:   [RelocDesc.new(type: R_AARCH64_CALL26, addend: 0, symbol: :named)],
          string: [RelocDesc.new(type: R_AARCH64_ADR_PREL_PG_HI21, addend: :recorded,
                                 symbol: :rodata_section),
                   RelocDesc.new(type: R_AARCH64_ADD_ABS_LO12_NC, addend: :recorded,
                                 symbol: :rodata_section, offset_delta: 4)],
          global: [RelocDesc.new(type: R_AARCH64_ADR_PREL_PG_HI21, addend: 0, symbol: :named),
                   RelocDesc.new(type: R_AARCH64_ADD_ABS_LO12_NC, addend: 0, symbol: :named,
                                 offset_delta: 4)],
          func:   [RelocDesc.new(type: R_AARCH64_ADR_PREL_PG_HI21, addend: 0, symbol: :named),
                   RelocDesc.new(type: R_AARCH64_ADD_ABS_LO12_NC, addend: 0, symbol: :named,
                                 offset_delta: 4)],
          got:    [RelocDesc.new(type: R_AARCH64_ADR_GOT_PAGE, addend: 0, symbol: :named),
                   RelocDesc.new(type: R_AARCH64_LD64_GOT_LO12_NC, addend: 0, symbol: :named,
                                 offset_delta: 4)],
          symbol: [RelocDesc.new(type: R_AARCH64_ABS64, addend: :recorded, symbol: :named)],
          rodata: [RelocDesc.new(type: R_AARCH64_ABS64, addend: :recorded, symbol: :rodata_section)]
        }.freeze,
        text_padding: AARCH64_NOP
      )

      # --- initializer / finalizer arrays ------------------------------------
      # An array section is a flat vector of 8-byte function pointers, each slot
      # filled in by an absolute 64-bit relocation against the function it names.
      # Its shape is fixed by the ABI and by what the linker's array pass demands
      # (SharedLinker#split_array_sections): writable and allocatable, entsize 8,
      # 8-byte aligned.
      ARRAY_ENTSIZE = 8
      ARRAY_ALIGN   = 8

      ARRAY_SECTION_BASE = { init: ".init_array", fini: ".fini_array" }.freeze
      ARRAY_SECTION_TYPE = { init: SHT_INIT_ARRAY, fini: SHT_FINI_ARRAY }.freeze
      # Constructors before destructors, so grouping the entries is deterministic
      # whatever order the caller registered them in.
      ARRAY_KIND_ORDER = %i[init fini].freeze

      # How a priority is spelled. A run-order number below the default goes into
      # its own section named "<base>.NNNNN", which is how the *linker* learns the
      # order (a priority is nowhere in the section's contents). Both numbers were
      # measured off gcc's own objects rather than assumed: priority 101 emits
      # `.init_array.00101`, so the field is zero-padded to five digits, and
      # priority 65535 emits the plain, unnumbered `.init_array`, so 65535 is the
      # default. The five digits are exactly what the linker's array_priority
      # regexp (`\.\d+`) reads back.
      DEFAULT_ARRAY_PRIORITY = 65535
      ARRAY_PRIORITY_DIGITS  = 5

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
        # Kept as an Array (in first-added order) because that order feeds the
        # symbol table's layout, and the layout must be deterministic (DESIGN
        # N4: identical input -> identical binary). @undefined_symbol_set
        # mirrors its contents purely for O(1) membership checks, so a large
        # translation unit's undefined-symbol lookups stay linear overall
        # instead of quadratic.
        @undefined_symbols = []
        @undefined_symbol_set = Set.new
        @relocations = []
        @data_relocations = []
        # Constructor/destructor registrations, in registration order (which is
        # the order their slots are laid out within a section, and so the order
        # the runtime calls them in).
        @array_entries = []
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
        unless @undefined_symbol_set.include?(name)
          @undefined_symbols << name
          @undefined_symbol_set << name
        end
        self
      end

      def add_text_relocation(offset:, symbol:)
        @relocations << { kind: :call, offset: offset, symbol: symbol }
        self
      end

      # Records a taken function address in .text (a function pointer value, as
      # opposed to a call site). x86_64 resolves it exactly as a call does, but
      # aarch64 does not — a `bl`'s CALL26 and an adrp/add address pair are
      # different sequences — so the two kinds stay distinct here and the machine
      # description decides whether they coincide.
      def add_func_relocation(offset:, symbol:)
        @relocations << { kind: :func, offset: offset, symbol: symbol }
        self
      end

      # Records a reference from .text into .rodata: `offset` is the start of the
      # referring instruction sequence within .text and `addend` the string's
      # plain byte offset within .rodata, with no target-specific bias applied —
      # the machine description supplies that (see RelocDesc#addend_bias).
      # Resolved against the .rodata section symbol.
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

      # Registers `symbol` — a function this object defines — as a constructor
      # (`kind` :init) or a destructor (`kind` :fini). It becomes one 8-byte slot
      # in the matching array section, filled by an absolute 64-bit relocation
      # against that symbol. `priority` selects the section: the default goes to
      # the plain ".init_array"/".fini_array", a lower number to its own
      # ".init_array.NNNNN". The symbol may be file-local (a `static`
      # constructor, which is the common case), since an absolute relocation
      # against a local symbol resolves within the object just as well.
      def add_array_entry(kind:, symbol:, priority: DEFAULT_ARRAY_PRIORITY)
        raise ArgumentError, "unknown array kind: #{kind.inspect}" unless ARRAY_SECTION_BASE.key?(kind)

        @array_entries << { kind: kind, priority: priority, symbol: symbol }
        self
      end

      # Assembles and returns the ELF object as an ASCII-8BIT String.
      def to_binary
        # Fixed first: the section name list, the layout and the .rela payloads
        # all read it, and they must agree on one grouping.
        @array_sections = build_array_sections
        @symbols = build_symbol_list
        @section_names = build_section_names
        symbol_indices = index_symbols_by_name(@symbols)
        rodata_sym_index = @symbols.index { |sym| sym[:type] == STT_SECTION && sym[:shndx] == :rodata }

        strtab, sym_name_offsets = build_strtab
        symtab = build_symtab(@symbols, sym_name_offsets)
        rela = relocations? ? build_rela(symbol_indices, rodata_sym_index) : nil
        rela_data = data_relocations? ? build_rela_data(symbol_indices, rodata_sym_index) : nil
        rela_arrays = @array_sections.to_h do |group|
          [group[:name], build_rela_array(group[:entries], symbol_indices, rodata_sym_index)]
        end

        sections = section_layout(symtab: symtab, strtab: strtab, rela: rela, rela_data: rela_data,
                                  rela_arrays: rela_arrays)
        assemble(sections)
      end

      private

      # The array sections to emit, one per (kind, priority) the registrations
      # used, each as { name:, kind:, entries: }. Ordered constructors first, then
      # destructors, ascending priority within each kind — the same order the
      # linker lays the run in, so reading the object's section list already shows
      # the run order. Entries keep registration (source) order within a section.
      # Empty when nothing was registered, which is what keeps a translation unit
      # without constructors byte-identical to before.
      def build_array_sections
        @array_entries
          .group_by { |entry| [entry[:kind], entry[:priority]] }
          .sort_by { |(kind, priority), _| [ARRAY_KIND_ORDER.index(kind), priority] }
          .map do |(kind, priority), entries|
            { name: array_section_name(kind, priority), kind: kind, entries: entries }
          end
      end

      # The section name a (kind, priority) pair is spelled with. See
      # DEFAULT_ARRAY_PRIORITY / ARRAY_PRIORITY_DIGITS for where the two numbers
      # in this format come from.
      def array_section_name(kind, priority)
        base = ARRAY_SECTION_BASE.fetch(kind)
        return base if priority == DEFAULT_ARRAY_PRIORITY

        "#{base}.#{format("%0#{ARRAY_PRIORITY_DIGITS}d", priority)}"
      end

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
        @array_sections.each { |group| names << group[:name] }
        names << ".rela.text" if relocations?
        names << ".rela.data" if data_relocations?
        @array_sections.each { |group| names << ".rela#{group[:name]}" }
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

      # Builds one array section's .rela payload: every slot is an absolute
      # 64-bit pointer to its function, so each reuses the machine description's
      # :symbol kind — R_X86_64_64 on x86_64, R_AARCH64_ABS64 on aarch64 — with a
      # zero addend, at the slot's byte offset within the section.
      def build_rela_array(entries, symbol_indices, rodata_sym_index)
        buf = +"".b
        entries.each_with_index do |entry, slot|
          reloc = { kind: :symbol, offset: slot * ARRAY_ENTSIZE, symbol: entry[:symbol], addend: 0 }
          append_machine_reloc(buf, reloc, symbol_indices, rodata_sym_index)
        end
        buf
      end

      # Emits the Elf64_Rela entries for one machine-independent relocation
      # record, looking its kind up in the injected machine description. A kind
      # maps to one descriptor per ELF entry the target needs — one on x86_64,
      # two for an aarch64 address-forming pair — and each yields its own
      # relocation type, offset (the recorded offset plus the descriptor's byte
      # delta into the instruction sequence), addend (a fixed value or the
      # record's own recorded one, plus the target's field-placement bias) and
      # target symbol (the record's named symbol, or the .rodata section symbol
      # for a :rodata_section descriptor).
      def append_machine_reloc(buf, reloc, symbol_indices, rodata_sym_index)
        @machine.relocations.fetch(reloc[:kind]).each do |desc|
          sym_index = desc.symbol == :rodata_section ? rodata_sym_index : symbol_indices.fetch(reloc[:symbol])
          addend = (desc.addend == :recorded ? reloc[:addend] : desc.addend) + desc.addend_bias
          append_rela(buf, reloc[:offset] + desc.offset_delta, sym_index, desc.type, addend)
        end
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
      def section_layout(symtab:, strtab:, rela:, rela_data:, rela_arrays:)
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
        # Each array section is a run of empty pointer slots (the relocations
        # supply every byte), paired with its own .rela table. Both are named by
        # literal string, since a priority-numbered name has no symbolic form.
        @array_sections.each do |group|
          name = group[:name]
          sections[name] = { type: ARRAY_SECTION_TYPE.fetch(group[:kind]),
                             flags: SHF_ALLOC | SHF_WRITE,
                             data: "\0".b * (group[:entries].size * ARRAY_ENTSIZE),
                             link: 0, info: 0, addralign: ARRAY_ALIGN, entsize: ARRAY_ENTSIZE }
          sections[".rela#{name}"] = { type: SHT_RELA, flags: SHF_INFO_LINK,
                                       data: rela_arrays.fetch(name), link: :symtab, info: name,
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

      # A section's sh_link/sh_info is either a literal integer or a section
      # reference resolved to an index — a symbolic one (:symtab, :strtab, :text)
      # or, for a priority-numbered array section, its literal name.
      def resolve_ref(value)
        value.is_a?(Integer) ? value : section_index(value)
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
