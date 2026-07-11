# frozen_string_literal: true

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
    # Line splicing is handled inside the character cursor rather than by
    # rewriting the source string: the cursor transparently steps over a
    # backslash-newline pair while advancing the physical line counter, so a
    # token split across a continuation still reports a truthful line/column and
    # source excerpt (rewriting the string first would corrupt those columns).
    class Scanner
      # Two- and one-character punctuators gain the preprocessor-only "##" and
      # "#" over the shared punctuator tables; the three-character set is unchanged.
      PP_PUNCTUATORS_3 = Front::LexemeReader::PUNCTUATORS_3
      PP_PUNCTUATORS_2 = (Front::LexemeReader::PUNCTUATORS_2 + ["##"]).freeze
      PP_PUNCTUATORS_1 = (Front::LexemeReader::PUNCTUATORS_1 + ["#"]).freeze

      def initialize(source, filename:)
        @src = source
        @filename = filename
        @pos = 0
        @line = 1
        @column = 1
        # -1 keeps a trailing empty field so line numbers map 1:1 to entries.
        @lines = source.split("\n", -1)
        # Establish the invariant that the cursor never rests on a spliced
        # backslash-newline, so #current_char always yields a logical character.
        consume_splices
      end

      def scan
        tokens = []
        loop do
          before = @pos
          skip_whitespace_and_comments(tokens)
          # Whether any whitespace or comment separated this token from the
          # previous one on the same logical line. The directive layer needs it
          # to tell "#define F(x)" (function-like) from "#define F (x)" (an
          # object macro whose replacement begins with a parenthesis).
          space_before = @pos != before
          break if at_end?

          if current_char == "\n"
            line = @line
            column = @column
            advance
            tokens << make_token(:newline, "\n", line, column, space_before)
          else
            tokens << scan_token(space_before)
          end
        end
        tokens << make_token(:eof, nil, @line, @column)
        tokens
      end

      private

      def at_end?
        @pos >= @src.length
      end

      # The logical character at the cursor. The splice invariant guarantees it
      # is never the backslash of a line continuation.
      def current_char
        @src[@pos]
      end

      # The logical character `offset` positions ahead, stepping over any line
      # continuations in between without disturbing the cursor.
      def peek(offset = 1)
        pos = @pos
        offset.times { pos = skip_splices_at(pos + 1) }
        @src[pos]
      end

      # Consumes one logical character, advancing the physical line/column and
      # then re-establishing the splice invariant so the cursor lands on the next
      # logical character.
      def advance
        ch = @src[@pos]
        @pos += 1
        if ch == "\n"
          @line += 1
          @column = 1
        else
          @column += 1
        end
        consume_splices
        ch
      end

      # Steps the cursor over any run of backslash-newline pairs at the current
      # position (translation phase 2), advancing the physical line counter so a
      # continued line is still located truthfully.
      def consume_splices
        while @src[@pos] == "\\" && @src[@pos + 1] == "\n"
          @pos += 2
          @line += 1
          @column = 1
        end
      end

      # The first position at or after `pos` that is not the backslash of a line
      # continuation; used for read-only lookahead.
      def skip_splices_at(pos)
        pos += 2 while @src[pos] == "\\" && @src[pos + 1] == "\n"
        pos
      end

      # Skips horizontal whitespace and comments (translation phase 3). Newlines
      # are left for the caller so they become tokens; a newline retained inside
      # a block comment is emitted here directly, keeping the logical line count
      # exact for later directive processing.
      def skip_whitespace_and_comments(tokens)
        loop do
          ch = current_char
          if ch.nil? || ch == "\n"
            return
          elsif horizontal_whitespace?(ch)
            advance
          elsif ch == "/" && peek == "/"
            skip_line_comment
          elsif ch == "/" && peek == "*"
            skip_block_comment(tokens)
          else
            return
          end
        end
      end

      def horizontal_whitespace?(ch)
        ch == " " || ch == "\t" || ch == "\r" || ch == "\v" || ch == "\f"
      end

      # A // comment runs to (but not over) the end of the physical line. A
      # trailing backslash-newline is spliced by the cursor, so the comment
      # continues onto the next line just as it does under gcc.
      def skip_line_comment
        advance # first /
        advance # second /
        advance until at_end? || current_char == "\n"
      end

      # A /* */ comment, which may span physical lines. Each retained newline it
      # crosses is emitted as a token so the line count stays consistent; a
      # backslash-newline continuation inside it is spliced away (no token). An
      # unterminated comment is a hard error.
      def skip_block_comment(tokens)
        start_line = @line
        start_col = @column
        advance # /
        advance # *
        loop do
          if at_end?
            raise_error("unterminated block comment", start_line, start_col)
          elsif current_char == "*" && peek == "/"
            advance # *
            advance # /
            return
          elsif current_char == "\n"
            line = @line
            column = @column
            advance
            tokens << make_token(:newline, "\n", line, column)
          else
            advance
          end
        end
      end

      # Scans a single preprocessing token (never a newline or whitespace),
      # tagging it with the physical location of its first character.
      def scan_token(space_before)
        line = @line
        column = @column
        ch = current_char

        type, text =
          if ch =~ /[0-9]/
            scan_pp_number
          elsif ch == "." && peek =~ /[0-9]/
            scan_pp_number
          elsif ch =~ /[A-Za-z_]/
            scan_identifier
          elsif ch == "'"
            scan_char_constant
          elsif ch == "\""
            scan_string_literal
          else
            scan_punctuator
          end
        make_token(type, text, line, column, space_before)
      end

      def scan_identifier
        text = +""
        text << advance while identifier_char?(current_char)
        [:identifier, text]
      end

      # A preprocessing number (6.4.8): starts with a digit, or a "." then a
      # digit, and then admits digits, identifier characters, ".", and a sign
      # immediately after an 'e'/'E'/'p'/'P'. Whether the run is a valid C
      # constant is decided later, at conversion time.
      def scan_pp_number
        text = +""
        text << advance # leading digit or "."
        loop do
          ch = current_char
          break if ch.nil?

          if (ch == "+" || ch == "-")
            break unless "eEpP".include?(text[-1])

            text << advance
          elsif ch =~ /[0-9A-Za-z_.]/
            text << advance
          else
            break
          end
        end
        [:pp_number, text]
      end

      # A string literal or character constant, kept verbatim (quotes and escapes
      # included). Only the boundary is recognized here, matching the streaming
      # lexer: a backslash shields the following character so an escaped quote
      # does not close the literal. An unterminated literal keeps whatever was
      # read; the converter re-scans it and raises the positioned error.
      def scan_string_literal
        [:string, scan_quoted("\"")]
      end

      def scan_char_constant
        [:char, scan_quoted("'")]
      end

      def scan_quoted(quote)
        text = +""
        text << advance # opening quote
        loop do
          ch = current_char
          if ch.nil? || ch == "\n"
            break
          elsif ch == "\\"
            text << advance # backslash
            nxt = current_char
            break if nxt.nil? || nxt == "\n"

            text << advance # shielded character
          elsif ch == quote
            text << advance # closing quote
            break
          else
            text << advance
          end
        end
        text
      end

      # Longest-match punctuator scan over the preprocessor tables. Anything that
      # matches no punctuator becomes a single-character :other token (6.4p1),
      # deferring the decision of whether it is an error to a later phase.
      def scan_punctuator
        three = "#{current_char}#{peek(1)}#{peek(2)}"
        two = "#{current_char}#{peek(1)}"
        if PP_PUNCTUATORS_3.include?(three)
          [:punct, advance_n(3)]
        elsif PP_PUNCTUATORS_2.include?(two)
          [:punct, advance_n(2)]
        elsif PP_PUNCTUATORS_1.include?(current_char)
          [:punct, advance]
        else
          [:other, advance]
        end
      end

      # Consumes `count` logical characters and returns their spelling.
      def advance_n(count)
        text = +""
        count.times { text << advance }
        text
      end

      def identifier_char?(ch)
        !ch.nil? && ch.match?(/[A-Za-z0-9_]/)
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
