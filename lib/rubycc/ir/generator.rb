# frozen_string_literal: true

require_relative "ir"
require_relative "../front/ast"
require_relative "../front/constant_evaluator"
require_relative "../front/initializer_resolver"
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
      # address :global_addr materializes. `const` records whether the object is
      # top-level const-qualified, so a write to it (a plain assignment, a
      # compound assignment or "++"/"--") is diagnosed as writing a read-only
      # variable; reads and "&" are unaffected.
      Local = Data.define(:type, :storage, :global, :const)
      # Returns an IR::Program: an IR::Function per AST::FunctionDef plus the
      # translation unit's read-only string pool. Prototypes
      # (AST::FunctionDecl) contribute only a signature-table entry and emit no
      # code. The table is filled in source order so a definition can reference
      # itself (recursion) or an earlier prototype (mutual recursion), while a
      # call to a still-unknown name is diagnosed as an implicit declaration.
      def generate(program)
        # name -> { param_types:, return_type:, variadic:, defined: }.
        # `param_types` is the array of parameter Rubycc::Types (its length being
        # the fixed arity — for a variadic function, only the named parameters);
        # `return_type` is the declared Rubycc::Type of a call to this function;
        # `variadic` is true for a "..."-terminated prototype (its calls admit
        # extra, promoted arguments past the fixed ones); `defined` distinguishes
        # a prototype from a completed definition so redefinitions can be
        # rejected.
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
        # Names of file-scope variables that have a real definition here (storage
        # reserved), as opposed to a bare `extern` reference. A second definition
        # of a name already in this set is a redefinition, while any number of
        # `extern` references may coexist with (at most) one definition.
        @defined_globals = {}
        # A monotonic counter that names each block-scope `static` uniquely as
        # "<var>.<n>". A '.' cannot appear in a C identifier, so these names
        # never collide with a real symbol; the counter runs over the whole
        # translation unit in source order, keeping the output deterministic (N4).
        @static_local_count = 0
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
            # A prototype's storage class (`static`/`extern`) is recorded on the
            # AST but drives no behavior here: a declaration reserves nothing and
            # M1 does not diagnose a static/extern mismatch against the eventual
            # definition, so a prototype only contributes a signature.
            declare_function(decl.name, decl.return_type, decl.params.map(&:type),
                             variadic: decl.variadic, defined: false, token: decl.token)
          when Front::AST::FunctionDef
            declare_function(decl.name, decl.return_type, decl.params.map(&:type),
                             variadic: decl.variadic, defined: true, token: decl.token)
            # `static` gives the definition internal linkage (an STB_LOCAL text
            # symbol); an absent or `extern` specifier leaves it external.
            linkage = decl.storage == :static ? :internal : :external
            ir_functions << gen_function(decl, linkage)
          end
        end
        Program.new(ir_functions, @strings, @globals)
      end

      private

      # Records a file-scope variable. A name already taken by a function is a
      # redefinition. The storage class then steers the outcome:
      #   * `extern` is a reference declaration — it registers the binding (so
      #     later code sees the name and its type) but reserves no storage, and
      #     any number may coexist with each other and with one real definition;
      #   * an absent or `static` specifier is a definition — it lays out an
      #     IR::Global (external or internal linkage) and marks the name defined,
      #     so a second definition is caught as a redefinition.
      # Whenever a binding already exists (from an earlier reference or
      # definition), the two must agree on type.
      def declare_global(decl)
        if @signatures.key?(decl.name)
          error_at(decl.token, "redefinition of '#{decl.name}'")
        end
        # Resolve the initializer first: a "[]" array bound is only known once
        # its initializer has been walked, so the final type (and thus the
        # storage size) may differ from the declared one. An uninitialized global
        # keeps its declared type and lands in .bss (a nil init).
        type = decl.type
        init = nil
        if decl.initializer_node
          type, init = build_global_init(type, decl.initializer_node, decl.token)
        elsif !decl.initializer_value.nil?
          init = GlobalInit.new(bytes: pack_integer(decl.initializer_value, type.size), relocations: [])
        end
        # A global needs a known storage width and boundary, so an incomplete
        # struct (a tag never defined) cannot be laid out in .bss/.data — and an
        # `extern` reference likewise needs a concrete type to bind here.
        require_complete(type, decl.token)

        existing = @global_bindings[decl.name]
        if existing && existing.type != type
          error_at(decl.token, "conflicting types for '#{decl.name}'")
        end

        if decl.storage == :extern
          # A reference declaration: bind the name (once) with no storage. A real
          # definition, before or after, supplies the object; if none does, a
          # reference to it becomes an undefined symbol for the linker.
          @global_bindings[decl.name] ||=
            Local.new(type: type, storage: decl.name, global: true, const: decl.const)
          return
        end

        if @defined_globals[decl.name]
          error_at(decl.token, "redefinition of '#{decl.name}'")
        end
        @defined_globals[decl.name] = true
        linkage = decl.storage == :static ? :internal : :external
        @global_bindings[decl.name] = Local.new(type: type, storage: decl.name, global: true, const: decl.const)
        @globals << Global.new(name: decl.name, size: type.size, align: type.alignment,
                               init: init, linkage: linkage)
      end

      # Materializes a global's deferred initializer into [final_type,
      # GlobalInit]. A structural initializer (a brace list, or a string for a
      # char array) is resolved and each placement packed into the byte image; a
      # bare pointer initializer is an address constant. The image starts all
      # zeros, so any byte the initializer leaves unset — struct padding, an
      # array's tail, a string's NUL — is already zero (6.7.9p10/p21).
      def build_global_init(type, node, token)
        if Front::InitializerResolver.structural?(type, node)
          resolved = Front::InitializerResolver.resolve(type, node)
          final_type = resolved.type
          require_complete(final_type, token)
          image = "\0".b * final_type.size
          relocations = []
          resolved.entries.each { |entry| pack_global_entry(entry, image, relocations) }
          [final_type, GlobalInit.new(bytes: image, relocations: relocations)]
        else
          require_complete(type, token)
          image = "\0".b * type.size
          relocations = []
          pack_global_scalar(0, type, node, image, relocations)
          [type, GlobalInit.new(bytes: image, relocations: relocations)]
        end
      end

      # Writes one resolved placement into a global's image: a scalar folded (or
      # relocated, for a pointer) into its slot, or a string literal's bytes
      # copied verbatim (the surrounding zeros supply its NUL and any padding).
      def pack_global_entry(entry, image, relocations)
        case entry
        when Front::ScalarInit
          pack_global_scalar(entry.offset, entry.type, entry.value, image, relocations)
        when Front::StringInit
          image[entry.offset, entry.bytes.bytesize] = entry.bytes.b
        end
      end

      # Packs one scalar slot of a global. An integer/_Bool slot is folded to a
      # constant and stored little-endian; a pointer slot is an address constant
      # (see #pack_global_pointer). Any other slot type has no constant form.
      def pack_global_scalar(offset, type, value, image, relocations)
        if type.integer?
          folded = fold_global_constant(value)
          image[offset, type.size] = pack_integer(folded, type.size)
        elsif type.pointer?
          pack_global_pointer(offset, type, value, image, relocations)
        else
          error_at(value.token, "unsupported initializer for global variable")
        end
      end

      # Packs a global pointer slot. The address constants this subset admits
      # are: a null pointer constant (the eight zero bytes already in place); a
      # string literal (a .rodata relocation on the interned string); a "&global"
      # or a decayed global array name (an absolute relocation against that
      # object's symbol); and a function name "f" or "&f" (the same, against the
      # function's symbol, its signature checked against the pointer's target).
      # A computed address like "&arr[i]" still has no constant form.
      def pack_global_pointer(offset, type, value, _image, relocations)
        if Front::AST.null_pointer_constant?(value)
          nil # eight zero bytes are already in the image
        elsif value.is_a?(Front::AST::StringLit)
          relocations << GlobalReloc.new(offset: offset, kind: :string,
                                         symbol: nil, string_id: intern_string(value.value))
        elsif (name = function_address_constant(type, value)) ||
              (name = address_constant_symbol(value))
          relocations << GlobalReloc.new(offset: offset, kind: :symbol, symbol: name, string_id: nil)
        else
          error_at(value.token, "unsupported initializer for global variable")
        end
      end

      # The function symbol a pointer initializer takes the address of — "f" or
      # "&f" — or nil when `value` is not a function reference. The function's
      # signature must match the pointer's target type, exactly as a local
      # function-pointer assignment requires. A name shadowed by a file-scope
      # variable is left to #address_constant_symbol.
      def function_address_constant(type, value)
        name =
          if value.is_a?(Front::AST::Unary) && value.op == :addr &&
             value.operand.is_a?(Front::AST::VariableRef)
            value.operand.name
          elsif value.is_a?(Front::AST::VariableRef)
            value.name
          end
        return nil if name.nil? || @global_bindings.key?(name)

        sig = @signatures[name]
        return nil unless sig

        unless type.pointer? && type.target == function_type_of(sig)
          error_at(value.token, "incompatible types in initialization")
        end
        name
      end

      # The file-scope object symbol a pointer initializer takes the address of,
      # or nil when `value` is not such an address constant: "&g" against a global
      # variable, or a bare global array name that decays to a pointer to its
      # first element.
      def address_constant_symbol(value)
        if value.is_a?(Front::AST::Unary) && value.op == :addr &&
           value.operand.is_a?(Front::AST::VariableRef)
          binding = @global_bindings[value.operand.name]
          return binding.storage if binding
        elsif value.is_a?(Front::AST::VariableRef)
          binding = @global_bindings[value.name]
          return binding.storage if binding&.type&.array?
        end
        nil
      end

      # Folds a global's scalar-integer initializer element to a constant, the
      # rule (6.6) a global requires; a non-constant element (a call, a variable)
      # or a division by zero is diagnosed at its own token.
      def fold_global_constant(node)
        Front::ConstantEvaluator.evaluate(node)
      rescue Front::ConstantEvaluator::NotConstant => e
        error_at(e.token, "initializer element is not a constant")
      rescue Front::ConstantEvaluator::DivisionByZero => e
        error_at(e.token, "division by zero in constant expression")
      end

      # Packs an integer into `size` little-endian two's-complement bytes. The
      # value is masked to the slot width first — the constant evaluator works in
      # unbounded Ruby Integers, so an expression like "1L << 100" would
      # otherwise overflow pack's fixed-width directives with a RangeError
      # instead of storing the low bytes the way a C store to that width does.
      def pack_integer(value, size)
        masked = value & ((1 << (size * 8)) - 1)
        case size
        when 1 then [masked].pack("C")
        when 2 then [masked].pack("S<")
        when 4 then [masked].pack("L<")
        else [masked].pack("Q<")
        end
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
      def declare_function(name, return_type, param_types, variadic:, defined:, token:)
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
          if existing[:param_types] != param_types || existing[:return_type] != return_type ||
             existing[:variadic] != variadic
            error_at(token, "conflicting types for '#{name}'")
          elsif defined && existing[:defined]
            error_at(token, "redefinition of '#{name}'")
          end
        end
        @signatures[name] = {
          param_types: param_types,
          return_type: return_type,
          variadic: variadic,
          defined: defined || existing&.fetch(:defined) || false
        }
      end

      def gen_function(func, linkage)
        @insts = []
        @vreg_count = 0
        @label_count = 0
        # The enclosing function's declared return type, consulted by
        # #gen_return to type-check "return ...;" and by the implicit-return
        # fallback below.
        @current_return_type = func.return_type
        # The enclosing function's "..." flag and its ordered named parameters,
        # consulted by #gen_va_start to reject va_start in a fixed-arity function
        # and to check its second argument against the last named parameter.
        @current_variadic = func.variadic
        @current_named_params = func.params
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
          @scopes.last[param.name] = Local.new(type: param.type, storage: new_vreg, global: false, const: param.const)
        end

        # A narrow integer parameter (char/short and their unsigned forms,
        # _Bool) arrives in a register with an unspecified high half; re-derive
        # its value from the low bytes in place, by the type's signedness, so
        # its slot holds the properly extended value like any other narrow
        # lvalue. Wider parameters (int/long and their unsigned forms, pointers)
        # already arrive in the right representation.
        func.params.each do |param|
          type = param.type
          next unless type.integer? && (type.size == 1 || type.size == 2)

          slot = @scopes.last[param.name].storage
          emit(type.signed? ? :sext : :zext, dst: slot, a: slot, size: type.size)
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

        Function.new(func.name, @insts, @vreg_count, func.params.size, @stack_objects, linkage, func.variadic)
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
        # The controlling expression must be an integer type; a pointer, struct
        # or other non-integer has no case constants to match against. It
        # undergoes integer promotion (6.8.4.2), and the case constants are
        # compared against it in that promoted type.
        unless control_type.integer?
          error_at(node.token, "switch quantity is not an integer")
        end
        promoted_type = integer_promote(control_type)
        control = convert(control, from: control_type, to: promoted_type)

        # Collect every case/default that belongs to this switch — those not
        # sealed off inside a nested switch — assigning each a label and checking
        # for duplicate values and a second default.
        collected = []
        collect_switch_labels(node.body, collected)
        labels, default_node = resolve_switch_labels(collected)

        end_label = new_label
        emit_switch_dispatch(control, promoted_type, collected, labels, default_node, end_label)

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
      def emit_switch_dispatch(control, control_type, collected, labels, default_node, end_label)
        # A size-8 controlling type compares (and loads its case constants) at
        # 64 bits, so a long case value and the high half of the control both
        # participate.
        size = control_type.size == 8 ? 8 : nil
        collected.each do |node|
          next if node.is_a?(Front::AST::Default)

          value_reg = new_vreg
          emit(:const, dst: value_reg, a: node.value, size: size)
          cmp = new_vreg
          emit(:ne, dst: cmp, a: control, b: value_reg, size: size)
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
        emit(:ret, a: convert_for_assignment(value, value_type, @current_return_type))
      end

      def gen_variable_decl(decl)
        scope = @scopes.last
        if scope.key?(decl.name)
          error_at(decl.token, "redeclaration of '#{decl.name}'")
        end

        # A block-scope declarator that builds a function type ("int f(int);"
        # inside a body) declares an external function, not a local object. This
        # subset does not model that, so it is rejected here rather than laid out
        # as if it were a variable. A function *pointer* local (Pointer with a
        # FunctionType target) is an ordinary 8-byte scalar and falls through.
        if decl.type.function?
          error_at(decl.token, "block-scope function declarations are not supported")
        end

        # A block-scope storage class changes where the object lives, not its
        # visibility beyond this block: `static` gives it a private file-scope
        # object (see #gen_block_static_decl) and `extern` merely references a
        # file-scope one (see #gen_block_extern_decl). Only an automatic object
        # takes an ordinary local slot.
        case decl.storage
        when :static
          gen_block_static_decl(decl, scope)
        when :extern
          gen_block_extern_decl(decl)
        # An array or a struct is an aggregate lowered onto a stack object; a
        # scalar (int, pointer) takes a vreg slot.
        else
          if decl.type.array? || decl.type.struct?
            gen_aggregate_decl(decl, scope)
          else
            gen_scalar_decl(decl, scope)
          end
        end
      end

      # A block-scope `static` object. It has automatic-storage *scope* (visible
      # only in this block, named in `scope`) but static *storage*: it is lowered
      # to a uniquely named file-scope IR::Global with internal linkage, so it
      # persists across calls and is initialized once, at load time, with no
      # runtime initialization code. The unique name "<var>.<n>" cannot clash
      # with a real symbol, so two same-named block statics (in different
      # functions or blocks) get distinct objects. The binding is a global one,
      # so every access flows through the ordinary :global_addr path.
      def gen_block_static_decl(decl, scope)
        name = "#{decl.name}.#{@static_local_count}"
        @static_local_count += 1
        type = decl.type
        init = nil
        # The initializer must be a constant expression (6.7.8p4), folded through
        # the same global-initializer path that a file-scope object uses; a
        # non-constant element reaches "initializer element is not a constant"
        # there. Without an initializer the object is zero-filled in .bss.
        type, init = build_global_init(type, decl.initializer, decl.token) if decl.initializer
        require_complete(type, decl.token)
        scope[decl.name] = Local.new(type: type, storage: name, global: true, const: decl.const)
        @globals << Global.new(name: name, size: type.size, align: type.alignment,
                               init: init, linkage: :internal)
      end

      # A block-scope `extern` declaration references a file-scope object defined
      # elsewhere (this unit or another). It reserves no storage; it registers a
      # file-scope binding if the name is not already bound, so references resolve
      # to that external symbol (an undefined one if nothing defines it here).
      # M1 lets this binding outlive the block, a deliberate simplification.
      def gen_block_extern_decl(decl)
        require_complete(decl.type, decl.token)
        existing = @global_bindings[decl.name]
        if existing && existing.type != decl.type
          error_at(decl.token, "conflicting types for '#{decl.name}'")
        end
        @global_bindings[decl.name] ||=
          Local.new(type: decl.type, storage: decl.name, global: true, const: decl.const)
      end

      # A scalar local. A brace-wrapped initializer ("int x = {5};", 6.7.9p11) is
      # resolved to its single scalar value first; every other initializer is a
      # plain expression. The binding is created before the initializer runs, so
      # a (pathological) self-reference resolves to this very variable.
      def gen_scalar_decl(decl, scope)
        vreg = new_vreg
        scope[decl.name] = Local.new(type: decl.type, storage: vreg, global: false, const: decl.const)
        return unless decl.initializer

        value_node = decl.initializer
        if value_node.is_a?(Front::AST::InitializerList)
          value_node = Front::InitializerResolver.resolve(decl.type, value_node).entries.first.value
        end
        value, value_type = gen_value(value_node)
        unless compatible_assignment?(decl.type, value_node, value_type)
          error_at(decl.token, "incompatible types in assignment")
        end
        emit(:copy, dst: vreg, a: convert_for_assignment(value, value_type, decl.type))
      end

      # An aggregate local (array or struct). A structural initializer (a brace
      # list, or a string for a char array) is resolved — completing an inferred
      # "[]" bound — and lowered onto the stack object; a struct may also be
      # copy-initialized from a whole-struct expression ("struct s a = b;"). The
      # binding is created before the initializer is lowered so a member's
      # initializer could refer back to the object.
      def gen_aggregate_decl(decl, scope)
        type = decl.type
        init = decl.initializer

        if init && Front::InitializerResolver.structural?(type, init)
          resolved = Front::InitializerResolver.resolve(type, init)
          type = resolved.type
          require_complete(type, decl.token)
          base = bind_stack_object(scope, decl.name, type, decl.const)
          lower_resolved_init(base, type, resolved.entries)
          return
        end

        require_complete(type, decl.token)
        base = bind_stack_object(scope, decl.name, type, decl.const)
        return unless init

        # The only non-structural aggregate initializer is a whole-struct copy;
        # an array cannot be initialized from a scalar or another array here.
        if type.struct?
          src, src_type = gen_value(init)
          unless src_type == type
            error_at(decl.token, "incompatible types in initialization")
          end
          gen_struct_copy(base, src, type)
        else
          error_at(decl.token, "invalid initializer for array (expected '{' or a string)")
        end
      end

      # Reserves a stack object for `type`, binds `name` to it, and returns a
      # vreg holding the object's base address (the destination every placement
      # is written through).
      def bind_stack_object(scope, name, type, const)
        object_id = new_object(type.size)
        scope[name] = Local.new(type: type, storage: object_id, global: false, const: const)
        base = new_vreg
        emit(:object_addr, dst: base, a: object_id)
        base
      end

      # Lowers a resolved aggregate initializer onto the object at `base`. The
      # object is zeroed whole first, then each explicit placement overwrites its
      # slot, so any unspecified byte (struct padding, an array's tail, a
      # string's NUL) reads as 0 with no bookkeeping over which ranges stay
      # untouched. Each scalar is converted to its slot's type like an ordinary
      # assignment; a string is written as immediate bytes.
      def lower_resolved_init(base, type, entries)
        zero_fill(base, type.size)
        entries.each do |entry|
          case entry
          when Front::ScalarInit
            addr = offset_address(base, entry.offset)
            value, value_type = gen_value(entry.value)
            unless compatible_assignment?(entry.type, entry.value, value_type)
              error_at(entry.value.token, "incompatible types in initialization")
            end
            converted = convert_for_assignment(value, value_type, entry.type)
            emit(:store, a: addr, b: converted, size: entry.type.size)
          when Front::StringInit
            write_string_bytes(base, entry.offset, entry.bytes)
          end
        end
      end

      # Zeroes `size` bytes at `base`, using the widest store that still fits at
      # each step (8, then 4/2/1 for the tail) so any object size is covered by a
      # handful of stores from a single zero register.
      def zero_fill(base, size)
        zero = new_vreg
        emit(:const, dst: zero, a: 0, size: 8)
        offset = 0
        [8, 4, 2, 1].each do |chunk|
          while size - offset >= chunk
            emit(:store, a: offset_address(base, offset), b: zero, size: chunk)
            offset += chunk
          end
        end
      end

      # Writes a char array's string initializer as a run of 1-byte immediate
      # stores. Immediate bytes (rather than a memcpy from an interned .rodata
      # copy) keep a char-array initializer out of the string pool; the earlier
      # whole-object zeroing already supplied the terminating NUL and any tail.
      def write_string_bytes(base, offset, bytes)
        bytes.each_byte.with_index do |byte, i|
          value = new_vreg
          emit(:const, dst: value, a: byte)
          emit(:store, a: offset_address(base, offset + i), b: value, size: 1)
        end
      end

      # A vreg holding `base + offset`, or `base` itself when the offset is zero
      # (the object's first byte needs no arithmetic).
      def offset_address(base, offset)
        return base if offset.zero?

        off = new_vreg
        emit(:const, dst: off, a: offset)
        addr = new_vreg
        emit(:add, dst: addr, a: base, b: off, size: 8)
        addr
      end

      # Lowers an expression, returning [result_vreg, Rubycc::Type]. The type
      # travels alongside the value so every caller can type-check its operands
      # and pick the right access width for pointer loads and stores.
      def gen_expr(node)
        case node
        when Front::AST::IntLit
          dst = new_vreg
          # The literal's type is fixed by the parser (6.4.4.1); a long/unsigned
          # long constant loads a full 64-bit immediate so its high half is
          # valid, a narrower one a 32-bit immediate.
          emit(:const, dst: dst, a: node.value, size: (8 if node.type.size == 8))
          [dst, node.type]
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
        when Front::AST::AlignofType
          gen_alignof(node.type, node.token)
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
        when Front::AST::VaStart
          gen_va_start(node)
        when Front::AST::VaArg
          gen_va_arg(node)
        when Front::AST::VaEnd
          gen_va_end(node)
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

      # "__builtin_va_start(ap, last)": initializes `ap` so a following
      # __builtin_va_arg can walk the variable arguments. It is only valid inside
      # a variadic function (a fixed-arity one has no variable part to point at),
      # and `last` must name that function's last fixed parameter (6.7.6.3 anchors
      # the variable part just past it). The single :va_start op carries the
      # va_list address and the fixed parameter count, from which the backend
      # fills the four System V fields against its register-save area. The value
      # is void — va_start is only ever an expression-statement.
      def gen_va_start(node)
        unless @current_variadic
          error_at(node.token, "'va_start' used in function with fixed arguments")
        end
        ap = gen_va_list_address(node.ap, node.token, "va_start")
        last = @current_named_params.last
        if last.nil? || last.name != node.last_name
          error_at(node.token, "second argument to 'va_start' is not the last named parameter")
        end
        emit(:va_start, a: ap, b: @current_named_params.size)
        [ap, Type::Void]
      end

      # "__builtin_va_arg(ap, type)": fetches the next variable argument as
      # `type` and advances `ap`, lowered entirely to existing IR (no dedicated
      # op). Following the System V register-save-area convention it reads
      # gp_offset: while it is below 48 the argument still sits in a saved
      # register (reg_save_area + gp_offset, then gp_offset += 8); once it reaches
      # 48 the argument has spilled onto the stack (overflow_arg_area, then that
      # pointer += 8). Both arms deposit the argument's address into one slot the
      # merge point loads through, the load width and signedness following `type`.
      # Only an int/long/unsigned/pointer-sized object type is admissible (see
      # #require_va_arg_type); a promotable or aggregate type is diagnosed.
      def gen_va_arg(node)
        ap = gen_va_list_address(node.ap, node.token, "va_arg")
        type = node.type
        require_va_arg_type(type, node.token)

        gp_field = offset_address(ap, Type::VaListTag.member("gp_offset").offset)
        result_addr = new_vreg
        overflow_label = new_label
        end_label = new_label

        emit_va_arg_dispatch(ap, gp_field, result_addr, overflow_label, end_label)

        dst = new_vreg
        emit_scalar_load(dst, result_addr, type)
        [dst, type]
      end

      # Emits the register-vs-overflow branch of a va_arg. `gp_field` addresses
      # the va_list's gp_offset; `result_addr` is the slot both arms leave the
      # argument's address in.
      def emit_va_arg_dispatch(ap, gp_field, result_addr, overflow_label, end_label)
        # gp = gp_offset; if gp >= 48 the argument is on the stack.
        gp = new_vreg
        emit(:uload, dst: gp, a: gp_field, size: 4)
        limit = new_vreg
        emit(:const, dst: limit, a: 48)
        below = new_vreg
        emit(:ult, dst: below, a: gp, b: limit)
        emit(:jump_if_zero, a: below, b: overflow_label)

        # Register arm: addr = reg_save_area + gp; gp_offset += 8.
        reg_save = new_vreg
        emit(:load, dst: reg_save, a: offset_address(ap, Type::VaListTag.member("reg_save_area").offset), size: 8)
        gp_wide = convert(gp, from: Type::UInt, to: Type::Long)
        reg_addr = new_vreg
        emit(:add, dst: reg_addr, a: reg_save, b: gp_wide, size: 8)
        emit(:copy, dst: result_addr, a: reg_addr)
        emit(:store, a: gp_field, b: bump(gp, 8), size: 4)
        emit(:jump, a: end_label)

        # Overflow arm: addr = overflow_arg_area; overflow_arg_area += 8.
        emit(:label, a: overflow_label)
        overflow_field = offset_address(ap, Type::VaListTag.member("overflow_arg_area").offset)
        overflow = new_vreg
        emit(:load, dst: overflow, a: overflow_field, size: 8)
        emit(:copy, dst: result_addr, a: overflow)
        emit(:store, a: overflow_field, b: bump(overflow, 8, size: 8), size: 8)
        emit(:label, a: end_label)
      end

      # A vreg holding `value + amount`. `size` selects 32- or 64-bit addition
      # (8 for a pointer bump, the default 4 for the gp_offset counter).
      def bump(value, amount, size: nil)
        addend = new_vreg
        emit(:const, dst: addend, a: amount)
        dst = new_vreg
        emit(:add, dst: dst, a: value, b: addend, size: size)
        dst
      end

      # "__builtin_va_end(ap)": ends traversal of `ap`. System V keeps no state
      # to tear down, so beyond type-checking the operand this emits nothing; its
      # value is void, like va_start.
      def gen_va_end(node)
        ap = gen_va_list_address(node.ap, node.token, "va_end")
        [ap, Type::Void]
      end

      # Evaluates a va_* builtin's first operand and returns the vreg holding the
      # address of its __va_list_tag. Both a local `__builtin_va_list` (a one-tag
      # array that decays to a __va_list_tag *) and a forwarded parameter (a
      # __va_list_tag * after the 6.7.6.3 adjustment) yield exactly that pointer,
      # so the one type check — a pointer to the shared VaListTag — covers both
      # and rejects anything else (`builtin` names the site in the diagnostic).
      def gen_va_list_address(node, token, builtin)
        ap, ap_type = gen_value(node)
        unless ap_type.pointer? && ap_type.target == Type::VaListTag
          error_at(token, "first argument to '#{builtin}' is not of type '__builtin_va_list'")
        end
        ap
      end

      # Rejects a va_arg type-name that cannot be fetched. A char/short/_Bool (or
      # their unsigned forms) is of promotable type: it was widened to int by the
      # default argument promotions at the call, so va_arg(char) would read the
      # wrong width — the caller must use the promoted type. A struct/union, void,
      # function or array has no scalar argument slot to read here at all. Only an
      # int/unsigned/long/unsigned long (enum being int already) or a pointer is
      # admissible.
      def require_va_arg_type(type, token)
        if type.integer? && type.size < 4
          error_at(token, "second argument to 'va_arg' is of promotable type '#{type}'")
        end
        return if (type.integer? && type.size >= 4) || type.pointer?

        error_at(token, "second argument to 'va_arg' has type '#{type}', which va_arg cannot yield")
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
      # global is read through its address (see #gen_global_ref). A name that
      # binds no variable but names a function is a function designator, which
      # decays to a pointer to that function (see #gen_function_designator).
      def gen_variable_ref(node)
        local = lookup_variable(node.name)
        return gen_function_designator(node.name, node.token) unless local
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
        else
          [read_local_scalar(local), local.type]
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
          emit_scalar_load(dst, addr, local.type)
          [dst, local.type]
        end
      end

      # A function designator that appears anywhere but the callee of a call
      # (or under sizeof) decays to a pointer to the function (6.3.2.1p4), so
      # "fp = f", "&f", passing "f" as an argument and comparing two function
      # names all see the same Pointer(FunctionType) value. Its value is the
      # function's own address, materialized by :func_addr; a name that is
      # neither a visible variable nor a declared function is undeclared.
      def gen_function_designator(name, token)
        sig = @signatures[name]
        error_at(token, "undeclared variable '#{name}'") unless sig

        dst = new_vreg
        emit(:func_addr, dst: dst, a: name)
        [dst, Type::Pointer.new(function_type_of(sig))]
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
        emit_scalar_load(dst, addr, element_type)
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
          emit_scalar_load(dst, addr, member_type)
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

      # sizeof folds to a compile-time constant of type size_t (unsigned long
      # here): the resolved type's byte size. The operand (for the expression
      # form) is never evaluated, so no code other than the constant is emitted.
      # void (an incomplete type with no size) is rejected, whether written
      # directly ("sizeof(void)") or reached through a void-returning call's
      # result type ("sizeof f()").
      def gen_sizeof(type, token)
        error_at(token, "invalid application of 'sizeof' to void type") if type.void?
        # A function type has no size (only a pointer to it does), whether
        # written directly ("sizeof(int (int))") or reached through an operand.
        error_at(token, "invalid application of 'sizeof' to a function type") if type.function?
        # An incomplete struct has no known size to fold, whether written
        # directly ("sizeof(struct node)" before it is defined) or reached
        # through an operand of that type.
        require_complete(type, token)

        dst = new_vreg
        # The size is small and non-negative, so a 32-bit mov (which zeroes the
        # upper half of rax) already leaves a valid 8-byte unsigned long value.
        emit(:const, dst: dst, a: type.size)
        [dst, Type::ULong]
      end

      # _Alignof folds to a size_t (unsigned long) constant, the resolved type's
      # alignment, mirroring #gen_sizeof: a void, function or incomplete type has
      # no alignment and is rejected the same way sizeof rejects a missing size.
      def gen_alignof(type, token)
        error_at(token, "invalid application of '_Alignof' to void type") if type.void?
        error_at(token, "invalid application of '_Alignof' to a function type") if type.function?
        require_complete(type, token)

        dst = new_vreg
        # An alignment is a small power of two, so a 32-bit mov already leaves a
        # valid unsigned long value (its upper half zeroed).
        emit(:const, dst: dst, a: type.alignment)
        [dst, Type::ULong]
      end

      # A cast "( type-name ) operand". The destination type steers the whole
      # conversion, since the type-name grammar only ever yields an integer
      # type, void, a pointer or a bare struct:
      #   * "(void)e" evaluates e for its side effects and discards the value;
      #   * a pointer destination retags a pointer source (no code), turns a
      #     null pointer constant into a null pointer, and widens any other
      #     integer to a 64-bit address value, but rejects a struct;
      #   * an arithmetic destination converts an integer or pointer source to
      #     the destination type (#convert), and rejects a struct source;
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
      # already occupies the whole slot), and any other integer is widened to a
      # 64-bit address value by its own signedness (a signed int extends its
      # sign, an unsigned one zero-fills). A struct source has no pointer value
      # to take.
      def gen_cast_to_pointer(node, target, value, value_type)
        return [value, target] if value_type.pointer?
        return [value, target] if Front::AST.null_pointer_constant?(node.operand)
        if value_type.integer?
          # Widen to the pointer's 8-byte width. convert(to: Long) triggers the
          # size-8 path, extending by the source signedness; a source that is
          # already 8 bytes passes through.
          return [convert(value, from: value_type, to: Type::Long), target]
        end
        error_at(node.token, "cannot cast '#{value_type}' to '#{target}'")
      end

      # A cast to an arithmetic type. An integer source is converted to the
      # destination type (narrowing, widening or a sign change, per #convert); a
      # pointer source is reinterpreted as an unsigned 64-bit value and then
      # converted to the destination width. A struct source has no arithmetic
      # value.
      def gen_cast_to_arithmetic(node, target, value, value_type)
        source_type = value_type.pointer? ? Type::ULong : value_type
        unless source_type.integer?
          error_at(node.token, "cannot cast '#{value_type}' to '#{target}'")
        end
        [convert(value, from: source_type, to: target), target]
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
          gen_comparison(op, lhs, lhs_type, rhs, rhs_type)
        elsif SHIFT_OPS.include?(op)
          gen_shift(op, lhs, lhs_type, rhs, result_type)
        elsif lhs_type.pointer? && rhs_type.pointer?
          gen_pointer_difference(lhs, rhs, lhs_type)
        elsif lhs_type.pointer?
          gen_pointer_int_arith(op, lhs, rhs, rhs_type, lhs_type)
        elsif rhs_type.pointer?
          # int + pointer (subtraction in this order was already rejected).
          gen_pointer_int_arith(op, rhs, lhs, lhs_type, rhs_type)
        else
          gen_integer_arithmetic(op, lhs, lhs_type, rhs, rhs_type, result_type)
        end
      end

      # A comparison, yielding int 0/1. Two pointers compare as full 64-bit
      # values: equality with the sign-independent :eq/:ne, ordering with the
      # unsigned :ult family, since an address is unsigned. Two integers are
      # first brought to their common type (6.3.1.8), then compared with the
      # signed or unsigned setcc that the common type's signedness selects; the
      # comparison is 64-bit only when the common type is 8 bytes.
      def gen_comparison(op, lhs, lhs_type, rhs, rhs_type)
        dst = new_vreg
        if lhs_type.pointer? && rhs_type.pointer?
          cmp = EQUALITY_OPS.include?(op) ? op : UNSIGNED_COMPARISONS.fetch(op)
          emit(cmp, dst: dst, a: lhs, b: rhs, size: 8)
        else
          common = common_arithmetic_type(lhs_type, rhs_type)
          l = convert(lhs, from: lhs_type, to: common)
          r = convert(rhs, from: rhs_type, to: common)
          cmp = op
          cmp = UNSIGNED_COMPARISONS.fetch(op) if common.unsigned? && !EQUALITY_OPS.include?(op)
          emit(cmp, dst: dst, a: l, b: r, size: (8 if common.size == 8))
        end
        [dst, Type::Int]
      end

      # A shift promotes each operand on its own — never the usual arithmetic
      # conversion — and takes the promoted left operand's type as its result
      # (6.5.7), which #binary_result_type has already computed. "<<" is the
      # logical :shl; ">>" is the arithmetic :sar for a signed left operand and
      # the logical :shr for an unsigned one. The count rides in b (its low byte,
      # read from cl by the backend); a size-8 left operand shifts 64-bit.
      def gen_shift(op, lhs, lhs_type, rhs, result_type)
        value = convert(lhs, from: lhs_type, to: result_type)
        opcode = if op == :shl
                   :shl
                 else
                   result_type.unsigned? ? :shr : :sar
                 end
        dst = new_vreg
        emit(opcode, dst: dst, a: value, b: rhs, size: (8 if result_type.size == 8))
        [dst, result_type]
      end

      # Ordinary integer arithmetic (+ - * / % and the bitwise & | ^). Both
      # operands are converted to their common type (which is the result type),
      # then combined; the additive, multiplicative and bitwise opcodes are
      # shared across signedness (their bit patterns coincide, wrap-around
      # included), while division and remainder pick the signed or unsigned
      # opcode. A common type of 8 bytes runs the operation 64-bit.
      def gen_integer_arithmetic(op, lhs, lhs_type, rhs, rhs_type, result_type)
        l = convert(lhs, from: lhs_type, to: result_type)
        r = convert(rhs, from: rhs_type, to: result_type)
        opcode = case op
                 when :div then result_type.unsigned? ? :udiv : :div
                 when :mod then result_type.unsigned? ? :umod : :mod
                 else op
                 end
        dst = new_vreg
        emit(opcode, dst: dst, a: l, b: r, size: (8 if result_type.size == 8))
        [dst, result_type]
      end

      # pointer +/- int: scale the int index by the element size (as a 64-bit
      # byte offset) and add or subtract it from the pointer. The result has the
      # pointer's type.
      def gen_pointer_int_arith(op, ptr_vreg, int_vreg, int_type, ptr_type)
        offset = scale_index(int_vreg, int_type, ptr_type.target.size)
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

      # Widens an index to a 64-bit byte offset and multiplies it by the element
      # size, yielding the offset used to index a pointer or array. The widening
      # follows the index's own signedness (a signed index sign-extends, so
      # p[-1] addresses the element below the pointer; an unsigned one
      # zero-extends), and an already-64-bit index passes through.
      def scale_index(index_vreg, index_type, element_size)
        wide = convert(index_vreg, from: index_type, to: Type::Long)
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
        unless index_type.integer?
          error_at(node.token, "array subscript is not an integer")
        end
        offset = scale_index(index, index_type, element_type.size)
        addr = new_vreg
        emit(:add, dst: addr, a: base, b: offset, size: 8)
        [addr, element_type]
      end

      def gen_unary(node)
        case node.op
        when :not
          gen_logical_not(node)
        when :neg
          operand, operand_type = gen_value(node.operand)
          unless operand_type.integer?
            error_at(node.token, "wrong type argument to unary minus")
          end
          # Unary minus promotes its operand and negates in the promoted type,
          # so "-x" of a long is long (negated 64-bit) and of a char is int.
          result_type = integer_promote(operand_type)
          value = convert(operand, from: operand_type, to: result_type)
          dst = new_vreg
          emit(:neg, dst: dst, a: value, size: (8 if result_type.size == 8))
          [dst, result_type]
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
        emit(:eq, dst: dst, a: operand, b: zero, size: (8 if wide_scalar?(operand_type)))
        [dst, Type::Int]
      end

      # "&x" yields the address of an lvalue. A variable reference, a subscript
      # "e[i]" or a dereference "*p" is an lvalue here: "&x" is a pointer to x's
      # type, "&a" a pointer to a whole array, "&e[i]" a pointer to the element
      # (its already-computed address) and "&*p" collapses to p itself. "&f" of
      # a function designator is a pointer to the function, the same value the
      # bare name decays to.
      def gen_address_of(node)
        operand = node.operand
        if operand.is_a?(Front::AST::VariableRef)
          local = lookup_variable(operand.name)
          # A bare function name: "&f" is a pointer to the function, identical
          # to the decayed designator "f" (6.3.2.1p4), so reuse it.
          return gen_function_designator(operand.name, operand.token) unless local

          # A struct or array variable already evaluates to its object's base
          # address (a stack object or a global symbol), so "&s"/"&a" reuse that
          # and just retag it as a pointer to the whole object. A scalar's
          # address is its symbol (:global_addr) or the absolute address of its
          # stack slot (:addr_of).
          if local.type.struct? || local.type.array?
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
          # "&s.arr" of an array member is a pointer to the whole array (the
          # member's own address); every other member address retags likewise.
          addr, member_type = gen_member_address(operand)
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
        # "*fp" of a function pointer is a function designator, which decays
        # right back to the same pointer value (its code address), so it is
        # returned unchanged — this is what lets "(*fp)(x)" and "(**fp)(x)"
        # reach the call as an ordinary Pointer(FunctionType).
        return [addr, ptr_type] if result_type.function?
        # "*p" of a pointer-to-array is an array lvalue, which decays to a
        # pointer to its first element (the same address), so "(*p)[i]" and
        # pointer-to-array arithmetic work; nothing is loaded.
        return [addr, Type::Pointer.new(result_type.element)] if result_type.array?

        dst = new_vreg
        emit_scalar_load(dst, addr, result_type)
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
        reject_readonly_write(local, target, node.token)
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
        stored = store_scalar_variable(local, value, value_type)
        [stored, local.type]
      end

      # Reads a scalar variable's current value into a usable vreg. A local
      # scalar comes from its slot (re-derived from the low bytes for a narrow
      # type, see #read_local_scalar); a global is loaded through its address
      # (:global_addr then a width- and sign-appropriate load).
      def load_scalar_variable(local)
        return read_local_scalar(local) unless local.global

        addr = new_vreg
        emit(:global_addr, dst: addr, a: local.storage)
        dst = new_vreg
        emit_scalar_load(dst, addr, local.type)
        dst
      end

      # Writes `value_vreg` (of type `value_type`) into a scalar variable,
      # converting it to the variable's type first (the usual assignment
      # conversion — a narrowing, widening or sign change). A local is a plain
      # :copy into its slot; a global is a :store through its address, the store
      # width following its type. Returns the vreg holding the stored (converted)
      # value, which is the assignment expression's value.
      def store_scalar_variable(local, value_vreg, value_type)
        converted = convert_for_assignment(value_vreg, value_type, local.type)
        if local.global
          addr = new_vreg
          emit(:global_addr, dst: addr, a: local.storage)
          emit(:store, a: addr, b: converted, size: local.type.size)
        else
          emit(:copy, dst: local.storage, a: converted)
        end
        converted
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

      # Lowers a call. A callee that is a bare function name not shadowed by a
      # variable is a direct call to that symbol; any other callee (a function
      # pointer variable, "(*fp)(x)", "s.fp(x)", "table[i](x)") is evaluated to
      # a Pointer(FunctionType) value and called indirectly. Arguments are
      # evaluated left to right, each landing in its own vreg; the result's type
      # is the callee's return type (a void one is only valid when the whole
      # call is an expression-statement, enforced by #gen_value at every other
      # site).
      def gen_call(node)
        callee = node.callee
        # A bare identifier callee that binds no variable is a direct call to a
        # function of that name; an unknown one is an implicit declaration.
        if callee.is_a?(Front::AST::VariableRef) && lookup_variable(callee.name).nil?
          unless @signatures.key?(callee.name)
            error_at(node.token, "implicit declaration of function '#{callee.name}'")
          end
          gen_direct_call(node, callee.name)
        else
          gen_indirect_call(node)
        end
      end

      # A direct call to the named function, its signature already known.
      def gen_direct_call(node, name)
        sig = @signatures[name]
        arg_vregs = lower_call_arguments(node, sig[:param_types], sig[:variadic], name)
        dst = new_vreg
        # A variadic callee carries its fixed parameter count in `size` (non-nil
        # marks the call variadic), which the backend turns into the al=0 the
        # System V ABI wants (no xmm arguments in this subset).
        emit(:call, dst: dst, a: name, b: arg_vregs, size: (sig[:param_types].size if sig[:variadic]))
        [dst, sig[:return_type]]
      end

      # An indirect call through a function-pointer value. The callee is
      # evaluated (a function designator having already decayed to a pointer);
      # its type must be a pointer to a function, whose signature drives the
      # argument checks and supplies the result type. The target address rides
      # in the a-field and the argument vregs in b, exactly like a direct call.
      def gen_indirect_call(node)
        target, callee_type = gen_value(node.callee)
        func_type = called_function_type(callee_type, node.token)
        arg_vregs = lower_call_arguments(node, func_type.param_types, func_type.variadic, nil)
        dst = new_vreg
        # `size` marks a variadic callee for the backend's al=0, exactly as in a
        # direct call; the function pointer's own type supplies the flag.
        emit(:call_indirect, dst: dst, a: target, b: arg_vregs,
                             size: (func_type.param_types.size if func_type.variadic))
        [dst, func_type.return_type]
      end

      # The FunctionType a call's callee names, or a diagnostic when the callee
      # is neither a function nor a pointer to one. A function designator would
      # already have decayed to Pointer(FunctionType), but a bare function type
      # is accepted too for completeness.
      def called_function_type(callee_type, token)
        return callee_type.target if callee_type.pointer? && callee_type.target.function?
        return callee_type if callee_type.function?

        error_at(token, "called object is not a function or function pointer")
      end

      # Evaluates a call's arguments against `param_types` (the fixed, named
      # parameters), checking the count and converting each. A fixed argument
      # (index below the parameter count) is checked against its parameter type
      # and converted like an assignment (an arithmetic widening/narrowing/sign
      # change; a pointer or null pointer constant passes through). When
      # `variadic` is set, any extra arguments past the fixed ones are allowed
      # (only a shortfall below the fixed count is an error, never a surplus) and
      # each takes the default argument promotions (see #promote_variadic_argument)
      # instead of an assignment conversion. `name` names the callee in the
      # diagnostics of a direct call, or is nil for an indirect one.
      def lower_call_arguments(node, param_types, variadic, name)
        callee_desc = name ? "function '#{name}'" : "function pointer"
        fixed = param_types.size
        if node.args.size < fixed
          error_at(node.token, "too few arguments to #{callee_desc}")
        elsif !variadic && node.args.size > fixed
          error_at(node.token, "too many arguments to #{callee_desc}")
        end

        node.args.each_with_index.map do |arg, i|
          vreg, arg_type = gen_value(arg)
          if i < fixed
            unless compatible_assignment?(param_types[i], arg, arg_type)
              suffix = name ? " of '#{name}'" : ""
              error_at(node.token, "incompatible type for argument #{i + 1}#{suffix}")
            end
            convert_for_assignment(vreg, arg_type, param_types[i])
          else
            promote_variadic_argument(vreg, arg_type, node.token)
          end
        end
      end

      # The default argument promotions applied to an argument in a variadic
      # call's variable part (6.5.2.2p6): an integer narrower than int (char,
      # short and their unsigned forms, and _Bool) widens to int, while int,
      # long, their unsigned forms and any pointer pass through unchanged.
      # (A floating type would promote double, but this subset has none.) A
      # struct has no promoted form the callee could recover through va_arg in a
      # register/stack layout this step models, so passing one is rejected.
      def promote_variadic_argument(vreg, arg_type, token)
        if arg_type.struct?
          error_at(token, "passing a struct to a variadic function is not supported yet")
        end
        return vreg unless arg_type.integer?

        convert(vreg, from: arg_type, to: integer_promote(arg_type))
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
        # The result type is settled up front from the arms' static types (the
        # same code-free inference sizeof uses), so each arm's value can be
        # converted to it inside its own branch before the shared result slot is
        # written — needed when the arms differ (e.g. int and long).
        result_type = conditional_result_type(node.then_expr, static_type(node.then_expr),
                                               node.else_expr, static_type(node.else_expr), node.token)
        cond = gen_condition(node.condition)
        else_label = new_label
        end_label = new_label
        result = new_vreg
        emit(:jump_if_zero, a: cond, b: else_label)

        then_value, then_type = gen_value(node.then_expr)
        emit(:copy, dst: result, a: convert_for_assignment(then_value, then_type, result_type))
        emit(:jump, a: end_label)

        emit(:label, a: else_label)
        else_value, else_type = gen_value(node.else_expr)
        emit(:copy, dst: result, a: convert_for_assignment(else_value, else_type, result_type))
        emit(:label, a: end_label)

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
        elsif then_type.integer? && else_type.integer?
          common_arithmetic_type(then_type, else_type)
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
        emit_scalar_load(current, addr, member_type)

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
        reject_readonly_write(local, target, node.token)
        error_at(node.token, "array type is not assignable") if local.type.array?
        error_at(node.token, "invalid operands to binary expression") if local.type.struct?

        value, value_type = gen_value(node.value)
        current = load_scalar_variable(local)
        result, result_type = gen_binary_op(node.op, current, local.type, value, value_type, node.token)
        unless compatible_types?(local.type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        stored = store_scalar_variable(local, result, result_type)
        [stored, local.type]
      end

      def gen_compound_assignment_through_subscript(node, target)
        addr, element_type = gen_element_address(target)
        require_scalar_target(element_type, node.token)
        current = new_vreg
        emit_scalar_load(current, addr, element_type)

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
        emit_scalar_load(current, addr, target_type)

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
        emit_scalar_load(current, addr, member_type)

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
        reject_readonly_write(local, target, node.token)
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
        stored = store_scalar_variable(local, result, result_type)
        node.prefix ? [stored, local.type] : [old_value, local.type]
      end

      def gen_inc_dec_through_subscript(node, target)
        addr, element_type = gen_element_address(target)
        require_scalar_target(element_type, node.token)
        current = new_vreg
        emit_scalar_load(current, addr, element_type)

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
        emit_scalar_load(current, addr, target_type)

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
        return true if expected.integer? && actual.integer?
        # Any scalar converts to _Bool (the "!= 0" rule), pointers included.
        return true if expected.bool? && actual.pointer?
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

      # Integer promotion (6.3.1.1): a type whose rank is below int (char, short
      # and their unsigned forms, and _Bool) promotes to int, which holds every
      # one of their values; int, unsigned int, long and unsigned long are
      # unchanged. Only an integer type is promoted; anything else passes
      # through.
      def integer_promote(type)
        return type unless type.integer?

        type.size < 4 ? Type::Int : type
      end

      # The common type of two arithmetic operands (6.3.1.8), after each has
      # been integer-promoted. Same signedness picks the wider rank; mixed
      # signedness gives the unsigned type when its rank is at least the signed
      # type's, otherwise the signed type — which under LP64 always represents
      # every value of a strictly narrower unsigned type (e.g. long covers
      # unsigned int, so "long + unsigned int" is long).
      def common_arithmetic_type(lhs_type, rhs_type)
        a = integer_promote(lhs_type)
        b = integer_promote(rhs_type)
        return a if a == b
        return (a.size >= b.size ? a : b) if a.signed? == b.signed?

        unsigned, signed = a.unsigned? ? [a, b] : [b, a]
        unsigned.size >= signed.size ? unsigned : signed
      end

      # Converts `vreg` (a value of integer type `from`) to integer type `to`,
      # emitting the width/sign change the value representation calls for and
      # returning the vreg holding the result. A conversion to _Bool is the
      # truth test "value != 0". Widening to 8 bytes extends by the *source*
      # signedness (preserving the numeric value); a 1/2-byte destination
      # re-derives its low bytes by the *destination* signedness; a 4-byte
      # destination, and same-bit-pattern reinterpretations (int <-> unsigned
      # int, long <-> unsigned long), need no code at all.
      def convert(vreg, from:, to:)
        return vreg if from == to
        return to_bool(vreg, from) if to.bool?

        if to.size == 8
          return vreg if from.size == 8 # long <-> unsigned long: same 64 bits

          dst = new_vreg
          emit(from.signed? ? :sext : :zext, dst: dst, a: vreg, size: 4)
          dst
        elsif to.size == 4
          vreg # the low 32 bits already hold the converted value
        else # to.size 1 or 2
          dst = new_vreg
          emit(to.signed? ? :sext : :zext, dst: dst, a: vreg, size: to.size)
          dst
        end
      end

      # The implicit conversion an assignment context (=, initialization, an
      # argument, a return, a "?:" arm) applies to a value of type `from_type`
      # bound to a `to_type` target. An arithmetic-to-arithmetic conversion goes
      # through #convert; a conversion of any scalar to _Bool is "value != 0";
      # a pointer (or null pointer constant, already full-width) otherwise
      # passes through unchanged.
      def convert_for_assignment(value_vreg, from_type, to_type)
        if to_type.bool? && (from_type.integer? || from_type.pointer?)
          return to_bool(value_vreg, from_type)
        end
        return value_vreg unless to_type.integer? && from_type.integer?

        convert(value_vreg, from: from_type, to: to_type)
      end

      # "value != 0", the conversion of a scalar to _Bool: a nonzero source
      # becomes 1, zero becomes 0. A pointer or 8-byte integer source compares
      # at 64 bits so its whole value decides. The int 0/1 result is already a
      # valid _Bool representation.
      def to_bool(value_vreg, from_type)
        zero = new_vreg
        emit(:const, dst: zero, a: 0)
        dst = new_vreg
        emit(:ne, dst: dst, a: value_vreg, b: zero, size: (8 if wide_scalar?(from_type)))
        dst
      end

      # Whether a scalar's truth/zero test must run 64-bit: a pointer or an
      # 8-byte integer, whose high half would otherwise be ignored by a 32-bit
      # test.
      def wide_scalar?(type)
        type.pointer? || (type.integer? && type.size == 8)
      end

      # Reads a non-global scalar local's value into a usable vreg. A 1/2-byte
      # integer is re-derived from the slot's low bytes by its signedness
      # (:sext / :zext), guarding against a stale upper half after an aliased
      # pointer write through "&x" (the trap first seen for char in Step 11,
      # now general to every narrow type); a wider local's slot already holds a
      # usable value, so its slot vreg is returned directly.
      def read_local_scalar(local)
        type = local.type
        return local.storage unless type.integer? && (type.size == 1 || type.size == 2)

        dst = new_vreg
        emit(type.signed? ? :sext : :zext, dst: dst, a: local.storage, size: type.size)
        dst
      end

      # Emits a scalar load through `addr`, choosing the zero-extending :uload
      # for an unsigned narrow type (and _Bool) and the sign-extending :load
      # otherwise; the two coincide at width 4 and 8.
      def emit_scalar_load(dst, addr, type)
        op = type.integer? && type.unsigned? ? :uload : :load
        emit(op, dst: dst, a: addr, size: type.size)
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
        # A 4-byte-or-narrower integer's low 32 bits already hold its value, so
        # the 32-bit :jump_if_zero test reads it directly. A pointer or an
        # 8-byte integer must be tested at 64 bits so its whole value decides,
        # so it is desugared to "value != 0" (an int 0/1) up front.
        return value if type.integer? && type.size <= 4

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
      # rides in cl and each operand promotes on its own), so #gen_binary_op
      # handles them apart from the ordinary arithmetic ops.
      SHIFT_OPS = %i[shl shr].freeze

      # The relational operators' unsigned counterparts, chosen when the common
      # operand type is unsigned (and always for pointer ordering). Equality
      # (:eq/:ne) is sign-independent and so absent here.
      UNSIGNED_COMPARISONS = { lt: :ult, le: :ule, gt: :ugt, ge: :uge }.freeze

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
      # Integer operands mix per the usual arithmetic conversions
      # (#common_arithmetic_type), except a shift, whose result is its promoted
      # left operand's type alone (6.5.7). Shared by the lowering path
      # (#gen_binary) and the code-free type inference used by sizeof
      # (#static_type):
      #   * comparisons: integer/integer, or pointer/pointer per
      #     #pointer_comparable? -> int;
      #   * shifts "<<" ">>": integer/integer -> the promoted left type;
      #   * "+": integer/integer -> their common type, and pointer/integer or
      #     integer/pointer -> that (non-void) pointer;
      #   * "-": integer/integer -> their common type, pointer/integer -> that
      #     (non-void) pointer, and same-type (non-void) pointer/pointer -> int;
      #   * "*" "/" "%", the bitwise "&" "|" "^": integer/integer -> their
      #     common type only (any pointer operand is invalid), which is the
      #     fall-through "else" case below.
      def binary_result_type(op, lhs_type, rhs_type, token)
        result =
          if comparison_op?(op)
            if lhs_type.integer? && rhs_type.integer? then Type::Int
            elsif lhs_type.pointer? && rhs_type.pointer? && pointer_comparable?(op, lhs_type, rhs_type) then Type::Int
            end
          elsif SHIFT_OPS.include?(op)
            integer_promote(lhs_type) if lhs_type.integer? && rhs_type.integer?
          else
            case op
            when :add
              if lhs_type.integer? && rhs_type.integer? then common_arithmetic_type(lhs_type, rhs_type)
              elsif lhs_type.pointer? && rhs_type.integer? then require_non_void_pointer(lhs_type, token)
              elsif lhs_type.integer? && rhs_type.pointer? then require_non_void_pointer(rhs_type, token)
              end
            when :sub
              if lhs_type.integer? && rhs_type.integer? then common_arithmetic_type(lhs_type, rhs_type)
              elsif lhs_type.pointer? && rhs_type.integer? then require_non_void_pointer(lhs_type, token)
              elsif lhs_type.pointer? && rhs_type.pointer? && lhs_type == rhs_type
                require_non_void_pointer(lhs_type, token)
                Type::Int
              end
            else # :mul, :div, :mod, :and, :or, :xor
              common_arithmetic_type(lhs_type, rhs_type) if lhs_type.integer? && rhs_type.integer?
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
          local = lookup_variable(node.name)
          # A bare function name under sizeof keeps its function type, which
          # gen_sizeof then rejects ("sizeof f" has no size); a variable keeps
          # its declared type with no array-to-pointer decay.
          return local.type if local

          sig = @signatures[node.name] ||
                error_at(node.token, "undeclared variable '#{node.name}'")
          function_type_of(sig)
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
        when Front::AST::IntLit
          node.type
        when Front::AST::SizeofExpr, Front::AST::SizeofType, Front::AST::AlignofType
          Type::ULong
        when Front::AST::Call
          call_return_type(node)
        when Front::AST::StringLit
          Type::Pointer.new(Type::Char)
        when Front::AST::VariableRef
          local = lookup_variable(node.name)
          if local
            local.type.array? ? Type::Pointer.new(local.type.element) : local.type
          else
            sig = @signatures[node.name] ||
                  error_at(node.token, "undeclared variable '#{node.name}'")
            Type::Pointer.new(function_type_of(sig))
          end
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

      # A call's rvalue type without emitting code: the callee's return type,
      # resolved the same way #gen_call splits a direct call from an indirect
      # one.
      def call_return_type(node)
        callee = node.callee
        if callee.is_a?(Front::AST::VariableRef) && lookup_variable(callee.name).nil?
          sig = @signatures[callee.name]
          error_at(node.token, "implicit declaration of function '#{callee.name}'") unless sig
          sig[:return_type]
        else
          called_function_type(static_type(callee), node.token).return_type
        end
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
        when :not
          Type::Int
        when :neg
          integer_promote(static_type(node.operand))
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
          local = lookup_variable(operand.name)
          # "&f" of a function name is a pointer to the function, like the
          # decayed designator itself; "&a" is a pointer to the whole array.
          return static_type(operand) unless local

          Type::Pointer.new(local.type)
        elsif operand.is_a?(Front::AST::Subscript)
          Type::Pointer.new(subscript_element_type(static_type(operand.target), operand.token))
        elsif operand.is_a?(Front::AST::MemberAccess)
          Type::Pointer.new(static_member(operand).type)
        elsif operand.is_a?(Front::AST::Unary) && operand.op == :deref
          type = static_type(operand.operand)
          require_pointer(type, operand.token)
          type
        else
          error_at(node.token, "lvalue required as unary '&' operand")
        end
      end

      # Resolves a variable by walking scopes from innermost to outermost, so
      # an inner declaration shadows an outer one with the same name. Returns
      # nil when no variable binds the name — the caller decides whether the
      # name might instead be a function designator or is simply undeclared.
      def lookup_variable(name)
        @scopes.reverse_each do |scope|
          local = scope[name]
          return local if local
        end
        nil
      end

      # Like #lookup_variable but for the contexts that require an object (an
      # assignment target, a "++"/"--"): a name that binds no variable is
      # undeclared here (a function name never reaches these, the parser having
      # made it a call or a decayed pointer instead).
      def lookup_local(name, token)
        lookup_variable(name) || error_at(token, "undeclared variable '#{name}'")
      end

      # Rejects a write to a top-level const-qualified variable or parameter — a
      # plain assignment, a compound assignment or "++"/"--". Only the variable's
      # own const-ness is tracked (M1 carries no qualified types), so a write
      # through a pointer, a subscript or a struct member is not caught here.
      def reject_readonly_write(local, target, token)
        return unless local.const

        error_at(token, "assignment of read-only variable '#{target.name}'")
      end

      # The Type::FunctionType a function's recorded signature describes, used
      # both to build the pointer a function designator decays to and to check
      # an indirect call or a function-pointer assignment against it.
      def function_type_of(sig)
        Type::FunctionType.new(sig[:return_type], sig[:param_types], sig[:variadic])
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
