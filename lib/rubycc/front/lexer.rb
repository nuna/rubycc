# frozen_string_literal: true

require_relative "token"
require_relative "../compile_error"

module Rubycc
  module Front
    # Hand-written lexer for the C subset. Tracks 1-based line/column positions
    # and keeps each source line around so tokens (and errors) can be reported
    # with source excerpts. Handles // and /* */ comments and whitespace.
    class Lexer
      KEYWORDS = %w[int void return if else while do for break continue sizeof].freeze

      # Two-character punctuators, matched before the single-character list so
      # the lexer always prefers the longest punctuator ("==" over two "=",
      # "&&" over two "&", "++" or "+=" over a lone "+").
      PUNCTUATORS_2 = %w[== != <= >= && || += -= *= /= %= ++ --].freeze

      # Single-character punctuators used by this slice. "&" is the address-of
      # operator, "*" doubles as dereference and pointer-declarator marker,
      # "[" "]" bracket array declarators and subscripts, and "?" ":" form the
      # conditional operator.
      PUNCTUATORS_1 = %w[+ - * / % ( ) { } ; = , < > ! & [ ] ? :].freeze

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
        else
          lex_punctuator(line, column)
        end
      end

      # Longest-match punctuator scan: try the two-character punctuators first,
      # then fall back to the single-character ones.
      def lex_punctuator(line, column)
        two = "#{current_char}#{peek(1)}"
        if PUNCTUATORS_2.include?(two)
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
