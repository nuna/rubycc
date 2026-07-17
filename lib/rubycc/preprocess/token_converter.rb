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
    #
    # This is where translation phases 5-7 sit in this pipeline, so adjacent
    # string-literal concatenation (phase 6, ISO C 6.4.5p5) happens here: a run
    # of neighbouring string tokens folds into one, its bytes the per-literal
    # decodings laid end to end. The streaming Front::Lexer takes the direct path
    # and does not concatenate — nothing but this converter ever feeds the
    # parser in the real compile pipeline (which always runs through the
    # preprocessor), so the lexer's simpler single-literal path serves its
    # unit-test-only role without the phase-6 fold.
    class TokenConverter
      def convert(pp_tokens)
        tokens = []
        index = 0
        while index < pp_tokens.length
          pp = pp_tokens[index]
          case pp.type
          when :newline
            index += 1
          when :eof
            tokens << front_token(pp, :eof, nil)
            index += 1
          when :identifier
            spelling = Front::LexemeReader.keyword_spelling(pp.text)
            tokens << front_token(pp, spelling ? :keyword : :ident, spelling || pp.text)
            index += 1
          when :pp_number
            tokens << convert_number(pp)
            index += 1
          when :string
            value, index = concatenate_strings(pp_tokens, index)
            tokens << front_token(pp, :string, value)
          when :char
            tokens << num_token(pp, decode_char(pp), 10, "")
            index += 1
          when :punct
            if pp.text == "#" || pp.text == "##"
              raise_at(pp, "stray '#' in program")
            end
            tokens << front_token(pp, :punct, pp.text)
            index += 1
          when :other
            raise_at(pp, "unexpected character #{pp.text.inspect}")
          end
        end
        tokens
      end

      private

      # Folds the maximal run of adjacent string-literal tokens starting at
      # `index` into a single value (translation phase 6). Each literal is decoded
      # on its own, so an escape resolves within the literal that spells it —
      # "\x41" "1" is the two bytes 'A' and '1', never one "\x411" digit run
      # (6.4.5p4) — and the decoded bytes are concatenated. Intervening newline
      # tokens are inter-token whitespace and do not break adjacency; in the
      # compile pipeline the expander has already dropped them, so consecutive
      # string tokens simply abut. Returns [concatenated-bytes, index-past-run].
      def concatenate_strings(pp_tokens, index)
        bytes = decode_string(pp_tokens[index])
        index += 1
        loop do
          nxt = index
          nxt += 1 while pp_tokens[nxt]&.type == :newline
          break unless pp_tokens[nxt]&.type == :string

          bytes += decode_string(pp_tokens[nxt])
          index = nxt + 1
        end
        [bytes, index]
      end

      # The escape-resolved bytes of one string literal. A wide string literal
      # (an "L" prefix) has element type wchar_t, which this subset cannot
      # represent, so it is rejected rather than silently narrowed.
      def decode_string(pp)
        raise_at(pp, "wide string literals are not supported") if pp.text.start_with?("L")

        decode(pp, pp.text) { |reader| reader.read_string }.value
      end

      # A character constant's integer value. A wide character constant L'c' has
      # type wchar_t (int on this target); for the single-byte characters this
      # subset lexes its value equals the plain constant's, so the "L" prefix is
      # dropped and the remainder decoded like an ordinary 'c'.
      def decode_char(pp)
        spelling = pp.text.start_with?("L") ? pp.text[1..] : pp.text
        decode(pp, spelling) { |reader| reader.read_char }.value
      end

      # Folds a preprocessing number into a :num or :float token. A pp-number is
      # broader than a C constant, so an ill-formed one (e.g. "12abc", "1.2.3")
      # is rejected here rather than at scan time.
      def convert_number(pp)
        result = decode(pp, pp.text) { |reader| reader.read_number }
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

      # Runs a LexemeReader over `spelling` (the token's own text, or that text
      # with a wide-literal "L" prefix already stripped), mapping any LexError
      # onto the token's start position. A lexeme spliced across a line
      # continuation is reported at its start, matching where it begins in source.
      def decode(pp, spelling)
        yield Front::LexemeReader.new(spelling)
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
