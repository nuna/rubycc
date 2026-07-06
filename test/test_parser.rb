# frozen_string_literal: true

require_relative "test_helper"

class TestParser < Minitest::Test
  AST = Rubycc::Front::AST
  Type = Rubycc::Type

  def parse(source, filename: "test.c")
    tokens = Rubycc::Front::Lexer.new(source, filename: filename).tokenize
    Rubycc::Front::Parser.new(tokens).parse
  end

  # Parses "int main(void) { return <expr>; }" and returns the expr node.
  def parse_expr(expr_source)
    program = parse("int main(void) { return #{expr_source}; }")
    program.functions.first.body.first.expr
  end

  def test_parses_program_structure
    program = parse("int main(void) { return 42; }")

    assert_equal 1, program.functions.size
    func = program.functions.first
    assert_equal "main", func.name
    assert_equal 1, func.body.size
    assert_kind_of AST::Return, func.body.first
    assert_kind_of AST::IntLit, func.body.first.expr
    assert_equal 42, func.body.first.expr.value
  end

  def test_accepts_empty_parameter_list
    program = parse("int main() { return 0; }")
    assert_equal "main", program.functions.first.name
  end

  def test_precedence_multiplication_binds_tighter_than_addition
    # 2 + 3 * 4  =>  (add 2 (mul 3 4))
    expr = parse_expr("2 + 3 * 4")

    assert_kind_of AST::Binary, expr
    assert_equal :add, expr.op
    assert_equal 2, expr.lhs.value

    rhs = expr.rhs
    assert_kind_of AST::Binary, rhs
    assert_equal :mul, rhs.op
    assert_equal 3, rhs.lhs.value
    assert_equal 4, rhs.rhs.value
  end

  def test_parentheses_override_precedence
    # (2 + 3) * 4  =>  (mul (add 2 3) 4)
    expr = parse_expr("(2 + 3) * 4")

    assert_equal :mul, expr.op
    assert_kind_of AST::Binary, expr.lhs
    assert_equal :add, expr.lhs.op
    assert_equal 4, expr.rhs.value
  end

  def test_subtraction_is_left_associative
    # 100 - 60 + 2  =>  (add (sub 100 60) 2)
    expr = parse_expr("100 - 60 + 2")

    assert_equal :add, expr.op
    assert_kind_of AST::Binary, expr.lhs
    assert_equal :sub, expr.lhs.op
    assert_equal 100, expr.lhs.lhs.value
    assert_equal 60, expr.lhs.rhs.value
    assert_equal 2, expr.rhs.value
  end

  def test_unary_minus_produces_neg_node
    expr = parse_expr("-42")
    assert_kind_of AST::Unary, expr
    assert_equal :neg, expr.op
    assert_equal 42, expr.operand.value
  end

  def test_unary_plus_is_folded_away
    expr = parse_expr("+42")
    assert_kind_of AST::IntLit, expr
    assert_equal 42, expr.value
  end

  def test_missing_semicolon_reports_compile_error
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { return 42 }")
    end

    assert_equal "test.c", error.filename
    assert_equal 1, error.line
    assert_match(/expected ';'/, error.description)
    # The caret should point at the unexpected '}' token.
    assert_equal 28, error.column
  end

  def test_missing_expression_reports_compile_error
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { return ; }")
    end
    assert_match(/expected expression/, error.description)
  end

  def test_bare_expression_is_a_valid_statement
    # "42;" is now a valid expression-statement (its value is discarded).
    program = parse("int main(void) { 42; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::ExpressionStmt, stmt
    assert_kind_of AST::IntLit, stmt.expr
  end

  def test_unexpected_token_where_statement_expected
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { ) ; }")
    end
    assert_match(/expected expression/, error.description)
  end

  def test_parses_variable_declaration_without_initializer
    program = parse("int main(void) { int x; return 0; }")
    decl = program.functions.first.body.first

    assert_kind_of AST::VariableDecl, decl
    assert_equal "x", decl.name
    assert_nil decl.initializer
  end

  def test_parses_variable_declaration_with_initializer
    program = parse("int main(void) { int x = 6; return x; }")
    decl = program.functions.first.body.first

    assert_kind_of AST::VariableDecl, decl
    assert_equal "x", decl.name
    assert_kind_of AST::IntLit, decl.initializer
    assert_equal 6, decl.initializer.value
  end

  def test_parses_comma_separated_declarators_as_separate_decls
    program = parse("int main(void) { int a = 1, b; return 0; }")
    body = program.functions.first.body

    assert_kind_of AST::VariableDecl, body[0]
    assert_equal "a", body[0].name
    assert_equal 1, body[0].initializer.value

    assert_kind_of AST::VariableDecl, body[1]
    assert_equal "b", body[1].name
    assert_nil body[1].initializer
  end

  def test_variable_declaration_has_int_type
    program = parse("int main(void) { int x; return 0; }")
    decl = program.functions.first.body.first

    assert_kind_of AST::VariableDecl, decl
    assert_equal Type::Int, decl.type
  end

  def test_parses_pointer_declaration_type
    program = parse("int main(void) { int *p; return 0; }")
    decl = program.functions.first.body.first

    assert_kind_of AST::VariableDecl, decl
    assert_equal "p", decl.name
    assert_equal Type::Pointer.new(Type::Int), decl.type
  end

  def test_parses_pointer_to_pointer_declaration_type
    program = parse("int main(void) { int **pp; return 0; }")
    decl = program.functions.first.body.first

    assert_equal "pp", decl.name
    assert_equal Type::Pointer.new(Type::Pointer.new(Type::Int)), decl.type
  end

  def test_pointer_declarator_binds_per_declarator
    # In "int *p, q", the "*" applies only to p; q stays a plain int.
    program = parse("int main(void) { int *p, q; return 0; }")
    body = program.functions.first.body

    assert_equal Type::Pointer.new(Type::Int), body[0].type
    assert_equal Type::Int, body[1].type
  end

  def test_parses_pointer_parameter_type
    program = parse("int f(int *p) { return 0; } int main(void) { return 0; }")
    param = program.functions.first.params.first

    assert_kind_of AST::Parameter, param
    assert_equal "p", param.name
    assert_equal Type::Pointer.new(Type::Int), param.type
  end

  def test_parses_address_of_as_unary_addr
    expr = parse_expr("&x")
    assert_kind_of AST::Unary, expr
    assert_equal :addr, expr.op
    assert_kind_of AST::VariableRef, expr.operand
    assert_equal "x", expr.operand.name
  end

  def test_parses_dereference_as_unary_deref
    expr = parse_expr("*p")
    assert_kind_of AST::Unary, expr
    assert_equal :deref, expr.op
    assert_kind_of AST::VariableRef, expr.operand
    assert_equal "p", expr.operand.name
  end

  def test_parses_nested_dereference
    # **pp  =>  (deref (deref pp))
    expr = parse_expr("**pp")
    assert_kind_of AST::Unary, expr
    assert_equal :deref, expr.op
    assert_kind_of AST::Unary, expr.operand
    assert_equal :deref, expr.operand.op
    assert_equal "pp", expr.operand.operand.name
  end

  def test_dereference_binds_tighter_than_multiplication
    # *p * 4  =>  (mul (deref p) 4)
    expr = parse_expr("*p * 4")
    assert_kind_of AST::Binary, expr
    assert_equal :mul, expr.op
    assert_kind_of AST::Unary, expr.lhs
    assert_equal :deref, expr.lhs.op
    assert_equal 4, expr.rhs.value
  end

  def test_parses_store_through_pointer
    # *p = v  =>  (assign (deref p) v), a valid assignable target.
    expr = parse_expr("*p = 42")
    assert_kind_of AST::Assignment, expr
    assert_kind_of AST::Unary, expr.target
    assert_equal :deref, expr.target.op
    assert_equal 42, expr.value.value
  end

  def test_parses_variable_reference
    expr = parse_expr("x")
    assert_kind_of AST::VariableRef, expr
    assert_equal "x", expr.name
  end

  def test_parses_assignment_expression
    expr = parse_expr("x = 42")
    assert_kind_of AST::Assignment, expr
    assert_kind_of AST::VariableRef, expr.target
    assert_equal "x", expr.target.name
    assert_kind_of AST::IntLit, expr.value
    assert_equal 42, expr.value.value
  end

  def test_chained_assignment_is_right_associative
    # a = b = c  =>  (assign a (assign b c))
    expr = parse_expr("a = b = c")

    assert_kind_of AST::Assignment, expr
    assert_equal "a", expr.target.name
    assert_kind_of AST::Assignment, expr.value
    assert_equal "b", expr.value.target.name
    assert_kind_of AST::VariableRef, expr.value.value
    assert_equal "c", expr.value.value.name
  end

  def test_parses_expression_statement
    program = parse("int main(void) { x; return 0; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::ExpressionStmt, stmt
    assert_kind_of AST::VariableRef, stmt.expr
  end

  def test_parses_empty_statement
    program = parse("int main(void) { ; return 0; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::EmptyStmt, stmt
  end

  def test_assignment_to_non_lvalue_reports_compile_error
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { 1 = 2; return 0; }")
    end
    assert_match(/expression is not assignable/, error.description)
  end

  def test_equality_operator_produces_eq_node
    # 1 == 2  =>  (eq 1 2)
    expr = parse_expr("1 == 2")
    assert_kind_of AST::Binary, expr
    assert_equal :eq, expr.op
    assert_equal 1, expr.lhs.value
    assert_equal 2, expr.rhs.value
  end

  def test_relational_operators_map_to_ops
    { "<" => :lt, ">" => :gt, "<=" => :le, ">=" => :ge }.each do |punct, op|
      expr = parse_expr("1 #{punct} 2")
      assert_equal op, expr.op
    end
  end

  def test_additive_binds_tighter_than_equality
    # 1 + 1 == 2  =>  (eq (add 1 1) 2)
    expr = parse_expr("1 + 1 == 2")

    assert_equal :eq, expr.op
    assert_kind_of AST::Binary, expr.lhs
    assert_equal :add, expr.lhs.op
    assert_equal 1, expr.lhs.lhs.value
    assert_equal 1, expr.lhs.rhs.value
    assert_equal 2, expr.rhs.value
  end

  def test_relational_binds_tighter_than_equality
    # 0 < 1 == 1  =>  (eq (lt 0 1) 1)
    expr = parse_expr("0 < 1 == 1")

    assert_equal :eq, expr.op
    assert_kind_of AST::Binary, expr.lhs
    assert_equal :lt, expr.lhs.op
    assert_equal 1, expr.rhs.value
  end

  def test_logical_not_produces_not_node
    expr = parse_expr("!0")
    assert_kind_of AST::Unary, expr
    assert_equal :not, expr.op
    assert_equal 0, expr.operand.value
  end

  def test_parses_if_without_else
    program = parse("int main(void) { if (1) return 2; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::If, stmt
    assert_kind_of AST::IntLit, stmt.condition
    assert_kind_of AST::Return, stmt.then_stmt
    assert_nil stmt.else_stmt
  end

  def test_parses_if_with_else
    program = parse("int main(void) { if (1) return 2; else return 3; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::If, stmt
    assert_kind_of AST::Return, stmt.then_stmt
    assert_kind_of AST::Return, stmt.else_stmt
  end

  def test_dangling_else_binds_to_nearest_if
    # if (1) if (0) return 7; else return 42;
    # The else must attach to the inner if, not the outer one.
    program = parse("int main(void) { if (1) if (0) return 7; else return 42; }")
    outer = program.functions.first.body.first

    assert_kind_of AST::If, outer
    assert_nil outer.else_stmt

    inner = outer.then_stmt
    assert_kind_of AST::If, inner
    assert_kind_of AST::Return, inner.then_stmt
    assert_kind_of AST::Return, inner.else_stmt
  end

  def test_parses_compound_statement_as_block
    program = parse("int main(void) { { int x = 1; x; } return 0; }")
    block = program.functions.first.body.first

    assert_kind_of AST::Block, block
    assert_equal 2, block.items.size
    assert_kind_of AST::VariableDecl, block.items[0]
    assert_kind_of AST::ExpressionStmt, block.items[1]
  end

  def test_parses_while_statement
    program = parse("int main(void) { while (1) return 2; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::While, stmt
    assert_kind_of AST::IntLit, stmt.condition
    assert_equal 1, stmt.condition.value
    assert_kind_of AST::Return, stmt.body
  end

  def test_parses_do_while_statement
    program = parse("int main(void) { do return 2; while (1); }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::DoWhile, stmt
    assert_kind_of AST::Return, stmt.body
    assert_kind_of AST::IntLit, stmt.condition
    assert_equal 1, stmt.condition.value
  end

  def test_parses_for_statement_with_declaration_init
    program = parse("int main(void) { for (int i = 0; i < 10; i = i + 1) return i; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::For, stmt
    assert_kind_of Array, stmt.init
    assert_kind_of AST::VariableDecl, stmt.init.first
    assert_equal "i", stmt.init.first.name
    assert_kind_of AST::Binary, stmt.condition
    assert_equal :lt, stmt.condition.op
    assert_kind_of AST::Assignment, stmt.step
    assert_kind_of AST::Return, stmt.body
  end

  def test_parses_for_statement_with_expression_init
    program = parse("int main(void) { int i; for (i = 0; i < 10; i = i + 1) return i; }")
    stmt = program.functions.first.body.last

    assert_kind_of AST::For, stmt
    assert_kind_of AST::Assignment, stmt.init
  end

  def test_parses_for_statement_with_all_clauses_omitted
    program = parse("int main(void) { for (;;) break; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::For, stmt
    assert_nil stmt.init
    assert_nil stmt.condition
    assert_nil stmt.step
    assert_kind_of AST::Break, stmt.body
  end

  def test_parses_break_statement
    program = parse("int main(void) { while (1) break; }")
    stmt = program.functions.first.body.first.body

    assert_kind_of AST::Break, stmt
  end

  def test_parses_continue_statement
    program = parse("int main(void) { while (1) continue; }")
    stmt = program.functions.first.body.first.body

    assert_kind_of AST::Continue, stmt
  end

  def test_parses_function_definition_with_parameters
    program = parse("int add(int a, int b) { return a + b; }")
    func = program.functions.first

    assert_kind_of AST::FunctionDef, func
    assert_equal "add", func.name
    assert_equal 2, func.params.size
    assert_kind_of AST::Parameter, func.params[0]
    assert_equal "a", func.params[0].name
    assert_equal "b", func.params[1].name
  end

  def test_parses_multiple_top_level_functions
    program = parse("int f(void) { return 1; } int main(void) { return 0; }")

    assert_equal 2, program.functions.size
    assert_equal "f", program.functions[0].name
    assert_equal "main", program.functions[1].name
  end

  def test_parses_function_prototype
    program = parse("int f(int a, int b); int main(void) { return 0; }")
    proto = program.functions.first

    assert_kind_of AST::FunctionDecl, proto
    assert_equal "f", proto.name
    assert_equal 2, proto.params.size
    assert_equal "a", proto.params[0].name
  end

  def test_prototype_may_omit_parameter_names
    program = parse("int f(int, int); int main(void) { return 0; }")
    proto = program.functions.first

    assert_kind_of AST::FunctionDecl, proto
    assert_equal 2, proto.params.size
    assert_nil proto.params[0].name
    assert_nil proto.params[1].name
  end

  def test_prototype_with_void_has_no_parameters
    program = parse("int f(void); int main(void) { return 0; }")
    proto = program.functions.first

    assert_kind_of AST::FunctionDecl, proto
    assert_empty proto.params
  end

  def test_parses_function_call_with_arguments
    expr = parse_expr("add(1, 2)")

    assert_kind_of AST::Call, expr
    assert_equal "add", expr.name
    assert_equal 2, expr.args.size
    assert_equal 1, expr.args[0].value
    assert_equal 2, expr.args[1].value
  end

  def test_parses_call_with_no_arguments
    expr = parse_expr("f()")

    assert_kind_of AST::Call, expr
    assert_equal "f", expr.name
    assert_empty expr.args
  end

  def test_parses_nested_call_arguments
    expr = parse_expr("f(g(1))")

    assert_kind_of AST::Call, expr
    assert_kind_of AST::Call, expr.args.first
    assert_equal "g", expr.args.first.name
  end

  def test_parses_array_declaration_type
    program = parse("int main(void) { int a[10]; return 0; }")
    decl = program.functions.first.body.first

    assert_kind_of AST::VariableDecl, decl
    assert_equal "a", decl.name
    assert_equal Type::Array.new(Type::Int, 10), decl.type
    assert_nil decl.initializer
  end

  def test_parses_pointer_array_declaration_type
    program = parse("int main(void) { int *ps[4]; return 0; }")
    decl = program.functions.first.body.first

    assert_equal "ps", decl.name
    assert_equal Type::Array.new(Type::Pointer.new(Type::Int), 4), decl.type
  end

  def test_array_size_must_be_a_positive_constant
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { int a[0]; return 0; }")
    end
    assert_match(/array size must be positive/, error.description)
  end

  def test_array_size_must_be_an_integer_constant
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { int n; int a[n]; return 0; }")
    end
    assert_match(/array size must be an integer constant/, error.description)
  end

  def test_multidimensional_array_is_rejected
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { int a[3][4]; return 0; }")
    end
    assert_match(/multidimensional arrays are not supported yet/, error.description)
  end

  def test_array_initializer_is_rejected
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { int a[3] = 0; return 0; }")
    end
    assert_match(/array initializers are not supported yet/, error.description)
  end

  def test_parses_subscript
    # a[i]  =>  (subscript a i)
    expr = parse_expr("a[i]")
    assert_kind_of AST::Subscript, expr
    assert_kind_of AST::VariableRef, expr.target
    assert_equal "a", expr.target.name
    assert_kind_of AST::VariableRef, expr.index
    assert_equal "i", expr.index.name
  end

  def test_parses_subscript_chain
    # a[i][j]  =>  (subscript (subscript a i) j)
    expr = parse_expr("a[i][j]")
    assert_kind_of AST::Subscript, expr
    assert_equal "j", expr.index.name
    inner = expr.target
    assert_kind_of AST::Subscript, inner
    assert_equal "a", inner.target.name
    assert_equal "i", inner.index.name
  end

  def test_subscript_target_is_assignable
    # a[i] = 42  =>  (assign (subscript a i) 42)
    expr = parse_expr("a[i] = 42")
    assert_kind_of AST::Assignment, expr
    assert_kind_of AST::Subscript, expr.target
    assert_equal 42, expr.value.value
  end

  def test_parses_sizeof_unary_expression
    # sizeof 1  =>  (sizeof-expr 1)
    expr = parse_expr("sizeof 1")
    assert_kind_of AST::SizeofExpr, expr
    assert_kind_of AST::IntLit, expr.operand
    assert_equal 1, expr.operand.value
  end

  def test_parses_sizeof_parenthesized_variable_as_expression
    # sizeof(a): the "(" is not a type-name, so it is a parenthesized operand.
    expr = parse_expr("sizeof(a)")
    assert_kind_of AST::SizeofExpr, expr
    assert_kind_of AST::VariableRef, expr.operand
    assert_equal "a", expr.operand.name
  end

  def test_parses_sizeof_type_name
    expr = parse_expr("sizeof(int)")
    assert_kind_of AST::SizeofType, expr
    assert_equal Type::Int, expr.type
  end

  def test_parses_sizeof_pointer_type_name
    expr = parse_expr("sizeof(int *)")
    assert_kind_of AST::SizeofType, expr
    assert_equal Type::Pointer.new(Type::Int), expr.type
  end

  def test_parses_sizeof_pointer_to_pointer_type_name
    expr = parse_expr("sizeof(int **)")
    assert_kind_of AST::SizeofType, expr
    assert_equal Type::Pointer.new(Type::Pointer.new(Type::Int)), expr.type
  end

  def test_logical_and_produces_logical_and_node
    expr = parse_expr("1 && 2")
    assert_kind_of AST::LogicalAnd, expr
    assert_equal 1, expr.lhs.value
    assert_equal 2, expr.rhs.value
  end

  def test_logical_or_produces_logical_or_node
    expr = parse_expr("1 || 2")
    assert_kind_of AST::LogicalOr, expr
    assert_equal 1, expr.lhs.value
    assert_equal 2, expr.rhs.value
  end

  def test_logical_and_binds_tighter_than_logical_or
    # 1 || 0 && 0  =>  (or 1 (and 0 0))
    expr = parse_expr("1 || 0 && 0")
    assert_kind_of AST::LogicalOr, expr
    assert_equal 1, expr.lhs.value
    assert_kind_of AST::LogicalAnd, expr.rhs
    assert_equal 0, expr.rhs.lhs.value
    assert_equal 0, expr.rhs.rhs.value
  end

  def test_conditional_operator_produces_conditional_node
    expr = parse_expr("1 ? 2 : 3")
    assert_kind_of AST::Conditional, expr
    assert_equal 1, expr.condition.value
    assert_equal 2, expr.then_expr.value
    assert_equal 3, expr.else_expr.value
  end

  def test_conditional_operator_is_right_associative
    # a ? b : c ? d : e  =>  (cond a b (cond c d e))
    expr = parse_expr("1 ? 2 : 3 ? 4 : 5")
    assert_kind_of AST::Conditional, expr
    assert_equal 1, expr.condition.value
    assert_equal 2, expr.then_expr.value
    assert_kind_of AST::Conditional, expr.else_expr
    assert_equal 3, expr.else_expr.condition.value
    assert_equal 4, expr.else_expr.then_expr.value
    assert_equal 5, expr.else_expr.else_expr.value
  end

  def test_assignment_binds_looser_than_conditional
    # a = b ? c : d  =>  (assign a (cond b c d))
    expr = parse_expr("a = b ? c : d")
    assert_kind_of AST::Assignment, expr
    assert_equal "a", expr.target.name
    assert_kind_of AST::Conditional, expr.value
  end

  def test_parses_compound_assignment_operators
    { "+=" => :add, "-=" => :sub, "*=" => :mul, "/=" => :div, "%=" => :mod }.each do |punct, op|
      expr = parse_expr("x #{punct} 1")
      assert_kind_of AST::CompoundAssignment, expr
      assert_equal op, expr.op
      assert_kind_of AST::VariableRef, expr.target
      assert_equal "x", expr.target.name
      assert_equal 1, expr.value.value
    end
  end

  def test_compound_assignment_to_non_lvalue_reports_compile_error
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { 1 += 2; return 0; }")
    end
    assert_match(/expression is not assignable/, error.description)
  end

  def test_parses_prefix_increment
    expr = parse_expr("++i")
    assert_kind_of AST::IncDec, expr
    assert_equal :add, expr.op
    assert_equal true, expr.prefix
    assert_kind_of AST::VariableRef, expr.target
    assert_equal "i", expr.target.name
  end

  def test_parses_prefix_decrement
    expr = parse_expr("--i")
    assert_kind_of AST::IncDec, expr
    assert_equal :sub, expr.op
    assert_equal true, expr.prefix
  end

  def test_parses_postfix_increment
    expr = parse_expr("i++")
    assert_kind_of AST::IncDec, expr
    assert_equal :add, expr.op
    assert_equal false, expr.prefix
    assert_kind_of AST::VariableRef, expr.target
    assert_equal "i", expr.target.name
  end

  def test_parses_postfix_decrement
    expr = parse_expr("i--")
    assert_kind_of AST::IncDec, expr
    assert_equal :sub, expr.op
    assert_equal false, expr.prefix
  end

  def test_postfix_increment_on_subscript
    expr = parse_expr("a[i]++")
    assert_kind_of AST::IncDec, expr
    assert_equal false, expr.prefix
    assert_kind_of AST::Subscript, expr.target
  end

  def test_prefix_increment_of_non_lvalue_reports_compile_error
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { ++1; return 0; }")
    end
    assert_match(/expression is not assignable/, error.description)
  end

  def test_postfix_increment_of_non_lvalue_reports_compile_error
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { 1++; return 0; }")
    end
    assert_match(/expression is not assignable/, error.description)
  end

  # --- file-scope (global) variable declarations --------------------------

  def test_parses_uninitialized_global_declaration
    program = parse("int g; int main(void) { return 0; }")
    decl = program.functions.first

    assert_kind_of AST::GlobalDecl, decl
    assert_equal "g", decl.name
    assert_equal Type::Int, decl.type
    assert_nil decl.initializer_value
  end

  def test_parses_initialized_global_declaration
    program = parse("int g = 42; int main(void) { return 0; }")
    decl = program.functions.first

    assert_kind_of AST::GlobalDecl, decl
    assert_equal "g", decl.name
    assert_equal 42, decl.initializer_value
  end

  def test_parses_negative_global_initializer
    decl = parse("int g = -8; int main(void) { return 0; }").functions.first

    assert_equal(-8, decl.initializer_value)
  end

  def test_parses_char_global_initializer
    decl = parse("char c = 'x'; int main(void) { return 0; }").functions.first

    assert_kind_of AST::GlobalDecl, decl
    assert_equal Type::Char, decl.type
    assert_equal 120, decl.initializer_value # 'x'
  end

  def test_parses_global_array_declaration
    decl = parse("int table[8]; int main(void) { return 0; }").functions.first

    assert_kind_of AST::GlobalDecl, decl
    assert_equal Type::Array.new(Type::Int, 8), decl.type
    assert_nil decl.initializer_value
  end

  def test_parses_global_pointer_declaration
    decl = parse("int *p; int main(void) { return 0; }").functions.first

    assert_kind_of AST::GlobalDecl, decl
    assert_equal Type::Pointer.new(Type::Int), decl.type
  end

  def test_parses_comma_separated_globals
    program = parse("int a, b = 3, c; int main(void) { return 0; }")
    globals = program.functions.first(3)

    assert_equal %w[a b c], globals.map(&:name)
    assert_equal [nil, 3, nil], globals.map(&:initializer_value)
    assert(globals.all? { |g| g.is_a?(AST::GlobalDecl) })
  end

  def test_distinguishes_global_from_function
    program = parse("int g = 1; int main(void) { return 0; }")

    assert_kind_of AST::GlobalDecl, program.functions[0]
    assert_kind_of AST::FunctionDef, program.functions[1]
  end
end
