# frozen_string_literal: true

require_relative "test_helper"

class TestDiagnostics < Minitest::Test
  def compile(source, filename: "foo.c")
    Rubycc::Compiler.new.compile(source, filename: filename)
  end

  def test_missing_semicolon_message_has_full_diagnostic
    source = "int main(void) { return 42 }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    # Structured attributes (N3).
    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_equal 28, error.column # the unexpected '}'
    assert_equal source, error.source_line
    assert_match(/expected ';'/, error.description)

    # Rendered message: header, source excerpt, and a caret line.
    lines = error.message.split("\n")
    assert_equal "foo.c:1:28: error: expected ';'", lines[0]
    assert_equal source, lines[1]
    assert_equal "#{" " * 27}^", lines[2] # caret under column 28
  end

  def test_message_includes_filename_line_and_column
    source = "int main(void) {\n  return 1 +\n}"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_match(/foo\.c:/, error.message)
    assert_includes error.message, "error:"
    # Caret line consists of spaces followed by a single caret.
    caret_line = error.message.split("\n").last
    assert_match(/\A *\^\z/, caret_line)
  end

  def test_undeclared_variable_message_has_full_diagnostic
    source = "int main(void) { return x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/undeclared variable 'x'/, error.description)
    assert_match(/foo\.c:1:\d+: error: undeclared variable 'x'/, error.message)
  end

  def test_redeclaration_message_has_full_diagnostic
    source = "int main(void) { int x; int x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/redeclaration of 'x'/, error.description)
    assert_match(/foo\.c:1:\d+: error: redeclaration of 'x'/, error.message)
  end

  def test_same_scope_redeclaration_is_still_an_error
    source = "int main(void) { int x; int x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redeclaration of 'x'/, error.description)
  end

  def test_inner_scope_shadowing_is_not_an_error
    # Re-declaring 'x' in a nested block shadows the outer 'x' rather than
    # colliding with it, so compilation must succeed.
    source = "int main(void) { int x = 1; { int x = 2; return x; } }"
    assert_kind_of String, compile(source)
  end

  def test_variable_declared_in_block_is_not_visible_outside
    source = "int main(void) { { int x = 1; } return x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/undeclared variable 'x'/, error.description)
  end

  def test_break_outside_loop_message_has_full_diagnostic
    source = "int main(void) { break; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/break statement not within a loop/, error.description)
    assert_match(/foo\.c:1:\d+: error: break statement not within a loop/, error.message)
  end

  def test_continue_outside_loop_message_has_full_diagnostic
    source = "int main(void) { continue; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/continue statement not within a loop/, error.description)
    assert_match(/foo\.c:1:\d+: error: continue statement not within a loop/, error.message)
  end

  def test_break_inside_if_but_outside_loop_is_still_an_error
    source = "int main(void) { if (1) break; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/break statement not within a loop/, error.description)
  end

  def test_implicit_declaration_of_function
    source = "int main(void) { return f(1); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/implicit declaration of function 'f'/, error.description)
    assert_match(/foo\.c:1:\d+: error: implicit declaration of function 'f'/, error.message)
  end

  def test_too_few_arguments_to_function
    source = "int f(int a, int b) { return a + b; } int main(void) { return f(1); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/too few arguments to function 'f'/, error.description)
  end

  def test_too_many_arguments_to_function
    source = "int f(int a) { return a; } int main(void) { return f(1, 2); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/too many arguments to function 'f'/, error.description)
  end

  def test_redefinition_of_function
    source = "int f(void) { return 1; } int f(void) { return 2; } int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redefinition of 'f'/, error.description)
  end

  def test_conflicting_types_between_prototype_and_definition
    source = "int f(int a); int f(int a, int b) { return a + b; } int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/conflicting types for 'f'/, error.description)
  end

  def test_too_many_parameters
    source = "int f(int a, int b, int c, int d, int e, int g, int h) { return a; } " \
             "int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/too many parameters \(rubycc supports up to 6\)/, error.description)
  end

  def test_parameter_name_omitted_in_definition
    source = "int f(int a, int) { return a; } int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/parameter name omitted/, error.description)
  end

  def test_dereference_of_non_pointer_is_rejected
    source = "int main(void) { int x; return *x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/invalid type argument of unary '\*'/, error.description)
    assert_match(%r{foo\.c:1:\d+: error: invalid type argument of unary '\*'}, error.message)
  end

  def test_address_of_non_lvalue_is_rejected
    source = "int main(void) { return &1; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal 1, error.line
    assert_match(/lvalue required as unary '&' operand/, error.description)
    assert_match(/foo\.c:1:\d+: error: lvalue required as unary '&' operand/, error.message)
  end

  def test_assigning_pointer_to_int_is_a_type_error
    source = "int main(void) { int x; int *p; x = p; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal 1, error.line
    assert_match(/incompatible types in assignment/, error.description)
    assert_match(/foo\.c:1:\d+: error: incompatible types in assignment/, error.message)
  end

  def test_assigning_int_to_pointer_is_a_type_error
    source = "int main(void) { int *p; int x; p = x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible types in assignment/, error.description)
  end

  def test_pointer_argument_type_mismatch_is_rejected
    source = "int f(int *p) { return 0; } int main(void) { int x; return f(x); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal 1, error.line
    assert_match(/incompatible type for argument 1 of 'f'/, error.description)
    assert_match(/foo\.c:1:\d+: error: incompatible type for argument 1 of 'f'/, error.message)
  end

  def test_int_argument_to_pointer_parameter_is_rejected
    source = "int f(int a, int *p) { return a; } " \
             "int main(void) { int x; return f(1, 2); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible type for argument 2 of 'f'/, error.description)
  end

  def test_assigning_to_an_array_is_rejected
    source = "int main(void) { int a[3]; int *p; a = p; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal 1, error.line
    assert_match(/array type is not assignable/, error.description)
    assert_match(/foo\.c:1:\d+: error: array type is not assignable/, error.message)
  end

  def test_address_of_whole_array_is_rejected
    source = "int main(void) { int a[3]; return &a == 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal 1, error.line
    assert_match(/address of array is not supported yet/, error.description)
  end

  def test_subscripting_an_int_is_rejected
    source = "int main(void) { int x; return x[0]; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/subscripted value is neither array nor pointer/, error.description)
  end

  def test_adding_two_pointers_is_rejected
    source = "int main(void) { int a[4]; int *p; int *q; p = a; q = a; return p + q; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_arithmetic_on_mismatched_pointer_types_is_rejected
    source = "int main(void) { int *p; int **q; return q - p; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_comparing_mismatched_pointer_types_is_rejected
    source = "int main(void) { int *p; int **q; return p < q; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_comparing_pointer_with_int_is_rejected
    source = "int main(void) { int *p; return p < 1; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_multidimensional_array_is_rejected
    source = "int main(void) { int a[3][4]; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/multidimensional arrays are not supported yet/, error.description)
  end

  def test_array_initializer_is_rejected
    source = "int main(void) { int a[3] = 0; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/array initializers are not supported yet/, error.description)
  end

  def test_pointer_used_as_if_condition_is_rejected
    source = "int main(void) { int *p; if (p) return 1; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/used pointer where scalar int is required/, error.description)
    assert_match(/foo\.c:1:\d+: error: used pointer where scalar int is required/, error.message)
  end

  def test_pointer_used_as_while_condition_is_rejected
    source = "int main(void) { int *p; while (p) p = p; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/used pointer where scalar int is required/, error.description)
  end

  def test_pointer_used_as_logical_and_operand_is_rejected
    source = "int main(void) { int *p; return p && 1; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/used pointer where scalar int is required/, error.description)
  end

  def test_pointer_used_as_logical_or_operand_is_rejected
    source = "int main(void) { int *p; return 1 || p; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/used pointer where scalar int is required/, error.description)
  end

  def test_pointer_used_as_logical_not_operand_is_rejected
    source = "int main(void) { int *p; return !p; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/used pointer where scalar int is required/, error.description)
  end

  def test_pointer_used_as_conditional_operator_condition_is_rejected
    source = "int main(void) { int *p; int x; return p ? x : x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/used pointer where scalar int is required/, error.description)
  end

  def test_conditional_operator_type_mismatch_is_rejected
    source = "int main(void) { int *p; int x; return 1 ? x : p; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal 1, error.line
    assert_match(/type mismatch in conditional expression/, error.description)
    assert_match(/foo\.c:1:\d+: error: type mismatch in conditional expression/, error.message)
  end

  def test_increment_of_non_lvalue_is_rejected
    source = "int main(void) { return ++1; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/expression is not assignable/, error.description)
  end

  def test_compound_assignment_multiply_with_pointer_target_is_rejected
    source = "int main(void) { int *p; int x; p *= x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end
end
