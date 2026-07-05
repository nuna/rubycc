# frozen_string_literal: true

module Rubycc
  module Front
    # A single lexical token. `type` is one of :num, :ident, :keyword, :punct,
    # :eof. `value` is an Integer for :num and a String otherwise (nil for
    # :eof). The remaining fields locate the token in the source for diagnostics.
    class Token
      TYPES = %i[num ident keyword punct eof].freeze

      attr_reader :type, :value, :filename, :line, :column, :source_line

      def initialize(type:, value:, filename:, line:, column:, source_line:)
        @type = type
        @value = value
        @filename = filename
        @line = line
        @column = column
        @source_line = source_line
      end

      def punct?(str)
        type == :punct && value == str
      end

      def keyword?(str)
        type == :keyword && value == str
      end

      def eof?
        type == :eof
      end

      def inspect
        "#<Token #{type} #{value.inspect} @#{line}:#{column}>"
      end
    end
  end
end
