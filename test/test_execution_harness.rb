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
    "int main(void) { int unused = 99; return 42; }"
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
