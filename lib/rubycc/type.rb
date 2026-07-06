# frozen_string_literal: true

module Rubycc
  # The type system for this C subset: the scalar arithmetic types `int` and
  # `char`, the incomplete `void` type, pointers to another type,
  # one-dimensional arrays of another type, and structures (Type::StructType).
  # The scalar, pointer and array types compare by value, so any two `int *`
  # are equal, and each renders itself the way a C declarator would ("int",
  # "char *", "int [10]") for use in diagnostics. Structures instead compare by
  # identity (see Type::StructType): a struct type is the same type only when it
  # is the very same tag definition, which is what lets a self-referential
  # struct ("struct node { struct node *next; }") describe itself without a
  # value-equality walk looping forever.
  #
  # Every type but `void` and an incomplete struct reports its storage width in
  # bytes via #size (int 4, char 1, any pointer 8, an array its element width
  # times its length, a struct its laid-out size) and its required boundary via
  # #alignment (int 4, char 1, any pointer 8, an array its element's alignment,
  # a struct its widest member's). `void` has no size or alignment (see
  # Type::VoidType) since it is only ever valid as a function's return type or
  # as the target of a pointer; an incomplete struct likewise has neither until
  # it is completed. #arithmetic? groups the scalar arithmetic types (int and
  # char) that mix freely in expressions and convert to one another implicitly,
  # while #char? and #int? name each one individually, #void? names `void`
  # itself, and #struct? names a structure.
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

      def void?
        false
      end

      def arithmetic?
        true
      end

      def array?
        false
      end

      def struct?
        false
      end

      # An `int` occupies 4 bytes.
      def size
        4
      end

      # An `int` is 4-byte aligned.
      def alignment
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

      def void?
        false
      end

      def arithmetic?
        true
      end

      def array?
        false
      end

      def struct?
        false
      end

      # A `char` occupies 1 byte.
      def size
        1
      end

      # A `char` is 1-byte aligned (no alignment constraint).
      def alignment
        1
      end

      def to_s
        "char"
      end
    end

    # The incomplete `void` type. A single shared instance (Type::Void) stands
    # in for every `void`. It is valid only as a function's return type or as
    # the target of a pointer (`void *`); every other use (a variable, an
    # array element, a non-pointer parameter, `sizeof(void)`, dereferencing a
    # `void *`) is rejected by the parser or the generator rather than modelled
    # here. It has no storage width: #size raises, since a well-formed program
    # never asks a bare `void` for one.
    class VoidType
      def pointer?
        false
      end

      def int?
        false
      end

      def char?
        false
      end

      def void?
        true
      end

      def arithmetic?
        false
      end

      def array?
        false
      end

      def struct?
        false
      end

      # `void` is incomplete and has no storage width; every call site that
      # might reach a bare `void` here (sizeof, a global's layout, ...) rejects
      # it first with a proper CompileError, so reaching this is a bug.
      def size
        raise "void has no size"
      end

      # `void` has no alignment for the same reason it has no size; a
      # well-formed program never lays a bare `void` out in storage.
      def alignment
        raise "void has no alignment"
      end

      def to_s
        "void"
      end
    end

    # The lone `int`. Referred to everywhere as Type::Int.
    Int = Scalar.new

    # The lone `char`. Referred to everywhere as Type::Char.
    Char = CharType.new

    # The lone `void`. Referred to everywhere as Type::Void.
    Void = VoidType.new

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

      def void?
        false
      end

      def arithmetic?
        false
      end

      def array?
        false
      end

      def struct?
        false
      end

      # Every pointer is a 64-bit address, so 8 bytes wide.
      def size
        8
      end

      # A 64-bit address is 8-byte aligned. A pointer to an incomplete type is
      # still a complete, 8-byte pointer, which is exactly what lets a struct
      # hold a pointer to itself.
      def alignment
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

      def void?
        false
      end

      def arithmetic?
        false
      end

      def array?
        true
      end

      def struct?
        false
      end

      # The whole array's byte size: the element width times the count.
      def size
        element.size * length
      end

      # An array is aligned like one of its elements: an `int [10]` on a 4-byte
      # boundary, a `struct point [3]` on the struct's boundary.
      def alignment
        element.alignment
      end

      # Renders like a C array declarator: the element type, a space, then the
      # bracketed length ("int [10]", "int * [4]").
      def to_s
        "#{element} [#{length}]"
      end
    end

    # One laid-out member of a struct: its `name`, its declared Type and the
    # byte `offset` of its first byte from the start of the enclosing struct.
    Member = Data.define(:name, :type, :offset)

    # A structure type. Unlike every other type here, a struct compares by
    # identity, not by value: two struct types are the same type exactly when
    # they are the same object, which is the object a single tag definition
    # produces. That is what C means by struct type identity (a redeclared
    # "struct point" refers to the one definition, never a structurally equal
    # copy) and it is also what keeps equality and #to_s from looping on a
    # self-referential struct, whose members point back at itself.
    #
    # A StructType is born incomplete: `tag` (the name after "struct", or nil
    # for an anonymous struct) is fixed, but its members are unknown until
    # #define lays them out. This mutability is deliberate — a forward
    # declaration ("struct node;") and, above all, a self-referential pointer
    # ("struct node *next;" inside "struct node"'s own body) both take a
    # reference to the still-incomplete object, and #define later fills in the
    # very same object, so those earlier references observe the completed
    # layout. Until then #size and #alignment raise and #complete? is false, so
    # the generator can reject an incomplete type (a variable, a sizeof, a
    # by-value member) with a proper diagnostic rather than lay out nonsense.
    class StructType
      attr_reader :tag, :members

      def initialize(tag)
        @tag = tag
        @members = nil
        @size = nil
        @alignment = nil
        @complete = false
      end

      def pointer?
        false
      end

      def int?
        false
      end

      def char?
        false
      end

      def void?
        false
      end

      def arithmetic?
        false
      end

      def array?
        false
      end

      def struct?
        true
      end

      # Whether the tag's body has been laid out yet. A struct only used
      # through a pointer may stay incomplete forever; every other use is a
      # diagnostic error the generator raises against this flag.
      def complete?
        @complete
      end

      # The member named `name`, or nil when there is none — the generator uses
      # the nil to diagnose "no member named ...".
      def member(name)
        @members&.find { |m| m.name == name }
      end

      # Lays out the struct from `raw_members` (an array of [name, Type] pairs
      # in declaration order) following the System V AMD64 rules: each member
      # starts at the next offset that satisfies its own alignment (inserting
      # padding as needed), the struct's alignment is its widest member's, and
      # the total size is rounded up to that alignment so arrays of the struct
      # keep every element aligned. Completing the struct in place means any
      # reference taken while it was incomplete now sees the finished layout.
      def define(raw_members)
        offset = 0
        max_alignment = 1
        @members = raw_members.map do |name, type|
          member_alignment = type.alignment
          offset = align_up(offset, member_alignment)
          member = Member.new(name, type, offset)
          offset += type.size
          max_alignment = member_alignment if member_alignment > max_alignment
          member
        end
        @alignment = max_alignment
        @size = align_up(offset, max_alignment)
        @complete = true
      end

      # The laid-out byte size. Guarded like Type::Void's: every path that
      # could reach an incomplete struct here rejects it first with a
      # CompileError, so a raise means a missing guard.
      def size
        raise "incomplete struct has no size" unless @complete

        @size
      end

      # The struct's alignment (its widest member's), guarded exactly like
      # #size against an incomplete struct.
      def alignment
        raise "incomplete struct has no alignment" unless @complete

        @alignment
      end

      # Two struct types are identical only when they are the same object (the
      # same tag definition); a comparison with any other type, or with a
      # different struct, is false. Identity avoids walking members, so a
      # self-referential struct compares without recursing.
      def ==(other)
        equal?(other)
      end

      # Renders as a C type name for diagnostics. Never inspects members, so a
      # self-referential struct renders in one step; an anonymous struct has no
      # tag to name.
      def to_s
        tag ? "struct #{tag}" : "struct <anonymous>"
      end

      private

      def align_up(value, alignment)
        (value + alignment - 1) / alignment * alignment
      end
    end
  end
end
