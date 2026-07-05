# frozen_string_literal: true

require_relative "ir"
require_relative "../front/ast"

module Rubycc
  module IR
    # Lowers the AST into IR. A straightforward post-order walk that allocates a
    # fresh virtual register for every computed value. No optimization.
    class Generator
      # Returns an array of IR::Function, one per AST::FunctionDef.
      def generate(program)
        program.functions.map { |func| gen_function(func) }
      end

      private

      def gen_function(func)
        @insts = []
        @vreg_count = 0

        func.body.each { |stmt| gen_statement(stmt) }

        # C99: falling off the end of main returns 0. Emit an explicit return
        # unless the body already ended with one.
        unless @insts.last&.op == :ret
          zero = new_vreg
          emit(:const, dst: zero, a: 0)
          emit(:ret, a: zero)
        end

        Function.new(func.name, @insts, @vreg_count)
      end

      def gen_statement(stmt)
        case stmt
        when Front::AST::Return
          value = gen_expr(stmt.expr)
          emit(:ret, a: value)
        else
          raise "unsupported statement: #{stmt.class}"
        end
      end

      def gen_expr(node)
        case node
        when Front::AST::IntLit
          dst = new_vreg
          emit(:const, dst: dst, a: node.value)
          dst
        when Front::AST::Unary
          operand = gen_expr(node.operand)
          dst = new_vreg
          emit(node.op, dst: dst, a: operand)
          dst
        when Front::AST::Binary
          lhs = gen_expr(node.lhs)
          rhs = gen_expr(node.rhs)
          dst = new_vreg
          emit(node.op, dst: dst, a: lhs, b: rhs)
          dst
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      def new_vreg
        vreg = @vreg_count
        @vreg_count += 1
        vreg
      end

      def emit(op, dst: nil, a: nil, b: nil)
        @insts << Instruction.new(op, dst: dst, a: a, b: b)
      end
    end
  end
end
