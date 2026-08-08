# frozen_string_literal: true

require_relative "ast"
require_relative "../type"
require_relative "../compile_error"

module Rubycc
  module Front
    # One scalar placed by an initializer: `value` (an expression node) writes
    # `type` (a scalar Rubycc::Type) at byte `offset` from the object's start.
    # The caller evaluates `value` in its own context — folded to a constant for
    # a global, generated and narrowed for a local — so the resolver stays free
    # of the generator and of constant evaluation.
    ScalarInit = Data.define(:offset, :type, :value)

    # A scalar placed into a bit-field. `offset` identifies the containing
    # storage unit; `shift` is the field's bit position within that unit. It
    # stays separate from ScalarInit because a bit-field initializer must be a
    # read-modify-write, not a whole-width scalar store at the member's byte.
    BitfieldInit = Data.define(:offset, :type, :value, :width, :shift)

    # A run of literal bytes a string initializer places at `offset` (the raw
    # string-literal bytes, without the terminating NUL). The caller zero-fills
    # the whole object first, so the NUL and any trailing array slots come for
    # free and are not recorded here.
    StringInit = Data.define(:offset, :bytes)

    # A whole aggregate expression copied into an aggregate subobject at
    # `offset`. C permits an initializer-list element to be a single expression
    # of the subobject's own structure/union type (6.7.9p13) -- a compound
    # literal such as `.base = (Node){ .type = 1 }`, a call returning that
    # struct, a variable of it; it is an expression initializer, not a
    # brace-elided walk of the outer cursor.
    AggregateInit = Data.define(:offset, :type, :value)

    # The outcome of resolving an initializer: `type` is the object's type with
    # any "[]" array bound now filled in (so sizeof and the storage layout see a
    # complete type), `entries` is the flat list of ScalarInit/BitfieldInit/
    # StringInit/AggregateInit placements
    # placements, in source order, that the caller lowers, and `flexible_bytes`
    # is the storage an initialized flexible array member adds *beyond*
    # `type.size` (0 for every other object; see #fill_flexible_array_member).
    ResolvedInitializer = Data.define(:type, :entries, :flexible_bytes)

    # Resolves an initializer (6.7.9) against the object's type into a flat list
    # of scalar/string placements plus a completed type. The whole current-object
    # walk lives here — nested braces, brace elision (an aggregate subobject with
    # no braces of its own keeps drawing from the enclosing list), designated
    # initializers ("[i] = ", ".m = ", and chains such as ".a.b = "), the "{0}"
    # idiom, unions (the first member by default, any member by designator) and
    # transparent designation into an anonymous member — so both the local and
    # the global lowering share one interpretation and neither re-implements it.
    #
    # What it deliberately leaves out: it never evaluates a scalar's value (that
    # is the caller's, since a constant fold and a run-time store differ), and it
    # never type-checks a scalar against its slot (the caller applies the
    # ordinary assignment conversion). It only diagnoses the structural errors —
    # excess elements, a braced list for a scalar, an unknown member, an
    # out-of-range index and an over-long char-array string — that
    # depend on the shape alone.
    class InitializerResolver
      # A forward cursor over one brace level's items. Brace elision hands the
      # same cursor to a subobject's fill so it continues where the parent left
      # off; an explicit nested brace gets a fresh cursor over its own items.
      class Cursor
        def initialize(items)
          @items = items
          @pos = 0
        end

        def eof?
          @pos >= @items.size
        end

        def peek
          @items[@pos]
        end

        def advance
          item = @items[@pos]
          @pos += 1
          item
        end
      end

      # Whether `init` initializes `type` structurally (needs this resolver)
      # rather than as a plain scalar value: a brace list always does, and so
      # does a bare string literal aimed at a char array. Both the parser (to
      # decide whether to fold or defer) and the generator consult this.
      def self.structural?(type, init)
        init.is_a?(AST::InitializerList) ||
          (char_array?(type) && init.is_a?(AST::StringLit))
      end

      # An array of character type — the one aggregate a string literal may
      # initialize as a whole (6.7.9p14). Any of the three character types
      # qualifies (plain `char` under either target signedness, `signed char`,
      # `unsigned char`), since the literal's bytes are copied in unchanged.
      def self.char_array?(type)
        type.array? && Type.character?(type.element)
      end

      # `static_storage` says the object being initialized lives in .data/.bss
      # (a file-scope definition or a block-scope `static`), which is the only
      # place a trailing flexible array member may be initialized.
      #
      # `type_of` is how the caller lends this resolver its view of expression
      # types: a callable taking an expression node and answering its
      # Rubycc::Type, or nil when it cannot tell (see #single_expression_init?,
      # which is the only thing that asks). It must not emit code or evaluate
      # anything — the generator passes its #static_type inference, the parser
      # the smaller one it uses for parse-time sizeof. A caller with no type
      # table at all may leave it out, and every subobject then falls to brace
      # elision as it did before the hook existed.
      def self.resolve(type, initializer, static_storage: false, type_of: nil)
        new.resolve(type, initializer, static_storage: static_storage, type_of: type_of)
      end

      def resolve(type, initializer, static_storage: false, type_of: nil)
        @entries = []
        @static_storage = static_storage
        @type_of = type_of
        @flexible_bytes = 0
        # Only the object's *own* trailing flexible array member may be
        # initialized; one reached through a nested struct is rejected, so
        # remember which struct owns the one initializer this run may fill.
        @flexible_owner = type.struct? ? type : nil
        final = init_top(type, initializer)
        ResolvedInitializer.new(final, @entries, @flexible_bytes)
      end

      private

      # The outermost object. A char array taking a (possibly braced) string,
      # then a scalar taking a plain expression, are the two non-list forms;
      # everything else is a brace list dispatched by the object's kind.
      def init_top(type, initializer)
        if self.class.char_array?(type) && (bytes = string_bytes(initializer))
          return place_string(type, 0, bytes, initializer)
        end

        unless initializer.is_a?(AST::InitializerList)
          return place_scalar_value(type, 0, initializer)
        end

        init_object_from_list(type, 0, initializer)
      end

      # A scalar initialized by a plain (non-brace) expression: record it as is.
      # Only a scalar reaches here off the non-list path; an aggregate without
      # braces (and without the char-array string form) has no meaning.
      def place_scalar_value(type, offset, value)
        unless scalar?(type)
          error(value.token, "invalid initializer for aggregate (expected '{')")
        end
        @entries << ScalarInit.new(offset, type, value)
        type
      end

      # Initializes `type` at `base` from an explicit brace list. A scalar in
      # braces ("int x = {5};") is unwrapped; an aggregate is walked by its kind,
      # then any leftover item is an excess element.
      def init_object_from_list(type, base, list)
        # GCC accepts the empty compound literal used by yajl-ruby, and C23
        # standardizes the same zero-initializer form. The lowering zero-fills
        # the whole object before applying entries, so no entry is needed here.
        return type if list.items.empty?

        return init_scalar_from_list(type, base, list) if scalar?(type)

        require_layout(type, list.token)
        cursor = Cursor.new(list.items)
        final = fill_aggregate(type, base, cursor)
        unless cursor.eof?
          error(item_token(cursor.peek), "excess elements in initializer")
        end
        final
      end

      # "int x = {5};" (6.7.9p11): exactly one item, no designator, no inner
      # brace; more than one item, or a designator, or a nested brace is an
      # error.
      def init_scalar_from_list(type, base, list)
        first = list.items.first
        unless first.designators.empty?
          error(first.designators.first.token, "designator in initializer for scalar type")
        end
        if first.value.is_a?(AST::InitializerList)
          error(first.value.token, "too many braces around scalar initializer")
        end
        if list.items.size > 1
          error(item_token(list.items[1]), "excess elements in scalar initializer")
        end
        @entries << ScalarInit.new(base, type, first.value)
        type
      end

      # Dispatches an aggregate to its kind-specific fill, returning the (possibly
      # length-completed) type. Only a top-level "[]" array is ever incomplete;
      # a nested one always has a fixed bound.
      def fill_aggregate(type, base, cursor)
        if type.array?
          max = fill_array(type, base, cursor)
          type.length ? type : Type::Array.new(type.element, max + 1)
        elsif type.union?
          fill_union(type, base, cursor)
          type
        else
          fill_struct(type, base, cursor)
          type
        end
      end

      # Fills array elements in order, honoring "[i]" designators (which jump the
      # cursor and continue from i+1) and stopping when the fixed bound is reached
      # or a designator that is not ours appears (it belongs to an enclosing
      # object). Returns the greatest index touched, so a top-level "[]" bound can
      # be inferred as that plus one.
      def fill_array(type, base, cursor)
        element = type.element
        index = 0
        highest = -1
        until cursor.eof?
          item = cursor.peek
          designator = item.designators.first
          if designator
            break unless designator.is_a?(AST::ArrayDesignator)

            index = designator.index
            check_array_index(type, designator)
            rest = item.designators[1..]
          else
            break if type.length && index >= type.length

            rest = []
          end
          init_subobject(element, base + index * element.size, cursor, item, rest)
          highest = index if index > highest
          index += 1
        end
        highest
      end

      # Fills struct members in order, honoring ".m" designators (which reposition
      # to that member — transparently into an anonymous member — and continue
      # from the one after) and stopping at the last member or a non-member
      # designator meant for an enclosing object.
      def fill_struct(type, base, cursor)
        members = type.members
        index = 0
        until cursor.eof?
          item = cursor.peek
          designator = item.designators.first
          if designator
            break unless designator.is_a?(AST::MemberDesignator)

            member, index = locate_member(type, designator)
            fill_member(type, member, base, cursor, item, item.designators[1..], designated: true)
            index += 1
          else
            break if index >= members.size

            member = members[index]
            fill_member(type, member, base, cursor, item, [])
            index += 1
          end
        end
      end

      # Places `item` into one member of `type`. A flexible array member takes
      # the separate path below, since it has no reserved storage of its own and
      # so decides how much the object grows.
      def fill_member(type, member, base, cursor, item, designators, designated: false)
        if flexible_array_member?(member)
          fill_flexible_array_member(type, member, base, cursor, item, designators)
        else
          init_subobject(member.type, base + member.offset, cursor, item, designators, member,
                         designated: designated)
        end
      end

      # The trailing "T name[]" of a struct (6.7.2.1p18): an array member with
      # no bound, hence an incomplete type.
      def flexible_array_member?(member)
        member.type.array? && member.type.incomplete?
      end

      # An initializer directed at a flexible array member. ISO C reserves no
      # storage for one (it contributes nothing to sizeof), so the standard has
      # no meaning for this; gcc extends the language to allow it for an object
      # with static storage duration, laying the elements out at the member's
      # offset and widening the *object* past its type's size. Measured against
      # gcc: the object occupies sizeof(struct) + n * sizeof(element) bytes for
      # n elements (so the struct's own trailing padding stays, and the extra
      # bytes ride behind it), the count n is the highest element index any item
      # reaches plus one whatever order the items arrive in, and an initialized
      # FAM at automatic storage duration, or one reached through a nested
      # struct, is rejected. `@flexible_bytes` carries n * sizeof(element) out
      # to the caller, which sizes the object's image by it.
      def fill_flexible_array_member(type, member, base, cursor, item, designators)
        unless type.equal?(@flexible_owner)
          error(item_token(item), "initialization of a flexible array member in a nested context")
        end
        unless @static_storage
          error(item_token(item), "non-static initialization of a flexible array member")
        end

        element = member.type.element
        offset = base + member.offset
        count = flexible_array_count(member, offset, cursor, item, designators)
        @flexible_bytes = count * element.size if count * element.size > @flexible_bytes
      end

      # How many elements an item directed at a flexible array member reaches.
      # A leading "[i]" designator names one element, so it reaches i + 1; every
      # other form (a brace list, a string, or brace elision drawing from the
      # enclosing list) fills the member as a whole, and the bound the fill
      # infers for the unbounded array is the count.
      def flexible_array_count(member, offset, cursor, item, designators)
        if designators.first.is_a?(AST::ArrayDesignator)
          index = designators.first.index
          init_subobject(member.type, offset, cursor, item, designators, member)
          index + 1
        else
          completed = init_subobject(member.type, offset, cursor, item, designators, member)
          (completed.is_a?(Type::Array) && completed.length) || 0
        end
      end

      # A union holds one member at a time: the first by default, or the one a
      # leading ".m" designator selects. Exactly one item is consumed here; any
      # further items are surfaced as excess by the enclosing list.
      def fill_union(type, base, cursor)
        return if cursor.eof?

        item = cursor.peek
        designator = item.designators.first
        if designator.is_a?(AST::MemberDesignator)
          member, = locate_member(type, designator)
          init_subobject(member.type, base + member.offset, cursor, item, item.designators[1..], member,
                         designated: true)
        elsif designator
          # An array designator here is for an enclosing object; leave it.
          nil
        else
          member = type.members.first
          init_subobject(member.type, base + member.offset, cursor, item, [], member)
        end
      end

      # Places one item into the subobject at (sub_type, sub_offset). A remaining
      # designator chain first steps deeper (".a.b" / "[1].m"); with none left,
      # the item's value initializes the subobject: a char array takes a string,
      # a nested brace recurses with its own cursor, a scalar is recorded, and a
      # braceless aggregate elides — it keeps drawing from the *same* cursor.
      def init_subobject(sub_type, sub_offset, cursor, item, designators, member = nil, designated: false)
        unless designators.empty?
          inner_type, inner_offset, inner_member = step_designator(sub_type, sub_offset, designators.first)
          return init_subobject(inner_type, inner_offset, cursor, item, designators[1..], inner_member,
                                designated: true)
        end

        value = item.value
        if self.class.char_array?(sub_type) && (bytes = string_bytes(value))
          cursor.advance
          place_string(sub_type, sub_offset, bytes, value)
        elsif value.is_a?(AST::InitializerList)
          cursor.advance
          init_object_from_list(sub_type, sub_offset, value)
        elsif single_expression_init?(sub_type, value, designated)
          cursor.advance
          @entries << AggregateInit.new(sub_offset, sub_type, value)
        elsif scalar?(sub_type)
          cursor.advance
          if member&.bitfield?
            unit_bits = member.type.size * 8
            unit_offset = (member.bit_offset / unit_bits) * member.type.size
            shift = member.bit_offset % unit_bits
            unit_base = sub_offset - member.offset + unit_offset
            @entries << BitfieldInit.new(unit_base, sub_type, value, member.bit_width, shift)
          else
            @entries << ScalarInit.new(sub_offset, sub_type, value)
          end
        else
          # Brace elision (6.7.9p20): a braceless aggregate subobject consumes as
          # many following items as it needs from the shared cursor.
          require_layout(sub_type, value.token)
          fill_aggregate(sub_type, sub_offset, cursor)
        end
      end

      # An incomplete struct/union has no known layout, so it cannot be
      # initialized; the generator's own completeness guards never see it,
      # because the resolver walks the type first.
      def require_layout(type, token)
        return unless type.struct? && !type.complete?

        error(token, "initialization of incomplete type '#{type}'")
      end

      # Records a char array's string initializer and, for a top-level "[]",
      # completes its bound to the string length plus the NUL. An array sized
      # exactly to the character count (excluding the NUL) is allowed (6.7.9p14):
      # the terminating NUL is simply dropped, so "char x[3] = \"abc\"" fills the
      # array with no room to spare. Only a string longer than the array — one
      # whose characters alone will not fit — is diagnosed as too long.
      def place_string(type, offset, bytes, node)
        length = type.length || bytes.bytesize + 1
        if length < bytes.bytesize
          error(node.token, "initializer-string for char array is too long")
        end
        @entries << StringInit.new(offset, bytes)
        Type::Array.new(type.element, length)
      end

      # Steps one designator into an aggregate, returning the [type, offset] of
      # the named/indexed subobject; a member step resolves transparently through
      # anonymous members.
      def step_designator(type, base, designator)
        if designator.is_a?(AST::MemberDesignator)
          unless type.struct?
            error(designator.token, "field designator '.#{designator.name}' in non-struct initializer")
          end
          member = type.member(designator.name) ||
                   error(designator.token, "unknown field designator '.#{designator.name}'")
          [member.type, base + member.offset, member]
        else
          unless type.array?
            error(designator.token, "array designator in non-array initializer")
          end
          check_array_index(type, designator)
          [type.element, base + designator.index * type.element.size, nil]
        end
      end

      # The member a ".m" designator names, plus the index in `type.members` to
      # continue positional filling from. A direct member gives its own index; a
      # name reached through an anonymous member gives that anonymous member's
      # index (so the next positional item lands after it).
      def locate_member(type, designator)
        direct = type.members.index { |m| m.name == designator.name }
        return [type.members[direct], direct] if direct

        member = type.member(designator.name) ||
                 error(designator.token, "unknown field designator '.#{designator.name}'")
        containing = type.members.index do |m|
          m.name.nil? && m.type.struct? && m.type.member(designator.name)
        end
        [member, containing || type.members.size - 1]
      end

      # Rejects a negative or past-the-end array designator; a top-level "[]"
      # (unknown bound) only rejects a negative index.
      def check_array_index(type, designator)
        if designator.index.negative? || (type.length && designator.index >= type.length)
          error(designator.token, "array designator index #{designator.index} exceeds array bounds")
        end
      end

      # The raw bytes of a string that initializes a char array — a bare string
      # literal, or a brace wrapping exactly one undesignated string literal
      # ('char s[] = { "hi" };'); anything else is not a string initializer.
      def string_bytes(node)
        return node.value if node.is_a?(AST::StringLit)

        if node.is_a?(AST::InitializerList) && node.items.size == 1
          item = node.items.first
          return item.value.value if item.designators.empty? && item.value.is_a?(AST::StringLit)
        end
        nil
      end

      def scalar?(type)
        !type.array? && !type.struct?
      end

      # Whether `value` initializes the whole subobject as a single expression,
      # rather than being the next item brace elision drops into the subobject's
      # innermost member. 6.7.9p13 draws that line by *type*, not by syntax and
      # not by whether a designator named the subobject: the initializer for a
      # structure or union object is either a brace list "or a single expression
      # that has compatible structure or union type". So the question here is
      # only whether the expression's type is that of the struct/union subobject
      # standing at the cursor.
      #
      # A designator does not enter into it, which is why the earlier
      # approximation (any call/variable/member expression counts as an
      # aggregate when designated, never when reached positionally) was wrong in
      # both directions, as measured against gcc:
      #
      #   MapInit m = { map, TypeInfo_get(f), TypeInfo_get(g), arena };
      #
      # has no designator anywhere, yet gcc initializes the two TypeInfo members
      # from the calls that return TypeInfo (google-protobuf's message.c writes
      # exactly this, and rubycc rejected it with "incompatible types in
      # initialization"); while
      #
      #   pt a[] = { 1, 2, 3, f(), 9, 10 };   /* int f(void) */
      #
      # is a two-element array for gcc because f() is an ordinary scalar item
      # mid-elision -- and a three-element one when the same call returns pt,
      # since then the expression fills a whole element. Only the type tells the
      # two apart.
      #
      # An expression whose type is unknown (no `type_of` hook, or a form it
      # does not cover) stays on the brace-elision path, which is what preserves
      # `{ 0 }` and the ordinary positional rules.
      # `designated` says a designator named this subobject, and only matters
      # when no `type_of` hook was lent (the parser resolves with no type table
      # at all, purely to complete an inferred array bound). There, a designator
      # naming a struct/union subobject whose item is not a brace list leaves
      # exactly one reading open under 6.7.9p13 -- the single-expression form --
      # because brace elision cannot descend into a subobject the designator
      # already selected. Guessing that way keeps the parser's type completion
      # working; the generator re-resolves the same initializer *with* the hook,
      # so a genuinely mistyped expression is still caught, by the pass that can
      # actually see the type.
      def single_expression_init?(sub_type, value, designated = false)
        return false unless sub_type.struct?

        value_type = expression_type(value)
        return designated if value_type.nil?

        value_type.struct? && value_type == sub_type
      end

      # The type of an initializer item's expression, or nil when it cannot be
      # told here. A compound literal and a cast name their own type, so they
      # are answered without help and identically on every caller's path;
      # everything else needs the surrounding scope and goes to the caller's
      # `type_of` hook.
      def expression_type(node)
        case node
        when AST::CompoundLiteral, AST::Cast
          node.type
        else
          @type_of&.call(node)
        end
      end

      # The token that locates an item for diagnostics: its first designator, or
      # its value.
      def item_token(item)
        item.designators.first&.token || item.value.token
      end

      def error(token, description)
        raise CompileError.new(
          description,
          filename: token.filename,
          line: token.line,
          column: token.column,
          source_line: token.source_line
        )
      end
    end
  end
end
