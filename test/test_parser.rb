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

  # Parses "int main(void) { <decl_source> return 0; }" and returns the first
  # declaration statement.
  def parse_decl(decl_source)
    program = parse("int main(void) { #{decl_source} return 0; }")
    program.functions.first.body.first
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
      parse("int main(void) { return 1 + ; }")
    end
    assert_match(/expected expression/, error.description)
  end

  def test_return_without_expression_parses_as_valueless_return
    program = parse("void f(void) { return; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::Return, stmt
    assert_nil stmt.expr
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

  def test_parses_switch_statement
    program = parse("int main(void) { switch (x) { case 1: return 1; } }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::Switch, stmt
    assert_kind_of AST::VariableRef, stmt.control
    assert_equal "x", stmt.control.name
    assert_kind_of AST::Block, stmt.body
  end

  def test_parses_case_label_with_folded_constant
    program = parse("int main(void) { switch (x) { case 42: return 1; } }")
    switch = program.functions.first.body.first
    case_stmt = switch.body.items.first

    assert_kind_of AST::Case, case_stmt
    assert_equal 42, case_stmt.value
    assert_kind_of AST::Return, case_stmt.body
  end

  def test_parses_case_label_with_negative_constant
    # "case -1:" folds the unary minus into the constant at parse time.
    program = parse("int main(void) { switch (x) { case -1: return 1; } }")
    case_stmt = program.functions.first.body.first.body.items.first

    assert_kind_of AST::Case, case_stmt
    assert_equal(-1, case_stmt.value)
  end

  def test_parses_case_label_with_character_constant
    program = parse("int main(void) { switch (x) { case 'A': return 1; } }")
    case_stmt = program.functions.first.body.first.body.items.first

    assert_kind_of AST::Case, case_stmt
    assert_equal 65, case_stmt.value
  end

  def test_case_label_folds_an_additive_constant_expression
    program = parse("int main(void) { switch (x) { case 1 + 2: return 1; } }")
    case_stmt = program.functions.first.body.first.body.items.first

    assert_kind_of AST::Case, case_stmt
    assert_equal 3, case_stmt.value
  end

  def test_case_label_folds_a_bitwise_or_enum_constant_expression
    program = parse("enum Color { RED = 1 }; int main(void) { switch (x) { case RED | 4: return 1; } }")
    case_stmt = program.functions.last.body.first.body.items.first

    assert_kind_of AST::Case, case_stmt
    assert_equal 5, case_stmt.value
  end

  def test_case_label_folds_a_conditional_expression
    # "case 1 ? 2 : 3:" parses the "?:" operand's own ":" as part of the
    # conditional-expression, leaving the label's ":" for the labeled
    # statement that follows.
    program = parse("int main(void) { switch (x) { case 1 ? 2 : 3: return 1; } }")
    case_stmt = program.functions.first.body.first.body.items.first

    assert_kind_of AST::Case, case_stmt
    assert_equal 2, case_stmt.value
    assert_kind_of AST::Return, case_stmt.body
  end

  def test_case_label_folds_short_circuiting_logical_operators
    program = parse("int main(void) { switch (x) { case 0 || 5: return 1; case 1 && 0: return 2; } }")
    labels = program.functions.first.body.first.body.items

    assert_equal 1, labels[0].value
    assert_equal 0, labels[1].value
  end

  def test_case_label_folds_a_sizeof_type_comparison
    program = parse("int main(void) { switch (x) { case sizeof(int) == 4: return 1; } }")
    case_stmt = program.functions.first.body.first.body.items.first

    assert_equal 1, case_stmt.value
  end

  def test_case_label_truncates_division_toward_zero
    program = parse("int main(void) { switch (x) { case -7 / 2: return 1; } }")
    case_stmt = program.functions.first.body.first.body.items.first

    assert_equal(-3, case_stmt.value)
  end

  def test_case_label_folds_a_cast_that_wraps_its_value
    program = parse("int main(void) { switch (x) { case (char)300: return 1; } }")
    case_stmt = program.functions.first.body.first.body.items.first

    assert_equal 44, case_stmt.value
  end

  def test_parses_default_label
    program = parse("int main(void) { switch (x) { default: return 1; } }")
    default_stmt = program.functions.first.body.first.body.items.first

    assert_kind_of AST::Default, default_stmt
    assert_kind_of AST::Return, default_stmt.body
  end

  def test_parses_goto_statement
    program = parse("int main(void) { goto done; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::Goto, stmt
    assert_equal "done", stmt.label
  end

  def test_parses_labeled_statement
    # "done: return 0;" is a labeled statement, distinguished from an
    # expression-statement by the identifier immediately followed by ":".
    program = parse("int main(void) { done: return 0; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::Label, stmt
    assert_equal "done", stmt.name
    assert_kind_of AST::Return, stmt.body
  end

  def test_parses_labeled_empty_statement
    program = parse("int main(void) { end: ; }")
    stmt = program.functions.first.body.first

    assert_kind_of AST::Label, stmt
    assert_equal "end", stmt.name
    assert_kind_of AST::EmptyStmt, stmt.body
  end

  def test_identifier_expression_statement_is_not_a_label
    # A bare identifier not followed by ":" stays an expression-statement, so
    # the two-token lookahead does not mistake "x;" for a label.
    program = parse("int main(void) { int x; x; }")
    stmt = program.functions.first.body.last

    assert_kind_of AST::ExpressionStmt, stmt
    assert_kind_of AST::VariableRef, stmt.expr
    assert_equal "x", stmt.expr.name
  end

  def test_parses_function_definition_with_parameters
    program = parse("int add(int a, int b) { return a + b; }")
    func = program.functions.first

    assert_kind_of AST::FunctionDef, func
    assert_equal "add", func.name
    assert_equal Type::Int, func.return_type
    assert_equal 2, func.params.size
    assert_kind_of AST::Parameter, func.params[0]
    assert_equal "a", func.params[0].name
    assert_equal "b", func.params[1].name
  end

  def test_parses_pointer_return_type
    program = parse("int *f(void) { return 0; }")
    func = program.functions.first

    assert_equal Type::Pointer.new(Type::Int), func.return_type
  end

  def test_parses_char_return_type
    program = parse("char f(void) { return 0; }")
    func = program.functions.first

    assert_equal Type::Char, func.return_type
  end

  def test_parses_void_return_type
    program = parse("void f(void) { return; }")
    func = program.functions.first

    assert_equal Type::Void, func.return_type
  end

  def test_parses_void_pointer_return_type
    program = parse("void *f(void) { return 0; }")
    func = program.functions.first

    assert_equal Type::Pointer.new(Type::Void), func.return_type
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
    assert_equal Type::Int, proto.return_type
    assert_equal 2, proto.params.size
    assert_equal "a", proto.params[0].name
  end

  def test_parses_void_pointer_prototype
    program = parse("void *malloc(int n); int main(void) { return 0; }")
    proto = program.functions.first

    assert_kind_of AST::FunctionDecl, proto
    assert_equal Type::Pointer.new(Type::Void), proto.return_type
    assert_equal Type::Int, proto.params[0].type
  end

  def test_parses_void_pointer_parameter
    program = parse("void free(void *p) { return; } int main(void) { return 0; }")
    param = program.functions.first.params.first

    assert_equal Type::Pointer.new(Type::Void), param.type
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

  def test_array_size_folds_a_constant_expression
    program = parse("enum { N = 5 }; int main(void) { int a[N * 2]; return 0; }")
    decl = program.functions.last.body.first

    assert_equal Type::Array.new(Type::Int, 10), decl.type
  end

  def test_array_size_folds_a_sizeof_type_expression
    program = parse("int main(void) { char b[sizeof(int) * 4]; return 0; }")
    decl = program.functions.first.body.first

    assert_equal Type::Array.new(Type::Char, 16), decl.type
  end

  def test_multidimensional_array_is_rejected
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { int a[3][4]; return 0; }")
    end
    assert_match(/multidimensional arrays are not supported yet/, error.description)
  end

  def test_parses_array_initializer_list
    decl = parse("int main(void) { int a[3] = {1, 2, 3}; return 0; }").functions.first.body.first

    assert_kind_of AST::VariableDecl, decl
    assert_kind_of AST::InitializerList, decl.initializer
    assert_equal 3, decl.initializer.items.size
    assert_equal [1, 2, 3], decl.initializer.items.map { |item| item.value.value }
    assert(decl.initializer.items.all? { |item| item.designators.empty? })
  end

  def test_array_initializer_infers_length_from_positional_elements
    decl = parse("int main(void) { int a[] = {4, 5, 6, 7}; return 0; }").functions.first.body.first

    assert_equal Type::Array.new(Type::Int, 4), decl.type
  end

  def test_array_initializer_infers_length_from_the_largest_designator
    decl = parse("int main(void) { int a[] = {[4] = 1, 2}; return 0; }").functions.first.body.first

    # [4] fixes index 4, then the following positional element lands at 5, so
    # the inferred length is 6 (max index + 1), not the element count.
    assert_equal Type::Array.new(Type::Int, 6), decl.type
  end

  def test_char_array_initializer_infers_length_from_the_string
    decl = parse("int main(void) { char s[] = \"abc\"; return 0; }").functions.first.body.first

    # Three characters plus the terminating NUL.
    assert_equal Type::Array.new(Type::Char, 4), decl.type
  end

  def test_parses_designated_and_nested_initializers
    program = parse("struct p { int x; int y; }; " \
                    "int main(void) { struct p a[2] = { {1, 2}, [1].y = 9 }; return 0; }")
    decl = program.functions.last.body.first
    items = decl.initializer.items

    assert_kind_of AST::InitializerList, items[0].value
    assert_kind_of AST::ArrayDesignator, items[1].designators[0]
    assert_equal 1, items[1].designators[0].index
    assert_kind_of AST::MemberDesignator, items[1].designators[1]
    assert_equal "y", items[1].designators[1].name
  end

  def test_parses_the_zero_initializer_idiom
    decl = parse("struct p { int x; int y; }; " \
                 "int main(void) { struct p a = {0}; return 0; }").functions.last.body.first

    assert_kind_of AST::InitializerList, decl.initializer
    assert_equal 1, decl.initializer.items.size
    assert_equal 0, decl.initializer.items.first.value.value
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

  def test_parses_cast_to_scalar_type
    # (int)x  =>  (cast int x)
    expr = parse_expr("(int)x")
    assert_kind_of AST::Cast, expr
    assert_equal Type::Int, expr.type
    assert_kind_of AST::VariableRef, expr.operand
    assert_equal "x", expr.operand.name
  end

  def test_parses_cast_to_pointer_type
    expr = parse_expr("(char *)p")
    assert_kind_of AST::Cast, expr
    assert_equal Type::Pointer.new(Type::Char), expr.type
    assert_kind_of AST::VariableRef, expr.operand
    assert_equal "p", expr.operand.name
  end

  def test_parses_nested_casts_right_to_left
    # (int)(char)x  =>  (cast int (cast char x))
    expr = parse_expr("(int)(char)x")
    assert_kind_of AST::Cast, expr
    assert_equal Type::Int, expr.type
    inner = expr.operand
    assert_kind_of AST::Cast, inner
    assert_equal Type::Char, inner.type
    assert_kind_of AST::VariableRef, inner.operand
  end

  def test_parses_cast_to_void_of_call
    # (void)f()  =>  (cast void (call f))
    expr = parse_expr("(void)f()")
    assert_kind_of AST::Cast, expr
    assert_equal Type::Void, expr.type
    assert_kind_of AST::Call, expr.operand
    assert_equal "f", expr.operand.name
  end

  def test_parenthesized_non_type_is_an_operand_not_a_cast
    # "(x) + 1": x is not a type-specifier, so "(x)" is a parenthesized operand
    # (the left side of "+"), never a cast of "+ 1" to type x.
    expr = parse_expr("(x) + 1")
    assert_kind_of AST::Binary, expr
    assert_equal :add, expr.op
    assert_kind_of AST::VariableRef, expr.lhs
    assert_equal "x", expr.lhs.name
    assert_equal 1, expr.rhs.value
  end

  def test_parenthesized_non_type_before_parentheses_is_not_a_cast
    # "(x)(y)": x is not a type-specifier, so "(x)" is a parenthesized operand,
    # not a cast — it is treated as a (would-be) call target. This subset only
    # calls a bare identifier, so the trailing "(y)" is left unconsumed and the
    # parser stops expecting ";", proving "(x)" was taken as a value, not a
    # cast of "(y)" to type x (which would fail asking for a type specifier).
    error = assert_raises(Rubycc::CompileError) do
      parse("int main(void) { return (x)(y); }")
    end
    assert_match(/expected ';'/, error.description)
  end

  def test_unary_minus_applies_to_cast
    # -(int)x  =>  (neg (cast int x)): a unary operator's operand is a
    # cast-expression, so the cast binds inside the negation.
    expr = parse_expr("-(int)x")
    assert_kind_of AST::Unary, expr
    assert_equal :neg, expr.op
    assert_kind_of AST::Cast, expr.operand
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
    {
      "+=" => :add, "-=" => :sub, "*=" => :mul, "/=" => :div, "%=" => :mod,
      "&=" => :and, "|=" => :or, "^=" => :xor, "<<=" => :shl, ">>=" => :shr
    }.each do |punct, op|
      expr = parse_expr("x #{punct} 1")
      assert_kind_of AST::CompoundAssignment, expr
      assert_equal op, expr.op
      assert_kind_of AST::VariableRef, expr.target
      assert_equal "x", expr.target.name
      assert_equal 1, expr.value.value
    end
  end

  # --- Step 15: bitwise, shift and comma operators ---------------------

  def test_bitwise_operators_produce_binary_nodes
    { "&" => :and, "|" => :or, "^" => :xor, "<<" => :shl, ">>" => :shr }.each do |punct, op|
      expr = parse_expr("a #{punct} b")
      assert_kind_of AST::Binary, expr
      assert_equal op, expr.op
      assert_equal "a", expr.lhs.name
      assert_equal "b", expr.rhs.name
    end
  end

  def test_bitwise_precedence_inclusive_or_loosest_then_xor_then_and
    # a | b ^ c & d  =>  (or a (xor b (and c d))): inclusive-OR is loosest,
    # exclusive-OR next, bitwise AND tightest of the three.
    expr = parse_expr("a | b ^ c & d")
    assert_kind_of AST::Binary, expr
    assert_equal :or, expr.op
    assert_equal "a", expr.lhs.name
    xor = expr.rhs
    assert_equal :xor, xor.op
    assert_equal "b", xor.lhs.name
    bit_and = xor.rhs
    assert_equal :and, bit_and.op
    assert_equal "c", bit_and.lhs.name
    assert_equal "d", bit_and.rhs.name
  end

  def test_bitwise_and_is_looser_than_equality
    # a & b == c  =>  (and a (eq b c)): equality binds tighter than bitwise AND.
    expr = parse_expr("a & b == c")
    assert_equal :and, expr.op
    assert_equal "a", expr.lhs.name
    assert_kind_of AST::Binary, expr.rhs
    assert_equal :eq, expr.rhs.op
  end

  def test_shift_is_between_relational_and_additive
    # a < b << c + d  =>  (lt a (shl b (add c d))): shift is tighter than
    # relational and looser than additive.
    expr = parse_expr("a < b << c + d")
    assert_equal :lt, expr.op
    assert_equal "a", expr.lhs.name
    shift = expr.rhs
    assert_equal :shl, shift.op
    assert_equal "b", shift.lhs.name
    add = shift.rhs
    assert_equal :add, add.op
    assert_equal "c", add.lhs.name
    assert_equal "d", add.rhs.name
  end

  def test_binary_and_distinguished_from_address_of
    # "a & b" is a bitwise AND of two operands...
    expr = parse_expr("a & b")
    assert_kind_of AST::Binary, expr
    assert_equal :and, expr.op

    # ...while "&a" (a "&" opening a unary-expression) is address-of.
    unary = parse_expr("&a")
    assert_kind_of AST::Unary, unary
    assert_equal :addr, unary.op
    assert_equal "a", unary.operand.name
  end

  def test_bitwise_not_desugars_to_xor_with_minus_one
    # ~a is lowered at parse time to the exclusive-or "a ^ -1".
    expr = parse_expr("~a")
    assert_kind_of AST::Binary, expr
    assert_equal :xor, expr.op
    assert_equal "a", expr.lhs.name
    assert_kind_of AST::IntLit, expr.rhs
    assert_equal(-1, expr.rhs.value)
  end

  def test_comma_operator_is_left_associative
    # a, b, c  =>  (comma (comma a b) c)
    expr = parse_expr("a, b, c")
    assert_kind_of AST::Comma, expr
    assert_kind_of AST::Comma, expr.left
    assert_equal "a", expr.left.left.name
    assert_equal "b", expr.left.right.name
    assert_equal "c", expr.right.name
  end

  def test_comma_is_looser_than_assignment
    # a = 1, b = 2  =>  (comma (assign a 1) (assign b 2))
    expr = parse_expr("a = 1, b = 2")
    assert_kind_of AST::Comma, expr
    assert_kind_of AST::Assignment, expr.left
    assert_kind_of AST::Assignment, expr.right
  end

  def test_comma_as_separator_is_not_a_comma_operator
    # A comma between call arguments stays a separator: "f(a, b)" has two
    # arguments, not one comma-expression argument.
    program = parse("int f(int a, int b); int main(void) { return f(1, 2); }")
    call = program.functions.last.body.first.expr
    assert_kind_of AST::Call, call
    assert_equal 2, call.args.size
    assert_equal 1, call.args[0].value
    assert_equal 2, call.args[1].value
  end

  def test_comma_operator_inside_parentheses_as_call_argument
    # Parentheses turn a comma back into the operator: "f((a, b))" is one
    # argument whose value is the comma-expression.
    program = parse("int f(int a); int main(void) { return f((1, 2)); }")
    call = program.functions.last.body.first.expr
    assert_equal 1, call.args.size
    assert_kind_of AST::Comma, call.args[0]
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

  def test_parses_global_initializer_with_a_constant_expression
    decl = parse("int g = (1 << 4) - 1; int main(void) { return 0; }").functions.first

    assert_equal 15, decl.initializer_value
  end

  def test_parses_global_initializer_with_a_sizeof_constant_expression
    decl = parse("int g = sizeof(int) * 4; int main(void) { return 0; }").functions.first

    assert_equal 16, decl.initializer_value
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

  # --- structs ------------------------------------------------------------

  def test_struct_definition_alone_yields_no_object
    # "struct point { ... };" declares only the tag, so the program holds just
    # the function that follows it.
    program = parse("struct point { int x; int y; }; int main(void) { return 0; }")

    assert_equal 1, program.functions.size
    assert_kind_of AST::FunctionDef, program.functions.first
  end

  def test_parses_struct_variable_declaration_type
    program = parse("struct point { int x; int y; }; " \
                    "int main(void) { struct point p; return 0; }")
    decl = program.functions.first.body.first

    assert_kind_of AST::VariableDecl, decl
    assert_equal "p", decl.name
    assert_predicate decl.type, :struct?
    assert_equal "point", decl.type.tag
    assert_equal 8, decl.type.size
  end

  def test_same_tag_resolves_to_one_struct_type
    # Two "struct point" declarators name the very same (identity-equal) type.
    program = parse("struct point { int x; }; " \
                    "int main(void) { struct point a; struct point b; return 0; }")
    body = program.functions.first.body

    assert_same body[0].type, body[1].type
  end

  def test_parses_pointer_to_struct_type
    program = parse("struct node { int v; }; " \
                    "int main(void) { struct node *p; return 0; }")
    decl = program.functions.first.body.first

    assert_predicate decl.type, :pointer?
    assert_predicate decl.type.target, :struct?
    assert_equal "node", decl.type.target.tag
  end

  def test_self_referential_struct_pointer_member
    program = parse("struct node { int v; struct node *next; }; " \
                    "int main(void) { struct node n; return 0; }")
    type = program.functions.first.body.first.type

    assert_same type, type.member("next").type.target
  end

  def test_forward_declared_struct_is_incomplete
    program = parse("struct node; int main(void) { struct node *p; return 0; }")
    decl = program.functions.first.body.first

    assert_predicate decl.type, :pointer?
    refute_predicate decl.type.target, :complete?
  end

  def test_parses_anonymous_struct_variable
    program = parse("int main(void) { struct { int x; } v; return 0; }")
    decl = program.functions.first.body.first

    assert_predicate decl.type, :struct?
    assert_nil decl.type.tag
  end

  # --- unions and anonymous members --------------------------------------

  def test_parses_union_variable_declaration_type
    program = parse("union u { int i; char c; }; " \
                    "int main(void) { union u v; return 0; }")
    decl = program.functions.first.body.first

    assert_kind_of AST::VariableDecl, decl
    assert_predicate decl.type, :struct? # an aggregate, like a struct
    assert_predicate decl.type, :union?
    assert_equal "u", decl.type.tag
  end

  def test_union_overlays_members_at_offset_zero
    # Every member starts at 0; the size holds the widest member (int, 4),
    # rounded to the widest alignment (int, 4).
    program = parse("union u { int i; char c; short s; }; " \
                    "int main(void) { union u v; return 0; }")
    type = program.functions.first.body.first.type

    assert_equal 0, type.member("i").offset
    assert_equal 0, type.member("c").offset
    assert_equal 0, type.member("s").offset
    assert_equal 4, type.size
    assert_equal 4, type.alignment
  end

  def test_union_size_rounds_widest_member_to_alignment
    # The widest member is char[5] (size 5, alignment 1), but the int member
    # forces alignment 4, so the size rounds 5 up to 8.
    program = parse("union u { int i; char buf[5]; }; " \
                    "int main(void) { union u v; return 0; }")
    type = program.functions.first.body.first.type

    assert_equal 8, type.size
    assert_equal 4, type.alignment
  end

  def test_anonymous_member_resolves_transparently_with_composed_offset
    # "n" and "p" live inside the anonymous struct, which itself sits after the
    # int "tag" (offset 4 under 4-byte alignment). Accessing them through the
    # outer struct folds the anonymous member's offset into the inner one.
    program = parse("struct obj { int tag; struct { int n; int p; }; }; " \
                    "int main(void) { struct obj o; return 0; }")
    type = program.functions.first.body.first.type

    assert_equal 0, type.member("tag").offset
    assert_equal 4, type.member("n").offset
    assert_equal 8, type.member("p").offset
  end

  def test_anonymous_union_member_shares_offset_with_sibling
    # The anonymous union overlays both variants at the struct's second slot.
    program = parse("struct box { int kind; union { int n; char *s; }; }; " \
                    "int main(void) { struct box b; return 0; }")
    type = program.functions.first.body.first.type

    assert_equal 8, type.member("n").offset # 8-byte pointer forces alignment 8
    assert_equal 8, type.member("s").offset
  end

  def test_nested_anonymous_members_resolve_recursively
    # An anonymous union inside an anonymous struct: the deep field is reached
    # through two transparent layers in one lookup.
    program = parse("struct outer { int a; struct { int b; union { int c; char d; }; }; }; " \
                    "int main(void) { struct outer o; return 0; }")
    type = program.functions.first.body.first.type

    assert_equal 4, type.member("b").offset
    assert_equal 8, type.member("c").offset
    assert_equal 8, type.member("d").offset
  end

  def test_typedef_of_tagged_union
    decl = parse_body_item("union pair { int a; int b; }; typedef union pair Pair;",
                           "Pair p; return 0;")
    assert_predicate decl.type, :union?
    assert_equal "pair", decl.type.tag
  end

  def test_typedef_of_anonymous_union
    decl = parse_body_item("typedef union { int i; char c; } U;", "U u; return 0;")
    assert_predicate decl.type, :union?
    assert_nil decl.type.tag
  end

  def test_parses_dot_member_access
    # s.x  =>  (member s "x" arrow=false)
    expr = parse_expr("s.x")
    assert_kind_of AST::MemberAccess, expr
    assert_kind_of AST::VariableRef, expr.base
    assert_equal "s", expr.base.name
    assert_equal "x", expr.member
    refute expr.arrow
  end

  def test_parses_arrow_member_access
    # p->x  =>  (member p "x" arrow=true)
    expr = parse_expr("p->x")
    assert_kind_of AST::MemberAccess, expr
    assert_equal "p", expr.base.name
    assert_equal "x", expr.member
    assert expr.arrow
  end

  def test_parses_nested_member_access
    # a.b.c  =>  (member (member a "b") "c")
    expr = parse_expr("a.b.c")
    assert_kind_of AST::MemberAccess, expr
    assert_equal "c", expr.member
    inner = expr.base
    assert_kind_of AST::MemberAccess, inner
    assert_equal "b", inner.member
    assert_equal "a", inner.base.name
  end

  def test_parses_arrow_chain
    # p->q->r  =>  (member (member p "q" arrow) "r" arrow)
    expr = parse_expr("p->q->r")
    assert_kind_of AST::MemberAccess, expr
    assert expr.arrow
    assert_equal "r", expr.member
    assert_kind_of AST::MemberAccess, expr.base
    assert_equal "q", expr.base.member
  end

  def test_member_access_of_subscript
    # a[i].x  =>  (member (subscript a i) "x")
    expr = parse_expr("a[i].x")
    assert_kind_of AST::MemberAccess, expr
    assert_equal "x", expr.member
    assert_kind_of AST::Subscript, expr.base
  end

  def test_subscript_of_member_access
    # s.a[i]  =>  (subscript (member s "a") i)
    expr = parse_expr("s.a[i]")
    assert_kind_of AST::Subscript, expr
    assert_kind_of AST::MemberAccess, expr.target
    assert_equal "a", expr.target.member
  end

  def test_member_access_is_assignable
    # s.x = 42  =>  (assign (member s "x") 42)
    expr = parse_expr("s.x = 42")
    assert_kind_of AST::Assignment, expr
    assert_kind_of AST::MemberAccess, expr.target
    assert_equal 42, expr.value.value
  end

  # --- integer type extension (Step 17) -----------------------------------

  def test_declaration_specifiers_normalize_regardless_of_order
    { "unsigned long x;" => Type::ULong, "long unsigned x;" => Type::ULong,
      "long unsigned int x;" => Type::ULong, "unsigned long int x;" => Type::ULong,
      "int long unsigned x;" => Type::ULong, "long long x;" => Type::Long,
      "long long int x;" => Type::Long, "int long x;" => Type::Long,
      "signed long x;" => Type::Long, "unsigned x;" => Type::UInt,
      "unsigned int x;" => Type::UInt, "signed x;" => Type::Int,
      "signed int x;" => Type::Int, "short x;" => Type::Short,
      "short int x;" => Type::Short, "unsigned short x;" => Type::UShort,
      "short unsigned int x;" => Type::UShort, "signed char x;" => Type::Char,
      "char x;" => Type::Char, "unsigned char x;" => Type::UChar,
      "_Bool x;" => Type::Bool }.each do |source, expected|
      assert_equal expected, parse_decl(source).type, "#{source.inspect} should normalize to #{expected}"
    end
  end

  def test_sizeof_unsigned_long_type_name
    expr = parse_expr("sizeof(unsigned long)")
    assert_kind_of AST::SizeofType, expr
    assert_equal Type::ULong, expr.type
  end

  def test_sizeof_short_and_unsigned_char_type_names
    assert_equal Type::Short, parse_expr("sizeof(short)").type
    assert_equal Type::UChar, parse_expr("sizeof(unsigned char)").type
    assert_equal Type::Bool, parse_expr("sizeof(_Bool)").type
  end

  def test_hexadecimal_and_octal_integer_literal_values
    assert_equal 31, parse_expr("0x1F").value
    assert_equal 8, parse_expr("010").value
    assert_equal 0, parse_expr("0").value
  end

  def test_decimal_literal_type_by_size
    assert_equal Type::Int, parse_expr("42").type
    assert_equal Type::Long, parse_expr("2147483648").type # past INT_MAX
    assert_equal Type::Long, parse_expr("4294967296").type # past UINT_MAX
  end

  def test_hexadecimal_literal_may_become_unsigned
    # A decimal constant never falls to an unsigned type without a suffix, but
    # a hex constant may (6.4.4.1): 0x80000000 does not fit a signed int, so it
    # takes the next candidate, unsigned int, rather than widening to long.
    assert_equal Type::UInt, parse_expr("0x80000000").type
    assert_equal Type::Int, parse_expr("0x7FFFFFFF").type
  end

  def test_unsigned_suffix_literal_type
    assert_equal Type::UInt, parse_expr("10u").type
    assert_equal Type::UInt, parse_expr("10U").type
  end

  def test_long_suffix_literal_type
    assert_equal Type::Long, parse_expr("10l").type
    assert_equal Type::Long, parse_expr("10L").type
    assert_equal Type::Long, parse_expr("10ll").type
  end

  def test_unsigned_long_suffix_literal_type_regardless_of_order
    assert_equal Type::ULong, parse_expr("10ul").type
    assert_equal Type::ULong, parse_expr("10lu").type
    assert_equal Type::ULong, parse_expr("10ull").type
    assert_equal Type::ULong, parse_expr("10llu").type
  end

  def test_character_constant_is_always_plain_int
    assert_equal Type::Int, parse_expr("'A'").type
  end

  # --- typedef (Step 18) --------------------------------------------------

  # Parses the first body item of "<prelude> int main(void) { <body> }".
  def parse_body_item(prelude, body)
    program = parse("#{prelude} int main(void) { #{body} }")
    program.functions.last.body.first
  end

  def test_typedef_name_declares_a_variable_of_the_aliased_type
    decl = parse_body_item("typedef int MyInt;", "MyInt x; return 0;")
    assert_kind_of AST::VariableDecl, decl
    assert_equal "x", decl.name
    assert_equal Type::Int, decl.type
  end

  def test_typedef_declaration_yields_no_object
    # A typedef contributes no AST node, so the program holds only main.
    program = parse("typedef int MyInt; int main(void) { return 0; }")
    assert_equal 1, program.functions.size
    assert_kind_of AST::FunctionDef, program.functions.first
  end

  def test_typedef_of_pointer_type
    decl = parse_body_item("typedef int *IntPtr;", "IntPtr p; return 0;")
    assert_equal Type::Pointer.new(Type::Int), decl.type
  end

  def test_typedef_of_array_type
    decl = parse_body_item("typedef char Buf[8];", "Buf b; return 0;")
    assert_equal Type::Array.new(Type::Char, 8), decl.type
  end

  def test_typedef_of_unsigned_long
    decl = parse_body_item("typedef unsigned long VALUE;", "VALUE v; return 0;")
    assert_equal Type::ULong, decl.type
  end

  def test_typedef_of_tagged_struct
    decl = parse_body_item("struct point { int x; int y; }; typedef struct point Point;",
                           "Point p; return 0;")
    assert_predicate decl.type, :struct?
    assert_equal "point", decl.type.tag
    assert_equal 8, decl.type.size
  end

  def test_typedef_of_anonymous_struct
    decl = parse_body_item("typedef struct { int x; } S;", "S s; return 0;")
    assert_predicate decl.type, :struct?
    assert_nil decl.type.tag
  end

  def test_typedef_name_is_usable_in_a_cast
    # (T)5 parses as a cast, T resolving through the typedef namespace.
    program = parse("typedef int T; int main(void) { return (T)5; }")
    expr = program.functions.last.body.first.expr
    assert_kind_of AST::Cast, expr
    assert_equal Type::Int, expr.type
    assert_equal 5, expr.operand.value
  end

  def test_typedef_name_is_usable_in_sizeof
    program = parse("typedef int *P; int main(void) { return sizeof(P); }")
    expr = program.functions.last.body.first.expr
    assert_kind_of AST::SizeofType, expr
    assert_equal Type::Pointer.new(Type::Int), expr.type
  end

  def test_typedef_name_is_usable_as_a_parameter_type
    program = parse("typedef int T; int f(T a) { return a; } int main(void) { return 0; }")
    param = program.functions.first.params.first
    assert_equal Type::Int, param.type
  end

  def test_declarator_shadows_a_typedef_name_of_the_same_name
    # After "int T;" in the block, T names a variable, so "T" is an ordinary
    # reference rather than a type — the return statement reads the variable.
    program = parse("typedef int T; int main(void) { int T = 5; return T; }")
    body = program.functions.last.body
    assert_kind_of AST::VariableDecl, body[0]
    assert_equal "T", body[0].name
    ret = body[1]
    assert_kind_of AST::VariableRef, ret.expr
    assert_equal "T", ret.expr.name
  end

  # --- enum (Step 18) -----------------------------------------------------

  def test_enum_specifier_resolves_to_int
    decl = parse_body_item("enum Color { RED, GREEN, BLUE };", "enum Color c; return 0;")
    assert_kind_of AST::VariableDecl, decl
    assert_equal Type::Int, decl.type
  end

  def test_enumerators_default_to_consecutive_values_from_zero
    # RED=0, GREEN=1, BLUE=2, folded to int literals at their use sites.
    program = parse("enum Color { RED, GREEN, BLUE }; " \
                    "int main(void) { return RED + GREEN + BLUE; }")
    expr = program.functions.last.body.first.expr
    # (RED + GREEN) + BLUE = (0 + 1) + 2
    assert_equal 2, expr.rhs.value
    assert_equal 1, expr.lhs.rhs.value
    assert_equal 0, expr.lhs.lhs.value
  end

  def test_enumerator_explicit_value_advances_the_next_default
    # A = 10, B = 11 (10 + 1), C = 20, D = 21.
    program = parse("enum E { A = 10, B, C = 20, D }; " \
                    "int main(void) { return D; }")
    expr = program.functions.last.body.first.expr
    assert_kind_of AST::IntLit, expr
    assert_equal 21, expr.value
  end

  def test_enumerator_folds_to_an_int_literal
    program = parse("enum E { LO = -2, HI = 5 }; int main(void) { return HI; }")
    expr = program.functions.last.body.first.expr
    assert_kind_of AST::IntLit, expr
    assert_equal 5, expr.value
    assert_equal Type::Int, expr.type
  end

  def test_enumerator_value_folds_a_constant_expression
    # "A" is bound to (1 << 4) - 1 == 15 before "B" is parsed, so "B" can refer
    # to it in its own constant expression, exactly like an earlier enumerator.
    program = parse("enum E { A = (1 << 4) - 1, B = A + 1 }; int main(void) { return B; }")
    expr = program.functions.last.body.first.expr
    assert_kind_of AST::IntLit, expr
    assert_equal 16, expr.value
  end

  def test_trailing_comma_in_enumerator_list_is_allowed
    decl = parse_body_item("enum E { A, B, };", "int x = B; return x;")
    assert_kind_of AST::VariableDecl, decl
    assert_equal 1, decl.initializer.value
  end

  def test_enum_constant_folds_in_a_case_label
    program = parse("enum Color { RED, GREEN }; int main(void) { int c = 1; " \
                    "switch (c) { case RED: return 0; case GREEN: return 1; } return 9; }")
    switch = program.functions.last.body[1]
    labels = switch.body.items
    assert_equal 0, labels[0].value
    assert_equal 1, labels[1].value
  end

  def test_local_variable_shadows_an_enum_constant
    # V is an enum constant at file scope but a variable inside main, so the
    # reference resolves to the variable, not the folded constant.
    program = parse("enum E { V = 7 }; int main(void) { int V = 3; return V; }")
    ret = program.functions.last.body[1]
    assert_kind_of AST::VariableRef, ret.expr
    assert_equal "V", ret.expr.name
  end
end
