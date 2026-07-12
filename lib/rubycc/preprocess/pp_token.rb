# frozen_string_literal: true

module Rubycc
  module Preprocess
    # A preprocessing token (ISO C 6.4). Unlike a Front::Token it holds only the
    # source spelling (`text`), deferring interpretation of numbers, literals and
    # keywords to the conversion that ends translation phase 4. `type` is one of:
    #
    #   :identifier  an identifier or keyword spelling
    #   :pp_number   a preprocessing number (6.4.8), broader than a C constant
    #   :string      a string literal, quotes and escapes still verbatim
    #   :char        a character constant, quotes and escapes still verbatim
    #   :punct       a punctuator (including the pp-only "#" and "##")
    #   :newline     an end-of-line marker kept so directives stay line-oriented
    #   :other       any single character matching no other category (6.4p1)
    #   :eof         the end of the translation unit
    #
    # The location fields follow the same 1-based line/column convention as
    # Front::Token, and point at the token's first character on its physical
    # line (a token spliced across a line continuation keeps its start line).
    # `space_before` records whether whitespace or a comment preceded the token,
    # which the directive layer consults to classify a macro definition.
    # `suppress` is the token's own set of macro names it must not be re-expanded
    # as (6.10.3.4, "painted blue"): a frozen list carried along every copy, so
    # each token remembers the expansions it was already born from.
    class PPToken
      # The suppression set of a token that came straight from source and has yet
      # to pass through any macro; shared so unpainted tokens cost no allocation.
      NO_SUPPRESS = [].freeze

      attr_reader :type, :text, :filename, :line, :column, :source_line, :space_before, :suppress

      def initialize(type:, text:, filename:, line:, column:, source_line:, space_before: false,
                     suppress: NO_SUPPRESS)
        @type = type
        @text = text
        @filename = filename
        @line = line
        @column = column
        @source_line = source_line
        @space_before = space_before
        @suppress = suppress
      end

      def newline?
        @type == :newline
      end

      def eof?
        @type == :eof
      end

      def punct?(str)
        @type == :punct && @text == str
      end

      def inspect
        "#<PPToken #{type} #{text.inspect} @#{line}:#{column}>"
      end
    end
  end
end
