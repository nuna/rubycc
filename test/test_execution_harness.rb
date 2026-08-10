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

  def test_while_loop_sums_up_to_n
    assert_c_exit_status(
      45,
      "int main(void) { int i = 0; int sum = 0; while (i < 10) { sum = sum + i; i = i + 1; } return sum; }",
      compiler: :rubycc
    )
  end

  def test_while_false_never_executes_body
    assert_c_exit_status(42, "int main(void) { while (0) return 7; return 42; }", compiler: :rubycc)
  end

  def test_do_while_executes_body_at_least_once
    assert_c_exit_status(42, "int main(void) { int x = 0; do { x = 42; } while (0); return x; }", compiler: :rubycc)
  end

  def test_do_while_loops_until_condition_false
    assert_c_exit_status(42, "int main(void) { int i = 0; do { i = i + 1; } while (i < 42); return i; }", compiler: :rubycc)
  end

  def test_for_loop_sums_a_range
    assert_c_exit_status(
      45,
      "int main(void) { int sum = 0; for (int i = 1; i <= 9; i = i + 1) { sum = sum + i; } return sum; }",
      compiler: :rubycc
    )
  end

  def test_for_loop_with_expression_init
    assert_c_exit_status(
      42,
      "int main(void) { int i; int sum = 0; for (i = 0; i < 7; i = i + 1) sum = sum + 6; return sum; }",
      compiler: :rubycc
    )
  end

  def test_for_loop_with_all_clauses_omitted_relies_on_break
    assert_c_exit_status(
      42,
      "int main(void) { int i = 0; for (;;) { i = i + 1; if (i == 42) break; } return i; }",
      compiler: :rubycc
    )
  end

  def test_continue_skips_to_the_step_clause
    assert_c_exit_status(
      25,
      "int main(void) { int sum = 0; for (int i = 0; i < 10; i = i + 1) { if (i % 2 == 0) continue; sum = sum + i; } return sum; }",
      compiler: :rubycc
    )
  end

  def test_while_with_break_and_continue
    assert_c_exit_status(
      10,
      "int main(void) { int i = 0; int n = 0; while (1) { i = i + 1; if (i > 100) break; if (i % 10 != 0) continue; n = n + 1; } return n; }",
      compiler: :rubycc
    )
  end

  def test_nested_for_loops_with_break_in_inner_loop
    assert_c_exit_status(
      15,
      "int main(void) { int total = 0; for (int i = 0; i < 5; i = i + 1) " \
      "{ for (int j = 0; j < 5; j = j + 1) { if (j > i) break; total = total + 1; } } return total; }",
      compiler: :rubycc
    )
  end

  def test_for_loop_init_declaration_scopes_to_the_loop
    assert_c_exit_status(
      100,
      "int main(void) { int i = 100; for (int i = 0; i < 5; i = i + 1) { ; } return i; }",
      compiler: :rubycc
    )
  end

  def test_calls_another_function
    assert_c_exit_status(
      42,
      "int add(int a, int b) { return a + b; } int main(void) { return add(40, 2); }",
      compiler: :rubycc
    )
  end

  def test_argument_order_is_preserved
    assert_c_exit_status(
      42,
      "int f(int a, int b) { return a - b; } int main(void) { return f(50, 8); }",
      compiler: :rubycc
    )
  end

  def test_six_arguments
    assert_c_exit_status(
      67,
      "int f(int a, int b, int c, int d, int e, int g) " \
      "{ return a + b * 2 + c * 3 + d * 4 + e * 5 + g * 6; } " \
      "int main(void) { return f(1, 2, 3, 4, 5, 2); }",
      compiler: :rubycc
    )
  end

  def test_recursion
    assert_c_exit_status(
      55,
      "int fib(int n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } " \
      "int main(void) { return fib(10); }",
      compiler: :rubycc
    )
  end

  def test_mutual_recursion_via_prototype
    assert_c_exit_status(
      42,
      "int is_odd(int n); " \
      "int is_even(int n) { if (n == 0) return 1; return is_odd(n - 1); } " \
      "int is_odd(int n) { if (n == 0) return 0; return is_even(n - 1); } " \
      "int main(void) { return is_even(10) * 42; }",
      compiler: :rubycc
    )
  end

  def test_nested_calls
    assert_c_exit_status(
      42,
      "int twice(int x) { return x * 2; } int main(void) { return twice(twice(10)) + 2; }",
      compiler: :rubycc
    )
  end

  def test_external_libc_function
    assert_c_exit_status(
      42,
      "int abs(int); int main(void) { return abs(0 - 42); }",
      compiler: :rubycc
    )
  end

  def test_call_inside_loop
    assert_c_exit_status(
      30,
      "int sq(int x) { return x * x; } " \
      "int main(void) { int s = 0; for (int i = 1; i <= 4; i = i + 1) s = s + sq(i); return s; }",
      compiler: :rubycc
    )
  end

  def test_reads_through_a_pointer
    assert_c_exit_status(
      42,
      "int main(void) { int x = 10; int *p = &x; return *p * 4 + 2; }",
      compiler: :rubycc
    )
  end

  def test_writes_through_a_pointer
    assert_c_exit_status(
      42,
      "int main(void) { int x = 1; int *p = &x; *p = 42; return x; }",
      compiler: :rubycc
    )
  end

  def test_writes_through_a_pointer_to_a_pointer
    assert_c_exit_status(
      42,
      "int main(void) { int x = 5; int *p = &x; int **pp = &p; **pp = 42; return x; }",
      compiler: :rubycc
    )
  end

  def test_reassigning_a_pointer
    assert_c_exit_status(
      42,
      "int main(void) { int x = 5; int y = 42; int *p = &x; p = &y; return *p; }",
      compiler: :rubycc
    )
  end

  def test_read_write_mix_through_a_pointer
    assert_c_exit_status(
      42,
      "int main(void) { int x = 40; int *p = &x; *p = *p + 2; return x; }",
      compiler: :rubycc
    )
  end

  def test_function_writes_through_pointer_argument
    assert_c_exit_status(
      42,
      "int set(int *dst, int v) { *dst = v; return 0; } " \
      "int main(void) { int x = 0; set(&x, 42); return x; }",
      compiler: :rubycc
    )
  end

  def test_swap_through_pointer_arguments
    assert_c_exit_status(
      118,
      "int swap(int *a, int *b) { int t = *a; *a = *b; *b = t; return 0; } " \
      "int main(void) { int x = 2; int y = 40; swap(&x, &y); return x - y + 80; }",
      compiler: :rubycc
    )
  end

  def test_array_write_and_read_in_a_loop
    assert_c_exit_status(
      42,
      "int main(void) { int a[5]; for (int i = 0; i < 5; i = i + 1) a[i] = i * 10; return a[4] + 2; }",
      compiler: :rubycc
    )
  end

  def test_array_sum
    assert_c_exit_status(
      42,
      "int main(void) { int a[3]; a[0] = 1; a[1] = 2; a[2] = 3; int s = 0; " \
      "for (int i = 0; i < 3; i = i + 1) s = s + a[i]; return s * 7; }",
      compiler: :rubycc
    )
  end

  def test_pointer_to_array_and_pointer_arithmetic_store
    assert_c_exit_status(
      42,
      "int main(void) { int a[4]; int *p = a; *(p + 2) = 42; return a[2]; }",
      compiler: :rubycc
    )
  end

  def test_address_of_element_and_subscript_through_pointer
    assert_c_exit_status(
      42,
      "int main(void) { int a[4]; a[3] = 42; int *p = &a[3]; return p[0]; }",
      compiler: :rubycc
    )
  end

  def test_negative_subscript_through_pointer
    assert_c_exit_status(
      42,
      "int main(void) { int a[8]; a[2] = 42; int *p = &a[5]; return p[-3]; }",
      compiler: :rubycc
    )
  end

  def test_pointer_difference
    assert_c_exit_status(
      42,
      "int main(void) { int a[10]; int *p = &a[1]; int *q = &a[8]; return (q - p) * 6; }",
      compiler: :rubycc
    )
  end

  def test_pointer_comparison_in_loop
    assert_c_exit_status(
      42,
      "int main(void) { int a[4]; int *p = &a[0]; int *q = &a[3]; int n = 0; " \
      "while (p < q) { p = p + 1; n = n + 1; } return n * 14; }",
      compiler: :rubycc
    )
  end

  def test_passing_an_array_decays_to_a_pointer
    assert_c_exit_status(
      42,
      "int sum(int *v, int n) { int s = 0; for (int i = 0; i < n; i = i + 1) s = s + v[i]; return s; } " \
      "int main(void) { int a[4]; a[0] = 10; a[1] = 11; a[2] = 10; a[3] = 11; return sum(a, 4); }",
      compiler: :rubycc
    )
  end

  def test_sizeof_of_arrays_pointers_and_types
    # sizeof(a) - sizeof(int) * 8 + sizeof(p) - sizeof(int *) + sizeof 1 - 2
    #   = 40 - 32 + 8 - 8 + 4 - 2 = 10 (matching gcc).
    assert_c_exit_status(
      10,
      "int main(void) { int a[10]; int *p; " \
      "return sizeof(a) - sizeof(int) * 8 + sizeof(p) - sizeof(int *) + sizeof 1 - 2; }",
      compiler: :rubycc
    )
  end

  def test_sizeof_of_function_pointer_types
    # A function pointer is an ordinary 8-byte address, so sizeof of a function
    # pointer type (written directly or through a local variable) is 8. The
    # value semantics of function pointers arrive later; this measures the type.
    # 8 + 8 * 4 + 2 = 42, matching gcc.
    assert_c_exit_status(
      42,
      "int main(void) { int (*fp)(int); " \
      "return sizeof(int (*)(int)) + sizeof(fp) * 4 + 2; }",
      compiler: :gcc
    )
    assert_c_exit_status(
      42,
      "int main(void) { int (*fp)(int); " \
      "return sizeof(int (*)(int)) + sizeof(fp) * 4 + 2; }",
      compiler: :rubycc
    )
  end

  def test_multiple_objects_and_scalars_interleaved
    assert_c_exit_status(
      42,
      "int main(void) { int x = 1; int a[3]; int y = 2; a[1] = 39; return x + a[1] + y; }",
      compiler: :rubycc
    )
  end

  def test_logical_and_or_arithmetic
    assert_c_exit_status(
      41,
      "int main(void) { return (1 && 2) * 21 + (0 && 1) + (1 || 0) * 20 + (0 || 0); }",
      compiler: :rubycc
    )
  end

  def test_short_circuit_and_or_skip_their_side_effecting_operand
    assert_c_exit_status(
      42,
      "int f(int *p) { *p = 99; return 1; } " \
      "int main(void) { int x = 0; 0 && f(&x); 1 || f(&x); return x + 42; }",
      compiler: :rubycc
    )
  end

  def test_short_circuit_and_or_run_their_evaluated_operand
    assert_c_exit_status(
      42,
      "int bump(int *p) { *p += 1; return 1; } " \
      "int main(void) { int c = 0; 1 && bump(&c); 0 || bump(&c); return c * 21; }",
      compiler: :rubycc
    )
  end

  def test_conditional_operator
    assert_c_exit_status(42, "int main(void) { int x = 1; return x == 1 ? 42 : 7; }", compiler: :rubycc)
  end

  def test_conditional_operator_is_right_associative
    assert_c_exit_status(
      42,
      "int main(void) { int n = 2; return n == 1 ? 10 : n == 2 ? 42 : 30; }",
      compiler: :rubycc
    )
  end

  def test_compound_assignment_add
    assert_c_exit_status(42, "int main(void) { int x = 40; x += 2; return x; }", compiler: :rubycc)
  end

  def test_compound_assignment_div
    assert_c_exit_status(42, "int main(void) { int x = 84; x /= 2; return x; }", compiler: :rubycc)
  end

  def test_compound_assignment_mod
    assert_c_exit_status(42, "int main(void) { int x = 100; x %= 58; return x; }", compiler: :rubycc)
  end

  def test_compound_assignment_mul
    assert_c_exit_status(42, "int main(void) { int x = 7; x *= 6; return x; }", compiler: :rubycc)
  end

  def test_compound_assignment_sub
    assert_c_exit_status(42, "int main(void) { int x = 44; x -= 2; return x; }", compiler: :rubycc)
  end

  def test_pointer_compound_assignment_scales_by_element_size
    assert_c_exit_status(
      42,
      "int main(void) { int a[8]; a[5] = 42; int *p = a; p += 5; return *p; }",
      compiler: :rubycc
    )
  end

  def test_prefix_increment
    assert_c_exit_status(42, "int main(void) { int i = 41; return ++i; }", compiler: :rubycc)
  end

  def test_postfix_increment
    assert_c_exit_status(42, "int main(void) { int i = 42; return i++; }", compiler: :rubycc)
  end

  def test_prefix_decrement
    assert_c_exit_status(42, "int main(void) { int i = 43; return --i; }", compiler: :rubycc)
  end

  def test_postfix_increment_in_array_subscript
    assert_c_exit_status(
      42,
      "int main(void) { int i = 0; int a[3]; a[i++] = 40; a[i] = 2; return a[0] + a[1]; }",
      compiler: :rubycc
    )
  end

  def test_pointer_postfix_increment_scales_by_element_size
    assert_c_exit_status(
      42,
      "int main(void) { int a[4]; a[0] = 40; a[1] = 2; int *p = a; int s = *p++; s += *p; return s; }",
      compiler: :rubycc
    )
  end

  def test_subscript_compound_assignment
    assert_c_exit_status(42, "int main(void) { int a[2]; a[1] = 40; a[1] += 2; return a[1]; }", compiler: :rubycc)
  end

  def test_loop_using_compound_assignment_and_prefix_increment
    assert_c_exit_status(
      42,
      "int main(void) { int s = 0; for (int i = 1; i <= 9; ++i) s += i; return s - 3; }",
      compiler: :rubycc
    )
  end

  def test_char_arithmetic_promotes_to_int
    assert_c_exit_status(42, "int main(void) { char c = 65; return c - 23; }", compiler: :rubycc)
  end

  def test_char_assignment_truncates_to_one_byte
    assert_c_exit_status(44, "int main(void) { char c = 300; return c; }", compiler: :rubycc)
  end

  def test_character_constant
    assert_c_exit_status(42, "int main(void) { char c = 'A'; return c == 65 ? 42 : 0; }", compiler: :rubycc)
  end

  def test_character_constant_escape
    assert_c_exit_status(42, "int main(void) { return '\\n' == 10 ? 42 : 7; }", compiler: :rubycc)
  end

  def test_string_subscript
    assert_c_exit_status(101, "int main(void) { char *s = \"hello\"; return s[1]; }", compiler: :rubycc)
  end

  def test_string_length_with_own_strlen
    assert_c_exit_status(
      42,
      "int length(char *s) { int n = 0; while (s[n]) n++; return n; } " \
      "int main(void) { return length(\"forty-two!\") * 4 + 2; }",
      compiler: :rubycc
    )
  end

  def test_char_array_store_and_load
    assert_c_exit_status(
      120,
      "int main(void) { char buf[4]; buf[0] = 'x'; buf[1] = 0; return buf[0]; }",
      compiler: :rubycc
    )
  end

  def test_char_pointer_arithmetic_scales_by_one
    assert_c_exit_status(99, "int main(void) { char *s = \"abc\"; s += 2; return *s; }", compiler: :rubycc)
  end

  def test_string_escape_is_resolved
    assert_c_exit_status(42, "int main(void) { char *s = \"a\\tb\"; return s[1] == 9 ? 42 : 0; }", compiler: :rubycc)
  end

  def test_sizeof_of_char_string_and_char_pointer
    assert_c_exit_status(
      42,
      "int main(void) { return sizeof(\"hi\") * 10 + sizeof(char) * 8 + sizeof(char *) / 2; }",
      compiler: :rubycc
    )
  end

  def test_char_promotes_when_added_to_int
    assert_c_exit_status(42, "int main(void) { char a = 40; int b = 2; return a + b; }", compiler: :rubycc)
  end

  def test_identical_string_literals_are_deduplicated
    # rubycc pools identical literals, so both pointers hold the same .rodata
    # address. (Excluded from the gcc differential: identical string identity
    # is unspecified in C.)
    assert_c_exit_status(
      42,
      "int main(void) { char *a = \"same\"; char *b = \"same\"; return a == b ? 42 : 7; }",
      compiler: :rubycc
    )
  end

  def test_while_dereference_loop_counts_characters
    assert_c_exit_status(
      42,
      "int count(char *s, char t) { int n = 0; while (*s) { if (*s == t) n++; s++; } return n; } " \
      "int main(void) { return count(\"mississippi\", 's') * 10 + 2; }",
      compiler: :rubycc
    )
  end

  # --- pointer, char and void return types --------------------------------

  def test_pointer_return_type
    assert_c_exit_status(
      42,
      "int *pick(int *a, int i) { return &a[i]; } " \
      "int main(void) { int v[3]; v[2] = 42; return *pick(v, 2); }",
      compiler: :rubycc
    )
  end

  def test_char_return_type
    assert_c_exit_status(
      42,
      "char first(char *s) { return s[0]; } " \
      "int main(void) { return first(\"*hello\") == 42 ? 42 : 7; }",
      compiler: :rubycc
    )
  end

  def test_void_function_returns_no_value
    assert_c_exit_status(
      42,
      "void fill(int *p, int v) { *p = v; return; } " \
      "int main(void) { int x; fill(&x, 42); return x; }",
      compiler: :rubycc
    )
  end

  def test_void_function_falls_off_the_end
    assert_c_exit_status(
      42,
      "void nop(void) { } int main(void) { nop(); return 42; }",
      compiler: :rubycc
    )
  end

  def test_malloc_and_free_through_void_pointer_prototypes
    assert_c_exit_status(
      42,
      "void *malloc(int n); void free(void *p); " \
      "int main(void) { int *a = malloc(sizeof(int) * 10); " \
      "for (int i = 0; i < 10; i++) a[i] = i; " \
      "int s = a[9] * 4 + a[6]; free(a); return s; }",
      compiler: :rubycc
    )
  end

  def test_pointer_returning_string_search
    assert_c_exit_status(
      42,
      "char *find(char *s, char c) { while (*s && *s != c) s++; return s; } " \
      "int main(void) { char *p = find(\"abcdef\", 'd'); return *p - 58; }",
      compiler: :rubycc
    )
  end

  def test_void_pointer_passed_through_and_back
    assert_c_exit_status(
      42,
      "void *pass(void *p) { return p; } " \
      "int main(void) { int x = 42; int *q = pass(&x); return *q; }",
      compiler: :rubycc
    )
  end

  def test_recursive_void_function
    assert_c_exit_status(
      42,
      "void countdown(int *n) { if (*n > 0) { *n -= 1; countdown(n); } } " \
      "int main(void) { int n = 58; countdown(&n); return 42 - n; }",
      compiler: :rubycc
    )
  end

  # --- file-scope (global) variables --------------------------------------

  def test_global_int_in_bss_is_shared_across_functions
    assert_c_exit_status(
      42,
      "int counter; int bump(void) { counter += 7; return 0; } " \
      "int main(void) { bump(); bump(); bump(); return counter * 2; }",
      compiler: :rubycc
    )
  end

  def test_global_int_with_initializer_lives_in_data
    assert_c_exit_status(42, "int base = 40; int main(void) { return base + 2; }", compiler: :rubycc)
  end

  def test_global_char_initializer
    assert_c_exit_status(42, "char tag = 'Z'; int main(void) { return tag - 48; }", compiler: :rubycc)
  end

  def test_global_negative_initializer
    assert_c_exit_status(42, "int negative = -8; int main(void) { return negative + 50; }", compiler: :rubycc)
  end

  def test_global_array_in_bss
    assert_c_exit_status(
      42,
      "int table[8]; int main(void) { for (int i = 0; i < 8; i++) table[i] = i; return table[6] * 7; }",
      compiler: :rubycc
    )
  end

  def test_local_shadows_global
    assert_c_exit_status(42, "int g = 5; int main(void) { int g = 40; return g + 2; }", compiler: :rubycc)
  end

  def test_global_shared_across_calls
    assert_c_exit_status(
      42,
      "int shared = 30; int add(int n) { shared += n; return shared; } " \
      "int main(void) { add(5); return add(7); }",
      compiler: :rubycc
    )
  end

  def test_global_address_and_pointer_write
    assert_c_exit_status(42, "int v = 21; int main(void) { int *p = &v; *p *= 2; return v; }", compiler: :rubycc)
  end

  def test_local_char_alias_write_is_visible_on_reread
    # A store through "char *p = &c" rewrites only the slot's low byte; the
    # subsequent read of c must re-extract that byte rather than trust the
    # slot's stale upper bytes.
    assert_c_exit_status(
      42,
      "int main(void) { char c = -1; char *p = &c; *p = 'x'; return c == 'x' ? 42 : 7; }",
      compiler: :rubycc
    )
  end

  def test_global_char_written_through_pointer_parameter
    assert_c_exit_status(
      42,
      "char gc = -1; int set(char *p) { *p = 'A'; return 0; } " \
      "int main(void) { set(&gc); return gc - 23; }",
      compiler: :rubycc
    )
  end

  # These file-scope cases must agree with gcc bit-for-bit on exit code,
  # covering .bss/.data placement, char and negative initializers, arrays,
  # shadowing and the local-char aliasing fix.
  GLOBAL_DIFFERENTIAL_SOURCES = [
    "int counter; int bump(void) { counter += 7; return 0; } " \
    "int main(void) { bump(); bump(); bump(); return counter * 2; }",
    "int base = 40; int main(void) { return base + 2; }",
    "char tag = 'Z'; int main(void) { return tag - 48; }",
    "int negative = -8; int main(void) { return negative + 50; }",
    "int table[8]; int main(void) { for (int i = 0; i < 8; i++) table[i] = i; return table[6] * 7; }",
    "int g = 5; int main(void) { int g = 40; return g + 2; }",
    "int shared = 30; int add(int n) { shared += n; return shared; } " \
    "int main(void) { add(5); return add(7); }",
    "int v = 21; int main(void) { int *p = &v; *p *= 2; return v; }",
    "int main(void) { char c = -1; char *p = &c; *p = 'x'; return c == 'x' ? 42 : 7; }",
    "char gc = -1; int set(char *p) { *p = 'A'; return 0; } " \
    "int main(void) { set(&gc); return gc - 23; }"
  ].freeze

  def test_globals_match_gcc_exit_codes
    GLOBAL_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  PUTS_PROGRAM = "int puts(char *s); int main(void) { puts(\"hello, rubycc\"); return 0; }"

  def test_puts_writes_to_stdout
    assert_c_program(PUTS_PROGRAM, exit_status: 0, stdout: "hello, rubycc\n", compiler: :rubycc)
  end

  def test_puts_matches_gcc_stdout_and_exit
    rubycc = program_output(PUTS_PROGRAM, compiler: :rubycc)
    gcc = program_output(PUTS_PROGRAM, compiler: :gcc)
    assert_equal gcc, rubycc, "rubycc and gcc disagree on [exit, stdout] for puts"
  end

  def test_linking_emits_no_executable_stack_warning
    # The .note.GNU-stack section marks the stack non-executable, so gcc's
    # linker driver should not print any warning when producing the executable.
    in_tmpdir do |dir|
      object_path = File.join(dir, "test.o")
      compile_with_rubycc("int f(int x) { return x; } int main(void) { return f(42); }", object_path)
      assert_empty link_stderr(object_path)
    end
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
    "int main(void) { int a = 1; int b = 2; if (a == 1) { if (b == 2) { return 42; } } return 7; }",
    "int main(void) { int i = 0; int sum = 0; while (i < 10) { sum = sum + i; i = i + 1; } return sum; }",
    "int main(void) { while (0) return 7; return 42; }",
    "int main(void) { int x = 0; do { x = 42; } while (0); return x; }",
    "int main(void) { int i = 0; do { i = i + 1; } while (i < 42); return i; }",
    "int main(void) { int sum = 0; for (int i = 1; i <= 9; i = i + 1) { sum = sum + i; } return sum; }",
    "int main(void) { int i; int sum = 0; for (i = 0; i < 7; i = i + 1) sum = sum + 6; return sum; }",
    "int main(void) { int i = 0; for (;;) { i = i + 1; if (i == 42) break; } return i; }",
    "int main(void) { int sum = 0; for (int i = 0; i < 10; i = i + 1) " \
    "{ if (i % 2 == 0) continue; sum = sum + i; } return sum; }",
    "int main(void) { int i = 0; int n = 0; while (1) " \
    "{ i = i + 1; if (i > 100) break; if (i % 10 != 0) continue; n = n + 1; } return n; }",
    "int main(void) { int total = 0; for (int i = 0; i < 5; i = i + 1) " \
    "{ for (int j = 0; j < 5; j = j + 1) { if (j > i) break; total = total + 1; } } return total; }",
    "int main(void) { int i = 100; for (int i = 0; i < 5; i = i + 1) { ; } return i; }",
    "int add(int a, int b) { return a + b; } int main(void) { return add(40, 2); }",
    "int f(int a, int b) { return a - b; } int main(void) { return f(50, 8); }",
    "int f(int a, int b, int c, int d, int e, int g) " \
    "{ return a + b * 2 + c * 3 + d * 4 + e * 5 + g * 6; } " \
    "int main(void) { return f(1, 2, 3, 4, 5, 2); }",
    "int fib(int n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } " \
    "int main(void) { return fib(10); }",
    "int is_odd(int n); " \
    "int is_even(int n) { if (n == 0) return 1; return is_odd(n - 1); } " \
    "int is_odd(int n) { if (n == 0) return 0; return is_even(n - 1); } " \
    "int main(void) { return is_even(10) * 42; }",
    "int twice(int x) { return x * 2; } int main(void) { return twice(twice(10)) + 2; }",
    "int abs(int); int main(void) { return abs(0 - 42); }",
    "int sq(int x) { return x * x; } " \
    "int main(void) { int s = 0; for (int i = 1; i <= 4; i = i + 1) s = s + sq(i); return s; }",
    "int main(void) { int x = 10; int *p = &x; return *p * 4 + 2; }",
    "int main(void) { int x = 1; int *p = &x; *p = 42; return x; }",
    "int main(void) { int x = 5; int *p = &x; int **pp = &p; **pp = 42; return x; }",
    "int main(void) { int x = 5; int y = 42; int *p = &x; p = &y; return *p; }",
    "int main(void) { int x = 40; int *p = &x; *p = *p + 2; return x; }",
    "int set(int *dst, int v) { *dst = v; return 0; } " \
    "int main(void) { int x = 0; set(&x, 42); return x; }",
    "int swap(int *a, int *b) { int t = *a; *a = *b; *b = t; return 0; } " \
    "int main(void) { int x = 2; int y = 40; swap(&x, &y); return x - y + 80; }",
    "int main(void) { int a[5]; for (int i = 0; i < 5; i = i + 1) a[i] = i * 10; return a[4] + 2; }",
    "int main(void) { int a[3]; a[0] = 1; a[1] = 2; a[2] = 3; int s = 0; " \
    "for (int i = 0; i < 3; i = i + 1) s = s + a[i]; return s * 7; }",
    "int main(void) { int a[4]; int *p = a; *(p + 2) = 42; return a[2]; }",
    "int main(void) { int a[4]; a[3] = 42; int *p = &a[3]; return p[0]; }",
    "int main(void) { int a[8]; a[2] = 42; int *p = &a[5]; return p[-3]; }",
    "int main(void) { int a[10]; int *p = &a[1]; int *q = &a[8]; return (q - p) * 6; }",
    "int main(void) { int a[4]; int *p = &a[0]; int *q = &a[3]; int n = 0; " \
    "while (p < q) { p = p + 1; n = n + 1; } return n * 14; }",
    "int sum(int *v, int n) { int s = 0; for (int i = 0; i < n; i = i + 1) s = s + v[i]; return s; } " \
    "int main(void) { int a[4]; a[0] = 10; a[1] = 11; a[2] = 10; a[3] = 11; return sum(a, 4); }",
    "int main(void) { int a[10]; int *p; " \
    "return sizeof(a) - sizeof(int) * 8 + sizeof(p) - sizeof(int *) + sizeof 1 - 2; }",
    "int main(void) { int x = 1; int a[3]; int y = 2; a[1] = 39; return x + a[1] + y; }",
    "int main(void) { return (1 && 2) * 21 + (0 && 1) + (1 || 0) * 20 + (0 || 0); }",
    "int f(int *p) { *p = 99; return 1; } " \
    "int main(void) { int x = 0; 0 && f(&x); 1 || f(&x); return x + 42; }",
    "int bump(int *p) { *p += 1; return 1; } " \
    "int main(void) { int c = 0; 1 && bump(&c); 0 || bump(&c); return c * 21; }",
    "int main(void) { int x = 1; return x == 1 ? 42 : 7; }",
    "int main(void) { int n = 2; return n == 1 ? 10 : n == 2 ? 42 : 30; }",
    "int main(void) { int x = 40; x += 2; return x; }",
    "int main(void) { int x = 84; x /= 2; return x; }",
    "int main(void) { int x = 100; x %= 58; return x; }",
    "int main(void) { int x = 7; x *= 6; return x; }",
    "int main(void) { int x = 44; x -= 2; return x; }",
    "int main(void) { int a[8]; a[5] = 42; int *p = a; p += 5; return *p; }",
    "int main(void) { int i = 41; return ++i; }",
    "int main(void) { int i = 42; return i++; }",
    "int main(void) { int i = 43; return --i; }",
    "int main(void) { int i = 0; int a[3]; a[i++] = 40; a[i] = 2; return a[0] + a[1]; }",
    "int main(void) { int a[4]; a[0] = 40; a[1] = 2; int *p = a; int s = *p++; s += *p; return s; }",
    "int main(void) { int a[2]; a[1] = 40; a[1] += 2; return a[1]; }",
    "int main(void) { int s = 0; for (int i = 1; i <= 9; ++i) s += i; return s - 3; }",
    "int main(void) { char c = 65; return c - 23; }",
    "int main(void) { char c = 300; return c; }",
    "int main(void) { char c = 'A'; return c == 65 ? 42 : 0; }",
    "int main(void) { return '\\n' == 10 ? 42 : 7; }",
    "int main(void) { char *s = \"hello\"; return s[1]; }",
    "int length(char *s) { int n = 0; while (s[n]) n++; return n; } " \
    "int main(void) { return length(\"forty-two!\") * 4 + 2; }",
    "int main(void) { char buf[4]; buf[0] = 'x'; buf[1] = 0; return buf[0]; }",
    "int main(void) { char *s = \"abc\"; s += 2; return *s; }",
    "int main(void) { char *s = \"a\\tb\"; return s[1] == 9 ? 42 : 0; }",
    "int main(void) { return sizeof(\"hi\") * 10 + sizeof(char) * 8 + sizeof(char *) / 2; }",
    "int main(void) { char a = 40; int b = 2; return a + b; }",
    "int count(char *s, char t) { int n = 0; while (*s) { if (*s == t) n++; s++; } return n; } " \
    "int main(void) { return count(\"mississippi\", 's') * 10 + 2; }"
  ].freeze

  def test_matches_gcc_exit_codes
    DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # --- structs ------------------------------------------------------------

  def test_struct_member_read_and_write
    assert_c_exit_status(
      42,
      "struct point { int x; int y; }; " \
      "int main(void) { struct point p; p.x = 40; p.y = 2; return p.x + p.y; }",
      compiler: :rubycc
    )
  end

  def test_struct_member_write_through_arrow
    assert_c_exit_status(
      42,
      "struct point { int x; int y; }; " \
      "int main(void) { struct point p; struct point *q = &p; " \
      "q->x = 40; q->y = 2; return p.x + p.y; }",
      compiler: :rubycc
    )
  end

  def test_struct_assignment_copies_all_members
    assert_c_exit_status(
      42,
      "struct point { int x; int y; }; " \
      "int main(void) { struct point a; a.x = 40; a.y = 2; " \
      "struct point b; b = a; return b.x + b.y; }",
      compiler: :rubycc
    )
  end

  def test_nested_struct_member_access
    assert_c_exit_status(
      42,
      "struct inner { int v; }; struct outer { struct inner in; int w; }; " \
      "int main(void) { struct outer o; o.in.v = 40; o.w = 2; return o.in.v + o.w; }",
      compiler: :rubycc
    )
  end

  def test_array_of_structs
    assert_c_exit_status(
      42,
      "struct point { int x; int y; }; " \
      "int main(void) { struct point ps[3]; " \
      "for (int i = 0; i < 3; i++) { ps[i].x = i; ps[i].y = i * 10; } " \
      "return ps[2].x * 16 + ps[1].y; }",
      compiler: :rubycc
    )
  end

  def test_sizeof_struct_type
    assert_c_exit_status(
      42,
      "struct point { int x; int y; }; int main(void) { return sizeof(struct point) + 34; }",
      compiler: :rubycc
    )
  end

  def test_sizeof_struct_expression
    assert_c_exit_status(
      42,
      "struct s { int a; int b; int c; }; " \
      "int main(void) { struct s v; return sizeof v + 30; }",
      compiler: :rubycc
    )
  end

  def test_struct_with_char_and_int_members_roundtrips_through_padding
    assert_c_exit_status(
      42,
      "struct s { char c; int i; }; " \
      "int main(void) { struct s v; v.c = 7; v.i = 35; return v.c + v.i; }",
      compiler: :rubycc
    )
  end

  def test_char_members_survive_struct_copy
    # A whole-struct copy is a byte-for-byte memcpy, so each single-byte char
    # member lands intact in the destination.
    assert_c_exit_status(
      42,
      "struct s { char a; char b; char c; }; " \
      "int main(void) { struct s x; x.a = 10; x.b = 14; x.c = 18; " \
      "struct s y; y = x; return y.a + y.b + y.c; }",
      compiler: :rubycc
    )
  end

  def test_global_struct
    assert_c_exit_status(
      42,
      "struct point { int x; int y; }; struct point g; " \
      "int main(void) { g.x = 40; g.y = 2; return g.x + g.y; }",
      compiler: :rubycc
    )
  end

  def test_struct_with_array_member
    assert_c_exit_status(
      42,
      "struct s { int a[4]; int n; }; " \
      "int main(void) { struct s v; v.n = 2; for (int i = 0; i < 4; i++) v.a[i] = i * 10; " \
      "return v.a[3] + v.a[1] - v.n + 4; }",
      compiler: :rubycc
    )
  end

  def test_address_of_struct_member
    assert_c_exit_status(
      42,
      "struct p { int x; int y; }; " \
      "int main(void) { struct p a; a.y = 42; int *pp = &a.y; return *pp; }",
      compiler: :rubycc
    )
  end

  def test_struct_pointer_parameter_mutates_caller_struct
    assert_c_exit_status(
      42,
      "struct p { int x; int y; }; " \
      "int setx(struct p *q, int v) { q->x = v; return 0; } " \
      "int main(void) { struct p a; a.x = 0; a.y = 2; setx(&a, 40); return a.x + a.y; }",
      compiler: :rubycc
    )
  end

  def test_pointer_arithmetic_over_struct_array
    assert_c_exit_status(
      42,
      "struct p { int x; int y; }; " \
      "int main(void) { struct p ps[3]; " \
      "for (int i = 0; i < 3; i++) { ps[i].x = i; ps[i].y = i * 10; } " \
      "struct p *q = ps; return (q + 2)->y + (q + 2)->x * 11; }",
      compiler: :rubycc
    )
  end

  def test_linked_list_built_and_traversed_with_arrow
    # Build a three-node list on the stack, chaining with "&", then walk it
    # through "->". The last node points at itself so traversal has a stable
    # terminator without a null pointer constant (which this subset lacks).
    assert_c_exit_status(
      42,
      "struct node { int v; struct node *next; }; " \
      "int main(void) { struct node a; struct node b; struct node c; " \
      "a.v = 10; a.next = &b; b.v = 14; b.next = &c; c.v = 18; c.next = &c; " \
      "struct node *p = &a; int sum = 0; " \
      "for (int i = 0; i < 3; i++) { sum += p->v; p = p->next; } return sum; }",
      compiler: :rubycc
    )
  end

  def test_anonymous_struct_variable
    assert_c_exit_status(
      42,
      "int main(void) { struct { int x; int y; } v; v.x = 40; v.y = 2; return v.x + v.y; }",
      compiler: :rubycc
    )
  end

  def test_forward_declared_struct_completed_later
    assert_c_exit_status(
      42,
      "struct node; struct wrap { struct node *p; }; struct node { int v; }; " \
      "int main(void) { struct node n; n.v = 42; struct wrap w; w.p = &n; return w.p->v; }",
      compiler: :rubycc
    )
  end

  # These struct cases must agree with gcc bit-for-bit on exit code, covering
  # member access via "." and "->", whole-struct copy, nesting, struct arrays,
  # struct globals, pointer arithmetic over structs, sizeof and a "->"-traversed
  # linked list.
  STRUCT_DIFFERENTIAL_SOURCES = [
    "struct point { int x; int y; }; int main(void) { struct point p; p.x = 40; p.y = 2; return p.x + p.y; }",
    "struct point { int x; int y; }; int main(void) { struct point p; struct point *q = &p; " \
    "q->x = 40; q->y = 2; return p.x + p.y; }",
    "struct point { int x; int y; }; int main(void) { struct point a; a.x = 40; a.y = 2; " \
    "struct point b; b = a; return b.x + b.y; }",
    "struct inner { int v; }; struct outer { struct inner in; int w; }; " \
    "int main(void) { struct outer o; o.in.v = 40; o.w = 2; return o.in.v + o.w; }",
    "struct point { int x; int y; }; int main(void) { struct point ps[3]; " \
    "for (int i = 0; i < 3; i++) { ps[i].x = i; ps[i].y = i * 10; } return ps[2].x * 16 + ps[1].y; }",
    "struct point { int x; int y; }; int main(void) { return sizeof(struct point) + 34; }",
    "struct s { char c; int i; }; int main(void) { struct s v; v.c = 7; v.i = 35; return v.c + v.i; }",
    "struct point { int x; int y; }; struct point g; int main(void) { g.x = 40; g.y = 2; return g.x + g.y; }",
    "struct p { int x; int y; }; struct p g[3]; int main(void) { " \
    "for (int i = 0; i < 3; i++) { g[i].x = i; g[i].y = i; } return g[2].x * 20 + g[1].y * 2; }",
    "struct node { int v; struct node *next; }; int main(void) { " \
    "struct node a; struct node b; struct node c; " \
    "a.v = 10; a.next = &b; b.v = 14; b.next = &c; c.v = 18; c.next = &c; " \
    "struct node *p = &a; int sum = 0; for (int i = 0; i < 3; i++) { sum += p->v; p = p->next; } return sum; }",
    "struct p { int x; int y; }; int main(void) { struct p ps[3]; " \
    "for (int i = 0; i < 3; i++) { ps[i].x = i; ps[i].y = i * 10; } " \
    "struct p *q = ps; return (q + 2)->y + (q + 2)->x * 11; }",
    "struct s { int a[4]; int n; }; int main(void) { struct s v; v.n = 2; " \
    "for (int i = 0; i < 4; i++) v.a[i] = i * 10; return v.a[3] + v.a[1] - v.n + 4; }",
    "struct p { int x; int y; }; int main(void) { struct p a; a.y = 42; int *pp = &a.y; return *pp; }",
    "struct p { int x; int y; }; int setx(struct p *q, int v) { q->x = v; return 0; } " \
    "int main(void) { struct p a; a.x = 0; a.y = 2; setx(&a, 40); return a.x + a.y; }",
    "struct s { char a; char b; char c; }; int main(void) { struct s x; x.a = 10; x.b = 14; x.c = 18; " \
    "struct s y; y = x; return y.a + y.b + y.c; }",
    "int main(void) { struct { int x; int y; } v; v.x = 40; v.y = 2; return v.x + v.y; }",
    "struct node; struct wrap { struct node *p; }; struct node { int v; }; " \
    "int main(void) { struct node n; n.v = 42; struct wrap w; w.p = &n; return w.p->v; }",
    "struct s { int a; int b; int c; }; int main(void) { struct s v; return sizeof v + 30; }"
  ].freeze

  def test_structs_match_gcc_exit_codes
    STRUCT_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # Struct arguments and results passed by value under the host psABI
  # classification (System V AMD64 or AArch64 AAPCS64; Step 25 Phase B). Each
  # source hands a whole struct across a call and folds the result into an exit
  # code, so gcc's host-target classification is the oracle bit-for-bit.
  STRUCT_ABI_DIFFERENTIAL_SOURCES = [
    # Two ints share one INTEGER eightbyte: a single-register argument and return.
    "struct P { int x; int y; }; struct P mk(int a, int b) { struct P p; p.x = a; p.y = b; return p; } " \
    "int main(void) { struct P p = mk(40, 2); return p.x + p.y; }",
    # Four ints are 16 bytes, two INTEGER eightbytes ([:gp, :gp]).
    "struct Q { int a; int b; int c; int d; }; struct Q id(struct Q q) { return q; } " \
    "int main(void) { struct Q q; q.a = 1; q.b = 2; q.c = 3; q.d = 4; struct Q r = id(q); " \
    "return r.a + r.b + r.c + r.d + 32; }",
    # Two doubles are two SSE eightbytes ([:sse8, :sse8]).
    "struct D { double a; double b; }; struct D id(struct D d) { return d; } " \
    "int main(void) { struct D d; d.a = 1.5; d.b = 2.5; struct D r = id(d); return (int)(r.a + r.b) + 38; }",
    # Two floats pack into one SSE eightbyte ([:sse8]): a single movsd carries both.
    "struct F { float a; float b; }; struct F id(struct F f) { return f; } " \
    "int main(void) { struct F f; f.a = 1.5f; f.b = 2.5f; struct F r = id(f); return (int)(r.a + r.b) + 38; }",
    # Four floats are 16 bytes, two packed SSE eightbytes ([:sse8, :sse8]).
    "struct F4 { float a; float b; float c; float d; }; struct F4 id(struct F4 f) { return f; } " \
    "int main(void) { struct F4 f; f.a = 1.0f; f.b = 2.0f; f.c = 3.0f; f.d = 4.0f; struct F4 r = id(f); " \
    "return (int)(r.a + r.b + r.c + r.d) + 32; }",
    # A mixed { int; double; }: the int and the double fall in separate eightbytes
    # ([:gp, :sse8]), so the result rides one integer register and one xmm.
    "struct M { int i; double d; }; struct M id(struct M m) { return m; } " \
    "int main(void) { struct M m; m.i = 10; m.d = 2.5; struct M r = id(m); return r.i + (int)r.d + 30; }",
    # A mixed { double; long; } is the opposite order ([:sse8, :gp]).
    "struct N { double d; long l; }; struct N id(struct N n) { return n; } " \
    "int main(void) { struct N n; n.d = 2.5; n.l = 7; struct N r = id(n); return (int)r.d + (int)r.l + 33; }",
    # 24 bytes exceeds two eightbytes: a MEMORY argument and MEMORY return, both
    # through a hidden result pointer.
    "struct B { long a; long b; long c; }; struct B add(struct B u, struct B v) { struct B r; " \
    "r.a = u.a + v.a; r.b = u.b + v.b; r.c = u.c + v.c; return r; } " \
    "int main(void) { struct B u; u.a = 1; u.b = 2; u.c = 3; struct B v; v.a = 10; v.b = 20; v.c = 30; " \
    "struct B w = add(u, v); return (int)(w.a + w.b + w.c); }",
    # Odd-sized char structs (1/2/3/4 bytes): a fraction of an eightbyte, copied
    # through a scratch buffer so the 8-byte eightbyte load never reads past them.
    "struct C1 { char a; }; struct C1 id(struct C1 c) { return c; } " \
    "int main(void) { struct C1 c; c.a = 42; struct C1 r = id(c); return r.a; }",
    "struct C2 { char a; char b; }; struct C2 id(struct C2 c) { return c; } " \
    "int main(void) { struct C2 c; c.a = 40; c.b = 2; struct C2 r = id(c); return r.a + r.b; }",
    "struct C3 { char a; char b; char c; }; struct C3 id(struct C3 c) { return c; } " \
    "int main(void) { struct C3 c; c.a = 10; c.b = 14; c.c = 18; struct C3 r = id(c); return r.a + r.b + r.c; }",
    "struct C4 { char a; char b; char c; char d; }; struct C4 id(struct C4 c) { return c; } " \
    "int main(void) { struct C4 c; c.a = 10; c.b = 14; c.c = 8; c.d = 10; struct C4 r = id(c); " \
    "return r.a + r.b + r.c + r.d; }",
    # All-or-nothing: five GP arguments leave only one integer register, so a
    # two-INTEGER-eightbyte struct cannot fit and spills wholly to the stack.
    "struct T { int a; int b; int c; int d; }; " \
    "int f(int p1, int p2, int p3, int p4, int p5, struct T t) { return p1 + p2 + p3 + p4 + p5 + t.a + t.b + t.c + t.d; } " \
    "int main(void) { struct T t; t.a = 1; t.b = 2; t.c = 3; t.d = 4; return f(1, 2, 3, 4, 5, t) + 27; }",
    # All-or-nothing on the SSE side: seven xmm arguments leave one xmm register,
    # so a two-SSE-eightbyte struct spills wholly to the stack.
    "struct D2 { double a; double b; }; " \
    "int f(double a1, double a2, double a3, double a4, double a5, double a6, double a7, struct D2 d) { " \
    "return (int)(a1 + a2 + a3 + a4 + a5 + a6 + a7 + d.a + d.b); } " \
    "int main(void) { struct D2 d; d.a = 1.5; d.b = 2.5; return f(1, 2, 3, 4, 5, 6, 7, d) + 8; }",
    # A nested struct, a union member and an array member all fold into the
    # eightbyte classification: { struct { int; int; }; float[2]; } is [:gp, :sse8].
    "struct In { int a; int b; }; struct S { struct In inner; float f[2]; }; struct S id(struct S s) { return s; } " \
    "int main(void) { struct S s; s.inner.a = 1; s.inner.b = 2; s.f[0] = 1.5f; s.f[1] = 2.5f; struct S r = id(s); " \
    "return r.inner.a + r.inner.b + (int)(r.f[0] + r.f[1]) + 35; }",
    "union U { int i; float f; }; struct SU { union U u; int tag; }; struct SU id(struct SU s) { return s; } " \
    "int main(void) { struct SU s; s.u.i = 40; s.tag = 2; struct SU r = id(s); return r.u.i + r.tag; }",
    # A struct in the fixed part of a variadic function: va_start must advance
    # gp_offset past the struct's eightbytes before reading the variable ints.
    "struct P { int x; int y; }; " \
    "int sum(struct P p, ...) { __builtin_va_list ap; __builtin_va_start(ap, p); int t = p.x + p.y; " \
    "t += __builtin_va_arg(ap, int); t += __builtin_va_arg(ap, int); __builtin_va_end(ap); return t; } " \
    "int main(void) { struct P p; p.x = 10; p.y = 20; return sum(p, 5, 7); }",
    # Accessing a member of a struct returned by value (f(s).x).
    "struct P { int x; int y; }; struct P mk(int a, int b) { struct P p; p.x = a; p.y = b; return p; } " \
    "int main(void) { return mk(40, 2).x + mk(0, 2).y; }",
    # A struct-returning call feeding another (g(f(s))).
    "struct P { int x; int y; }; struct P inc(struct P p) { p.x += 1; p.y += 1; return p; } " \
    "int main(void) { struct P a; a.x = 40; a.y = 0; struct P r = inc(inc(a)); return r.x + r.y; }",
    # return *p reads a whole struct through a pointer.
    "struct P { int x; int y; }; struct P deref(struct P *p) { return *p; } " \
    "int main(void) { struct P a; a.x = 40; a.y = 2; struct P r = deref(&a); return r.x + r.y; }",
    # A struct object initialized from a by-value struct return.
    "struct P { int x; int y; }; struct P mk(int a, int b) { struct P p; p.x = a; p.y = b; return p; } " \
    "int main(void) { struct P t = mk(40, 2); return t.x + t.y; }",
    # Through a function pointer, a register-returned struct.
    "struct P { int x; int y; }; struct P mk(struct P p) { p.x += 1; p.y += 1; return p; } " \
    "int main(void) { struct P (*fp)(struct P) = mk; struct P a; a.x = 40; a.y = 0; struct P r = fp(a); " \
    "return r.x + r.y + 1; }",
    # Through a function pointer, a MEMORY-returned struct (hidden pointer).
    "struct B { long a; long b; long c; }; struct B mk(struct B b) { b.a += 1; return b; } " \
    "int main(void) { struct B (*fp)(struct B) = mk; struct B x; x.a = 40; x.b = 1; x.c = 0; struct B r = fp(x); " \
    "return (int)(r.a + r.b + r.c); }"
  ].freeze

  def test_struct_abi_matches_gcc_exit_codes
    STRUCT_ABI_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # --- GNU __attribute__ aligned/packed layout + ABI (Step 28 Phase A) ------

  # Structs bearing __attribute__((packed)) or ((aligned(N))) passed and
  # returned by value. A packed struct with an unaligned field is MEMORY-class
  # per the psABI (rubycc's classifier matches gcc here), while a naturally
  # aligned aligned(16) struct still rides its registers; each program folds the
  # round-tripped result into an exit code, so gcc's own ABI is the oracle.
  ATTRIBUTE_ABI_DIFFERENTIAL_SOURCES = [
    # A packed { char; int; } is 5 bytes with the int unaligned at offset 1, so
    # it is MEMORY-classified: passed and returned through the stack.
    "struct __attribute__((packed)) P { char c; int i; }; struct P id(struct P p) { return p; } " \
    "int main(void) { struct P p; p.c = 7; p.i = 35; struct P r = id(p); return r.c + r.i; }",
    # A packed { char; long; } is 9 bytes: the long would straddle the eightbyte
    # boundary, another MEMORY case.
    "struct __attribute__((packed)) Q { char c; long l; }; struct Q id(struct Q q) { return q; } " \
    "int main(void) { struct Q q; q.c = 5; q.l = 37; struct Q r = id(q); return r.c + (int)r.l; }",
    # A packed all-char { char; char; char; } has no unaligned field, so it stays
    # a single INTEGER eightbyte in a register.
    "struct __attribute__((packed)) C { char a; char b; char c; }; struct C id(struct C c) { return c; } " \
    "int main(void) { struct C c; c.a = 10; c.b = 14; c.c = 18; struct C r = id(c); return r.a + r.b + r.c; }",
    # An aligned(16) { int; int; } is naturally aligned and 16 bytes: two INTEGER
    # eightbytes, still passed in registers.
    "struct __attribute__((aligned(16))) A { int x; int y; }; struct A id(struct A a) { return a; } " \
    "int main(void) { struct A a; a.x = 40; a.y = 2; struct A r = id(a); return r.x + r.y; }"
  ].freeze

  def test_attribute_layout_abi_matches_gcc_exit_codes
    ATTRIBUTE_ABI_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # sizeof / _Alignof of packed and aligned structs printed to stdout: rubycc's
  # layout must render byte-for-byte identically to gcc's.
  ATTRIBUTE_LAYOUT_SIZEOF_PROGRAM =
    "int printf(char *fmt, ...); " \
    "struct __attribute__((packed)) P { char c; int i; }; " \
    "struct __attribute__((aligned(16))) A { char c; }; " \
    "struct __attribute__((packed, aligned(4))) PA { char c; char d; char e; }; " \
    "struct Plain { char c; int i; }; " \
    "int main(void) { " \
    "printf(\"P %d %d\\n\", (int)sizeof(struct P), (int)_Alignof(struct P)); " \
    "printf(\"A %d %d\\n\", (int)sizeof(struct A), (int)_Alignof(struct A)); " \
    "printf(\"PA %d %d\\n\", (int)sizeof(struct PA), (int)_Alignof(struct PA)); " \
    "printf(\"Plain %d %d\\n\", (int)sizeof(struct Plain), (int)_Alignof(struct Plain)); " \
    "return 0; }"

  def test_attribute_layout_sizeof_matches_gcc_stdout
    rubycc = program_output(ATTRIBUTE_LAYOUT_SIZEOF_PROGRAM, compiler: :rubycc)
    gcc = program_output(ATTRIBUTE_LAYOUT_SIZEOF_PROGRAM, compiler: :gcc)
    assert_equal gcc, rubycc, "rubycc and gcc disagree on sizeof/_Alignof output"
  end

  # --- __builtin_expect / __builtin_alloca / empty __asm__ (Step 28 Phase B) --

  # __builtin_expect(exp, c) has no optimizer weight in rubycc: it evaluates both
  # operands and yields `exp` converted to long. Each program folds that value
  # into an exit code, so gcc's own unoptimized result is the oracle.
  BUILTIN_EXPECT_DIFFERENTIAL_SOURCES = [
    # A truthy exp passes through as the tested value (37 != 0 -> 37).
    "int main(void) { return (int)__builtin_expect(37, 1); }",
    # A falsy exp passes through as 0.
    "int main(void) { return (int)__builtin_expect(0, 1) + 42; }",
    # Used as an if condition: the branch is taken because the tested value is
    # truthy, exactly as gcc's unoptimized build does.
    "int main(void) { int x = 9; if (__builtin_expect(x == 9, 1)) return 42; return 0; }",
    # A falsy hint still drives the else arm.
    "int main(void) { int x = 3; if (__builtin_expect(x == 9, 1)) return 1; return 42; }"
  ].freeze

  def test_builtin_expect_value_matches_gcc_exit_codes
    BUILTIN_EXPECT_DIFFERENTIAL_SOURCES.each do |source|
      assert_equal run_source(source, compiler: :gcc),
                   run_source(source, compiler: :rubycc),
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # __builtin_alloca carves automatic storage from the stack. Each program folds
  # a byte-pattern total (or an alignment flag) into an exit code, so gcc is the
  # oracle for both the runtime effect and the ABI-guaranteed alignment.
  BUILTIN_ALLOCA_DIFFERENTIAL_SOURCES = [
    # Write then read a rising byte pattern through the alloca'd block: the
    # low byte of 0+1+...+9 == 45.
    "int main(void) { unsigned char *p = (unsigned char *)__builtin_alloca(10); " \
    "for (int i = 0; i < 10; i++) p[i] = (unsigned char)i; " \
    "int s = 0; for (int i = 0; i < 10; i++) s += p[i]; return s; }",
    # Two independent blocks: writing the second must not disturb the first.
    "int main(void) { unsigned char *p = (unsigned char *)__builtin_alloca(8); " \
    "unsigned char *q = (unsigned char *)__builtin_alloca(8); " \
    "for (int i = 0; i < 8; i++) p[i] = 1; " \
    "for (int i = 0; i < 8; i++) q[i] = 4; " \
    "int s = 0; for (int i = 0; i < 8; i++) s += p[i] + q[i]; return s; }",
    # The block survives an intervening call (whose own stack arguments must not
    # clobber it): fill it, call a 3-arg helper, then total the block. 1+..+16==136.
    "int add3(int a, int b, int c) { return a + b + c; } " \
    "int main(void) { unsigned char *p = (unsigned char *)__builtin_alloca(16); " \
    "for (int i = 0; i < 16; i++) p[i] = (unsigned char)(i + 1); " \
    "int t = add3(1, 2, 3); " \
    "int s = 0; for (int i = 0; i < 16; i++) s += p[i]; return s + t - t; }",
    # The returned pointer is at least 16-byte aligned, as gcc guarantees.
    "int main(void) { char *p = (char *)__builtin_alloca(1); " \
    "return (((unsigned long)p & 15) == 0) ? 42 : 0; }"
  ].freeze

  def test_builtin_alloca_matches_gcc_exit_codes
    skip "aarch64 __builtin_alloca lowering is not implemented (DESIGN R7 limitation)" if host_target == "aarch64"

    BUILTIN_ALLOCA_DIFFERENTIAL_SOURCES.each do |source|
      assert_equal run_source(source, compiler: :gcc),
                   run_source(source, compiler: :rubycc),
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # An empty __asm__ barrier emits no code, so a program printing around it must
  # produce exactly the surrounding output under both compilers.
  ASM_BARRIER_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "int main(void) { " \
    "printf(\"before\\n\"); " \
    "__asm__ volatile(\"\" ::: \"memory\"); " \
    "printf(\"after\\n\"); " \
    "return 0; }"

  def test_asm_barrier_matches_gcc_stdout
    assert_equal program_output(ASM_BARRIER_PROGRAM, compiler: :gcc),
                 program_output(ASM_BARRIER_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on output around an empty asm barrier"
  end

  # --- casts, null pointer constants and pointer conditions (Step 14) ------

  def test_cast_truncates_int_to_char
    # 298 & 0xFF == 42, so the narrowing cast keeps only the low byte.
    assert_c_exit_status(42, "int main(void) { int x = 298; return (char)x; }", compiler: :rubycc)
  end

  def test_cast_char_to_int_widens
    assert_c_exit_status(65, "int main(void) { char c = 'A'; return (int)c; }", compiler: :rubycc)
  end

  def test_pointer_cast_reinterprets_low_byte
    # Read an int's first byte through a char *: on little-endian x86-64 that
    # is the low byte (298 & 0xFF == 42), proving the cast only retags.
    assert_c_exit_status(
      42, "int main(void) { int x = 298; char *p = (char *)&x; return *p; }", compiler: :rubycc
    )
  end

  def test_void_cast_discards_value
    assert_c_exit_status(42, "int main(void) { int x = 42; (void)x; return x; }", compiler: :rubycc)
  end

  def test_void_cast_of_void_call
    assert_c_program(
      "int puts(char *s); void f(void) { puts(\"cast\"); } " \
      "int main(void) { (void)f(); return 0; }",
      exit_status: 0, stdout: "cast\n", compiler: :rubycc
    )
  end

  def test_null_pointer_constant_assignment_and_comparison
    assert_c_exit_status(
      42, "int main(void) { int *p; p = 0; return p == 0 ? 42 : 7; }", compiler: :rubycc
    )
  end

  def test_null_pointer_constant_comparison_both_orders
    assert_c_exit_status(
      42, "int main(void) { int *p = 0; return (0 == p) == (p != 0 ? 0 : 1) ? 42 : 7; }",
      compiler: :rubycc
    )
  end

  def test_null_pointer_constant_as_argument
    assert_c_exit_status(
      42, "int f(int *p) { return p == 0; } int main(void) { return f(0) ? 42 : 7; }",
      compiler: :rubycc
    )
  end

  def test_null_pointer_constant_as_return_value
    assert_c_exit_status(
      42, "int *g(void) { return 0; } int main(void) { return g() == 0 ? 42 : 7; }",
      compiler: :rubycc
    )
  end

  def test_null_pointer_constant_in_conditional_arms
    assert_c_exit_status(
      42, "int main(void) { int x = 5; int *p = x ? 0 : &x; return p == 0 ? 42 : 7; }",
      compiler: :rubycc
    )
  end

  def test_char_null_terminator_is_a_null_pointer_constant
    # '\0' is a character constant of value 0, so it is a null pointer constant.
    assert_c_exit_status(
      42, "int main(void) { char *p = '\\0'; return p == 0 ? 42 : 7; }", compiler: :rubycc
    )
  end

  def test_pointer_used_directly_as_while_condition
    assert_c_exit_status(
      42, "int main(void) { int a[3]; int *p = a; int n = 0; " \
          "p = 0; while (p) { n++; p = 0; } return n == 0 ? 42 : 7; }",
      compiler: :rubycc
    )
  end

  def test_not_of_null_pointer_is_true
    assert_c_exit_status(
      42, "int main(void) { int *p = 0; if (!p) return 42; return 7; }", compiler: :rubycc
    )
  end

  def test_global_null_pointer_is_zero_initialized
    assert_c_exit_status(
      42, "int *gp = 0; int main(void) { return gp == 0 ? 42 : 7; }", compiler: :rubycc
    )
  end

  def test_null_terminated_linked_list_built_and_traversed
    # Step 13's linked-list test used a self-loop on the last node as a
    # sentinel because the subset then lacked a null pointer constant. With
    # NPC and pointer conditions (Step 14), the list terminates on a real null
    # and "while (p)" walks it to the end.
    assert_c_exit_status(
      42,
      "struct node { int v; struct node *next; }; " \
      "int main(void) { struct node a; struct node b; struct node c; " \
      "a.v = 10; a.next = &b; b.v = 14; b.next = &c; c.v = 18; c.next = 0; " \
      "struct node *p = &a; int sum = 0; " \
      "while (p) { sum += p->v; p = p->next; } return sum; }",
      compiler: :rubycc
    )
  end

  def test_sizeof_null_pointer_cast
    # sizeof measures the cast's type (char *, 8 bytes) without evaluating it,
    # exercising the static-type path for a cast.
    assert_c_exit_status(
      42, "int main(void) { return sizeof((char *)0) * 5 + 2; }", compiler: :rubycc
    )
  end

  # --- Step 15: bitwise, shift and comma operators ---------------------

  def test_bitwise_and
    assert_c_exit_status(2, "int main(void) { return 6 & 3; }", compiler: :rubycc)
  end

  def test_bitwise_or
    assert_c_exit_status(7, "int main(void) { return 6 | 1; }", compiler: :rubycc)
  end

  def test_bitwise_xor
    assert_c_exit_status(5, "int main(void) { return 6 ^ 3; }", compiler: :rubycc)
  end

  def test_bitwise_not_is_desugared_to_xor_minus_one
    # ~5 == -6; taken mod 256 as an exit code that is 250.
    assert_c_exit_status(250, "int main(void) { return ~5; }", compiler: :rubycc)
  end

  def test_left_shift
    assert_c_exit_status(40, "int main(void) { return 5 << 3; }", compiler: :rubycc)
  end

  def test_right_shift_of_positive
    assert_c_exit_status(5, "int main(void) { return 40 >> 3; }", compiler: :rubycc)
  end

  def test_right_shift_of_negative_is_arithmetic
    # -8 >> 1 is -4 with an arithmetic (sign-preserving) shift; -4 mod 256 is 252.
    assert_c_exit_status(252, "int main(void) { int x = -8; return x >> 1; }", compiler: :rubycc)
  end

  def test_bitwise_precedence_and_tighter_than_xor_tighter_than_or
    # 2 | 4 ^ 4 & 5  ==  2 | (4 ^ (4 & 5))  ==  2 | (4 ^ 4)  ==  2 | 0  ==  2.
    assert_c_exit_status(2, "int main(void) { return 2 | 4 ^ 4 & 5; }", compiler: :rubycc)
  end

  def test_shift_is_left_associative
    # 1 << 3 >> 1  ==  (1 << 3) >> 1  ==  8 >> 1  ==  4.
    assert_c_exit_status(4, "int main(void) { return 1 << 3 >> 1; }", compiler: :rubycc)
  end

  def test_additive_binds_tighter_than_shift
    # 1 + 2 << 3  ==  (1 + 2) << 3  ==  24.
    assert_c_exit_status(24, "int main(void) { return 1 + 2 << 3; }", compiler: :rubycc)
  end

  def test_bitwise_and_compound_assignment
    assert_c_exit_status(8, "int main(void) { int x = 12; x &= 10; return x; }", compiler: :rubycc)
  end

  def test_bitwise_or_compound_assignment
    assert_c_exit_status(13, "int main(void) { int x = 12; x |= 1; return x; }", compiler: :rubycc)
  end

  def test_bitwise_xor_compound_assignment
    assert_c_exit_status(10, "int main(void) { int x = 12; x ^= 6; return x; }", compiler: :rubycc)
  end

  def test_left_shift_compound_assignment
    assert_c_exit_status(16, "int main(void) { int x = 1; x <<= 4; return x; }", compiler: :rubycc)
  end

  def test_right_shift_compound_assignment
    assert_c_exit_status(16, "int main(void) { int x = 64; x >>= 2; return x; }", compiler: :rubycc)
  end

  def test_compound_bitwise_narrows_to_char
    # 300 & 15 == 12, still a char after "&="; the store keeps only the low byte.
    assert_c_exit_status(12, "int main(void) { char c = 300; c &= 15; return c; }", compiler: :rubycc)
  end

  def test_comma_operator_yields_right_operand
    assert_c_exit_status(42, "int main(void) { return (1, 2, 42); }", compiler: :rubycc)
  end

  def test_sizeof_of_shift_expression_is_int_via_static_type
    # sizeof(1 << 2) folds through the code-free static-type path: a shift is an
    # int, so its size is 4. (4 * 10 + 2 == 42.)
    assert_c_exit_status(42, "int main(void) { return sizeof(1 << 2) * 10 + 2; }", compiler: :rubycc)
  end

  def test_sizeof_of_comma_expression_measures_right_operand
    # The comma's type (and size) is its right operand's: a char is 1 byte.
    assert_c_exit_status(
      42, "int main(void) { char c; return sizeof(1, c) == 1 ? 42 : 7; }", compiler: :rubycc
    )
  end

  def test_comma_operator_evaluates_left_for_side_effects
    # The left operand's assignment happens, then the right operand is the value.
    assert_c_exit_status(7, "int main(void) { int x = 1; int y = (x = 5, x + 2); return y; }", compiler: :rubycc)
  end

  def test_comma_in_for_step_clause
    # "i++, j++" runs both updates each iteration; j starts at 10 and steps 3 times.
    assert_c_exit_status(
      13, "int main(void) { int i = 0; int j = 10; for (i = 0; i < 3; i++, j++); return j; }",
      compiler: :rubycc
    )
  end

  def test_compound_assignment_through_subscript_evaluates_lvalue_once
    # a[i++] += 5 must evaluate the index (with its side effect) exactly once,
    # so i advances by one and only a[0] is touched.
    assert_c_exit_status(
      245, "int main(void) { int a[3]; a[0] = 0; a[1] = 0; a[2] = 0; int i = 0; " \
           "a[i++] += 5; return a[0] * 100 + i; }",
      compiler: :rubycc
    )
  end

  # These bitwise/shift/comma cases must agree with gcc bit-for-bit on the exit
  # code (including operator precedence, arithmetic right shift and comma
  # sequencing).
  BITWISE_SHIFT_COMMA_DIFFERENTIAL_SOURCES = [
    "int main(void) { return 6 & 3; }",
    "int main(void) { return 6 | 1; }",
    "int main(void) { return 6 ^ 3; }",
    "int main(void) { return ~0 == -1 ? 42 : 7; }",
    "int main(void) { char c = 5; return ~c; }",
    "int main(void) { return 5 << 3; }",
    "int main(void) { return 40 >> 3; }",
    "int main(void) { int x = -8; return x >> 1; }",
    "int main(void) { return -8 >> 2; }",
    "int main(void) { return 2 | 4 ^ 4 & 5; }",
    "int main(void) { return 1 << 3 >> 1; }",
    "int main(void) { return 1 + 2 << 3; }",
    "int main(void) { return 1 << 2 + 3; }",
    "int main(void) { return 5 & 3 | 8; }",
    "int main(void) { int x = 12; x &= 10; x |= 1; x ^= 6; return x; }",
    "int main(void) { int x = 1; x <<= 4; x >>= 2; return x; }",
    "int main(void) { char c = 300; c &= 15; return c; }",
    "int main(void) { return (1, 2, 42); }",
    "int main(void) { int x = 1; int y = (x = 5, x + 2); return y; }",
    "int main(void) { int i = 0; int j = 10; for (i = 0; i < 3; i++, j++); return j; }",
    "int main(void) { int a[3]; a[0] = 0; a[1] = 0; a[2] = 0; int i = 0; a[i++] += 5; return a[0] * 100 + i; }",
    "int main(void) { int a[3]; a[0] = 4; a[1] = 0; a[2] = 0; int i = 0; a[i++] <<= 3; return a[0] + i; }"
  ].freeze

  def test_bitwise_shift_comma_match_gcc_exit_codes
    BITWISE_SHIFT_COMMA_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # These cast/NPC/pointer-condition cases must agree with gcc bit-for-bit on
  # the exit code.
  CAST_AND_NULL_DIFFERENTIAL_SOURCES = [
    "int main(void) { int x = 298; return (char)x; }",
    "int main(void) { return (char)(-1) == -1 ? 42 : 7; }",
    "int main(void) { char c = 'A'; return (int)c; }",
    "int main(void) { int x = 298; char *p = (char *)&x; return *p; }",
    "int main(void) { int x = 42; (void)x; return x; }",
    "int main(void) { int *p; p = 0; return p == 0 ? 42 : 7; }",
    "int f(int *p) { return p == 0; } int main(void) { return f(0) ? 42 : 7; }",
    "int *g(void) { return 0; } int main(void) { return g() == 0 ? 42 : 7; }",
    "int main(void) { int x = 5; int *p = x ? 0 : &x; return p == 0 ? 42 : 7; }",
    "int main(void) { int *p = 0; if (!p) return 42; return 7; }",
    "int *gp = 0; int main(void) { return gp == 0 ? 42 : 7; }",
    "struct node { int v; struct node *next; }; " \
    "int main(void) { struct node a; struct node b; struct node c; " \
    "a.v = 10; a.next = &b; b.v = 14; b.next = &c; c.v = 18; c.next = 0; " \
    "struct node *p = &a; int sum = 0; while (p) { sum += p->v; p = p->next; } return sum; }",
    "int main(void) { char buf[4]; char *p = buf; p[0] = 42; return *(char *)buf; }",
    "int main(void) { int a[3]; int *p = a; if (p) return 42; return 7; }"
  ].freeze

  def test_casts_and_nulls_match_gcc_exit_codes
    CAST_AND_NULL_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # switch/case/default and goto/labels, each checked bit-for-bit against gcc's
  # exit code: matching cases, default, no-match fall-out, fall-through between
  # cases, a nested switch (whose cases stay its own), the break/continue split
  # inside a loop (break leaves the switch, continue reaches the loop), case
  # labels buried in nested statements, and goto's forward, backward and
  # multi-loop-escape jumps.
  SWITCH_GOTO_DIFFERENTIAL_SOURCES = [
    # Basic dispatch: a matching case, the default, and no match with no default.
    "int main(void) { int x = 2; switch (x) { case 1: return 10; case 2: return 20; case 3: return 30; } return 0; }",
    "int main(void) { int x = 9; switch (x) { case 1: return 10; default: return 42; } return 0; }",
    "int main(void) { int x = 9; switch (x) { case 1: return 10; } return 7; }",
    # default need not be last; it is only reached when no case matches.
    "int main(void) { int x = 5; switch (x) { default: return 99; case 5: return 42; } return 0; }",
    # Fall-through: without a break, control runs into the next case's code.
    "int main(void) { int x = 1; int s = 0; switch (x) { case 1: s += 1; case 2: s += 2; case 3: s += 4; } return s; }",
    "int main(void) { int x = 2; int s = 0; switch (x) { case 1: s += 1; case 2: s += 2; case 3: s += 4; } return s; }",
    # break leaves the switch immediately.
    "int main(void) { int x = 1; int s = 0; switch (x) { case 1: s += 1; break; case 2: s += 2; } return s; }",
    # A char control (promoted to int) matched against integer case constants.
    "int main(void) { char c = 'B'; switch (c) { case 65: return 1; case 66: return 2; } return 0; }",
    # A signed case constant.
    "int main(void) { int x = -1; switch (x) { case -1: return 33; default: return 0; } }",
    # A nested switch: the inner case belongs to the inner switch, and the outer
    # case 2 is only reachable by falling through the inner switch's end.
    "int main(void) { int a = 1; int b = 2; switch (a) { case 1: switch (b) { case 2: return 55; } " \
    "case 2: return 3; } return 0; }",
    # Case labels sitting inside nested statements (a block here) still belong to
    # the enclosing switch and are jumped to across the block boundary.
    "int main(void) { int x = 3; int s = 0; switch (x) { case 1: { s += 1; case 3: s += 10; } case 4: s += 100; } return s; }",
    # A loop wrapping a switch: continue passes through the switch to the loop's
    # step, while break only leaves the switch.
    "int main(void) { int s = 0; for (int i = 0; i < 5; i++) { switch (i) { case 2: continue; case 4: break; } " \
    "s += i; } return s; }",
    # continue from within a switch restarts the while loop (never falls out).
    "int main(void) { int i = 0; int n = 0; while (i < 6) { i++; switch (i) { case 3: continue; } n++; } return n; }",
    # goto: a forward jump skipping code.
    "int main(void) { int x = 0; goto skip; x = 99; skip: return x; }",
    # goto: a backward jump forming a loop.
    "int main(void) { int i = 0; int s = 0; loop: if (i < 5) { s += i; i++; goto loop; } return s; }",
    # goto: escaping two nested loops at once.
    "int main(void) { int i; int j; for (i = 0; i < 10; i++) { for (j = 0; j < 10; j++) " \
    "{ if (i * j > 6) goto done; } } done: return i * 10 + j; }",
    # A labeled empty statement as a goto target.
    "int main(void) { int x = 5; goto end; x = 0; end: ; return x; }",
    # A case label folded from a general constant-expression (Step 20's
    # constant evaluator), including a truncating division and a wrapping
    # cast, rather than a bare (optionally signed) literal.
    "int main(void) { int x = 3; switch (x) { case 1 + 2: return 42; default: return 0; } }",
    "int main(void) { int x = -3; switch (x) { case -7 / 2: return 42; default: return 0; } }",
    "int main(void) { int x = 44; switch (x) { case (char)300: return 42; default: return 0; } }"
  ].freeze

  def test_switch_and_goto_match_gcc_exit_codes
    SWITCH_GOTO_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # float/double in-function arithmetic (Step 24 Phase A), each checked
  # bit-for-bit against gcc's exit code. Every case keeps its floating work
  # inside main (Phase A crosses no call boundary), casts the result to int
  # before returning, and stays within a 0..255 exit code. Coverage: the four
  # arithmetic operators for float and for double, all six comparisons, the
  # int<->float<->double conversions in both directions, unary minus, floating
  # conditions (if / while / && / || / ?: / !), mixed int-and-double
  # expressions, sizeof, casts, the f suffix, exponent notation and the
  # leading/trailing-dot literal forms.
  FLOAT_ARITHMETIC_DIFFERENTIAL_SOURCES = [
    # Double four-function arithmetic.
    "int main(void) { double a = 3.5; double b = 2.0; return (int)(a + b); }",
    "int main(void) { double a = 3.5; double b = 2.0; return (int)(a - b); }",
    "int main(void) { double a = 3.5; double b = 2.0; return (int)(a * b); }",
    "int main(void) { double a = 9.0; double b = 2.0; return (int)(a / b); }",
    # Float four-function arithmetic (the f suffix, single precision).
    "int main(void) { float a = 1.5f; float b = 2.5f; return (int)(a + b); }",
    "int main(void) { float a = 5.5f; float b = 2.0f; return (int)(a - b); }",
    "int main(void) { float a = 2.5f; float b = 3.0f; return (int)(a * b); }",
    "int main(void) { float a = 7.5f; float b = 2.5f; return (int)(a / b); }",
    # All six double comparisons, each a 0/1 result.
    "int main(void) { double a = 1.5; double b = 2.5; return a < b; }",
    "int main(void) { double a = 1.5; double b = 2.5; return a > b; }",
    "int main(void) { double a = 2.5; double b = 2.5; return a <= b; }",
    "int main(void) { double a = 2.5; double b = 2.5; return a >= b; }",
    "int main(void) { double a = 2.5; double b = 2.5; return a == b; }",
    "int main(void) { double a = 2.5; double b = 2.5; return a != b; }",
    # Float comparisons.
    "int main(void) { float a = 1.25f; float b = 1.5f; return a < b; }",
    "int main(void) { float a = 1.5f; return a == 1.5f; }",
    # int -> double -> int round trip, and float -> double widening.
    "int main(void) { int i = 7; double d = i; return (int)(d * 2.0); }",
    "int main(void) { double d = 3.9; int i = d; return i; }",
    "int main(void) { float f = 1.25f; double d = f; return (int)(d * 4.0); }",
    "int main(void) { double d = 2.5; float f = (float)d; return (int)(f * 2.0f); }",
    # long -> double and char -> double conversions.
    "int main(void) { long l = 5; double d = l; return (int)(d * 3.0); }",
    "int main(void) { char c = 4; double d = c; return (int)(d + 0.5); }",
    # unsigned int -> double: a value above the signed-int range converts
    # correctly (the whole 0..2^32-1 range), the result scaled back into range.
    "int main(void) { unsigned int u = 3000000000u; double d = u; return (int)(d / 100000000.0); }",
    # Unary minus on double and on float (the sign-bit flip).
    "int main(void) { double x = -2.5; return (int)(-x); }",
    "int main(void) { float f = -1.5f; return (int)(-f * 2.0f); }",
    # Floating values in every control condition.
    "int main(void) { double d = 0.0; if (d) return 1; return 42; }",
    "int main(void) { double d = 1.5; if (d) return 42; return 1; }",
    "int main(void) { double d = 0.0; return !d; }",
    "int main(void) { double d = 3.0; int n = 0; while (d > 0.5) { d = d - 1.0; n++; } return n; }",
    "int main(void) { double a = 1.5; double b = 0.0; return (a > 1.0 && b < 1.0) ? 42 : 7; }",
    "int main(void) { double a = 0.0; double b = 2.0; return (a > 1.0 || b > 1.0) ? 42 : 7; }",
    "int main(void) { double d = 2.5; int r = d > 2.0 ? 10 : 20; return r; }",
    # Mixed int-and-double expressions (the usual arithmetic conversions).
    "int main(void) { int i = 3; return (int)(i + 2.5); }",
    "int main(void) { int i = 10; double d = 4.0; return (int)(i / d); }",
    "int main(void) { double d = 2.5; int i = 3; return (int)(d * i + 1); }",
    # sizeof of the floating types.
    "int main(void) { return sizeof(float) + sizeof(double); }",
    "int main(void) { float f; double d; return sizeof f + sizeof d; }",
    # Exponent and leading/trailing-dot literal forms.
    "int main(void) { double d = 1e2; return (int)d; }",
    "int main(void) { double d = 1.5e-1; return (int)(d * 100.0); }",
    "int main(void) { double d = .5; return (int)(d * 10.0); }",
    "int main(void) { double d = 1.; return (int)(d * 3.0); }",
    # A compound assignment and a running sum on a double accumulator.
    "int main(void) { double d = 1.0; d += 2.5; d *= 2.0; return (int)d; }",
    "int main(void) { double s = 0.0; for (int i = 0; i < 4; i++) s = s + 0.25; return (int)(s * 4.0); }"
  ].freeze

  def test_float_arithmetic_matches_gcc_exit_codes
    FLOAT_ARITHMETIC_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # The extended integer types (Step 17): unsigned wrap-around, signed vs.
  # unsigned division/remainder/shift/comparison, a wide long computation that
  # overflows 32 bits, hexadecimal/octal literals and suffixed literals,
  # narrow-type storage (sign- vs. zero-extension on reload), _Bool's
  # normalization to 0/1 from every source, a pointer round trip through a
  # long, sizeof on every width, integer promotion, and a long switch control
  # expression. Every case masks or sizes its result to stay a 0..255 exit
  # code.
  INTEGER_TYPES_DIFFERENTIAL_SOURCES = [
    # Unsigned wrap-around on overflow and underflow.
    "int main(void) { unsigned int x = 4294967295u; x = x + 1; return x; }",
    "int main(void) { unsigned int x = 0; x = x - 1; return x & 255; }",
    # Signed vs. unsigned division and remainder differ on a negative operand.
    "int main(void) { int a = -7; int b = 2; return a / b; }",
    "int main(void) { unsigned int a = 0xFFFFFFF9; unsigned int b = 2; return a / b; }",
    "int main(void) { int a = -7; int b = 2; return (a % b) & 255; }",
    "int main(void) { unsigned int a = 0xFFFFFFF9; unsigned int b = 2; return a % b; }",
    # Arithmetic (signed) vs. logical (unsigned) right shift.
    "int main(void) { int a = -8; return a >> 1; }",
    "int main(void) { unsigned int a = 0xFFFFFFF8; return a >> 1; }",
    # Unsigned comparison: a large unsigned value outranks a small signed one
    # cast alongside it, and a negative int reads as huge once compared
    # unsigned.
    "int main(void) { unsigned int a = 4000000000u; int b = 100; return a > (unsigned int)b ? 1 : 0; }",
    "int main(void) { int a = -1; unsigned int b = 1; return a > b ? 1 : 0; }",
    # A 64-bit long computation that overflows 32 bits, and extracting its
    # upper half.
    "int main(void) { long x = 4294967296L; x = x + 1; return (int)(x & 255); }",
    "int main(void) { long x = 4294967296L; return (int)(x >> 32); }",
    # Hexadecimal and octal literals.
    "int main(void) { return 0x2A; }",
    "int main(void) { return 052; }",
    # Suffixed literals (u/U, l/L, ul/lu, ll) still add like plain integers.
    "int main(void) { return 10u + 5; }",
    "int main(void) { return 10ul + 5; }",
    "int main(void) { return 10ll + 5; }",
    # short truncates on store, and unsigned char/short wrap instead of
    # sign-extending on overflow.
    "int main(void) { short s = 40000; return s & 255; }",
    "int main(void) { unsigned char c = 200; c = c + 100; return c; }",
    "int main(void) { unsigned char c = 255; c++; return c; }",
    "int main(void) { unsigned short s = 65535; s++; return s; }",
    # A negative short reinterpreted as unsigned short zero-extends instead of
    # sign-extending on reload.
    "int main(void) { short s = -1; unsigned short us = (unsigned short)s; return us & 255; }",
    # _Bool normalizes any nonzero source (an int, a negative int, a nonzero
    # pointer) to 1 and any zero source to 0, including through a parameter.
    "int main(void) { _Bool b = 0; return b; }",
    "int main(void) { _Bool b = 5; return b; }",
    "int main(void) { _Bool b = -1; return b; }",
    "int main(void) { int *p = 0; _Bool b = (_Bool)p; return b; }",
    "int f(_Bool b) { return b; } int main(void) { return f(42); }",
    # A pointer survives a round trip through a long.
    "int main(void) { int x = 7; long addr = (long)&x; int *p = (int *)addr; return *p; }",
    # sizeof on every extended width.
    "int main(void) { return sizeof(char) + sizeof(short) * 10 + sizeof(int) * 100 + sizeof(long); }",
    "int main(void) { return sizeof(unsigned long); }",
    # Integer promotion: a char operand promotes to int before "+", so the sum
    # compares past what a char alone could hold.
    "int main(void) { char c = 100; int x = 100; return (c + x) > 199 ? 1 : 0; }",
    # A long switch control expression.
    "int main(void) { long x = 10; switch (x) { case 10: return 42; default: return 0; } }"
  ].freeze

  def test_integer_types_match_gcc_exit_codes
    INTEGER_TYPES_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # enum and typedef (Step 18): default/explicit/mixed enumerator values, an
  # enum constant used as a switch case label, an enum variable assigned and
  # computed with, a typedef alias for unsigned long arithmetic, a struct
  # typedef accessed by value and through a pointer, a typedef array, a block
  # that shadows a typedef with a variable of the same name, and typedef names
  # in a cast and a sizeof. Each case sizes its result to a 0..255 exit code.
  ENUM_TYPEDEF_DIFFERENTIAL_SOURCES = [
    # Enumerators default to 0, 1, 2, ...; the last one reads back its index.
    "enum Weekday { MON, TUE, WED, THU, FRI }; int main(void) { return FRI; }",
    # Explicit values, and a default that resumes from the previous one plus one.
    "enum E { P = 10, Q, R = 20, S }; int main(void) { return P + Q + R + S; }",
    # Bit-flag style constants combined by addition.
    "enum Bits { A = 1, B = 2, C = 4, D = 8 }; int main(void) { return A + B + C + D; }",
    # A negative explicit value participates in arithmetic.
    "enum Range { LO = -2, HI = 2 }; int main(void) { return (HI - LO) + 40; }",
    # A character-constant enumerator value.
    "enum Ch { X = 'A', Y = 'B' }; int main(void) { return Y - X + 41; }",
    # An enum constant folded into a switch case label.
    "enum Color { RED, GREEN, BLUE }; int main(void) { int c = 2; " \
    "switch (c) { case RED: return 1; case GREEN: return 2; case BLUE: return 42; } return 0; }",
    # An enum variable (an int) assigned and advanced.
    "enum Color { RED, GREEN, BLUE }; int main(void) { enum Color c = GREEN; c = c + 1; return c + 41; }",
    # sizeof of an enum type and of an enum variable are both sizeof(int) == 4.
    "enum Color { RED }; int main(void) { enum Color c = RED; return sizeof(enum Color) + sizeof(c) * 10 - 2; }",
    # A typedef alias for unsigned long carries a computation past 32 bits.
    "typedef unsigned long VALUE; int main(void) { VALUE a = 4294967296; VALUE b = a + 1; " \
    "return (int)(b >> 32) + (int)(b & 255); }",
    # A struct typedef accessed by value.
    "typedef struct { int x; int y; } Point; int main(void) { Point p; p.x = 20; p.y = 22; return p.x + p.y; }",
    # A struct typedef passed and read through a pointer parameter.
    "typedef struct { int x; } Box; int get(Box *b) { return b->x; } " \
    "int main(void) { Box b; b.x = 42; return get(&b); }",
    # A typedef pointer alias written through.
    "typedef int *IntPtr; int main(void) { int a = 30; IntPtr p = &a; *p = *p + 12; return a; }",
    # A typedef array alias.
    "typedef char Buf[4]; int main(void) { Buf b; b[0] = 10; b[1] = 32; return b[0] + b[1]; }",
    # A block-local variable shadows an outer typedef name of the same spelling.
    "typedef int T; int main(void) { T x = 5; { int T = 10; return x + T + 27; } }",
    # A typedef name in a cast and in sizeof.
    "typedef int Elem; int main(void) { Elem a = 100; Elem b = (Elem)200; return (a + b) & 255; }",
    "typedef int T; int main(void) { T x = 40; return sizeof(T) + x - 2; }",
    # An enumerator value folded from a general constant-expression (Step 20's
    # constant evaluator), referring back to an earlier enumerator in the same
    # list.
    "enum E { A = (1 << 4) - 1, B = A + 1 }; int main(void) { return B; }",
    # An array bound and a global initializer folded the same way.
    "enum { N = 5 }; int main(void) { int a[N * 2]; a[9] = 42; return a[9]; }",
    "int g = sizeof(int) * 4 + 26; int main(void) { return g; }"
  ].freeze

  def test_enum_and_typedef_match_gcc_exit_codes
    ENUM_TYPEDEF_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # --- unions and anonymous struct/union members (Step 19) -----------------
  #
  # Every source stays within a 0..255 exit code. The type-punning cases assume
  # x86-64's little-endian layout, which both compilers target, so reading a
  # union through a narrower member sees the low bytes of the wider one.
  UNION_DIFFERENTIAL_SOURCES = [
    # Write the int member, read back its low byte through the char member.
    "union u { int i; char c; }; int main(void) { union u v; v.i = 0x11223344; return v.c; }",
    # sizeof a union is its widest member's, rounded to the widest alignment.
    "union u { char c; int i; long l; }; int main(void) { return sizeof(union u) + 34; }",
    # An anonymous union inside a struct (an RBasic-style common header plus a
    # variant): the variant's members are reached straight off the struct.
    "struct obj { int flags; union { int num; char ch; }; }; " \
    "int main(void) { struct obj o; o.flags = 3; o.num = 39; return o.flags + o.num; }",
    # A deep, transparent path: an anonymous union inside an anonymous struct
    # inside the outer struct, all reached in one flat access.
    "struct outer { int a; struct { int b; union { int c; char d; }; }; }; " \
    "int main(void) { struct outer o; o.a = 1; o.b = 2; o.c = 39; return o.a + o.b + o.c; }",
    # A union pointer's "->" writes one member and reads a narrower one back.
    "union u { int i; char c; }; int main(void) { union u v; union u *p = &v; " \
    "p->i = 0x2A; return p->c; }",
    # Whole-union assignment copies the object, not a single member.
    "union u { int i; char c; }; int main(void) { union u a; a.i = 42; union u b; b = a; return b.i; }",
    # A struct nested inside a union, overlaid with a short: two chars overlay
    # the short's two bytes.
    "union u { struct { char a; char b; } pair; short both; }; " \
    "int main(void) { union u v; v.both = 0; v.pair.a = 20; v.pair.b = 22; return v.pair.a + v.pair.b; }",
    # A typedef'd anonymous union with an array member, fully initialized before
    # readback so no byte is indeterminate.
    "typedef union { int i; char bytes[4]; } Word; " \
    "int main(void) { Word w; w.i = 0; w.bytes[0] = 21; return w.i + 21; }"
  ].freeze

  def test_unions_and_anonymous_members_match_gcc_exit_codes
    UNION_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # Aggregate and string initializers (Step 20): local and global arrays,
  # structs and unions initialized with brace lists (fully, partially with a
  # zero tail, nested, brace-elided, designated and via the "{0}" idiom), char
  # arrays and pointers initialized from string literals, "[]" bound inference
  # with sizeof, and pointer globals bearing address constants. Every exit code
  # stays within 0..255.
  INITIALIZER_DIFFERENTIAL_SOURCES = [
    # A fully initialized local array, read back element by element.
    "int main(void) { int a[3] = {40, 1, 1}; return a[0] + a[1] + a[2]; }",
    # A partially initialized local array: the unlisted tail is zero.
    "int main(void) { int a[5] = {10, 20}; return a[0] + a[1] + a[2] + a[3] + a[4]; }",
    # The "{0}" idiom zeroes a whole aggregate.
    "int main(void) { int a[4] = {0}; return a[0] + a[1] + a[2] + a[3] + 42; }",
    # Brace elision: a flat list fills an array of structs.
    "struct p { int x; int y; }; " \
    "int main(void) { struct p a[2] = {1, 2, 3, 4}; return a[0].x + a[0].y + a[1].x + a[1].y + 32; }",
    # Fully braced (non-elided) array of structs.
    "struct p { int x; int y; }; " \
    "int main(void) { struct p a[2] = { {5, 6}, {7, 8} }; return a[0].x + a[1].y - 4; }",
    # Array designators, out of order, with a zeroed gap.
    "int main(void) { int a[6] = {[5] = 3, [1] = 39}; return a[1] + a[5] + a[0]; }",
    # A designator followed by positional continuation from the next index.
    "int main(void) { int a[4] = {[1] = 10, 20}; return a[0] + a[1] + a[2] + a[3] + 12; }",
    # A local struct initialized positionally.
    "struct p { int a; int b; int c; }; " \
    "int main(void) { struct p s = {12, 13, 14}; return s.a + s.b + s.c + 3; }",
    # A local struct initialized with member designators, out of order.
    "struct p { int a; int b; int c; }; " \
    "int main(void) { struct p s = {.c = 30, .a = 12}; return s.a + s.b + s.c; }",
    # A nested struct with an inner brace.
    "struct in { int x; int y; }; struct out { struct in m; int z; }; " \
    "int main(void) { struct out o = { {1, 2}, 39 }; return o.m.x + o.m.y + o.z; }",
    # A chained member designator reaches a nested field.
    "struct in { int x; int y; }; struct out { struct in m; int z; }; " \
    "int main(void) { struct out o = {.m.y = 41, .z = 1}; return o.m.x + o.m.y + o.z; }",
    # A union defaults to its first member.
    "union u { int i; char c; }; int main(void) { union u v = {66}; return v.c; }",
    # A union member picked by designator.
    "union u { int i; char c; }; int main(void) { union u v = {.c = 67}; return v.c; }",
    # A designator into an anonymous member, reached transparently.
    "struct obj { int flags; union { int num; char ch; }; }; " \
    "int main(void) { struct obj o = {.num = 39, .flags = 3}; return o.flags + o.num; }",
    # A char array initialized by a string literal, its NUL and tail zeroed.
    "int main(void) { char s[8] = \"AB\"; return s[0] + s[1] + s[2] + s[7]; }",
    # A char array whose bound is inferred from the string, measured by sizeof.
    "int main(void) { char s[] = \"hello\"; return sizeof(s) + s[0] - 60; }",
    # A char array initialized by a braced string.
    "int main(void) { char s[4] = { \"cd\" }; return s[0] + s[1] + s[2]; }",
    # An int array whose bound is inferred, measured by sizeof.
    "int main(void) { int a[] = {9, 8, 7, 6, 5}; return sizeof(a) / sizeof(int) * 8 + a[4]; }",
    # A global array read back.
    "int g[3] = {30, 40, 50}; int main(void) { return g[0] + g[1] + g[2] - 78; }",
    # A partially initialized global array with a zeroed tail.
    "int g[5] = {21, 21}; int main(void) { return g[0] + g[1] + g[2] + g[3] + g[4]; }",
    # A global struct read back.
    "struct p { int x; int y; }; struct p g = {19, 23}; " \
    "int main(void) { return g.x + g.y; }",
    # A global char pointer to a string literal.
    "char *s = \"hi!\"; int main(void) { return s[0] + s[1] + s[2] - 100; }",
    # A global char array initialized by a string, plus sizeof.
    "char s[] = \"abcd\"; int main(void) { return sizeof(s) + s[0] - 60; }",
    # A pointer global holding another global's address, dereferenced and used
    # to write back through.
    "int g = 41; int *p = &g; int main(void) { *p = *p + 1; return g; }",
    # A decayed global array name stored in a pointer global.
    "int a[3] = {7, 8, 9}; int *p = a; int main(void) { return p[0] + p[1] + p[2] + 18; }",
    # A global struct with a string-pointer member.
    "struct s { char *name; int v; }; struct s g = {\"Z\", 42}; " \
    "int main(void) { return g.name[0] + g.v - 90; }"
  ].freeze

  def test_initializers_match_gcc_exit_codes
    INITIALIZER_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # Step 21: function pointers (declaration, both address forms, direct and
  # dereferenced calls, callbacks, returning a pointer, struct members,
  # dispatch tables, typedefs, comparisons), stack-passed arguments beyond the
  # sixth, and pointers to whole arrays. Every program exits in 0..255.
  FUNCTION_POINTER_DIFFERENTIAL_SOURCES = [
    # A function pointer declared and assigned from the plain name, then called.
    "int add1(int x) { return x + 1; } " \
    "int main(void) { int (*fp)(int) = add1; return fp(41); }",
    # Assigned from "&f" instead, and called through an explicit dereference.
    "int add1(int x) { return x + 1; } " \
    "int main(void) { int (*fp)(int) = &add1; return (*fp)(41); }",
    # A reassigned function pointer picks a different target at run time.
    "int a(int x) { return x + 1; } int b(int x) { return x * 2; } " \
    "int main(void) { int (*fp)(int) = a; fp = b; return fp(21); }",
    # A pointer to a function pointer, called through a double dereference.
    "int add1(int x) { return x + 1; } " \
    "int main(void) { int (*fp)(int) = add1; int (**pp)(int) = &fp; return (**pp)(41); }",
    # A callback: a function taking a function pointer as a parameter.
    "int apply(int (*f)(int), int v) { return f(v); } int dbl(int x) { return x * 2; } " \
    "int main(void) { return apply(dbl, 21); }",
    # A callback parameter written with function syntax (adjusted to a pointer).
    "int apply(int f(int), int v) { return f(v) + 2; } int inc(int x) { return x + 1; } " \
    "int main(void) { return apply(inc, 39); }",
    # A function that returns a function pointer, immediately called.
    "int inc(int x) { return x + 1; } int (*pick(void))(int) { return inc; } " \
    "int main(void) { return pick()(41); }",
    # A struct member function pointer: stored, then called through the member.
    "struct ops { int (*fp)(int); }; int t(int x) { return x + 2; } " \
    "int main(void) { struct ops o; o.fp = t; return o.fp(40); }",
    # An array of function pointers used as a dispatch table.
    "int a0(int x) { return x + 10; } int a1(int x) { return x + 20; } " \
    "int main(void) { int (*ops[2])(int) = {a0, a1}; return ops[0](11) + ops[1](1); }",
    # A typedef'd function-pointer type.
    "typedef int (*binop)(int, int); int sub(int a, int b) { return a - b; } " \
    "int main(void) { binop f = sub; return f(50, 8); }",
    # Equality and inequality of function pointers, and a null comparison.
    "int f(int x) { return x; } int g(int x) { return x; } " \
    "int main(void) { int (*fp)(int) = f; int (*gp)(int) = 0; " \
    "return (fp == f) * 20 + (fp != g) * 21 + (gp == 0); }",
    # Selecting a function pointer with "?:" and calling the result.
    "int a(int x) { return x + 1; } int b(int x) { return x + 2; } " \
    "int main(void) { int use_a = 1; int (*fp)(int) = use_a ? a : b; return fp(41); }",
    # Seven arguments: one on the stack (an odd push count, so a pad is added).
    "int s7(int a, int b, int c, int d, int e, int f, int g) { return a + b + c + d + e + f + g; } " \
    "int main(void) { return s7(1, 2, 3, 4, 5, 6, 21); }",
    # Eight arguments: two on the stack (an even push count, no pad).
    "int s8(int a, int b, int c, int d, int e, int f, int g, int h) " \
    "{ return a + b + c + d + e + f + g + h; } " \
    "int main(void) { return s8(1, 2, 3, 4, 5, 6, 7, 14); }",
    # Nine arguments: three on the stack (an odd push count again).
    "int s9(int a, int b, int c, int d, int e, int f, int g, int h, int i) " \
    "{ return a + b + c + d + e + f + g + h + i; } " \
    "int main(void) { return s9(1, 2, 3, 4, 5, 6, 7, 8, 6); }",
    # An indirect call passing eight arguments (register + stack split).
    "int s8(int a, int b, int c, int d, int e, int f, int g, int h) " \
    "{ return a + b + c + d + e + f + g + h; } " \
    "int main(void) { int (*fp)(int, int, int, int, int, int, int, int) = s8; " \
    "return fp(1, 2, 3, 4, 5, 6, 7, 14); }",
    # Narrow integer types (char/short) landing in stack-passed argument slots.
    "int f(int a, int b, int c, int d, int e, int g, char h, short i) " \
    "{ return a + b + c + d + e + g + h + i; } " \
    "int main(void) { return f(1, 2, 3, 4, 5, 6, (char)-1, (short)23); }",
    # A stack argument that is itself a function-call result.
    "int id(int x) { return x; } " \
    "int s7(int a, int b, int c, int d, int e, int f, int g) { return a + b + c + d + e + f + g; } " \
    "int main(void) { return s7(1, 2, 3, 4, 5, 6, id(21)); }",
    # "&a" is a pointer to a whole array, dereferenced and subscripted.
    "int main(void) { int a[3] = {10, 20, 12}; int (*p)[3] = &a; " \
    "return (*p)[0] + (*p)[1] + (*p)[2]; }",
    # "sizeof *p" measures the whole pointed-to array, not one element.
    "int main(void) { int a[4]; int (*p)[4] = &a; return sizeof(*p) / sizeof(int) * 10 + 2; }",
    # Adding 1 to a pointer-to-array advances by the whole array's size.
    "int main(void) { int a[6] = {1, 2, 3, 4, 5, 6}; int (*p)[3] = (int (*)[3])a; " \
    "int (*q)[3] = p + 1; return (*q)[0] + (*q)[1] + (*q)[2] + 27; }",
    # A global function pointer initialized from a function name.
    "int inc(int x) { return x + 1; } int (*gp)(int) = inc; " \
    "int main(void) { return gp(41); }",
    # A global function-pointer array (mixing "f" and "&f"), used to dispatch.
    "int a0(int x) { return x + 10; } int a1(int x) { return x + 20; } " \
    "int (*table[2])(int) = {a0, &a1}; " \
    "int main(void) { return table[0](11) + table[1](1); }",
    # A function pointer to an external libc function (abs), called indirectly.
    "int abs(int); int main(void) { int (*fp)(int) = abs; return fp(0 - 42); }"
  ].freeze

  def test_function_pointers_match_gcc_exit_codes
    FUNCTION_POINTER_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # Type qualifiers, _Alignof and _Static_assert (Step 22 Phase A): const
  # objects and parameters that are only read, a const pointer whose pointee is
  # still writable, a "const char *" string, a volatile loop counter, _Alignof
  # of each admitted type, and a program guarded by a satisfied _Static_assert.
  # Every exit code stays within 0..255. static/extern semantics are Phase B, so
  # only their acceptance (not their runtime effect) is exercised elsewhere.
  QUALIFIER_DIFFERENTIAL_SOURCES = [
    # A const local, read back through its own name.
    "int main(void) { const int x = 42; return x; }",
    # A const parameter, read (never written) inside the callee.
    "int f(const int n) { return n + 1; } int main(void) { return f(41); }",
    # A const pointer ("int * const"): p itself is fixed, but "*p" is writable.
    "int main(void) { int x = 5; int * const p = &x; *p = 40; return *p + 2; }",
    # A "const char *" walked byte by byte ('h'=104, 'i'=105).
    "int main(void) { const char *s = \"hi\"; return s[0] + s[1] - 167; }",
    # A volatile loop counter and accumulator summing 0..9.
    "int main(void) { volatile int s = 0; for (volatile int i = 0; i < 10; i++) { s += i; } return s - 3; }",
    # _Alignof of the standard integer types, a pointer and a struct.
    "int main(void) { return _Alignof(int) + 38; }",
    "int main(void) { return _Alignof(long) + 34; }",
    "int main(void) { return _Alignof(char) + 41; }",
    "int main(void) { return _Alignof(int *) + 34; }",
    "struct s { char c; int i; long l; }; int main(void) { return _Alignof(struct s) + 34; }",
    # _Alignof folds as a constant, usable in a constant expression (an array
    # bound here), and equals sizeof for a single scalar.
    "int main(void) { int a[_Alignof(long)]; return sizeof(a) + 34; }",
    # A program guarded by a satisfied file-scope _Static_assert.
    "_Static_assert(sizeof(int) == 4, \"int must be 4 bytes\"); int main(void) { return 42; }",
    # A block-scope _Static_assert that holds, plus const const-folding.
    "int main(void) { _Static_assert(_Alignof(long) == 8, \"long aligns to 8\"); " \
    "const int k = 40; return k + 2; }"
  ].freeze

  def test_qualifiers_alignof_and_static_assert_match_gcc_exit_codes
    QUALIFIER_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  STORAGE_CLASS_DIFFERENTIAL_SOURCES = [
    # A static file-scope function and a static global read and written.
    "static int add(int a, int b) { return a + b; } static int total = 100; " \
    "int main(void) { total = total + add(3, 4); return total - 100; }",
    # A static local counter accumulating across three calls (it is initialized
    # once, not on every entry).
    "int tick(void) { static int n = 0; n = n + 1; return n; } " \
    "int main(void) { tick(); tick(); return tick() + 39; }",
    # A static local array with an initializer, summed.
    "int main(void) { static int a[3] = {10, 20, 30}; return a[0] + a[1] + a[2] - 18; }",
    # A static local array without an initializer lands in .bss (all zero).
    "int main(void) { static int a[4]; int s = 0; for (int i = 0; i < 4; i++) { s += a[i]; } return s + 42; }",
    # A static local struct with an initializer, its members read back.
    "struct p { int x; int y; }; " \
    "int main(void) { static struct p pt = {5, 7}; return pt.x + pt.y + 30; }",
    # A static local struct without an initializer is zero-filled in .bss.
    "struct p { int x; int y; }; " \
    "int main(void) { static struct p pt; return pt.x + pt.y + 42; }",
    # Two same-named static locals in different functions keep independent
    # objects (the unique-name lowering), advancing separately.
    "int f(void) { static int v = 10; return ++v; } " \
    "int g(void) { static int v = 20; return ++v; } " \
    "int main(void) { f(); g(); return f() + g() - 20; }",
    # A static local shadowing an outer automatic variable of the same name.
    "int main(void) { int x = 5; { static int x = 40; return x + 2; } }",
    # A const static local, folded and read back.
    "int main(void) { static const int k = 42; return k; }",
    # A static function's address taken into a function pointer, then called.
    "static int one(void) { return 1; } " \
    "int main(void) { int (*fp)(void) = one; return fp() + 41; }",
    # An extern reference resolved by a definition later in the same unit.
    "extern int shared; int get(void) { return shared; } " \
    "int main(void) { shared = 42; return get(); } int shared;",
    # A block-scope extern referencing a file-scope object defined above.
    "int counter = 0; " \
    "int main(void) { { extern int counter; counter = 42; } return counter; }",
    # A static const table indexed across several calls.
    "static const int squares[4] = {0, 1, 4, 9}; int sq(int i) { return squares[i]; } " \
    "int main(void) { return sq(3) + sq(2) + sq(1) + 28; }"
  ].freeze

  def test_storage_class_semantics_match_gcc_exit_codes
    STORAGE_CLASS_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # Variadic call sites (Step 23 Phase A): a prototype/pointer ending in "...",
  # the default argument promotions on the variable part, and the target ABI's
  # variadic-call metadata. Every program calls a real libc
  # variadic function (printf/snprintf) or a locally defined variadic one, so
  # both its exit code and its stdout are matched against gcc. Each exit code
  # stays within 0..255 (printf/snprintf return their byte counts, kept small).
  VARIADIC_CALL_DIFFERENTIAL_SOURCES = [
    # printf's return value (the number of bytes written) drives the exit code.
    "int printf(const char *, ...); " \
    "int main(void) { return printf(\"value=%d\\n\", 42); }",
    # A char and a short argument promote to int in the variable part (%d).
    "int printf(const char *, ...); " \
    "int main(void) { char c = 65; short s = 1000; return printf(\"%d %d\\n\", c, s); }",
    # A negative char promotes with its sign preserved (sign extension to int).
    "int printf(const char *, ...); " \
    "int main(void) { char c = (char)-5; return printf(\"%d\\n\", c) + 40; }",
    # snprintf stringifies an integer; a hand-written loop counts its length,
    # the size argument being an unsigned long fixed parameter.
    "int snprintf(char *, unsigned long, const char *, ...); " \
    "int main(void) { char buf[16]; snprintf(buf, 16, \"%d\", 12345); " \
    "int n = 0; while (buf[n] != 0) { n = n + 1; } return n + 40; }",
    # A variadic call through a function pointer of variadic type.
    "int printf(const char *, ...); " \
    "int main(void) { int (*fp)(const char *, ...) = printf; return fp(\"%d%d\\n\", 7, 8); }",
    # Nine call arguments (one fixed, eight variable): three ride the stack.
    "int printf(const char *, ...); " \
    "int main(void) { return printf(\"%d %d %d %d %d %d %d %d\\n\", 1, 2, 3, 4, 5, 6, 7, 8); }",
    # A long argument passes through the promotions unchanged (%ld).
    "int printf(const char *, ...); " \
    "int main(void) { long x = 100000; return printf(\"%ld\\n\", x) + 30; }",
    # A locally defined variadic function whose body ignores the variable part
    # (va_* is Phase B): defining and calling it must still work.
    "int first(int a, ...) { return a; } " \
    "int main(void) { return first(42, 1, 2, 3); }"
  ].freeze

  def test_variadic_calls_match_gcc
    VARIADIC_CALL_DIFFERENTIAL_SOURCES.each do |source|
      rubycc = program_output(source, compiler: :rubycc)
      gcc = program_output(source, compiler: :gcc)
      assert_equal gcc, rubycc,
                   "rubycc and gcc disagree on [exit, stdout] for: #{source}"
    end
  end

  # Variadic function definitions (Step 23 Phase B): __builtin_va_list, the
  # __builtin_va_start / __builtin_va_arg / __builtin_va_end trio and the
  # register-save-area prologue. gcc understands the same builtins, so each
  # program is compiled and run by both and its [exit, stdout] compared. Exit
  # codes stay within 0..255.
  VARIADIC_DEFINITION_DIFFERENTIAL_SOURCES = [
    # sum(n, ...) reading n ints: three arguments stay in registers, ...
    "int sum(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n); " \
    "int t = 0, i; for (i = 0; i < n; i = i + 1) t = t + __builtin_va_arg(ap, int); " \
    "__builtin_va_end(ap); return t; } " \
    "int main(void) { return sum(3, 10, 20, 30); }",
    # ... and eight cross from the five register argument slots into the stack
    # overflow area.
    "int sum(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n); " \
    "int t = 0, i; for (i = 0; i < n; i = i + 1) t = t + __builtin_va_arg(ap, int); " \
    "__builtin_va_end(ap); return t; } " \
    "int main(void) { return sum(8, 1, 2, 3, 4, 5, 6, 7, 8); }",
    # Seven named parameters fill every integer register, so the variable part
    # begins in the stack overflow area from its first argument.
    "int seven(int a, int b, int c, int d, int e, int f, int g, ...) { " \
    "__builtin_va_list ap; __builtin_va_start(ap, g); " \
    "int x = __builtin_va_arg(ap, int); int y = __builtin_va_arg(ap, int); " \
    "__builtin_va_end(ap); return a + b + c + d + e + f + g + x + y; } " \
    "int main(void) { return seven(1, 2, 3, 4, 5, 6, 7, 100, 200); }",
    # va_arg(long) and va_arg(char *) mixed: the long is summed and the string's
    # first byte drives the low bits of the exit code.
    "int mix(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n); " \
    "long v = __builtin_va_arg(ap, long); char *s = __builtin_va_arg(ap, char *); " \
    "__builtin_va_end(ap); return (int)v + s[0]; } " \
    "int main(void) { return mix(2, 100L, \"A\"); }",
    # A va_list forwarded to a helper that takes a __builtin_va_list parameter
    # (the vsum pattern): the callee reads through the same tag object.
    "int vsum(int n, __builtin_va_list ap) { int t = 0, i; " \
    "for (i = 0; i < n; i = i + 1) t = t + __builtin_va_arg(ap, int); return t; } " \
    "int forward(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n); " \
    "int r = vsum(n, ap); __builtin_va_end(ap); return r; } " \
    "int main(void) { return forward(4, 5, 6, 7, 8); }",
    # Two va_start/va_end passes over the same list re-read it from the start.
    "int twice(int n, ...) { __builtin_va_list ap; int a, b; " \
    "__builtin_va_start(ap, n); a = __builtin_va_arg(ap, int); __builtin_va_end(ap); " \
    "__builtin_va_start(ap, n); b = __builtin_va_arg(ap, int); __builtin_va_end(ap); " \
    "return a + b; } " \
    "int main(void) { return twice(2, 41, 99); }",
    # A static variadic function called through a variadic function pointer.
    "static int ssum(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n); " \
    "int t = 0, i; for (i = 0; i < n; i = i + 1) t = t + __builtin_va_arg(ap, int); " \
    "__builtin_va_end(ap); return t; } " \
    "int main(void) { int (*fp)(int, ...) = ssum; return fp(4, 1, 2, 3, 4); }",
    # A logf(fmt, ...) that va_starts and forwards to the libc vprintf, so its
    # stdout is matched byte-for-byte against gcc.
    "int vprintf(const char *, __builtin_va_list); " \
    "void logline(const char *fmt, ...) { __builtin_va_list ap; " \
    "__builtin_va_start(ap, fmt); vprintf(fmt, ap); __builtin_va_end(ap); } " \
    "int main(void) { logline(\"n=%d s=%s\\n\", 42, \"ok\"); return 0; }"
  ].freeze

  def test_variadic_definitions_match_gcc
    VARIADIC_DEFINITION_DIFFERENTIAL_SOURCES.each do |source|
      rubycc = program_output(source, compiler: :rubycc)
      gcc = program_output(source, compiler: :gcc)
      assert_equal gcc, rubycc,
                   "rubycc and gcc disagree on [exit, stdout] for: #{source}"
    end
  end

  # The float/double call boundary (Step 24 Phase B): the host ABI's floating
  # argument and return convention. Every case keeps its result an integer 0..255 exit
  # code, casting the floating value before returning, and crosses a real call
  # boundary so the xmm register/stack routing, the al xmm-count, the float/
  # double return in xmm0, the register-save-area SSE walk of va_arg(double) and
  # the .data/.bss floating globals are all exercised against gcc.
  FLOAT_CALL_DIFFERENTIAL_SOURCES = [
    # A double and a float parameter with a matching return.
    "double add(double a, double b) { return a + b; } " \
    "int main(void) { return (int)add(1.5, 2.25); }",
    "float scale(float x, int n) { return x * (float)n; } " \
    "int main(void) { return (int)scale(1.25f, 4); }",
    # An int argument converts to the double parameter at the call.
    "double twice(double x) { return x * 2.0; } " \
    "int main(void) { return (int)twice(21); }",
    # Nine arguments alternating int and double: the two classes draw from their
    # own register sequences (five of six GP, four of eight xmm), so each class's
    # walk must skip over the other's arguments.
    "double mix9(int a, double b, int c, double d, int e, double f, int g, double h, int i) { " \
    "return b + d + f + h + (double)(a + c + e + g + i); } " \
    "int main(void) { return (int)mix9(1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5); }",
    # Nine doubles: the ninth spills past xmm0..7 onto the stack.
    "double sum9(double a, double b, double c, double d, double e, double f, double g, double h, double i) { " \
    "return a + b + c + d + e + f + g + h + i; } " \
    "int main(void) { return (int)sum9(1, 2, 3, 4, 5, 6, 7, 8, 9); }",
    # Both classes overflow at once (seven ints, nine doubles, then one more
    # int): the seventh int, ninth double and final int all land on the stack,
    # where they must keep their left-to-right argument order interleaved.
    "double spill2(int a, int b, int c, int d, int e, int f, int g, " \
    "double p, double q, double r, double s, double t, double u, double v, double w, double x, int y) { " \
    "return p + q + r + s + t + u + v + w + x + (double)(a + b + c + d + e + f + g + y); } " \
    "int main(void) { return (int)spill2(1, 2, 3, 4, 5, 6, 7, " \
    "0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9); }",
    # A chain of double-returning calls used within an expression.
    "double sq(double x) { return x * x; } double half(double x) { return x / 2.0; } " \
    "int main(void) { return (int)(half(sq(4.0)) + sq(2.0)); }",
    # A double returned through a function pointer, and a float through one.
    "double addd(double a, double b) { return a + b; } " \
    "int main(void) { double (*fp)(double, double) = addd; return (int)fp(2.5, 3.5); }",
    "float mulf(float a, float b) { return a * b; } " \
    "int main(void) { float (*fp)(float, float) = mulf; return (int)fp(1.5f, 4.0f); }",
    # va_arg(double) over a variadic function: four doubles averaged, all in xmm.
    "double avg(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n); " \
    "double t = 0.0; int i; for (i = 0; i < n; i = i + 1) t = t + __builtin_va_arg(ap, double); " \
    "__builtin_va_end(ap); return t / (double)n; } " \
    "int main(void) { return (int)avg(4, 2.0, 4.0, 6.0, 8.0); }",
    # A variadic call mixing int and double variable arguments: gp_offset and
    # fp_offset advance independently, so each va_arg reaches its own slot.
    "double blend(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n); " \
    "int a = __builtin_va_arg(ap, int); double b = __builtin_va_arg(ap, double); " \
    "int c = __builtin_va_arg(ap, int); double d = __builtin_va_arg(ap, double); " \
    "__builtin_va_end(ap); return b + d + (double)(a + c); } " \
    "int main(void) { return (int)blend(0, 10, 1.5, 20, 2.5); }",
    # Nine variadic doubles: the ninth is read from the stack overflow area.
    "double vsum9(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n); " \
    "double t = 0.0; int i; for (i = 0; i < n; i = i + 1) t = t + __builtin_va_arg(ap, double); " \
    "__builtin_va_end(ap); return t; } " \
    "int main(void) { return (int)vsum9(9, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0); }",
    # float promotes to double in the variable part, fetched as double.
    "double firstd(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n); " \
    "double v = __builtin_va_arg(ap, double); __builtin_va_end(ap); return v; } " \
    "int main(void) { float f = 3.5f; return (int)firstd(1, f); }",
    # Floating globals and a block-scope static: an initialized double/float lands
    # in .data, an uninitialized one in .bss, and a negative folds through unary
    # minus.
    "double g = 1.5; float f = 2.5f; static double sg = -3.25; " \
    "int main(void) { static float lf = 0.5f; return (int)(g + f + sg + lf); }",
    "double z; float zf; int main(void) { return (int)(z + zf) + 42; }",
    # An integer constant initializing a floating global (int -> double).
    "double d = 7; int main(void) { return (int)d; }"
  ].freeze

  def test_float_call_boundary_matches_gcc_exit_codes
    FLOAT_CALL_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # printf with floating conversions (Step 24 Phase B): a float argument promotes
  # to double in the variable part and al carries the xmm-argument count, so the
  # formatted stdout must match gcc byte-for-byte. Exit codes (printf's byte
  # count) stay small.
  FLOAT_PRINTF_DIFFERENTIAL_SOURCES = [
    # %f and %g on double literals, alongside an int (al = 2 xmm registers).
    "int printf(const char *, ...); " \
    "int main(void) { return printf(\"%f %g %d\\n\", 1.5, 2.5, 7); }",
    # A float argument promotes to double for %f; a double prints too.
    "int printf(const char *, ...); " \
    "int main(void) { float f = 3.5f; double d = 2.25; return printf(\"%.2f %.2f\\n\", f, d); }",
    # Many floating arguments, past the count a single line of xmm registers
    # would hold in a fixed call, so al reports the full eight-or-fewer here.
    "int printf(const char *, ...); " \
    "int main(void) { return printf(\"%g %g %g %g %g\\n\", 1.0, 2.0, 3.0, 4.0, 5.0); }"
  ].freeze

  def test_float_printf_matches_gcc
    FLOAT_PRINTF_DIFFERENTIAL_SOURCES.each do |source|
      rubycc = program_output(source, compiler: :rubycc)
      gcc = program_output(source, compiler: :gcc)
      assert_equal gcc, rubycc,
                   "rubycc and gcc disagree on [exit, stdout] for: #{source}"
    end
  end

  # Assignment through an address (a subscript, a member or a dereferenced
  # pointer) must convert the right-hand side to the target's type before
  # storing, exactly like a plain variable assignment. Each case folds an
  # otherwise-invisible conversion bug (a missing sign-extend or int<->float
  # conversion) into the exit code so gcc's own conversion is the oracle.
  STORE_CONVERSION_DIFFERENTIAL_SOURCES = [
    # A negative int stored into a long struct member must sign-extend.
    "struct s { long m; }; int main(void) { struct s v; v.m = -16; return (v.m == -16) ? 42 : 1; }",
    # A negative int stored into a long array element must sign-extend.
    "int main(void) { long a[2]; a[0] = -16; return (a[0] == -16) ? 42 : 1; }",
    # A negative int stored through a "long *" must sign-extend.
    "int main(void) { long v; long *p = &v; *p = -16; return (*p == -16) ? 42 : 1; }",
    # An int stored into a float struct member must convert int -> float.
    "struct s { float f; }; int main(void) { struct s v; v.f = 3; return (v.f == 3.0f) ? 42 : 1; }",
    # An int stored into a double array element must convert int -> double.
    "int main(void) { double a[2]; a[0] = 3; return (a[0] == 3.0) ? 42 : 1; }",
    # "+=" on a float member computes the usual arithmetic conversion in
    # double, which must narrow back to float before the store.
    "struct s { float f; }; int main(void) { struct s v; v.f = 1.0f; v.f += 2.0; " \
    "return (v.f == 3.0f) ? 42 : 1; }",
    # "+=" with a negative int right-hand side on a long member.
    "struct s { long m; }; int main(void) { struct s v; v.m = 0; v.m += -20; return (v.m == -20) ? 42 : 1; }",
    # The assignment expression's own value is the converted value, not the
    # unconverted one, so it must chain correctly into a further comparison.
    "struct s { long m; }; int main(void) { struct s v; return ((v.m = -16) == -16) ? 42 : 1; }"
  ].freeze

  def test_store_conversions_match_gcc_exit_codes
    STORE_CONVERSION_DIFFERENTIAL_SOURCES.each do |source|
      rubycc_exit = run_source(source, compiler: :rubycc)
      gcc_exit = run_source(source, compiler: :gcc)
      assert_equal gcc_exit, rubycc_exit,
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # A backslash-newline in the middle of an expression is spliced away before
  # tokenizing, so rubycc must agree with gcc that the operands rejoin. The "+"
  # and its operand land on separate physical lines.
  def test_line_continuation_within_expression_matches_gcc
    source = "int main(void) {\n  int total = 40 +\\\n2;\n  return total;\n}\n"
    assert_equal run_source(source, compiler: :gcc),
                 run_source(source, compiler: :rubycc)
  end

  # A backslash-newline splitting an identifier fuses it back into one name, so
  # the split declaration and its later use still resolve to the same variable.
  def test_line_continuation_within_identifier_matches_gcc
    source = "int main(void) {\n  int resu\\\nlt = 6 * 7;\n  return result;\n}\n"
    assert_equal run_source(source, compiler: :gcc),
                 run_source(source, compiler: :rubycc)
  end

  # Object-like macros are pure text substitution, so gcc is the oracle: each
  # program folds its macro use into an exit code and both compilers must agree.
  MACRO_DIFFERENTIAL_SOURCES = [
    # A plain object macro standing in for a return value.
    "#define ANSWER 42\nint main(void) { return ANSWER; }\n",
    # A parenthesized expression macro, kept intact by the surrounding parens.
    "#define TWICE (2 * 3)\nint main(void) { return TWICE * 7; }\n",
    # A macro defined in terms of other macros, expanded by rescanning.
    "#define A 6\n#define B 7\n#define PRODUCT (A * B)\nint main(void) { return PRODUCT; }\n"
  ].freeze

  def test_object_macros_match_gcc_exit_codes
    MACRO_DIFFERENTIAL_SOURCES.each do |source|
      assert_equal run_source(source, compiler: :gcc),
                   run_source(source, compiler: :rubycc),
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # Function-like macros are text substitution with argument expansion and
  # rescanning, so gcc is the oracle: each program folds a macro call into its
  # exit code and both compilers must agree.
  FUNCTION_MACRO_DIFFERENTIAL_SOURCES = [
    # A macro used twice with different arguments.
    "#define SQR(x) ((x) * (x))\nint main(void) { return SQR(3) + SQR(4) - 33; }\n",
    # A conditional-expression macro whose call spans a newline.
    "#define MAX(a, b) ((a) > (b) ? (a) : (b))\n" \
    "int main(void) { return MAX(40, 2) + MAX(1,\n2); }\n",
    # A macro whose replacement calls another macro (rescanning).
    "#define ADD(a, b) ((a) + (b))\n#define DOUBLE(x) ADD(x, x)\n" \
    "int main(void) { return DOUBLE(21); }\n"
  ].freeze

  def test_function_macros_match_gcc_exit_codes
    FUNCTION_MACRO_DIFFERENTIAL_SOURCES.each do |source|
      assert_equal run_source(source, compiler: :gcc),
                   run_source(source, compiler: :rubycc),
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # The "#" and "##" operators are text operations, so gcc is again the oracle:
  # the pasted identifier must name the same variable and the stringized label
  # must print byte-for-byte, so [exit, stdout] has to agree.
  SHOW_PROGRAM = "int printf(const char *format, ...);\n" \
                 "#define SHOW(expr) printf(\"%s = %d\\n\", #expr, (expr))\n" \
                 "#define MAX(a, b) ((a) > (b) ? (a) : (b))\n" \
                 "int main(void) { int n = 5; SHOW(MAX(n, 8)); SHOW(n * n); return 0; }\n"

  def test_stringize_program_matches_gcc_stdout_and_exit
    assert_equal program_output(SHOW_PROGRAM, compiler: :gcc),
                 program_output(SHOW_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on [exit, stdout] for the stringize program"
  end

  PASTE_DIFFERENTIAL_SOURCES = [
    # "##" pastes a prefix onto a name to reach the variable declared under it.
    "#define VAR(name) slot_ ## name\n" \
    "int main(void) { int VAR(a) = 40; int VAR(b) = 2; return slot_a + slot_b; }\n",
    # A pasted number fragment and a left-to-right chain fold into the result.
    "#define CAT(a, b) a ## b\n#define TRIP(a, b, c) a ## b ## c\n" \
    "int main(void) { return CAT(3, 9) + TRIP(1, 0, 0) - 97; }\n"
  ].freeze

  def test_paste_programs_match_gcc_exit_codes
    PASTE_DIFFERENTIAL_SOURCES.each do |source|
      assert_equal run_source(source, compiler: :gcc),
                   run_source(source, compiler: :rubycc),
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # Conditional inclusion is again pure text selection, so gcc is the oracle:
  # each program compiles to whichever return value its #if chain selects, and
  # both compilers must agree.
  CONDITIONAL_DIFFERENTIAL_SOURCES = [
    # A defined macro drives an #if/#else that picks the return value.
    "#define WIDE 1\n" \
    "#if WIDE\nint main(void) { return 42; }\n#else\nint main(void) { return 7; }\n#endif\n",
    # An #elif chain with a computed condition and a #undef in between.
    "#define LEVEL 2\n#undef LEVEL\n#define LEVEL 3\n" \
    "int main(void) {\n" \
    "#if LEVEL == 1\n  return 1;\n#elif LEVEL == 3\n  return 42;\n#else\n  return 9;\n#endif\n}\n",
    # #ifndef guarding a fallback default, plus defined() in the expression.
    "#define BASE 40\n" \
    "int main(void) {\n#ifndef BASE\n  return 0;\n#endif\n" \
    "#if defined(BASE) && BASE + 2 == 42\n  return 42;\n#else\n  return 1;\n#endif\n}\n"
  ].freeze

  def test_conditional_compilation_matches_gcc_exit_codes
    CONDITIONAL_DIFFERENTIAL_SOURCES.each do |source|
      assert_equal run_source(source, compiler: :gcc),
                   run_source(source, compiler: :rubycc),
                   "rubycc and gcc disagree on exit code for: #{source}"
    end
  end

  # "\x" and octal escapes decode to bytes, so gcc is the oracle: the mixed
  # hex/octal/named spelling must print byte-for-byte identical stdout.
  HEX_OCTAL_ESCAPE_PROGRAM = "int printf(const char *format, ...);\n" \
                             "int main(void) { printf(\"\\x41\\102\\x43\\n\"); return 0; }\n"

  def test_hex_and_octal_escapes_match_gcc_stdout_and_exit
    assert_equal program_output(HEX_OCTAL_ESCAPE_PROGRAM, compiler: :gcc),
                 program_output(HEX_OCTAL_ESCAPE_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on [exit, stdout] for mixed hex/octal escapes"
  end

  # The eleven simple escape sequences of 6.4.4.4p1, printed as their byte
  # values from character constants and echoed from a string literal, so gcc
  # decides every one of them. "\?" is the odd member: it denotes a plain '?'
  # and exists only to break up a would-be trigraph, so an unescaped '?' in the
  # same run must produce the identical byte.
  SIMPLE_ESCAPE_PROGRAM = "int printf(const char *format, ...);\n" \
                          "int main(void) {\n" \
                          "  printf(\"%d %d %d %d %d %d %d %d %d %d %d %d\\n\",\n" \
                          "         '\\'', '\\\"', '\\?', '?', '\\\\',\n" \
                          "         '\\a', '\\b', '\\f', '\\n', '\\r', '\\t', '\\v');\n" \
                          "  printf(\"[%s]\\n\", \"\\'\\\"\\?q\\\\\\a\\b\\f\\v\");\n" \
                          "  return 0;\n}\n"

  def test_simple_escapes_match_gcc_stdout_and_exit
    assert_equal program_output(SIMPLE_ESCAPE_PROGRAM, compiler: :gcc),
                 program_output(SIMPLE_ESCAPE_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on [exit, stdout] for the simple escape sequences"
  end

  # 6.7.6.3p7: an unsized array parameter adjusts to a pointer, so a caller may
  # pass an array by decay and the callee may index it as usual.
  ARRAY_PARAMETER_PROGRAM = "int sum(int a[], int n) { int i; int total = 0; " \
                            "for (i = 0; i < n; i = i + 1) total = total + a[i]; return total; } " \
                            "int main(void) { int values[5] = {1, 2, 3, 4, 5}; return sum(values, 5); }"

  def test_unsized_array_parameter_matches_gcc_exit_code
    assert_equal run_source(ARRAY_PARAMETER_PROGRAM, compiler: :gcc),
                 run_source(ARRAY_PARAMETER_PROGRAM, compiler: :rubycc)
  end

  # --- __int128 / unsigned __int128 (Step 28 Phase C4) -----------------------

  # The rb_mul_size_overflow shape from <ruby.h>'s memory.h, driven with (a,b,max)
  # triples spanning: no overflow, product > max within 128 bits, a product that
  # needs the high word, and max = SIZE_MAX. gcc is the oracle for both the 0/1
  # outcome and the low-word result printed on success.
  INT128_MUL_OVERFLOW_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "int mul_ov(unsigned long a, unsigned long b, unsigned long max, unsigned long *c) { " \
    "  unsigned __int128 da, db, c2; " \
    "  da = a; db = b; c2 = da * db; " \
    "  if (c2 > max) return 1; " \
    "  *c = (unsigned long)c2; return 0; } " \
    "void one(unsigned long a, unsigned long b, unsigned long max) { " \
    "  unsigned long c = 0; int r = mul_ov(a, b, max, &c); " \
    "  printf(\"%d %lu\\n\", r, r ? 0 : c); } " \
    "int main(void) { " \
    "  one(3, 4, 100); " \
    "  one(3, 4, 10); " \
    "  one(0xFFFFFFFFUL, 0xFFFFFFFFUL, 0xFFFFFFFFFFFFFFFFUL); " \
    "  one(0x100000000UL, 0x100000000UL, 0xFFFFFFFFFFFFFFFFUL); " \
    "  one(2, 5, 10); " \
    "  return 0; }"

  def test_int128_mul_overflow_matches_gcc_stdout
    assert_equal program_output(INT128_MUL_OVERFLOW_PROGRAM, compiler: :gcc),
                 program_output(INT128_MUL_OVERFLOW_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on the rb_mul_size_overflow shape"
  end

  # The mixed compare "(unsigned __int128)x * y > (unsigned long)max" as a truth
  # table over several x, y and max (including SIZE_MAX): the narrower operand
  # must convert up to the 128-bit type (unsigned wins) and compare there.
  INT128_MIXED_COMPARE_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "int main(void) { " \
    "  unsigned long xs[4]; unsigned long ys[3]; unsigned long ms[4]; " \
    "  xs[0]=0; xs[1]=1; xs[2]=100; xs[3]=0xFFFFFFFFUL; " \
    "  ys[0]=0; ys[1]=2; ys[2]=100; " \
    "  ms[0]=0; ms[1]=50; ms[2]=10000; ms[3]=0xFFFFFFFFFFFFFFFFUL; " \
    "  for (int i=0;i<4;i++) for (int j=0;j<3;j++) for (int k=0;k<4;k++) " \
    "    printf(\"%d\", (unsigned __int128)xs[i] * ys[j] > (unsigned long)ms[k]); " \
    "  printf(\"\\n\"); return 0; }"

  def test_int128_mixed_compare_matches_gcc_stdout
    assert_equal program_output(INT128_MIXED_COMPARE_PROGRAM, compiler: :gcc),
                 program_output(INT128_MIXED_COMPARE_PROGRAM, compiler: :rubycc)
  end

  # A signed __int128 converted from a negative long sign-fills its high half, so
  # it compares as a negative value; a truncating cast recovers the low long.
  INT128_SIGNED_CONVERT_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "int main(void) { " \
    "  long a = -5; __int128 x = a; __int128 y = 3; " \
    "  printf(\"%d %d %d %d %d\\n\", x < y, x > y, x == y, x <= y, x < 0); " \
    "  __int128 z = -1; printf(\"%d\\n\", z < 0); " \
    "  printf(\"%ld\\n\", (long)x); return 0; }"

  def test_int128_signed_conversion_matches_gcc_stdout
    assert_equal program_output(INT128_SIGNED_CONVERT_PROGRAM, compiler: :gcc),
                 program_output(INT128_SIGNED_CONVERT_PROGRAM, compiler: :rubycc)
  end

  # 128-bit shift (Step 95), the last compile blocker for bigdecimal (bits.h's
  # nlz_int128 does `x >> 64`). Each shift is printed as its two 8-byte halves so
  # the whole 128-bit result is compared, over counts spanning the three ranges
  # the double-word lowering splits on — 0, below 64, exactly 64, above 64 and
  # 127 — for `<<`, logical `>>` (unsigned) and arithmetic `>>` (a negative
  # signed value), and both a variable count and the constant `>> 64`/`<< 64`.
  INT128_SHIFT_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "typedef union { __int128 s; unsigned __int128 u; unsigned long h[2]; } S; " \
    "static void show(unsigned __int128 v) { S s; s.u = v; printf(\"%lu:%lu \", s.h[0], s.h[1]); } " \
    "int main(void) { " \
    "  S in; in.h[0] = 0x0123456789abcdefUL; in.h[1] = 0xfedcba9876543210UL; " \
    "  unsigned __int128 u = in.u; __int128 sn = in.s; " \
    "  int counts[7]; counts[0]=0; counts[1]=1; counts[2]=63; counts[3]=64; counts[4]=65; counts[5]=96; counts[6]=127; " \
    "  for (int i = 0; i < 7; i++) { int n = counts[i]; " \
    "    show(u >> n); show(u << n); show((unsigned __int128)(sn >> n)); show((unsigned __int128)(sn << n)); } " \
    "  show(u >> 64); show(u << 64); show(u >> 32); show(u << 100); " \
    "  show((unsigned __int128)(sn >> 64)); show((unsigned __int128)(sn >> 100)); " \
    "  printf(\"\\n\"); return 0; }"

  def test_int128_shift_matches_gcc_stdout
    assert_equal program_output(INT128_SHIFT_PROGRAM, compiler: :gcc),
                 program_output(INT128_SHIFT_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on 128-bit shift"
  end

  # `register` on a parameter (Step 96) — the one storage class 6.7.6.3p2 admits
  # there, and the shape bigdecimal's missing/dtoa.c uses
  # ("hi0bits(register ULong x)"). It has no effect on the generated value, so
  # the check is that the parameter still behaves like any other: read, written,
  # address-free arithmetic, and passed on. `register` locals appear too, the
  # form the same file uses inside its bodies.
  REGISTER_PARAM_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "static unsigned hi0bits(register unsigned long x) { " \
    "  register unsigned n = 0; " \
    "  while (x && !(x & 0x8000000000000000UL)) { x = x << 1; n = n + 1; } " \
    "  return n; } " \
    "static long acc(register long a, register long b, long c) { a = a + b; return a * c; } " \
    "int main(void) { " \
    "  printf(\"%u %u %u\\n\", hi0bits(1UL), hi0bits(0x8000000000000000UL), hi0bits(0UL)); " \
    "  printf(\"%ld %ld\\n\", acc(3, 4, 5), acc(-2, 7, 3)); " \
    "  return 0; }"

  def test_register_parameter_matches_gcc_stdout
    assert_equal program_output(REGISTER_PARAM_PROGRAM, compiler: :gcc),
                 program_output(REGISTER_PARAM_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on a `register` parameter"
  end

  # A floating constant *expression* in a static initializer (Step 97), the
  # shape bigdecimal's missing/dtoa.c uses for its tinytens[] table
  # ("9007199254740992.*9007199254740992.e-256"). Printed at %.17g so the exact
  # double is compared, not a rounded rendering. The `intsem` row is the trap the
  # folding must not fall into: with no floating operand the expression is an
  # integer constant expression and keeps integer semantics, so 7/2 is 3.0 —
  # folding it in floating point would wrongly give 3.5.
  STATIC_FLOAT_FOLD_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "static const double tinytens[] = { 1e-16, 1e-32, 1e-64, 1e-128, " \
    "    9007199254740992.*9007199254740992.e-256 }; " \
    "static const double sums[] = { 1.5 + 2.25, 10.0 - 0.5, 3.0 * 1.5, 7.0 / 2.0, -2.5 * 4, 2 * 1.25 }; " \
    "static const double intsem[] = { 7 / 2, 1 + 2, -9 / 4 }; " \
    "static const float singles[] = { 1.5f * 2.0f, 7.0f / 2.0f }; " \
    "double gd = 2.5 * 4; " \
    "int main(void) { " \
    "  for (int i = 0; i < 5; i++) printf(\"t%d=%.17g\\n\", i, tinytens[i]); " \
    "  for (int i = 0; i < 6; i++) printf(\"s%d=%.17g\\n\", i, sums[i]); " \
    "  for (int i = 0; i < 3; i++) printf(\"i%d=%.17g\\n\", i, intsem[i]); " \
    "  for (int i = 0; i < 2; i++) printf(\"f%d=%.9g\\n\", i, (double)singles[i]); " \
    "  printf(\"gd=%.17g\\n\", gd); return 0; }"

  def test_static_float_constant_folding_matches_gcc_stdout
    assert_equal program_output(STATIC_FLOAT_FOLD_PROGRAM, compiler: :gcc),
                 program_output(STATIC_FLOAT_FOLD_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on folding a floating constant expression in a static initializer"
  end

  # A high-word-bearing product truncated back to unsigned long / unsigned int.
  INT128_TRUNCATE_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "int main(void) { " \
    "  unsigned __int128 c = (unsigned __int128)0xFFFFFFFFUL * (unsigned __int128)0x100000001UL; " \
    "  printf(\"%lu %u\\n\", (unsigned long)c, (unsigned)c); return 0; }"

  def test_int128_truncating_cast_matches_gcc_stdout
    assert_equal program_output(INT128_TRUNCATE_PROGRAM, compiler: :gcc),
                 program_output(INT128_TRUNCATE_PROGRAM, compiler: :rubycc)
  end

  # Addition across the low-word carry boundary and subtraction with a borrow,
  # for both signednesses; gcc is the oracle for the truncated low results.
  INT128_ADD_SUB_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "int main(void) { " \
    "  unsigned __int128 a = (unsigned __int128)0xFFFFFFFFFFFFFFFFUL; " \
    "  unsigned __int128 s = a + (unsigned __int128)1; " \
    "  unsigned __int128 d = s - (unsigned __int128)1; " \
    "  __int128 sa = -3; __int128 sb = 10; __int128 diff = sb - sa; __int128 sum = sa + sb; " \
    "  printf(\"%lu %lu %ld %ld\\n\", (unsigned long)s, (unsigned long)d, (long)diff, (long)sum); " \
    "  return 0; }"

  def test_int128_add_sub_matches_gcc_stdout
    assert_equal program_output(INT128_ADD_SUB_PROGRAM, compiler: :gcc),
                 program_output(INT128_ADD_SUB_PROGRAM, compiler: :rubycc)
  end

  # A 16-byte struct containing a single __int128 passes by value in two integer
  # registers, exactly as gcc classifies it; the callee reads back both halves.
  INT128_STRUCT_BYVALUE_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "struct W { unsigned __int128 x; }; " \
    "unsigned long low(struct W w) { return (unsigned long)w.x; } " \
    "int main(void) { struct W w; w.x = (unsigned __int128)0xFFFFFFFFUL * (unsigned __int128)3; " \
    "  printf(\"%lu\\n\", low(w)); return 0; }"

  def test_int128_struct_passed_by_value_matches_gcc_stdout
    assert_equal program_output(INT128_STRUCT_BYVALUE_PROGRAM, compiler: :gcc),
                 program_output(INT128_STRUCT_BYVALUE_PROGRAM, compiler: :rubycc)
  end

  # An array of function pointers whose bound is deduced from its initializer,
  # written with the "[]" buried inside the parenthesized declarator
  # "int (*ops[])(int)" (Step 98, driven by redcarpet's smartypants_cb_ptrs).
  # The dispatch through ops[i] and the sizeof both depend on the length being
  # inferred as gcc infers it.
  FUNCTION_POINTER_ARRAY_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "static int add1(int x) { return x + 1; } " \
    "static int dbl(int x) { return x * 2; } " \
    "static int neg(int x) { return -x; } " \
    "static int (*ops[])(int) = { 0, add1, dbl, neg }; " \
    "int main(void) { " \
    "  int total = 0; " \
    "  for (int i = 1; i < 4; i++) total += ops[i](10); " \
    "  printf(\"%d %d\\n\", total, (int)(sizeof(ops) / sizeof(ops[0]))); " \
    "  return 0; }"

  def test_function_pointer_array_matches_gcc_stdout
    assert_equal program_output(FUNCTION_POINTER_ARRAY_PROGRAM, compiler: :gcc),
                 program_output(FUNCTION_POINTER_ARRAY_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on a deduced-size array of function pointers"
  end

  # Passing a pointer whose pointee differs only in signedness (unsigned char* /
  # uint8_t* where char* is wanted, and the reverse) -- gcc's -Wpointer-sign
  # case, which rubycc accepts (Step 98, driven by redcarpet passing a uint8_t*
  # to strncmp). The signed char* argument to firstchar covers the same-
  # signedness char family case (char <-> signed char). The run confirms the
  # reinterpretation is a no-op: the bytes are compared and counted identically
  # to gcc.
  POINTER_SIGN_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "unsigned long strlen(const char *s); " \
    "int strncmp(const char *a, const char *b, unsigned long n); " \
    "typedef unsigned char u8; " \
    "static int firstbyte(const u8 *p) { return (int)p[0]; } " \
    "static int firstchar(const char *p) { return (int)p[0]; } " \
    "int main(void) { " \
    "  u8 a[] = \"hello\"; char b[] = \"help\"; signed char s[] = \"Z\"; " \
    "  unsigned long n = strlen(a); " \
    "  int c = strncmp(a, b, 3); " \
    "  int d = strncmp(a, b, 4); " \
    "  int e = firstbyte(b); " \
    "  int f = firstchar(s); " \
    "  printf(\"%lu %d %d %d %d\\n\", n, c, d < 0 ? -1 : (d > 0 ? 1 : 0), e, f); " \
    "  return 0; }"

  def test_pointer_sign_mismatch_matches_gcc_stdout
    assert_equal program_output(POINTER_SIGN_PROGRAM, compiler: :gcc),
                 program_output(POINTER_SIGN_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on passing a char-signedness-mismatched pointer"
  end

  # Multidimensional arrays (Step 99, driven by date's monthtab[2][13]): a
  # static const 2D global and a 3D global with nested-brace initializers, a
  # local 2D array, indexing a[i][j] (the row a[i] decays to a pointer), taking
  # &a[i][j] and writing through it, a 2D array parameter adjusting to
  # int(*)[3], passing a row as int*, a pointer-to-array int(*)[3], and sizeof
  # of each whole array -- all compared against gcc.
  MULTIDIM_ARRAY_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "static const int monthtab[2][13] = { " \
    "  { 0,31,59,90,120,151,181,212,243,273,304,334,365 }, " \
    "  { 0,31,60,91,121,152,182,213,244,274,305,335,366 } }; " \
    "static int grid3[2][2][2] = { {{1,2},{3,4}}, {{5,6},{7,8}} }; " \
    "static int sum2d(int a[][3], int rows) { " \
    "  int s = 0; for (int i = 0; i < rows; i++) for (int j = 0; j < 3; j++) s += a[i][j]; return s; } " \
    "static int rowsum(int *r, int n) { int s = 0; for (int k = 0; k < n; k++) s += r[k]; return s; } " \
    "int main(void) { " \
    "  int m[2][3] = { {1,2,3}, {4,5,6} }; " \
    "  int *p = &m[1][2]; *p = 100; m[0][1] = 20; " \
    "  int (*pa)[3] = m; " \
    "  printf(\"%d %d %d %d %d %d %d %d\\n\", " \
    "    sum2d(m, 2), rowsum(m[0], 3), pa[1][0] + (*pa)[2], " \
    "    monthtab[1][2], grid3[1][0][1], " \
    "    (int)sizeof(monthtab), (int)sizeof(m), (int)sizeof(grid3)); " \
    "  return 0; }"

  def test_multidimensional_arrays_match_gcc_stdout
    assert_equal program_output(MULTIDIM_ARRAY_PROGRAM, compiler: :gcc),
                 program_output(MULTIDIM_ARRAY_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on multidimensional array layout / indexing"
  end

  # sizeof(<expression>) folded inside an array bound at parse time (Step 100,
  # driven by date's "char fmt[sizeof(timefmt) + ...]"): sizeof of a named array
  # object (undecayed, the whole array), of a string literal, and of a string
  # literal's element -- the last two being ruby.h's rb_strlen_lit shape
  # "sizeof(s) / sizeof(s[0]) - 1". Exercised in both a file-scope array bound
  # (gtab) and local ones (fmt, two); every sizeof must match gcc's.
  SIZEOF_ARRAY_BOUND_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "static const char tf[] = \"T%H:%M:%S\"; " \
    "static const char zn[] = \"%:z\"; " \
    "static int gtab[sizeof(tf)]; " \
    "int main(void) { " \
    "  char fmt[sizeof(tf) + sizeof(zn) + (sizeof(\".%N\") / sizeof(\".%N\"[0]) - 1) + 20]; " \
    "  char two[sizeof(zn[0]) + sizeof(tf)]; " \
    "  printf(\"%d %d %d\\n\", (int)sizeof(fmt), (int)sizeof(gtab), (int)sizeof(two)); " \
    "  return 0; }"

  def test_sizeof_in_array_bound_matches_gcc_stdout
    assert_equal program_output(SIZEOF_ARRAY_BOUND_PROGRAM, compiler: :gcc),
                 program_output(SIZEOF_ARRAY_BOUND_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on folding sizeof(expr) in an array bound"
  end

  # A static initializer that casts a function designator to a differently-typed
  # function pointer (Step 101, driven by date's tmx_funcs vtable
  # "(VALUE (*)(void *))m_real_year"): the address constant is the function's own
  # symbol, and the explicit cast reinterprets the pointer type with no signature
  # check. Covered in a struct of function pointers and an array of them; calling
  # through the reinterpreted pointers must behave as gcc's does.
  STATIC_FUNCTION_POINTER_CAST_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "typedef long VALUE; " \
    "static VALUE f_year(int *x) { return 2026 + *x; } " \
    "static int f_mon(int *x) { return 7 + *x; } " \
    "static int f_id(int x) { return x; } " \
    "struct funcs { VALUE (*year)(void *); int (*mon)(void *); }; " \
    "static const struct funcs F = { (VALUE (*)(void *))f_year, (int (*)(void *))f_mon }; " \
    "static int (*idtab[])(int) = { (int (*)(int))f_id, f_id }; " \
    "int main(void) { " \
    "  int d = 3; " \
    "  VALUE (*yp)(void *) = F.year; " \
    "  printf(\"%ld %d %d\\n\", yp(&d), F.mon(&d), idtab[0](40) + idtab[1](2)); " \
    "  return 0; }"

  def test_static_function_pointer_cast_matches_gcc_stdout
    assert_equal program_output(STATIC_FUNCTION_POINTER_CAST_PROGRAM, compiler: :gcc),
                 program_output(STATIC_FUNCTION_POINTER_CAST_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on a function-pointer cast in a static initializer"
  end

  # The #line directive (Step 102, driven by date's gperf-generated zonetab.h):
  # it presumes the next line's number and, given a string, the file name, both
  # feeding __LINE__/__FILE__. Setting a virtual file name makes __FILE__
  # deterministic across compilers (otherwise it is the temp path), so the two
  # outputs are comparable. A bare "#line 5" keeps the presumed name.
  PREPROCESSOR_LINE_PROGRAM =
    "int printf(const char *fmt, ...);\n" \
    "#line 100 \"virtual.c\"\n" \
    "int a = __LINE__;\n" \
    "int b = __LINE__;\n" \
    "#line 5\n" \
    "int c = __LINE__;\n" \
    "int main(void) {\n" \
    "  printf(\"%d %d %d %s\\n\", a, b, c, __FILE__);\n" \
    "  return 0;\n" \
    "}\n"

  def test_line_directive_matches_gcc_stdout
    assert_equal program_output(PREPROCESSOR_LINE_PROGRAM, compiler: :gcc),
                 program_output(PREPROCESSOR_LINE_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on #line's effect on __LINE__/__FILE__"
  end

  # The manual offsetof idiom "(int)(size_t)&((T*)0)->member" in a static
  # initializer (Step 103, driven by date's gperf-generated zonetab.h): a
  # pointer→integer cast of a null-based member address folds to the member's
  # byte offset. Covered both as the elements of a static array (date's shape)
  # and as a scalar global; every offset must equal gcc's for this layout.
  MANUAL_OFFSETOF_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "struct S { int a; char b; long c; short d; }; " \
    "static const int offs[] = { " \
    "  (int)(unsigned long)&((struct S *)0)->a, " \
    "  (int)(unsigned long)&((struct S *)0)->b, " \
    "  (int)(unsigned long)&((struct S *)0)->c, " \
    "  (int)(unsigned long)&((struct S *)0)->d }; " \
    "static const long off_c = (long)(unsigned long)&((struct S *)0)->c; " \
    "int main(void) { " \
    "  printf(\"%d %d %d %d %ld\\n\", offs[0], offs[1], offs[2], offs[3], off_c); " \
    "  return 0; }"

  def test_manual_offsetof_idiom_matches_gcc_stdout
    assert_equal program_output(MANUAL_OFFSETOF_PROGRAM, compiler: :gcc),
                 program_output(MANUAL_OFFSETOF_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on the &((T*)0)->m offsetof idiom in a static initializer"
  end

  # _Static_assert over "sizeof <expression>" (Step 107, surfaced by ruby.h's
  # RBIMPL_STATIC_ASSERT(…, sizeof *ptr == sizeof(size_t)) when the compile-
  # throughput benchmark staged bigdecimal with gcc-derived defines): the
  # parse-time sizeof resolver that already folds array bounds serves the
  # assertion too — a declared object, a dereferenced parameter, and a string
  # literal all size at parse time, so these guarded programs compile and run.
  STATIC_ASSERT_SIZEOF_EXPR_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "static long counters[4]; " \
    "_Static_assert(sizeof counters == 4 * sizeof(long), \"whole array\"); " \
    "_Static_assert(sizeof \"abc\" == 4, \"string literal with NUL\"); " \
    "int width(void *volatile *slot) { " \
    "  _Static_assert(sizeof *slot == sizeof(unsigned long), \"pointer slot\"); " \
    "  return (int)sizeof *slot; } " \
    "int main(void) { " \
    "  void *volatile cell = 0; " \
    "  printf(\"%d %d\\n\", width(&cell), (int)sizeof counters); " \
    "  return 0; }"

  def test_static_assert_over_sizeof_expression_matches_gcc_stdout
    assert_equal program_output(STATIC_ASSERT_SIZEOF_EXPR_PROGRAM, compiler: :gcc),
                 program_output(STATIC_ASSERT_SIZEOF_EXPR_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on _Static_assert over sizeof <expression>"
  end

  # sizeof over a member access folds an array bound too (Step 114), the gap
  # left by Step 107 that sqlite3's amalgamation hits at
  # "char dbFileVers[sizeof(pPager->dbFileVers)]" -- a fixed-size buffer sized
  # from a struct member reached through a pointer parameter. Mirrored here
  # with both a "->" and a "." access of the same member.
  MEMBER_SIZEOF_ARRAY_BOUND_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "struct Pager { int flags; char dbFileVers[16]; }; " \
    "int probe(struct Pager *pPager) { " \
    "  char dbFileVers[sizeof(pPager->dbFileVers)]; " \
    "  dbFileVers[0] = 7; " \
    "  return (int)(sizeof dbFileVers + sizeof pPager->dbFileVers) + dbFileVers[0]; } " \
    "int main(void) { " \
    "  struct Pager pg; " \
    "  pg.flags = 0; " \
    "  printf(\"%d %d\\n\", probe(&pg), (int)sizeof pg.dbFileVers); " \
    "  return 0; }"

  def test_member_sizeof_array_bound_matches_gcc_stdout
    assert_equal program_output(MEMBER_SIZEOF_ARRAY_BOUND_PROGRAM, compiler: :gcc),
                 program_output(MEMBER_SIZEOF_ARRAY_BOUND_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on an array bound sized from sizeof(base.member)"
  end

  # #fold_time_sizeof (the parse-time "sizeof <expression>" resolver an array
  # bound and a _Static_assert already reach) is wired into every other
  # integer-constant-expression context too (Step 148): an enumerator value, a
  # bit-field width, a case label, and an array designator. The enumerator here
  # is nkf.c's own idiom for a compile-time string length,
  # "len = sizeof(str) - 1"; the other three are exercised in the same program
  # so one gcc-diffed run covers all four wiring gaps at once.
  SIZEOF_EXPR_CONSTANT_CONTEXTS_PROGRAM =
    "int printf(const char *fmt, ...); " \
    "const char str[] = \"abc\"; " \
    "enum { len = sizeof(str) - 1 }; " \
    "static int probe; " \
    "struct S { unsigned f : sizeof(probe); }; " \
    "int classify(int n) { " \
    "  int arr[3]; " \
    "  switch (n) { " \
    "    case sizeof(arr) / sizeof(arr[0]): return 100; " \
    "    default: return -1; " \
    "  } " \
    "} " \
    "int main(void) { " \
    "  char s[] = \"ab\"; " \
    "  int a[10] = {[sizeof(s) - 1] = 9}; " \
    "  struct S t; " \
    "  t.f = 5; " \
    "  printf(\"%d %d %d %d\\n\", len, classify(3), a[2], t.f); " \
    "  return 0; }"

  def test_sizeof_expression_constant_contexts_match_gcc_stdout
    assert_equal program_output(SIZEOF_EXPR_CONSTANT_CONTEXTS_PROGRAM, compiler: :gcc),
                 program_output(SIZEOF_EXPR_CONSTANT_CONTEXTS_PROGRAM, compiler: :rubycc),
                 "rubycc and gcc disagree on sizeof <expression> folded in an enumerator, " \
                 "bit-field width, case label, or array designator"
  end

  private

  def run_source(source, compiler:)
    in_tmpdir do |dir|
      object_path = File.join(dir, "test.o")
      compile_source(source, object_path, compiler)
      exit_status, = link_and_run(object_path)
      exit_status
    end
  end

  # Compiles and runs `source`, returning [exit_status, stdout] for comparison.
  def program_output(source, compiler:)
    in_tmpdir do |dir|
      object_path = File.join(dir, "test.o")
      compile_source(source, object_path, compiler)
      link_and_run(object_path)
    end
  end
end
