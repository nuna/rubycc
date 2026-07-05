# frozen_string_literal: true

require_relative "test_helper"

class TestParser < Minitest::Test
  AST = Rubycc::Front::AST

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
end
