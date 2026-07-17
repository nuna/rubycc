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

      def self.evaluate(node)
        new.evaluate(node)
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
        when AST::SizeofType
          evaluate_sizeof_type(node)
        when AST::AlignofType
          evaluate_alignof_type(node)
        when AST::BuiltinOffsetof
          evaluate_builtin_offsetof(node)
        else
          # Every other node — VariableRef, Call, Assignment,
          # CompoundAssignment, IncDec, MemberAccess, Subscript, StringLit,
          # SizeofExpr, Comma — is not a constant-expression here.
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

        operation = BINARY_OPERATIONS[node.op]
        raise NotConstant, node.token unless operation

        operation.call(evaluate(node.lhs), evaluate(node.rhs))
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
      # not something this evaluator folds.
      def evaluate_cast(node)
        raise NotConstant, node.token unless node.type.integer?

        wrap_to_type(evaluate(node.operand), node.type)
      end

      def wrap_to_type(value, type)
        return value.zero? ? 0 : 1 if type.bool?

        bits = type.size * 8
        wrapped = value & ((1 << bits) - 1)
        return wrapped if type.unsigned? || wrapped < (1 << (bits - 1))

        wrapped - (1 << bits)
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

      # Whether `type` is an incomplete tagged type with no size or alignment: a
      # struct/union never completed, or an incomplete (forward-referenced) enum.
      def incomplete_aggregate?(type)
        (type.struct? && !type.complete?) || type.is_a?(Rubycc::Type::EnumType)
      end
    end
  end
end
