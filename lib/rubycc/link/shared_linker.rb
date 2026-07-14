# frozen_string_literal: true

module Rubycc
  module Link
    # The final-link core that turns an ordered set of relocatable inputs into a
    # loadable ELF64 shared object (ET_DYN, a `.so`) for Linux x86_64. It is the
    # counterpart of the `ld -r` static core: where PartialLinker merges inputs
    # into another ET_REL and only *retargets* relocations, this stage assigns
    # load-time virtual addresses, *applies* the relocations by patching bytes,
    # and synthesizes the dynamic-linking metadata a runtime loader (glibc's
    # dlopen, in particular) reads to bind and run the object.
    #
    # This is the first stage of the shared-library writer. It handles a
    # *self-contained* object — one that calls neither libc nor any other shared
    # library, i.e. the kind rubycc emits for internal arithmetic, internal
    # function calls, internal globals/strings and internal function pointers.
    # Every relocation therefore resolves within this object; an undefined
    # (imported) symbol is rejected, since external symbol resolution — PLT/GOT
    # imports, JUMP_SLOT/GLOB_DAT, DT_NEEDED — is a later stage.
    #
    # Pipeline: the inputs are first merged into one ET_REL image by PartialLinker
    # (reusing its section concatenation, symbol resolution and archive pull-in),
    # then read back through ELFReader so this stage works from resolved
    # Section/Symbol/Relocation values. From there it (1) lays the allocatable
    # sections into three page-aligned PT_LOAD segments by permission — r-x, r--,
    # rw- — with the ELF and program headers at the head of the first, choosing
    # `p_vaddr == p_offset` for every placed section so the `p_vaddr ≡ p_offset
    # (mod page)` load constraint holds trivially; (2) builds the dynamic tables
    # (.dynsym/.dynstr exporting every defined global and weak, a SysV .hash, and
    # a .dynamic array); (3) applies each relocation against the assigned
    # addresses, creating a GOT slot for a GOT-relative reference and emitting an
    # R_X86_64_RELATIVE dynamic relocation for every absolute address the loader
    # must rebase (a GOT slot's contents and an R_X86_64_64 data initializer).
    #
    # Output is deterministic (N4): sections keep the merged object's order, the
    # dynamic symbol table follows the merged symbol order, the hash bucket count
    # is derived from the symbol count, and no timestamp or address randomness is
    # embedded — identical inputs yield byte-identical `.so` output.
    class SharedLinker
      include ObjFile

      PAGE = 0x1000

      # ELF header encodings.
      ELFCLASS64  = 2
      ELFDATA2LSB = 1
      EV_CURRENT  = 1
      ET_DYN      = 3
      EM_X86_64   = 62
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
      # alike; R_X86_64_RELATIVE (8) is the only *dynamic* relocation emitted, for
      # an absolute address the loader must rebase.
      R_X86_64_64            = 1
      R_X86_64_PC32          = 2
      R_X86_64_PLT32         = 4
      R_X86_64_GOTPCREL      = 9
      R_X86_64_32            = 10
      R_X86_64_32S           = 11
      R_X86_64_GOTPCRELX     = 41
      R_X86_64_REX_GOTPCRELX = 42
      R_X86_64_RELATIVE      = 8
      GOT_RELOC_TYPES = [R_X86_64_GOTPCREL, R_X86_64_GOTPCRELX, R_X86_64_REX_GOTPCRELX].freeze

      # Dynamic array tags emitted into .dynamic.
      DT_NULL      = 0
      DT_HASH      = 4
      DT_STRTAB    = 5
      DT_SYMTAB    = 6
      DT_RELA      = 7
      DT_RELASZ    = 8
      DT_RELAENT   = 9
      DT_STRSZ     = 10
      DT_SYMENT    = 11
      DT_RELACOUNT = 0x6FFFFFF9

      SYM_ENTSIZE  = 24
      RELA_ENTSIZE = 24
      DYN_ENTSIZE  = 16

      class << self
        # Links `inputs` (an ordered array; each element a filesystem path, or the
        # raw bytes of an ET_REL object or an ar archive — the same shapes
        # PartialLinker accepts) into a shared object, returned as an ASCII-8BIT
        # String.
        def link(inputs)
          new(inputs).link
        end

        # Convenience: link and write the shared object to `path`.
        def link_to(inputs, path)
          File.binwrite(path, link(inputs))
        end
      end

      def initialize(inputs)
        @inputs = inputs
      end

      def link
        @reader = ELFReader.read(PartialLinker.link(@inputs))
        plan_dynamic_symbols
        scan_relocations
        place_sections
        apply_relocations
        assemble
      end

      private

      # A section placed into the image: its ELF section-header fields plus the
      # assigned load address and file offset. `data` holds the file bytes (nil
      # for a NOBITS section, which reserves memory only). `index` is its position
      # in the emitted section header table, resolved during layout.
      Placed = Struct.new(
        :name, :type, :flags, :addralign, :entsize, :size, :data,
        :vaddr, :offset, :link, :info, :index, keyword_init: true
      )

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

      # Walks every relocation to reject unresolved externals and to size the
      # GOT and the dynamic relocation table before addresses are assigned: it
      # collects the ordered set of symbols that need a GOT slot and counts the
      # absolute-64 initializers that will each need an R_X86_64_RELATIVE entry.
      def scan_relocations
        @got_order = []   # symbols needing a GOT slot, first-seen order
        @got_index = {}   # got key => slot index
        @data64_count = 0
        allocatable_relocation_sections.each do |rs|
          rs.relocations.each { |reloc| scan_relocation(reloc) }
        end
      end

      def scan_relocation(reloc)
        type = reloc.type
        unless supported_relocation?(type)
          raise LinkError, "unsupported relocation type #{reloc.type_name || type} in a shared object"
        end

        sym = reloc.symbol
        reject_undefined(sym)

        if GOT_RELOC_TYPES.include?(type)
          key = got_key(sym)
          unless @got_index.key?(key)
            @got_index[key] = @got_order.size
            @got_order << sym
          end
        elsif type == R_X86_64_64
          @data64_count += 1
        end
      end

      def supported_relocation?(type)
        [R_X86_64_64, R_X86_64_PC32, R_X86_64_PLT32, R_X86_64_32, R_X86_64_32S,
         *GOT_RELOC_TYPES].include?(type)
      end

      # An undefined (imported) symbol cannot be bound within a self-contained
      # object; report it clearly and point at the stage that will handle it.
      def reject_undefined(sym)
        return unless sym && sym.type != :section && sym.undefined?

        raise LinkError, "cannot build a self-contained shared object: symbol " \
                         "'#{sym.name}' is undefined. External symbol resolution " \
                         "(PLT/GOT imports, DT_NEEDED) is not yet implemented " \
                         "(planned for the next shared-library stage, L5b)"
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

      # --- address assignment ------------------------------------------------

      # Lays the allocatable input sections and the synthesized dynamic sections
      # into three page-aligned PT_LOAD segments by permission, assigning each a
      # file offset and an equal virtual address. The r-x segment begins at file
      # offset 0 so the ELF header and program headers it contains are mapped;
      # the r-- and rw- segments each start on a fresh page. .bss (NOBITS) sits
      # last in the rw- segment, extending its memory size past its file size.
      def place_sections
        rx = input_sections { |s| executable?(s) }
        ro = dynamic_ro_sections + input_sections { |s| !executable?(s) && !writable?(s) }
        rw_files = input_sections { |s| writable?(s) && s.type != SHT_NOBITS } + writable_dynamic_sections
        bss = input_sections { |s| writable?(s) && s.type == SHT_NOBITS }

        cursor = EHDR_SIZE + phnum * PHDR_SIZE
        cursor, @rx = lay(rx, cursor)
        cursor = align(cursor, PAGE)
        cursor, @ro = lay(ro, cursor)
        cursor = align(cursor, PAGE)
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
          sec.vaddr = cursor
          sec.offset = cursor
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

      # The three synthesized read-only dynamic sections, in the order the loader
      # expects to find them addressed from .dynamic: the SysV hash, the dynamic
      # symbol table, and its string table, followed by .rela.dyn when present.
      def dynamic_ro_sections
        secs = [
          placed_generated(".hash", SHT_HASH, SHF_ALLOC, 8, 4, hash_bytes.bytesize),
          placed_generated(".dynsym", SHT_DYNSYM, SHF_ALLOC, 8, SYM_ENTSIZE, dynsym_size),
          placed_generated(".dynstr", SHT_STRTAB, SHF_ALLOC, 1, 0, dynstr_bytes.bytesize)
        ]
        secs << placed_generated(".rela.dyn", SHT_RELA, SHF_ALLOC, 8, RELA_ENTSIZE, rela_size) if rela?
        secs
      end

      # The synthesized writable dynamic sections: the GOT (only when a GOT slot
      # is needed) and the .dynamic array.
      def writable_dynamic_sections
        secs = []
        secs << placed_generated(".got", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, 8, 8, @got_order.size * 8) unless @got_order.empty?
        secs << placed_generated(".dynamic", SHT_DYNAMIC, SHF_ALLOC | SHF_WRITE, 8, DYN_ENTSIZE, dynamic_size)
        secs
      end

      def placed_generated(name, type, flags, addralign, entsize, size)
        Placed.new(name: name, type: type, flags: flags, addralign: addralign,
                   entsize: entsize, size: size, data: nil)
      end

      def rela? = @data64_count.positive? || !@got_order.empty?
      def rela_size = rela_count * RELA_ENTSIZE
      def rela_count = @got_order.size + @data64_count
      def dynsym_size = (@exports.size + 1) * SYM_ENTSIZE
      # The dynamic array's size depends only on which tags are present, not on
      # the addresses filled in later, so it can be computed during sizing: the
      # five always-present tags, the four relocation tags when .rela.dyn exists,
      # and the DT_NULL terminator.
      def dynamic_size = (5 + (rela? ? 4 : 0) + 1) * DYN_ENTSIZE

      # --- relocation application --------------------------------------------

      # Patches every allocatable target section against the assigned addresses,
      # filling the GOT slots and collecting the R_X86_64_RELATIVE entries. The
      # relative entries are ordered GOT slots first (in slot order), then the
      # absolute-64 initializers (in relocation order), for a deterministic
      # .rela.dyn.
      def apply_relocations
        @section_data = {}
        @placed.each { |sec| @section_data[sec.name] = sec.data if sec.data }
        @rela_data = []

        allocatable_relocation_sections.each do |rs|
          base = @vaddr[rs.target.name]
          buf = @section_data[rs.target.name]
          rs.relocations.each { |reloc| apply_relocation(reloc, base, buf) }
        end

        build_got_and_relative
      end

      def apply_relocation(reloc, base, buf)
        s = symbol_address(reloc.symbol)
        a = reloc.addend
        p = base + reloc.offset
        case reloc.type
        when R_X86_64_PC32, R_X86_64_PLT32
          patch32(buf, reloc.offset, s + a - p)
        when R_X86_64_32, R_X86_64_32S
          patch32(buf, reloc.offset, s + a)
        when *GOT_RELOC_TYPES
          slot = @vaddr[".got"] + @got_index[got_key(reloc.symbol)] * 8
          patch32(buf, reloc.offset, slot + a - p)
        when R_X86_64_64
          value = s + a
          patch64(buf, reloc.offset, value)
          @rela_data << [p, value]
        end
      end

      # Fills each GOT slot with the link-time address of its symbol and records
      # an R_X86_64_RELATIVE entry so the loader rewrites the slot to base + that
      # address. The self-contained target is why every GOT slot is a plain
      # relative rebase rather than a JUMP_SLOT/GLOB_DAT import.
      def build_got_and_relative
        @got_bytes = +"".b
        @rela_got = []
        @got_order.each_with_index do |sym, i|
          address = symbol_address(sym)
          @got_bytes << [address].pack("Q<")
          @rela_got << [@vaddr[".got"] + i * 8, address]
        end
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

      # Builds .dynstr and the exported-name offset map, memoized so the sizing
      # pass and the emit share one table.
      def dynstr
        @dynstr ||= begin
          buf = +"\0".b
          offsets = {}
          @exports.each do |sym|
            next if offsets.key?(sym.name)

            offsets[sym.name] = buf.bytesize
            buf << sym.name.b << "\0".b
          end
          [buf, offsets]
        end
      end

      def dynstr_bytes = dynstr[0]

      # The .dynsym payload: the reserved null entry, then one entry per exported
      # symbol carrying its load address, size, binding/type and defining section.
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
        buf
      end

      # The SysV (.hash) table: nbucket, nchain, then the bucket heads and the
      # collision chain. Each dynamic symbol is hashed into a bucket and prepended
      # to that bucket's chain, in symbol-index order for a deterministic layout.
      def hash_bytes
        nsyms = @exports.size + 1
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

      # The concatenated .rela.dyn payload: the GOT-slot relatives, then the
      # data initializer relatives. Every entry is an R_X86_64_RELATIVE (no
      # symbol), so r_info is just the type.
      def rela_bytes
        buf = +"".b
        (@rela_got + @rela_data).each do |offset, addend|
          buf << [offset].pack("Q<") << [R_X86_64_RELATIVE].pack("Q<") << [addend].pack("q<")
        end
        buf
      end

      # The .dynamic array: pointers/sizes for the hash and symbol/string tables,
      # the relocation table when present (including DT_RELACOUNT, since every
      # entry is relative), and the DT_NULL terminator.
      def dynamic_entries
        entries = [
          [DT_HASH, @vaddr[".hash"]],
          [DT_STRTAB, @vaddr[".dynstr"]],
          [DT_SYMTAB, @vaddr[".dynsym"]],
          [DT_STRSZ, dynstr_bytes.bytesize],
          [DT_SYMENT, SYM_ENTSIZE]
        ]
        if rela?
          entries += [
            [DT_RELA, @vaddr[".rela.dyn"]],
            [DT_RELASZ, rela_size],
            [DT_RELAENT, RELA_ENTSIZE],
            [DT_RELACOUNT, rela_count]
          ]
        end
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
        when ".rela.dyn" then rela_bytes
        when ".got"      then @got_bytes
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
          phdr(PT_LOAD, PF_R | PF_X, 0, 0, rx[:filesz], rx[:filesz], PAGE),
          phdr(PT_LOAD, PF_R, ro[:offset], ro[:offset], ro[:filesz], ro[:filesz], PAGE),
          phdr(PT_LOAD, PF_R | PF_W, @rw_start, @rw_start,
               @file_end - @rw_start, @mem_end - @rw_start, PAGE),
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
          [ET_DYN].pack("S<") +
          [EM_X86_64].pack("S<") +
          [EV_CURRENT].pack("L<") +
          [0].pack("Q<") +                # e_entry (a shared object has no entry)
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
