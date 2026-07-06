# frozen_string_literal: true

module Rubycc
  module Front
    # Abstract syntax tree nodes for the C subset. Each node carries a
    # representative token (`token`) for source-location diagnostics.
    module AST
      # Integer literal. `value` is a Ruby Integer.
      IntLit = Data.define(:value, :token)

      # String literal. `value` is the escape-resolved bytes as an ASCII-8BIT
      # String, without the NUL terminator. Its type is char[N+1] (N being the
      # byte count); in every expression context except sizeof it decays to a
      # char * pointing at the string's first byte in .rodata.
      StringLit = Data.define(:value, :token)

      # Unary operation. `op` is :neg or :not (unary + is folded away by the
      # parser), :addr (the address-of "&") or :deref (the dereference "*").
      Unary = Data.define(:op, :operand, :token)

      # Binary operation. `op` is one of :add, :sub, :mul, :div, :mod (arithmetic)
      # or :eq, :ne, :lt, :le, :gt, :ge (comparisons yielding int 0/1).
      Binary = Data.define(:op, :lhs, :rhs, :token)

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

      # `return <expr>;`
      Return = Data.define(:expr, :token)

      # A local variable declaration. `type` is the declared Rubycc::Type
      # (int or a pointer). `initializer` is an expression node or nil when the
      # declarator has no "= <expr>" part.
      VariableDecl = Data.define(:name, :type, :initializer, :token)

      # A file-scope (global) variable declaration. `type` is the declared
      # Rubycc::Type (int, char, a pointer or a one-dimensional array).
      # `initializer_value` is the initializer folded to a Ruby Integer (an
      # integer/character constant, optionally negated) or nil when the
      # declarator has no "= <constant>" part, since a global may only be
      # initialized by a constant expression the parser evaluates on the spot.
      GlobalDecl = Data.define(:name, :type, :initializer_value, :token)

      # A reference to a local variable by name.
      VariableRef = Data.define(:name, :token)

      # A subscript `target[index]` (postfix "[" expression "]"). Both `target`
      # and `index` are expression nodes; the generator lowers it as
      # "*(target + index)" and type-checks that `target` is an array/pointer.
      Subscript = Data.define(:target, :index, :token)

      # `sizeof operand`: the byte size of a unary-expression's result type.
      # `operand` is an expression node; the array-to-pointer decay does not
      # apply to it, so `sizeof a` measures the whole array.
      SizeofExpr = Data.define(:operand, :token)

      # `sizeof ( type-name )`: the byte size of a written type ("int",
      # "int *", ...). `type` is the resolved Rubycc::Type.
      SizeofType = Data.define(:type, :token)

      # Simple assignment `target = value`. `target` is a VariableRef or a
      # dereference (Unary with op :deref); the parser rejects any other,
      # non-assignable target.
      Assignment = Data.define(:target, :value, :token)

      # An expression evaluated for its side effects; the value is discarded.
      ExpressionStmt = Data.define(:expr, :token)

      # The empty statement ";".
      EmptyStmt = Data.define(:token)

      # `if (condition) then_stmt` with an optional `else else_stmt`.
      # `else_stmt` is nil when there is no else clause.
      If = Data.define(:condition, :then_stmt, :else_stmt, :token)

      # A compound-statement "{ block-item* }" introducing a new scope.
      # `items` is a flat array of declaration/statement nodes.
      Block = Data.define(:items, :token)

      # `while (condition) body`
      While = Data.define(:condition, :body, :token)

      # `do body while (condition);`
      DoWhile = Data.define(:body, :condition, :token)

      # `for (init; condition; step) body`. `init` is an array of
      # VariableDecl (from a declaration clause), an expression node (from an
      # expression clause) or nil (clause omitted). `condition` and `step`
      # are expression nodes or nil when omitted.
      For = Data.define(:init, :condition, :step, :body, :token)

      # `break;` — targets the innermost enclosing iteration-statement.
      Break = Data.define(:token)

      # `continue;` — targets the innermost enclosing iteration-statement.
      Continue = Data.define(:token)

      # A call to a named function. `args` is an array of expression nodes
      # (the argument-expression-list), evaluated left to right.
      Call = Data.define(:name, :args, :token)

      # A single function parameter. `name` is the identifier String, or nil
      # for an unnamed parameter in a prototype (e.g. "int f(int, int);").
      # `type` is the parameter's Rubycc::Type (int or a pointer).
      Parameter = Data.define(:name, :type, :token)

      # A function prototype (a bare declaration with no body), e.g.
      # "int f(int a, int b);". `params` is an array of Parameter.
      FunctionDecl = Data.define(:name, :params, :token)

      # A function definition. `params` is an array of Parameter (each with a
      # non-nil name) and `body` is an array of statement nodes.
      FunctionDef = Data.define(:name, :params, :body, :token)

      # Whole translation unit. `functions` is an array of FunctionDef,
      # FunctionDecl (prototype) and GlobalDecl (file-scope variable) nodes in
      # source order.
      Program = Data.define(:functions)
    end
  end
end
