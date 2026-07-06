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
      # A declared variable's binding and its declared Rubycc::Type. When
      # `global` is false it is a local: `storage` is a virtual-register number
      # for a scalar (int or pointer) and a stack object id for an array, which
      # one following from `type.array?`. When `global` is true it is a
      # file-scope variable and `storage` is its symbol name (a String), whose
      # address :global_addr materializes.
      Local = Data.define(:type, :storage, :global)
      # Returns an IR::Program: an IR::Function per AST::FunctionDef plus the
      # translation unit's read-only string pool. Prototypes
      # (AST::FunctionDecl) contribute only a signature-table entry and emit no
      # code. The table is filled in source order so a definition can reference
      # itself (recursion) or an earlier prototype (mutual recursion), while a
      # call to a still-unknown name is diagnosed as an implicit declaration.
      def generate(program)
        # name -> { param_types:, return_type:, defined: }. `param_types` is
        # the array of parameter Rubycc::Types (its length being the arity);
        # `return_type` is the declared Rubycc::Type of a call to this
        # function; `defined` distinguishes a prototype from a completed
        # definition so redefinitions can be rejected.
        @signatures = {}
        # The translation-unit-wide string pool: `@strings` holds each interned
        # byte string in id order, `@string_ids` maps content back to its id so
        # identical literals collapse to one entry (and one .rodata address).
        @strings = []
        @string_ids = {}
        # File-scope variables: `@global_bindings` maps each name to its Local
        # binding (the outermost scope every function shares), while `@globals`
        # holds the IR::Global descriptors in source order for the compiler to
        # lay out into .data/.bss.
        @global_bindings = {}
        @globals = []
        ir_functions = []
        # Declarations are processed in source order, so a function may only
        # reference a global or callee already declared above it (C's
        # declaration-before-use rule), and a name reused across the global and
        # function namespaces is rejected as a redefinition.
        program.functions.each do |decl|
          case decl
          when Front::AST::GlobalDecl
            declare_global(decl)
          when Front::AST::FunctionDecl
            declare_function(decl.name, decl.return_type, decl.params.map(&:type), defined: false, token: decl.token)
          when Front::AST::FunctionDef
            declare_function(decl.name, decl.return_type, decl.params.map(&:type), defined: true, token: decl.token)
            ir_functions << gen_function(decl)
          end
        end
        Program.new(ir_functions, @strings, @globals)
      end

      private

      # Records a file-scope variable: its binding (visible to every function
      # as the outermost scope) and its IR::Global layout descriptor. A name
      # already taken by another global or by a function is a redefinition.
      def declare_global(decl)
        if @global_bindings.key?(decl.name) || @signatures.key?(decl.name)
          error_at(decl.token, "redefinition of '#{decl.name}'")
        end
        @global_bindings[decl.name] = Local.new(type: decl.type, storage: decl.name, global: true)
        align = decl.type.array? ? decl.type.element.size : decl.type.size
        @globals << Global.new(name: decl.name, size: decl.type.size, align: align,
                               init: decl.initializer_value)
      end

      # Interns `bytes` (an ASCII-8BIT String) into the string pool, returning
      # its id. Identical contents share one id, deduplicating string literals
      # across the whole translation unit.
      def intern_string(bytes)
        @string_ids.fetch(bytes) do
          id = @strings.size
          @strings << bytes
          @string_ids[bytes] = id
          id
        end
      end

      # Records or updates a function's signature, enforcing that repeated
      # declarations agree on their return type and parameter types (which
      # also covers arity) and that a body is defined at most once.
      def declare_function(name, return_type, param_types, defined:, token:)
        error_at(token, "redefinition of '#{name}'") if @global_bindings.key?(name)
        existing = @signatures[name]
        if existing
          if existing[:param_types] != param_types || existing[:return_type] != return_type
            error_at(token, "conflicting types for '#{name}'")
          elsif defined && existing[:defined]
            error_at(token, "redefinition of '#{name}'")
          end
        end
        @signatures[name] = {
          param_types: param_types,
          return_type: return_type,
          defined: defined || existing&.fetch(:defined) || false
        }
      end

      def gen_function(func)
        @insts = []
        @vreg_count = 0
        @label_count = 0
        # The enclosing function's declared return type, consulted by
        # #gen_return to type-check "return ...;" and by the implicit-return
        # fallback below.
        @current_return_type = func.return_type
        # Aggregate stack objects (arrays), indexed by object id; each entry is
        # the object's byte size. The backend lays them out below the vreg
        # slots and resolves :object_addr against this table.
        @stack_objects = []
        # Symbol tables form a scope stack (innermost last), each mapping a
        # variable name to its Local binding. The shared file-scope globals sit
        # at the bottom so a local of the same name shadows a global; the
        # function body owns the next scope, and every compound-statement pushes
        # a fresh one on top.
        @scopes = [@global_bindings, {}]
        # Innermost-last stack of enclosing loops, so break/continue can jump
        # to the right labels without threading them through every call.
        @loop_stack = []

        # Parameters take the first vregs (0..n-1) in the outermost scope; the
        # backend spills the incoming argument registers into these slots.
        func.params.each do |param|
          @scopes.last[param.name] = Local.new(type: param.type, storage: new_vreg, global: false)
        end

        # A char parameter arrives as a full int in its register; narrow it to
        # 8 bits in place so its slot holds the truncated char value like any
        # other char lvalue.
        func.params.each do |param|
          next unless param.type.char?

          slot = @scopes.last[param.name].storage
          emit(:sext8, dst: slot, a: slot)
        end

        func.body.each { |stmt| gen_statement(stmt) }

        # Falling off the end of the body needs an explicit return, unless one
        # was already emitted. A void function returns no value; every other
        # return type (including char and pointer, where falling off the end
        # is technically undefined behavior, just like a non-void, non-main
        # function in C99) returns 0, matching main's C99 fallback and keeping
        # this single case simple.
        unless @insts.last&.op == :ret
          if @current_return_type.void?
            emit(:ret, a: nil)
          else
            zero = new_vreg
            emit(:const, dst: zero, a: 0)
            emit(:ret, a: zero)
          end
        end

        Function.new(func.name, @insts, @vreg_count, func.params.size, @stack_objects)
      end

      def gen_statement(stmt)
        case stmt
        when Front::AST::Return
          gen_return(stmt)
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
        cond, cond_type = gen_value(node.condition)
        require_scalar_condition(cond_type, node.condition.token)
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
        cond, cond_type = gen_value(node.condition)
        require_scalar_condition(cond_type, node.condition.token)
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
        cond, cond_type = gen_value(node.condition)
        require_scalar_condition(cond_type, node.condition.token)
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
          cond, cond_type = gen_value(node.condition)
          require_scalar_condition(cond_type, node.condition.token)
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

      # "return;" or "return expr;", checked against the enclosing function's
      # declared return type (@current_return_type): a void function accepts
      # only the valueless form ("return with a value in void function"
      # otherwise), every other return type requires a value ("return without
      # a value" otherwise) that is return-type-compatible (#compatible_types?,
      # the same rule assignment and arguments use) and is narrowed to that
      # type exactly like a variable's initializer.
      def gen_return(node)
        if @current_return_type.void?
          error_at(node.token, "return with a value in void function") if node.expr
          emit(:ret, a: nil)
          return
        end

        error_at(node.token, "return without a value") unless node.expr

        value, value_type = gen_value(node.expr)
        unless compatible_types?(@current_return_type, value_type)
          error_at(node.token, "incompatible return type")
        end
        emit(:ret, a: narrow_to_type(value, @current_return_type))
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
          scope[decl.name] = Local.new(type: decl.type, storage: new_object(decl.type.size), global: false)
        else
          vreg = new_vreg
          scope[decl.name] = Local.new(type: decl.type, storage: vreg, global: false)
          if decl.initializer
            value, value_type = gen_value(decl.initializer)
            unless compatible_types?(decl.type, value_type)
              error_at(decl.token, "incompatible types in assignment")
            end
            emit(:copy, dst: vreg, a: narrow_to_type(value, decl.type))
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
        when Front::AST::StringLit
          gen_string_literal(node)
        when Front::AST::Unary
          gen_unary(node)
        when Front::AST::Binary
          gen_binary(node)
        when Front::AST::VariableRef
          gen_variable_ref(node)
        when Front::AST::Subscript
          gen_subscript(node)
        when Front::AST::SizeofExpr
          gen_sizeof(sizeof_operand_type(node.operand), node.token)
        when Front::AST::SizeofType
          gen_sizeof(node.type, node.token)
        when Front::AST::Assignment
          gen_assignment(node)
        when Front::AST::Call
          gen_call(node)
        when Front::AST::LogicalAnd
          gen_logical_and(node)
        when Front::AST::LogicalOr
          gen_logical_or(node)
        when Front::AST::Conditional
          gen_conditional(node)
        when Front::AST::CompoundAssignment
          gen_compound_assignment(node)
        when Front::AST::IncDec
          gen_inc_dec(node)
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      # Lowers `node` for its value like #gen_expr, but rejects a void result:
      # the only expression a void type can have is a call to a void function,
      # and C only allows that call's (non-)value to be discarded as a whole
      # expression-statement, never consumed as an operand. Every context that
      # actually uses the value it gets back (an operand, an argument, an
      # initializer, a condition, ...) goes through this instead of #gen_expr.
      def gen_value(node)
        value, type = gen_expr(node)
        error_at(node.token, "void value not ignored as it ought to be") if type.void?
        [value, type]
      end

      # A variable reference. A local scalar yields its slot directly; an array
      # "decays" to a pointer to its first element (its base address), which is
      # the value every expression context except sizeof and unary "&" sees. A
      # global is read through its address (see #gen_global_ref).
      def gen_variable_ref(node)
        local = lookup_local(node.name, node.token)
        return gen_global_ref(local) if local.global

        if local.type.array?
          dst = new_vreg
          emit(:object_addr, dst: dst, a: local.storage)
          [dst, Type::Pointer.new(local.type.element)]
        elsif local.type.char?
          # A char local lives in its 8-byte slot as a sign-extended int, but a
          # store through a pointer to it ("char *p = &c; *p = v;") rewrites
          # only the slot's low byte, leaving the upper bytes stale. Re-extract
          # the char value from that low byte with :sext8 so a plain read of the
          # variable never depends on the (possibly aliased) upper bytes.
          dst = new_vreg
          emit(:sext8, dst: dst, a: local.storage)
          [dst, local.type]
        else
          [local.storage, local.type]
        end
      end

      # A file-scope variable reference. Its address is materialized with
      # :global_addr; an array decays to that base address (a pointer to its
      # first element), while a scalar is loaded through it, the width following
      # its type (a size-1 char load already re-extends the byte, so no aliasing
      # fix like a local's is needed).
      def gen_global_ref(local)
        addr = new_vreg
        emit(:global_addr, dst: addr, a: local.storage)
        if local.type.array?
          [addr, Type::Pointer.new(local.type.element)]
        else
          dst = new_vreg
          emit(:load, dst: dst, a: addr, size: local.type.size)
          [dst, local.type]
        end
      end

      # A string literal decays, in every expression context, to a char *
      # pointing at its bytes in the read-only pool. The bytes are interned
      # (deduplicated) and :string_addr loads the resulting address.
      def gen_string_literal(node)
        id = intern_string(node.value)
        dst = new_vreg
        emit(:string_addr, dst: dst, a: id)
        [dst, Type::Pointer.new(Type::Char)]
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
      # code other than the constant is emitted. void (an incomplete type with
      # no size) is rejected, whether written directly ("sizeof(void)") or
      # reached through a void-returning call's result type ("sizeof f()").
      def gen_sizeof(type, token)
        error_at(token, "invalid application of 'sizeof' to void type") if type.void?

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
        lhs, lhs_type = gen_value(node.lhs)
        rhs, rhs_type = gen_value(node.rhs)
        gen_binary_op(node.op, lhs, lhs_type, rhs, rhs_type, node.token)
      end

      # The value-level core of #gen_binary, factored out so compound
      # assignment and "++"/"--" (see #gen_compound_assignment, #gen_inc_dec)
      # can reuse the exact same lowering and type rules on operands they have
      # already evaluated into vregs, without re-walking an AST::Binary node.
      def gen_binary_op(op, lhs, lhs_type, rhs, rhs_type, token)
        result_type = binary_result_type(op, lhs_type, rhs_type, token)

        if comparison_op?(op)
          dst = new_vreg
          emit(op, dst: dst, a: lhs, b: rhs, size: (8 if lhs_type.pointer?))
          [dst, result_type]
        elsif lhs_type.pointer? && rhs_type.pointer?
          gen_pointer_difference(lhs, rhs, lhs_type)
        elsif lhs_type.pointer?
          gen_pointer_int_arith(op, lhs, rhs, lhs_type)
        elsif rhs_type.pointer?
          # int + pointer (subtraction in this order was already rejected).
          gen_pointer_int_arith(op, rhs, lhs, rhs_type)
        else
          dst = new_vreg
          emit(op, dst: dst, a: lhs, b: rhs)
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
      # element size and added, exactly like "*(e + i)" (rejected up front when
      # the element type is void, since there is no size to scale by). Returns
      # [address_vreg, element_type].
      def gen_element_address(node)
        base, base_type = gen_value(node.target)
        element_type = subscript_element_type(base_type, node.token)
        error_at(node.token, "invalid use of void pointer") if element_type.void?
        index, index_type = gen_value(node.index)
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
          operand, = gen_value(node.operand)
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
      # the :eq path rather than introducing a dedicated IR opcode. Its operand
      # is a condition, so it must be int-typed.
      def gen_logical_not(node)
        operand, operand_type = gen_value(node.operand)
        require_scalar_condition(operand_type, node.operand.token)
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
          # A global's address is its symbol (:global_addr); a local's is the
          # absolute address of its stack slot (:addr_of).
          dst = new_vreg
          emit(local.global ? :global_addr : :addr_of, dst: dst, a: local.storage)
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
        addr, ptr_type = gen_value(node.operand)
        require_dereferenceable_pointer(ptr_type, node.token)
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
        value, value_type = gen_value(node.value)
        unless compatible_types?(local.type, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        stored = store_scalar_variable(local, value)
        [stored, local.type]
      end

      # Reads a scalar variable's current value into a usable vreg. A local
      # scalar already lives in its slot vreg; a global is loaded through its
      # address (:global_addr then :load, the width following its type).
      def load_scalar_variable(local)
        return local.storage unless local.global

        addr = new_vreg
        emit(:global_addr, dst: addr, a: local.storage)
        dst = new_vreg
        emit(:load, dst: dst, a: addr, size: local.type.size)
        dst
      end

      # Writes `value_vreg` into a scalar variable, narrowing it to the
      # variable's type first (int -> char). A local is a plain :copy into its
      # slot; a global is a :store through its address. Returns the vreg holding
      # the stored (narrowed) value, which is the assignment expression's value.
      def store_scalar_variable(local, value_vreg)
        narrowed = narrow_to_type(value_vreg, local.type)
        if local.global
          addr = new_vreg
          emit(:global_addr, dst: addr, a: local.storage)
          emit(:store, a: addr, b: narrowed, size: local.type.size)
        else
          emit(:copy, dst: local.storage, a: narrowed)
        end
        narrowed
      end

      # "e[i] = v": compute the element address (see #gen_element_address) and
      # write v through it, the store width following the element type. The
      # expression's value is v.
      def gen_store_through_subscript(node, target)
        addr, element_type = gen_element_address(target)
        value, value_type = gen_value(node.value)
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
        addr, ptr_type = gen_value(target.operand)
        require_dereferenceable_pointer(ptr_type, target.token)
        target_type = ptr_type.target
        value, value_type = gen_value(node.value)
        unless compatible_types?(target_type, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: value, size: target_type.size)
        [value, target_type]
      end

      # Lowers a call: the callee must have a known signature and a matching
      # argument count, and each argument's type must match the corresponding
      # parameter. Arguments are evaluated left to right, each landing in its
      # own vreg; the result's type is the callee's declared return type (a
      # void one is only valid when the whole call is used as an
      # expression-statement, enforced by #gen_value at every other site).
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
          vreg, arg_type = gen_value(arg)
          unless compatible_types?(param_types[i], arg_type)
            error_at(node.token, "incompatible type for argument #{i + 1} of '#{node.name}'")
          end
          vreg
        end
        dst = new_vreg
        emit(:call, dst: dst, a: node.name, b: arg_vregs)
        [dst, sig[:return_type]]
      end

      # "lhs && rhs": short-circuit, so rhs is only evaluated when lhs is
      # non-zero. Both operands are conditions (int required). Lowered with a
      # single result vreg written from one of two "const 1"/"const 0" arms,
      # since the IR has no boolean value beyond an int 0/1:
      #   lhs -> jump_if_zero(false) -> rhs -> jump_if_zero(false)
      #     -> result = 1 -> jump(end)
      #   false: result = 0
      #   end:
      def gen_logical_and(node)
        lhs, lhs_type = gen_value(node.lhs)
        require_scalar_condition(lhs_type, node.lhs.token)
        false_label = new_label
        end_label = new_label
        result = new_vreg
        emit(:jump_if_zero, a: lhs, b: false_label)

        rhs, rhs_type = gen_value(node.rhs)
        require_scalar_condition(rhs_type, node.rhs.token)
        emit(:jump_if_zero, a: rhs, b: false_label)
        emit_const_copy(result, 1)
        emit(:jump, a: end_label)

        emit(:label, a: false_label)
        emit_const_copy(result, 0)
        emit(:label, a: end_label)
        [result, Type::Int]
      end

      # "lhs || rhs": short-circuit, so rhs is only evaluated when lhs is
      # zero. Symmetric to #gen_logical_and: a false (zero) lhs falls through
      # to evaluate rhs, while a true lhs settles the result at 1 immediately.
      #   lhs -> jump_if_zero(rhs) -> result = 1 -> jump(end)
      #   rhs: rhs -> jump_if_zero(false) -> result = 1 -> jump(end)
      #   false: result = 0
      #   end:
      def gen_logical_or(node)
        lhs, lhs_type = gen_value(node.lhs)
        require_scalar_condition(lhs_type, node.lhs.token)
        rhs_label = new_label
        false_label = new_label
        end_label = new_label
        result = new_vreg
        emit(:jump_if_zero, a: lhs, b: rhs_label)

        emit_const_copy(result, 1)
        emit(:jump, a: end_label)

        emit(:label, a: rhs_label)
        rhs, rhs_type = gen_value(node.rhs)
        require_scalar_condition(rhs_type, node.rhs.token)
        emit(:jump_if_zero, a: rhs, b: false_label)
        emit_const_copy(result, 1)
        emit(:jump, a: end_label)

        emit(:label, a: false_label)
        emit_const_copy(result, 0)
        emit(:label, a: end_label)
        [result, Type::Int]
      end

      # "condition ? then_expr : else_expr": the condition must be int-typed;
      # only one of the two arms is evaluated, and both must settle on the
      # same result type (which becomes the expression's type).
      def gen_conditional(node)
        cond, cond_type = gen_value(node.condition)
        require_scalar_condition(cond_type, node.condition.token)
        else_label = new_label
        end_label = new_label
        result = new_vreg
        emit(:jump_if_zero, a: cond, b: else_label)

        then_value, then_type = gen_value(node.then_expr)
        emit(:copy, dst: result, a: then_value)
        emit(:jump, a: end_label)

        emit(:label, a: else_label)
        else_value, else_type = gen_value(node.else_expr)
        emit(:copy, dst: result, a: else_value)
        emit(:label, a: end_label)

        [result, conditional_result_type(then_type, else_type, node.token)]
      end

      # The type of "condition ? then : else": identical types are kept as is,
      # a mixed arithmetic pair (int/char) promotes to int, and anything else
      # (e.g. pointer vs int, or two different pointer types) is rejected.
      def conditional_result_type(then_type, else_type, token)
        if then_type == else_type then then_type
        elsif then_type.arithmetic? && else_type.arithmetic? then Type::Int
        else error_at(token, "type mismatch in conditional expression")
        end
      end

      # A compound assignment "target op= value" reads through the target's
      # address (or its vreg, for a plain variable) exactly once, combines it
      # with value via the same operator/type rules as "target = target op
      # value" (#gen_binary_op), and writes the result back. The expression's
      # value is the result.
      def gen_compound_assignment(node)
        target = node.target
        if target.is_a?(Front::AST::Unary) && target.op == :deref
          gen_compound_assignment_through_pointer(node, target)
        elsif target.is_a?(Front::AST::Subscript)
          gen_compound_assignment_through_subscript(node, target)
        else
          gen_compound_assignment_to_variable(node, target)
        end
      end

      def gen_compound_assignment_to_variable(node, target)
        local = lookup_local(target.name, target.token)
        error_at(node.token, "array type is not assignable") if local.type.array?

        value, value_type = gen_value(node.value)
        current = load_scalar_variable(local)
        result, result_type = gen_binary_op(node.op, current, local.type, value, value_type, node.token)
        unless compatible_types?(local.type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        stored = store_scalar_variable(local, result)
        [stored, local.type]
      end

      def gen_compound_assignment_through_subscript(node, target)
        addr, element_type = gen_element_address(target)
        current = new_vreg
        emit(:load, dst: current, a: addr, size: element_type.size)

        value, value_type = gen_value(node.value)
        result, result_type = gen_binary_op(node.op, current, element_type, value, value_type, node.token)
        unless compatible_types?(element_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: result, size: element_type.size)
        [result, element_type]
      end

      def gen_compound_assignment_through_pointer(node, target)
        addr, ptr_type = gen_value(target.operand)
        require_dereferenceable_pointer(ptr_type, target.token)
        target_type = ptr_type.target
        current = new_vreg
        emit(:load, dst: current, a: addr, size: target_type.size)

        value, value_type = gen_value(node.value)
        result, result_type = gen_binary_op(node.op, current, target_type, value, value_type, node.token)
        unless compatible_types?(target_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: result, size: target_type.size)
        [result, target_type]
      end

      # Prefix/postfix "++"/"--" is a compound assignment by the constant 1,
      # sharing #gen_binary_op's type rules (an int step scaled for a pointer
      # target, same as "p += 1"). Only the reported value differs: a prefix
      # form yields the updated value, a postfix form yields the value read
      # before the update.
      def gen_inc_dec(node)
        target = node.target
        if target.is_a?(Front::AST::Unary) && target.op == :deref
          gen_inc_dec_through_pointer(node, target)
        elsif target.is_a?(Front::AST::Subscript)
          gen_inc_dec_through_subscript(node, target)
        else
          gen_inc_dec_variable(node, target)
        end
      end

      def gen_inc_dec_variable(node, target)
        local = lookup_local(target.name, target.token)
        error_at(node.token, "array type is not assignable") if local.type.array?

        current = load_scalar_variable(local)
        old_value = nil
        unless node.prefix
          old_value = new_vreg
          emit(:copy, dst: old_value, a: current)
        end

        one = new_vreg
        emit(:const, dst: one, a: 1)
        result, result_type = gen_binary_op(node.op, current, local.type, one, Type::Int, node.token)
        unless compatible_types?(local.type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        stored = store_scalar_variable(local, result)
        node.prefix ? [stored, local.type] : [old_value, local.type]
      end

      def gen_inc_dec_through_subscript(node, target)
        addr, element_type = gen_element_address(target)
        current = new_vreg
        emit(:load, dst: current, a: addr, size: element_type.size)

        one = new_vreg
        emit(:const, dst: one, a: 1)
        result, result_type = gen_binary_op(node.op, current, element_type, one, Type::Int, node.token)
        unless compatible_types?(element_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: result, size: element_type.size)
        node.prefix ? [result, element_type] : [current, element_type]
      end

      def gen_inc_dec_through_pointer(node, target)
        addr, ptr_type = gen_value(target.operand)
        require_dereferenceable_pointer(ptr_type, target.token)
        target_type = ptr_type.target
        current = new_vreg
        emit(:load, dst: current, a: addr, size: target_type.size)

        one = new_vreg
        emit(:const, dst: one, a: 1)
        result, result_type = gen_binary_op(node.op, current, target_type, one, Type::Int, node.token)
        unless compatible_types?(target_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: result, size: target_type.size)
        node.prefix ? [result, target_type] : [current, target_type]
      end

      # Materializes an immediate into `dst` via a fresh const vreg; shared by
      # the short-circuit lowerings (#gen_logical_and, #gen_logical_or) which
      # need to write a fixed 0/1 into the same result vreg from more than one
      # control-flow arm.
      def emit_const_copy(dst, value)
        src = new_vreg
        emit(:const, dst: src, a: value)
        emit(:copy, dst: dst, a: src)
      end

      # Assignment/initialization/argument/return compatibility. The arithmetic
      # types int and char convert to one another implicitly (int -> char
      # narrows; char -> int promotes), so any arithmetic pair is compatible.
      # Two pointers are compatible when they share the same target type or
      # either side is void * (void * converts to and from any pointer type,
      # both directions); mixing an arithmetic type with a pointer (either
      # direction) is rejected.
      def compatible_types?(expected, actual)
        return true if expected.arithmetic? && actual.arithmetic?
        return true if expected.pointer? && actual.pointer? &&
                        (expected == actual || expected.target.void? || actual.target.void?)

        expected == actual
      end

      # Narrows a value to its destination scalar type just before it is copied
      # into that lvalue's slot. A char destination keeps only the low 8 bits
      # (sign-extended back to the slot width), giving int -> char truncation;
      # every other destination type takes the value unchanged.
      def narrow_to_type(value_vreg, type)
        return value_vreg unless type.char?

        dst = new_vreg
        emit(:sext8, dst: dst, a: value_vreg)
        dst
      end

      # Guards a unary "*": its operand must be a pointer.
      def require_pointer(type, token)
        error_at(token, "invalid type argument of unary '*'") unless type.pointer?
      end

      # Guards an actual load/store through a pointer ("*p", "*p = v",
      # "p += 1", "e[i]", ...): beyond #require_pointer's plain pointer check,
      # a void pointer is rejected too, since its pointed-to type has no size
      # to load, store or scale by ("&*p", which never touches memory, is the
      # one place a void pointer's target may go unexamined).
      def require_dereferenceable_pointer(type, token)
        require_pointer(type, token)
        error_at(token, "invalid use of void pointer") if type.target.void?
      end

      # Guards every condition position (if/while/do-while/for, "&&"/"||"
      # operands, "!" operand, "?:" condition): an arithmetic value (int or a
      # char, which promotes to int) is a valid scalar condition, but a pointer
      # is not and this subset has no other truthiness rule, so a pointer is
      # rejected rather than silently treated as non-zero.
      def require_scalar_condition(type, token)
        error_at(token, "used pointer where scalar int is required") unless type.arithmetic?
      end

      COMPARISON_OPS = %i[eq ne lt le gt ge].freeze

      def comparison_op?(op)
        COMPARISON_OPS.include?(op)
      end

      # "==" and "!=" alone let a void * mix with any other pointer type (as
      # in an assignment); every other pointer comparison ("<", "<=", ">",
      # ">=") requires the exact same pointer type on both sides, void *
      # included.
      EQUALITY_OPS = %i[eq ne].freeze

      def pointer_comparable?(op, lhs_type, rhs_type)
        return lhs_type == rhs_type || lhs_type.target.void? || rhs_type.target.void? if EQUALITY_OPS.include?(op)

        lhs_type == rhs_type
      end

      # Pointer arithmetic (p + n, p - n, p - q) scales by the pointed-to
      # type's size, which void has none of; rejected up front with "invalid
      # use of void pointer" rather than let #size raise deep in the lowering.
      # Returns `type` so it can sit directly in #binary_result_type's
      # if/elsif chain.
      def require_non_void_pointer(type, token)
        error_at(token, "invalid use of void pointer") if type.target.void?
        type
      end

      # Settles a binary operation's result type and rejects any illegal
      # operand combination with "invalid operands to binary expression".
      # Arithmetic operands (int and char) mix freely and promote to int, so
      # the rules below read "arithmetic" wherever int would once have stood.
      # Shared by the lowering path (#gen_binary) and the code-free type
      # inference used by sizeof (#static_type):
      #   * comparisons: arithmetic/arithmetic, or pointer/pointer per
      #     #pointer_comparable? -> int;
      #   * "+": arithmetic/arithmetic -> int, and pointer/arithmetic or
      #     arithmetic/pointer -> that (non-void) pointer;
      #   * "-": arithmetic/arithmetic -> int, pointer/arithmetic -> that
      #     (non-void) pointer, and same-type (non-void) pointer/pointer -> int;
      #   * "*" "/" "%": arithmetic/arithmetic -> int only.
      def binary_result_type(op, lhs_type, rhs_type, token)
        result =
          if comparison_op?(op)
            if lhs_type.arithmetic? && rhs_type.arithmetic? then Type::Int
            elsif lhs_type.pointer? && rhs_type.pointer? && pointer_comparable?(op, lhs_type, rhs_type) then Type::Int
            end
          else
            case op
            when :add
              if lhs_type.arithmetic? && rhs_type.arithmetic? then Type::Int
              elsif lhs_type.pointer? && rhs_type.arithmetic? then require_non_void_pointer(lhs_type, token)
              elsif lhs_type.arithmetic? && rhs_type.pointer? then require_non_void_pointer(rhs_type, token)
              end
            when :sub
              if lhs_type.arithmetic? && rhs_type.arithmetic? then Type::Int
              elsif lhs_type.pointer? && rhs_type.arithmetic? then require_non_void_pointer(lhs_type, token)
              elsif lhs_type.pointer? && rhs_type.pointer? && lhs_type == rhs_type
                require_non_void_pointer(lhs_type, token)
                Type::Int
              end
            else # :mul, :div, :mod
              Type::Int if lhs_type.arithmetic? && rhs_type.arithmetic?
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
      # array; a string literal is likewise measured as its char[N+1] array
      # (NUL included) rather than the char * it would decay to; every other
      # operand takes its ordinary (decayed) expression type.
      def sizeof_operand_type(node)
        if node.is_a?(Front::AST::VariableRef)
          lookup_local(node.name, node.token).type
        elsif node.is_a?(Front::AST::StringLit)
          Type::Array.new(Type::Char, node.value.bytesize + 1)
        else
          static_type(node)
        end
      end

      # Infers an expression's rvalue type without emitting any code, applying
      # the same rules (and array-to-pointer decay) as #gen_expr. Used only to
      # resolve a sizeof operand's type.
      def static_type(node)
        case node
        when Front::AST::IntLit, Front::AST::SizeofExpr, Front::AST::SizeofType
          Type::Int
        when Front::AST::Call
          call_return_type(node)
        when Front::AST::StringLit
          Type::Pointer.new(Type::Char)
        when Front::AST::VariableRef
          type = lookup_local(node.name, node.token).type
          type.array? ? Type::Pointer.new(type.element) : type
        when Front::AST::Subscript
          subscript_element_type(static_type(node.target), node.token)
        when Front::AST::Binary
          binary_result_type(node.op, static_type(node.lhs), static_type(node.rhs), node.token)
        when Front::AST::Unary
          static_unary_type(node)
        when Front::AST::Assignment, Front::AST::CompoundAssignment, Front::AST::IncDec
          static_type(node.target)
        when Front::AST::LogicalAnd, Front::AST::LogicalOr
          Type::Int
        when Front::AST::Conditional
          static_conditional_type(node)
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      # A call's rvalue type without emitting code: the callee's declared
      # return type, looked up the same way #gen_call does.
      def call_return_type(node)
        sig = @signatures[node.name]
        error_at(node.token, "implicit declaration of function '#{node.name}'") unless sig

        sig[:return_type]
      end

      # The type of "condition ? then_expr : else_expr" without emitting code,
      # mirroring #gen_conditional: both arms must agree, and that shared type
      # is the result.
      def static_conditional_type(node)
        conditional_result_type(static_type(node.then_expr), static_type(node.else_expr), node.token)
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
