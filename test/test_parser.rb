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
end
