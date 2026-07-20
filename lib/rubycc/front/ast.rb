# frozen_string_literal: true

module Rubycc
  module Front
    # Abstract syntax tree nodes for the C subset. Each node carries a
    # representative token (`token`) for source-location diagnostics.
    module AST
      # Integer literal. `value` is a Ruby Integer and `type` its Rubycc::Type,
      # fixed by the parser from the constant's base, suffix and magnitude
      # (6.4.4.1) — int/long or their unsigned forms; a character constant is
      # int.
      IntLit = Data.define(:value, :token, :type)

      # Floating-point literal. `value` is a Ruby Float and `type` its
      # Rubycc::Type — Type::Float for an f/F-suffixed constant, Type::Double
      # otherwise (a plain or l/L-suffixed one) — fixed by the parser from the
      # constant's suffix (6.4.4.2).
      FloatLit = Data.define(:value, :type, :token)

      # String literal. `value` is the escape-resolved bytes as an ASCII-8BIT
      # String, without the NUL terminator. Its type is char[N+1] (N being the
      # byte count); in every expression context except sizeof it decays to a
      # char * pointing at the string's first byte in .rodata.
      StringLit = Data.define(:value, :token)

      # Unary operation. `op` is :neg or :not (unary + is folded away by the
      # parser), :addr (the address-of "&") or :deref (the dereference "*").
      Unary = Data.define(:op, :operand, :token)

      # Binary operation. `op` is one of :add, :sub, :mul, :div, :mod
      # (arithmetic), :and, :or, :xor (bitwise), :shl, :shr (shifts) or
      # :eq, :ne, :lt, :le, :gt, :ge (comparisons yielding int 0/1). The unary
      # bitwise-not "~x" has no op of its own: the parser desugars it to the
      # Binary "x ^ -1", so it reaches the generator as an ordinary :xor.
      Binary = Data.define(:op, :lhs, :rhs, :token)

      # The comma operator "left, right" (ISO C 6.5.17): `left` is evaluated
      # for its side effects and its value discarded, then `right` is evaluated
      # and its value and type become the whole expression's. Only a context
      # that admits a full expression (a parenthesized expression, a subscript,
      # an expression-statement, the three for-clauses, a control condition, a
      # return, the middle of "?:") ever builds one; a comma that merely
      # separates items (call arguments, declarators) is not this node.
      Comma = Data.define(:left, :right, :token)

      # Short-circuit "&&" and "||". Kept apart from Binary because both
      # operands must be int-typed and only one side may end up evaluated at
      # run time, unlike every other Binary operator.
      LogicalAnd = Data.define(:lhs, :rhs, :token)
      LogicalOr = Data.define(:lhs, :rhs, :token)

      # The conditional operator "condition ? then_expr : else_expr".
      # `condition` must be int-typed; `then_expr` and `else_expr` must share
      # the same type (int/int or same-type pointer/pointer).
      Conditional = Data.define(:condition, :then_expr, :else_expr, :token)

      # Compound assignment "target op= value". `op` is one of :add, :sub,
      # :mul, :div, :mod (the operator without its trailing "="). `target` is
      # a VariableRef, a Subscript or a dereference (Unary with op :deref); the
      # parser rejects any other, non-assignable target.
      CompoundAssignment = Data.define(:op, :target, :value, :token)

      # Prefix or postfix "++"/"--". `op` is :add for "++" and :sub for "--".
      # `prefix` is true for "++x"/"--x" and false for "x++"/"x--". `target`
      # is a VariableRef, a Subscript or a dereference, exactly like
      # CompoundAssignment.
      IncDec = Data.define(:op, :target, :prefix, :token)

      # `return <expr>;`, or `return;` with `expr` nil (a void return).
      Return = Data.define(:expr, :token)

      # A local variable declaration. `type` is the declared Rubycc::Type
      # (int or a pointer). `initializer` is an expression node or nil when the
      # declarator has no "= <expr>" part. `const` is true when the object is
      # top-level const-qualified (the only qualification M1 tracks), which the
      # generator rejects writes against. `storage` records the storage-class
      # specifier (nil, :static or :extern) for Phase B; the generator does not
      # consume it yet.
      VariableDecl = Data.define(:name, :type, :initializer, :token, :const, :storage)

      # A file-scope (global) variable declaration. `type` is the declared
      # Rubycc::Type (int, char, a pointer, a one-dimensional array or a
      # struct/union). At most one of two initializer fields is set:
      # `initializer_value` is a plain scalar-integer initializer folded to a
      # Ruby Integer on the spot (the common "int g = 1 + 2;" case, kept folded
      # so nothing downstream re-evaluates it), while `initializer_node` carries
      # a still-unfolded initializer the generator lowers itself — a brace
      # initializer-list (AST::InitializerList) for an aggregate or scalar, a
      # string literal for a char array, or an address constant for a pointer
      # (a null pointer, "&other_global", a decayed global array name or a
      # string literal). Both are nil for an uninitialized global, which lands
      # in .bss. `const` and `storage` carry the same top-level const flag and
      # storage-class specifier (nil/:static/:extern) as VariableDecl; the
      # generator diagnoses writes against a const global but does not yet act
      # on the storage class (Phase B).
      GlobalDecl = Data.define(:name, :type, :initializer_value, :initializer_node, :token, :const, :storage)

      # A brace-enclosed initializer "{ ... }" (ISO C 6.7.9). `items` is the
      # ordered list of InitItem, one per comma-separated element (a trailing
      # comma adds none). Appears as a VariableDecl/GlobalDecl initializer, or
      # nested as an InitItem's value; the resolver walks it against the
      # object's type to place each scalar. `token` is the opening brace.
      InitializerList = Data.define(:items, :token)

      # One element of an initializer-list. `designators` is the (possibly
      # empty) leading designator chain — ArrayDesignator / MemberDesignator
      # nodes, so ".a.b = x" and "[1].m = y" carry two — that redirects the
      # current object before `value` initializes it; `value` is either an
      # expression node or a nested InitializerList.
      InitItem = Data.define(:designators, :value)

      # An array designator "[constant-expression]" (6.7.9). `index` is the
      # bracketed constant folded to a Ruby Integer at parse time; `token` is
      # the "[" for diagnostics (an out-of-range index).
      ArrayDesignator = Data.define(:index, :token)

      # A member designator ".identifier" (6.7.9). `name` is the member's name;
      # `token` is the "." for diagnostics (an unknown member).
      MemberDesignator = Data.define(:name, :token)

      # A reference to a local variable by name.
      VariableRef = Data.define(:name, :token)

      # A subscript `target[index]` (postfix "[" expression "]"). Both `target`
      # and `index` are expression nodes; the generator lowers it as
      # "*(target + index)" and type-checks that `target` is an array/pointer.
      Subscript = Data.define(:target, :index, :token)

      # A struct member access. `base` is the postfix-expression on the left,
      # `member` the identifier String on the right and `arrow` false for the
      # "." form (base is the struct itself) or true for the "->" form (base is
      # a pointer to the struct, so "p->m" means "(*p).m"). Both forms are
      # lvalues: the generator lowers either to the base struct's address plus
      # the member's constant offset, then reads or writes through it.
      MemberAccess = Data.define(:base, :member, :arrow, :token)

      # `sizeof operand`: the byte size of a unary-expression's result type.
      # `operand` is an expression node; the array-to-pointer decay does not
      # apply to it, so `sizeof a` measures the whole array.
      SizeofExpr = Data.define(:operand, :token)

      # `sizeof ( type-name )`: the byte size of a written type ("int",
      # "int *", ...). `type` is the resolved Rubycc::Type.
      SizeofType = Data.define(:type, :token)

      # `_Alignof ( type-name )` (ISO C 6.5.3.4): the alignment requirement, in
      # bytes, of a written type. `type` is the resolved Rubycc::Type. Only the
      # parenthesized type-name form exists; unlike sizeof there is no operand
      # form. The result folds to a size_t (unsigned long) constant, exactly
      # like SizeofType, and is rejected for a void, function or incomplete type.
      AlignofType = Data.define(:type, :token)

      # A cast "( type-name ) operand" (ISO C 6.5.4). `type` is the resolved
      # Rubycc::Type the operand is converted to and `operand` is the
      # cast-expression to its right. The generator settles which conversions
      # are legal (arithmetic reinterpretation, a pointer retag, discarding a
      # value with "(void)", a null-pointer-constant cast) and emits any code a
      # narrowing needs; the parser only builds the node.
      Cast = Data.define(:type, :operand, :token)

      # A compound literal "( type-name ) { initializer-list }" (ISO C 6.5.2.5).
      # `type` is the resolved Rubycc::Type of the unnamed object the literal
      # denotes, with any inferred "[]" array bound already completed by the
      # parser (so "(int[]){1,2,3}" carries int[3]); `initializer` is the
      # AST::InitializerList that fills it. In block scope the object has
      # automatic storage lasting the enclosing block, so the literal is an
      # lvalue: the generator lays it out on a stack object, initializes it, and
      # yields the object's value the same way a variable of `type` would (a
      # struct/union as its base address, an array decayed to an element pointer,
      # a scalar as a load) — which is what lets "&(T){...}", "(T){...}.member",
      # a by-value argument and an assignment right-hand side all work. A
      # compound literal in a static-storage-duration (file-scope) initializer is
      # diagnosed as unsupported by the generator. `token` is the opening "(".
      CompoundLiteral = Data.define(:type, :initializer, :token)

      # A null pointer constant, as this subset defines it: an integer literal
      # whose value is 0, which also covers a character constant like '\0'
      # (the lexer already lowers it to an integer 0). ISO C additionally admits
      # any integer constant expression evaluating to 0, and such an expression
      # cast to void *, but general constant-expression evaluation arrives in a
      # later step, so matching the literal form is enough here. A null pointer
      # constant converts implicitly to any pointer type in an assignment, an
      # initializer, an argument, a return, an "=="/"!=" comparison and the arms
      # of "?:".
      def self.null_pointer_constant?(node)
        node.is_a?(IntLit) && node.value.zero?
      end

      # Simple assignment `target = value`. `target` is a VariableRef or a
      # dereference (Unary with op :deref); the parser rejects any other,
      # non-assignable target.
      Assignment = Data.define(:target, :value, :token)

      # An expression evaluated for its side effects; the value is discarded.
      ExpressionStmt = Data.define(:expr, :token)

      # The empty statement ";".
      EmptyStmt = Data.define(:token)

      # A GNU inline-assembly statement in its only accepted (degenerate) form
      # (DESIGN R7): `__asm__` with optional volatile qualifiers and an empty
      # template, e.g. `__asm__ volatile("" ::: "memory");`. The parser has
      # already verified the template is empty and no real operand appears, so
      # nothing is carried but the keyword token; it lowers to no code at all —
      # rubycc never reorders, so a memory-clobber barrier is a natural no-op.
      InlineAsm = Data.define(:token)

      # `if (condition) then_stmt` with an optional `else else_stmt`.
      # `else_stmt` is nil when there is no else clause.
      If = Data.define(:condition, :then_stmt, :else_stmt, :token)

      # A compound-statement "{ block-item* }" introducing a new scope.
      # `items` is a flat array of declaration/statement nodes.
      Block = Data.define(:items, :token)

      # A GNU statement expression "( { block-item* } )" (a GCC extension, not
      # ISO C). `body` is the AST::Block the parentheses wrap around a compound
      # statement; the braces introduce the block's own scope, just like any
      # compound-statement. When the block's last block-item is an
      # expression-statement, that expression's value and type are the whole
      # construct's; otherwise (an empty block, or a last item that is a
      # declaration, a loop, a bare ";" and so on) the construct is void.
      StatementExpr = Data.define(:body, :token)

      # `while (condition) body`
      While = Data.define(:condition, :body, :token)

      # `do body while (condition);`
      DoWhile = Data.define(:body, :condition, :token)

      # `for (init; condition; step) body`. `init` is an array of
      # VariableDecl (from a declaration clause), an expression node (from an
      # expression clause) or nil (clause omitted). `condition` and `step`
      # are expression nodes or nil when omitted.
      For = Data.define(:init, :condition, :step, :body, :token)

      # `break;` — targets the innermost enclosing iteration-statement or,
      # once switch exists, the innermost enclosing switch.
      Break = Data.define(:token)

      # `continue;` — targets the innermost enclosing iteration-statement,
      # passing straight through any switch that sits between it and the loop.
      Continue = Data.define(:token)

      # `switch (control) body` (ISO C 6.8.4.2). `control` is the controlling
      # expression (an integer type). `body` is a single statement — usually a
      # compound-statement — inside which `case`/`default` labels mark the entry
      # points the generator lowers to a comparison chain. A case label may sit
      # at any depth of a nested statement in `body`; the ones that belong to
      # this switch are exactly those not enclosed by a nested switch.
      Switch = Data.define(:control, :body, :token)

      # A `case <constant>: statement` label (6.8.1). `value` is the case
      # constant folded to a Ruby Integer at parse time (an integer or character
      # constant, optionally signed — general constant-expression evaluation
      # arrives in a later step). `body` is the labeled statement. A Case only
      # has meaning inside a switch; the generator diagnoses one that is not.
      Case = Data.define(:value, :body, :token)

      # A `default: statement` label (6.8.1). `body` is the labeled statement.
      # Like Case it is only meaningful inside a switch, and at most one may
      # appear per switch.
      Default = Data.define(:body, :token)

      # A `goto identifier;` jump (6.8.6.1). `label` is the target label's name.
      # The target may be defined anywhere in the same function, before or after
      # the goto; the generator resolves the name against a function-scoped label
      # table and diagnoses a jump to an undefined label at the function's end.
      Goto = Data.define(:label, :token)

      # A labeled statement `identifier: statement` (6.8.1), the target of a
      # goto. `name` is the label's name and `body` the statement it prefixes
      # (often the empty statement, as in "end: ;"). Distinguished from an
      # ordinary expression-statement by two tokens of lookahead — an identifier
      # immediately followed by ":".
      Label = Data.define(:name, :body, :token)

      # A function call "callee ( args )" (ISO C 6.5.2.2). `callee` is the
      # postfix-expression being called — an ordinary identifier for a direct
      # call ("f(x)"), but equally a dereference ("(*fp)(x)"), a subscript
      # ("table[i](x)"), a member access ("s.fp(x)") or any expression that
      # yields a function or a function pointer. `args` is an array of
      # expression nodes (the argument-expression-list), evaluated left to
      # right. The generator settles whether the callee is a direct function
      # designator (a plain :call) or a pointer value (an indirect call).
      Call = Data.define(:callee, :args, :token)

      # "__builtin_va_start ( ap , last )" (the initializer of a variable
      # argument list). `ap` is the va_list expression to initialize; `last_name`
      # is the identifier String naming the function's last fixed parameter,
      # which ISO C requires so the variable part can be located just past it.
      # `token` is the builtin keyword, locating every diagnostic (a fixed-arity
      # enclosing function, a wrong last-parameter name, a bad `ap` type). The
      # expression's value is void — it is only ever an expression-statement.
      VaStart = Data.define(:ap, :last_name, :token)

      # "__builtin_va_arg ( ap , type-name )": fetches the next variable argument
      # and advances `ap`. `ap` is the va_list expression and `type` is the
      # resolved Rubycc::Type the argument is read as (an int/long/unsigned/
      # pointer object type; a promotable or aggregate type is diagnosed). The
      # whole expression's value and type are that argument.
      VaArg = Data.define(:ap, :type, :token)

      # "__builtin_va_end ( ap )": ends traversal of `ap`. On System V this is a
      # no-op beyond type-checking the operand, so the node carries only the
      # va_list expression and the keyword token; its value is void.
      VaEnd = Data.define(:ap, :token)

      # "__builtin_va_copy ( dest , src )": copies the traversal state of `src`
      # into `dest` so the two can be walked independently (7.16.1.2). Both are
      # va_list expressions; the generator lowers the copy to a whole-tag move
      # between their (decayed) addresses. The value is void, like va_end.
      VaCopy = Data.define(:dest, :src, :token)

      # "__builtin_expect ( exp , c )": gcc's branch-prediction hint, typed
      # `long(long, long)`. `exp` is the tested expression and `c` the value it
      # is expected to take. rubycc has no optimizer, so the hint carries no
      # weight: both operands are evaluated (left to right, `c` for its side
      # effects) and the whole expression is `exp` converted to `long`. `token`
      # is the builtin keyword.
      BuiltinExpect = Data.define(:exp, :c, :token)

      # "__builtin_alloca ( n )": reserves `n` bytes of automatic storage on the
      # stack, released when the enclosing *function* returns. `size` is the
      # byte-count expression (converted to size_t) and `token` the keyword; the
      # whole expression's value is the block's base address, a `void *` the ABI
      # keeps 16-byte aligned.
      BuiltinAlloca = Data.define(:size, :token)

      # "__builtin_offsetof ( type-name , member-designator )": the byte offset of
      # a member within a struct/union, folded to a size_t constant. Unlike the
      # traditional "((size_t)&(((t*)0)->m))" macro, it is a genuine
      # constant-expression, so it holds in a static initializer, an array bound
      # or a case label — the reason gcc/clang provide it. `type` is the resolved
      # aggregate type; `designator` is the parsed member-designator, a non-empty
      # array whose first element is always an OffsetofMember (the leading member
      # name carries no "."). Each element is either an OffsetofMember (".name",
      # or the leading bare name) or an OffsetofIndex ("[ constant-expression ]"),
      # so a nested field ("a.b[2].c") reaches its target one element at a time.
      # `token` is the builtin keyword, locating every diagnostic.
      BuiltinOffsetof = Data.define(:type, :designator, :token)

      # One member step of a __builtin_offsetof designator: the member named
      # `name` of the aggregate reached so far. `token` is the member identifier,
      # for a "no member named ..." diagnostic.
      OffsetofMember = Data.define(:name, :token)

      # One subscript step of a __builtin_offsetof designator: element `index`
      # (a constant-expression node) of the array reached so far. `token` is the
      # "[" token, for a "subscript of non-array" diagnostic.
      OffsetofIndex = Data.define(:index, :token)

      # "__builtin_constant_p ( expr )": gcc's compile-time-constant test, typed
      # int. `expr` is the (unevaluated) operand and `token` the builtin keyword.
      # The whole expression folds to 1 when `expr` reduces to a compile-time
      # constant and 0 otherwise — including when it references a variable or a
      # function call, which is not an error here (unlike an ordinary constant
      # expression) but simply yields 0. `expr` is never evaluated, so it
      # produces no code and no side effects.
      BuiltinConstantP = Data.define(:expr, :token)

      # "__builtin_ctz/ctzll/clz/clzll ( x )": counts the trailing (ctz) or
      # leading (clz) zero bits of an integer, typed int. `operand` is the value
      # scanned, `direction` is :forward for ctz or :reverse for clz, and `width`
      # is the operand's byte width (4 for the plain form, 8 for the "ll" form).
      # `x == 0` is undefined behavior (gcc), so no zero handling is implied.
      # `token` is the builtin keyword.
      BuiltinBitScan = Data.define(:operand, :direction, :width, :token)

      # "__builtin_unreachable ()": marks a point control never reaches, typed
      # void. rubycc performs no optimization, so it lowers to no code at all —
      # its only role is to let constructs like CRuby's UNREACHABLE_RETURN
      # ("(__builtin_unreachable(), value)") compile. `token` is the keyword.
      BuiltinUnreachable = Data.define(:token)

      # A single function parameter. `name` is the identifier String, or nil
      # for an unnamed parameter in a prototype (e.g. "int f(int, int);").
      # `type` is the parameter's Rubycc::Type (int, char or a pointer; never
      # void, except as a pointer's target). `const` is true when the parameter
      # object is top-level const-qualified ("int f(const int x)"), computed
      # after the array/function-to-pointer adjustment, so the generator can
      # reject writes to it.
      Parameter = Data.define(:name, :type, :token, :const)

      # A function prototype (a bare declaration with no body), e.g.
      # "int f(int a, int b);". `return_type` is the declared Rubycc::Type
      # (int, char, void or a pointer). `params` is an array of Parameter.
      # `storage` records the storage-class specifier (nil/:static/:extern) for
      # Phase B; `inline` is accepted and folded away by the parser and left off
      # here since the generator has no use for it yet. `variadic` is true when
      # the prototype ends in "..." ("int printf(const char *, ...);"), in which
      # case `params` holds only the fixed, named parameters.
      FunctionDecl = Data.define(:name, :return_type, :params, :token, :storage, :variadic)

      # A function definition. `return_type` is the declared Rubycc::Type
      # (int, char, void or a pointer). `params` is an array of Parameter
      # (each with a non-nil name) and `body` is an array of statement nodes.
      # `storage` records the storage-class specifier (nil/:static/:extern) for
      # Phase B, the generator not yet acting on it. `variadic` is true when the
      # parameter list ends in "..." (the variable part is reachable only through
      # va_* in Phase B; a body that ignores it compiles and runs already).
      FunctionDef = Data.define(:name, :return_type, :params, :body, :token, :storage, :variadic)

      # Whole translation unit. `functions` is an array of FunctionDef,
      # FunctionDecl (prototype) and GlobalDecl (file-scope variable) nodes in
      # source order.
      Program = Data.define(:functions)
    end
  end
end
