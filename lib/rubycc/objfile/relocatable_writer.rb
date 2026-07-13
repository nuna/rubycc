# frozen_string_literal: true

module Rubycc
  module ObjFile
    # Writes a *general* ELF64 relocatable object (ET_REL) for Linux x86_64:
    # arbitrary named sections, an arbitrary symbol table, and full SHT_RELA
    # relocation tables carrying any relocation type and addend.
    #
    # It is the counterpart the linker's `ld -r` core needs and deliberately
    # NOT the compiler's ELFWriter. That writer serves a single translation
    # unit through a fixed menu — .text/.rodata/.data/.bss and three baked-in
    # relocation kinds — because a compiler always emits the same shape. A
    # merged object is open-ended: it may hold any section the inputs carried
    # (.comment, .note.*, .eh_frame, ...), section symbols pointing at merged
    # sections, and relocations of any numeric type against any symbol with any
    # addend. Rather than contort the compiler's writer, this one accepts those
    # pieces directly and lays them out.
    #
    # The API is build-then-emit: #add_section, #add_symbol and #add_relocation
    # return opaque handles (the value structs below) that later calls reference
    # by identity, so the caller never computes on-disk indices itself. #to_binary
    # fixes the section order (NULL, the content sections in insertion order, one
    # .rela.<name> per relocated target, then .symtab/.strtab/.shstrtab), resolves
    # every cross-reference (symbol st_shndx, rela sh_link/sh_info, r_info's symbol
    # index) against that order, and concatenates the image.
    #
    # Two invariants the caller relies on: symbols are emitted with every
    # STB_LOCAL before the first non-local (a stable partition of insertion
    # order, so relocation handles stay valid) and sh_info of .symtab lands on
    # the first global; output is fully deterministic (N4) — identical build
    # calls yield byte-identical bytes, with no timestamps embedded.
    class RelocatableWriter
      ELFCLASS64  = 2
      ELFDATA2LSB = 1
      EV_CURRENT  = 1
      ET_REL      = 1
      EM_X86_64   = 62

      SHN_UNDEF = 0
      SHN_ABS   = 0xFFF1

      SHT_SYMTAB = 2
      SHT_STRTAB = 3
      SHT_RELA   = 4
      SHT_NOBITS = 8

      SHF_INFO_LINK = 0x40

      # Symbolic bind/type/visibility accepted from the caller, mapped to their
      # st_info / st_other encodings. A caller may also pass the raw integer,
      # which passes through unchanged.
      BINDINGS     = { local: 0, global: 1, weak: 2 }.freeze
      TYPES        = { notype: 0, object: 1, func: 2, section: 3, file: 4, tls: 6, ifunc: 10 }.freeze
      VISIBILITIES = { default: 0, internal: 1, hidden: 2, protected: 3 }.freeze

      SYM_ENTSIZE  = 24
      RELA_ENTSIZE = 24
      SHDR_ENTSIZE = 64
      EHDR_SIZE    = 64

      # A section to emit. `data` holds the file bytes for a non-NOBITS section;
      # a NOBITS section (.bss) carries `size` instead and occupies no file
      # space. `index` is filled in during layout.
      Section = Struct.new(
        :name, :type, :flags, :addralign, :entsize, :data, :size, :index,
        keyword_init: true
      )

      # A symbol to emit. `section` (a Section handle) names the section that
      # defines it, in which case st_shndx is that section's index; otherwise
      # `shndx` carries a reserved value (SHN_UNDEF / SHN_ABS). `index` is filled
      # in during layout.
      Symbol = Struct.new(
        :name, :bind, :type, :visibility, :section, :shndx, :value, :size, :index,
        keyword_init: true
      )

      # A relocation to emit into the .rela table of `target`. `symbol` is a
      # Symbol handle; `type` is the numeric x86_64 relocation type.
      Relocation = Struct.new(:target, :offset, :symbol, :type, :addend, keyword_init: true)

      def initialize
        @sections = []
        # The reserved null symbol is index 0 by the ELF ABI; expose it so a
        # caller can re-point a "no symbol" relocation at it.
        @null_symbol = Symbol.new(name: nil, bind: 0, type: 0, visibility: 0,
                                  section: nil, shndx: SHN_UNDEF, value: 0, size: 0)
        @symbols = [@null_symbol]
        @relocations = []
      end

      attr_reader :null_symbol

      # Registers a content section. `type`/`flags`/`entsize` are raw ELF values;
      # `data` (bytes) or, for a NOBITS section, `size` gives its extent. Returns
      # the Section handle to reference from symbols and relocations.
      def add_section(name:, type:, flags:, addralign:, entsize: 0, data: nil, size: nil)
        section = Section.new(name: name, type: type, flags: flags,
                              addralign: [addralign, 1].max, entsize: entsize,
                              data: data&.b, size: size)
        @sections << section
        section
      end

      # Registers a symbol. `bind`/`type`/`visibility` may be the symbolic forms
      # (:local, :func, :hidden, ...) or raw integers. Returns the Symbol handle.
      def add_symbol(name:, bind:, type:, visibility: :default, section: nil, shndx: SHN_UNDEF, value: 0, size: 0)
        symbol = Symbol.new(
          name: name, bind: BINDINGS.fetch(bind, bind), type: TYPES.fetch(type, type),
          visibility: VISIBILITIES.fetch(visibility, visibility),
          section: section, shndx: shndx, value: value, size: size
        )
        @symbols << symbol
        symbol
      end

      # Records a relocation to emit into `target`'s .rela table.
      def add_relocation(target:, offset:, symbol:, type:, addend:)
        @relocations << Relocation.new(target: target, offset: offset, symbol: symbol,
                                       type: type, addend: addend)
        self
      end

      # Assembles and returns the object as an ASCII-8BIT String.
      def to_binary
        order_symbols
        layout = build_layout
        assemble(layout)
      end

      def write(path)
        File.binwrite(path, to_binary)
      end

      private

      # Stable-partitions the symbol table so every STB_LOCAL precedes the first
      # non-local, as the ABI requires, without disturbing relative order within
      # each class. The null symbol (bind 0 = local) naturally stays first.
      def order_symbols
        locals, globals = @symbols.partition { |sym| sym.bind == BINDINGS[:local] }
        @symbols = locals + globals
        @first_global = locals.size
        @symbols.each_with_index { |sym, i| sym.index = i }
      end

      # The relocations aimed at `section`, in insertion order — matched by
      # object identity, since a Section struct hashes by value and its :index
      # field is mutated during layout (a value-keyed lookup would then miss).
      def relocations_for(section)
        @relocations.select { |reloc| reloc.target.equal?(section) }
      end

      # A section descriptor used only during layout, carrying the payload bytes
      # and the resolved sh_link/sh_info as concrete indices.
      LaidOut = Struct.new(:name, :type, :flags, :addr, :size, :link, :info,
                           :addralign, :entsize, :data, :offset, keyword_init: true)

      # Fixes the on-disk section order and assigns every section its index, then
      # builds the symbol/relocation/string payloads against those indices.
      def build_layout
        # Section order: NULL, the content sections, one .rela per relocated
        # target, then the symbol and string tables. Indices are assigned as this
        # list is built so the cross-references below resolve to concrete values.
        sections = [null_layout]
        index = 1
        @sections.each do |sec|
          sec.index = index
          index += 1
        end
        rela_targets = @sections.select { |sec| relocations_for(sec).any? }
        symtab_index = index + rela_targets.size
        strtab_index = symtab_index + 1
        shstrtab_index = strtab_index + 1

        strtab, sym_name_offsets = build_strtab
        symtab = build_symtab(sym_name_offsets)

        @sections.each { |sec| sections << content_layout(sec) }
        rela_targets.each do |target|
          sections << rela_layout(target, relocations_for(target), symtab_index)
        end
        sections << symtab_layout(symtab, strtab_index)
        sections << strtab_layout(strtab)
        sections << shstrtab_layout

        { sections: sections, shstrtab_index: shstrtab_index }
      end

      def null_layout
        LaidOut.new(name: nil, type: 0, flags: 0, addr: 0, size: 0, link: 0, info: 0,
                    addralign: 0, entsize: 0, data: "".b)
      end

      # A NOBITS section reports its in-memory size but carries no file bytes; any
      # other section carries its data (nil data means the layout pass skips it).
      def content_layout(sec)
        nobits = sec.type == SHT_NOBITS
        LaidOut.new(
          name: sec.name, type: sec.type, flags: sec.flags, addr: 0,
          size: nobits ? (sec.size || 0) : (sec.data ? sec.data.bytesize : 0),
          link: 0, info: 0, addralign: sec.addralign, entsize: sec.entsize,
          data: nobits ? nil : (sec.data || "".b)
        )
      end

      def rela_layout(target, relocs, symtab_index)
        LaidOut.new(
          name: ".rela#{target.name}", type: SHT_RELA, flags: SHF_INFO_LINK, addr: 0,
          size: relocs.size * RELA_ENTSIZE, link: symtab_index, info: target.index,
          addralign: 8, entsize: RELA_ENTSIZE, data: build_rela(relocs)
        )
      end

      def symtab_layout(symtab, strtab_index)
        LaidOut.new(
          name: ".symtab", type: SHT_SYMTAB, flags: 0, addr: 0, size: symtab.bytesize,
          link: strtab_index, info: @first_global, addralign: 8, entsize: SYM_ENTSIZE,
          data: symtab
        )
      end

      def strtab_layout(strtab)
        LaidOut.new(name: ".strtab", type: SHT_STRTAB, flags: 0, addr: 0,
                    size: strtab.bytesize, link: 0, info: 0, addralign: 1, entsize: 0,
                    data: strtab)
      end

      def shstrtab_layout
        # Filled with real bytes in #assemble, once every section name is known.
        LaidOut.new(name: ".shstrtab", type: SHT_STRTAB, flags: 0, addr: 0, size: 0,
                    link: 0, info: 0, addralign: 1, entsize: 0, data: nil)
      end

      # Builds .strtab (symbol names). Returns [bytes, name -> offset]. Names are
      # de-duplicated so two symbols with the same string share one entry.
      def build_strtab
        buf = +"\0".b
        offsets = {}
        @symbols.each do |sym|
          name = sym.name
          next if name.nil? || name.empty? || offsets.key?(name)

          offsets[name] = buf.bytesize
          buf << name.b << "\0".b
        end
        [buf, offsets]
      end

      def build_symtab(sym_name_offsets)
        buf = +"".b
        @symbols.each do |sym|
          shndx = sym.section ? sym.section.index : sym.shndx
          name_off = sym.name && !sym.name.empty? ? sym_name_offsets.fetch(sym.name) : 0
          buf << sym_entry(name: name_off, info: (sym.bind << 4) | sym.type,
                           other: sym.visibility, shndx: shndx, value: sym.value, size: sym.size)
        end
        buf
      end

      # Builds one .rela payload: 24 bytes per entry (r_offset, r_info, r_addend).
      # r_info packs the symbol's resolved table index with the numeric type.
      def build_rela(relocs)
        buf = +"".b
        relocs.each do |reloc|
          r_info = (reloc.symbol.index << 32) | (reloc.type & 0xFFFFFFFF)
          buf << [reloc.offset].pack("Q<") << [r_info].pack("Q<") << [reloc.addend].pack("q<")
        end
        buf
      end

      # Computes file offsets, fills in .shstrtab, and concatenates the header,
      # section payloads and section header table.
      def assemble(layout)
        sections = layout[:sections]
        shstrtab, name_offsets = build_shstrtab(sections)
        sections[layout[:shstrtab_index]].data = shstrtab
        sections[layout[:shstrtab_index]].size = shstrtab.bytesize

        offset = EHDR_SIZE
        sections.each do |sec|
          # A NOBITS section keeps an aligned sh_offset for tooling but does not
          # advance the file cursor; a NULL section (nil-ish) is skipped likewise.
          if sec.type == SHT_NOBITS
            offset = align(offset, [sec.addralign, 1].max)
            sec.offset = offset
            next
          end
          next if sec.data.nil?

          offset = align(offset, [sec.addralign, 1].max)
          sec.offset = offset
          offset += sec.data.bytesize
        end
        shoff = align(offset, 8)

        out = +"".b
        out << build_ehdr(shoff, sections.size, layout[:shstrtab_index])
        sections.each do |sec|
          next if sec.data.nil? || sec.type == SHT_NOBITS

          pad_to(out, sec.offset)
          out << sec.data
        end
        pad_to(out, shoff)
        sections.each { |sec| out << build_shdr(sec, name_offsets) }
        out
      end

      def build_shstrtab(sections)
        buf = +"\0".b
        offsets = {}
        sections.each do |sec|
          name = sec.name
          next if name.nil? || offsets.key?(name)

          offsets[name] = buf.bytesize
          buf << name.b << "\0".b
        end
        [buf, offsets]
      end

      def build_ehdr(shoff, shnum, shstrndx)
        e_ident = [0x7F, 0x45, 0x4C, 0x46, ELFCLASS64, ELFDATA2LSB, EV_CURRENT,
                   0, 0, 0, 0, 0, 0, 0, 0, 0].pack("C16")
        e_ident +
          [ET_REL].pack("S<") +
          [EM_X86_64].pack("S<") +
          [EV_CURRENT].pack("L<") +
          [0].pack("Q<") +            # e_entry
          [0].pack("Q<") +            # e_phoff
          [shoff].pack("Q<") +        # e_shoff
          [0].pack("L<") +            # e_flags
          [EHDR_SIZE].pack("S<") +    # e_ehsize
          [0].pack("S<") +            # e_phentsize
          [0].pack("S<") +            # e_phnum
          [SHDR_ENTSIZE].pack("S<") + # e_shentsize
          [shnum].pack("S<") +        # e_shnum
          [shstrndx].pack("S<")       # e_shstrndx
      end

      def build_shdr(sec, name_offsets)
        [sec.name ? name_offsets[sec.name] : 0].pack("L<") +
          [sec.type].pack("L<") +
          [sec.flags].pack("Q<") +
          [sec.addr].pack("Q<") +
          [sec.offset || 0].pack("Q<") +
          [sec.size].pack("Q<") +
          [sec.link].pack("L<") +
          [sec.info].pack("L<") +
          [sec.addralign].pack("Q<") +
          [sec.entsize].pack("Q<")
      end

      def sym_entry(name:, info:, other:, shndx:, value:, size:)
        [name].pack("L<") + [info].pack("C") + [other].pack("C") +
          [shndx].pack("S<") + [value].pack("Q<") + [size].pack("Q<")
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
