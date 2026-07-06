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
    "int main(void) { int s = 0; for (int i = 1; i <= 9; ++i) s += i; return s - 3; }"
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
