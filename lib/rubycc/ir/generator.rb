# frozen_string_literal: true

require_relative "ir"
require_relative "../front/ast"
require_relative "../compile_error"

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
        @label_count = 0
        # Symbol tables form a scope stack (innermost last). Each entry maps a
        # variable name to its vreg number. The function body owns the
        # outermost scope; every compound-statement pushes a fresh one.
        @scopes = [{}]

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
        when Front::AST::VariableDecl
          gen_variable_decl(stmt)
        when Front::AST::ExpressionStmt
          gen_expr(stmt.expr)
        when Front::AST::EmptyStmt
          # no-op
        when Front::AST::If
          gen_if(stmt)
        when Front::AST::Block
          gen_block(stmt)
        else
          raise "unsupported statement: #{stmt.class}"
        end
      end

      def gen_block(block)
        @scopes.push({})
        block.items.each { |item| gen_statement(item) }
        @scopes.pop
      end

      def gen_if(node)
        cond = gen_expr(node.condition)
        if node.else_stmt
          else_label = new_label
          end_label = new_label
          emit(:jump_if_zero, a: cond, b: else_label)
          gen_statement(node.then_stmt)
          emit(:jump, a: end_label)
          emit(:label, a: else_label)
          gen_statement(node.else_stmt)
          emit(:label, a: end_label)
        else
          end_label = new_label
          emit(:jump_if_zero, a: cond, b: end_label)
          gen_statement(node.then_stmt)
          emit(:label, a: end_label)
        end
      end

      def gen_variable_decl(decl)
        scope = @scopes.last
        if scope.key?(decl.name)
          error_at(decl.token, "redeclaration of '#{decl.name}'")
        end

        vreg = new_vreg
        scope[decl.name] = vreg
        if decl.initializer
          value = gen_expr(decl.initializer)
          emit(:copy, dst: vreg, a: value)
        end
      end

      def gen_expr(node)
        case node
        when Front::AST::IntLit
          dst = new_vreg
          emit(:const, dst: dst, a: node.value)
          dst
        when Front::AST::Unary
          gen_unary(node)
        when Front::AST::Binary
          lhs = gen_expr(node.lhs)
          rhs = gen_expr(node.rhs)
          dst = new_vreg
          emit(node.op, dst: dst, a: lhs, b: rhs)
          dst
        when Front::AST::VariableRef
          lookup_vreg(node.name, node.token)
        when Front::AST::Assignment
          value = gen_expr(node.value)
          target_vreg = lookup_vreg(node.target.name, node.target.token)
          emit(:copy, dst: target_vreg, a: value)
          target_vreg
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      # Logical negation "!x" is lowered to the comparison "x == 0", reusing
      # the :eq path rather than introducing a dedicated IR opcode.
      def gen_unary(node)
        if node.op == :not
          operand = gen_expr(node.operand)
          zero = new_vreg
          emit(:const, dst: zero, a: 0)
          dst = new_vreg
          emit(:eq, dst: dst, a: operand, b: zero)
          dst
        else
          operand = gen_expr(node.operand)
          dst = new_vreg
          emit(node.op, dst: dst, a: operand)
          dst
        end
      end

      # Resolves a variable by walking scopes from innermost to outermost, so
      # an inner declaration shadows an outer one with the same name.
      def lookup_vreg(name, token)
        @scopes.reverse_each do |scope|
          vreg = scope[name]
          return vreg if vreg
        end
        error_at(token, "undeclared variable '#{name}'")
      end

      def new_vreg
        vreg = @vreg_count
        @vreg_count += 1
        vreg
      end

      def new_label
        label = @label_count
        @label_count += 1
        label
      end

      def emit(op, dst: nil, a: nil, b: nil)
        @insts << Instruction.new(op, dst: dst, a: a, b: b)
      end

      def error_at(token, description)
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
