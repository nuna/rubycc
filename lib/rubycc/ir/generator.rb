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
        # A global needs a known storage width and boundary, so an incomplete
        # struct (a tag never defined) cannot be laid out in .bss/.data.
        require_complete(decl.type, decl.token)
        @global_bindings[decl.name] = Local.new(type: decl.type, storage: decl.name, global: true)
        @globals << Global.new(name: decl.name, size: decl.type.size, align: decl.type.alignment,
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
        # Passing or returning a struct by value is out of scope for this step
        # (a struct pointer is the way to hand a struct across a call), so a
        # struct-typed parameter or return type is rejected up front, before any
        # call site can rely on it.
        if return_type.struct?
          error_at(token, "struct return values are not supported yet")
        end
        if param_types.any?(&:struct?)
          error_at(token, "struct parameters are not supported yet")
        end
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
        # Innermost-last stack of enclosing loops and switches, each frame a
        # { break_label:, continue_label: }. `break` jumps to the top frame's
        # break_label (a loop's end or a switch's end); `continue` jumps to the
        # top frame's continue_label. A switch frame carries the enclosing
        # loop's continue_label unchanged, so `continue` inside a switch passes
        # through to the loop, and a nil continue_label (a switch with no
        # enclosing loop) makes `continue` a diagnostic.
        @control_stack = []
        # Function-scoped goto label table: name -> { id:, defined:, token: }.
        # A label id is allocated the first time a name is seen (by a goto or by
        # its definition), so a forward goto needs no backpatching — it emits a
        # jump to the id the label will later mark. `defined` catches a duplicate
        # definition and, at the function's end, a goto to a never-defined label.
        @goto_labels = {}
        # Innermost-last stack of the current switches' case/default label maps
        # (each a node -> label id, keyed by object identity), so a Case/Default
        # statement encountered while walking a switch body can find the label
        # the comparison chain already assigned to it.
        @case_label_stack = []

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

        # Every label a goto referenced must have been defined somewhere in the
        # function; a goto to a label that never appears is diagnosed here, once
        # the whole body has been seen (so a forward reference is not mistaken
        # for an undefined one). The stored token locates the offending goto.
        @goto_labels.each do |name, entry|
          next if entry[:defined]

          error_at(entry[:token], "label '#{name}' used but not defined")
        end

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
        when Front::AST::Switch
          gen_switch(stmt)
        when Front::AST::Case
          gen_case(stmt)
        when Front::AST::Default
          gen_default(stmt)
        when Front::AST::Goto
          gen_goto(stmt)
        when Front::AST::Label
          gen_label(stmt)
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
        cond = gen_condition(node.condition)
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
        cond = gen_condition(node.condition)
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
        cond = gen_condition(node.condition)
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
          cond = gen_condition(node.condition)
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
      # once the body has been generated. Both targets are the loop's own, so
      # break leaves the loop and continue restarts it.
      def gen_loop_body(body, continue_label:, break_label:)
        @control_stack.push(break_label: break_label, continue_label: continue_label)
        gen_statement(body)
      ensure
        @control_stack.pop
      end

      # break jumps to the innermost enclosing loop's or switch's end. It is a
      # diagnostic only when no such construct is open at all.
      def gen_break(node)
        if @control_stack.empty?
          error_at(node.token, "break statement not within a loop or switch")
        end
        emit(:jump, a: @control_stack.last[:break_label])
      end

      # continue jumps to the innermost enclosing loop's continue target. A
      # switch frame carries the loop's target through unchanged, so a continue
      # inside a switch reaches the loop; a nil target (no enclosing loop at all,
      # even if a switch is open) is the diagnostic case.
      def gen_continue(node)
        target = @control_stack.last && @control_stack.last[:continue_label]
        error_at(node.token, "continue statement not within a loop") unless target
        emit(:jump, a: target)
      end

      # A switch is desugared to a comparison chain (no jump table — that is a
      # later optimization): the controlling expression is evaluated once, then
      # each case constant is compared against it and, on a match, control jumps
      # to that case's label; failing every case it jumps to default (or, absent
      # one, past the switch). The case/default labels themselves are placed
      # while the body is generated, so fall-through between cases (a case
      # without a break) just runs into the next label's code.
      def gen_switch(node)
        control, control_type = gen_value(node.control)
        # The controlling expression must be an integer type (char promotes to
        # int); a pointer, struct or other non-integer has no case constants to
        # match against.
        unless control_type.arithmetic?
          error_at(node.token, "switch quantity is not an integer")
        end

        # Collect every case/default that belongs to this switch — those not
        # sealed off inside a nested switch — assigning each a label and checking
        # for duplicate values and a second default.
        collected = []
        collect_switch_labels(node.body, collected)
        labels, default_node = resolve_switch_labels(collected)

        end_label = new_label
        emit_switch_dispatch(control, collected, labels, default_node, end_label)

        # Generate the body with the labels in scope so each Case/Default marks
        # its position, and with break routed to the switch's end.
        gen_switch_body(node.body, labels, end_label)
        emit(:label, a: end_label)
      end

      # Emits the comparison chain: for each case, "control != value" and a
      # jump-if-zero (i.e. jump when equal) to the case's label; then an
      # unconditional jump to default (or the switch's end when there is none).
      # ">> jump when equal" is spelled with the existing :ne + :jump_if_zero
      # because the IR has no jump-if-nonzero.
      def emit_switch_dispatch(control, collected, labels, default_node, end_label)
        collected.each do |node|
          next if node.is_a?(Front::AST::Default)

          value_reg = new_vreg
          emit(:const, dst: value_reg, a: node.value)
          cmp = new_vreg
          emit(:ne, dst: cmp, a: control, b: value_reg)
          emit(:jump_if_zero, a: cmp, b: labels[node])
        end
        emit(:jump, a: default_node ? labels[default_node] : end_label)
      end

      # Assigns a fresh label to each collected case/default and diagnoses a
      # duplicate case value or a second default. Returns [labels, default_node]
      # where `labels` maps each node (by identity) to its label id.
      def resolve_switch_labels(collected)
        labels = {}.compare_by_identity
        seen_values = {}
        default_node = nil
        collected.each do |node|
          if node.is_a?(Front::AST::Default)
            error_at(node.token, "multiple default labels in one switch") if default_node
            default_node = node
          elsif seen_values.key?(node.value)
            error_at(node.token, "duplicate case value '#{node.value}'")
          else
            seen_values[node.value] = true
          end
          labels[node] = new_label
        end
        [labels, default_node]
      end

      # Recursively gathers the Case/Default nodes that belong to one switch,
      # appending them to `collected` in source order. It descends through every
      # statement that can textually enclose a label (blocks, if arms, loops,
      # labeled statements and the case/default bodies themselves) but stops at a
      # nested switch, whose own cases belong to it, not this one.
      def collect_switch_labels(stmt, collected)
        case stmt
        when Front::AST::Case, Front::AST::Default
          collected << stmt
          collect_switch_labels(stmt.body, collected)
        when Front::AST::Label
          collect_switch_labels(stmt.body, collected)
        when Front::AST::Block
          stmt.items.each { |item| collect_switch_labels(item, collected) }
        when Front::AST::If
          collect_switch_labels(stmt.then_stmt, collected)
          collect_switch_labels(stmt.else_stmt, collected) if stmt.else_stmt
        when Front::AST::While, Front::AST::DoWhile, Front::AST::For
          collect_switch_labels(stmt.body, collected)
        end
        # Every other statement (a return, an expression, a declaration, a break,
        # a goto, or a nested switch) either holds no statement or, in the
        # switch's case, seals off its own labels, so recursion stops here.
      end

      # Generates a switch body with its case labels in scope (so Case/Default
      # nodes resolve to the labels the dispatch chain assigned) and break routed
      # to the switch's end. The continue target is inherited from the enclosing
      # loop unchanged, so a continue inside the switch still restarts that loop.
      def gen_switch_body(body, labels, break_label)
        inherited_continue = @control_stack.last && @control_stack.last[:continue_label]
        @case_label_stack.push(labels)
        @control_stack.push(break_label: break_label, continue_label: inherited_continue)
        gen_statement(body)
      ensure
        @control_stack.pop
        @case_label_stack.pop
      end

      # A case label: place the label the dispatch chain assigned, then generate
      # the labeled statement so control flows into it on a match (or falls
      # through from the case above). A Case reached with no switch open, or one
      # that belongs to an outer switch, has no label and is diagnosed.
      def gen_case(node)
        label = current_case_label(node)
        error_at(node.token, "case label not within a switch statement") unless label
        emit(:label, a: label)
        gen_statement(node.body)
      end

      # A default label, lowered exactly like a case: mark its position and
      # generate the labeled statement. Diagnosed when reached outside a switch.
      def gen_default(node)
        label = current_case_label(node)
        error_at(node.token, "'default' label not within a switch statement") unless label
        emit(:label, a: label)
        gen_statement(node.body)
      end

      # Looks up the label the innermost switch's dispatch assigned to this
      # Case/Default node. The node is matched by identity, so a label is found
      # only while generating the very switch body that collected it.
      def current_case_label(node)
        map = @case_label_stack.last
        map && map[node]
      end

      # goto: an unconditional jump to the named label. The label id is allocated
      # on first sight (here for a forward jump, or at the definition for a
      # backward one), so the jump can be emitted immediately with no
      # backpatching; the token is kept to locate the goto if the label turns out
      # to be undefined at the function's end.
      def gen_goto(node)
        entry = @goto_labels[node.label] ||= { id: new_label, defined: false, token: node.token }
        emit(:jump, a: entry[:id])
      end

      # A labeled statement "name: stmt": define the label (allocating its id if
      # a forward goto has not already) and place it, then generate the prefixed
      # statement. A name defined twice in one function is a diagnostic.
      def gen_label(node)
        entry = @goto_labels[node.name]
        if entry
          error_at(node.token, "duplicate label '#{node.name}'") if entry[:defined]
          entry[:defined] = true
        else
          entry = @goto_labels[node.name] = { id: new_label, defined: true, token: node.token }
        end
        emit(:label, a: entry[:id])
        gen_statement(node.body)
      end

      # "return;" or "return expr;", checked against the enclosing function's
      # declared return type (@current_return_type): a void function accepts
      # only the valueless form ("return with a value in void function"
      # otherwise), every other return type requires a value ("return without
      # a value" otherwise) that is return-type-compatible (#compatible_assignment?,
      # the same rule assignment and arguments use, so "return 0;" from a pointer
      # function is a null pointer) and is narrowed to that type exactly like a
      # variable's initializer.
      def gen_return(node)
        if @current_return_type.void?
          error_at(node.token, "return with a value in void function") if node.expr
          emit(:ret, a: nil)
          return
        end

        error_at(node.token, "return without a value") unless node.expr

        value, value_type = gen_value(node.expr)
        unless compatible_assignment?(@current_return_type, node.expr, value_type)
          error_at(node.token, "incompatible return type")
        end
        emit(:ret, a: narrow_to_type(value, @current_return_type))
      end

      def gen_variable_decl(decl)
        scope = @scopes.last
        if scope.key?(decl.name)
          error_at(decl.token, "redeclaration of '#{decl.name}'")
        end

        # An array or a struct is an aggregate: it reserves a stack object
        # sized to hold it (a struct must be complete first, so its width is
        # known), and the parser has already rejected any initializer for one.
        # A scalar takes a vreg slot and may be initialized in place.
        if decl.type.array? || decl.type.struct?
          require_complete(decl.type, decl.token)
          scope[decl.name] = Local.new(type: decl.type, storage: new_object(decl.type.size), global: false)
        else
          vreg = new_vreg
          scope[decl.name] = Local.new(type: decl.type, storage: vreg, global: false)
          if decl.initializer
            value, value_type = gen_value(decl.initializer)
            unless compatible_assignment?(decl.type, decl.initializer, value_type)
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
        when Front::AST::MemberAccess
          gen_member_access(node)
        when Front::AST::SizeofExpr
          gen_sizeof(sizeof_operand_type(node.operand), node.token)
        when Front::AST::SizeofType
          gen_sizeof(node.type, node.token)
        when Front::AST::Cast
          gen_cast(node)
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
        when Front::AST::Comma
          gen_comma(node)
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      # "left, right": evaluate `left` for its side effects and throw its value
      # away, then evaluate `right`, whose value and type are the comma
      # expression's. `left` is lowered with #gen_expr rather than #gen_value so
      # a void-typed left operand (a call to a void function) is allowed in the
      # discarded position, matching an expression-statement.
      def gen_comma(node)
        gen_expr(node.left)
        gen_expr(node.right)
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
        elsif local.type.struct?
          # A struct does not decay: unlike an array it keeps its struct type,
          # but its "value" is likewise its object's base address, which member
          # access, "&s" and struct assignment all build on. Nothing is loaded
          # here; a whole struct never lives in a single vreg.
          dst = new_vreg
          emit(:object_addr, dst: dst, a: local.storage)
          [dst, local.type]
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
        elsif local.type.struct?
          # Like a local struct (and unlike a scalar global), a global struct's
          # value is its base address, not a load: it keeps its struct type.
          [addr, local.type]
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

      # "e[i]" read: compute the element address (see #gen_element_address) and,
      # for a scalar element, load through it. A struct element does not load —
      # like a struct variable its value is its (element) address — so indexing
      # an array of structs yields the addressed struct.
      def gen_subscript(node)
        addr, element_type = gen_element_address(node)
        return [addr, element_type] if element_type.struct?

        dst = new_vreg
        emit(:load, dst: dst, a: addr, size: element_type.size)
        [dst, element_type]
      end

      # "s.m" / "p->m" read: compute the member's address (see
      # #gen_member_address) and, for a scalar member, load through it. A struct
      # member yields its own address (a nested struct lvalue) and an array
      # member decays to a pointer to its first element, matching how a struct
      # variable and an array variable each behave.
      def gen_member_access(node)
        addr, member_type = gen_member_address(node)
        if member_type.struct?
          [addr, member_type]
        elsif member_type.array?
          [addr, Type::Pointer.new(member_type.element)]
        else
          dst = new_vreg
          emit(:load, dst: dst, a: addr, size: member_type.size)
          [dst, member_type]
        end
      end

      # The address of a struct member — the lvalue shared by member reads and
      # writes and by "&s.m". It is the base struct's address (see
      # #gen_struct_base) plus the member's constant byte offset; a zero offset
      # (the first member) needs no arithmetic. Returns [address_vreg,
      # member_type].
      def gen_member_address(node)
        base_addr, struct_type = gen_struct_base(node)
        member = struct_type.member(node.member)
        unless member
          error_at(node.token, "no member named '#{node.member}' in '#{struct_type}'")
        end
        return [base_addr, member.type] if member.offset.zero?

        offset = new_vreg
        emit(:const, dst: offset, a: member.offset)
        addr = new_vreg
        emit(:add, dst: addr, a: base_addr, b: offset, size: 8)
        [addr, member.type]
      end

      # Evaluates the object a "." or "->" selects from, returning
      # [struct_address_vreg, complete_struct_type]. For "->" the base is a
      # pointer to a struct (its value is the address directly); for "." the
      # base is a struct lvalue (its value is already an address). Either way an
      # incomplete struct is rejected, since its members are unknown.
      def gen_struct_base(node)
        base, base_type = gen_value(node.base)
        if node.arrow
          require_pointer_to_struct(base_type, node)
          struct_type = base_type.target
        else
          unless base_type.struct?
            error_at(node.token, "request for member '#{node.member}' in something not a structure")
          end
          struct_type = base_type
        end
        require_complete(struct_type, node.token)
        [base, struct_type]
      end

      # Guards the "->" form: its base must be a pointer, and that pointer's
      # target must be a struct. A non-pointer base (e.g. "s->m" on a struct
      # value, where "s.m" was meant) and a pointer to a non-struct are both
      # rejected with the same "not a structure" wording "." uses.
      def require_pointer_to_struct(base_type, node)
        unless base_type.pointer? && base_type.target.struct?
          error_at(node.token, "request for member '#{node.member}' in something not a structure")
        end
      end

      # sizeof folds to a compile-time int constant: the resolved type's byte
      # size. The operand (for the expression form) is never evaluated, so no
      # code other than the constant is emitted. void (an incomplete type with
      # no size) is rejected, whether written directly ("sizeof(void)") or
      # reached through a void-returning call's result type ("sizeof f()").
      def gen_sizeof(type, token)
        error_at(token, "invalid application of 'sizeof' to void type") if type.void?
        # An incomplete struct has no known size to fold, whether written
        # directly ("sizeof(struct node)" before it is defined) or reached
        # through an operand of that type.
        require_complete(type, token)

        dst = new_vreg
        emit(:const, dst: dst, a: type.size)
        [dst, Type::Int]
      end

      # A cast "( type-name ) operand". The destination type steers the whole
      # conversion, since the type-name grammar only ever yields int, char,
      # void, a pointer or a bare struct:
      #   * "(void)e" evaluates e for its side effects and discards the value;
      #   * a pointer destination retags a pointer source (no code), turns a
      #     null pointer constant into a null pointer, and rejects any other
      #     integer (no same-width integer type exists yet) or a struct;
      #   * an arithmetic destination reinterprets an arithmetic source, with
      #     the int -> char narrowing #narrow_to_type already provides, and
      #     rejects a pointer or struct source;
      #   * a struct destination is never a valid cast target here.
      def gen_cast(node)
        target = node.type
        return gen_cast_to_void(node) if target.void?
        if target.struct?
          error_at(node.token, "conversion to non-scalar type requested")
        end

        value, value_type = gen_value(node.operand)
        if target.pointer?
          gen_cast_to_pointer(node, target, value, value_type)
        else
          gen_cast_to_arithmetic(node, target, value, value_type)
        end
      end

      # "(void)e": e is evaluated (with #gen_expr, not #gen_value, so a void
      # operand such as a call to a void function is allowed) and its value is
      # thrown away. The result is a void value, which nothing may consume —
      # #gen_value rejects it everywhere a value is actually needed, leaving
      # "(void)f();" as an expression-statement the one legal use.
      def gen_cast_to_void(node)
        value, = gen_expr(node.operand)
        [value, Type::Void]
      end

      # A cast to a pointer type. A pointer source is reinterpreted in place
      # (the value is the same 64-bit address, only its static type changes), a
      # null pointer constant becomes a 64-bit null pointer (its literal 0
      # already occupies the whole slot), any other integer is rejected until a
      # pointer-width integer type exists, and a struct source has no pointer
      # value to take.
      def gen_cast_to_pointer(node, target, value, value_type)
        return [value, target] if value_type.pointer?
        return [value, target] if Front::AST.null_pointer_constant?(node.operand)
        if value_type.arithmetic?
          error_at(node.token, "cast between pointer and integer is not supported yet")
        end
        error_at(node.token, "cannot cast '#{value_type}' to '#{target}'")
      end

      # A cast to an arithmetic type (int or char). An arithmetic source is
      # reinterpreted, narrowing to char via :sext8 when needed (a widening or
      # same-width conversion needs no code, since the slot already holds a
      # sign-extended value); a pointer source is rejected for want of a
      # pointer-width integer type, and a struct source has no arithmetic value.
      def gen_cast_to_arithmetic(node, target, value, value_type)
        if value_type.pointer?
          error_at(node.token, "cast between pointer and integer is not supported yet")
        end
        unless value_type.arithmetic?
          error_at(node.token, "cannot cast '#{value_type}' to '#{target}'")
        end
        [narrow_to_type(value, target), target]
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
        # "p == 0" / "0 != p": a null pointer constant compares equal or unequal
        # against any pointer. The bare operand types (pointer vs int) would
        # otherwise look mismatched, so recognize it here and compare at 64 bits
        # so the whole address participates. Only "==" and "!=" admit it; the
        # relational operators keep rejecting a pointer against 0.
        if EQUALITY_OPS.include?(node.op)
          if lhs_type.pointer? && Front::AST.null_pointer_constant?(node.rhs)
            return gen_pointer_null_comparison(node.op, lhs, rhs)
          elsif rhs_type.pointer? && Front::AST.null_pointer_constant?(node.lhs)
            return gen_pointer_null_comparison(node.op, lhs, rhs)
          end
        end
        gen_binary_op(node.op, lhs, lhs_type, rhs, rhs_type, node.token)
      end

      # "==" / "!=" between a pointer and a null pointer constant, compared at
      # 64 bits (the null constant's slot already holds a full-width 0). The
      # result is an int 0/1 like any other comparison.
      def gen_pointer_null_comparison(op, lhs, rhs)
        dst = new_vreg
        emit(op, dst: dst, a: lhs, b: rhs, size: 8)
        [dst, Type::Int]
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
        elsif SHIFT_OPS.include?(op)
          # A shift is 32-bit int arithmetic (a char operand is already promoted
          # in its slot); #binary_result_type has rejected any pointer operand.
          # The result is always int. "<<" is the logical :shl; ">>" on a signed
          # int is the arithmetic :sar (an unsigned left operand will select the
          # logical :shr once unsigned types exist). The shift count rides in the
          # b operand, whose low byte the backend reads from cl.
          dst = new_vreg
          emit(op == :shl ? :shl : :sar, dst: dst, a: lhs, b: rhs)
          [dst, Type::Int]
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
        # The element's size scales the index, so an incomplete struct element
        # (its width unknown) is rejected before it reaches #scale_index.
        require_complete(element_type, node.token)
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
      # is a truth value, so a pointer is allowed too ("!p" is "p is null"),
      # compared at 64 bits so the whole address decides the result.
      def gen_logical_not(node)
        operand, operand_type = gen_value(node.operand)
        require_scalar_for_truth(operand_type, node.operand.token)
        zero = new_vreg
        emit(:const, dst: zero, a: 0)
        dst = new_vreg
        emit(:eq, dst: dst, a: operand, b: zero, size: (8 if operand_type.pointer?))
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
          # A struct variable already evaluates to its object's base address
          # (a stack object or a global symbol), so "&s" reuses that and just
          # retags it as a pointer. A scalar's address is its symbol
          # (:global_addr) or the absolute address of its stack slot (:addr_of).
          if local.type.struct?
            addr, = gen_variable_ref(operand)
            return [addr, Type::Pointer.new(local.type)]
          end
          dst = new_vreg
          emit(local.global ? :global_addr : :addr_of, dst: dst, a: local.storage)
          [dst, Type::Pointer.new(local.type)]
        elsif operand.is_a?(Front::AST::Subscript)
          addr, element_type = gen_element_address(operand)
          [addr, Type::Pointer.new(element_type)]
        elsif operand.is_a?(Front::AST::MemberAccess)
          addr, member_type = gen_member_address(operand)
          if member_type.array?
            error_at(node.token, "address of array is not supported yet")
          end
          [addr, Type::Pointer.new(member_type)]
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
        # "*p" of a struct pointer is a struct lvalue: its value is the pointer
        # itself (the struct's address), so nothing is loaded, just as a struct
        # variable yields its address.
        return [addr, result_type] if result_type.struct?

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
        elsif target.is_a?(Front::AST::MemberAccess)
          gen_store_through_member(node, target)
        else
          gen_variable_assignment(node, target)
        end
      end

      # A whole-struct assignment "dst = src" (same struct type), lowered to a
      # :memcpy of the struct's byte width from the source object's address to
      # the destination's. Both sides evaluate to addresses (that is a struct
      # value here), so this works uniformly for a variable, a member, an
      # array element or a "*p" on either side. Returns [dest_addr, struct_type]
      # so a chained "a = b = c" copies into each in turn.
      def gen_struct_copy(dest_addr, src_addr, struct_type)
        emit(:memcpy, a: dest_addr, b: src_addr, size: struct_type.size)
        [dest_addr, struct_type]
      end

      def gen_variable_assignment(node, target)
        local = lookup_local(target.name, target.token)
        if local.type.array?
          error_at(node.token, "array type is not assignable")
        end
        value, value_type = gen_value(node.value)
        unless compatible_assignment?(local.type, node.value, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        # A struct variable is copied whole (both sides are addresses); a scalar
        # is narrowed and written into its slot or global.
        if local.type.struct?
          dest, = gen_variable_ref(target)
          return gen_struct_copy(dest, value, local.type)
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
        unless compatible_assignment?(element_type, node.value, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        return gen_struct_copy(addr, value, element_type) if element_type.struct?

        emit(:store, a: addr, b: value, size: element_type.size)
        [value, element_type]
      end

      # "s.m = v" / "p->m = v": compute the member's address (see
      # #gen_member_address) and write v through it. A struct member is copied
      # whole; an array member is not assignable, like an array variable; every
      # other member is a scalar store the member's width wide.
      def gen_store_through_member(node, target)
        addr, member_type = gen_member_address(target)
        if member_type.array?
          error_at(node.token, "array type is not assignable")
        end
        value, value_type = gen_value(node.value)
        unless compatible_assignment?(member_type, node.value, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        return gen_struct_copy(addr, value, member_type) if member_type.struct?

        emit(:store, a: addr, b: value, size: member_type.size)
        [value, member_type]
      end

      # "*p = v": evaluate p (an address) and v, then write v through the
      # address. The store width follows p's target type. The expression's
      # value is v.
      def gen_store_through_pointer(node, target)
        addr, ptr_type = gen_value(target.operand)
        require_dereferenceable_pointer(ptr_type, target.token)
        target_type = ptr_type.target
        value, value_type = gen_value(node.value)
        unless compatible_assignment?(target_type, node.value, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        return gen_struct_copy(addr, value, target_type) if target_type.struct?

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
          unless compatible_assignment?(param_types[i], arg, arg_type)
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
        lhs = gen_condition(node.lhs)
        false_label = new_label
        end_label = new_label
        result = new_vreg
        emit(:jump_if_zero, a: lhs, b: false_label)

        rhs = gen_condition(node.rhs)
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
        lhs = gen_condition(node.lhs)
        rhs_label = new_label
        false_label = new_label
        end_label = new_label
        result = new_vreg
        emit(:jump_if_zero, a: lhs, b: rhs_label)

        emit_const_copy(result, 1)
        emit(:jump, a: end_label)

        emit(:label, a: rhs_label)
        rhs = gen_condition(node.rhs)
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
        cond = gen_condition(node.condition)
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

        result_type = conditional_result_type(node.then_expr, then_type,
                                              node.else_expr, else_type, node.token)
        [result, result_type]
      end

      # The type of "condition ? then : else": identical types are kept as is,
      # a mixed arithmetic pair (int/char) promotes to int, and a pointer arm
      # paired with a null pointer constant (in either position) takes the
      # pointer type, so "cond ? p : 0" is a pointer. Anything else (a pointer
      # vs a non-null int, or two different pointer types) is rejected. Both
      # arms are passed as AST nodes so the null-pointer-constant check can look
      # at the literal, not just its int type.
      def conditional_result_type(then_node, then_type, else_node, else_type, token)
        return then_type if then_type == else_type
        if then_type.pointer? && Front::AST.null_pointer_constant?(else_node)
          then_type
        elsif else_type.pointer? && Front::AST.null_pointer_constant?(then_node)
          else_type
        elsif then_type.arithmetic? && else_type.arithmetic?
          Type::Int
        else
          error_at(token, "type mismatch in conditional expression")
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
        elsif target.is_a?(Front::AST::MemberAccess)
          gen_compound_assignment_through_member(node, target)
        else
          gen_compound_assignment_to_variable(node, target)
        end
      end

      # "s.m op= v": read the member once through its address, combine it with v
      # under #gen_binary_op's rules, and write it back. An aggregate member (a
      # struct or an array) has no arithmetic, so it is rejected before the read.
      def gen_compound_assignment_through_member(node, target)
        addr, member_type = gen_member_address(target)
        require_scalar_target(member_type, node.token)
        current = new_vreg
        emit(:load, dst: current, a: addr, size: member_type.size)

        value, value_type = gen_value(node.value)
        result, result_type = gen_binary_op(node.op, current, member_type, value, value_type, node.token)
        unless compatible_types?(member_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: result, size: member_type.size)
        [result, member_type]
      end

      def gen_compound_assignment_to_variable(node, target)
        local = lookup_local(target.name, target.token)
        error_at(node.token, "array type is not assignable") if local.type.array?
        error_at(node.token, "invalid operands to binary expression") if local.type.struct?

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
        require_scalar_target(element_type, node.token)
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
        require_scalar_target(target_type, node.token)
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
        elsif target.is_a?(Front::AST::MemberAccess)
          gen_inc_dec_through_member(node, target)
        else
          gen_inc_dec_variable(node, target)
        end
      end

      # "s.m++"/"++s.m": the member is read once through its address, stepped by
      # one, and written back; an aggregate member (a struct or array) has no
      # arithmetic and is rejected first. Prefix yields the new value, postfix
      # the value read before the step.
      def gen_inc_dec_through_member(node, target)
        addr, member_type = gen_member_address(target)
        require_scalar_target(member_type, node.token)
        current = new_vreg
        emit(:load, dst: current, a: addr, size: member_type.size)

        one = new_vreg
        emit(:const, dst: one, a: 1)
        result, result_type = gen_binary_op(node.op, current, member_type, one, Type::Int, node.token)
        unless compatible_types?(member_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: result, size: member_type.size)
        node.prefix ? [result, member_type] : [current, member_type]
      end

      def gen_inc_dec_variable(node, target)
        local = lookup_local(target.name, target.token)
        error_at(node.token, "array type is not assignable") if local.type.array?
        error_at(node.token, "invalid operands to binary expression") if local.type.struct?

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
        require_scalar_target(element_type, node.token)
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
        require_scalar_target(target_type, node.token)
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

      # Whether `value_node` (whose rvalue type is `actual`) may initialize, be
      # assigned to, be passed as, or be returned as `expected`. It is
      # #compatible_types? extended with the null-pointer-constant rule: a
      # literal 0 (an integer or a '\0') converts to any pointer type, so
      # "int *p = 0;", "p = 0;", "f(0)" against a pointer parameter and
      # "return 0;" from a pointer function are all well-typed. The node is
      # needed (not just the type) so the check sees the literal 0 rather than
      # merely its int type.
      def compatible_assignment?(expected, value_node, actual)
        return true if expected.pointer? && Front::AST.null_pointer_constant?(value_node)

        compatible_types?(expected, actual)
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
      # one place a void pointer's target may go unexamined). A pointer to an
      # incomplete struct is rejected for the same reason: its target has no
      # known size (member access checks completeness separately).
      def require_dereferenceable_pointer(type, token)
        require_pointer(type, token)
        error_at(token, "invalid use of void pointer") if type.target.void?
        require_complete(type.target, token)
      end

      # Rejects an incomplete struct (a tag never defined) wherever a complete
      # object type is required — a variable or global, a sizeof, a member's
      # base struct, an array/pointer element being sized. Only a struct can be
      # incomplete here; every other type is already complete.
      def require_complete(type, token)
        return unless type.struct? && !type.complete?

        error_at(token, "invalid use of incomplete type '#{type}'")
      end

      # Guards a compound-assignment or "++"/"--" target that must be a scalar
      # the arithmetic can read and write: an aggregate (a struct or an array
      # member) has no arithmetic, so it is rejected with the same wording a
      # bad binary operand gets.
      def require_scalar_target(type, token)
        return unless type.struct? || type.array?

        error_at(token, "invalid operands to binary expression")
      end

      # Evaluates an expression used as a truth value (an if/while/do-while/for
      # condition, a "&&"/"||" operand, a "?:" condition) and returns the vreg
      # the branch instructions test against zero. An arithmetic value is used
      # directly. A pointer is a valid scalar condition too — its truth is "is
      # not null" — so it is desugared to a 64-bit "pointer != 0", yielding an
      # int 0/1 the 32-bit :jump_if_zero test then reads without ever truncating
      # the address (the concern that made Step 9 reject pointer conditions
      # outright). A struct has no truth value and is rejected; a void one is
      # already caught by #gen_value.
      def gen_condition(node)
        value, type = gen_value(node)
        require_scalar_for_truth(type, node.token)
        return value if type.arithmetic?

        zero = new_vreg
        emit(:const, dst: zero, a: 0)
        dst = new_vreg
        emit(:ne, dst: dst, a: value, b: zero, size: 8)
        dst
      end

      # Guards a value used for its truth (a condition or a "!" operand): an
      # arithmetic value or a pointer is a scalar with a well-defined truth
      # value, but a struct is not (void is already rejected by #gen_value
      # before it reaches here).
      def require_scalar_for_truth(type, token)
        return if type.arithmetic? || type.pointer?

        error_at(token, "used struct type value where scalar is required")
      end

      COMPARISON_OPS = %i[eq ne lt le gt ge].freeze

      def comparison_op?(op)
        COMPARISON_OPS.include?(op)
      end

      # The two shift operators, whose operand order matters (the count is the
      # right operand, never commuted) and whose lowering is special (the count
      # rides in cl), so #gen_binary_op handles them apart from the commutative
      # 32-bit ops that share the plain :add lowering.
      SHIFT_OPS = %i[shl shr].freeze

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
        # Pointer arithmetic scales by the target's size, which an incomplete
        # struct target has none of, so it is rejected here alongside void.
        require_complete(type.target, token)
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
      #   * "*" "/" "%", the bitwise "&" "|" "^" and the shifts "<<" ">>":
      #     arithmetic/arithmetic -> int only (any pointer operand is invalid),
      #     which is exactly the fall-through "else" case below.
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
            else # :mul, :div, :mod, :and, :or, :xor, :shl, :shr
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
        elsif node.is_a?(Front::AST::MemberAccess)
          # A member keeps its declared type here (no array-to-pointer decay),
          # so "sizeof s.arr" measures the whole member array, like "sizeof a"
          # for a bare array variable.
          static_member(node).type
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
        when Front::AST::MemberAccess
          member = static_member(node)
          decay(member.type)
        when Front::AST::Binary
          static_binary_type(node)
        when Front::AST::Cast
          # A cast's rvalue type is simply the type named, mirroring #gen_cast.
          # sizeof rejects a "(void)e" operand through gen_sizeof's void guard,
          # just as it would a bare void.
          node.type
        when Front::AST::Unary
          static_unary_type(node)
        when Front::AST::Assignment, Front::AST::CompoundAssignment, Front::AST::IncDec
          static_type(node.target)
        when Front::AST::Comma
          # The comma operator's type is its right operand's, mirroring #gen_comma
          # (the left operand is evaluated only for effect), so "sizeof(a, b)"
          # measures b's type.
          static_type(node.right)
        when Front::AST::LogicalAnd, Front::AST::LogicalOr
          Type::Int
        when Front::AST::Conditional
          static_conditional_type(node)
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      # The array-to-pointer decay applied to an rvalue type: an array becomes a
      # pointer to its element, everything else (a struct included, since it
      # does not decay) is left as is. Used by the code-free type inference.
      def decay(type)
        type.array? ? Type::Pointer.new(type.element) : type
      end

      # Resolves the member a "." / "->" selects, using only static types (no
      # code emitted), for sizeof and address-of. It mirrors #gen_struct_base +
      # #gen_member_address: the base's struct type is inferred, an incomplete
      # struct or a base that is not a structure is rejected, and a missing
      # member is diagnosed. Returns the Type::Member.
      def static_member(node)
        base_type = static_type(node.base)
        struct_type =
          if node.arrow
            unless base_type.pointer? && base_type.target.struct?
              error_at(node.token, "request for member '#{node.member}' in something not a structure")
            end
            base_type.target
          else
            unless base_type.struct?
              error_at(node.token, "request for member '#{node.member}' in something not a structure")
            end
            base_type
          end
        require_complete(struct_type, node.token)
        struct_type.member(node.member) ||
          error_at(node.token, "no member named '#{node.member}' in '#{struct_type}'")
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
        conditional_result_type(node.then_expr, static_type(node.then_expr),
                                node.else_expr, static_type(node.else_expr), node.token)
      end

      # A binary operation's rvalue type without emitting code, mirroring
      # #gen_binary: an "=="/"!=" between a pointer and a null pointer constant
      # is an int comparison (the bare operand types would look mismatched),
      # everything else defers to #binary_result_type.
      def static_binary_type(node)
        lhs_type = static_type(node.lhs)
        rhs_type = static_type(node.rhs)
        if EQUALITY_OPS.include?(node.op) &&
           ((lhs_type.pointer? && Front::AST.null_pointer_constant?(node.rhs)) ||
            (rhs_type.pointer? && Front::AST.null_pointer_constant?(node.lhs)))
          return Type::Int
        end
        binary_result_type(node.op, lhs_type, rhs_type, node.token)
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
        elsif operand.is_a?(Front::AST::MemberAccess)
          member = static_member(operand)
          error_at(node.token, "address of array is not supported yet") if member.type.array?
          Type::Pointer.new(member.type)
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
