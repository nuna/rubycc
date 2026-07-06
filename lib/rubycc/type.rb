# frozen_string_literal: true

module Rubycc
  # The type system for this C subset: the scalar arithmetic types `int` and
  # `char`, pointers to another type, and one-dimensional arrays of another
  # type. Types compare by value, so any two `int *` are equal, and each
  # renders itself the way a C declarator would ("int", "char *", "int [10]")
  # for use in diagnostics. Every type reports its storage width in bytes via
  # #size (int 4, char 1, any pointer 8, an array its element width times its
  # length). #arithmetic? groups the scalar arithmetic types (int and char)
  # that mix freely in expressions and convert to one another implicitly, while
  # #char? and #int? name each one individually.
  module Type
    # The scalar integer type. A single shared instance (Type::Int) stands in
    # for every `int`, so identity comparison doubles as value comparison.
    class Scalar
      def pointer?
        false
      end

      def int?
        true
      end

      def char?
        false
      end

      def arithmetic?
        true
      end

      def array?
        false
      end

      # An `int` occupies 4 bytes.
      def size
        4
      end

      def to_s
        "int"
      end
    end

    # The signed 1-byte character type. Like Type::Int it is a single shared
    # instance (Type::Char), so identity comparison doubles as value
    # comparison. In expressions a char promotes to int; the 8-bit narrowing
    # happens only at the memory boundary (a size-1 load/store) and at an
    # explicit int->char conversion.
    class CharType
      def pointer?
        false
      end

      def int?
        false
      end

      def char?
        true
      end

      def arithmetic?
        true
      end

      def array?
        false
      end

      # A `char` occupies 1 byte.
      def size
        1
      end

      def to_s
        "char"
      end
    end

    # The lone `int`. Referred to everywhere as Type::Int.
    Int = Scalar.new

    # The lone `char`. Referred to everywhere as Type::Char.
    Char = CharType.new

    # A pointer to `target` (itself a Type). Being a Data, two pointers are
    # equal exactly when their targets are, giving "int *" == "int *".
    Pointer = Data.define(:target) do
      def pointer?
        true
      end

      def int?
        false
      end

      def char?
        false
      end

      def arithmetic?
        false
      end

      def array?
        false
      end

      # Every pointer is a 64-bit address, so 8 bytes wide.
      def size
        8
      end

      # Renders as a C declarator: a space separates the base type from its
      # first "*", and deeper levels stack their stars with no gap in between
      # ("int *", "int **").
      def to_s
        target.pointer? ? "#{target}*" : "#{target} *"
      end
    end

    # A one-dimensional array of `length` elements, each of type `element`
    # (itself a Type: an int or a pointer in this subset). Two arrays are equal
    # when both their element type and length match.
    Array = Data.define(:element, :length) do
      def pointer?
        false
      end

      def int?
        false
      end

      def char?
        false
      end

      def arithmetic?
        false
      end

      def array?
        true
      end

      # The whole array's byte size: the element width times the count.
      def size
        element.size * length
      end

      # Renders like a C array declarator: the element type, a space, then the
      # bracketed length ("int [10]", "int * [4]").
      def to_s
        "#{element} [#{length}]"
      end
    end
  end
end
