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

  # Step 14 resolves Step 9's intentional deviation: a pointer is a valid
  # scalar condition (its truth is "is not null"), so these once-rejected
  # forms now compile. Their run-time behavior is covered in the execution
  # harness; here we assert only that they no longer raise a diagnostic.
  def test_pointer_used_as_if_condition_is_accepted
    source = "int main(void) { int *p; if (p) return 1; return 0; }"
    assert_kind_of String, compile(source)
  end

  def test_pointer_used_as_while_condition_is_accepted
    source = "int main(void) { int *p; while (p) p = p; return 0; }"
    assert_kind_of String, compile(source)
  end

  def test_pointer_used_as_logical_and_operand_is_accepted
    source = "int main(void) { int *p; return p && 1; }"
    assert_kind_of String, compile(source)
  end

  def test_pointer_used_as_logical_or_operand_is_accepted
    source = "int main(void) { int *p; return 1 || p; }"
    assert_kind_of String, compile(source)
  end

  def test_pointer_used_as_logical_not_operand_is_accepted
    source = "int main(void) { int *p; return !p; }"
    assert_kind_of String, compile(source)
  end

  def test_pointer_used_as_conditional_operator_condition_is_accepted
    source = "int main(void) { int *p; int x; return p ? x : x; }"
    assert_kind_of String, compile(source)
  end

  # A struct still has no truth value, so it remains an illegal condition.
  def test_struct_used_as_if_condition_is_rejected
    source = "struct s { int x; }; int main(void) { struct s v; if (v) return 1; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/used struct type value where scalar is required/, error.description)
    assert_match(/foo\.c:1:\d+: error: used struct type value where scalar is required/, error.message)
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

  # Step 15: the bitwise and shift operators take arithmetic operands only, so
  # a pointer or struct operand is rejected as an invalid binary operand.
  def test_bitwise_and_of_pointer_is_rejected
    source = "int main(void) { int *p; return p & 1; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_left_shift_of_pointer_is_rejected
    source = "int main(void) { int *p; return p << 1; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_bitwise_not_of_pointer_is_rejected
    # "~p" desugars to "p ^ -1", so an xor of a pointer is the invalid operand.
    source = "int main(void) { int *p; return ~p; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_bitwise_or_of_struct_is_rejected
    source = "struct s { int x; }; int main(void) { struct s v; return v | 1; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_bitwise_compound_assignment_with_pointer_target_is_rejected
    source = "int main(void) { int *p; p &= 1; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_shift_compound_assignment_with_pointer_target_is_rejected
    source = "int main(void) { int *p; p <<= 1; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_assigning_char_pointer_to_int_pointer_is_rejected
    source = "int main(void) { char *c; int *p; p = c; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible types in assignment/, error.description)
  end

  def test_char_pointer_argument_to_int_pointer_parameter_is_rejected
    source = "int f(int *p) { return 0; } int main(void) { char *c; return f(c); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible type for argument 1 of 'f'/, error.description)
  end

  def test_comparing_char_pointer_with_int_pointer_is_rejected
    source = "int main(void) { char *c; int *p; return c < p; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_subtracting_mismatched_char_and_int_pointers_is_rejected
    source = "int main(void) { char *c; int *p; return p - c; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_void_variable_declaration_is_rejected
    source = "int main(void) { void x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal 1, error.line
    assert_match(/variable or field declared void/, error.description)
    assert_match(/foo\.c:1:\d+: error: variable or field declared void/, error.message)
  end

  def test_sizeof_void_is_rejected
    source = "int main(void) { return sizeof(void); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid application of 'sizeof' to void type/, error.description)
  end

  def test_void_function_result_used_as_a_value_is_rejected
    source = "void f(void) { return; } int main(void) { return f() + 1; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/void value not ignored as it ought to be/, error.description)
  end

  def test_return_without_a_value_in_non_void_function_is_rejected
    source = "int main(void) { return; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/return without a value/, error.description)
  end

  def test_return_with_a_value_in_void_function_is_rejected
    source = "void f(void) { return 1; } int main(void) { f(); return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/return with a value in void function/, error.description)
  end

  def test_return_type_mismatch_is_rejected
    source = "int *f(void) { return 1; } int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible return type/, error.description)
  end

  def test_void_return_is_still_valid_in_void_function
    source = "void f(void) { return; } int main(void) { f(); return 42; }"
    assert_kind_of String, compile(source)
  end

  def test_pointer_arithmetic_on_void_pointer_is_rejected
    source = "int main(void) { void *p; p = p + 1; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid use of void pointer/, error.description)
  end

  def test_dereferencing_void_pointer_is_rejected
    source = "int main(void) { void *p; return *p; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid use of void pointer/, error.description)
  end

  def test_conflicting_return_types_between_prototype_and_definition
    source = "int f(void); char f(void) { return 0; } int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/conflicting types for 'f'/, error.description)
  end

  def test_global_redefinition_is_rejected
    source = "int g; int g = 1; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/redefinition of 'g'/, error.description)
    assert_match(/foo\.c:1:\d+: error: redefinition of 'g'/, error.message)
  end

  def test_global_conflicting_with_function_is_rejected
    source = "int f; int f(void) { return 0; } int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redefinition of 'f'/, error.description)
  end

  def test_non_constant_global_initializer_is_rejected
    source = "int a = 1; int b = a; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal 1, error.line
    assert_match(/unsupported initializer for global variable/, error.description)
    assert_match(%r{foo\.c:1:\d+: error: unsupported initializer for global variable}, error.message)
  end

  def test_global_expression_initializer_is_rejected
    source = "int g = 1 + 2; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/unsupported initializer for global variable/, error.description)
  end

  def test_global_array_initializer_is_rejected
    source = "int a[3] = 0; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/unsupported initializer for global variable/, error.description)
  end

  def test_global_string_initializer_is_rejected
    source = "char *s = \"hi\"; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/unsupported initializer for global variable/, error.description)
  end

  def test_undeclared_global_uses_the_undeclared_variable_error
    source = "int main(void) { return missing; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/undeclared variable 'missing'/, error.description)
  end

  # --- structs ------------------------------------------------------------

  def test_variable_of_undefined_struct_tag_is_rejected
    source = "int main(void) { struct undefined x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/invalid use of incomplete type 'struct undefined'/, error.description)
    assert_match(%r{foo\.c:1:\d+: error: invalid use of incomplete type 'struct undefined'}, error.message)
  end

  def test_variable_of_forward_declared_struct_is_rejected
    source = "struct node; int main(void) { struct node n; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid use of incomplete type 'struct node'/, error.description)
  end

  def test_global_of_incomplete_struct_is_rejected
    source = "struct node; struct node g; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid use of incomplete type 'struct node'/, error.description)
  end

  def test_sizeof_incomplete_struct_type_is_rejected
    source = "struct node; int main(void) { return sizeof(struct node); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid use of incomplete type 'struct node'/, error.description)
  end

  def test_member_that_does_not_exist_is_rejected
    source = "struct s { int x; }; int main(void) { struct s v; return v.y; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal 1, error.line
    assert_match(/no member named 'y' in 'struct s'/, error.description)
    assert_match(%r{foo\.c:1:\d+: error: no member named 'y' in 'struct s'}, error.message)
  end

  def test_dot_on_non_struct_is_rejected
    source = "int main(void) { int x; return x.a; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/request for member 'a' in something not a structure/, error.description)
  end

  def test_arrow_on_non_pointer_is_rejected
    source = "struct s { int x; }; int main(void) { struct s v; return v->x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/request for member 'x' in something not a structure/, error.description)
  end

  def test_arrow_on_pointer_to_non_struct_is_rejected
    source = "int main(void) { int *p; return p->x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/request for member 'x' in something not a structure/, error.description)
  end

  def test_struct_parameter_is_rejected
    source = "struct s { int x; }; int f(struct s v) { return v.x; } " \
             "int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/struct parameters are not supported yet/, error.description)
  end

  def test_struct_return_value_is_rejected
    source = "struct s { int x; }; struct s f(void) { struct s v; return v; } " \
             "int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/struct return values are not supported yet/, error.description)
  end

  def test_arithmetic_on_struct_is_rejected
    source = "struct s { int x; }; " \
             "int main(void) { struct s a; struct s b; return a + b; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_struct_by_value_member_is_rejected
    source = "struct s { struct s inner; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/field 'inner' has incomplete type/, error.description)
  end

  def test_void_struct_member_is_rejected
    source = "struct s { void v; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/variable or field declared void/, error.description)
  end

  def test_struct_redefinition_is_rejected
    source = "struct s { int x; }; struct s { int y; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redefinition of 'struct s'/, error.description)
  end

  def test_duplicate_struct_member_is_rejected
    source = "struct s { int x; int x; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/duplicate member 'x'/, error.description)
  end

  def test_assigning_between_different_struct_types_is_rejected
    source = "struct a { int x; }; struct b { int x; }; " \
             "int main(void) { struct a p; struct b q; p = q; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible types in assignment/, error.description)
  end

  def test_global_struct_initializer_is_rejected
    source = "struct s { int x; }; struct s g = 0; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/unsupported initializer for global variable/, error.description)
  end

  # --- casts and null pointer constants (Step 14) -------------------------

  def test_cast_from_pointer_to_integer_is_rejected
    source = "int main(void) { int *p; return (int)p; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal 1, error.line
    assert_match(/cast between pointer and integer is not supported yet/, error.description)
    assert_match(%r{foo\.c:1:\d+: error: cast between pointer and integer}, error.message)
  end

  def test_cast_from_nonzero_integer_to_pointer_is_rejected
    # Only a null pointer constant (a literal 0) crosses the pointer/integer
    # boundary; any other integer needs a pointer-width integer type that does
    # not exist yet.
    source = "int main(void) { int *p; p = (int *)5; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/cast between pointer and integer is not supported yet/, error.description)
  end

  def test_cast_to_struct_type_is_rejected
    source = "struct s { int x; }; int main(void) { struct s v; return (struct s)v; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/conversion to non-scalar type requested/, error.description)
  end

  def test_cast_to_incomplete_struct_type_is_rejected
    source = "struct node; int main(void) { int *p; return (struct node)p; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/conversion to non-scalar type requested/, error.description)
  end

  def test_cast_from_struct_to_pointer_is_rejected
    source = "struct s { int x; }; int main(void) { struct s v; return (int *)v == 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/cannot cast 'struct s' to 'int \*'/, error.description)
  end

  def test_comparing_pointer_with_nonzero_integer_is_rejected
    # A null pointer constant is the literal 0 only; "p == 1" stays a type
    # error, since 1 is not a null pointer constant.
    source = "int main(void) { int *p; return p == 1; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_relational_comparison_of_pointer_with_zero_is_rejected
    # Only "==" / "!=" admit a null pointer constant; "<" against 0 is still a
    # type error (its result would be undefined in C anyway).
    source = "int main(void) { int *p; return p < 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_void_cast_result_used_as_a_value_is_rejected
    source = "int main(void) { int x; return (void)x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/void value not ignored as it ought to be/, error.description)
  end
end
