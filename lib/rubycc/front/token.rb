# frozen_string_literal: true

module Rubycc
  module Front
    # A single lexical token. `type` is one of :num, :float, :ident, :keyword,
    # :punct, :string, :eof. `value` is an Integer for :num, a Ruby Float for
    # :float (a floating constant), an ASCII-8BIT String of the escape-resolved
    # bytes for :string, a String for :ident/:keyword/:punct, and nil for :eof.
    # `base` (10/8/16) and `suffix` accompany a numeric constant so the parser
    # can fix its type: an integer :num carries a base and a normalized u/l
    # suffix run ("", "u", "ul") per 6.4.4.1, while a :float carries no base but
    # a normalized floating suffix ("" for double, "f" for float, "l" for long
    # double, itself treated as double). Both are nil on every other token (a
    # character constant is a :num with base 10 and no suffix). The remaining
    # fields locate the token in the source for diagnostics.
    class Token
      TYPES = %i[num float ident keyword punct string eof].freeze

      attr_reader :type, :value, :filename, :line, :column, :source_line, :base, :suffix

      def initialize(type:, value:, filename:, line:, column:, source_line:, base: nil, suffix: nil)
        @type = type
        @value = value
        @filename = filename
        @line = line
        @column = column
        @source_line = source_line
        @base = base
        @suffix = suffix
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
