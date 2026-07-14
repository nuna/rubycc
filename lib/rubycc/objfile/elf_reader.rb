# frozen_string_literal: true

module Rubycc
  module ObjFile
    # Raised for any input that is not a well-formed ELF64 object this reader
    # accepts: a truncated file, a bad magic, a non-64-bit class, a non-x86_64
    # machine, or an internally inconsistent structure (a section or table
    # pointing past the end of the file). The message names the specific defect
    # so the linker (L3) can surface it to the user.
    class ELFFormatError < Rubycc::Error; end

    # Reads an ELF64 little-endian x86_64 object for the linker. Two shapes are
    # supported: a relocatable object (ET_REL, a compiler-emitted `.o`) is fully
    # parsed — sections with their raw bytes, the `.symtab`, and every `.rela.*`
    # relocation table; a shared object (ET_DYN, a `.so`) is read for its
    # dynamic-linking interface — the `.dynsym` exported/imported symbols and the
    # `.dynamic` array's DT_SONAME / DT_NEEDED strings.
    #
    # This is the counterpart of ELFWriter and is designed to round-trip
    # everything that writer emits (see test/test_elf_reader.rb): the parsed
    # Section/Symbol/Relocation value objects carry exactly the fields the writer
    # sets, resolved back from their on-disk encoding (section names via
    # `.shstrtab`, symbol names via the linked string table, relocation targets
    # via `r_info`'s symbol index and the RELA section's `sh_info`).
    #
    # The model is load-then-query: `read`/`read_file` parse the whole image up
    # front into arrays and name-indexed lookups so the linker can address any
    # section, symbol, or relocation randomly rather than through a callback
    # stream. Nothing here writes or mutates an object.
    #
    # For a `.so` the dynamic tables are located strictly through the section
    # header table (`.dynsym` / `.dynstr` / `.dynamic` by `sh_type`, sized by
    # `sh_size` / `sh_entsize`). The allocated dynamic sections survive `strip`,
    # so a section-header-less `.so` is rare enough that the PT_DYNAMIC program
    # header fallback (deriving the symbol count from DT_HASH / DT_GNU_HASH) is
    # deliberately not built here — YAGNI until a real input demands it.
    class ELFReader
      # ELF identification (e_ident) and header field encodings.
      ELFMAG      = "\x7FELF".b
      EI_CLASS    = 4
      EI_DATA     = 5
      EI_VERSION  = 6
      ELFCLASS64  = 2
      ELFDATA2LSB = 1
      EV_CURRENT  = 1
      EHDR_SIZE   = 64
      SHDR_SIZE   = 64

      # e_type values (only the two the linker consumes are named; others are
      # reported numerically and rejected by #read).
      ET_REL = 1
      ET_DYN = 3

      EM_X86_64 = 62

      # Section header types.
      SHT_NULL     = 0
      SHT_PROGBITS = 1
      SHT_SYMTAB   = 2
      SHT_STRTAB   = 3
      SHT_RELA     = 4
      SHT_DYNAMIC  = 6
      SHT_NOBITS   = 8
      SHT_DYNSYM   = 11

      # Reserved section indices that a symbol's st_shndx may carry instead of a
      # real section number: an undefined (imported) symbol, an absolute value,
      # and a not-yet-allocated COMMON block.
      SHN_UNDEF     = 0
      SHN_LORESERVE = 0xFF00
      SHN_ABS       = 0xFFF1
      SHN_COMMON    = 0xFFF2
      SHN_XINDEX    = 0xFFFF

      SYM_ENTSIZE  = 24
      RELA_ENTSIZE = 24
      DYN_ENTSIZE  = 16

      # Symbol binding (st_info >> 4) and type (st_info & 0xF), mapped to symbols
      # for readable queries; an unrecognized value passes through as its integer.
      SYM_BINDINGS = { 0 => :local, 1 => :global, 2 => :weak }.freeze
      SYM_TYPES = {
        0 => :notype, 1 => :object, 2 => :func, 3 => :section, 4 => :file,
        6 => :tls, 10 => :ifunc
      }.freeze
      # Symbol visibility (st_other & 0x3).
      SYM_VISIBILITIES = { 0 => :default, 1 => :internal, 2 => :hidden, 3 => :protected }.freeze

      # x86_64 relocation types (r_info & 0xFFFFFFFF). The ones the toolchain
      # emits are named; any other type is preserved numerically (its name is nil)
      # rather than rejected, so an unfamiliar object is still fully readable.
      # The GOTPCREL family addresses a symbol's Global Offset Table slot: 9 is
      # the plain PC-relative GOT reference, and 41/42 its "relaxable" forms the
      # psABI defines for a `mov` that a linker may rewrite in place to a `lea`
      # (42 is the REX-prefixed form a 64-bit `mov rax, sym@GOTPCREL(%rip)` uses).
      RELOC_TYPES = {
        1 => :R_X86_64_64,
        2 => :R_X86_64_PC32,
        4 => :R_X86_64_PLT32,
        9 => :R_X86_64_GOTPCREL,
        10 => :R_X86_64_32,
        11 => :R_X86_64_32S,
        41 => :R_X86_64_GOTPCRELX,
        42 => :R_X86_64_REX_GOTPCRELX
      }.freeze

      # Dynamic array tags (.dynamic) this reader interprets: the terminator, the
      # DT_NEEDED shared-library dependencies, and the DT_SONAME of the object
      # itself. Every tag's raw value is still exposed; only these drive behavior.
      DT_NULL   = 0
      DT_NEEDED = 1
      DT_SONAME = 14

      # A parsed section header plus (for non-NOBITS sections) its raw file bytes.
      # `index` is the section's position in the header table — the value other
      # sections' sh_link/sh_info and symbols' st_shndx refer to. `data` is nil
      # for SHT_NULL and SHT_NOBITS (.bss), which occupy no file bytes while
      # still reporting their in-memory `size`.
      Section = Struct.new(
        :index, :name, :type, :flags, :addr, :offset, :size,
        :link, :info, :addralign, :entsize, :data, keyword_init: true
      ) do
        def nobits? = type == SHT_NOBITS
      end

      # A parsed symbol table entry. `bind`/`type`/`visibility` are the decoded
      # symbolic forms; `shndx` is the raw st_shndx and `section` the Section it
      # names (nil for an undefined/absolute/common symbol). The predicates
      # distinguish the reserved st_shndx markers the writer emits.
      Symbol = Struct.new(
        :index, :name, :value, :size, :bind, :type, :visibility, :shndx, :section,
        keyword_init: true
      ) do
        def undefined? = shndx == SHN_UNDEF
        def absolute? = shndx == SHN_ABS
        def common? = shndx == SHN_COMMON
        # Defined here means backed by a real section in this object (neither
        # imported nor a reserved marker) — what "does this .so export printf?"
        # asks of a dynamic symbol.
        def defined? = !undefined? && shndx < SHN_LORESERVE
      end

      # A single RELA entry. `symbol` is the resolved Symbol (from the RELA
      # section's linked symbol table); `type` is the numeric relocation type and
      # `type_name` its RELOC_TYPES symbol (nil when unknown). `addend` is signed.
      Relocation = Struct.new(
        :offset, :type, :type_name, :symbol, :addend, keyword_init: true
      )

      # One SHT_RELA table: the relocations it holds and the Section they patch
      # (its sh_info target, e.g. .text for .rela.text). Grouping by target is
      # what the linker walks when applying fixups section by section.
      RelocationSection = Struct.new(:section, :target, :relocations, keyword_init: true)

      class << self
        # Parses an in-memory ELF image (an ASCII-8BIT String) and returns a
        # ready-to-query ELFReader.
        def read(bytes)
          new(bytes).tap(&:parse!)
        end

        # Reads a file from disk and parses it. Convenience over read(File.binread).
        def read_file(path)
          read(File.binread(path))
        end
      end

      attr_reader :type, :machine, :entry, :sections, :symbols,
                  :relocation_sections, :dynamic_symbols, :dynamic_entries,
                  :soname, :needed

      def initialize(bytes)
        @data = bytes.b
        @sections = []
        @symbols = []
        @relocation_sections = []
        @dynamic_symbols = []
        @dynamic_entries = []
        @needed = []
        @soname = nil
      end

      def parse!
        parse_header
        parse_sections
        @symbols = symbol_table_by_index[symtab_section&.index] || []
        parse_relocations
        parse_dynamic_symbols
        parse_dynamic
        self
      end

      def relocatable? = @type == ET_REL
      def shared_object? = @type == ET_DYN

      # The first section with the given name, or nil. Section names are not
      # unique in ELF, but the ones this reader is asked about (.text, .symtab,
      # .rela.text, .dynsym, ...) are, so first-match is the useful lookup.
      def section(name)
        @sections.find { |sec| sec.name == name }
      end

      # The first symbol with the given name in .symtab, or nil.
      def symbol(name)
        @symbols.find { |sym| sym.name == name }
      end

      # The first dynamic symbol with the given name in .dynsym, or nil — the
      # export query for a shared object ("is printf here and defined?").
      def dynamic_symbol(name)
        @dynamic_symbols.find { |sym| sym.name == name }
      end

      # The relocations that patch the named section (e.g. "relocations_for('.text')"
      # yields the .rela.text entries), or an empty array.
      def relocations_for(target_name)
        rs = @relocation_sections.find { |r| r.target&.name == target_name }
        rs ? rs.relocations : []
      end

      private

      # --- header ------------------------------------------------------------

      def parse_header
        raise ELFFormatError, "file is too short to hold an ELF header" if @data.bytesize < EHDR_SIZE
        raise ELFFormatError, "bad ELF magic" unless @data.byteslice(0, 4) == ELFMAG

        cls = byte(EI_CLASS)
        raise ELFFormatError, "unsupported ELF class #{cls} (only ELFCLASS64 is supported)" unless cls == ELFCLASS64

        data_enc = byte(EI_DATA)
        raise ELFFormatError, "unsupported ELF data encoding #{data_enc} (only little-endian is supported)" \
          unless data_enc == ELFDATA2LSB

        @type = u16(16)
        @machine = u16(18)
        raise ELFFormatError, "unsupported machine #{@machine} (only EM_X86_64 is supported)" \
          unless @machine == EM_X86_64
        unless [ET_REL, ET_DYN].include?(@type)
          raise ELFFormatError, "unsupported ELF type #{@type} (only ET_REL and ET_DYN are supported)"
        end

        @entry = u64(24)
        @shoff = u64(40)
        @shentsize = u16(58)
        @shnum = u16(60)
        @shstrndx = u16(62)
      end

      # --- sections ----------------------------------------------------------

      def parse_sections
        return if @shoff.zero?

        raise ELFFormatError, "unexpected section header size #{@shentsize}" unless @shentsize == SHDR_SIZE

        # The zeroth section header doubles as an escape hatch for the two 16-bit
        # header fields that can overflow: when e_shnum is 0 the real count lives
        # in its sh_size, and when e_shstrndx is SHN_XINDEX the real index lives
        # in its sh_link. Resolve both before reading the rest.
        count = @shnum
        strndx = @shstrndx
        if count.zero? || strndx == SHN_XINDEX
          first = read_section_header(0)
          count = first.size if count.zero?
          strndx = first.link if strndx == SHN_XINDEX
        end

        # The whole section-header table must lie within the file. e_shnum is a
        # bounded 16-bit field, but the e_shnum==0 escape hatch above takes the
        # count from the zeroth header's 64-bit sh_size, which a hostile object
        # could set enormous to make the map below try to allocate a giant array
        # (or spin reading headers) before any per-entry bound trips. Rejecting a
        # count whose table cannot physically fit stops that up front; a genuine
        # object's table always fits, since the file holds it.
        if count.positive? && @shoff + count * SHDR_SIZE > @data.bytesize
          raise ELFFormatError, "section header table of #{count} entries extends past end of file"
        end

        raw = (0...count).map { |i| read_section_header(i) }
        shstr = raw[strndx] or raise ELFFormatError, "section-name string table index #{strndx} is out of range"
        strtab = section_bytes(shstr)

        @sections = raw.map do |sec|
          sec.name = read_string(strtab, sec.name_offset)
          sec.data = sec.type == SHT_NOBITS || sec.type == SHT_NULL ? nil : section_bytes(sec)
          Section.new(
            index: sec.index, name: sec.name, type: sec.type, flags: sec.flags,
            addr: sec.addr, offset: sec.offset, size: sec.size, link: sec.link,
            info: sec.info, addralign: sec.addralign, entsize: sec.entsize, data: sec.data
          )
        end
      end

      # A raw section header, before its name is resolved. name_offset is the
      # sh_name byte offset into .shstrtab.
      RawSection = Struct.new(
        :index, :name_offset, :name, :type, :flags, :addr, :offset, :size,
        :link, :info, :addralign, :entsize, :data, keyword_init: true
      )

      def read_section_header(index)
        base = @shoff + index * SHDR_SIZE
        require_range(base, SHDR_SIZE, "section header ##{index}")
        RawSection.new(
          index: index,
          name_offset: u32(base),
          type: u32(base + 4),
          flags: u64(base + 8),
          addr: u64(base + 16),
          offset: u64(base + 24),
          size: u64(base + 32),
          link: u32(base + 40),
          info: u32(base + 44),
          addralign: u64(base + 48),
          entsize: u64(base + 56)
        )
      end

      # The file bytes a section occupies. A NOBITS section holds none; every
      # other section must lie wholly within the file.
      def section_bytes(sec)
        return "".b if sec.type == SHT_NOBITS || sec.size.zero?

        require_range(sec.offset, sec.size, "section #{sec.name || sec.index} contents")
        @data.byteslice(sec.offset, sec.size)
      end

      # --- symbols -----------------------------------------------------------

      def symtab_section
        @sections.find { |sec| sec.type == SHT_SYMTAB }
      end

      # Parses every symbol table (.symtab and .dynsym) into arrays keyed by the
      # table's own section index, so a relocation can resolve r_info's symbol
      # through whichever table its RELA section links to. Computed lazily and
      # memoized because both #symbols and the relocation/dynamic passes need it.
      def symbol_table_by_index
        @symbol_table_by_index ||= begin
          tables = {}
          @sections.each do |sec|
            next unless sec.type == SHT_SYMTAB || sec.type == SHT_DYNSYM

            tables[sec.index] = parse_symbols(sec)
          end
          tables
        end
      end

      # Decodes one symbol table section into Symbol value objects. Names resolve
      # through the string table named by sh_link.
      def parse_symbols(sec)
        strtab = string_table_for(sec)
        entsize = sec.entsize.zero? ? SYM_ENTSIZE : sec.entsize
        # `count` cannot run away: parse_sections already validated that this
        # section's [offset, size) span lies within the file (section_bytes), so
        # size — and thus size/entsize — is bounded by the file's own length. The
        # per-entry require_range below is a second, exact guard. (The same holds
        # for parse_rela and parse_dynamic, whose sizes were validated alike.)
        count = sec.size / entsize
        (0...count).map do |i|
          base = sec.offset + i * entsize
          require_range(base, SYM_ENTSIZE, "symbol ##{i} in #{sec.name}")
          st_name = u32(base)
          st_info = byte_at(base + 4)
          st_other = byte_at(base + 5)
          shndx = u16(base + 6)
          Symbol.new(
            index: i,
            name: read_string(strtab, st_name),
            value: u64(base + 8),
            size: u64(base + 16),
            bind: SYM_BINDINGS.fetch(st_info >> 4, st_info >> 4),
            type: SYM_TYPES.fetch(st_info & 0xF, st_info & 0xF),
            visibility: SYM_VISIBILITIES.fetch(st_other & 0x3, st_other & 0x3),
            shndx: shndx,
            section: real_section_index?(shndx) ? @sections[shndx] : nil
          )
        end
      end

      # A st_shndx that names a real entry in the section header table, as
      # opposed to SHN_UNDEF or a reserved high value (SHN_ABS/SHN_COMMON/...).
      def real_section_index?(shndx)
        shndx > SHN_UNDEF && shndx < SHN_LORESERVE && shndx < @sections.size
      end

      # The string table (as bytes) a symbol- or dynamic-section's sh_link points
      # at; empty when the link is absent so name lookups yield "".
      def string_table_for(sec)
        link = @sections[sec.link]
        link ? link.data || "".b : "".b
      end

      # --- relocations -------------------------------------------------------

      def parse_relocations
        @relocation_sections = @sections.select { |sec| sec.type == SHT_RELA }.map do |sec|
          RelocationSection.new(
            section: sec,
            target: @sections[sec.info],
            relocations: parse_rela(sec)
          )
        end
      end

      def parse_rela(sec)
        symbols = symbol_table_by_index[sec.link] || []
        entsize = sec.entsize.zero? ? RELA_ENTSIZE : sec.entsize
        count = sec.size / entsize
        (0...count).map do |i|
          base = sec.offset + i * entsize
          require_range(base, RELA_ENTSIZE, "relocation ##{i} in #{sec.name}")
          r_info = u64(base + 8)
          sym_index = r_info >> 32
          type = r_info & 0xFFFFFFFF
          Relocation.new(
            offset: u64(base),
            type: type,
            type_name: RELOC_TYPES[type],
            symbol: symbols[sym_index],
            addend: s64(base + 16)
          )
        end
      end

      # --- dynamic (.so) -----------------------------------------------------

      def parse_dynamic_symbols
        dynsym = @sections.find { |sec| sec.type == SHT_DYNSYM }
        @dynamic_symbols = dynsym ? symbol_table_by_index[dynsym.index] : []
      end

      # Reads the .dynamic array (tag/value pairs) into DynamicEntry records,
      # then resolves the string-valued tags (DT_SONAME, DT_NEEDED) through
      # .dynstr — the section named by .dynamic's own sh_link.
      def parse_dynamic
        dyn = @sections.find { |sec| sec.type == SHT_DYNAMIC }
        return unless dyn

        strtab = string_table_for(dyn)
        entsize = dyn.entsize.zero? ? DYN_ENTSIZE : dyn.entsize
        count = dyn.size / entsize
        (0...count).each do |i|
          base = dyn.offset + i * entsize
          require_range(base, DYN_ENTSIZE, "dynamic entry ##{i}")
          tag = s64(base)
          val = u64(base + 8)
          break if tag == DT_NULL

          @dynamic_entries << DynamicEntry.new(tag: tag, value: val)
          case tag
          when DT_SONAME then @soname = read_string(strtab, val)
          when DT_NEEDED then @needed << read_string(strtab, val)
          end
        end
      end

      # One .dynamic array element: its raw d_tag and d_un value. String tags'
      # values are byte offsets into .dynstr (resolved into #soname / #needed).
      DynamicEntry = Struct.new(:tag, :value, keyword_init: true)

      # --- primitive reads (all bounds-checked against the image) -------------

      def byte(offset) = @data.getbyte(offset)
      def byte_at(offset)
        require_range(offset, 1, "byte")
        @data.getbyte(offset)
      end

      def u16(offset)
        require_range(offset, 2, "u16")
        @data.byteslice(offset, 2).unpack1("S<")
      end

      def u32(offset)
        require_range(offset, 4, "u32")
        @data.byteslice(offset, 4).unpack1("L<")
      end

      def u64(offset)
        require_range(offset, 8, "u64")
        @data.byteslice(offset, 8).unpack1("Q<")
      end

      def s64(offset)
        require_range(offset, 8, "s64")
        @data.byteslice(offset, 8).unpack1("q<")
      end

      # A NUL-terminated string starting at `offset` within a string table's
      # bytes; an out-of-range offset yields "" rather than raising, since a
      # zero sh_name legitimately points at the leading NUL (the empty name).
      def read_string(strtab, offset)
        return "" if offset >= strtab.bytesize

        stop = strtab.index("\0".b, offset) || strtab.bytesize
        strtab.byteslice(offset...stop).force_encoding(Encoding::UTF_8)
      end

      # Guards every structural read: the whole [offset, length) span must lie
      # within the image, or the file is truncated / self-inconsistent.
      def require_range(offset, length, what)
        if offset.negative? || length.negative? || offset + length > @data.bytesize
          raise ELFFormatError, "#{what} at offset #{offset} (#{length} bytes) extends past end of file"
        end
      end
    end
  end
end
