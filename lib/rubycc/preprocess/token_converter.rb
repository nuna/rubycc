# frozen_string_literal: true

require_relative "pp_token"
require_relative "../front/token"
require_relative "../front/lexeme_reader"
require_relative "../compile_error"

module Rubycc
  module Preprocess
    # Ends translation phase 4 by turning preprocessing tokens into the
    # Front::Token stream the parser consumes. Numbers are folded, string and
    # character literals decoded, and identifiers classified as keywords, all via
    # the shared LexemeReader so the result matches the streaming lexer exactly.
    # Newlines are dropped here; a "#"/"##" that survives to this point is a
    # stray operator with no macro meaning (directive lines are diagnosed
    # earlier), so it is rejected.
    class TokenConverter
      def convert(pp_tokens)
        tokens = []
        pp_tokens.each do |pp|
          case pp.type
          when :newline
            next
          when :eof
            tokens << front_token(pp, :eof, nil)
          when :identifier
            type = Front::LexemeReader.keyword?(pp.text) ? :keyword : :ident
            tokens << front_token(pp, type, pp.text)
          when :pp_number
            tokens << convert_number(pp)
          when :string
            result = decode(pp) { |reader| reader.read_string }
            tokens << front_token(pp, :string, result.value)
          when :char
            result = decode(pp) { |reader| reader.read_char }
            tokens << num_token(pp, result.value, 10, "")
          when :punct
            if pp.text == "#" || pp.text == "##"
              raise_at(pp, "stray '#' in program")
            end
            tokens << front_token(pp, :punct, pp.text)
          when :other
            raise_at(pp, "unexpected character #{pp.text.inspect}")
          end
        end
        tokens
      end

      private

      # Folds a preprocessing number into a :num or :float token. A pp-number is
      # broader than a C constant, so an ill-formed one (e.g. "12abc", "1.2.3")
      # is rejected here rather than at scan time.
      def convert_number(pp)
        result = decode(pp) { |reader| reader.read_number }
        if result.type == :float
          Front::Token.new(
            type: :float, value: result.value,
            filename: pp.filename, line: pp.line, column: pp.column,
            source_line: pp.source_line, suffix: result.suffix
          )
        else
          num_token(pp, result.value, result.base, result.suffix)
        end
      end

      # Runs a LexemeReader over the preprocessing token's spelling, mapping any
      # LexError onto the token's start position. A lexeme spliced across a line
      # continuation is reported at its start, matching where it begins in source.
      def decode(pp)
        yield Front::LexemeReader.new(pp.text)
      rescue Front::LexError => e
        raise_at(pp, e.message)
      end

      def front_token(pp, type, value)
        Front::Token.new(
          type: type, value: value,
          filename: pp.filename, line: pp.line, column: pp.column,
          source_line: pp.source_line
        )
      end

      def num_token(pp, value, base, suffix)
        Front::Token.new(
          type: :num, value: value,
          filename: pp.filename, line: pp.line, column: pp.column,
          source_line: pp.source_line, base: base, suffix: suffix
        )
      end

      def raise_at(pp, description)
        raise CompileError.new(
          description,
          filename: pp.filename, line: pp.line, column: pp.column,
          source_line: pp.source_line
        )
      end
    end
  end
end
