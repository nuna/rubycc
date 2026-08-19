# frozen_string_literal: true

require "strscan"

require_relative "pp_token"
require_relative "../front/lexeme_reader"
require_relative "../compile_error"

module Rubycc
  module Preprocess
    # Turns raw source into a stream of preprocessing tokens, carrying out
    # translation phases 2 and 3: backslash-newline line splicing and the
    # replacement of comments by whitespace. Newlines survive as explicit tokens
    # so the directive layer (added later) stays line-oriented, and every token
    # keeps the physical location of its first character.
    #
    # Splicing works by deleting every backslash-newline pair up front and
    # remembering where each deletion happened (@splice_points): tokens are then
    # matched over the spliced text with StringScanner-driven regexps — one
    # match per token instead of a method call per character, which is what
    # makes the preprocessor's dominant cost scale. A token's physical
    # line/column stays truthful because the recorded splice points replay the
    # deleted line breaks: everything at or past a splice point is located on
    # the following physical line (see #sync). Positions are byte offsets
    # (StringScanner's native unit); columns are converted back to character
    # counts only when a token is actually made, and only for non-ASCII source.
    #
    # The unit of the whole scan is the *byte*: a C source file is a sequence of
    # bytes (5.1.1.2), not text in whatever encoding the process's locale
    # happens to name, and every construct this scanner recognizes is spelled in
    # the basic character set. Anything else — a UTF-8 comment, a string literal
    # holding non-ASCII bytes, a file that is not valid UTF-8 at all — only has
    # to be carried through, and bytes carry it. #initialize therefore re-tags
    # its input as ASCII-8BIT. That is what makes the compiler independent of
    # Encoding.default_external: reading a header with File.read under a locale
    # of "C" yields a US-ASCII string, and the first regexp or #split over it
    # raises ArgumentError on the first byte past 0x7F (the bundled stddef.h has
    # three, in a comment). Callers that read files hand bytes over already
    # (File.binread); an embedder passing a String gets it re-tagged here, so no
    # entry point can smuggle a locale-dependent encoding past this point.
    class Scanner
      # Two- and one-character punctuators gain the preprocessor-only "##" and
      # "#" over the shared punctuator tables; the three-character set is unchanged.
      PP_PUNCTUATORS_3 = Front::LexemeReader::PUNCTUATORS_3
      PP_PUNCTUATORS_2 = (Front::LexemeReader::PUNCTUATORS_2 + ["##"]).freeze
      PP_PUNCTUATORS_1 = (Front::LexemeReader::PUNCTUATORS_1 + ["#"]).freeze

      # Longest alternative first, so one anchored attempt is a longest match.
      PUNCTUATOR_RE = Regexp.union(PP_PUNCTUATORS_3 + PP_PUNCTUATORS_2 + PP_PUNCTUATORS_1)

      HORIZONTAL_WS_RE = /[ \t\r\v\f]+/
      # A // comment runs to (but not over) the end of the physical line; a
      # trailing backslash-newline was already spliced away, so the comment
      # continues onto the next line just as it does under gcc.
      LINE_COMMENT_RE = %r{//[^\n]*}
      BLOCK_OPEN_RE = %r{/\*}
      BLOCK_CLOSE_RE = %r{\*/}
      NEWLINE_RE = /\n/

      IDENTIFIER_RE = /[A-Za-z_][A-Za-z0-9_]*/
      # A preprocessing number (6.4.8): a digit, or a "." then a digit, and then
      # digits, identifier characters, ".", and a sign immediately after an
      # 'e'/'E'/'p'/'P'. Whether the run is a valid C constant is decided later,
      # at conversion time.
      PP_NUMBER_RE = /(?:[0-9]|\.[0-9])(?:[eEpP][+-]|[0-9A-Za-z_.])*/

      # A string literal or character constant, kept verbatim (quotes and
      # escapes included). Only the boundary is recognized here, matching the
      # streaming lexer: a backslash shields the following character so an
      # escaped quote does not close the literal. An unterminated literal keeps
      # whatever was read (the trailing `("|\)?` picks up a lone backslash cut
      # off by end-of-line or end-of-file); the converter re-scans it and raises
      # the positioned error.
      STRING_RE = /"(?:[^"\\\n]|\\[^\n])*(?:"|\\)?/
      CHAR_RE = /'(?:[^'\\\n]|\\[^\n])*(?:'|\\)?/
      # A wide character constant L'c' or wide string literal L"..." (6.4.4.4,
      # 6.4.5): recognized only when the "L" abuts the quote, so an identifier
      # named "L" is unaffected. The "L" is kept in the spelling so the converter
      # can tell a wide literal from a plain one; it decides a wide character's
      # value (int here, as for a plain constant) and rejects a wide string. The
      # u/U/u8 prefixes are out of scope, so they still scan as an identifier.
      WIDE_CHAR_RE = /L'(?:[^'\\\n]|\\[^\n])*(?:'|\\)?/
      WIDE_STRING_RE = /L"(?:[^"\\\n]|\\[^\n])*(?:"|\\)?/

      # One character that matched no token class above (6.4p1). "Character",
      # not "byte": a lead byte takes the continuation bytes that follow it, so
      # a stray multibyte character stays one token spanning one column. Byte
      # tokens would break the rule that a token's spelling starts at its
      # reported column — a caret would point at the character and the message
      # would name a third of it — and would report one error per byte. A byte
      # that is not UTF-8 at all (a lone continuation byte, or a lead byte with
      # nothing after it) is a token of its own, which keeps the scan total for
      # input that is not UTF-8. Tagged /n because the scanned text is bytes.
      OTHER_RE = /[\xC0-\xFF][\x80-\xBF]*|./n

      # UTF-8 continuation bytes (0b10xxxxxx): the bytes #column_at does not
      # count, so that a multibyte character spans one column. Spelled as a byte
      # range over an ASCII-8BIT string, which is what the scanned text is.
      CONTINUATION_BYTES = "\x80-\xBF".b.freeze

      def initialize(source, filename:)
        @filename = filename
        # The scan is over bytes, so anything handed over as text is re-tagged
        # here — never transcoded (see the class comment).
        source = source.b unless source.encoding == Encoding::BINARY
        # -1 keeps a trailing empty field so line numbers map 1:1 to entries.
        @lines = source.split("\n", -1)
        splice(source)
        @scanner = StringScanner.new(@spliced)
        @ascii_only = @spliced.ascii_only?
        @line = 1
        # Byte offset in @spliced where the current physical line starts; a
        # column is the distance from here (plus one). @column_pos/@column_chars
        # are the incremental cursor #column_at advances (see there); they are
        # only meaningful for non-ASCII source, and reset_line_start resets all
        # three together so they can never drift apart.
        reset_line_start(0)
        # Index into @splice_points of the first point not yet replayed.
        @next_splice = 0
      end

      def scan
        tokens = []
        ss = @scanner
        loop do
          before = ss.pos
          skip_whitespace_and_comments(ss, tokens)
          # Whether any whitespace or comment separated this token from the
          # previous one on the same logical line. The directive layer needs it
          # to tell "#define F(x)" (function-like) from "#define F (x)" (an
          # object macro whose replacement begins with a parenthesis).
          space_before = ss.pos != before
          break if ss.eos?

          start = ss.pos
          sync(start)
          if ss.skip(NEWLINE_RE)
            tokens << make_token(:newline, "\n", @line, column_at(start), space_before)
            @line += 1
            reset_line_start(ss.pos)
          else
            tokens << scan_token(ss, @line, column_at(start), space_before)
          end
        end
        sync(@spliced.bytesize)
        tokens << make_token(:eof, nil, @line, column_at(@spliced.bytesize))
        tokens
      end

      private

      # Translation phase 2: delete every backslash-newline pair, recording for
      # each deletion the byte offset (in the spliced text) where the next
      # physical line begins. Two adjacent continuations record the same offset
      # twice — each still advances the line counter once when replayed. A
      # source with no continuations (the common case) is shared, not copied.
      def splice(source)
        @splice_points = []
        unless source.include?("\\\n")
          @spliced = source
          return
        end
        spliced = +"".b
        pos = 0
        while (idx = source.index("\\\n", pos))
          spliced << source[pos...idx]
          @splice_points << spliced.bytesize
          pos = idx + 2
        end
        spliced << source[pos..]
        @spliced = spliced
      end

      # Replays every splice point at or before byte offset `pos`: each one
      # marks a physical line break the deletion hid, so the line counter
      # advances and the line start moves to the point itself (its first
      # character is column 1 of the continued-onto line). Called with a token's
      # start offset before its location is read, and with interior offsets by
      # the block-comment walk; a point strictly inside a token is replayed when
      # the next token is located, which yields the same stream (a token is
      # located only by its first character).
      def sync(pos)
        points = @splice_points
        while @next_splice < points.length && points[@next_splice] <= pos
          @line += 1
          reset_line_start(points[@next_splice])
          @next_splice += 1
        end
      end

      # Moves the current physical line's start to byte offset `pos`. Every
      # assignment to @line_start goes through here so the column cursor is
      # rebased at the same time — a missed reset would not crash, it would
      # silently report wrong columns (N3).
      def reset_line_start(pos)
        @line_start = pos
        @column_pos = pos
        @column_chars = 0
      end

      # The 1-based column of byte offset `pos`, counted in characters from the
      # current physical line's start. A "character" here is a byte that is not
      # a UTF-8 continuation byte: the scanned text is bytes, so the count
      # cannot be delegated to String#length, and this rule gives the character
      # count exactly for well-formed UTF-8 (the only multibyte encoding a
      # caret-and-column diagnostic can hope to line up on a terminal) while
      # staying defined — one column per byte that can begin a character — for
      # input that is not UTF-8 at all. It is also decomposable, which the
      # incremental cursor below needs: the count over a span is the sum over
      # its parts however the span is cut, even mid-character.
      #
      # A rule that looked at the byte before — "count a
      # continuation byte unless a lead byte precedes it" — would be more
      # accurate on malformed input and would lose exactly that: a span cut
      # between a lead byte and its continuation would be counted one way by
      # the first half and another by the second, and the running total below
      # would drift. The price is paid where the input is not UTF-8 anyway: a
      # lone continuation byte counts as nothing, so two of them report the same
      # column and the rest of that line is reported as many columns short (the
      # answer is pinned in test/test_source_encoding.rb rather than left to be
      # discovered).
      #
      # Byte arithmetic serves ASCII source directly; non-ASCII source has to
      # count characters, and must count them *incrementally*: measuring the
      # whole @line_start..pos span per token costs O(line length) each time, so
      # a single long line of L tokens costs O(L^2) — and one non-ASCII byte
      # anywhere in the file (a comment in Japanese, a UTF-8 BOM) is enough to
      # switch @ascii_only off for all of it. Tokens are located left to right,
      # so keeping the last (byte offset, column) pair as a cursor and counting
      # only the span since then makes a line cost O(line length) in total.
      # Should a caller ever ask for an offset behind the cursor, the count
      # restarts from the line start, so the answer stays right even if that
      # monotonicity is lost.
      def column_at(pos)
        return pos - @line_start + 1 if @ascii_only

        if pos < @column_pos
          @column_pos = @line_start
          @column_chars = 0
        end
        if pos > @column_pos
          span = @spliced.byteslice(@column_pos, pos - @column_pos)
          @column_chars += span.bytesize - span.count(CONTINUATION_BYTES)
          @column_pos = pos
        end
        @column_chars + 1
      end

      # Skips horizontal whitespace and comments (translation phase 3). Newlines
      # are left for the caller so they become tokens; a newline retained inside
      # a block comment is emitted here directly, keeping the logical line count
      # exact for later directive processing.
      def skip_whitespace_and_comments(ss, tokens)
        loop do
          next if ss.skip(HORIZONTAL_WS_RE)
          next if ss.skip(LINE_COMMENT_RE)
          return unless ss.match?(BLOCK_OPEN_RE)

          skip_block_comment(ss, tokens)
        end
      end

      # A /* */ comment, which may span physical lines. Each retained newline it
      # crosses is emitted as a token so the line count stays consistent; a
      # spliced-away continuation inside it adds no token, only a line. An
      # unterminated comment is a hard error, positioned at the opening "/*".
      def skip_block_comment(ss, tokens)
        sync(ss.pos)
        start_line = @line
        start_column = column_at(ss.pos)
        ss.skip(BLOCK_OPEN_RE)
        body = ss.scan_until(BLOCK_CLOSE_RE)
        raise_error("unterminated block comment", start_line, start_column) if body.nil?

        base = ss.pos - body.bytesize
        from = 0
        while (idx = body.byteindex("\n", from))
          at = base + idx
          sync(at)
          tokens << make_token(:newline, "\n", @line, column_at(at))
          @line += 1
          reset_line_start(at + 1)
          from = idx + 1
        end
      end

      # Scans a single preprocessing token (never a newline or whitespace),
      # tagged with the physical location of its first character. One anchored
      # regexp attempt per candidate class, ordered so a prefix can never steal
      # a longer token: a pp-number before "." the punctuator, a wide literal
      # before the identifier "L".
      def scan_token(ss, line, column, space_before)
        if (text = ss.scan(PP_NUMBER_RE))
          type = :pp_number
        elsif (text = ss.scan(IDENTIFIER_RE))
          type = :identifier
          # An "L" abutting a quote is a wide literal, not an identifier.
          if text == "L" && (quoted = ss.scan(CHAR_RE) || ss.scan(STRING_RE))
            type = quoted.start_with?("'") ? :char : :string
            text = "L" + quoted
          end
        elsif (text = ss.scan(CHAR_RE))
          type = :char
        elsif (text = ss.scan(STRING_RE))
          type = :string
        elsif (text = ss.scan(PUNCTUATOR_RE))
          type = :punct
        else
          # Anything that matches nothing above becomes a single-character
          # :other token (6.4p1), deferring the decision of whether it is an
          # error to a later phase.
          type = :other
          text = ss.scan(OTHER_RE)
        end
        make_token(type, text, line, column, space_before)
      end

      def make_token(type, text, line, column, space_before = false)
        PPToken.new(
          type: type,
          text: text,
          filename: @filename,
          line: line,
          column: column,
          source_line: source_line_for(line),
          space_before: space_before
        )
      end

      def source_line_for(line)
        @lines[line - 1] || ""
      end

      def raise_error(description, line, column)
        raise CompileError.new(
          description,
          filename: @filename,
          line: line,
          column: column,
          source_line: source_line_for(line)
        )
      end
    end
  end
end
