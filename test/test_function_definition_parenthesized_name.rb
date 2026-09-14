# frozen_string_literal: true

require_relative "test_helper"

# A function definition whose declarator parenthesizes the function name
# (GAPS BM). "(add)(int a, int b)" is a parenthesized declarator ("(add)")
# followed by a parameter list -- a function declarator per ISO C11 6.7.6p1
# and 6.7.6.3 -- and is exactly as valid a function definition's declarator
# as the unparenthesized "add(int a, int b)". 6.9.1p2 forbids only
# *inheriting* the function type from a typedef name; it says nothing about
# parenthesizing the declared name itself. Parenthesizing the name is the
# standard trick to dodge a same-named function-like macro. Measured
# 2026-09-14 with gcc 13.3; see docs/development/STEPS.md,
# function-definition-parenthesized-name-1.
#
# Real case this closes: iodine 0.7.59's mustache_parser.h:1018, "MUSTACHE_FUNC
# int(mustache_build)(mustache_build_args_s args) { ... }".
class TestFunctionDefinitionParenthesizedName < Minitest::Test
  include ExecutionHelper

  def compile(source, filename: "foo.c")
    Rubycc::Compiler.new.compile(source, filename: filename, target: host_target)
  end

  # --- gcc-differential execution: the repro ---------------------------------

  def test_parenthesized_name_on_gcc
    assert_c_exit_status(0, parenthesized_name_source, compiler: :gcc)
  end

  def test_parenthesized_name_on_rubycc
    assert_c_exit_status(0, parenthesized_name_source, compiler: :rubycc)
  end

  def parenthesized_name_source
    <<~C
      int (add)(int a, int b) { return a + b; }
      int main(void) { return add(1, 2) - 3; }
    C
  end

  # Parameters are in scope in the body exactly as for the unparenthesized
  # form.
  def test_parameters_are_in_scope_in_the_body_on_gcc
    assert_c_exit_status(0, parameters_in_scope_source, compiler: :gcc)
  end

  def test_parameters_are_in_scope_in_the_body_on_rubycc
    assert_c_exit_status(0, parameters_in_scope_source, compiler: :rubycc)
  end

  def parameters_in_scope_source
    <<~C
      int (add)(int a, int b) { return (a + b) - 3; }
      int main(void) { return add(1, 2); }
    C
  end

  # --- gcc-differential execution: storage class ------------------------------

  def test_static_parenthesized_name_on_gcc
    assert_c_exit_status(0, static_parenthesized_name_source, compiler: :gcc)
  end

  def test_static_parenthesized_name_on_rubycc
    assert_c_exit_status(0, static_parenthesized_name_source, compiler: :rubycc)
  end

  def static_parenthesized_name_source
    <<~C
      static int (f)(void) { return 5; }
      int main(void) { return f() - 5; }
    C
  end

  # --- gcc-differential execution: pointer return type ------------------------

  def test_pointer_returning_parenthesized_name_on_gcc
    assert_c_exit_status(0, pointer_returning_parenthesized_name_source, compiler: :gcc)
  end

  def test_pointer_returning_parenthesized_name_on_rubycc
    assert_c_exit_status(0, pointer_returning_parenthesized_name_source, compiler: :rubycc)
  end

  def pointer_returning_parenthesized_name_source
    <<~C
      int *(g)(void) {
        static int value = 7;
        return &value;
      }
      int main(void) { return *g() - 7; }
    C
  end

  # --- gcc-differential execution: doubly-parenthesized name ------------------

  def test_doubly_parenthesized_name_on_gcc
    assert_c_exit_status(0, doubly_parenthesized_name_source, compiler: :gcc)
  end

  def test_doubly_parenthesized_name_on_rubycc
    assert_c_exit_status(0, doubly_parenthesized_name_source, compiler: :rubycc)
  end

  def doubly_parenthesized_name_source
    <<~C
      int ((h))(int x) { return x + 1; }
      int main(void) { return h(4) - 5; }
    C
  end

  # --- gcc-differential execution: old-style (K&R) parameter list -------------

  def test_old_style_parenthesized_name_on_gcc
    assert_c_exit_status(0, old_style_parenthesized_name_source, compiler: :gcc)
  end

  def test_old_style_parenthesized_name_on_rubycc
    assert_c_exit_status(0, old_style_parenthesized_name_source, compiler: :rubycc)
  end

  def old_style_parenthesized_name_source
    <<~C
      int (add)(a, b)
        int a;
        int b;
      { return a + b; }
      int main(void) { return add(1, 2) - 3; }
    C
  end

  # --- the trick this is for: dodging a same-named function-like macro -------

  def test_dodges_a_same_named_function_like_macro_on_gcc
    assert_c_exit_status(0, macro_dodge_source, compiler: :gcc)
  end

  def test_dodges_a_same_named_function_like_macro_on_rubycc
    assert_c_exit_status(0, macro_dodge_source, compiler: :rubycc)
  end

  def macro_dodge_source
    <<~C
      #define add(x, y) ((x) + (y) + 100)
      int (add)(int a, int b) { return a + b; }
      int main(void) {
        /* The macro fires here: "add(" is an unparenthesized invocation. */
        int via_macro = add(1, 2);
        /* Parenthesizing the call's designator dodges the macro, reaching the
         * real function instead. */
        int via_function = (add)(1, 2);
        return via_macro == 103 && via_function == 3 ? 0 : 1;
      }
    C
  end

  # --- a definition through a typedef is still rejected -----------------------
  #
  # 6.9.1p2 forbids *inheriting* the function type from a typedef name; a
  # parenthesized name does not change that, since the type still supplies no
  # parameter list of its own.

  def test_definition_through_a_typedef_is_still_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("typedef int F(void); F f { return 0; }")
    end
    assert_match(/function definition through a typedef/, error.message)
  end
end
