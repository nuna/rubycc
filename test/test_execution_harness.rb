# frozen_string_literal: true

require_relative "test_helper"

class TestExecutionHarness < Minitest::Test
  include ExecutionHelper

  def test_gcc_reference_path_reports_exit_status
    # Sanity check for the harness itself, using the system gcc as a
    # known-good reference compiler.
    assert_c_exit_status(42, "int main(void) { return 42; }", compiler: :gcc)
  end

  def test_returns_integer_literal
    assert_c_exit_status(42, "int main(void) { return 42; }", compiler: :rubycc)
  end

  def test_multiplication
    assert_c_exit_status(42, "int main(void) { return 6 * 7; }", compiler: :rubycc)
  end

  def test_precedence
    assert_c_exit_status(14, "int main(void) { return 2 + 3 * 4; }", compiler: :rubycc)
  end

  def test_parentheses
    assert_c_exit_status(20, "int main(void) { return (2 + 3) * 4; }", compiler: :rubycc)
  end

  def test_left_associativity
    assert_c_exit_status(42, "int main(void) { return 100 - 60 + 2; }", compiler: :rubycc)
  end

  def test_integer_division
    assert_c_exit_status(3, "int main(void) { return 7 / 2; }", compiler: :rubycc)
  end

  def test_modulo
    assert_c_exit_status(2, "int main(void) { return 17 % 5; }", compiler: :rubycc)
  end

  def test_nested_unary_minus
    assert_c_exit_status(42, "int main(void) { return -(-42); }", compiler: :rubycc)
  end

  def test_unary_plus
    assert_c_exit_status(42, "int main(void) { return +42; }", compiler: :rubycc)
  end

  def test_negative_intermediate_value
    assert_c_exit_status(42, "int main(void) { return 10 - 20 + 52; }", compiler: :rubycc)
  end

  def test_implicit_return_zero
    assert_c_exit_status(0, "int main(void) { }", compiler: :rubycc)
  end

  def test_variable_declaration_with_initializer
    assert_c_exit_status(42, "int main(void) { int x = 6; return x * 7; }", compiler: :rubycc)
  end

  def test_assignment_to_declared_variable
    assert_c_exit_status(42, "int main(void) { int x; x = 40; x = x + 2; return x; }", compiler: :rubycc)
  end

  def test_comma_separated_declarations
    assert_c_exit_status(42, "int main(void) { int a = 5, b = 7; return a * b + a + 2; }", compiler: :rubycc)
  end

  def test_assignment_expression_has_a_value
    assert_c_exit_status(42, "int main(void) { int x; return x = 42; }", compiler: :rubycc)
  end

  def test_chained_assignment_is_right_associative
    assert_c_exit_status(42, "int main(void) { int a; int b; a = b = 21; return a + b; }", compiler: :rubycc)
  end

  def test_mixed_declarations_and_statements
    assert_c_exit_status(42, "int main(void) { int x = 1; x = x + 1; int y = 40; return x + y; }", compiler: :rubycc)
  end

  def test_empty_statements
    assert_c_exit_status(42, "int main(void) { ; ; return 42; }", compiler: :rubycc)
  end

  def test_unused_variable
    assert_c_exit_status(42, "int main(void) { int unused = 99; return 42; }", compiler: :rubycc)
  end

  def test_relational_less_than_true
    assert_c_exit_status(1, "int main(void) { return 1 < 2; }", compiler: :rubycc)
  end

  def test_relational_less_than_false
    assert_c_exit_status(0, "int main(void) { return 2 < 1; }", compiler: :rubycc)
  end

  def test_relational_less_or_equal
    assert_c_exit_status(1, "int main(void) { return 2 <= 2; }", compiler: :rubycc)
  end

  def test_relational_greater_than
    assert_c_exit_status(1, "int main(void) { return 3 > 2; }", compiler: :rubycc)
  end

  def test_relational_greater_or_equal_false
    assert_c_exit_status(0, "int main(void) { return 2 >= 3; }", compiler: :rubycc)
  end

  def test_equality_true
    assert_c_exit_status(1, "int main(void) { return 42 == 42; }", compiler: :rubycc)
  end

  def test_equality_false
    assert_c_exit_status(0, "int main(void) { return 42 != 42; }", compiler: :rubycc)
  end

  def test_additive_binds_tighter_than_equality
    assert_c_exit_status(1, "int main(void) { return 1 + 1 == 2; }", compiler: :rubycc)
  end

  def test_relational_binds_tighter_than_equality
    assert_c_exit_status(1, "int main(void) { return 0 < 1 == 1; }", compiler: :rubycc)
  end

  def test_logical_not_of_zero
    assert_c_exit_status(1, "int main(void) { return !0; }", compiler: :rubycc)
  end

  def test_logical_not_of_nonzero
    assert_c_exit_status(0, "int main(void) { return !5; }", compiler: :rubycc)
  end

  def test_double_logical_not
    assert_c_exit_status(1, "int main(void) { return !!42; }", compiler: :rubycc)
  end

  def test_comparison_result_is_an_int_value
    assert_c_exit_status(42, "int main(void) { int x = 1 < 2; return x * 42; }", compiler: :rubycc)
  end

  def test_if_taken_branch_returns
    assert_c_exit_status(42, "int main(void) { if (1) return 42; return 7; }", compiler: :rubycc)
  end

  def test_if_not_taken_falls_through
    assert_c_exit_status(42, "int main(void) { if (0) return 7; return 42; }", compiler: :rubycc)
  end

  def test_if_else_takes_else_branch
    assert_c_exit_status(42, "int main(void) { if (0) return 7; else return 42; }", compiler: :rubycc)
  end

  def test_else_if_chain
    assert_c_exit_status(
      42,
      "int main(void) { int x = 2; if (x == 1) return 1; else if (x == 2) return 42; else return 3; }",
      compiler: :rubycc
    )
  end

  def test_dangling_else_binds_to_nearest_if
    assert_c_exit_status(42, "int main(void) { if (1) if (0) return 7; else return 42; return 9; }", compiler: :rubycc)
  end

  def test_block_statement_introduces_scope
    assert_c_exit_status(42, "int main(void) { if (1) { int x = 40; return x + 2; } return 7; }", compiler: :rubycc)
  end

  def test_inner_declaration_shadows_outer
    assert_c_exit_status(42, "int main(void) { int x = 1; { int x = 100; x = 41; } return x + 41; }", compiler: :rubycc)
  end

  def test_nested_if_inside_blocks
    assert_c_exit_status(
      42,
      "int main(void) { int a = 1; int b = 2; if (a == 1) { if (b == 2) { return 42; } } return 7; }",
      compiler: :rubycc
    )
  end

  # N7: differential test against gcc. Compile the same source with both
  # compilers and assert the process exit codes agree.
  DIFFERENTIAL_SOURCES = [
    "int main(void) { return 42; }",
    "int main(void) { return 6 * 7; }",
    "int main(void) { return 2 + 3 * 4; }",
    "int main(void) { return (2 + 3) * 4; }",
    "int main(void) { return 100 - 60 + 2; }",
    "int main(void) { return 7 / 2; }",
    "int main(void) { return 17 % 5; }",
    "int main(void) { return -(-42); }",
    "int main(void) { return 10 - 20 + 52; }",
    "int main(void) { }",
    "int main(void) { int x = 6; return x * 7; }",
    "int main(void) { int x; x = 40; x = x + 2; return x; }",
    "int main(void) { int a = 5, b = 7; return a * b + a + 2; }",
    "int main(void) { int x; return x = 42; }",
    "int main(void) { int a; int b; a = b = 21; return a + b; }",
    "int main(void) { int x = 1; x = x + 1; int y = 40; return x + y; }",
    "int main(void) { ; ; return 42; }",
    "int main(void) { int unused = 99; return 42; }",
    "int main(void) { return 1 < 2; }",
    "int main(void) { return 2 < 1; }",
    "int main(void) { return 2 <= 2; }",
    "int main(void) { return 3 > 2; }",
    "int main(void) { return 2 >= 3; }",
    "int main(void) { return 42 == 42; }",
    "int main(void) { return 42 != 42; }",
    "int main(void) { return 1 + 1 == 2; }",
    "int main(void) { return 0 < 1 == 1; }",
    "int main(void) { return !0; }",
    "int main(void) { return !5; }",
    "int main(void) { return !!42; }",
    "int main(void) { int x = 1 < 2; return x * 42; }",
    "int main(void) { if (1) return 42; return 7; }",
    "int main(void) { if (0) return 7; return 42; }",
    "int main(void) { if (0) return 7; else return 42; }",
    "int main(void) { int x = 2; if (x == 1) return 1; else if (x == 2) return 42; else return 3; }",
    "int main(void) { if (1) if (0) return 7; else return 42; return 9; }",
    "int main(void) { if (1) { int x = 40; return x + 2; } return 7; }",
    "int main(void) { int x = 1; { int x = 100; x = 41; } return x + 41; }",
    "int main(void) { int a = 1; int b = 2; if (a == 1) { if (b == 2) { return 42; } } return 7; }"
  ].freeze

  def test_matches_gcc_exit_codes
    DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  private

  def run_source(source, compiler:)
    in_tmpdir do |dir|
      object_path = File.join(dir, "test.o")
      case compiler
      when :rubycc then compile_with_rubycc(source, object_path)
      when :gcc then compile_with_gcc(source, object_path)
      end
      link_and_run(object_path)
    end
  end
end
