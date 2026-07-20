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
  # and convert to one another implicitly; #float? (FloatType) names the two
  # floating types, and #arithmetic? is the union of the two — every integer or
  # floating type — the notion "arithmetic" the usual arithmetic conversions act
  # on. #signed? / #unsigned? report an integer type's signedness — the axis
  # that decides signed vs unsigned division, right shift and comparison — and
  # #bool? names `_Bool` specifically (whose only values are 0 and 1). #int? and
  # #char? still name those two specific types (never their unsigned cousins),
  # #void? names `void` and #struct? names a structure or a union (both are
  # aggregates that share the same lvalue/copy machinery; #union? tells the two
  # apart).
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
      # `unsigned int` is not #int? and neither `signed char` nor `unsigned char`
      # is #char?; code that means "any integer" asks #integer? instead, and code
      # that means "any character type" asks Type.character?. Plain `char` is
      # #char? under either signedness, since both instances spell themselves the
      # same way (see Type.plain_char).
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

      # Every integer type is an arithmetic type; #float? tells it apart from a
      # floating one (see Type::FloatType), which is likewise #arithmetic? but
      # not #integer?.
      def arithmetic?
        true
      end

      def float?
        false
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

      # Each integer type is a shared singleton, so equality is normally
      # identity. The one exception: a completed enum is an int object
      # (6.7.2.2), so the plain `int` singleton is equal to any EnumType
      # completed to int — this makes the equality symmetric with EnumType#==,
      # so a function-type compatibility check matches whichever side holds the
      # `int`. #eql?/#hash are left as identity, so this does not disturb the
      # singletons' use as hash keys.
      def ==(other)
        return true if equal?(other)

        int? && other.is_a?(EnumType) && other.complete?
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

      def float?
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

    # A floating type: `float` (4 bytes, IEEE754 single precision) or `double`
    # (8 bytes, IEEE754 double precision). A single shared instance stands for
    # each (Type::Float, Type::Double); being a Data, identity and value
    # comparison coincide, so two `double`s name the very same type. `long
    # double` normalizes to `double` at parse time (same width here), so no
    # separate instance exists. #arithmetic? is true — a floating type mixes with
    # the integer types under the usual arithmetic conversions — while #integer?
    # is false and #float? true, which is how the generator tells a floating
    # operand apart to emit the f-prefixed IR (:fadd, :flt, ...) and the
    # integer/float conversions (:itof / :ftoi / :ftof).
    #
    # Value representation (see Backend::X86_64): a `float` value lives in its
    # virtual-register slot's low 4 bytes as an IEEE754 single-precision bit
    # pattern, a `double` in the whole 8-byte slot as a double-precision one; a
    # `float`'s spare bits 32..63 follow the same indeterminate rule a narrow
    # integer's do.
    FloatType = Data.define(:name, :size) do
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
        true
      end

      def float?
        true
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

      # A floating type is aligned to its own width: float 4, double 8.
      def alignment
        size
      end

      def to_s
        name
      end
    end

    # The shared integer-type instances, one per distinct C type. LP64 governs
    # the widths: int is 4 bytes, long and any pointer 8. `long long` normalizes
    # to `long` (same width under LP64) at the point it is parsed, so no separate
    # instance is needed here.
    #
    # The character types are three distinct types (6.2.5p15): `signed char` and
    # `unsigned char` have a fixed signedness, while plain `char` behaves as one
    # or the other, and which one is implementation-defined — pinned per ABI, so
    # it is a property of the target rather than of this subset: the x86-64
    # System V psABI makes plain `char` signed, AAPCS64 makes it unsigned. Both
    # plain-`char` instances therefore exist side by side and spell themselves
    # "char" (so #char?, #to_s and every diagnostic read alike whichever is in
    # play); Type.plain_char picks the one a target uses, and the front end
    # carries that choice from Compiler#compile down to every place a `char` type
    # is built. Type::Char stays the signed one, which is what a caller with no
    # target in hand (the default x86-64) means by "char".
    Char = IntegerType.new("char", 1, true)
    UnsignedChar = IntegerType.new("char", 1, false)
    SChar = IntegerType.new("signed char", 1, true)
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

    # The GNU 128-bit integer types (`__int128` and `unsigned __int128`), 16
    # bytes wide and 16-byte aligned. They are ordinary IntegerTypes for
    # classification (#integer?, #signed?, sizeof/_Alignof, the usual arithmetic
    # conversions), but their value does not fit a single 64-bit slot: the
    # generator represents a 128-bit value the way it represents a small struct —
    # as a 16-byte stack object whose low eightbyte lives at +0 and high at +8,
    # its address carried in an ordinary vreg — and lowers each supported
    # operation to 64-bit ops on the two halves. The width alone (size 16) marks
    # them apart from every other integer type; the generator's #wide128? tests it.
    Int128 = IntegerType.new("__int128", 16, true)
    UInt128 = IntegerType.new("unsigned __int128", 16, false)

    # The shared floating-type instances (Type::Float, Type::Double).
    Float = FloatType.new("float", 4)
    Double = FloatType.new("double", 8)

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

      def float?
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
    #
    # A `length` of nil is an *incomplete* array type (6.7.2.1): an unbounded
    # "[]" whose element count is unknown. It reaches this subset as a struct's
    # flexible array member (the last member, "T name[];", ISO C 6.7.2.1p18) and
    # nowhere a size is needed — #size raises, and every path that could demand
    # one (a variable, a plain sizeof/_Alignof of the array, an array-of-array
    # element) is rejected first by the parser or the generator's completeness
    # guard. A flexible array member still lays out (at its element's boundary,
    # contributing nothing to the struct's size), and an lvalue of this type
    # decays to a pointer to its element exactly as a bounded array does, so
    # "p->fam[i]" indexes it.
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

      def float?
        false
      end

      # Whether this is an incomplete array — an unbounded "[]" with no element
      # count, the shape a struct's flexible array member takes. It has no size,
      # so every size-needing use is diagnosed before #size would raise.
      def incomplete?
        length.nil?
      end

      # The whole array's byte size: the element width times the count. An
      # incomplete array ("[]") has no count and therefore no size; every path
      # that could reach one where a size is needed rejects it first with a
      # proper diagnostic, so a raise here is a missing guard.
      def size
        raise "incomplete array has no size" if length.nil?

        element.size * length
      end

      # An array is aligned like one of its elements: an `int [10]` on a 4-byte
      # boundary, a `struct point [3]` on the struct's boundary.
      def alignment
        element.alignment
      end

      # Renders like a C array declarator: the element type, a space, then the
      # bracketed length ("int [10]", "int * [4]"); an incomplete array shows an
      # empty "[]" ("int []").
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

      def float?
        false
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

    # An incomplete enumeration type: a reference to an "enum tag" whose
    # enumerator list is not visible (a forward-referenced tag, or one never
    # defined in the translation unit). A *complete* enum has no dedicated type
    # here — an enum object is an int (6.7.2.2), so #parse_enum_specifier resolves
    # a defined tag straight to Type::Int. This class exists only so an
    # *incomplete* enum can flow exactly where an incomplete struct may (a
    # pointer's target, a prototype's return type, an extern reference) while any
    # use that needs a size or arithmetic still rejects it. It mirrors an
    # incomplete StructType: every category predicate is false, #complete? is
    # false, and #size/#alignment raise behind the generator's completeness
    # guard. Two are equal when their tags match, so "enum E *" == "enum E *".
    class EnumType
      attr_reader :tag

      def initialize(tag)
        @tag = tag
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

      # Once completed, an enum object is an int (6.7.2.2), so the integer
      # predicates and measurements answer as `int` does. Before completion
      # every one is false/raising, exactly as for any other incomplete type.
      def integer?
        @complete
      end

      def arithmetic?
        @complete
      end

      def signed?
        raise "incomplete enum has no signedness" unless @complete

        true
      end

      def unsigned?
        raise "incomplete enum has no signedness" unless @complete

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

      def float?
        false
      end

      # A forward-referenced enum tag ("enum efoo;" before its "{...}") is
      # incomplete until #register_enum_tag sees the definition. A *defined* enum
      # normally resolves straight to Type::Int, so completion is modeled on the
      # object only for the one case that captured this incomplete type before
      # the definition (a prototype's return type, "enum efoo it_real_fn(void)").
      # #complete! then turns that very object into an int in place, so both the
      # earlier reference and the later "enum efoo" (an int) agree.
      def complete?
        @complete
      end

      # Completes this forward-referenced enum in place: the object that stood in
      # for an undefined tag starts answering as the `int` an enum object is.
      # Idempotent, since one tag may complete after several incomplete
      # references captured the same object.
      def complete!
        @complete = true
        self
      end

      # Guarded like Type::Void and an incomplete StructType while incomplete;
      # once completed it measures like `int` (4 bytes, 4-byte aligned).
      def size
        raise "incomplete enum has no size" unless @complete

        4
      end

      def alignment
        raise "incomplete enum has no alignment" unless @complete

        4
      end

      # Value equality by tag while incomplete, so two references to the same
      # undefined tag share a type (which is what a tentative-definition merge
      # and a redeclaration check compare). Once completed, an enum object is an
      # int, so a completed enum is equal to Type::Int (and to any other
      # completed enum) — this is the identity a function-type compatibility
      # check needs when "enum efoo (*)(void)" (resolved to int post-definition)
      # is assigned a function returning the once-incomplete "enum efoo".
      def ==(other)
        if @complete
          return true if other.equal?(Type::Int)
          return other.complete? if other.is_a?(EnumType)

          return false
        end
        other.is_a?(EnumType) && !other.complete? && other.tag == tag
      end

      def eql?(other)
        self == other
      end

      def hash
        [EnumType, tag].hash
      end

      def to_s
        "enum #{tag}"
      end
    end

    # One laid-out member of a struct: its `name`, its declared Type and the
    # byte `offset` of its first byte from the start of the enclosing struct.
    #
    # A bit-field member carries two extra fields (both nil for a plain member):
    # `bit_width`, the declared width in bits, and `bit_offset`, the field's bit
    # position measured from the start of the enclosing aggregate. `offset` for a
    # bit-field is the byte containing its first bit (bit_offset / 8), kept only
    # so ABI classification and diagnostics have a byte anchor — this subset
    # diagnoses every bit-field *access*, so no read or write ever consults these
    # bit fields to extract a value (recorded M2 debt). An unnamed bit-field
    # declares no member and is never recorded here; it only shapes the layout.
    Member = Data.define(:name, :type, :offset, :bit_width, :bit_offset) do
      def initialize(name:, type:, offset:, bit_width: nil, bit_offset: nil)
        super
      end

      # Whether this member is a bit-field, distinguishing it from a plain member
      # occupying whole bytes; the generator consults it to diagnose an access.
      def bitfield?
        !bit_width.nil?
      end
    end

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

      def float?
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

      # Whether this aggregate ends in a flexible array member (an unbounded
      # "[]", 6.7.2.1p18). A struct with one taints its uses: it may not be an
      # array element or (this subset) laid out by value inside another
      # aggregate, since its true size depends on a run-time element count the
      # enclosing layout cannot know. Only a defined struct can carry one, so an
      # incomplete type (no members yet) answers false.
      def flexible_array_member?
        return false unless @members

        last = @members.last
        !last.nil? && last.type.array? && last.type.incomplete?
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
          if inner
            return Member.new(name: inner.name, type: inner.type, offset: m.offset + inner.offset,
                              bit_width: inner.bit_width,
                              bit_offset: inner.bit_offset && inner.bit_offset + m.offset * 8)
          end
        end
        nil
      end

      # Lays out the aggregate from `raw_members` (an array of [name, Type,
      # bit_width] triples in declaration order; an anonymous struct/union member
      # has a nil name, and a plain member a nil bit_width — see #layout_struct
      # for how a bit-field is placed). A struct follows the System V AMD64 rules:
      # each member starts at
      # the next offset that satisfies its own alignment (inserting padding as
      # needed), the alignment is the widest member's, and the size is rounded
      # up to that alignment so arrays keep every element aligned. A union
      # overlays every member at offset 0, so its alignment is still the widest
      # member's but its size is the largest member's rounded up to that
      # alignment. Completing the type in place means any reference taken while
      # it was incomplete now sees the finished layout.
      #
      # `packed` and `aligned` carry the GNU __attribute__ layout overrides
      # (Step 28). `packed` drops every member to a 1-byte boundary — no padding
      # between members and no tail padding — and, on its own, the whole
      # aggregate to alignment 1. `aligned` (a power-of-two integer, or nil for
      # none) raises the aggregate's alignment to at least that value, rounding
      # the size up to it; combined with `packed` the members stay packed while
      # the aggregate takes `aligned` as its boundary and tail-rounding.
      #
      # `unnamed_bitfields_align` selects the one layout rule the two supported
      # ABIs spell differently (see #layout_struct): whether an unnamed
      # bit-field's declared type raises the aggregate's alignment. It does not
      # under the x86-64 System V psABI (the default) and does under AAPCS64.
      def define(raw_members, packed: false, aligned: nil, unnamed_bitfields_align: false)
        @members, @size, @alignment =
          if union?
            layout_union(raw_members, packed, aligned, unnamed_bitfields_align)
          else
            layout_struct(raw_members, packed, aligned, unnamed_bitfields_align)
          end
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

      # The struct layout: plain members placed in order at their own alignment
      # (or at a 1-byte boundary when `packed`), and bit-fields packed into
      # storage units by the System V x86-64 rules, the whole rounded up to the
      # aggregate's alignment. `aligned` (when set) raises that final alignment.
      # Returns [members, size, alignment].
      #
      # A running bit cursor (`bit_pos`, bits from the start) drives both kinds so
      # a bit-field and its neighbours share bytes exactly as gcc lays them out. A
      # bit-field `T name : W` takes the next W bits, but must not straddle a
      # T-sized storage unit: when it would, the cursor advances to the next
      # unit boundary first (6.7.2.1, psABI). A named bit-field always raises the
      # aggregate's alignment to alignof(T). Whether an unnamed one does too is
      # where the two ABIs part company, which is what `unnamed_bitfields_align`
      # selects: the x86-64 System V psABI says "unnamed bit-fields' types do not
      # affect the alignment of a structure", while AAPCS64 has every bit-field's
      # container contribute, so `struct { int : 32; }` is 4-byte aligned there
      # and 1-byte aligned here. Either way an unnamed `T : 0` places nothing and
      # only forces the cursor to the next unit boundary.
      # `packed` never coexists with a bit-field here (the parser rejects that
      # combination), so its 1-byte-boundary branch only governs plain members.
      def layout_struct(raw_members, packed, aligned, unnamed_bitfields_align)
        bit_pos = 0
        max_alignment = 1
        members = []
        raw_members.each do |name, type, bit_width|
          if bit_width.nil?
            member_alignment = packed ? 1 : type.alignment
            byte_offset = align_up(bits_to_bytes(bit_pos), member_alignment)
            members << Member.new(name: name, type: type, offset: byte_offset)
            # A flexible array member (the trailing "T name[]") sits at its
            # element's boundary but contributes nothing to the struct's size —
            # sizeof is as if it were absent (6.7.2.1p18) — so the cursor stops
            # at its offset. Its element alignment still joins the aggregate's
            # (raising it when the element is wider than every earlier member).
            member_size = type.array? && type.incomplete? ? 0 : type.size
            bit_pos = (byte_offset + member_size) * 8
            max_alignment = member_alignment if member_alignment > max_alignment
          else
            bit_pos = place_bitfield(members, name, type, bit_width, bit_pos,
                                     unnamed_bitfields_align) do |alignment|
              max_alignment = alignment if alignment > max_alignment
            end
          end
        end
        struct_alignment = final_alignment(max_alignment, aligned)
        [members, align_up(bits_to_bytes(bit_pos), struct_alignment), struct_alignment]
      end

      # Places one bit-field at bit cursor `bit_pos`, recording a Member for a
      # named one and yielding alignof(T) so #layout_struct can raise the
      # aggregate's alignment — for a named field always, for an unnamed one only
      # when `unnamed_bitfields_align` (AAPCS64). Returns the advanced cursor.
      # A zero-width field is always unnamed (the parser rejects a named one) and
      # merely realigns the cursor to the next storage-unit boundary; it still
      # contributes its container's alignment under AAPCS64, which is why the
      # yield precedes the early return.
      def place_bitfield(members, name, type, bit_width, bit_pos, unnamed_bitfields_align)
        unit_bits = type.size * 8
        yield type.alignment if unnamed_bitfields_align && name.nil?
        return align_up(bit_pos, unit_bits) if bit_width.zero?

        bit_pos = align_up(bit_pos, unit_bits) if (bit_pos % unit_bits) + bit_width > unit_bits
        if name
          members << Member.new(name: name, type: type, offset: bit_pos / 8,
                                bit_width: bit_width, bit_offset: bit_pos)
          yield type.alignment
        end
        bit_pos + bit_width
      end

      # The union layout: every member overlaid at offset 0, the size the widest
      # member's rounded up to the aggregate alignment. `packed` drops the
      # aggregate to a 1-byte boundary and `aligned` raises it. A bit-field is
      # laid at bit 0 and spans ceil(W/8) bytes; a named one raises the alignment
      # to its type's. An unnamed one contributes only its byte span (and a
      # `T : 0` nothing at all) under the x86-64 System V psABI, and its
      # container's alignment as well under AAPCS64 — the same divergence
      # #layout_struct documents, selected by `unnamed_bitfields_align`.
      # Returns [members, size, alignment].
      def layout_union(raw_members, packed, aligned, unnamed_bitfields_align)
        members = []
        max_size = 0
        natural_alignment = 1
        raw_members.each do |name, type, bit_width|
          if bit_width.nil?
            members << Member.new(name: name, type: type, offset: 0)
            byte_size = type.size
            member_alignment = packed ? 1 : type.alignment
          else
            unnamed_alignment = unnamed_bitfields_align && name.nil? ? type.alignment : 1
            if bit_width.zero?
              natural_alignment = unnamed_alignment if unnamed_alignment > natural_alignment
              next
            end

            byte_size = bits_to_bytes(bit_width)
            member_alignment = unnamed_alignment
            if name
              members << Member.new(name: name, type: type, offset: 0,
                                    bit_width: bit_width, bit_offset: 0)
              member_alignment = type.alignment
            end
          end
          max_size = byte_size if byte_size > max_size
          natural_alignment = member_alignment if member_alignment > natural_alignment
        end
        union_alignment = final_alignment(natural_alignment, aligned)
        [members, align_up(max_size, union_alignment), union_alignment]
      end

      # The number of whole bytes needed to hold `bits` bits (rounding up).
      def bits_to_bytes(bits)
        (bits + 7) / 8
      end

      # The aggregate's final alignment: its natural (or packed) alignment,
      # raised to `aligned` when a larger __attribute__((aligned(N))) asks for
      # it. A packed aggregate whose natural alignment is 1 thus still takes N
      # when aligned(N) is combined with packed.
      def final_alignment(natural, aligned)
        aligned && aligned > natural ? aligned : natural
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

    # The AAPCS64 representation of a `va_list` element. AArch64 splits the two
    # register files System V folds into one save area, so the tag has five
    # fields rather than four (AAPCS64 §B.4 / the Arm-64 va_list): `__stack` the
    # next stack argument, `__gr_top` and `__vr_top` the *ends* of the integer
    # and vector save areas, and `__gr_offs` / `__vr_offs` signed byte offsets
    # from those tops. The offsets run the other way from System V's: they start
    # negative (the whole file still to be read) and climb toward zero, at which
    # point the file is spent and the argument comes off `__stack`. The layout
    # (size 32, 8-byte aligned) is what the AArch64 C library agrees on, and the
    # tag compares by identity, so the generator recognizes it exactly as it does
    # the System V one.
    AArch64VaListTag = StructType.new("__va_list").tap do |tag|
      tag.define([
                   ["__stack", Pointer.new(Void)],
                   ["__gr_top", Pointer.new(Void)],
                   ["__vr_top", Pointer.new(Void)],
                   ["__gr_offs", Int],
                   ["__vr_offs", Int]
                 ])
    end

    # The AArch64 counterpart of BuiltinVaList: a one-element array of the
    # five-field tag. Making it an array (rather than the bare struct gcc's
    # __builtin_va_list happens to be) has the same decay-to-pointer effect the
    # System V form relies on, and it is ABI-identical at a call boundary: a
    # 32-byte va_list is passed by reference under AAPCS64 6.4.2 (a pointer to
    # the object in a single integer register), which is exactly what the decayed
    # array pointer already is. Forwarding a va_list to vprintf therefore lands
    # the same pointer in the same register a gcc caller would.
    AArch64BuiltinVaList = Array.new(AArch64VaListTag, 1)

    # The plain-`char` instance a target uses: the signed one when its ABI makes
    # plain `char` signed (x86-64 System V), the unsigned one otherwise
    # (AAPCS64). Neither is `signed char`/`unsigned char`, which keep their own
    # fixed-signedness instances whatever the target.
    def self.plain_char(signed)
      signed ? Char : UnsignedChar
    end

    # True for the character types (6.2.5p15): either plain `char` and the two
    # explicitly signed ones. This is what "an array of character type", the
    # form a string literal may initialize, means; `_Bool` is one byte wide too
    # but is not a character type.
    def self.character?(type)
      type.equal?(Char) || type.equal?(UnsignedChar) ||
        type.equal?(SChar) || type.equal?(UChar)
    end
  end
end
