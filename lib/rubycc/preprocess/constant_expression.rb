# frozen_string_literal: true

require_relative "../front/ast"
require_relative "../type"
require_relative "../compile_error"

module Rubycc
  module Preprocess
    # Parses the controlling constant-expression of a "#if"/"#elif" (ISO C
    # 6.10.1) into a Front::AST the shared ConstantEvaluator can fold. It runs
    # over an already-neutralized Front::Token stream: "defined" has been folded
    # to 1/0, macros have been expanded, and every surviving identifier has been
    # turned into the integer 0 (6.10.1p4), so the only leaves that reach here
    # are integer/character constants and parentheses.
    #
    # The grammar admitted is exactly the integer constant-expression subset the
    # preprocessor allows: unary "+ - ~ !", the binary arithmetic, shift,
    # relational, equality and bitwise operators, "&&"/"||", and "?:". Cast,
    # sizeof, comma and assignment are outside it; those spellings either arrive
    # as a stray punctuator (comma, assignment) or, being keyword-spelled
    # identifiers, have already collapsed to 0, and any leftover token is
    # rejected. Rather than a method per precedence level, a single precedence
    # table drives one climbing loop, so the whole binary grammar is one method.
    class ConstantExpressionParser
      # Each binary operator's binding power (higher binds tighter) and the
      # AST::Binary op it lowers to; "&&" and "||" carry :logical markers since
      # they build their own short-circuiting nodes rather than an AST::Binary.
      BINARY_OPERATORS = {
        "*" => [11, :mul], "/" => [11, :div], "%" => [11, :mod],
        "+" => [10, :add], "-" => [10, :sub],
        "<<" => [9, :shl], ">>" => [9, :shr],
        "<" => [8, :lt], ">" => [8, :gt], "<=" => [8, :le], ">=" => [8, :ge],
        "==" => [7, :eq], "!=" => [7, :ne],
        "&" => [6, :and],
        "^" => [5, :xor],
        "|" => [4, :or],
        "&&" => [3, :logical_and],
        "||" => [2, :logical_or]
      }.freeze

      # The lowest binding power in the table ("||"); the conditional operator
      # sits just below it, so climbing from here collects every binary operator
      # before "?:" is considered.
      LOGICAL_OR_PRECEDENCE = 2

      # The recursion-depth ceiling, mirroring the main parser's guard: a hostile
      # "#if (((...)))" or "#if !!!...1" would otherwise recurse until the Ruby
      # stack overflows with a bare SystemStackError. This grammar is far lighter
      # than the main parser's (a single precedence-climbing loop rather than a
      # deep chain), so its stack gives out only around 2500 nested parentheses;
      # 500 stops a pathological input after roughly 250 levels — an order of
      # magnitude below that, and far above the trivial nesting any real
      # controlling expression uses (well under ten).
      MAX_NESTING_DEPTH = 500

      def initialize(tokens, directive)
        @tokens = tokens
        @pos = 0
        # The directive keyword ("if"/"elif"), used only to name diagnostics.
        @directive = directive
        # Live recursion depth, capped at MAX_NESTING_DEPTH by #with_nesting_guard.
        @depth = 0
      end

      def parse
        node = parse_conditional
        unless current.eof?
          raise_at(current, "extra tokens at end of ##{@directive} expression")
        end

        node
      end

      private

      # conditional-expression: a logical-OR expression optionally followed by
      # "? expression : conditional-expression". Right associativity falls out of
      # recursing on the else arm. Every parenthesized sub-expression re-enters
      # here (a "(" primary recurses back into #parse_conditional), so guarding
      # this entry bounds the depth of nested parentheses and "?:" chains alike.
      def parse_conditional
        with_nesting_guard do
          condition = parse_binary(LOGICAL_OR_PRECEDENCE)
          if current.punct?("?")
            question = advance
            then_expr = parse_conditional
            expect(":", "expected ':' in preprocessor conditional expression")
            else_expr = parse_conditional
            Front::AST::Conditional.new(condition: condition, then_expr: then_expr,
                                        else_expr: else_expr, token: question)
          else
            condition
          end
        end
      end

      # Precedence climbing: parse a unary operand, then keep folding in any
      # binary operator whose binding power meets `min_power`, recursing one
      # level tighter on the right so equal-precedence operators associate left.
      def parse_binary(min_power)
        left = parse_unary
        loop do
          info = current.type == :punct ? BINARY_OPERATORS[current.value] : nil
          break if info.nil? || info[0] < min_power

          power, op = info
          operator = advance
          right = parse_binary(power + 1)
          left = build_binary(op, left, right, operator)
        end
        left
      end

      def build_binary(op, left, right, token)
        case op
        when :logical_and
          Front::AST::LogicalAnd.new(lhs: left, rhs: right, token: token)
        when :logical_or
          Front::AST::LogicalOr.new(lhs: left, rhs: right, token: token)
        else
          Front::AST::Binary.new(op: op, lhs: left, rhs: right, token: token)
        end
      end

      # unary-expression: a chain of "+ - ~ !" prefixes over a primary. Unary "+"
      # folds away; "~x" desugars to "x ^ -1", the same lowering the main parser
      # uses so the evaluator meets a single :xor form. A prefix chain recurses
      # here without passing through #parse_conditional, so it carries its own
      # depth guard against a long "!!!...1"/"~~~...1" run.
      def parse_unary
        with_nesting_guard do
          if current.punct?("+")
            advance
            parse_unary
          elsif current.punct?("-")
            token = advance
            Front::AST::Unary.new(op: :neg, operand: parse_unary, token: token)
          elsif current.punct?("!")
            token = advance
            Front::AST::Unary.new(op: :not, operand: parse_unary, token: token)
          elsif current.punct?("~")
            token = advance
            operand = parse_unary
            Front::AST::Binary.new(op: :xor, lhs: operand, rhs: int_literal(-1, token), token: token)
          else
            parse_primary
          end
        end
      end

      # primary-expression: an integer/character constant, or a parenthesized
      # conditional-expression. Anything else — a leftover operator, a comma, an
      # unmatched paren — is not valid in a preprocessor expression.
      def parse_primary
        token = current
        if token.type == :num
          advance
          int_literal(token.value, token)
        elsif token.punct?("(")
          advance
          node = parse_conditional
          expect(")", "expected ')' in preprocessor expression")
          node
        else
          raise_at(token, "token is not valid in preprocessor expressions")
        end
      end

      # An integer leaf. The value is what the evaluator reads; the type is
      # nominal (this subset folds every intermediate as an unbounded integer),
      # so a single wide signed type stands in for the intmax the preprocessor
      # nominally computes in.
      def int_literal(value, token)
        Front::AST::IntLit.new(value: value, token: token, type: Type::Long)
      end

      # Runs `block` one level deeper, rejecting a pathologically nested
      # controlling expression with a located diagnostic (rather than letting it
      # overflow the Ruby stack) once MAX_NESTING_DEPTH levels are live. The
      # depth is decremented in an ensure so a parse error still unwinds it.
      def with_nesting_guard
        if @depth >= MAX_NESTING_DEPTH
          raise_at(current, "##{@directive} expression nested too deeply")
        end

        @depth += 1
        begin
          yield
        ensure
          @depth -= 1
        end
      end

      def current
        @tokens[@pos]
      end

      def advance
        token = @tokens[@pos]
        @pos += 1 unless token.eof?
        token
      end

      def expect(punct, message)
        raise_at(current, message) unless current.punct?(punct)

        advance
      end

      def raise_at(token, description)
        raise CompileError.new(
          description,
          filename: token.filename, line: token.line, column: token.column,
          source_line: token.source_line
        )
      end
    end
  end
end
