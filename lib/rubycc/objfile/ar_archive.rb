# frozen_string_literal: true

module Rubycc
  module ObjFile
    # Raised for any input that is not a well-formed GNU `ar` archive this reader
    # accepts: a bad global magic, a member header that is truncated or missing
    # its `\x60\n` terminator, a non-numeric size field, a size that runs past the
    # end of the file, or a long-name reference that cannot be resolved against
    # the `//` extended-name table. The message names the specific defect so the
    # linker (L3), which reads static libraries through this class, can surface it.
    class ArFormatError < Rubycc::Error; end

    # The eight-byte magic that opens every `ar` archive.
    AR_MAGIC = "!<arch>\n".b

    # A single archive member: its resolved `name`, raw `data` bytes, and the four
    # POSIX metadata fields (`mtime`/`uid`/`gid`/`mode`) the 60-byte header
    # carries. `header_offset` is the byte position of that header in the whole
    # image — the value the symbol index points at, so a symbol can be mapped back
    # to the member that defines it. `special?` marks the two reserved members
    # (`/` symbol table, `//` name table) that are archive metadata rather than
    # real files, so callers listing or extracting members can skip them.
    ArMember = Struct.new(
      :name, :data, :mtime, :uid, :gid, :mode, :header_offset, :special,
      keyword_init: true
    ) do
      def special? = special
    end

    # Reads a GNU-format `ar` archive into its members and (when present) its
    # symbol index. BSD archives are out of scope; only `!<arch>\n` is accepted.
    #
    # The model mirrors ELFReader's load-then-query taste: `read`/`read_file`
    # walk the whole image once into `#members` (in file order) and, if the
    # archive carries one, a symbol name -> member map. That map is exactly what
    # the linker's lazy-extraction driver queries ("which member defines this
    # still-undefined symbol?"), so it is exposed both as the raw ordered
    # `#symbols` list and the first-wins `#symbol_index` hash.
    #
    # Three reserved member names are understood: `/` is the classic ranlib
    # symbol table (big-endian uint32 count, that many big-endian uint32
    # member-header offsets, then NUL-terminated symbol names); `//` is the
    # extended-name table holding long member names each terminated by `/\n`; and
    # `/N` in a member's name field is a decimal byte offset into that `//` table.
    # A short name is stored as `name/`, the trailing slash marking its end so a
    # name may keep trailing spaces. Archives written without a symbol index
    # (plain `ar qc`) are tolerated: `#symbols` is then empty.
    class ArReader
      HEADER_SIZE = 60

      # Field offsets and widths within a 60-byte member header. The five ASCII
      # fields are space-padded; only `size` (decimal) is needed to walk the
      # archive, the rest are decoded for the member's metadata.
      NAME_OFF = 0
      NAME_LEN = 16
      MTIME_OFF = 16
      MTIME_LEN = 12
      UID_OFF = 28
      UID_LEN = 6
      GID_OFF = 34
      GID_LEN = 6
      MODE_OFF = 40
      MODE_LEN = 8
      SIZE_OFF = 48
      SIZE_LEN = 10
      MAGIC_OFF = 58
      HEADER_MAGIC = "\x60\x0a".b

      class << self
        # Parses an in-memory archive (an ASCII-8BIT String) into a ready-to-query
        # reader.
        def read(bytes)
          new(bytes).tap(&:parse!)
        end

        # Reads an archive file from disk and parses it.
        def read_file(path)
          read(File.binread(path))
        end
      end

      attr_reader :members, :symbols, :name_table

      def initialize(bytes)
        @data = bytes.b
        @members = []
        @symbols = []
        @name_table = nil
        @symtab_raw = nil
      end

      def parse!
        unless @data.byteslice(0, AR_MAGIC.bytesize) == AR_MAGIC
          raise ArFormatError, "not an ar archive (bad global magic)"
        end

        pos = AR_MAGIC.bytesize
        # This loop always terminates: parse_member advances pos by at least the
        # 60-byte header plus a non-negative member size (a size field that is not
        # a non-negative decimal is rejected outright), so pos strictly increases
        # by >= 60 each turn and reaches @data.bytesize in a bounded number of
        # steps — a malformed archive cannot make it stall or loop.
        pos = parse_member(pos) while pos < @data.bytesize
        resolve_symbol_index
        self
      end

      # The member with the given name, or nil. Regular members only — the `/`
      # and `//` metadata members never carry a user-facing name.
      def member(name)
        @members.find { |m| !m.special? && m.name == name }
      end

      # symbol name -> defining member, first definition winning when a symbol is
      # exported by more than one member (the order the linker resolves in).
      def symbol_index
        @symbol_index ||= @symbols.each_with_object({}) do |entry, map|
          map[entry[:name]] ||= entry[:member]
        end
      end

      # The member that defines `symbol_name`, or nil — the query the lazy linker
      # asks for each still-undefined reference.
      def member_defining(symbol_name)
        symbol_index[symbol_name]
      end

      private

      # Parses one member starting at `pos` and returns the offset of the next
      # member (past the even-boundary padding byte). The `/` and `//` reserved
      # members are recorded like any other but flagged special and, for `//`,
      # captured as the name table so later `/N` references resolve.
      def parse_member(pos)
        if pos + HEADER_SIZE > @data.bytesize
          raise ArFormatError, "truncated member header at offset #{pos}"
        end

        header = @data.byteslice(pos, HEADER_SIZE)
        unless header.byteslice(MAGIC_OFF, 2) == HEADER_MAGIC
          raise ArFormatError, "member header at offset #{pos} lacks its `\\x60\\n` terminator"
        end

        size = decimal_field(header, SIZE_OFF, SIZE_LEN, "size", pos)
        data_off = pos + HEADER_SIZE
        if data_off + size > @data.bytesize
          raise ArFormatError, "member at offset #{pos} declares #{size} bytes running past end of file"
        end
        data = @data.byteslice(data_off, size)

        raw_name = header.byteslice(NAME_OFF, NAME_LEN)
        kind, resolved = classify_name(raw_name, pos)

        case kind
        when :symtab
          @symtab_raw = data
        when :nametable
          @name_table = data
        end

        @members << ArMember.new(
          name: resolved,
          data: data,
          mtime: decimal_field(header, MTIME_OFF, MTIME_LEN, "mtime", pos, allow_blank: true),
          uid: decimal_field(header, UID_OFF, UID_LEN, "uid", pos, allow_blank: true),
          gid: decimal_field(header, GID_OFF, GID_LEN, "gid", pos, allow_blank: true),
          mode: octal_field(header, MODE_OFF, MODE_LEN, pos),
          header_offset: pos,
          special: kind == :symtab || kind == :nametable
        )

        # Member data is padded with a single `\n` to an even offset; the size
        # field counts only the real bytes, so an odd size means one pad byte.
        data_off + size + (size.odd? ? 1 : 0)
      end

      # Decodes the 16-byte name field into [kind, name]. `/` alone is the symbol
      # table, `//` the extended-name table, `/N` a long-name reference resolved
      # through that table, and anything else a short `name/` (or, defensively, a
      # bare name) with its trailing slash stripped.
      def classify_name(raw_name, pos)
        trimmed = raw_name.rstrip
        if trimmed == "/"
          [:symtab, "/"]
        elsif trimmed == "//"
          [:nametable, "//"]
        elsif trimmed.start_with?("/") && trimmed.byteslice(1..).match?(/\A\d+\z/)
          [:long, resolve_long_name(trimmed.byteslice(1..).to_i, pos)]
        else
          [:short, trimmed.chomp("/")]
        end
      end

      # Resolves a `/N` reference: read from byte `offset` in the `//` table up to
      # the terminating `\n` and drop the trailing `/` GNU appends to each entry.
      def resolve_long_name(offset, pos)
        table = @name_table or
          raise ArFormatError, "member at offset #{pos} references a name table that is absent"
        if offset >= table.bytesize
          raise ArFormatError, "member at offset #{pos} references name-table offset #{offset} out of range"
        end

        stop = table.index("\n".b, offset) || table.bytesize
        table.byteslice(offset...stop).chomp("/").force_encoding(Encoding::UTF_8)
      end

      # Turns the raw `/` symbol table into name -> member entries. Deferred until
      # every member's header_offset is known so each big-endian offset can be
      # matched to the member it names. A symbol pointing at an unknown offset is
      # skipped rather than fatal — a stale index should not sink an otherwise
      # readable archive.
      def resolve_symbol_index
        return if @symtab_raw.nil? || @symtab_raw.bytesize < 4

        by_offset = @members.each_with_object({}) { |m, h| h[m.header_offset] = m }
        count = @symtab_raw.byteslice(0, 4).unpack1("N")
        offsets_end = 4 + count * 4
        return if offsets_end > @symtab_raw.bytesize

        offsets = @symtab_raw.byteslice(4, count * 4).unpack("N*")
        names_blob = @symtab_raw.byteslice(offsets_end..) || "".b

        cursor = 0
        count.times do |i|
          stop = names_blob.index("\0".b, cursor) or break
          name = names_blob.byteslice(cursor...stop).force_encoding(Encoding::UTF_8)
          cursor = stop + 1
          member = by_offset[offsets[i]]
          @symbols << { name: name, member: member } if member
        end
      end

      # Reads a space-padded ASCII decimal field. A field of all spaces decodes to
      # 0 when `allow_blank` (GNU leaves the deterministic uid/gid/mtime blank in
      # some writers); a non-numeric size or similar is a format error.
      def decimal_field(header, offset, length, what, pos, allow_blank: false)
        text = header.byteslice(offset, length).strip
        return 0 if text.empty? && allow_blank
        unless text.match?(/\A\d+\z/)
          raise ArFormatError, "member at offset #{pos} has a non-numeric #{what} field #{text.inspect}"
        end

        text.to_i
      end

      # Reads the octal mode field; a blank field means 0.
      def octal_field(header, offset, length, pos)
        text = header.byteslice(offset, length).strip
        return 0 if text.empty?
        unless text.match?(/\A[0-7]+\z/)
          raise ArFormatError, "member at offset #{pos} has a non-octal mode field #{text.inspect}"
        end

        text.to_i(8)
      end
    end

    # Builds a GNU-format `ar` archive. The counterpart of ArReader, mirroring
    # ELFWriter's builder taste: members are appended in order with #add_member
    # and the whole image is assembled by #to_binary.
    #
    # Every archive is written with a classic ranlib symbol index as its first
    # `/` member (always, even when empty), so output is a drop-in for `ar rcs`
    # and the linker can extract lazily. The index's symbols are gathered by
    # handing each member's bytes to ELFReader and taking its defined global and
    # weak symbols; a member ELFReader cannot parse (a non-ELF file) simply
    # contributes none. Long member names (over 15 characters, once the trailing
    # `/` is counted) move to a `//` extended-name table and are referenced by a
    # `/N` byte offset; shorter names are stored inline as `name/`.
    #
    # Output is fully deterministic (N4): mtime, uid and gid are pinned to 0 and
    # the mode to 0644 (the metadata GNU `ar` writes in deterministic mode), so
    # identical member bytes always produce a byte-identical archive.
    class ArWriter
      # Pinned deterministic member metadata. The reserved `/` and `//` members
      # carry a 0 mode, matching GNU.
      DETERMINISTIC_MTIME = "0"
      DETERMINISTIC_UID = "0"
      DETERMINISTIC_GID = "0"
      REGULAR_MODE = "644"
      SPECIAL_MODE = "0"

      # A name plus its trailing-slash form fits inline when at most this many
      # bytes; a longer name goes to the `//` table.
      INLINE_NAME_CAPACITY = 16

      def initialize
        @members = []
      end

      # Appends a member with the given name and raw data. Names are not
      # de-duplicated here — replace-or-append is the CLI's job; the writer lays
      # out exactly what it is given, in order.
      def add_member(name, data)
        @members << { name: name.to_s, data: data.b }
        self
      end

      # Assembles and returns the archive as an ASCII-8BIT String.
      def to_binary
        entries = @members.map { |m| { name: m[:name], data: m[:data], symbols: gather_symbols(m[:data]) } }

        name_table, name_field = build_name_table(entries)
        flat_symbols = flatten_symbols(entries)
        symtab_size = symtab_byte_size(flat_symbols)

        # The symbol index and the name table precede every regular member, so
        # each regular member's header offset — the value the index records — is
        # known once their spans are summed. The index's own size depends only on
        # the symbol count and names, not on the offsets it will hold, so there is
        # no circular dependency.
        base = AR_MAGIC.bytesize + member_span(symtab_size)
        base += member_span(name_table.bytesize) unless name_table.empty?
        offset = base
        entries.each do |entry|
          entry[:header_offset] = offset
          offset += member_span(entry[:data].bytesize)
        end

        symtab = build_symtab(flat_symbols, entries)

        out = +"".b
        out << AR_MAGIC
        emit_member(out, "/", symtab, SPECIAL_MODE)
        emit_member(out, "//", name_table, SPECIAL_MODE) unless name_table.empty?
        entries.each { |entry| emit_member(out, name_field[entry.object_id], entry[:data], REGULAR_MODE) }
        out
      end

      # Convenience: assemble and write the archive to `path`.
      def write(path)
        File.binwrite(path, to_binary)
      end

      private

      # The defined global and weak symbol names an ELF member exports, gathered
      # through ELFReader so no ELF is re-parsed by hand. A non-ELF member (or one
      # ELFReader rejects) contributes nothing.
      def gather_symbols(data)
        reader = ELFReader.read(data)
        reader.symbols.select do |sym|
          (sym.bind == :global || sym.bind == :weak) && !sym.undefined? && !sym.name.to_s.empty?
        end.map(&:name)
      rescue ELFFormatError
        []
      end

      # Assigns every member a name field, moving long names into the `//` table.
      # Returns [table_bytes, entry.object_id -> name field]. A name fits inline
      # when `name/` is at most 16 bytes; otherwise it is appended to the table
      # (terminated by `/\n`, GNU's convention) and referenced by `/offset`.
      def build_name_table(entries)
        table = +"".b
        fields = {}
        entries.each do |entry|
          name = entry[:name]
          if name.bytesize + 1 > INLINE_NAME_CAPACITY
            fields[entry.object_id] = "/#{table.bytesize}"
            table << name.b << "/\n".b
          else
            fields[entry.object_id] = "#{name}/"
          end
        end
        [table, fields]
      end

      # Flattens every member's symbols into [name, entry] pairs in member order,
      # so the index lists a member's exports contiguously and points them all at
      # that member's header.
      def flatten_symbols(entries)
        entries.flat_map { |entry| entry[:symbols].map { |name| [name, entry] } }
      end

      # The `/` symbol table's byte size: the uint32 count, one uint32 per symbol
      # offset, then each NUL-terminated name.
      def symtab_byte_size(flat_symbols)
        4 + 4 * flat_symbols.size + flat_symbols.sum { |(name, _)| name.bytesize + 1 }
      end

      # Builds the `/` symbol table body once member header offsets are fixed:
      # big-endian count, big-endian member-header offsets, then the names.
      def build_symtab(flat_symbols, _entries)
        buf = +"".b
        buf << [flat_symbols.size].pack("N")
        flat_symbols.each { |(_, entry)| buf << [entry[:header_offset]].pack("N") }
        flat_symbols.each { |(name, _)| buf << name.b << "\0".b }
        buf
      end

      # The whole-file span a member occupies: its 60-byte header, its data, and
      # the single `\n` pad that keeps the next member on an even offset.
      def member_span(data_size)
        HEADER_SIZE + data_size + (data_size.odd? ? 1 : 0)
      end

      HEADER_SIZE = 60

      # Appends a member (header, data, and the even-boundary pad byte) to `out`.
      def emit_member(out, name_field, data, mode)
        out << member_header(name_field, data.bytesize, mode)
        out << data
        out << "\n".b if data.bytesize.odd?
      end

      # A 60-byte member header. Every ASCII field is left-justified and
      # space-padded; the deterministic metadata is pinned and only name, size and
      # mode vary between members.
      def member_header(name_field, size, mode)
        header = +"".b
        header << pad(name_field, NAME_LEN)
        header << pad(DETERMINISTIC_MTIME, MTIME_LEN)
        header << pad(DETERMINISTIC_UID, UID_LEN)
        header << pad(DETERMINISTIC_GID, GID_LEN)
        header << pad(mode, MODE_LEN)
        header << pad(size.to_s, SIZE_LEN)
        header << HEADER_MAGIC
        header
      end

      NAME_LEN = 16
      MTIME_LEN = 12
      UID_LEN = 6
      GID_LEN = 6
      MODE_LEN = 8
      SIZE_LEN = 10
      HEADER_MAGIC = "\x60\x0a".b

      def pad(text, width)
        bytes = text.to_s.b
        raise ArFormatError, "field #{text.inspect} exceeds #{width} bytes" if bytes.bytesize > width

        bytes + (" ".b * (width - bytes.bytesize))
      end
    end
  end
end
