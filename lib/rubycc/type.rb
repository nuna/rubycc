# frozen_string_literal: true

module Rubycc
  # The type system for this C subset: the standard integer types (char and its
  # signed/unsigned variants, short, int, long and _Bool), the incomplete
  # `void` type, pointers to another type, one-dimensional arrays of another
  # type, and structures (Type::StructType). The integer, pointer and array
  # types compare by value, so any two `int *` are equal, and each renders
  # itself the way a C declarator would ("int", "unsigned long", "char *",
  # "int [10]") for use in diagnostics. Structures instead compare by identity
  # (see Type::StructType): a struct type is the same type only when it is the
  # very same tag definition, which is what lets a self-referential struct
  # ("struct node { struct node *next; }") describe itself without a
  # value-equality walk looping forever.
  #
  # Every type but `void` and an incomplete struct reports its storage width in
  # bytes via #size (char/_Bool 1, short 2, int 4, long 8, any pointer 8, an
  # array its element width times its length, a struct its laid-out size) and
  # its required boundary via #alignment (an integer type is aligned to its own
  # width, any pointer 8, an array its element's alignment, a struct its widest
  # member's). `void` has no size or alignment (see Type::VoidType) since it is
  # only ever valid as a function's return type or as the target of a pointer;
  # an incomplete struct likewise has neither until it is completed.
  #
  # #integer? groups the standard integer types that mix freely in expressions
  # and convert to one another implicitly (#arithmetic? is its synonym, kept for
  # the day a floating type widens the notion of "arithmetic"). #signed? /
  # #unsigned? report an integer type's signedness — the axis that decides
  # signed vs unsigned division, right shift and comparison — and #bool? names
  # `_Bool` specifically (whose only values are 0 and 1). #int? and #char? still
  # name those two specific types (never their unsigned cousins), #void? names
  # `void` and #struct? names a structure or a union (both are aggregates that
  # share the same lvalue/copy machinery; #union? tells the two apart).
  module Type
    # A standard integer type, identified by its C spelling (`name`), its width
    # in bytes (`size`, one of 1/2/4/8) and its signedness (`signed`). A single
    # shared instance stands in for each type (Type::Int, Type::ULong, ...), so
    # identity comparison doubles as value comparison; two variables both `int`
    # name the very same object. `bool` singles out `_Bool`, whose values are
    # constrained to 0 and 1.
    #
    # Value representation (see Backend::X86_64): an integer value narrower than
    # 8 bytes lives in its virtual-register slot extended to (at least) 32 bits
    # following this type's signedness — sign-extended when #signed?,
    # zero-extended when #unsigned? — with the slot's bits 32..63 left
    # indeterminate. An 8-byte value (long/unsigned long) uses the whole slot.
    class IntegerType
      attr_reader :name

      def initialize(name, size, signed, bool: false)
        @name = name
        @size = size
        @signed = signed
        @bool = bool
      end

      def pointer?
        false
      end

      # #int? and #char? name the plain `int` and `char` types alone, so an
      # `unsigned int` is not #int? and an `unsigned char` is not #char?; code
      # that means "any integer" asks #integer? instead.
      def int?
        @name == "int"
      end

      def char?
        @name == "char"
      end

      def void?
        false
      end

      def integer?
        true
      end

      # Synonym for #integer?: every integer type is an arithmetic type. The two
      # names diverge only once a floating type exists, which this subset lacks.
      def arithmetic?
        true
      end

      def signed?
        @signed
      end

      def unsigned?
        !@signed
      end

      def bool?
        @bool
      end

      def array?
        false
      end

      def struct?
        false
      end

      def function?
        false
      end

      def size
        @size
      end

      # An integer type is aligned to its own width: char/_Bool 1, short 2,
      # int 4, long 8.
      def alignment
        @size
      end

      def to_s
        @name
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

      def integer?
        false
      end

      def arithmetic?
        false
      end

      def bool?
        false
      end

      def array?
        false
      end

      def struct?
        false
      end

      def function?
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

    # The shared integer-type instances, one per distinct C type. LP64 governs
    # the widths: int is 4 bytes, long and any pointer 8. `char` is signed (this
    # subset's implementation-defined choice), and `signed char` normalizes to
    # it. `long long` normalizes to `long` (same width under LP64) at the point
    # it is parsed, so no separate instance is needed here.
    Char = IntegerType.new("char", 1, true)
    UChar = IntegerType.new("unsigned char", 1, false)
    Short = IntegerType.new("short", 2, true)
    UShort = IntegerType.new("unsigned short", 2, false)
    Int = IntegerType.new("int", 4, true)
    UInt = IntegerType.new("unsigned int", 4, false)
    Long = IntegerType.new("long", 8, true)
    ULong = IntegerType.new("unsigned long", 8, false)
    # `_Bool` is treated as an unsigned 1-byte type whose stored value is only
    # ever 0 or 1; a conversion to it lowers to "value != 0" (see the generator).
    Bool = IntegerType.new("_Bool", 1, false, bool: true)

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

      def integer?
        false
      end

      def arithmetic?
        false
      end

      def bool?
        false
      end

      def array?
        false
      end

      def struct?
        false
      end

      def function?
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

      # Renders as a C declarator. A pointer to a function or an array cannot be
      # spelled by simply suffixing a "*", since the postfix "()" / "[]" would
      # then bind tighter than the star; C parenthesizes the star instead, so a
      # pointer to "int (int)" is written "int (*)(int)" and a pointer to
      # "int [3]" is "int (*)[3]". Every other target uses the plain suffix form:
      # a space before the first star, deeper levels stacking with no gap
      # ("int *", "int **").
      def to_s
        if target.function?
          "#{target.return_type} (*)(#{target.parameter_list_string})"
        elsif target.array?
          "#{target.element} (*)[#{target.length}]"
        elsif target.pointer?
          "#{target}*"
        else
          "#{target} *"
        end
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

      def integer?
        false
      end

      def arithmetic?
        false
      end

      def bool?
        false
      end

      def array?
        true
      end

      def struct?
        false
      end

      def function?
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

    # A function type (6.7.6.3): its `return_type`, the ordered `param_types`
    # (an array of the parameter Types after the array/function adjustments the
    # parser applies — "(void)" and "()" both yield an empty array) and
    # `variadic`, true for a prototype ending in "..." (a variable argument list
    # after the named parameters, "int (const char *, ...)"). For a variadic
    # type `param_types` holds only the fixed, named parameters. Being a Data,
    # two function types are equal exactly when their return type, parameter
    # types and variadic flag all match, so "int (int)" == "int (int)" but a
    # variadic "int (int, ...)" differs from the fixed "int (int)"; this makes a
    # function-pointer signature check reject a variadic/non-variadic mismatch on
    # its own.
    #
    # A function type is not an object type: it has no storage width, so #size
    # and #alignment raise (a well-formed program measures a *pointer* to a
    # function, never the function itself, and the parser rejects a bare
    # function type wherever an object is required). It is reached in this
    # subset only through a pointer (a function pointer, Pointer with a
    # FunctionType target) or as the very type a function declarator builds;
    # #function? tells it apart from every object type.
    FunctionType = Data.define(:return_type, :param_types, :variadic) do
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

      def integer?
        false
      end

      def arithmetic?
        false
      end

      def bool?
        false
      end

      def array?
        false
      end

      def struct?
        false
      end

      def function?
        true
      end

      # A function type has no storage, so it cannot be laid out; every path
      # that could reach one where a size is needed (sizeof, a member layout, a
      # variable) rejects it first with a proper diagnostic, so a raise here is
      # a missing guard.
      def size
        raise "function type has no size"
      end

      def alignment
        raise "function type has no alignment"
      end

      # The parenthesized parameter list as it appears in a C declarator, used
      # both by #to_s and by Pointer#to_s for a function pointer. An empty list
      # renders "void" (a prototype taking no arguments); a variadic type ends
      # in ", ..." after its named parameters ("char *, ..."). A variadic type
      # always has at least one named parameter (ISO C forbids a lone "..."), so
      # the empty-list "void" spelling is never variadic.
      def parameter_list_string
        return "..." if param_types.empty? && variadic

        base = param_types.empty? ? "void" : param_types.map(&:to_s).join(", ")
        variadic ? "#{base}, ..." : base
      end

      # Renders like a C function declarator with the name elided: the return
      # type, a space, then the bracketed parameter list ("int (int, char *)",
      # "void (void)").
      def to_s
        "#{return_type} (#{parameter_list_string})"
      end
    end

    # One laid-out member of a struct: its `name`, its declared Type and the
    # byte `offset` of its first byte from the start of the enclosing struct.
    Member = Data.define(:name, :type, :offset)

    # A structure or a union type. Both are aggregates (6.7.2.1) that share this
    # one class, told apart by `kind` (:struct or :union); a union differs only
    # in its layout (every member at offset 0, sized to hold the widest one).
    # Unlike every other type here, one compares by identity, not by value: two
    # such types are the same type exactly when they are the same object, which
    # is the object a single tag definition produces. That is what C means by
    # struct/union type identity (a redeclared "struct point" refers to the one
    # definition, never a structurally equal copy) and it is also what keeps
    # equality and #to_s from looping on a self-referential struct, whose
    # members point back at itself.
    #
    # A StructType is born incomplete: `tag` (the name after "struct"/"union",
    # or nil for an anonymous one) and `kind` are fixed, but its members are
    # unknown until #define lays them out. This mutability is deliberate — a
    # forward declaration ("struct node;") and, above all, a self-referential
    # pointer ("struct node *next;" inside "struct node"'s own body) both take a
    # reference to the still-incomplete object, and #define later fills in the
    # very same object, so those earlier references observe the completed
    # layout. Until then #size and #alignment raise and #complete? is false, so
    # the generator can reject an incomplete type (a variable, a sizeof, a
    # by-value member) with a proper diagnostic rather than lay out nonsense.
    class StructType
      attr_reader :tag, :kind, :members

      def initialize(tag, kind: :struct)
        @tag = tag
        @kind = kind
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

      def integer?
        false
      end

      def arithmetic?
        false
      end

      def bool?
        false
      end

      def array?
        false
      end

      # True for a union as well as a struct: both are aggregates that reuse the
      # same lvalue, member-access and whole-object-copy paths, so every
      # generator site that means "an aggregate" (member address, :memcpy copy,
      # by-value rejection) asks #struct? and needs no union-specific branch.
      # #union? draws the distinction where the layout or a diagnostic depends
      # on it.
      def struct?
        true
      end

      def function?
        false
      end

      # Distinguishes a union from a struct; the two share this class and differ
      # only in layout and in the wording of tag-kind diagnostics.
      def union?
        @kind == :union
      end

      # Whether the tag's body has been laid out yet. A struct only used
      # through a pointer may stay incomplete forever; every other use is a
      # diagnostic error the generator raises against this flag.
      def complete?
        @complete
      end

      # The member named `name`, or nil when there is none — the generator uses
      # the nil to diagnose "no member named ...". A named member wins directly;
      # failing that, an anonymous struct/union member (name nil, an aggregate
      # per C11 6.7.2.1p13) is searched transparently, and a hit there is
      # returned as a synthesized Member whose offset folds the anonymous
      # member's own offset into the inner one. The search recurses, so an
      # anonymous member nested inside another resolves in the same single step;
      # because the returned Member carries a ready-made offset and type, the
      # generator's "." and "->" lowering reaches a nested field with no
      # awareness that it came through an anonymous member.
      def member(name)
        return nil unless @members

        direct = @members.find { |m| m.name == name }
        return direct if direct

        @members.each do |m|
          next unless m.name.nil? && m.type.struct?

          inner = m.type.member(name)
          return Member.new(inner.name, inner.type, m.offset + inner.offset) if inner
        end
        nil
      end

      # Lays out the aggregate from `raw_members` (an array of [name, Type]
      # pairs in declaration order; an anonymous struct/union member has a nil
      # name). A struct follows the System V AMD64 rules: each member starts at
      # the next offset that satisfies its own alignment (inserting padding as
      # needed), the alignment is the widest member's, and the size is rounded
      # up to that alignment so arrays keep every element aligned. A union
      # overlays every member at offset 0, so its alignment is still the widest
      # member's but its size is the largest member's rounded up to that
      # alignment. Completing the type in place means any reference taken while
      # it was incomplete now sees the finished layout.
      def define(raw_members)
        @members, @size, @alignment = union? ? layout_union(raw_members) : layout_struct(raw_members)
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
        keyword = union? ? "union" : "struct"
        tag ? "#{keyword} #{tag}" : "#{keyword} <anonymous>"
      end

      private

      # The struct layout: members packed in order at their own alignment, the
      # whole rounded up to the widest member's alignment. Returns
      # [members, size, alignment].
      def layout_struct(raw_members)
        offset = 0
        max_alignment = 1
        members = raw_members.map do |name, type|
          member_alignment = type.alignment
          offset = align_up(offset, member_alignment)
          member = Member.new(name, type, offset)
          offset += type.size
          max_alignment = member_alignment if member_alignment > max_alignment
          member
        end
        [members, align_up(offset, max_alignment), max_alignment]
      end

      # The union layout: every member overlaid at offset 0, the size the widest
      # member's rounded up to the widest alignment. Returns
      # [members, size, alignment].
      def layout_union(raw_members)
        members = raw_members.map { |name, type| Member.new(name, type, 0) }
        max_alignment = members.map { |m| m.type.alignment }.max || 1
        max_size = members.map { |m| m.type.size }.max || 0
        [members, align_up(max_size, max_alignment), max_alignment]
      end

      def align_up(value, alignment)
        (value + alignment - 1) / alignment * alignment
      end
    end

    # The System V AMD64 psABI representation of a `va_list` element: the
    # `__va_list_tag` structure a call's variable arguments are read through.
    # Its layout — a 32-bit `gp_offset` (the byte offset of the next integer
    # argument still in the register-save area), a 32-bit `fp_offset` (the same
    # for a vector argument), an `overflow_arg_area` pointer (the next argument
    # that spilled onto the stack) and a `reg_save_area` pointer (the base of the
    # saved argument registers) — is fixed by the ABI, so building it here from
    # the ordinary #define layout path (size 24, 8-byte aligned) matches what a
    # System V compiler and its C library agree on. A single shared instance
    # stands for the tag, and, being a StructType, it compares by identity, so
    # the generator recognizes "pointer to __va_list_tag" by object identity when
    # type-checking a va_start/va_arg/va_end operand.
    VaListTag = StructType.new("__va_list_tag").tap do |tag|
      tag.define([
                   ["gp_offset", UInt],
                   ["fp_offset", UInt],
                   ["overflow_arg_area", Pointer.new(Void)],
                   ["reg_save_area", Pointer.new(Void)]
                 ])
    end

    # The type the built-in `__builtin_va_list` typedef names: a one-element
    # array of __va_list_tag. The array shape is what makes a `va_list` object
    # decay to a `__va_list_tag *` in every expression context (so passing one
    # to a helper hands over a pointer to the same object, and va_start/va_arg
    # write through it), while a local declaration still reserves the whole
    # 24-byte tag as a stack object — exactly the System V convention.
    BuiltinVaList = Array.new(VaListTag, 1)
  end
end
