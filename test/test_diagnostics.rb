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

  def test_duplicate_case_value_is_an_error
    source = "int main(void) { int x = 0; switch (x) { case 1: return 1; case 1: return 2; } return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/duplicate case value '1'/, error.description)
  end

  def test_duplicate_default_label_is_an_error
    source = "int main(void) { int x = 0; switch (x) { default: return 1; default: return 2; } return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/multiple default labels in one switch/, error.description)
  end

  def test_case_outside_switch_is_an_error
    source = "int main(void) { case 1: return 1; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/case label not within a switch statement/, error.description)
  end

  def test_default_outside_switch_is_an_error
    source = "int main(void) { default: return 1; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'default' label not within a switch statement/, error.description)
  end

  def test_non_constant_case_expression_is_an_error
    source = "int main(void) { int y = 1; int x = 0; switch (x) { case y: return 1; } return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/case label does not reduce to an integer constant/, error.description)
  end

  def test_pointer_switch_control_is_an_error
    source = "int main(void) { int a; int *p = &a; switch (p) { case 1: return 1; } return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/switch quantity is not an integer/, error.description)
  end

  def test_struct_switch_control_is_an_error
    source = "struct S { int a; }; int main(void) { struct S s; switch (s) { case 1: return 1; } return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/switch quantity is not an integer/, error.description)
  end

  def test_duplicate_label_is_an_error
    source = "int main(void) { a: ; a: ; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/duplicate label 'a'/, error.description)
  end

  def test_goto_to_undefined_label_is_an_error
    source = "int main(void) { goto missing; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/label 'missing' used but not defined/, error.description)
  end

  def test_continue_in_switch_outside_loop_is_an_error
    # A continue inside a switch but with no enclosing loop has no loop target,
    # so it is diagnosed even though a break there would be legal.
    source = "int main(void) { int x = 0; switch (x) { case 0: continue; } return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/continue statement not within a loop/, error.description)
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

  # Step 23 Phase A: a variadic call still requires every fixed parameter.
  def test_too_few_arguments_to_variadic_function
    source = "int f(int a, int b, ...) { return a + b; } int main(void) { return f(1); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/too few arguments to function 'f'/, error.description)
  end

  # A fixed parameter of a variadic function is still type-checked (only the
  # variable part escapes the assignment-compatibility check).
  def test_fixed_argument_type_mismatch_to_variadic_function
    source = "int f(int *p, ...) { return 0; } int main(void) { return f(3); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible type for argument 1 of 'f'/, error.description)
  end

  # A struct has no promoted form the variable part can carry here.
  def test_struct_passed_to_variadic_function_is_rejected
    source = "struct p { int x; }; int f(int a, ...) { return a; } " \
             "int main(void) { struct p s; return f(1, s); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/passing a struct to a variadic function is not supported yet/, error.description)
  end

  # A variadic/non-variadic mismatch makes the function-pointer signatures
  # differ, so assigning a variadic function to a non-variadic pointer fails.
  def test_variadic_mismatch_function_pointer_assignment_is_rejected
    source = "int f(const char *fmt, ...); int g(const char *fmt); " \
             "int main(void) { int (*fp)(const char *) = g; fp = f; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible types in assignment/, error.description)
  end

  # Step 23 Phase B: va_start needs a variable part to anchor on, so it is
  # rejected in a function with a fixed parameter list.
  def test_va_start_in_fixed_arity_function_is_rejected
    source = "int f(int a) { __builtin_va_list ap; __builtin_va_start(ap, a); return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'va_start' used in function with fixed arguments/, error.description)
  end

  # The second argument to va_start must name the last fixed parameter.
  def test_va_start_wrong_last_parameter_is_rejected
    source = "int f(int a, int b, ...) { __builtin_va_list ap; __builtin_va_start(ap, a); return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/second argument to 'va_start' is not the last named parameter/, error.description)
  end

  # va_arg of a promotable type (char/short/_Bool) would read the wrong width,
  # since the argument was promoted to int at the call.
  def test_va_arg_of_promotable_type_is_rejected
    source = "int f(int a, ...) { __builtin_va_list ap; __builtin_va_start(ap, a); " \
             "return __builtin_va_arg(ap, char); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/second argument to 'va_arg' is of promotable type 'char'/, error.description)
  end

  # va_arg of a struct has no scalar argument slot to read here.
  def test_va_arg_of_struct_type_is_rejected
    source = "struct p { int x; }; int f(int a, ...) { __builtin_va_list ap; " \
             "__builtin_va_start(ap, a); struct p s = __builtin_va_arg(ap, struct p); return s.x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/second argument to 'va_arg' has type 'struct p', which va_arg cannot yield/, error.description)
  end

  # A va_* builtin's first argument must be a va_list (a __va_list_tag pointer),
  # not an arbitrary scalar.
  def test_va_start_first_argument_wrong_type_is_rejected
    source = "int f(int a, ...) { int ap; __builtin_va_start(ap, a); return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/first argument to 'va_start' is not of type '__builtin_va_list'/, error.description)
  end

  # Step 21: calling a non-function, non-pointer value is rejected.
  def test_calling_a_non_function_is_rejected
    source = "int main(void) { int x = 3; return x(1); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/called object is not a function or function pointer/, error.description)
  end

  # A function pointer may only be assigned a pointer to a function with the
  # very same signature; a differing arity or parameter type is incompatible.
  def test_incompatible_signature_function_pointer_assignment_is_rejected
    source = "int f(int a); int g(int a, int b); " \
             "int main(void) { int (*fp)(int) = f; fp = g; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible types in assignment/, error.description)
  end

  # An indirect call through a function pointer checks the argument count, just
  # like a direct call, but names the callee generically.
  def test_too_few_arguments_through_function_pointer_is_rejected
    source = "int f(int a, int b); " \
             "int main(void) { int (*fp)(int, int) = f; return fp(1); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/too few arguments to function pointer/, error.description)
  end

  def test_too_many_arguments_through_function_pointer_is_rejected
    source = "int f(int a); " \
             "int main(void) { int (*fp)(int) = f; return fp(1, 2); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/too many arguments to function pointer/, error.description)
  end

  # An indirect call also checks each argument's type against the pointed-to
  # function's parameter types.
  def test_argument_type_mismatch_through_function_pointer_is_rejected
    source = "int f(int *p); " \
             "int main(void) { int (*fp)(int *) = f; return fp(3); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible type for argument 1/, error.description)
  end

  # sizeof cannot be applied to a function designator (a function has no size).
  def test_sizeof_function_designator_is_rejected
    source = "int f(int a); int main(void) { return sizeof f; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid application of 'sizeof' to a function type/, error.description)
  end

  def test_conflicting_types_between_prototype_and_definition
    source = "int f(int a); int f(int a, int b) { return a + b; } int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/conflicting types for 'f'/, error.description)
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

  def test_array_initialized_from_a_scalar_is_rejected
    # An array is initialized by a brace list (or, for a char array, a string),
    # never by a bare scalar expression.
    source = "int main(void) { int a[3] = 0; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid initializer for array/, error.description)
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
    # Two *initialized* definitions are a redefinition (6.9.2); a tentative
    # definition followed by one initializer is not (see the tentative tests).
    source = "int g = 0; int g = 1; int main(void) { return 0; }"
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

  def test_global_function_call_initializer_is_rejected
    # A global's initializer is a constant-expression (6.6); a function call
    # is never one, even though "1 + 2" now folds to a plain constant.
    source = "int f(void); int g = f(); int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/unsupported initializer for global variable/, error.description)
  end

  def test_global_array_initializer_is_rejected
    source = "int a[3] = 0; int main(void) { return 0; }"
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

  def test_incomplete_struct_parameter_is_rejected
    # A struct passed by value needs a known layout for its eightbyte
    # classification; an incomplete (never-defined) tag is rejected up front.
    source = "struct s; int f(struct s v); " \
             "int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/parameter has incomplete type/, error.description)
  end

  def test_incomplete_struct_return_type_is_rejected
    source = "struct s; struct s f(void); " \
             "int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/return type is an incomplete type/, error.description)
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

  # --- unions and anonymous members --------------------------------------

  def test_struct_tag_redeclared_as_union_is_rejected
    source = "struct S { int x; }; int main(void) { union S u; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'S' defined as wrong kind of tag/, error.description)
  end

  def test_union_tag_redeclared_as_struct_is_rejected
    source = "union S { int x; }; struct S { int y; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'S' defined as wrong kind of tag/, error.description)
  end

  def test_union_tag_reused_as_enum_is_rejected
    source = "union S { int x; }; int main(void) { return sizeof(enum S); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'S' defined as wrong kind of tag/, error.description)
  end

  def test_variable_of_incomplete_union_is_rejected
    source = "union u; int main(void) { union u v; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid use of incomplete type 'union u'/, error.description)
  end

  def test_union_redefinition_is_rejected
    source = "union u { int x; }; union u { int y; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redefinition of 'union u'/, error.description)
  end

  def test_member_name_clashing_through_anonymous_member_is_rejected
    source = "struct s { union { int a; int b; }; int a; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/duplicate member 'a'/, error.description)
  end

  def test_tagged_member_without_declarator_declares_nothing
    source = "struct s { struct inner { int y; }; int x; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/declaration does not declare anything/, error.description)
  end

  def test_forward_declared_tag_without_declarator_declares_nothing
    source = "struct s { struct inner; int x; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/declaration does not declare anything/, error.description)
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

  # --- integer type extension (Step 17) -----------------------------------

  def test_signed_and_unsigned_together_is_rejected
    source = "int main(void) { signed unsigned x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/both 'signed' and 'unsigned' in declaration specifiers/, error.description)
  end

  def test_short_and_long_together_is_rejected
    source = "int main(void) { short long x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/both 'short' and 'long' in declaration specifiers/, error.description)
  end

  def test_duplicate_int_specifier_is_rejected
    source = "int main(void) { int int x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/duplicate 'int'/, error.description)
  end

  def test_more_than_two_longs_is_rejected
    source = "int main(void) { long long long x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/more than two 'long's in declaration specifiers/, error.description)
  end

  def test_void_combined_with_other_specifier_is_rejected
    source = "int main(void) { int void x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/cannot combine 'void' with other type specifiers/, error.description)
  end

  def test_bool_combined_with_other_specifier_is_rejected
    source = "int main(void) { _Bool int x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/cannot combine '_Bool' with other type specifiers/, error.description)
  end

  def test_char_with_size_specifier_is_rejected
    source = "int main(void) { char short x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/both 'char' and a size specifier in declaration specifiers/, error.description)
  end

  def test_integer_constant_too_large_is_rejected
    source = "int main(void) { unsigned long x = 99999999999999999999999999; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/integer constant is too large/, error.description)
  end

  def test_invalid_hexadecimal_constant_is_rejected
    source = "int main(void) { int x = 0x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid hexadecimal constant/, error.description)
  end

  def test_invalid_digit_in_octal_constant_is_rejected
    source = "int main(void) { int x = 08; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid digit in octal constant/, error.description)
  end

  def test_invalid_integer_suffix_is_rejected
    source = "int main(void) { int x = 1uu; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid suffix "uu" on integer constant/, error.description)
  end

  def test_unknown_letter_after_integer_constant_is_rejected
    source = "int main(void) { int x = 1z; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid suffix on integer constant/, error.description)
  end

  # --- typedef and enum (Step 18) -----------------------------------------

  def test_typedef_with_initializer_is_rejected
    source = "typedef int T = 1; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/typedef 'T' must not be initialized/, error.description)
  end

  def test_typedef_name_redefinition_is_rejected
    source = "typedef int T; typedef char T; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redefinition of typedef 'T'/, error.description)
  end

  def test_typedef_name_combined_with_type_specifier_is_rejected
    # "unsigned T x": once "unsigned" is seen, T is the declarator, so "x" is a
    # stray token — the same error gcc reports for this misuse.
    source = "typedef int T; int main(void) { unsigned T x; return 0; }"
    assert_raises(Rubycc::CompileError) { compile(source) }
  end

  def test_object_of_undefined_enum_tag_is_rejected
    # A forward-referenced enum tag is now allowed as an incomplete type (a
    # pointer target, a prototype return); an *object* of that type still needs a
    # size, so it is rejected as an incomplete type.
    source = "int main(void) { enum Missing x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid use of incomplete type 'enum Missing'/, error.description)
  end

  def test_struct_tag_reused_as_enum_is_rejected
    source = "struct S { int x; }; int main(void) { return sizeof(enum S); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'S' defined as wrong kind of tag/, error.description)
  end

  def test_enum_tag_reused_as_struct_is_rejected
    source = "enum E { A }; struct E { int x; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'E' defined as wrong kind of tag/, error.description)
  end

  def test_duplicate_enumerator_is_rejected
    source = "int main(void) { enum { A, A }; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redefinition of 'A'/, error.description)
  end

  def test_enumerator_colliding_with_variable_is_rejected
    source = "int main(void) { int v; enum { v }; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redefinition of 'v'/, error.description)
  end

  def test_non_constant_enumerator_value_is_rejected
    source = "int main(void) { int v = 0; enum { A = v }; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/enumerator value is not an integer constant/, error.description)
  end

  def test_enumerator_value_containing_an_assignment_is_rejected
    # An assignment is not itself a constant-expression, even parenthesized
    # inside one; "1 << 4" alone (no assignment) is fine (see test_parser.rb).
    source = "int main(void) { int v = 0; enum { A = (v = 1) }; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/enumerator value is not an integer constant/, error.description)
  end

  def test_case_label_calling_a_function_is_rejected
    source = "int f(void); int main(void) { switch (0) { case f(): return 1; } return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/case label does not reduce to an integer constant/, error.description)
  end

  def test_array_size_containing_an_assignment_is_rejected
    source = "int main(void) { int x = 0; int a[(x = 3)]; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/array size must be an integer constant/, error.description)
  end

  def test_negative_computed_array_size_is_rejected
    source = "int main(void) { int a[3 - 5]; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/array size must be positive/, error.description)
  end

  def test_division_by_zero_in_constant_expression_is_rejected
    source = "int main(void) { switch (0) { case 1 / 0: return 1; } return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/division by zero in constant expression/, error.description)
  end

  def test_modulo_by_zero_in_constant_expression_is_rejected
    source = "int main(void) { enum { A = 1 % 0 }; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/division by zero in constant expression/, error.description)
  end

  def test_short_circuited_division_by_zero_is_not_an_error
    # "&&"/"||" only evaluate their right operand once the left has not
    # already settled the result, exactly like the run-time operators; the
    # never-reached "1 / 0" must not raise.
    source = "int main(void) { switch (0) { case 1 || 1 / 0: return 1; case 0 && 1 / 0: return 2; } return 0; }"
    compile(source)
  end

  # --- initializers (Step 20) ---------------------------------------------

  def test_excess_elements_in_array_initializer_is_rejected
    source = "int main(void) { int a[2] = {1, 2, 3}; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/excess elements in initializer/, error.description)
  end

  def test_braced_list_for_a_scalar_is_rejected
    source = "int main(void) { int x = {1, 2}; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/excess elements in scalar initializer/, error.description)
  end

  def test_unknown_member_designator_is_rejected
    source = "struct p { int x; int y; }; int main(void) { struct p a = {.z = 1}; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/unknown field designator '\.z'/, error.description)
  end

  def test_out_of_range_array_designator_is_rejected
    source = "int main(void) { int a[3] = {[5] = 1}; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/array designator index 5 exceeds array bounds/, error.description)
  end

  def test_empty_braces_initializer_is_rejected
    source = "int main(void) { int a[3] = {}; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/empty braces are not a valid initializer/, error.description)
  end

  def test_array_without_size_or_initializer_is_rejected
    source = "int main(void) { int a[]; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/array size missing in 'a'/, error.description)
  end

  def test_overlong_string_initializer_for_char_array_is_rejected
    # A char array sized exactly to the characters may drop the terminating NUL
    # (6.7.9p14), but a string with *more* characters than the array has
    # elements still cannot fit: "abc" (three characters) does not fit a char[2].
    source = "int main(void) { char s[2] = \"abc\"; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/initializer-string for char array is too long/, error.description)
  end

  def test_exact_fit_string_initializer_for_char_array_is_accepted
    # 6.7.9p14: a char array sized exactly to the string's characters is
    # initialized by them with the terminating NUL simply dropped, so "hi" fits
    # a char[2] with no room to spare.
    assert compile("int main(void) { char s[2] = \"hi\"; return s[0]; }")
  end

  def test_non_constant_global_aggregate_element_is_rejected
    source = "int f(void); int a[2] = {1, f()}; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/initializer element is not a constant/, error.description)
  end

  def test_global_pointer_to_incompatibly_typed_function_is_rejected
    # A function name is a valid address constant for a matching function
    # pointer, but assigning it to an object pointer ("int *") mismatches the
    # target type, which is rejected like an incompatible initializer.
    source = "int f(void); int *p = f; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incompatible types in initialization/, error.description)
  end

  def test_function_returning_a_function_is_rejected
    source = "int f(void)(int); int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/function returning a function is not allowed/, error.description)
  end

  def test_function_returning_an_array_is_rejected
    source = "int f(void)[3]; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/function returning an array is not allowed/, error.description)
  end

  def test_array_of_functions_is_rejected
    source = "int a[3](int); int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/array of functions is not allowed/, error.description)
  end

  def test_sizeof_a_function_type_is_rejected
    source = "int main(void) { return sizeof(int (int)); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid application of 'sizeof' to a function type/, error.description)
  end

  def test_block_scope_function_declaration_is_rejected
    source = "int main(void) { int f(int); return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/block-scope function declarations are not supported/, error.description)
  end

  def test_struct_member_declared_as_a_function_is_rejected
    source = "struct s { int f(int); }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/field 'f' declared as a function/, error.description)
  end

  # --- storage class, const, inline, _Static_assert, _Alignof (Step 22) ---

  def test_assignment_to_const_variable_is_rejected
    source = "int main(void) { const int x = 1; x = 2; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/assignment of read-only variable 'x'/, error.description)
  end

  def test_compound_assignment_to_const_variable_is_rejected
    source = "int main(void) { const int x = 1; x += 2; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/assignment of read-only variable 'x'/, error.description)
  end

  def test_increment_of_const_variable_is_rejected
    source = "int main(void) { const int x = 1; x++; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/assignment of read-only variable 'x'/, error.description)
  end

  def test_predecrement_of_const_variable_is_rejected
    source = "int main(void) { const int x = 1; --x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/assignment of read-only variable 'x'/, error.description)
  end

  def test_assignment_to_const_parameter_is_rejected
    source = "int f(const int x) { x = 3; return x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/assignment of read-only variable 'x'/, error.description)
  end

  def test_multiple_storage_classes_is_rejected
    source = "int main(void) { static extern int x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/multiple storage classes in declaration specifiers/, error.description)
  end

  def test_storage_class_on_a_member_is_rejected
    source = "struct s { static int x; }; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'static' is not allowed here/, error.description)
  end

  def test_storage_class_on_a_parameter_is_rejected
    source = "int f(register int x) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'register' is not allowed here/, error.description)
  end

  def test_storage_class_in_a_type_name_is_rejected
    source = "int main(void) { return sizeof(static int); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'static' is not allowed here/, error.description)
  end

  def test_inline_on_a_variable_is_rejected
    source = "int main(void) { inline int z; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/variable 'z' declared 'inline'/, error.description)
  end

  def test_static_assert_failure_reports_the_message
    source = "int main(void) { _Static_assert(0, \"boom\"); return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/static assertion failed: "boom"/, error.description)
  end

  def test_static_assert_with_a_false_expression_fails
    source = "_Static_assert(1 == 2, \"unequal\"); int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/static assertion failed: "unequal"/, error.description)
  end

  def test_static_assert_with_a_non_constant_expression_is_rejected
    source = "int main(void) { int n = 1; _Static_assert(n, \"nc\"); return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/static assertion expression is not an integer constant/, error.description)
  end

  def test_alignof_of_a_function_type_is_rejected
    source = "int main(void) { return _Alignof(int (int)); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid application of '_Alignof' to a function type/, error.description)
  end

  def test_alignof_of_an_incomplete_type_is_rejected
    source = "struct s; int main(void) { return _Alignof(struct s); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incomplete type/, error.description)
  end

  def test_extern_with_initializer_is_rejected
    source = "extern int g = 5; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'g' has both 'extern' and initializer/, error.description)
  end

  def test_block_scope_static_with_a_non_constant_initializer_is_rejected
    source = "int f(int n) { static int c = n; return c; } int main(void) { return f(1); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/initializer element is not a constant/, error.description)
  end

  def test_extern_declaration_conflicting_with_the_definition_is_rejected
    source = "extern int g; long g; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/conflicting types for 'g'/, error.description)
  end

  def test_definition_conflicting_with_a_later_extern_declaration_is_rejected
    source = "int g; extern long g; int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/conflicting types for 'g'/, error.description)
  end

  def test_repeated_bare_tentative_definition_is_allowed
    # Two bare (uninitialized) file-scope declarations are tentative definitions
    # of one object (6.9.2), which merge rather than clashing as a redefinition.
    compile("int g; int g; int main(void) { return 0; }")
  end

  # --- floating types (Step 24 Phase A) ------------------------------------

  def test_hexadecimal_floating_constant_is_rejected
    source = "int main(void) { double d = 0x1p3; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/hexadecimal floating constants are not supported yet/, error.description)
  end

  def test_modulo_on_a_floating_operand_is_a_constraint_violation
    source = "int main(void) { double d = 1.5; return (int)(d % 2); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_bitwise_and_on_a_floating_operand_is_a_constraint_violation
    source = "int main(void) { double d = 1.5; return (int)(d & 1); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  def test_shift_on_a_floating_operand_is_a_constraint_violation
    source = "int main(void) { double d = 1.5; return (int)(d << 1); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid operands to binary expression/, error.description)
  end

  # float is of promotable type: the default argument promotions widen it to
  # double at the call, so va_arg(float) would read the wrong width. double is
  # the type the caller must fetch (and is admissible, see the execution tests).
  def test_va_arg_of_float_type_is_rejected_as_promotable
    source = "int f(int a, ...) { __builtin_va_list ap; __builtin_va_start(ap, a); " \
             "return (int)__builtin_va_arg(ap, float); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/second argument to 'va_arg' is of promotable type 'float'/, error.description)
  end

  # The run-time conversion between `unsigned long` and a floating type is now
  # lowered (Step 52), so it compiles cleanly rather than being diagnosed. Its
  # numeric behavior is cross-checked against gcc in TestUnsignedLongFloatConversion.
  def test_unsigned_long_to_floating_conversion_is_lowered
    source = "int main(void) { unsigned long u = 5; double d = u; return (int)d; }"
    assert compile(source).is_a?(String)
  end

  def test_casting_a_floating_value_to_a_pointer_is_rejected
    source = "int main(void) { double d = 1.5; int *p = (int *)d; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/cannot cast 'double' to 'int \*'/, error.description)
  end

  def test_double_combined_with_another_type_specifier_is_rejected
    source = "int main(void) { unsigned double d; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/cannot combine 'double' with other type specifiers/, error.description)
  end

  # --- bit-fields (Step 28 Phase C2) --------------------------------------

  # Bit-fields are now read and written (Step 48), but one cannot name a
  # whole-byte object, so "&s.field" is still rejected (6.5.3.2p1).
  def test_bitfield_address_is_rejected
    source = "struct S { int a:3; };\nint *f(struct S *s) { return &s->a; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/cannot take address of bit-field 'a'/, error.description)
  end

  def test_named_zero_width_bitfield_is_rejected
    source = "struct S { int a:0; };"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/named bit-field 'a' has zero width/, error.description)
  end

  def test_negative_width_bitfield_is_rejected
    source = "struct S { int a:-1; };"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/negative width in bit-field/, error.description)
  end

  def test_bitfield_width_exceeding_type_is_rejected
    source = "struct S { int a:40; };"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/width of bit-field exceeds its type/, error.description)
  end

  def test_non_integral_bitfield_is_rejected
    source = "struct S { int *p:3; };"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/bit-field has non-integral type 'int \*'/, error.description)
  end

  def test_packed_bitfield_is_rejected
    source = "struct __attribute__((packed)) S { int a:3; };"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/packed bit-fields are not supported/, error.description)
  end

  # --- tentative definitions (6.9.2) -----------------------------------------

  def test_repeated_tentative_definition_is_not_a_redefinition
    # A tentative definition may be repeated any number of times; only one may
    # initialize. This compiles without error.
    compile("int x; int x = 3; int x;\nint main(void) { return x; }")
  end

  def test_two_initialized_definitions_is_a_redefinition
    source = "int x = 1; int x = 2;\nint main(void) { return x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redefinition of 'x'/, error.description)
  end

  def test_tentative_definitions_must_agree_in_type
    source = "int x; long x;\nint main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/conflicting types for 'x'/, error.description)
  end

  def test_static_after_non_static_tentative_is_rejected
    source = "int x; static int x;\nint main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/static declaration of 'x' follows non-static declaration/, error.description)
  end

  def test_non_static_after_static_tentative_is_rejected
    source = "static int x; int x;\nint main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/non-static declaration of 'x' follows static declaration/, error.description)
  end

  def test_single_declaration_tentative_form_is_accepted
    # "int x, x = 3, x;" — three declarators of one object in one declaration.
    compile("int x, x = 3, x;\nint main(void) { return x; }")
  end

  # --- incomplete enum completeness diagnostics ------------------------------

  def test_object_of_incomplete_enum_type_is_rejected
    source = "enum E x;\nint main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/invalid use of incomplete type 'enum E'/, error.description)
  end

  def test_sizeof_incomplete_enum_is_rejected
    source = "int main(void) { return sizeof(enum E); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/incomplete type 'enum E'/, error.description)
  end

  def test_incomplete_enum_pointer_is_accepted
    # A pointer to an incomplete enum is complete, so it is allowed.
    compile("enum E *p;\nint main(void) { return 0; }")
  end

  # --- __int128: the operations left out of this phase each diagnose crisply ---

  def test_int128_division_is_rejected
    source = "unsigned long g(void) { unsigned __int128 a = 10, b = 3, c; c = a / b; return (unsigned long)c; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(%r{'/' on 128-bit integers is not supported yet}, error.description)
  end

  # Shifting a 128-bit integer is supported (Step 95): it is synthesized from
  # 64-bit half shifts across the word boundary, verified against gcc by the
  # execution-oracle tests in test_execution_harness.rb / test_aarch64_execution.rb
  # rather than diagnosed here.

  def test_int128_bitwise_and_is_rejected
    source = "unsigned long g(void) { unsigned __int128 a = 10, b = 3, c; c = a & b; return (unsigned long)c; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/'&' on 128-bit integers is not supported yet/, error.description)
  end

  # Passing and returning a 128-bit integer by value is supported (Step 94): it
  # travels as a 16-byte, two-INTEGER-eightbyte aggregate, verified by the
  # execution-oracle tests in test/test_int128_abi.rb rather than diagnosed here.

  def test_int128_variadic_argument_is_rejected
    source = "int printf(const char *fmt, ...); void f(void) { __int128 a = 1; printf(\"%d\", a); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/passing a 128-bit integer to a variadic function is not supported yet/, error.description)
  end

  def test_int128_to_floating_conversion_is_rejected
    source = "double g(void) { __int128 a = 5; return (double)a; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/conversion between '__int128' and a floating type is not supported yet/, error.description)
  end
end
