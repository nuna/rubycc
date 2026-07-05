# frozen_string_literal: true

module Rubycc
  module Front
    # Abstract syntax tree nodes for the C subset. Each node carries a
    # representative token (`token`) for source-location diagnostics.
    module AST
      # Integer literal. `value` is a Ruby Integer.
      IntLit = Data.define(:value, :token)

      # Unary operation. `op` is :neg (unary + is folded away by the parser).
      Unary = Data.define(:op, :operand, :token)

      # Binary operation. `op` is one of :add, :sub, :mul, :div, :mod.
      Binary = Data.define(:op, :lhs, :rhs, :token)

      # `return <expr>;`
      Return = Data.define(:expr, :token)

      # A local variable declaration. `initializer` is an expression node or
      # nil when the declarator has no "= <expr>" part.
      VariableDecl = Data.define(:name, :initializer, :token)

      # A reference to a local variable by name.
      VariableRef = Data.define(:name, :token)

      # Simple assignment `target = value`. `target` is always a
      # VariableRef (checked by the parser).
      Assignment = Data.define(:target, :value, :token)

      # An expression evaluated for its side effects; the value is discarded.
      ExpressionStmt = Data.define(:expr, :token)

      # The empty statement ";".
      EmptyStmt = Data.define(:token)

      # A function definition. `body` is an array of statement nodes.
      FunctionDef = Data.define(:name, :body, :token)

      # Whole translation unit. `functions` is an array of FunctionDef.
      Program = Data.define(:functions)
    end
  end
end
