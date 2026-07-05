# frozen_string_literal: true

module Rubycc
  # The minimal type system for this C subset. Only two kinds of type exist:
  # the scalar `int` and pointers to another type. Types compare by value, so
  # any two `int *` are equal, and each renders itself the way a C declarator
  # would ("int", "int *", "int **") for use in diagnostics.
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

      def to_s
        "int"
      end
    end

    # The lone `int`. Referred to everywhere as Type::Int.
    Int = Scalar.new

    # A pointer to `target` (itself a Type). Being a Data, two pointers are
    # equal exactly when their targets are, giving "int *" == "int *".
    Pointer = Data.define(:target) do
      def pointer?
        true
      end

      def int?
        false
      end

      # Renders as a C declarator: a space separates the base type from its
      # first "*", and deeper levels stack their stars with no gap in between
      # ("int *", "int **").
      def to_s
        target.pointer? ? "#{target}*" : "#{target} *"
      end
    end
  end
end
