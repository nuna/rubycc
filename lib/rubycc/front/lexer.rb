# frozen_string_literal: true

require_relative "token"
require_relative "lexeme_reader"
require_relative "../compile_error"

module Rubycc
  module Front
    # Hand-written lexer for the C subset. Tracks 1-based line/column positions
    # and keeps each source line around so tokens (and errors) can be reported
    # with source excerpts. Handles // and /* */ comments and whitespace. The
    # spelling-to-value decoding of numbers, string/character literals and
    # identifiers is delegated to the shared LexemeReader, which the preprocessor
    # reuses so both token sources agree exactly.
    class Lexer
      def initialize(source, filename:)
        @src = source
        @filename = filename
        @pos = 0
        @line = 1
        @column = 1
        # -1 keeps a trailing empty field, so line numbers map 1:1 to entries.
        @lines = source.split("\n", -1)
      end

      def tokenize
        tokens = []
        loop do
          skip_whitespace_and_comments
          break if at_end?

          tokens << next_token
        end
        tokens << make_token(:eof, nil, @line, @column)
        tokens
      end

      private

      def at_end?
        @pos >= @src.length
      end

      def current_char
        @src[@pos]
      end

      def peek(offset = 0)
        @src[@pos + offset]
      end

      # Consumes one character, maintaining line/column bookkeeping.
      def advance
        ch = @src[@pos]
        @pos += 1
        if ch == "\n"
          @line += 1
          @column = 1
        else
          @column += 1
        end
        ch
      end

      def skip_whitespace_and_comments
        loop do
          ch = current_char
          if ch.nil?
            return
          elsif ch =~ /\s/
            advance
          elsif ch == "/" && peek(1) == "/"
            advance until at_end? || current_char == "\n"
          elsif ch == "/" && peek(1) == "*"
            skip_block_comment
          else
            return
          end
        end
      end

      def skip_block_comment
        start_line = @line
        start_col = @column
        advance # /
        advance # *
        loop do
          if at_end?
            raise_error("unterminated block comment", start_line, start_col)
          elsif current_char == "*" && peek(1) == "/"
            advance # *
            advance # /
            return
          else
            advance
          end
        end
      end

      def next_token
        line = @line
        column = @column
        ch = current_char

        if ch =~ /[0-9]/
          read_lexeme(:read_number, line, column)
        elsif ch == "." && peek(1) =~ /[0-9]/
          # A leading-dot floating constant (".5"): a "." immediately followed
          # by a digit is the fractional-only form. A "." in any other position
          # is the member-access punctuator (or part of "..."), handled by
          # #lex_punctuator.
          read_lexeme(:read_number, line, column)
        elsif ch =~ /[A-Za-z_]/
          read_lexeme(:read_identifier, line, column)
        elsif ch == "'"
          read_lexeme(:read_char, line, column)
        elsif ch == "\""
          read_lexeme(:read_string, line, column)
        else
          lex_punctuator(line, column)
        end
      end

      # Decodes one lexeme with the shared LexemeReader, then walks the streaming
      # cursor over the exact characters it consumed so line/column bookkeeping
      # stays correct. A LexError from the reader carries an absolute offset into
      # the source, which maps to a column on this (single) line since none of
      # these lexemes span a newline.
      def read_lexeme(method, line, column)
        start = @pos
        reader = LexemeReader.new(@src, start)
        begin
          result = reader.public_send(method)
        rescue LexError => e
          raise_error(e.message, line, column + (e.offset - start))
        end
        advance while @pos < reader.pos
        build_token(result, line, column)
      end

      def build_token(result, line, column)
        case result.type
        when :num
          make_num_token(result.value, result.base, result.suffix, line, column)
        when :float
          make_float_token(result.value, result.suffix, line, column)
        else
          make_token(result.type, result.value, line, column)
        end
      end

      # Longest-match punctuator scan: try the three-character punctuators
      # first, then the two-character ones, then fall back to the
      # single-character ones. peek(1)/peek(2) yield nil past the end, which
      # interpolate to "", so the assembled candidates simply fail to match near
      # EOF and the scan falls through to a shorter length.
      def lex_punctuator(line, column)
        three = "#{current_char}#{peek(1)}#{peek(2)}"
        two = "#{current_char}#{peek(1)}"
        if LexemeReader::PUNCTUATORS_3.include?(three)
          advance
          advance
          advance
          make_token(:punct, three, line, column)
        elsif LexemeReader::PUNCTUATORS_2.include?(two)
          advance
          advance
          make_token(:punct, two, line, column)
        elsif LexemeReader::PUNCTUATORS_1.include?(current_char)
          ch = advance
          make_token(:punct, ch, line, column)
        else
          raise_error("unexpected character #{current_char.inspect}", line, column)
        end
      end

      def make_token(type, value, line, column)
        Token.new(
          type: type,
          value: value,
          filename: @filename,
          line: line,
          column: column,
          source_line: source_line_for(line)
        )
      end

      # A :num token carrying the extra base/suffix an integer constant needs
      # for the parser to fix its type.
      def make_num_token(value, base, suffix, line, column)
        Token.new(
          type: :num,
          value: value,
          filename: @filename,
          line: line,
          column: column,
          source_line: source_line_for(line),
          base: base,
          suffix: suffix
        )
      end

      # A :float token carrying the folded Ruby Float value and the normalized
      # floating suffix the parser fixes the constant's type from.
      def make_float_token(value, suffix, line, column)
        Token.new(
          type: :float,
          value: value,
          filename: @filename,
          line: line,
          column: column,
          source_line: source_line_for(line),
          suffix: suffix
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
