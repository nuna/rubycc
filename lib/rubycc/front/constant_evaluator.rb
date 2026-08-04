# frozen_string_literal: true

require_relative "ast"

module Rubycc
  module Front
    # Evaluates a constant-expression (ISO C 6.6, "conditional-expression" with
    # no assignment, increment/decrement, function call or comma reachable at
    # run time) to a Ruby Integer. Given an expression AST node it walks the
    # node straight away, with no dependency on the Parser or on any symbol
    # table: every enum constant and typedef name the parser might have folded
    # into the tree is already gone by the time this sees it (an enum
    # reference is an ordinary IntLit, see AST::Program), so evaluating the
    # AST alone is enough. A case label, an enumerator, a global initializer
    # and an array bound all reduce their expression through this one
    # evaluator; the preprocessor's "#if" (a later step) is meant to reuse it
    # unchanged, which is why it never touches source positions beyond the
    # token each node already carries.
    #
    # M1 keeps the arithmetic itself simple: every intermediate result is an
    # unbounded Ruby Integer, and a declared type's width/signedness is only
    # brought to bear at a Cast (see #evaluate_cast) — ordinary arithmetic
    # never wraps the way a real `unsigned int` would overflow. No construct
    # this subset admits in a constant expression actually depends on that
    # wraparound yet, so the gap is left open rather than modelled.
    class ConstantEvaluator
      # Raised when some reachable part of the expression is not a
      # constant-expression at all — a variable reference, a function call, an
      # assignment, an increment/decrement, `sizeof` of an expression, or a
      # comma. `token` is the offending node's token, for the caller to build a
      # diagnostic naming its own context ("case label ...", "array size ...").
      class NotConstant < StandardError
        attr_reader :token

        def initialize(token)
          @token = token
          super("expression is not a constant expression")
        end
      end

      # Raised when a division or remainder operator that *is* reached at
      # evaluation time (one on the taken side of "&&"/"||"/"?:" — the other
      # side is never evaluated, so a zero divisor there raises nothing) has a
      # zero right operand. `token` is the operator's token.
      class DivisionByZero < StandardError
        attr_reader :token

        def initialize(token)
          @token = token
          super("division by zero in constant expression")
        end
      end

      # Raised when a __builtin_offsetof designator cannot name a byte offset:
      # its type is not a struct/union or is incomplete, a step names no such
      # member, a subscript step applies to a non-array member, or the target is
      # a bit-field (which has no addressable byte offset). It is a NotConstant
      # so every context that already reports a non-constant expression catches
      # it too; `detail` carries the specific wording for a caller (the
      # generator) that can surface it, over NotConstant's generic message.
      class OffsetofError < NotConstant
        attr_reader :detail

        def initialize(token, detail)
          @detail = detail
          super(token)
        end
      end

      BINARY_OPERATIONS = {
        add: ->(a, b) { a + b },
        sub: ->(a, b) { a - b },
        mul: ->(a, b) { a * b },
        and: ->(a, b) { a & b },
        or: ->(a, b) { a | b },
        xor: ->(a, b) { a ^ b },
        shl: ->(a, b) { a << b },
        # An arithmetic (sign-extending) right shift, which is exactly what
        # Ruby's Integer#>> already does for an arbitrary-precision value.
        shr: ->(a, b) { a >> b },
        eq: ->(a, b) { a == b ? 1 : 0 },
        ne: ->(a, b) { a == b ? 0 : 1 },
        lt: ->(a, b) { a < b ? 1 : 0 },
        le: ->(a, b) { a <= b ? 1 : 0 },
        gt: ->(a, b) { a > b ? 1 : 0 },
        ge: ->(a, b) { a >= b ? 1 : 0 }
      }.freeze

      def self.evaluate(node, sizeof_expr: nil, pointer_int: nil)
        new(sizeof_expr: sizeof_expr, pointer_int: pointer_int).evaluate(node)
      end

      # `sizeof_expr`, when supplied, resolves a `sizeof <expression>` operand
      # (AST::SizeofExpr) to its byte size. The evaluator itself carries no
      # symbol table, so it cannot infer an expression's type on its own; a
      # caller that can (the IR generator, which knows every declaration's type)
      # passes a resolver here so a static initializer or other constant context
      # can fold "sizeof x". Without one, `sizeof <expression>` stays a
      # non-constant, as it is in a context with no type information (an array
      # bound folded during parsing).
      # `pointer_int`, when supplied, folds a pointer→integer cast whose operand
      # is an address constant of a load-time-known absolute value — the
      # "(size_t)&((T*)0)->member" offsetof idiom, whose value is the member's
      # byte offset. The address-constant machinery lives in the IR generator, so
      # a caller that has it (a static initializer) passes a resolver rather than
      # duplicating it here; without one such a cast stays a non-constant.
      def initialize(sizeof_expr: nil, pointer_int: nil)
        @sizeof_expr = sizeof_expr
        @pointer_int = pointer_int
      end

      def evaluate(node)
        case node
        when AST::IntLit
          node.value
        when AST::Unary
          evaluate_unary(node)
        when AST::Binary
          evaluate_binary(node)
        when AST::LogicalAnd
          evaluate_logical_and(node)
        when AST::LogicalOr
          evaluate_logical_or(node)
        when AST::Conditional
          evaluate(node.condition).zero? ? evaluate(node.else_expr) : evaluate(node.then_expr)
        when AST::Cast
          evaluate_cast(node)
        when AST::SizeofExpr
          evaluate_sizeof_expr(node)
        when AST::SizeofType
          evaluate_sizeof_type(node)
        when AST::AlignofType
          evaluate_alignof_type(node)
        when AST::BuiltinOffsetof
          evaluate_builtin_offsetof(node)
        when AST::BuiltinConstantP
          evaluate_builtin_constant_p(node)
        when AST::BuiltinBitScan
          evaluate_builtin_bit_scan(node)
        else
          # Every other node — VariableRef, Call, Assignment,
          # CompoundAssignment, IncDec, MemberAccess, Subscript, StringLit,
          # Comma — is not a constant-expression here.
          raise NotConstant, node.token
        end
      end

      private

      def evaluate_unary(node)
        case node.op
        when :neg then -evaluate(node.operand)
        when :not then evaluate(node.operand).zero? ? 1 : 0
        else raise NotConstant, node.token # :addr, :deref
        end
      end

      def evaluate_binary(node)
        return evaluate_division(node) if node.op == :div || node.op == :mod
        return evaluate_pointer_subtraction(node) if node.op == :sub

        operation = BINARY_OPERATIONS[node.op]
        raise NotConstant, node.token unless operation

        operation.call(evaluate(node.lhs), evaluate(node.rhs))
      end

      # Subtraction is ordinary integer arithmetic unless that fails and both
      # operands are addresses this evaluator can place on its own (see
      # #pointer_target) — the traditional "((size_t)(char *)&((t *)0)->m -
      # (char *)0)" offsetof idiom, and its relatives with any pointed-to type,
      # not only "char *". C's pointer-difference rule (6.5.6p9) then applies:
      # the byte difference is divided by the shared pointed-to type's size,
      # which must be identical on both sides and have one ("void *" and an
      # incomplete type do not) for the division to mean anything. When
      # #pointer_difference cannot place the difference this way it returns
      # nil, and the original NotConstant from the ordinary attempt is what
      # reaches the caller instead.
      def evaluate_pointer_subtraction(node)
        BINARY_OPERATIONS[:sub].call(evaluate(node.lhs), evaluate(node.rhs))
      rescue NotConstant
        difference = pointer_difference(node)
        raise if difference.nil?

        difference
      end

      # The [byte-difference / pointed-to-size] quotient of "lhs - rhs" when
      # both sides are addresses #pointer_target can place, or nil when either
      # side is not one or the two pointed-to types do not share a size. A
      # non-zero remainder never happens for two addresses this evaluator
      # itself derived from the same struct layout, but is still checked
      # rather than silently truncated, surfacing as an (unfolded) NotConstant.
      def pointer_difference(node)
        lhs = pointer_target(node.lhs)
        return nil if lhs.nil?

        rhs = pointer_target(node.rhs)
        return nil if rhs.nil?

        lhs_address, lhs_type = lhs
        rhs_address, rhs_type = rhs
        return nil unless sized?(lhs_type) && sized?(rhs_type) && lhs_type.size == rhs_type.size

        byte_difference = lhs_address - rhs_address
        raise NotConstant, node.token unless (byte_difference % lhs_type.size).zero?

        byte_difference / lhs_type.size
      end

      # Division and remainder truncate toward zero (6.5.5p6), unlike Ruby's
      # own "/" and "%", which floor. -7 / 2 is -3, not -4, and -7 % 2 is -1,
      # not 1.
      def evaluate_division(node)
        lhs = evaluate(node.lhs)
        rhs = evaluate(node.rhs)
        raise DivisionByZero, node.token if rhs.zero?

        quotient = lhs.abs / rhs.abs
        quotient = -quotient if (lhs.negative?) != (rhs.negative?)
        node.op == :div ? quotient : lhs - (quotient * rhs)
      end

      # Short-circuits exactly like the run-time operator: the right operand
      # is not evaluated (and so cannot raise DivisionByZero) once the left
      # settles the result on its own.
      def evaluate_logical_and(node)
        return 0 if evaluate(node.lhs).zero?

        evaluate(node.rhs).zero? ? 0 : 1
      end

      def evaluate_logical_or(node)
        return 1 unless evaluate(node.lhs).zero?

        evaluate(node.rhs).zero? ? 0 : 1
      end

      # A cast to an integer type wraps the operand's value into that type's
      # width and signedness; any other destination (a pointer, a struct) is
      # not something this evaluator folds. When the operand is itself a
      # floating-point constant (a literal, or a negated literal — a nested
      # cast such as "(long)(double)1e2" is not chased any further), 6.3.1.4p1
      # truncates it toward zero before the wrap; #evaluate never sees a Float
      # for any other node, so the arithmetic above stays purely integral.
      def evaluate_cast(node)
        raise NotConstant, node.token unless node.type.integer?

        float_value = float_constant_value(node.operand)
        return wrap_to_type(float_value.truncate, node.type) unless float_value.nil?

        wrap_to_type(evaluate_integer_or_address(node.operand), node.type)
      end

      # The integer value of a cast-to-integer operand: an integer constant
      # expression normally, but a pointer→integer cast has a pointer operand the
      # evaluator does not fold as an ordinary expression. One shape it folds
      # itself is the traditional "(size_t)&((T*)0)->m" offsetof idiom, whose
      # address is a member offset from a constant base and so needs nothing but
      # the struct layout the evaluator already reads (see
      # #absolute_pointer_value). When that does not apply and a @pointer_int
      # resolver is supplied, the operand is offered there instead; the resolver
      # returns the pointer's absolute integer value or re-raises NotConstant.
      def evaluate_integer_or_address(operand)
        evaluate(operand)
      rescue NotConstant
        absolute = absolute_pointer_value(operand)
        return absolute unless absolute.nil?
        raise unless @pointer_int

        @pointer_int.call(operand)
      end

      # The absolute integer value of a pointer-valued operand this evaluator can
      # place on its own — "&((T *)N)->m" and its relatives, where the address-of
      # applies to a designator rooted at a pointer cast of an integer constant,
      # or such a cast written on its own. That is the offsetof idiom a header
      # writes as "((size_t)&((T *)0)->m)", whose value is the member's byte
      # offset; folding it here rather than through a resolver makes it a
      # constant in every context, the parser's (a _Static_assert, an enumerator,
      # a bit-field width, an array bound) as much as the generator's. Anything
      # else is nil, an address only known at link time (a global's) included,
      # which the @pointer_int resolver still handles.
      def absolute_pointer_value(node)
        case node
        when AST::Unary
          return nil unless node.op == :addr

          address, = designator_address(node.operand)
          address
        when AST::Cast
          pointer_target(node)&.first
        end
      end

      # The [absolute address, pointed-to type] a pointer-valued expression
      # denotes when its value is a compile-time constant: a cast to pointer type
      # over an integer constant (or over another such pointer, as
      # "(T *)(void *)0" writes it), or the address of a designator #designator_address
      # can place. An array-typed operand never reaches here — the idiom's base is
      # always a cast — so no array-to-pointer decay is modelled.
      def pointer_target(node)
        case node
        when AST::Cast
          return nil unless node.type.pointer?

          address = constant_integer(node.operand) || pointer_target(node.operand)&.first
          address.nil? ? nil : [address, node.type.target]
        when AST::Unary
          return nil unless node.op == :addr

          designator_address(node.operand)
        when AST::Binary
          pointer_offset_target(node)
        end
      end

      # "pointer + integer" and "pointer - integer" (6.5.6p8) over a pointer
      # #pointer_target already places: the address moves by the integer
      # operand times the pointed-to type's size, on whichever side of "+" the
      # pointer operand is ("p + 1" and "1 + p" are both valid), or only the
      # left side of "-" ("1 - p" is not a pointer expression at all). nil when
      # neither operand is a foldable pointer, the other is not an integer
      # constant, or the pointed-to type has no size to stride by.
      def pointer_offset_target(node)
        return nil unless node.op == :add || node.op == :sub

        lhs_pointer = pointer_target(node.lhs)
        if lhs_pointer
          offset = constant_integer(node.rhs)
          return nil if offset.nil?

          return pointer_advance(lhs_pointer, node.op == :sub ? -offset : offset)
        end

        return nil if node.op == :sub

        rhs_pointer = pointer_target(node.rhs)
        return nil if rhs_pointer.nil?

        offset = constant_integer(node.lhs)
        return nil if offset.nil?

        pointer_advance(rhs_pointer, offset)
      end

      # [address + offset * pointed-to size, pointed-to type], or nil when the
      # pointed-to type has no size to stride by (void, a function, an
      # incomplete aggregate or array).
      def pointer_advance(pointer, offset)
        address, type = pointer
        return nil unless sized?(type)

        [address + (offset * type.size), type]
      end

      # The [absolute address, type] of a designator whose base is a pointer of
      # constant value: "*(T *)N" is [N, T], a member access adds the member's
      # offset (6.7.2.1's layout, the same one #offsetof_member_step walks) and a
      # subscript adds the index times the element size. nil for every other
      # designator — one rooted at a named object, or at a pointer whose value is
      # not constant.
      #
      # Unlike the __builtin_offsetof steps this mirrors, a step that names no
      # byte offset (an unknown member, a bit-field, a subscript of a non-array)
      # yields nil rather than an OffsetofError: the expression is an ordinary
      # one the surrounding context still type-checks, so leaving it unfolded
      # keeps that context's own diagnostic instead of pre-empting it here.
      def designator_address(node)
        case node
        when AST::Unary
          node.op == :deref ? pointer_target(node.operand) : nil
        when AST::MemberAccess
          member_designator_address(node)
        when AST::Subscript
          subscript_designator_address(node)
        end
      end

      # "base->m" over a constant pointer, or "base.m" over a designator already
      # placed, adds the member's offset to the base address.
      def member_designator_address(node)
        base = node.arrow ? pointer_target(node.base) : designator_address(node.base)
        return nil if base.nil?

        address, type = base
        return nil unless type.struct? && type.complete?

        member = type.member(node.member)
        return nil if member.nil? || member.bitfield?

        [address + member.offset, member.type]
      end

      # "base[i]" strides by the element size: over a constant pointer ("((T *)N)[i]")
      # the element is what it points to, over an array designator
      # ("((T *)0)->a[i]") it is the array's element type. A non-constant index,
      # or an element with no size, leaves the address unfolded.
      def subscript_designator_address(node)
        index = constant_integer(node.index)
        return nil if index.nil?

        address, element = subscript_base(node.target)
        return nil if address.nil? || !sized?(element)

        [address + (index * element.size), element]
      end

      # Whether `type` has a byte size a subscript can stride by — every type
      # but void, a function, an incomplete aggregate and an unbounded array.
      def sized?(type)
        return false if type.void? || type.function? || incomplete_aggregate?(type)

        !(type.array? && type.incomplete?)
      end

      # The [base address, element type] a subscript strides over, or nil when
      # neither form applies.
      def subscript_base(target)
        pointer = pointer_target(target)
        return pointer if pointer

        address, type = designator_address(target)
        address.nil? || !type.array? ? nil : [address, type.element]
      end

      # `node`'s value as an integer constant, or nil when it is not one. Used
      # where a non-constant sub-expression only means the surrounding address
      # stays unfolded, rather than being a failure to report.
      def constant_integer(node)
        evaluate(node)
      rescue NotConstant, DivisionByZero
        nil
      end

      # The Float a floating-point constant operand denotes, or nil when
      # `node` is not one — a plain FloatLit, or a unary minus directly over
      # one.
      def float_constant_value(node)
        case node
        when AST::FloatLit
          node.value
        when AST::Unary
          return nil unless node.op == :neg && node.operand.is_a?(AST::FloatLit)

          -node.operand.value
        end
      end

      def wrap_to_type(value, type)
        return value.zero? ? 0 : 1 if type.bool?

        bits = type.size * 8
        wrapped = value & ((1 << bits) - 1)
        return wrapped if type.unsigned? || wrapped < (1 << (bits - 1))

        wrapped - (1 << bits)
      end

      # sizeof(expression) folds to the byte size of the operand's type, which
      # only a caller carrying type information can supply (see #initialize): the
      # resolver returns the size, applying the same "no size" rejections
      # sizeof(type-name) does. Without a resolver it is a non-constant, so a
      # context with no type table (an array bound folded while parsing) reports
      # "not an integer constant" rather than a wrong value.
      def evaluate_sizeof_expr(node)
        raise NotConstant, node.token unless @sizeof_expr

        @sizeof_expr.call(node)
      end

      # sizeof(type-name) folds to the type's byte size; an incomplete type
      # (void, a struct/union never completed, or a forward-referenced enum) has
      # none to fold.
      def evaluate_sizeof_type(node)
        type = node.type
        raise NotConstant, node.token if type.void? || incomplete_aggregate?(type)

        type.size
      end

      # _Alignof(type-name) folds to the type's alignment; a void, function or
      # incomplete type has no alignment to fold, matching what the generator
      # rejects for the same construct.
      def evaluate_alignof_type(node)
        type = node.type
        if type.void? || type.function? || incomplete_aggregate?(type)
          raise NotConstant, node.token
        end

        type.alignment
      end

      # __builtin_offsetof(type-name, member-designator) folds to the byte offset
      # of the designated member, walking the designator one step at a time from
      # the aggregate type. A member step adds the member's offset and descends
      # into its type; a subscript step (over an array member) adds the index
      # times the element size and descends into the element type. Every failure
      # — a non-aggregate or incomplete type, a missing member, a subscript of a
      # non-array, or a bit-field target with no addressable offset — is an
      # OffsetofError carrying the diagnostic wording. The member lookup goes
      # through Type::StructType#member, so an anonymous struct/union member is
      # traversed transparently with its own offset already folded in.
      def evaluate_builtin_offsetof(node)
        type = node.type
        offset = 0
        node.designator.each do |step|
          case step
          when AST::OffsetofMember
            offset, type = offsetof_member_step(type, step, offset)
          when AST::OffsetofIndex
            offset, type = offsetof_index_step(type, step, offset)
          end
        end
        offset
      end

      def offsetof_member_step(type, step, offset)
        unless type.struct?
          raise OffsetofError.new(step.token,
                                  "request for member '#{step.name}' in something not a structure or union")
        end
        unless type.complete?
          raise OffsetofError.new(step.token, "offsetof of incomplete type '#{type}'")
        end

        member = type.member(step.name)
        raise OffsetofError.new(step.token, "no member named '#{step.name}' in '#{type}'") if member.nil?
        if member.bitfield?
          raise OffsetofError.new(step.token, "attempt to get the offset of a bit-field member '#{step.name}'")
        end

        [offset + member.offset, member.type]
      end

      def offsetof_index_step(type, step, offset)
        unless type.array?
          raise OffsetofError.new(step.token, "subscripted value in offsetof is not an array")
        end

        index = evaluate(step.index)
        [offset + index * type.element.size, type.element]
      end

      # __builtin_constant_p(expr) folds to 1 when its operand is itself a
      # constant-expression and 0 otherwise. The operand is probed by trying to
      # evaluate it: success means it reduced to a constant (so 1), while a
      # NotConstant (a variable, call, ...) or a DivisionByZero means it did not
      # (so 0). It never propagates the failure — unlike an ordinary
      # sub-expression, a non-constant operand here is a legitimate 0, not an
      # error — so the probe swallows both. The operand is evaluated only to test
      # foldability; the caller discards the value.
      def evaluate_builtin_constant_p(node)
        evaluate(node.expr)
        1
      rescue NotConstant, DivisionByZero
        0
      end

      # __builtin_ctz/clz(x) folds to the trailing/leading zero-bit count of a
      # constant operand, over its `width`-byte value, matching gcc so the same
      # fold serves a HAVE_BUILTIN___BUILTIN_CLZLL-guarded constant context. A
      # zero operand is undefined behavior (gcc), so it is left unfolded (a
      # NotConstant) rather than given an arbitrary value.
      def evaluate_builtin_bit_scan(node)
        bits = node.width * 8
        value = evaluate(node.operand) & ((1 << bits) - 1)
        raise NotConstant, node.token if value.zero?

        if node.direction == :forward
          (value & -value).bit_length - 1        # trailing zero count
        else
          bits - value.bit_length                # leading zero count
        end
      end

      # Whether `type` is an incomplete tagged type with no size or alignment: a
      # struct/union never completed, or an incomplete (forward-referenced) enum.
      def incomplete_aggregate?(type)
        (type.struct? && !type.complete?) || type.is_a?(Rubycc::Type::EnumType)
      end
    end
  end
end
