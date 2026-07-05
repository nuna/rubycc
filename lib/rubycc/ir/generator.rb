# frozen_string_literal: true

require_relative "ir"
require_relative "../front/ast"
require_relative "../compile_error"

module Rubycc
  module IR
    # Lowers the AST into IR. A straightforward post-order walk that allocates a
    # fresh virtual register for every computed value. No optimization.
    class Generator
      # Returns an array of IR::Function, one per AST::FunctionDef. Prototypes
      # (AST::FunctionDecl) contribute only a signature-table entry and emit no
      # code. The table is filled in source order so a definition can reference
      # itself (recursion) or an earlier prototype (mutual recursion), while a
      # call to a still-unknown name is diagnosed as an implicit declaration.
      def generate(program)
        # name -> { arity:, defined: }. `defined` distinguishes a prototype
        # from a completed definition so redefinitions can be rejected.
        @signatures = {}
        ir_functions = []
        program.functions.each do |decl|
          case decl
          when Front::AST::FunctionDecl
            declare_function(decl.name, decl.params.size, defined: false, token: decl.token)
          when Front::AST::FunctionDef
            declare_function(decl.name, decl.params.size, defined: true, token: decl.token)
            ir_functions << gen_function(decl)
          end
        end
        ir_functions
      end

      private

      # Records or updates a function's signature, enforcing that repeated
      # declarations agree on arity and that a body is defined at most once.
      def declare_function(name, arity, defined:, token:)
        existing = @signatures[name]
        if existing
          if existing[:arity] != arity
            error_at(token, "conflicting types for '#{name}'")
          elsif defined && existing[:defined]
            error_at(token, "redefinition of '#{name}'")
          end
        end
        @signatures[name] = { arity: arity, defined: defined || existing&.fetch(:defined) || false }
      end

      def gen_function(func)
        @insts = []
        @vreg_count = 0
        @label_count = 0
        # Symbol tables form a scope stack (innermost last). Each entry maps a
        # variable name to its vreg number. The function body owns the
        # outermost scope; every compound-statement pushes a fresh one.
        @scopes = [{}]
        # Innermost-last stack of enclosing loops, so break/continue can jump
        # to the right labels without threading them through every call.
        @loop_stack = []

        # Parameters take the first vregs (0..n-1) in the outermost scope; the
        # backend spills the incoming argument registers into these slots.
        func.params.each { |param| @scopes.last[param.name] = new_vreg }

        func.body.each { |stmt| gen_statement(stmt) }

        # C99: falling off the end of main returns 0. Emit an explicit return
        # unless the body already ended with one.
        unless @insts.last&.op == :ret
          zero = new_vreg
          emit(:const, dst: zero, a: 0)
          emit(:ret, a: zero)
        end

        Function.new(func.name, @insts, @vreg_count, func.params.size)
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
        when Front::AST::While
          gen_while(stmt)
        when Front::AST::DoWhile
          gen_do_while(stmt)
        when Front::AST::For
          gen_for(stmt)
        when Front::AST::Break
          gen_break(stmt)
        when Front::AST::Continue
          gen_continue(stmt)
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

      def gen_while(node)
        cond_label = new_label
        end_label = new_label
        emit(:label, a: cond_label)
        cond = gen_expr(node.condition)
        emit(:jump_if_zero, a: cond, b: end_label)
        gen_loop_body(node.body, continue_label: cond_label, break_label: end_label)
        emit(:jump, a: cond_label)
        emit(:label, a: end_label)
      end

      def gen_do_while(node)
        body_label = new_label
        cond_label = new_label
        end_label = new_label
        emit(:label, a: body_label)
        gen_loop_body(node.body, continue_label: cond_label, break_label: end_label)
        emit(:label, a: cond_label)
        cond = gen_expr(node.condition)
        emit(:jump_if_zero, a: cond, b: end_label)
        emit(:jump, a: body_label)
        emit(:label, a: end_label)
      end

      # C99: the for-loop's own parentheses introduce a scope, so a
      # declaration in clause-1 is only visible to the condition, step and
      # body (not to code after the loop).
      def gen_for(node)
        @scopes.push({})
        gen_for_init(node.init)

        cond_label = new_label
        step_label = new_label
        end_label = new_label

        emit(:label, a: cond_label)
        if node.condition
          cond = gen_expr(node.condition)
          emit(:jump_if_zero, a: cond, b: end_label)
        end
        gen_loop_body(node.body, continue_label: step_label, break_label: end_label)
        emit(:label, a: step_label)
        gen_expr(node.step) if node.step
        emit(:jump, a: cond_label)
        emit(:label, a: end_label)

        @scopes.pop
      end

      def gen_for_init(init)
        case init
        when Array
          init.each { |decl| gen_variable_decl(decl) }
        when nil
          # no-op: clause-1 was omitted
        else
          gen_expr(init)
        end
      end

      # Runs a loop's body with break/continue targets visible to any nested
      # Break/Continue node, restoring the enclosing loop's targets (if any)
      # once the body has been generated.
      def gen_loop_body(body, continue_label:, break_label:)
        @loop_stack.push(continue_label: continue_label, break_label: break_label)
        gen_statement(body)
      ensure
        @loop_stack.pop
      end

      def gen_break(node)
        error_at(node.token, "break statement not within a loop") if @loop_stack.empty?
        emit(:jump, a: @loop_stack.last[:break_label])
      end

      def gen_continue(node)
        error_at(node.token, "continue statement not within a loop") if @loop_stack.empty?
        emit(:jump, a: @loop_stack.last[:continue_label])
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
        when Front::AST::Call
          gen_call(node)
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      # Lowers a call: the callee must have a known signature and a matching
      # argument count. Arguments are evaluated left to right, each landing in
      # its own vreg, and the whole call yields a fresh vreg for the result.
      def gen_call(node)
        sig = @signatures[node.name]
        error_at(node.token, "implicit declaration of function '#{node.name}'") unless sig

        if node.args.size < sig[:arity]
          error_at(node.token, "too few arguments to function '#{node.name}'")
        elsif node.args.size > sig[:arity]
          error_at(node.token, "too many arguments to function '#{node.name}'")
        end

        arg_vregs = node.args.map { |arg| gen_expr(arg) }
        dst = new_vreg
        emit(:call, dst: dst, a: node.name, b: arg_vregs)
        dst
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
