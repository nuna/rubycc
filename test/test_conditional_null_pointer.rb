# frozen_string_literal: true

require_relative "test_helper"

class TestConditionalNullPointer < Minitest::Test
  include ExecutionHelper

  def test_void_pointer_null_cast_is_a_null_pointer_constant
    assert_c_exit_status(
      42,
      "int main(void) { int x; int *p = 1 ? (void *)0 : &x; " \
      "return p == 0 ? 42 : 7; }",
      compiler: :rubycc
    )
  end

  def test_void_pointer_null_cast_composes_with_function_pointer
    assert_c_exit_status(
      42,
      "int f(void) { return 42; } " \
      "int main(void) { int (*fp)(void) = 0 ? (void *)0 : f; return fp(); }",
      compiler: :rubycc
    )
  end
end
