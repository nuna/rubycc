# frozen_string_literal: true

module Rubycc
  module Link
    # The final-link core that turns an ordered set of relocatable inputs into a
    # loadable ELF64 shared object (ET_DYN, a `.so`) for Linux x86_64 or aarch64.
    # It is the
    # counterpart of the `ld -r` static core: where PartialLinker merges inputs
    # into another ET_REL and only *retargets* relocations, this stage assigns
    # load-time virtual addresses, *applies* the relocations by patching bytes,
    # and synthesizes the dynamic-linking metadata a runtime loader (glibc's
    # dlopen, in particular) reads to bind and run the object.
    #
    # It handles both a self-contained object — one that calls neither libc nor
    # any other shared library — and one that imports functions and data from
    # other shared libraries. Every relocation against an internal definition is
    # resolved within this object; a relocation against an *undefined* (imported)
    # symbol is bound through the standard dynamic mechanisms: an external call
    # goes through a .plt stub whose .got.plt slot the loader fills from a
    # JUMP_SLOT relocation, and an external data reference goes through a GOT slot
    # the loader fills from a GLOB_DAT relocation. Each dependency `.so` that
    # actually supplies at least one resolved symbol is recorded as a DT_NEEDED
    # (an --as-needed-style trim); a still-undefined reference is left undefined,
    # since a shared object may legitimately be completed by the runtime scope.
    #
    # Binding is eager (BIND_NOW): DF_BIND_NOW / DF_1_NOW ask the loader to
    # resolve every JUMP_SLOT and GLOB_DAT at load time, so the .plt stub is just
    # an indirect `jmp *slot(%rip)` and the lazy-resolution trampoline (the
    # reserved .got.plt[1]/[2] and PLT[0]) is unneeded.
    #
    # Pipeline: the inputs are first merged into one ET_REL image by PartialLinker
    # (reusing its section concatenation, symbol resolution and archive pull-in),
    # then read back through ELFReader so this stage works from resolved
    # Section/Symbol/Relocation values. From there it (1) selects the exported and
    # imported dynamic symbols and resolves the imports against the dependency
    # `.so`s; (2) lays the allocatable sections into three page-aligned PT_LOAD
    # segments by permission — r-x (text + .plt), r-- (rodata + the read-only
    # dynamic tables), rw- (data + .got/.got.plt + .dynamic) — choosing
    # `p_vaddr == p_offset` for every placed section so the `p_vaddr ≡ p_offset
    # (mod page)` load constraint holds trivially; (3) builds the dynamic tables
    # (.dynsym/.dynstr, a SysV .hash, .rela.dyn, .rela.plt and .dynamic); and (4)
    # applies each relocation against the assigned addresses, filling internal GOT
    # slots (rebased with R_X86_64_RELATIVE), external GOT slots (GLOB_DAT) and
    # the .got.plt (JUMP_SLOT).
    #
    # Output is deterministic (N4): sections keep the merged object's order, the
    # dynamic symbol table follows the merged symbol order (exports then imports),
    # the hash bucket count is derived from the export count, the relocation tables
    # are ordered by slot, and no timestamp or address randomness is embedded —
    # identical inputs yield byte-identical `.so` output.
    class SharedLinker
      include ObjFile

      PAGE = 0x1000

      # ELF header encodings.
      ELFCLASS64  = 2
      ELFDATA2LSB = 1
      EV_CURRENT  = 1
      ET_DYN      = 3
      EM_X86_64   = 62
      EM_AARCH64  = 183
      EHDR_SIZE   = 64
      PHDR_SIZE   = 56
      SHDR_SIZE   = 64

      # Section header types and the section flag bits that classify a section
      # into its load segment.
      SHT_NULL     = 0
      SHT_PROGBITS = 1
      SHT_STRTAB   = 3
      SHT_RELA     = 4
      SHT_HASH     = 5
      SHT_DYNAMIC  = 6
      SHT_NOBITS   = 8
      SHT_DYNSYM   = 11

      SHF_WRITE     = 0x1
      SHF_ALLOC     = 0x2
      SHF_EXECINSTR = 0x4

      # Program header types and permission flags.
      PT_LOAD      = 1
      PT_DYNAMIC   = 2
      PT_GNU_STACK = 0x6474E551
      PF_X = 0x1
      PF_W = 0x2
      PF_R = 0x4

      # Reserved section index for an undefined symbol reference.
      SHN_UNDEF = 0

      # Symbol binding/type/visibility encodings for the .dynsym entries.
      STB = { local: 0, global: 1, weak: 2 }.freeze
      STT = { notype: 0, object: 1, func: 2, section: 3, file: 4, tls: 6, ifunc: 10 }.freeze
      STV = { default: 0, internal: 1, hidden: 2, protected: 3 }.freeze

      # x86_64 relocation types this stage applies. The GOT-relative family
      # (9/41/42) all address a symbol's GOT slot PC-relatively and are handled
      # alike. Of the *dynamic* relocations emitted, R_X86_64_RELATIVE (8) rebases
      # an absolute address (an internal GOT slot or an R_X86_64_64 initializer),
      # R_X86_64_GLOB_DAT (6) fills an external data GOT slot, and
      # R_X86_64_JUMP_SLOT (7) fills a .got.plt slot for an external function.
      R_X86_64_64            = 1
      R_X86_64_PC32          = 2
      R_X86_64_PLT32         = 4
      R_X86_64_GOTPCREL      = 9
      R_X86_64_32            = 10
      R_X86_64_32S           = 11
      R_X86_64_GOTPCRELX     = 41
      R_X86_64_REX_GOTPCRELX = 42
      R_X86_64_RELATIVE      = 8
      R_X86_64_GLOB_DAT      = 6
      R_X86_64_JUMP_SLOT     = 7
      GOT_RELOC_TYPES = [R_X86_64_GOTPCREL, R_X86_64_GOTPCRELX, R_X86_64_REX_GOTPCRELX].freeze

      # aarch64 relocation types this stage applies. AArch64 forms an address in
      # two instructions, so an address reference arrives as a *pair* of static
      # relocations the reader hands over separately: ADR_PREL_PG_HI21 patches an
      # `adrp`'s 21-bit page immediate and ADD_ABS_LO12_NC the following `add`'s
      # 12-bit within-page offset; ADR_GOT_PAGE / LD64_GOT_LO12_NC are the same
      # split addressing a symbol's GOT slot (the second an `ldr`'s scaled
      # immediate). CALL26 is a `bl`'s 26-bit branch word-displacement. ABS64 is
      # the absolute 64-bit pointer slot, aarch64's spelling of R_X86_64_64. Of
      # the *dynamic* relocations, R_AARCH64_RELATIVE rebases an absolute address
      # (a PIC image; a non-PIE executable writes it directly), GLOB_DAT fills an
      # external data GOT slot, and JUMP_SLOT fills a .got.plt slot. The numbers
      # are the ELF-for-the-Arm-64-bit-Architecture values, confirmed against real
      # aarch64-linux-gnu tool output.
      R_AARCH64_ABS64            = 257
      R_AARCH64_ADR_PREL_PG_HI21 = 275
      R_AARCH64_ADD_ABS_LO12_NC  = 277
      R_AARCH64_CALL26           = 283
      R_AARCH64_ADR_GOT_PAGE     = 311
      R_AARCH64_LD64_GOT_LO12_NC = 312
      R_AARCH64_GLOB_DAT         = 1025
      R_AARCH64_JUMP_SLOT        = 1026
      R_AARCH64_RELATIVE         = 1027
      AARCH64_GOT_RELOC_TYPES = [R_AARCH64_ADR_GOT_PAGE, R_AARCH64_LD64_GOT_LO12_NC].freeze
      AARCH64_SUPPORTED_RELOC_TYPES = [
        R_AARCH64_ABS64, R_AARCH64_ADR_PREL_PG_HI21, R_AARCH64_ADD_ABS_LO12_NC,
        R_AARCH64_CALL26, *AARCH64_GOT_RELOC_TYPES
      ].freeze

      # The maximum page size used to align load segments and stamp p_align: 4 KiB
      # on x86_64, 64 KiB on aarch64 (matching the target toolchain default, so
      # the image loads on a 64 KiB-page kernel as well as a 4 KiB one). ADRP page
      # arithmetic is always 4 KiB regardless.
      AARCH64_MAX_PAGE = 0x10000

      # Dynamic array tags emitted into .dynamic.
      DT_NULL      = 0
      DT_NEEDED    = 1
      DT_PLTRELSZ  = 2
      DT_PLTGOT    = 3
      DT_HASH      = 4
      DT_STRTAB    = 5
      DT_SYMTAB    = 6
      DT_RELA      = 7
      DT_RELASZ    = 8
      DT_RELAENT   = 9
      DT_STRSZ     = 10
      DT_SYMENT    = 11
      DT_SONAME    = 14
      DT_PLTREL    = 20
      DT_JMPREL    = 23
      DT_FLAGS     = 30
      DT_RELACOUNT = 0x6FFFFFF9
      DT_FLAGS_1   = 0x6FFFFFFB

      # Dynamic flags requesting eager binding.
      DF_BIND_NOW = 0x8
      DF_1_NOW    = 0x1

      SYM_ENTSIZE  = 24
      RELA_ENTSIZE = 24
      DYN_ENTSIZE  = 16

      # Each .plt stub is a 16-byte-aligned entry; a .got.plt reserves three
      # leading slots (spec convention: [0] = &_DYNAMIC, [1]/[2] the lazy-resolver
      # hooks left zero under BIND_NOW) before the per-function slots.
      PLT_ENTSIZE   = 16
      GOTPLT_RESERVED = 3

      class << self
        # Links `inputs` (an ordered array; each element a filesystem path, or the
        # raw bytes of an ET_REL object or an ar archive — the same shapes
        # PartialLinker accepts) into a shared object, returned as an ASCII-8BIT
        # String. `needed` lists the dependency shared libraries to resolve
        # imports against (each a `.so` filesystem path or an already-parsed
        # ELFReader); `soname` sets this object's DT_SONAME.
        def link(inputs, needed: [], soname: nil)
          new(inputs, needed: needed, soname: soname).link
        end

        # Convenience: link and write the shared object to `path`.
        def link_to(inputs, path, needed: [], soname: nil)
          File.binwrite(path, link(inputs, needed: needed, soname: soname))
        end
      end

      def initialize(inputs, needed: [], soname: nil)
        @inputs = inputs
        @needed = needed
        @soname = soname
      end

      def link
        @reader = ELFReader.read(PartialLinker.link(link_inputs))
        @em = @reader.machine
        check_machine!
        after_merge
        plan_dynamic_symbols
        scan_relocations
        resolve_imports
        place_sections
        apply_relocations
        assemble
      end

      private

      # --- subclass hooks ----------------------------------------------------
      # The final-link core is shared with the executable writer (ExecutableLinker),
      # which differs from a shared object only in a handful of decisions expressed
      # through these hooks. A shared object links its inputs as given (an
      # executable prepends a synthesized crt), needs no post-merge validation,
      # loads at virtual address 0 so p_vaddr == p_offset (an executable loads at a
      # fixed non-PIE base), rebases every internal absolute address at load time
      # through R_X86_64_RELATIVE (an executable, mapped at a fixed address, writes
      # the final address directly and needs no base relocation), places no section
      # ahead of .text (an executable places .interp), and is an entry-less ET_DYN
      # (an executable is an ET_EXEC entered at _start). Each default keeps the
      # shared-object behavior byte-for-byte.
      def link_inputs = @inputs
      def after_merge; end
      def load_base = 0

      # --- target machine ----------------------------------------------------
      # The final-link core is written for both x86_64 and aarch64: a shared
      # object and the executable writer share it. Each target-dependent decision
      # — the machine id, the segment page size, the relocation scan/apply, the
      # PLT stub bytes and the dynamic relocation type numbers — branches on this
      # flag; the whole section/symbol/table layer above it is machine-independent.
      # An aarch64 `.so` binds through R_AARCH64_RELATIVE rebasing of its internal
      # absolute addresses (internal GOT slots and ABS64 initializers) and through
      # the same eager (BIND_NOW) per-function PLT the x86_64 `.so` uses, so no
      # lazy-resolver PLT0 header is needed.

      def aarch64? = @em == EM_AARCH64
      def e_machine_id = aarch64? ? EM_AARCH64 : EM_X86_64
      def seg_align = aarch64? ? AARCH64_MAX_PAGE : PAGE

      # The set of machines this writer accepts: x86_64 and aarch64, for both the
      # shared object and the executable subclass.
      def supported_machines = [EM_X86_64, EM_AARCH64]

      def check_machine!
        return if supported_machines.include?(@em)

        raise LinkError, "linking for machine #{@em} is not supported by this linker"
      end

      # The dynamic relocation type numbers, chosen per target. x86_64 keeps its
      # own constants so its output stays byte-for-byte identical.
      def reloc_relative  = aarch64? ? R_AARCH64_RELATIVE  : R_X86_64_RELATIVE
      def reloc_glob_dat  = aarch64? ? R_AARCH64_GLOB_DAT  : R_X86_64_GLOB_DAT
      def reloc_jump_slot = aarch64? ? R_AARCH64_JUMP_SLOT : R_X86_64_JUMP_SLOT
      def reloc_abs64     = aarch64? ? R_AARCH64_ABS64     : R_X86_64_64
      def rebase_internal? = true
      def leading_sections = []
      def e_type = ET_DYN
      def e_entry = 0

      # A section placed into the image: its ELF section-header fields plus the
      # assigned load address and file offset. `data` holds the file bytes (nil
      # for a NOBITS section, which reserves memory only). `index` is its position
      # in the emitted section header table, resolved during layout.
      Placed = Struct.new(
        :name, :type, :flags, :addralign, :entsize, :size, :data,
        :vaddr, :offset, :link, :info, :index, keyword_init: true
      )

      # A dependency shared library the imports resolve against: its DT_NEEDED
      # name (its own DT_SONAME, or the base filename when it carries none) and
      # the set of symbol names it defines and exports.
      Dependency = Struct.new(:name, :provides, keyword_init: true)

      # --- dynamic symbols ---------------------------------------------------

      # Selects the symbols to export: every defined global or weak with default
      # or protected visibility, in the merged symbol table's order (deterministic).
      # A hidden/internal symbol is deliberately not exported, matching the linker
      # default that only externally visible definitions enter .dynsym.
      def plan_dynamic_symbols
        @exports = @reader.symbols.select do |sym|
          (sym.bind == :global || sym.bind == :weak) &&
            sym.defined? && !sym.name.to_s.empty? &&
            (sym.visibility == :default || sym.visibility == :protected)
        end
      end

      # --- relocation scan (sizing pass) -------------------------------------

      # Walks every relocation to size the tables before addresses are assigned:
      # it collects the ordered set of imported (undefined) symbols, the symbols
      # needing a data GOT slot (internal or external), the external functions
      # needing a .plt stub, and the counts of absolute-64 initializers (internal
      # rebased by RELATIVE, external bound by a symbolic R_X86_64_64).
      def scan_relocations
        @got_order = []     # symbols needing a data GOT slot, first-seen order
        @got_index = {}     # got key => slot index
        @plt_order = []     # external functions needing a .plt stub, first-seen
        @plt_index = {}     # function name => stub index
        @import_order = []  # imported (undefined) symbols, first-seen order
        @import_index = {}  # import name => position
        @data64_count = 0     # internal R_X86_64_64 -> RELATIVE
        @data64_dyn_count = 0 # external R_X86_64_64 -> symbolic
        allocatable_relocation_sections.each do |rs|
          rs.relocations.each { |reloc| scan_relocation(reloc) }
        end
      end

      def scan_relocation(reloc)
        return scan_relocation_aarch64(reloc) if aarch64?

        type = reloc.type
        unless supported_relocation?(type)
          raise LinkError, "unsupported relocation type #{reloc.type_name || type} in a shared object"
        end

        sym = reloc.symbol
        external = external_import?(sym)
        if external
          if [R_X86_64_PC32, R_X86_64_32, R_X86_64_32S].include?(type)
            raise LinkError, "unsupported text relocation against external symbol " \
                             "'#{sym.name}' in a shared object"
          end
          register_import(sym)
        end

        if GOT_RELOC_TYPES.include?(type)
          register_got(sym)
        elsif type == R_X86_64_PLT32
          register_plt(sym) if external
        elsif type == R_X86_64_64
          external ? (@data64_dyn_count += 1) : (@data64_count += 1)
        end
      end

      def supported_relocation?(type)
        [R_X86_64_64, R_X86_64_PC32, R_X86_64_PLT32, R_X86_64_32, R_X86_64_32S,
         *GOT_RELOC_TYPES].include?(type)
      end

      # The aarch64 sizing pass, the counterpart of #scan_relocation: it registers
      # the same import/GOT/PLT/absolute-64 sets from aarch64's relocation
      # vocabulary. A CALL26 to an external symbol needs a .plt stub; the GOT pair
      # needs a data GOT slot; an ABS64 is an absolute-64 initializer (internal
      # rebased by RELATIVE in a PIC image, external bound symbolically). An
      # adrp/add pair against an external symbol would be a text relocation a
      # dynamic image cannot satisfy, diagnosed like x86_64's external PC32.
      def scan_relocation_aarch64(reloc)
        type = reloc.type
        unless AARCH64_SUPPORTED_RELOC_TYPES.include?(type)
          raise LinkError, "unsupported relocation type #{reloc.type_name || type} in an aarch64 link"
        end

        sym = reloc.symbol
        external = external_import?(sym)
        if external && [R_AARCH64_ADR_PREL_PG_HI21, R_AARCH64_ADD_ABS_LO12_NC].include?(type)
          raise LinkError, "unsupported text relocation against external symbol " \
                           "'#{sym.name}' (build the reference through the GOT)"
        end
        register_import(sym) if external

        if AARCH64_GOT_RELOC_TYPES.include?(type)
          register_got(sym)
        elsif type == R_AARCH64_CALL26
          register_plt(sym) if external
        elsif type == R_AARCH64_ABS64
          external ? (@data64_dyn_count += 1) : (@data64_count += 1)
        end
      end

      # An imported reference: an undefined named symbol (a section symbol always
      # names a section within this object and so is never an import).
      def external_import?(sym)
        sym && sym.type != :section && sym.undefined?
      end

      def register_import(sym)
        return if @import_index.key?(sym.name)

        @import_index[sym.name] = @import_order.size
        @import_order << sym
      end

      def register_got(sym)
        key = got_key(sym)
        return if @got_index.key?(key)

        @got_index[key] = @got_order.size
        @got_order << sym
      end

      def register_plt(sym)
        return if @plt_index.key?(sym.name)

        @plt_index[sym.name] = @plt_order.size
        @plt_order << sym
      end

      # A stable key identifying the symbol a GOT slot stands for: a named symbol
      # by its name, a section reference by its section name.
      def got_key(sym)
        name = sym.name.to_s
        name.empty? ? "\0sec:#{sym.section&.name}" : "g:#{name}"
      end

      # The relocation sections whose target lands in the loaded image; a
      # relocation against a non-allocated section is not applied.
      def allocatable_relocation_sections
        @reader.relocation_sections.select { |rs| rs.target && allocatable?(rs.target) }
      end

      def allocatable?(section)
        (section.flags & SHF_ALLOC) != 0
      end

      # --- import resolution -------------------------------------------------

      # Resolves each imported symbol against the dependency `.so`s, in dependency
      # order, recording (as-needed) only the dependencies that actually supply a
      # resolved symbol as DT_NEEDED. A still-unresolved import is left undefined:
      # a shared object may be completed by the runtime scope, so this is not an
      # error.
      def resolve_imports
        @deps = build_dependencies
        used = {}
        @import_order.each do |sym|
          dep = @deps.find { |d| d.provides.key?(sym.name) }
          used[dep] = true if dep
        end
        @used_deps = @deps.select { |d| used[d] }
      end

      # Parses each dependency into a Dependency: its DT_NEEDED name and the set
      # (a name => true hash) of the global/weak symbols it defines and exports.
      def build_dependencies
        @needed.map do |entry|
          reader, name = load_dependency(entry)
          provides = {}
          reader.dynamic_symbols.each do |sym|
            next unless sym.defined? && !sym.name.to_s.empty? &&
                        (sym.bind == :global || sym.bind == :weak)

            provides[sym.name] = true
          end
          Dependency.new(name: name, provides: provides)
        end
      end

      # A dependency given either as an already-parsed ELFReader or a `.so`
      # filesystem path; its DT_NEEDED name is its DT_SONAME, falling back to the
      # base filename for a path input (a reader without a SONAME has no name).
      def load_dependency(entry)
        if entry.is_a?(ELFReader)
          soname = entry.soname or
            raise LinkError, "dependency shared object carries no DT_SONAME; pass its path instead"
          [entry, soname]
        else
          reader = ELFReader.read_file(entry)
          [reader, reader.soname || File.basename(entry)]
        end
      end

      # --- address assignment ------------------------------------------------

      # Lays the allocatable input sections and the synthesized dynamic sections
      # into three page-aligned PT_LOAD segments by permission, assigning each a
      # file offset and an equal virtual address. The r-x segment begins at file
      # offset 0 so the ELF header and program headers it contains are mapped;
      # the r-- and rw- segments each start on a fresh page. .bss (NOBITS) sits
      # last in the rw- segment, extending its memory size past its file size.
      def place_sections
        rx = leading_sections + input_sections { |s| executable?(s) } + plt_sections
        ro = dynamic_ro_sections + input_sections { |s| !executable?(s) && !writable?(s) }
        rw_files = input_sections { |s| writable?(s) && s.type != SHT_NOBITS } + writable_dynamic_sections
        bss = input_sections { |s| writable?(s) && s.type == SHT_NOBITS }

        cursor = EHDR_SIZE + phnum * PHDR_SIZE
        cursor, @rx = lay(rx, cursor)
        cursor = align(cursor, seg_align)
        cursor, @ro = lay(ro, cursor)
        cursor = align(cursor, seg_align)
        rw_start = cursor
        cursor, rw_placed = lay(rw_files, cursor)
        @file_end = cursor
        cursor, bss_placed = lay(bss, cursor)
        @rw = rw_placed + bss_placed
        @rw_start = rw_start
        @mem_end = cursor

        index_sections
        build_dynamic_contents
      end

      def executable?(section) = (section.flags & SHF_EXECINSTR) != 0
      def writable?(section) = (section.flags & SHF_WRITE) != 0

      # The allocatable input sections matching a predicate, in merged order,
      # each turned into a Placed carrying a mutable copy of its bytes so the
      # relocation pass can patch them.
      def input_sections
        @reader.sections.select { |s| allocatable?(s) && yield(s) }.map do |s|
          Placed.new(name: s.name, type: s.type, flags: s.flags, addralign: [s.addralign, 1].max,
                     entsize: s.entsize, size: s.size, data: s.type == SHT_NOBITS ? nil : s.data.b)
        end
      end

      # Assigns offsets/addresses to a run of sections starting at `cursor`, which
      # tracks the virtual/memory position (equal to the file offset for file-
      # backed sections). The segment's file offset (`offset`) may precede
      # `cursor` when the header sits in front of the first section (the r-x
      # segment). A NOBITS section advances the memory cursor like any other — its
      # bytes are simply skipped when the file is written — so the caller captures
      # the file-end cursor before laying the .bss run and reads the memory-end
      # cursor after it. Returns [end_cursor, placed].
      def lay(sections, cursor)
        placed = []
        sections.each do |sec|
          cursor = align(cursor, sec.addralign)
          # The file offset is the raw cursor; the virtual address adds the load
          # base (zero for a shared object, so vaddr == offset as before; a fixed
          # base for a non-PIE executable).
          sec.offset = cursor
          sec.vaddr = load_base + cursor
          cursor += sec.size
          placed << sec
        end
        [cursor, placed]
      end

      # Assigns the final section-header index to every placed section (NULL is 0,
      # then r-x, r--, rw- runs in placement order, then .shstrtab) and builds the
      # section-name -> index and section-name -> vaddr maps the symbol and
      # dynamic tables resolve through.
      def index_sections
        @placed = @rx + @ro + @rw
        @section_index = { nil => 0 }
        @vaddr = {}
        @placed.each_with_index do |sec, i|
          sec.index = i + 1
          @section_index[sec.name] = sec.index
          @vaddr[sec.name] = sec.vaddr
        end
        @shstrtab_index = @placed.size + 1
      end

      # The executable .plt (one stub per imported function), or none when there
      # are no external calls.
      def plt_sections
        return [] unless plt?

        [placed_generated(".plt", SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, 16, 0, @plt_order.size * PLT_ENTSIZE)]
      end

      # The synthesized read-only dynamic sections, in the order the loader
      # expects to find them addressed from .dynamic: the SysV hash, the dynamic
      # symbol table, and its string table, followed by .rela.dyn (RELATIVE /
      # GLOB_DAT / symbolic 64) and .rela.plt (JUMP_SLOT) when present.
      def dynamic_ro_sections
        secs = [
          placed_generated(".hash", SHT_HASH, SHF_ALLOC, 8, 4, hash_bytes.bytesize),
          placed_generated(".dynsym", SHT_DYNSYM, SHF_ALLOC, 8, SYM_ENTSIZE, dynsym_size),
          placed_generated(".dynstr", SHT_STRTAB, SHF_ALLOC, 1, 0, dynstr_bytes.bytesize)
        ]
        secs << placed_generated(".rela.dyn", SHT_RELA, SHF_ALLOC, 8, RELA_ENTSIZE, rela_dyn_size) if rela_dyn?
        secs << placed_generated(".rela.plt", SHT_RELA, SHF_ALLOC, 8, RELA_ENTSIZE, rela_plt_size) if plt?
        secs
      end

      # The synthesized writable dynamic sections: the data GOT (only when a data
      # GOT slot is needed), the .got.plt (only when there are external calls),
      # and the .dynamic array.
      def writable_dynamic_sections
        secs = []
        secs << placed_generated(".got", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, 8, 8, @got_order.size * 8) unless @got_order.empty?
        secs << placed_generated(".got.plt", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, 8, 8, gotplt_size) if plt?
        secs << placed_generated(".dynamic", SHT_DYNAMIC, SHF_ALLOC | SHF_WRITE, 8, DYN_ENTSIZE, dynamic_size)
        secs
      end

      def placed_generated(name, type, flags, addralign, entsize, size)
        Placed.new(name: name, type: type, flags: flags, addralign: addralign,
                   entsize: entsize, size: size, data: nil)
      end

      def plt? = !@plt_order.empty?
      def bind_now? = !@import_order.empty?

      def gotplt_size = (GOTPLT_RESERVED + @plt_order.size) * 8
      def rela_plt_count = @plt_order.size
      def rela_plt_size = rela_plt_count * RELA_ENTSIZE

      # A .rela.dyn is present when any internal address must be rebased (a GOT
      # slot or an R_X86_64_64 initializer) or any external data reference bound
      # (a GLOB_DAT slot or a symbolic R_X86_64_64).
      def rela_dyn? = rela_dyn_count.positive?
      def rela_dyn_size = rela_dyn_count * RELA_ENTSIZE
      # The GLOB_DAT entries (external data GOT slots) and symbolic-64 entries
      # (external absolute-64 initializers) are always dynamic; the RELATIVE
      # entries only exist when internal absolute addresses are rebased at load
      # time (a shared object). A non-PIE executable writes those addresses
      # directly, so it emits no RELATIVE entry.
      def rela_dyn_count = external_got_count + @data64_dyn_count + relacount
      # The number of leading RELATIVE entries in .rela.dyn (DT_RELACOUNT): the
      # internal GOT slots and internal absolute-64 initializers, which precede
      # the GLOB_DAT and symbolic entries. None when internal addresses are not
      # rebased (a non-PIE executable).
      def relacount = rebase_internal? ? (internal_got_count + @data64_count) : 0
      def internal_got_count = @got_order.count { |sym| !external_import?(sym) }
      def external_got_count = @got_order.count { |sym| external_import?(sym) }

      def dynsym_size = (@exports.size + @import_order.size + 1) * SYM_ENTSIZE
      # The dynamic array's size depends only on which tags are present, not on
      # the addresses filled in later, so it can be computed during sizing.
      def dynamic_size = dynamic_entry_count * DYN_ENTSIZE
      def dynamic_entry_count
        @used_deps.size + (@soname ? 1 : 0) + 5 +
          (rela_dyn? ? 4 : 0) + (plt? ? 4 : 0) + (bind_now? ? 2 : 0) + 1
      end

      # --- relocation application --------------------------------------------

      # Patches every allocatable target section against the assigned addresses,
      # then builds the GOT, the .plt and their dynamic relocation entries. The
      # relative entries are ordered internal GOT slots (in slot order) then the
      # absolute-64 initializers (in relocation order), for a deterministic
      # .rela.dyn.
      def apply_relocations
        @section_data = {}
        @placed.each { |sec| @section_data[sec.name] = sec.data if sec.data }
        @rela_data = []      # internal R_X86_64_64 -> [offset, addend] RELATIVE
        @rela_data_sym = []  # external R_X86_64_64 -> [offset, dynindex, addend]

        allocatable_relocation_sections.each do |rs|
          base = @vaddr[rs.target.name]
          buf = @section_data[rs.target.name]
          rs.relocations.each { |reloc| apply_relocation(reloc, base, buf) }
        end

        build_got
        build_plt if plt?
      end

      def apply_relocation(reloc, base, buf)
        return apply_relocation_aarch64(reloc, base, buf) if aarch64?

        sym = reloc.symbol
        a = reloc.addend
        p = base + reloc.offset
        external = external_import?(sym)
        case reloc.type
        when R_X86_64_PLT32
          target = external ? plt_stub_addr(sym) : symbol_address(sym)
          patch32(buf, reloc.offset, target + a - p)
        when R_X86_64_PC32
          patch32(buf, reloc.offset, symbol_address(sym) + a - p)
        when R_X86_64_32, R_X86_64_32S
          patch32(buf, reloc.offset, symbol_address(sym) + a)
        when *GOT_RELOC_TYPES
          slot = got_addr + @got_index[got_key(sym)] * 8
          patch32(buf, reloc.offset, slot + a - p)
        when R_X86_64_64
          if external
            patch64(buf, reloc.offset, 0)
            @rela_data_sym << [p, import_dynindex(sym), a]
          else
            value = symbol_address(sym) + a
            patch64(buf, reloc.offset, value)
            # A shared object rebases this absolute initializer at load time; a
            # non-PIE executable's address is already final, so no RELATIVE.
            @rela_data << [p, value] if rebase_internal?
          end
        end
      end

      # The aarch64 apply, the counterpart of #apply_relocation. Where x86_64
      # patches a plain 32/64-bit displacement, aarch64 patches an immediate
      # bit-field packed inside a fixed 32-bit instruction word, and its address
      # references span two instructions the reader delivered as two relocations:
      # a CALL26 patches a `bl` (routed through the .plt for an external target),
      # ADR_PREL_PG_HI21 the page distance of an `adrp`, ADD_ABS_LO12_NC the
      # within-page offset of the `add`, and the GOT pair the same split against a
      # GOT slot. ABS64 is the absolute-64 pointer slot: written with its final
      # value in a non-PIE executable (no RELATIVE) or bound symbolically when it
      # names an import.
      def apply_relocation_aarch64(reloc, base, buf)
        sym = reloc.symbol
        a = reloc.addend
        p = base + reloc.offset
        external = external_import?(sym)
        case reloc.type
        when R_AARCH64_CALL26
          target = external ? plt_stub_addr(sym) : symbol_address(sym)
          patch_call26(buf, reloc.offset, target + a - p)
        when R_AARCH64_ADR_PREL_PG_HI21
          patch_adrp(buf, reloc.offset, page(symbol_address(sym) + a) - page(p))
        when R_AARCH64_ADD_ABS_LO12_NC
          patch_add_lo12(buf, reloc.offset, (symbol_address(sym) + a) & 0xFFF)
        when R_AARCH64_ADR_GOT_PAGE
          patch_adrp(buf, reloc.offset, page(got_slot_addr(sym)) - page(p))
        when R_AARCH64_LD64_GOT_LO12_NC
          patch_ld64_lo12(buf, reloc.offset, got_slot_addr(sym) & 0xFFF)
        when R_AARCH64_ABS64
          if external
            patch64(buf, reloc.offset, 0)
            @rela_data_sym << [p, import_dynindex(sym), a]
          else
            value = symbol_address(sym) + a
            patch64(buf, reloc.offset, value)
            @rela_data << [p, value] if rebase_internal?
          end
        end
      end

      def got_slot_addr(sym) = got_addr + @got_index[got_key(sym)] * 8

      # The 4 KiB page a virtual address sits in — the unit `adrp` operates on,
      # independent of the (larger) load-segment alignment.
      def page(addr) = addr & ~0xFFF

      def read_insn(buf, offset) = buf[offset, 4].unpack1("L<")
      def write_insn(buf, offset, word) = (buf[offset, 4] = [word & 0xFFFFFFFF].pack("L<"))

      # Patches a `bl`/`b`'s 26-bit signed word offset (ARM DDI 0487, the
      # unconditional-branch-immediate form): the byte displacement is a multiple
      # of four, so imm26 = disp >> 2 occupies bits [25:0].
      def patch_call26(buf, offset, disp)
        imm = (disp >> 2) & 0x03FFFFFF
        write_insn(buf, offset, (read_insn(buf, offset) & ~0x03FFFFFF) | imm)
      end

      # Patches an `adrp`'s 21-bit signed page immediate. The page distance is a
      # multiple of 4 KiB, so imm21 = page_delta >> 12 splits into immlo (bits
      # [1:0], encoded at instruction bits [30:29]) and immhi (bits [20:2],
      # encoded at bits [23:5]).
      def patch_adrp(buf, offset, page_delta)
        imm = (page_delta >> 12) & 0x1FFFFF
        immlo = imm & 0x3
        immhi = (imm >> 2) & 0x7FFFF
        word = read_insn(buf, offset) & ~((0x3 << 29) | (0x7FFFF << 5))
        write_insn(buf, offset, word | (immlo << 29) | (immhi << 5))
      end

      # Patches an `add` (immediate) 12-bit unsigned field at bits [21:10] with the
      # symbol's within-page byte offset.
      def patch_add_lo12(buf, offset, value)
        imm = value & 0xFFF
        write_insn(buf, offset, (read_insn(buf, offset) & ~(0xFFF << 10)) | (imm << 10))
      end

      # Patches a 64-bit `ldr`'s 12-bit unsigned-offset field at bits [21:10]. The
      # field is the byte offset scaled by the access size (8), so the GOT slot's
      # 8-byte-aligned low offset encodes exactly as value >> 3.
      def patch_ld64_lo12(buf, offset, value)
        imm = (value >> 3) & 0xFFF
        write_insn(buf, offset, (read_insn(buf, offset) & ~(0xFFF << 10)) | (imm << 10))
      end

      # Fills the data GOT: an internal slot holds its symbol's link-time address
      # and is rebased by an R_X86_64_RELATIVE; an external slot is left zero and
      # bound by an R_X86_64_GLOB_DAT naming the imported symbol.
      def build_got
        @got_bytes = +"".b
        @rela_relative_got = []
        @rela_glob_dat = []
        @got_order.each_with_index do |sym, i|
          slot = got_addr + i * 8
          if external_import?(sym)
            @got_bytes << [0].pack("Q<")
            @rela_glob_dat << [slot, import_dynindex(sym)]
          else
            address = symbol_address(sym)
            @got_bytes << [address].pack("Q<")
            # The slot already holds its final address; a shared object still
            # rebases it with a RELATIVE, a non-PIE executable does not.
            @rela_relative_got << [slot, address] if rebase_internal?
          end
        end
      end

      # Builds the .plt stubs, the .got.plt and its JUMP_SLOT relocations. Each
      # stub is `jmp *slot(%rip)` (FF 25 + a PC-relative disp32 to its .got.plt
      # slot) padded with single-byte NOPs to the 16-byte entry; under BIND_NOW
      # the loader has already stored the resolved target in the slot, so the
      # first call jumps straight there. The .got.plt reserves three leading slots
      # ([0] = &_DYNAMIC, [1]/[2] zero) before the per-function slots.
      def build_plt
        return build_plt_aarch64 if aarch64?

        @plt_bytes = +"".b
        @gotplt_bytes = +[@vaddr[".dynamic"], 0, 0].pack("Q<Q<Q<")
        @rela_plt = []
        @plt_order.each_with_index do |sym, i|
          stub = plt_stub_addr(sym)
          slot = gotplt_slot_addr(i)
          disp = slot - (stub + 6)
          @plt_bytes << [0xFF, 0x25].pack("C2") << [disp].pack("l<")
          @plt_bytes << ([0x90] * (PLT_ENTSIZE - 6)).pack("C*")
          @gotplt_bytes << [0].pack("Q<")
          @rela_plt << [slot, import_dynindex(sym)]
        end
      end

      # The aarch64 .plt, the counterpart of #build_plt. Each 16-byte stub loads
      # its function's resolved address from the .got.plt slot and branches there;
      # under BIND_NOW the loader has already stored the JUMP_SLOT target, so the
      # first call reaches the callee directly. The four-instruction sequence
      # (ARM DDI 0487 encodings) is: `adrp x16, page(slot)`; `ldr x17, [x16,
      # #lo12]`; `add x16, x16, #lo12`; `br x17`. The .got.plt reserves three
      # leading slots ([0] = &_DYNAMIC, [1]/[2] zero) before the per-function ones.
      def build_plt_aarch64
        @plt_bytes = +"".b
        @gotplt_bytes = +[@vaddr[".dynamic"], 0, 0].pack("Q<Q<Q<")
        @rela_plt = []
        @plt_order.each_with_index do |sym, i|
          stub = plt_stub_addr(sym)
          slot = gotplt_slot_addr(i)
          @plt_bytes << aarch64_plt_stub(stub, slot)
          @gotplt_bytes << [0].pack("Q<")
          @rela_plt << [slot, import_dynindex(sym)]
        end
      end

      # The four instruction words of one aarch64 .plt stub reaching `slot` from
      # its own address `stub` (see #build_plt_aarch64).
      def aarch64_plt_stub(stub, slot)
        lo12 = slot & 0xFFF
        adrp = aarch64_adrp(16, page(slot) - page(stub))
        ldr  = aarch64_ldr64(17, 16, lo12)
        add  = aarch64_add(16, 16, lo12)
        br   = 0xD61F0000 | (17 << 5)
        [adrp, ldr, add, br].pack("L<4")
      end

      # `adrp Xd, #page_delta`: base opcode 0x90000000 with the 21-bit page
      # immediate split into immlo (bits [30:29]) and immhi (bits [23:5]).
      def aarch64_adrp(rd, page_delta)
        imm = (page_delta >> 12) & 0x1FFFFF
        0x90000000 | ((imm & 0x3) << 29) | (((imm >> 2) & 0x7FFFF) << 5) | rd
      end

      # `ldr Xt, [Xn, #byteoff]` (64-bit unsigned offset): base 0xF9400000 with the
      # scaled (byteoff / 8) 12-bit immediate at bits [21:10].
      def aarch64_ldr64(rt, rn, byteoff)
        0xF9400000 | (((byteoff >> 3) & 0xFFF) << 10) | (rn << 5) | rt
      end

      # `add Xd, Xn, #imm12`: base 0x91000000 with the 12-bit immediate at bits
      # [21:10].
      def aarch64_add(rd, rn, imm12)
        0x91000000 | ((imm12 & 0xFFF) << 10) | (rn << 5) | rd
      end

      def got_addr = @vaddr[".got"]
      def plt_stub_addr(sym) = @vaddr[".plt"] + @plt_index[sym.name] * PLT_ENTSIZE
      def gotplt_slot_addr(i) = @vaddr[".got.plt"] + (GOTPLT_RESERVED + i) * 8

      # The .dynsym index of an imported symbol: after the null entry and the
      # exported symbols.
      def import_dynindex(sym)
        @exports.size + 1 + @import_index[sym.name]
      end

      # The load-time virtual address of a relocation's symbol: a section
      # reference resolves to the section's base, an absolute symbol to its
      # value, and any other defined symbol to its section base plus its offset.
      def symbol_address(sym)
        return 0 unless sym
        return @vaddr[sym.section.name] if sym.type == :section && sym.section
        return sym.value if sym.absolute?

        @vaddr[sym.section.name] + sym.value
      end

      # --- dynamic table contents --------------------------------------------

      # Builds .dynstr and the name -> offset map, memoized so the sizing pass and
      # the emit share one table. It holds every exported and imported symbol name,
      # every recorded DT_NEEDED name and this object's DT_SONAME.
      def dynstr
        @dynstr ||= begin
          buf = +"\0".b
          offsets = {}
          dynstr_names.each do |name|
            next if name.nil? || name.empty? || offsets.key?(name)

            offsets[name] = buf.bytesize
            buf << name.b << "\0".b
          end
          [buf, offsets]
        end
      end

      def dynstr_names
        @exports.map(&:name) + @import_order.map(&:name) + @used_deps.map(&:name) + [@soname]
      end

      def dynstr_bytes = dynstr[0]
      def dynstr_offset(name) = dynstr[1].fetch(name)

      # The .dynsym payload: the reserved null entry, then one entry per exported
      # symbol carrying its load address, size, binding/type and defining section,
      # then one UND entry per imported symbol (st_shndx = SHN_UNDEF, value 0).
      def dynsym_bytes
        _, name_offsets = dynstr
        buf = +("\0".b * SYM_ENTSIZE)
        @exports.each do |sym|
          info = (STB.fetch(sym.bind, 1) << 4) | STT.fetch(sym.type, 0)
          buf << sym_entry(name: name_offsets.fetch(sym.name), info: info,
                           other: STV.fetch(sym.visibility, 0),
                           shndx: @section_index.fetch(sym.section.name),
                           value: @vaddr[sym.section.name] + sym.value, size: sym.size)
        end
        @import_order.each do |sym|
          info = (STB.fetch(sym.bind, 1) << 4) | STT.fetch(sym.type, 0)
          buf << sym_entry(name: name_offsets.fetch(sym.name), info: info,
                           other: STV.fetch(sym.visibility, 0),
                           shndx: SHN_UNDEF, value: 0, size: 0)
        end
        buf
      end

      # The SysV (.hash) table: nbucket, nchain, then the bucket heads and the
      # collision chain. Every dynamic symbol (exports and imports) occupies a
      # chain slot so nchain equals the .dynsym count, but only the exported
      # (defined) symbols are hashed into the buckets — an import is never looked
      # up here — in symbol-index order for a deterministic layout.
      def hash_bytes
        nsyms = @exports.size + @import_order.size + 1
        nbucket = bucket_count(@exports.size)
        buckets = Array.new(nbucket, SHN_UNDEF)
        chain = Array.new(nsyms, SHN_UNDEF)
        @exports.each_with_index do |sym, i|
          idx = i + 1
          b = elf_hash(sym.name) % nbucket
          chain[idx] = buckets[b]
          buckets[b] = idx
        end
        [nbucket, nsyms].pack("L<L<") + buckets.pack("L<*") + chain.pack("L<*")
      end

      # Derives the hash bucket count deterministically from the export count via
      # a fixed growth ladder, keeping average chain length near one without
      # depending on anything but the input's size (N4).
      def bucket_count(n)
        ladder = [1, 3, 7, 17, 37, 67, 127, 251, 509, 1021, 2039]
        ladder.reverse_each { |b| return b if b <= n }
        1
      end

      # The ELF gABI symbol hash (name -> unsigned 32-bit-ish value) glibc uses to
      # locate a symbol in the SysV hash table.
      def elf_hash(name)
        h = 0
        name.each_byte do |c|
          h = (h << 4) + c
          g = h & 0xF0000000
          h ^= g >> 24 if g != 0
          h &= ~g & 0xFFFFFFFF
        end
        h
      end

      # The .rela.dyn payload: the RELATIVE entries (internal GOT slots then data
      # initializers) first, so DT_RELACOUNT can cover them, then the GLOB_DAT
      # entries for external data GOT slots, then the symbolic R_X86_64_64 data
      # initializers pointing at imported data.
      def rela_dyn_bytes
        buf = +"".b
        (@rela_relative_got + @rela_data).each do |offset, addend|
          buf << rela_entry(offset, reloc_relative, 0, addend)
        end
        @rela_glob_dat.each do |offset, dynindex|
          buf << rela_entry(offset, reloc_glob_dat, dynindex, 0)
        end
        @rela_data_sym.each do |offset, dynindex, addend|
          buf << rela_entry(offset, reloc_abs64, dynindex, addend)
        end
        buf
      end

      # The .rela.plt payload: one JUMP_SLOT per external function, naming its
      # imported symbol; the loader stores the resolved address into the slot.
      def rela_plt_bytes
        buf = +"".b
        @rela_plt.each { |offset, dynindex| buf << rela_entry(offset, reloc_jump_slot, dynindex, 0) }
        buf
      end

      def rela_entry(offset, type, sym_index, addend)
        [offset, (sym_index << 32) | type].pack("Q<Q<") + [addend].pack("q<")
      end

      # The .dynamic array: the DT_NEEDED dependencies and DT_SONAME first, then
      # pointers/sizes for the hash and symbol/string tables, the .rela.dyn table
      # (with DT_RELACOUNT), the .plt relocation table (DT_PLTGOT/PLTRELSZ/
      # PLTREL/JMPREL), the BIND_NOW flags, and the DT_NULL terminator.
      def dynamic_entries
        entries = []
        @used_deps.each { |dep| entries << [DT_NEEDED, dynstr_offset(dep.name)] }
        entries << [DT_SONAME, dynstr_offset(@soname)] if @soname
        entries += [
          [DT_HASH, @vaddr[".hash"]],
          [DT_STRTAB, @vaddr[".dynstr"]],
          [DT_SYMTAB, @vaddr[".dynsym"]],
          [DT_STRSZ, dynstr_bytes.bytesize],
          [DT_SYMENT, SYM_ENTSIZE]
        ]
        if rela_dyn?
          entries += [
            [DT_RELA, @vaddr[".rela.dyn"]],
            [DT_RELASZ, rela_dyn_size],
            [DT_RELAENT, RELA_ENTSIZE],
            [DT_RELACOUNT, relacount]
          ]
        end
        if plt?
          entries += [
            [DT_PLTGOT, @vaddr[".got.plt"]],
            [DT_PLTRELSZ, rela_plt_size],
            [DT_PLTREL, DT_RELA],
            [DT_JMPREL, @vaddr[".rela.plt"]]
          ]
        end
        entries += [[DT_FLAGS, DF_BIND_NOW], [DT_FLAGS_1, DF_1_NOW]] if bind_now?
        entries << [DT_NULL, 0]
        entries
      end

      def dynamic_bytes
        buf = +"".b
        dynamic_entries.each { |tag, val| buf << [tag].pack("q<") << [val].pack("Q<") }
        buf
      end

      # Resolves the sh_link/sh_info cross-references and materializes the byte
      # payload of every synthesized section once addresses are known. Input
      # sections carry their patched bytes; NOBITS carries none.
      def build_dynamic_contents
        dynsym = named(".dynsym")
        named(".hash").link = dynsym.index
        dynsym.link = named(".dynstr").index
        dynsym.info = 1 # first non-local dynamic symbol (only the null entry is local)
        named(".dynamic").link = named(".dynstr").index
        named(".rela.dyn")&.link = dynsym.index
        rela_plt = named(".rela.plt")
        return unless rela_plt

        rela_plt.link = dynsym.index
        rela_plt.info = named(".got.plt").index # the section the JUMP_SLOTs modify
      end

      def named(name)
        @placed.find { |sec| sec.name == name }
      end

      # The bytes to emit for a placed section: patched input bytes, or the
      # freshly built payload of a synthesized one.
      def section_bytes(sec)
        case sec.name
        when ".hash"     then hash_bytes
        when ".dynsym"   then dynsym_bytes
        when ".dynstr"   then dynstr_bytes
        when ".rela.dyn" then rela_dyn_bytes
        when ".rela.plt" then rela_plt_bytes
        when ".plt"      then @plt_bytes
        when ".got"      then @got_bytes
        when ".got.plt"  then @gotplt_bytes
        when ".dynamic"  then dynamic_bytes
        else @section_data[sec.name]
        end
      end

      # --- assembly ----------------------------------------------------------

      # Concatenates the ELF header, program headers, the placed sections' file
      # bytes, .shstrtab and the section header table into the final image.
      def assemble
        shstrtab, name_offsets = build_shstrtab
        shstrtab_offset = @file_end
        shoff = align(shstrtab_offset + shstrtab.bytesize, 8)

        out = +"".b
        out << build_ehdr(shoff)
        out << build_phdrs
        @placed.each do |sec|
          next if sec.type == SHT_NOBITS

          pad_to(out, sec.offset)
          out << section_bytes(sec)
        end
        pad_to(out, shstrtab_offset)
        out << shstrtab
        pad_to(out, shoff)
        out << build_null_shdr(name_offsets)
        @placed.each { |sec| out << build_shdr(sec, name_offsets) }
        out << build_shstrtab_shdr(shstrtab_offset, shstrtab.bytesize, name_offsets)
        out
      end

      # The program header count is fixed: three PT_LOAD segments (r-x, r--,
      # rw-), PT_DYNAMIC, and PT_GNU_STACK marking a non-executable stack.
      def phnum = 5

      def build_phdrs
        rx = segment_extent(@rx, base: 0)
        ro = segment_extent(@ro, base: @ro.first.vaddr)
        dynamic = named(".dynamic")
        [
          phdr(PT_LOAD, PF_R | PF_X, 0, 0, rx[:filesz], rx[:filesz], seg_align),
          phdr(PT_LOAD, PF_R, ro[:offset], ro[:offset], ro[:filesz], ro[:filesz], seg_align),
          phdr(PT_LOAD, PF_R | PF_W, @rw_start, @rw_start,
               @file_end - @rw_start, @mem_end - @rw_start, seg_align),
          phdr(PT_DYNAMIC, PF_R | PF_W, dynamic.offset, dynamic.vaddr, dynamic.size, dynamic.size, 8),
          phdr(PT_GNU_STACK, PF_R | PF_W, 0, 0, 0, 0, 0x10)
        ].join
      end

      # The file/memory extent of a segment given its placed sections: the file
      # offset of its first section and the span from that offset to the end of
      # its last file-backed byte.
      def segment_extent(sections, base:)
        last = sections.reject { |s| s.type == SHT_NOBITS }.last
        finish = last ? last.offset + last.size : base
        { offset: sections.first.offset, filesz: finish - sections.first.offset }
      end

      def phdr(type, flags, offset, vaddr, filesz, memsz, align)
        [type].pack("L<") + [flags].pack("L<") + [offset].pack("Q<") +
          [vaddr].pack("Q<") + [0].pack("Q<") + [filesz].pack("Q<") +
          [memsz].pack("Q<") + [align].pack("Q<")
      end

      def build_ehdr(shoff)
        e_ident = [0x7F, 0x45, 0x4C, 0x46, ELFCLASS64, ELFDATA2LSB, EV_CURRENT,
                   0, 0, 0, 0, 0, 0, 0, 0, 0].pack("C16")
        e_ident +
          [e_type].pack("S<") +           # ET_DYN for a .so, ET_EXEC for an executable
          [e_machine_id].pack("S<") +
          [EV_CURRENT].pack("L<") +
          [e_entry].pack("Q<") +          # 0 for a shared object, _start's vaddr for an executable
          [EHDR_SIZE].pack("Q<") +        # e_phoff (program headers follow the header)
          [shoff].pack("Q<") +            # e_shoff
          [0].pack("L<") +                # e_flags
          [EHDR_SIZE].pack("S<") +        # e_ehsize
          [PHDR_SIZE].pack("S<") +        # e_phentsize
          [phnum].pack("S<") +            # e_phnum
          [SHDR_SIZE].pack("S<") +        # e_shentsize
          [@placed.size + 2].pack("S<") + # e_shnum (NULL + placed + .shstrtab)
          [@shstrtab_index].pack("S<")    # e_shstrndx
      end

      def build_shstrtab
        buf = +"\0".b
        offsets = {}
        (@placed.map(&:name) + [".shstrtab"]).each do |name|
          next if offsets.key?(name)

          offsets[name] = buf.bytesize
          buf << name.b << "\0".b
        end
        [buf, offsets]
      end

      def build_null_shdr(name_offsets)
        shdr(name: 0, type: SHT_NULL, flags: 0, addr: 0, offset: 0, size: 0,
             link: 0, info: 0, addralign: 0, entsize: 0)
      end

      def build_shdr(sec, name_offsets)
        shdr(name: name_offsets[sec.name], type: sec.type, flags: sec.flags,
             addr: sec.vaddr, offset: sec.offset, size: sec.size,
             link: sec.link || 0, info: sec.info || 0,
             addralign: sec.addralign, entsize: sec.entsize)
      end

      def build_shstrtab_shdr(offset, size, name_offsets)
        shdr(name: name_offsets[".shstrtab"], type: SHT_STRTAB, flags: 0, addr: 0,
             offset: offset, size: size, link: 0, info: 0, addralign: 1, entsize: 0)
      end

      def shdr(name:, type:, flags:, addr:, offset:, size:, link:, info:, addralign:, entsize:)
        [name].pack("L<") + [type].pack("L<") + [flags].pack("Q<") + [addr].pack("Q<") +
          [offset].pack("Q<") + [size].pack("Q<") + [link].pack("L<") + [info].pack("L<") +
          [addralign].pack("Q<") + [entsize].pack("Q<")
      end

      def sym_entry(name:, info:, other:, shndx:, value:, size:)
        [name].pack("L<") + [info].pack("C") + [other].pack("C") +
          [shndx].pack("S<") + [value].pack("Q<") + [size].pack("Q<")
      end

      def patch32(buf, offset, value)
        buf[offset, 4] = [value & 0xFFFFFFFF].pack("L<")
      end

      def patch64(buf, offset, value)
        buf[offset, 8] = [value & 0xFFFFFFFFFFFFFFFF].pack("Q<")
      end

      def align(value, alignment)
        alignment <= 1 ? value : (value + alignment - 1) / alignment * alignment
      end

      def pad_to(buffer, target)
        buffer << ("\0" * (target - buffer.bytesize)).b if buffer.bytesize < target
      end
    end
  end
end
