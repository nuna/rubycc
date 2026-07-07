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
