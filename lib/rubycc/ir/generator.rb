# frozen_string_literal: true

require_relative "ir"
require_relative "../front/ast"
require_relative "../type"
require_relative "../compile_error"

module Rubycc
  module IR
    # Lowers the AST into IR. A straightforward post-order walk that allocates a
    # fresh virtual register for every computed value, tracking each
    # expression's static type so pointer operations can be type-checked and
    # lowered. No optimization.
    class Generator
      # A declared variable's binding: the stack slot (vreg) that holds its
      # value and its declared Rubycc::Type.
      Local = Data.define(:vreg, :type)
      # Returns an array of IR::Function, one per AST::FunctionDef. Prototypes
      # (AST::FunctionDecl) contribute only a signature-table entry and emit no
      # code. The table is filled in source order so a definition can reference
      # itself (recursion) or an earlier prototype (mutual recursion), while a
      # call to a still-unknown name is diagnosed as an implicit declaration.
      def generate(program)
        # name -> { param_types:, defined: }. `param_types` is the array of
        # parameter Rubycc::Types (its length being the arity); `defined`
        # distinguishes a prototype from a completed definition so redefinitions
        # can be rejected.
        @signatures = {}
        ir_functions = []
        program.functions.each do |decl|
          case decl
          when Front::AST::FunctionDecl
            declare_function(decl.name, decl.params.map(&:type), defined: false, token: decl.token)
          when Front::AST::FunctionDef
            declare_function(decl.name, decl.params.map(&:type), defined: true, token: decl.token)
            ir_functions << gen_function(decl)
          end
        end
        ir_functions
      end

      private

      # Records or updates a function's signature, enforcing that repeated
      # declarations agree on their parameter types (which also covers arity)
      # and that a body is defined at most once.
      def declare_function(name, param_types, defined:, token:)
        existing = @signatures[name]
        if existing
          if existing[:param_types] != param_types
            error_at(token, "conflicting types for '#{name}'")
          elsif defined && existing[:defined]
            error_at(token, "redefinition of '#{name}'")
          end
        end
        @signatures[name] = {
          param_types: param_types,
          defined: defined || existing&.fetch(:defined) || false
        }
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
        func.params.each { |param| @scopes.last[param.name] = Local.new(new_vreg, param.type) }

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
          value, = gen_expr(stmt.expr)
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
        cond, = gen_expr(node.condition)
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
        cond, = gen_expr(node.condition)
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
        cond, = gen_expr(node.condition)
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
          cond, = gen_expr(node.condition)
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
        scope[decl.name] = Local.new(vreg, decl.type)
        if decl.initializer
          value, value_type = gen_expr(decl.initializer)
          unless compatible_types?(decl.type, value_type)
            error_at(decl.token, "incompatible types in assignment")
          end
          emit(:copy, dst: vreg, a: value)
        end
      end

      # Lowers an expression, returning [result_vreg, Rubycc::Type]. The type
      # travels alongside the value so every caller can type-check its operands
      # and pick the right access width for pointer loads and stores.
      def gen_expr(node)
        case node
        when Front::AST::IntLit
          dst = new_vreg
          emit(:const, dst: dst, a: node.value)
          [dst, Type::Int]
        when Front::AST::Unary
          gen_unary(node)
        when Front::AST::Binary
          gen_binary(node)
        when Front::AST::VariableRef
          local = lookup_local(node.name, node.token)
          [local.vreg, local.type]
        when Front::AST::Assignment
          gen_assignment(node)
        when Front::AST::Call
          gen_call(node)
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      # Arithmetic and comparison operators are int-only in this subset. A
      # pointer operand has no defined lowering yet (pointer arithmetic and
      # comparison arrive with arrays), so it is rejected here.
      def gen_binary(node)
        lhs, lhs_type = gen_expr(node.lhs)
        rhs, rhs_type = gen_expr(node.rhs)
        if lhs_type.pointer? || rhs_type.pointer?
          error_at(node.token, "invalid operands to binary expression")
        end
        dst = new_vreg
        emit(node.op, dst: dst, a: lhs, b: rhs)
        [dst, Type::Int]
      end

      def gen_unary(node)
        case node.op
        when :not
          gen_logical_not(node)
        when :neg
          operand, = gen_expr(node.operand)
          dst = new_vreg
          emit(:neg, dst: dst, a: operand)
          [dst, Type::Int]
        when :addr
          gen_address_of(node)
        when :deref
          gen_deref(node)
        end
      end

      # Logical negation "!x" is lowered to the comparison "x == 0", reusing
      # the :eq path rather than introducing a dedicated IR opcode.
      def gen_logical_not(node)
        operand, = gen_expr(node.operand)
        zero = new_vreg
        emit(:const, dst: zero, a: 0)
        dst = new_vreg
        emit(:eq, dst: dst, a: operand, b: zero)
        [dst, Type::Int]
      end

      # "&x" yields the address of an lvalue. Only a variable reference or a
      # dereference "*p" is an lvalue here; "&x" is a pointer to x's type, and
      # "&*p" collapses to p itself (its already-computed address).
      def gen_address_of(node)
        operand = node.operand
        if operand.is_a?(Front::AST::VariableRef)
          local = lookup_local(operand.name, operand.token)
          dst = new_vreg
          emit(:addr_of, dst: dst, a: local.vreg)
          [dst, Type::Pointer.new(local.type)]
        elsif operand.is_a?(Front::AST::Unary) && operand.op == :deref
          addr, ptr_type = gen_expr(operand.operand)
          require_pointer(ptr_type, operand.token)
          [addr, ptr_type]
        else
          error_at(node.token, "lvalue required as unary '&' operand")
        end
      end

      # "*p" read: evaluate p to an address, then load through it. The result
      # type is p's pointed-to type, which also fixes the load width (a pointer
      # target is 8 bytes wide, an int 4).
      def gen_deref(node)
        addr, ptr_type = gen_expr(node.operand)
        require_pointer(ptr_type, node.token)
        result_type = ptr_type.target
        dst = new_vreg
        emit(:load, dst: dst, a: addr, size: type_size(result_type))
        [dst, result_type]
      end

      # Two forms of assignment share the same "=": a plain variable copy and a
      # store through a dereferenced pointer ("*p = v"). Both yield the assigned
      # value; the parser has already guaranteed the target is assignable.
      def gen_assignment(node)
        target = node.target
        if target.is_a?(Front::AST::Unary) && target.op == :deref
          gen_store_through_pointer(node, target)
        else
          gen_variable_assignment(node, target)
        end
      end

      def gen_variable_assignment(node, target)
        local = lookup_local(target.name, target.token)
        value, value_type = gen_expr(node.value)
        unless compatible_types?(local.type, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:copy, dst: local.vreg, a: value)
        [local.vreg, local.type]
      end

      # "*p = v": evaluate p (an address) and v, then write v through the
      # address. The store width follows p's target type. The expression's
      # value is v.
      def gen_store_through_pointer(node, target)
        addr, ptr_type = gen_expr(target.operand)
        require_pointer(ptr_type, target.token)
        target_type = ptr_type.target
        value, value_type = gen_expr(node.value)
        unless compatible_types?(target_type, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: value, size: type_size(target_type))
        [value, target_type]
      end

      # Lowers a call: the callee must have a known signature and a matching
      # argument count, and each argument's type must match the corresponding
      # parameter. Arguments are evaluated left to right, each landing in its
      # own vreg; the result is always int (the only return type in this subset).
      def gen_call(node)
        sig = @signatures[node.name]
        error_at(node.token, "implicit declaration of function '#{node.name}'") unless sig

        param_types = sig[:param_types]
        if node.args.size < param_types.size
          error_at(node.token, "too few arguments to function '#{node.name}'")
        elsif node.args.size > param_types.size
          error_at(node.token, "too many arguments to function '#{node.name}'")
        end

        arg_vregs = node.args.each_with_index.map do |arg, i|
          vreg, arg_type = gen_expr(arg)
          unless compatible_types?(param_types[i], arg_type)
            error_at(node.token, "incompatible type for argument #{i + 1} of '#{node.name}'")
          end
          vreg
        end
        dst = new_vreg
        emit(:call, dst: dst, a: node.name, b: arg_vregs)
        [dst, Type::Int]
      end

      # Assignment/initialization/argument compatibility: types must match
      # exactly. Mixing int and pointer (either direction) is rejected.
      def compatible_types?(expected, actual)
        expected == actual
      end

      # Guards a unary "*": its operand must be a pointer.
      def require_pointer(type, token)
        error_at(token, "invalid type argument of unary '*'") unless type.pointer?
      end

      # Storage width in bytes driving load/store access sizes: pointers are 8,
      # int is 4.
      def type_size(type)
        type.pointer? ? 8 : 4
      end

      # Resolves a variable by walking scopes from innermost to outermost, so
      # an inner declaration shadows an outer one with the same name.
      def lookup_local(name, token)
        @scopes.reverse_each do |scope|
          local = scope[name]
          return local if local
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

      def emit(op, dst: nil, a: nil, b: nil, size: nil)
        @insts << Instruction.new(op, dst: dst, a: a, b: b, size: size)
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
