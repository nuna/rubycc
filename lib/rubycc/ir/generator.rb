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
      # A declared variable's binding and its declared Rubycc::Type. `storage`
      # is a virtual-register number for a scalar (int or pointer) and a stack
      # object id for an array; which one it is follows from `type.array?`.
      Local = Data.define(:type, :storage)
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
        # Aggregate stack objects (arrays), indexed by object id; each entry is
        # the object's byte size. The backend lays them out below the vreg
        # slots and resolves :object_addr against this table.
        @stack_objects = []
        # Symbol tables form a scope stack (innermost last). Each entry maps a
        # variable name to its vreg number. The function body owns the
        # outermost scope; every compound-statement pushes a fresh one.
        @scopes = [{}]
        # Innermost-last stack of enclosing loops, so break/continue can jump
        # to the right labels without threading them through every call.
        @loop_stack = []

        # Parameters take the first vregs (0..n-1) in the outermost scope; the
        # backend spills the incoming argument registers into these slots.
        func.params.each do |param|
          @scopes.last[param.name] = Local.new(type: param.type, storage: new_vreg)
        end

        func.body.each { |stmt| gen_statement(stmt) }

        # C99: falling off the end of main returns 0. Emit an explicit return
        # unless the body already ended with one.
        unless @insts.last&.op == :ret
          zero = new_vreg
          emit(:const, dst: zero, a: 0)
          emit(:ret, a: zero)
        end

        Function.new(func.name, @insts, @vreg_count, func.params.size, @stack_objects)
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

        # An array reserves a stack object sized to hold all its elements; the
        # parser has already rejected any initializer for it. A scalar takes a
        # vreg slot and may be initialized in place.
        if decl.type.array?
          scope[decl.name] = Local.new(type: decl.type, storage: new_object(decl.type.size))
        else
          vreg = new_vreg
          scope[decl.name] = Local.new(type: decl.type, storage: vreg)
          if decl.initializer
            value, value_type = gen_expr(decl.initializer)
            unless compatible_types?(decl.type, value_type)
              error_at(decl.token, "incompatible types in assignment")
            end
            emit(:copy, dst: vreg, a: value)
          end
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
          gen_variable_ref(node)
        when Front::AST::Subscript
          gen_subscript(node)
        when Front::AST::SizeofExpr
          gen_sizeof(sizeof_operand_type(node.operand))
        when Front::AST::SizeofType
          gen_sizeof(node.type)
        when Front::AST::Assignment
          gen_assignment(node)
        when Front::AST::Call
          gen_call(node)
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      # A variable reference. A scalar yields its slot directly; an array
      # "decays" to a pointer to its first element (its base address), which is
      # the value every expression context except sizeof and unary "&" sees.
      def gen_variable_ref(node)
        local = lookup_local(node.name, node.token)
        if local.type.array?
          dst = new_vreg
          emit(:object_addr, dst: dst, a: local.storage)
          [dst, Type::Pointer.new(local.type.element)]
        else
          [local.storage, local.type]
        end
      end

      # "e[i]" read: compute the element address (see #gen_element_address) and
      # load through it, the width following the element type.
      def gen_subscript(node)
        addr, element_type = gen_element_address(node)
        dst = new_vreg
        emit(:load, dst: dst, a: addr, size: element_type.size)
        [dst, element_type]
      end

      # sizeof folds to a compile-time int constant: the resolved type's byte
      # size. The operand (for the expression form) is never evaluated, so no
      # code other than the constant is emitted.
      def gen_sizeof(type)
        dst = new_vreg
        emit(:const, dst: dst, a: type.size)
        [dst, Type::Int]
      end

      # A binary operation. Its result type (and the legality of its operands)
      # is settled by #binary_result_type; the lowering then branches on the
      # operand kinds:
      #   * comparisons stay a single compare, widened to 64 bits when the
      #     operands are pointers;
      #   * pointer +/- int scales the int by the element size (64-bit);
      #   * pointer - pointer subtracts, then divides by the element size to
      #     yield an int element count;
      #   * everything else is ordinary 32-bit int arithmetic.
      def gen_binary(node)
        lhs, lhs_type = gen_expr(node.lhs)
        rhs, rhs_type = gen_expr(node.rhs)
        result_type = binary_result_type(node.op, lhs_type, rhs_type, node.token)

        if comparison_op?(node.op)
          dst = new_vreg
          emit(node.op, dst: dst, a: lhs, b: rhs, size: (8 if lhs_type.pointer?))
          [dst, result_type]
        elsif lhs_type.pointer? && rhs_type.pointer?
          gen_pointer_difference(lhs, rhs, lhs_type)
        elsif lhs_type.pointer?
          gen_pointer_int_arith(node.op, lhs, rhs, lhs_type)
        elsif rhs_type.pointer?
          # int + pointer (subtraction in this order was already rejected).
          gen_pointer_int_arith(node.op, rhs, lhs, rhs_type)
        else
          dst = new_vreg
          emit(node.op, dst: dst, a: lhs, b: rhs)
          [dst, Type::Int]
        end
      end

      # pointer +/- int: scale the int index by the element size (as a 64-bit
      # byte offset) and add or subtract it from the pointer. The result has the
      # pointer's type.
      def gen_pointer_int_arith(op, ptr_vreg, int_vreg, ptr_type)
        offset = scale_index(int_vreg, ptr_type.target.size)
        dst = new_vreg
        emit(op, dst: dst, a: ptr_vreg, b: offset, size: 8)
        [dst, ptr_type]
      end

      # pointer - pointer (same type): the byte distance divided by the element
      # size, giving the number of elements between them as an int.
      def gen_pointer_difference(lhs_vreg, rhs_vreg, ptr_type)
        diff = new_vreg
        emit(:sub, dst: diff, a: lhs_vreg, b: rhs_vreg, size: 8)
        size_reg = new_vreg
        emit(:const, dst: size_reg, a: ptr_type.target.size)
        dst = new_vreg
        emit(:div, dst: dst, a: diff, b: size_reg, size: 8)
        [dst, Type::Int]
      end

      # Sign-extends a 32-bit index to 64 bits and multiplies it by the element
      # size, yielding the byte offset used to index a pointer or array. Shared
      # by pointer arithmetic and subscripting; the sign extension makes
      # negative indices (p[-1]) address the element below the pointer.
      def scale_index(index_vreg, element_size)
        wide = new_vreg
        emit(:sext, dst: wide, a: index_vreg)
        size_reg = new_vreg
        emit(:const, dst: size_reg, a: element_size)
        scaled = new_vreg
        emit(:mul, dst: scaled, a: wide, b: size_reg, size: 8)
        scaled
      end

      # Computes the address of "e[i]" — the lvalue shared by subscript reads
      # and writes and by "&e[i]". The target decays to a pointer (an array
      # becomes a pointer to its first element); the int index is scaled by the
      # element size and added, exactly like "*(e + i)". Returns
      # [address_vreg, element_type].
      def gen_element_address(node)
        base, base_type = gen_expr(node.target)
        element_type = subscript_element_type(base_type, node.token)
        index, index_type = gen_expr(node.index)
        unless index_type.int?
          error_at(node.token, "array subscript is not an integer")
        end
        offset = scale_index(index, element_type.size)
        addr = new_vreg
        emit(:add, dst: addr, a: base, b: offset, size: 8)
        [addr, element_type]
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

      # "&x" yields the address of an lvalue. A variable reference, a subscript
      # "e[i]" or a dereference "*p" is an lvalue here: "&x" is a pointer to x's
      # type, "&e[i]" is a pointer to the element (its already-computed
      # address) and "&*p" collapses to p itself. Taking the address of a whole
      # array is not modelled (use "&a[0]").
      def gen_address_of(node)
        operand = node.operand
        if operand.is_a?(Front::AST::VariableRef)
          local = lookup_local(operand.name, operand.token)
          if local.type.array?
            error_at(node.token, "address of array is not supported yet")
          end
          dst = new_vreg
          emit(:addr_of, dst: dst, a: local.storage)
          [dst, Type::Pointer.new(local.type)]
        elsif operand.is_a?(Front::AST::Subscript)
          addr, element_type = gen_element_address(operand)
          [addr, Type::Pointer.new(element_type)]
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
        emit(:load, dst: dst, a: addr, size: result_type.size)
        [dst, result_type]
      end

      # Two forms of assignment share the same "=": a plain variable copy and a
      # store through a dereferenced pointer ("*p = v"). Both yield the assigned
      # value; the parser has already guaranteed the target is assignable.
      def gen_assignment(node)
        target = node.target
        if target.is_a?(Front::AST::Unary) && target.op == :deref
          gen_store_through_pointer(node, target)
        elsif target.is_a?(Front::AST::Subscript)
          gen_store_through_subscript(node, target)
        else
          gen_variable_assignment(node, target)
        end
      end

      def gen_variable_assignment(node, target)
        local = lookup_local(target.name, target.token)
        if local.type.array?
          error_at(node.token, "array type is not assignable")
        end
        value, value_type = gen_expr(node.value)
        unless compatible_types?(local.type, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:copy, dst: local.storage, a: value)
        [local.storage, local.type]
      end

      # "e[i] = v": compute the element address (see #gen_element_address) and
      # write v through it, the store width following the element type. The
      # expression's value is v.
      def gen_store_through_subscript(node, target)
        addr, element_type = gen_element_address(target)
        value, value_type = gen_expr(node.value)
        unless compatible_types?(element_type, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: value, size: element_type.size)
        [value, element_type]
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
        emit(:store, a: addr, b: value, size: target_type.size)
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

      COMPARISON_OPS = %i[eq ne lt le gt ge].freeze

      def comparison_op?(op)
        COMPARISON_OPS.include?(op)
      end

      # Settles a binary operation's result type and rejects any illegal
      # operand combination with "invalid operands to binary expression".
      # Shared by the lowering path (#gen_binary) and the code-free type
      # inference used by sizeof (#static_type):
      #   * comparisons: int/int or same-type pointer/pointer -> int;
      #   * "+": int/int -> int, and pointer/int or int/pointer -> that pointer;
      #   * "-": int/int -> int, pointer/int -> that pointer, and same-type
      #     pointer/pointer -> int;
      #   * "*" "/" "%": int/int -> int only.
      def binary_result_type(op, lhs_type, rhs_type, token)
        result =
          if comparison_op?(op)
            Type::Int if lhs_type == rhs_type && (lhs_type.int? || lhs_type.pointer?)
          else
            case op
            when :add
              if lhs_type.int? && rhs_type.int? then Type::Int
              elsif lhs_type.pointer? && rhs_type.int? then lhs_type
              elsif lhs_type.int? && rhs_type.pointer? then rhs_type
              end
            when :sub
              if lhs_type.int? && rhs_type.int? then Type::Int
              elsif lhs_type.pointer? && rhs_type.int? then lhs_type
              elsif lhs_type.pointer? && rhs_type.pointer? && lhs_type == rhs_type then Type::Int
              end
            else # :mul, :div, :mod
              Type::Int if lhs_type.int? && rhs_type.int?
            end
          end
        result || error_at(token, "invalid operands to binary expression")
      end

      # A subscripted value must be a pointer (an array has already decayed to
      # one); the result is the pointed-to element type.
      def subscript_element_type(base_type, token)
        unless base_type.pointer?
          error_at(token, "subscripted value is neither array nor pointer")
        end
        base_type.target
      end

      # sizeof measures the operand's type without evaluating it. A bare array
      # variable keeps its array type (no decay), so "sizeof a" is the whole
      # array; every other operand takes its ordinary (decayed) expression type.
      def sizeof_operand_type(node)
        if node.is_a?(Front::AST::VariableRef)
          lookup_local(node.name, node.token).type
        else
          static_type(node)
        end
      end

      # Infers an expression's rvalue type without emitting any code, applying
      # the same rules (and array-to-pointer decay) as #gen_expr. Used only to
      # resolve a sizeof operand's type.
      def static_type(node)
        case node
        when Front::AST::IntLit, Front::AST::Call,
             Front::AST::SizeofExpr, Front::AST::SizeofType
          Type::Int
        when Front::AST::VariableRef
          type = lookup_local(node.name, node.token).type
          type.array? ? Type::Pointer.new(type.element) : type
        when Front::AST::Subscript
          subscript_element_type(static_type(node.target), node.token)
        when Front::AST::Binary
          binary_result_type(node.op, static_type(node.lhs), static_type(node.rhs), node.token)
        when Front::AST::Unary
          static_unary_type(node)
        when Front::AST::Assignment
          static_type(node.target)
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      def static_unary_type(node)
        case node.op
        when :neg, :not
          Type::Int
        when :deref
          type = static_type(node.operand)
          require_pointer(type, node.token)
          type.target
        when :addr
          static_address_of_type(node)
        end
      end

      # The type of "&operand" without emitting code, mirroring #gen_address_of.
      def static_address_of_type(node)
        operand = node.operand
        if operand.is_a?(Front::AST::VariableRef)
          local = lookup_local(operand.name, operand.token)
          error_at(node.token, "address of array is not supported yet") if local.type.array?
          Type::Pointer.new(local.type)
        elsif operand.is_a?(Front::AST::Subscript)
          Type::Pointer.new(subscript_element_type(static_type(operand.target), operand.token))
        elsif operand.is_a?(Front::AST::Unary) && operand.op == :deref
          type = static_type(operand.operand)
          require_pointer(type, operand.token)
          type
        else
          error_at(node.token, "lvalue required as unary '&' operand")
        end
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

      # Reserves a stack object of `byte_size` bytes, returning its id (an index
      # into @stack_objects the backend lays out below the vreg slots).
      def new_object(byte_size)
        id = @stack_objects.size
        @stack_objects << byte_size
        id
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
