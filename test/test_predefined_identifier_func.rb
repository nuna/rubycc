# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# __func__ (C99 6.4.2.2) and its GNU synonyms __FUNCTION__/__PRETTY_FUNCTION__
# (GAPS BJ). gcc behaves as if
# "static const char __func__[] = "<function-name>";" were declared right
# after the enclosing function's opening brace: a const char array, usable in
# a nested block, decaying to a pointer, whose address is stable within one
# function. In C mode (unlike C++) __PRETTY_FUNCTION__ is a plain synonym for
# __func__ — no decorated signature. Measured 2026-09-14 with gcc 13.3; see
# docs/development/STEPS.md, predefined-identifier-func-1.
class TestPredefinedIdentifierFunc < Minitest::Test
  include ExecutionHelper

  def compile(source, filename: "foo.c")
    Rubycc::Compiler.new.compile(source, filename: filename, target: host_target)
  end

  # --- gcc-differential execution: value and sizeof --------------------------

  def test_func_name_and_size_on_gcc
    assert_c_program(func_name_and_size_source, exit_status: 0, stdout: "[main] 5\n", compiler: :gcc)
  end

  def test_func_name_and_size_on_rubycc
    assert_c_program(func_name_and_size_source, exit_status: 0, stdout: "[main] 5\n", compiler: :rubycc)
  end

  def func_name_and_size_source
    <<~C
      int printf(const char *, ...);
      int main(void) {
        printf("[%s] %lu\\n", __func__, (unsigned long)sizeof(__func__));
        return 0;
      }
    C
  end

  # --- gcc-differential execution: GNU synonyms -------------------------------

  def test_function_and_pretty_function_synonyms_on_gcc
    assert_c_program(synonyms_source, exit_status: 0, stdout: "[main][main]\n", compiler: :gcc)
  end

  def test_function_and_pretty_function_synonyms_on_rubycc
    assert_c_program(synonyms_source, exit_status: 0, stdout: "[main][main]\n", compiler: :rubycc)
  end

  def synonyms_source
    <<~C
      int printf(const char *, ...);
      int main(void) {
        printf("[%s][%s]\\n", __FUNCTION__, __PRETTY_FUNCTION__);
        return 0;
      }
    C
  end

  # --- gcc-differential execution: reflects the enclosing function's name ----

  def test_reflects_the_enclosing_functions_name_on_gcc
    assert_c_program(named_function_source, exit_status: 0, stdout: "[add]\n", compiler: :gcc)
  end

  def test_reflects_the_enclosing_functions_name_on_rubycc
    assert_c_program(named_function_source, exit_status: 0, stdout: "[add]\n", compiler: :rubycc)
  end

  def named_function_source
    <<~C
      int printf(const char *, ...);
      int add(int a, int b) {
        printf("[%s]\\n", __func__);
        return a + b;
      }
      int main(void) { return add(1, 2) == 3 ? 0 : 1; }
    C
  end

  # --- gcc-differential execution: usable inside a nested block --------------

  def test_usable_in_a_nested_block_on_gcc
    assert_c_program(nested_block_source, exit_status: 0, stdout: "[main]\n", compiler: :gcc)
  end

  def test_usable_in_a_nested_block_on_rubycc
    assert_c_program(nested_block_source, exit_status: 0, stdout: "[main]\n", compiler: :rubycc)
  end

  def nested_block_source
    <<~C
      int printf(const char *, ...);
      int main(void) {
        if (1) {
          printf("[%s]\\n", __func__);
        }
        return 0;
      }
    C
  end

  # --- gcc-differential execution: one object per function (stable address) --

  def test_two_references_share_one_object_on_gcc
    assert_c_exit_status(0, stable_address_source, compiler: :gcc)
  end

  def test_two_references_share_one_object_on_rubycc
    assert_c_exit_status(0, stable_address_source, compiler: :rubycc)
  end

  def stable_address_source
    <<~C
      int main(void) {
        const char *a = __func__;
        const char *b = __func__;
        return a == b ? 0 : 1;
      }
    C
  end

  # "&__func__" is an address-of on an lvalue of array type; taken twice, both
  # addresses agree (same underlying object).
  def test_address_of_is_stable_on_gcc
    assert_c_exit_status(0, address_of_source, compiler: :gcc)
  end

  def test_address_of_is_stable_on_rubycc
    assert_c_exit_status(0, address_of_source, compiler: :rubycc)
  end

  def address_of_source
    <<~C
      int main(void) {
        const char *a = (const char *)&__func__;
        const char *b = (const char *)&__func__;
        return a == b ? 0 : 1;
      }
    C
  end

  # --- gcc-differential execution: file scope ---------------------------------
  #
  # gcc 13.3 (measured 2026-09-14) accepts __func__ at file scope with a
  # warning, giving it an empty string (sizeof 1) rather than erroring. rubycc
  # matches the value and the diagnostic; __FUNCTION__/__PRETTY_FUNCTION__ get
  # the same empty-string treatment here without a warning (gcc gives
  # __PRETTY_FUNCTION__ "top level" instead of "" at file scope, and warns for
  # neither synonym — not reproduced; see the STEPS entry's 残された観点).

  def test_file_scope_value_on_gcc
    assert_c_program(file_scope_source, exit_status: 0, stdout: "[] 1\n", compiler: :gcc)
  end

  def test_file_scope_value_on_rubycc
    assert_c_program(file_scope_source, exit_status: 0, stdout: "[] 1\n", compiler: :rubycc)
  end

  def file_scope_source
    <<~C
      int printf(const char *, ...);
      const char *p = __func__;
      unsigned long sz = sizeof(__func__);
      int main(void) {
        printf("[%s] %lu\\n", p, sz);
        return 0;
      }
    C
  end

  def test_file_scope_use_warns_it_is_not_defined_outside_function_scope
    sink = StringIO.new
    Rubycc::Diagnostics.to(sink) { compile("const char *p = __func__;\nint main(void) { return 0; }") }
    assert_match(/'__func__' is not defined outside of function scope/, sink.string)
  end

  def test_file_scope_synonyms_do_not_warn
    sink = StringIO.new
    src = "const char *p = __FUNCTION__;\nconst char *q = __PRETTY_FUNCTION__;\nint main(void) { return 0; }"
    Rubycc::Diagnostics.to(sink) { compile(src) }
    assert_empty sink.string
  end

  # --- a real user declaration of the same name wins over the built-in -------
  #
  # gcc rejects any user declaration spelled __func__/__FUNCTION__/
  # __PRETTY_FUNCTION__ outright (reserved identifiers, "expected identifier
  # or '(' before '__func__'" — measured 2026-09-14 with gcc 13.3), so this
  # cannot be a gcc-differential case. rubycc is more permissive: since the
  # built-in is fabricated only when nothing already binds the name (see
  # Front::Parser#predefined_function_name_literal), a real file-scope
  # declaration of "__func__" is an ordinary global and a function that
  # references the name sees that global instead of its own name.
  def test_a_real_declaration_of_the_name_wins_over_the_builtin
    assert_c_exit_status(7, <<~C, compiler: :rubycc)
      int __func__ = 7;
      int f(void) { return __func__; }
      int main(void) { return f(); }
    C
  end
end
