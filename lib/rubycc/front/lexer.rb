# frozen_string_literal: true

require_relative "token"
require_relative "../compile_error"

module Rubycc
  module Front
    # Hand-written lexer for the C subset. Tracks 1-based line/column positions
    # and keeps each source line around so tokens (and errors) can be reported
    # with source excerpts. Handles // and /* */ comments and whitespace.
    class Lexer
      KEYWORDS = %w[int char void struct return if else while do for break continue
                    switch case default goto sizeof].freeze

      # Escape sequences shared by character constants and string literals,
      # mapping the letter after the backslash to the byte value it denotes.
      ESCAPES = {
        "n" => 10, "t" => 9, "r" => 13, "0" => 0, "\\" => 92,
        "'" => 39, "\"" => 34, "a" => 7, "b" => 8, "f" => 12, "v" => 11
      }.freeze

      # Three-character punctuators, matched before the shorter lists so the
      # longest one always wins: "<<=" must beat "<<" (and "<="/"<"), and
      # ">>=" must beat ">>" (and ">="/">"). These are the two compound shift
      # assignments; no other punctuator in this subset is three characters.
      PUNCTUATORS_3 = %w[<<= >>=].freeze

      # Two-character punctuators, matched before the single-character list so
      # the lexer always prefers the longest punctuator ("==" over two "=",
      # "&&" over two "&", "++" or "+=" over a lone "+", "->" over a lone "-",
      # "<<" over two "<", "&=" over "&"/"&&").
      PUNCTUATORS_2 = %w[== != <= >= && || += -= *= /= %= ++ -- -> << >> &= |= ^=].freeze

      # Single-character punctuators used by this slice. "&" is both the
      # address-of operator and the bitwise-and operator, "*" doubles as
      # dereference and pointer-declarator marker, "|" "^" "~" are the remaining
      # bitwise operators, "[" "]" bracket array declarators and subscripts,
      # "?" ":" form the conditional operator, and "." selects a struct member.
      PUNCTUATORS_1 = %w[+ - * / % ( ) { } ; = , < > ! & | ^ ~ [ ] ? : .].freeze

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
          lex_number(line, column)
        elsif ch =~ /[A-Za-z_]/
          lex_identifier(line, column)
        elsif ch == "'"
          lex_character_constant(line, column)
        elsif ch == "\""
          lex_string_literal(line, column)
        else
          lex_punctuator(line, column)
        end
      end

      # A character constant 'c' or '\n': lexed as a :num token whose value is
      # the character's byte code, since an ISO C character constant has type
      # int. The constant must hold exactly one character; an empty '', a
      # multi-character 'ab', an unterminated ' and an unknown escape are all
      # rejected with a positioned error.
      def lex_character_constant(line, column)
        advance # opening quote
        if at_end? || current_char == "\n"
          raise_error("unterminated character constant", line, column)
        elsif current_char == "'"
          raise_error("empty character constant", line, column)
        end
        value = read_escaped_byte(line, column, "character constant")
        if at_end? || current_char == "\n"
          raise_error("unterminated character constant", line, column)
        elsif current_char != "'"
          raise_error("multi-character character constant", line, column)
        end
        advance # closing quote
        make_token(:num, value, line, column)
      end

      # A string literal "abc": lexed as a :string token whose value is the
      # escape-resolved bytes (ASCII-8BIT), without the NUL terminator the
      # generator later appends. An unterminated literal (newline or EOF before
      # the closing quote) and an unknown escape are rejected.
      def lex_string_literal(line, column)
        advance # opening quote
        bytes = +"".b
        loop do
          if at_end? || current_char == "\n"
            raise_error("unterminated string literal", line, column)
          end
          break if current_char == "\""

          bytes << read_escaped_byte(line, column, "string literal")
        end
        advance # closing quote
        make_token(:string, bytes, line, column)
      end

      # Reads one logical character at the cursor and returns its byte value,
      # decoding a backslash escape via ESCAPES. Shared by character constants
      # and string literals; `context` names the construct for error messages.
      def read_escaped_byte(start_line, start_col, context)
        ch = current_char
        if ch.nil? || ch == "\n"
          raise_error("unterminated #{context}", start_line, start_col)
        elsif ch == "\\"
          advance # backslash
          esc = current_char
          if esc.nil? || esc == "\n"
            raise_error("unterminated #{context}", start_line, start_col)
          end
          code = ESCAPES[esc]
          raise_error("unknown escape sequence in #{context}", start_line, start_col) unless code

          advance
          code
        else
          advance
          ch.ord
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
        if PUNCTUATORS_3.include?(three)
          advance
          advance
          advance
          make_token(:punct, three, line, column)
        elsif PUNCTUATORS_2.include?(two)
          advance
          advance
          make_token(:punct, two, line, column)
        elsif PUNCTUATORS_1.include?(current_char)
          ch = advance
          make_token(:punct, ch, line, column)
        else
          raise_error("unexpected character #{current_char.inspect}", line, column)
        end
      end

      def lex_number(line, column)
        digits = +""
        digits << advance while !at_end? && current_char =~ /[0-9]/
        # A digit immediately followed by an identifier char is not a valid
        # integer token in this subset (e.g. 12abc).
        if !at_end? && current_char =~ /[A-Za-z_]/
          raise_error("invalid digit in number", @line, @column)
        end
        make_token(:num, digits.to_i, line, column)
      end

      def lex_identifier(line, column)
        name = +""
        name << advance while !at_end? && current_char =~ /[A-Za-z0-9_]/
        type = KEYWORDS.include?(name) ? :keyword : :ident
        make_token(type, name, line, column)
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
