# frozen_string_literal: true

require_relative "test_helper"

class TestConditionalNullPointer < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

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

  # ISO C11 6.3.2.3p3: "An integer constant expression with the value 0 ...
  # is called a null pointer constant." 6.6p6 lets a cast to another integer
  # type appear inside such a constant expression, so a cast to a typedef'd
  # integer type (VALUE below, mirroring CRuby's "typedef unsigned long
  # VALUE", the shape mysql2's client.c hits comparing against Qfalse) stays a
  # null pointer constant -- not just a cast to "void *". gcc is the oracle
  # for every case here (measured directly against it); every accepted form is
  # exercised in every context the front end recognizes a null pointer
  # constant in: a static and a local initializer, a plain assignment, an
  # "=="/"!=" comparison in both operand orders, a function argument, a
  # return value and both arms of "?:".
  INTEGER_CAST_SOURCE = <<~C
    #include <stdio.h>
    typedef unsigned long VALUE;
    enum { Q_FALSE = 0 };

    void *global_init = (VALUE)0;
    void *g;

    void *e_ulong0(void) { return (VALUE)0; }
    void *e_char0(void) { return (char)0; }
    void *e_enum(void) { return (VALUE)Q_FALSE; }

    int take(void *p) { return p == 0; }

    int main(void) {
      int x;
      void *p = &x;
      void *a = (VALUE)0;
      void *b = (VALUE)(1 - 1);
      void *c = (char)0;
      void *d = (VALUE)Q_FALSE;
      g = (VALUE)0;

      printf("%d %d %d %d %d\\n", a == 0, b == 0, c == 0, d == 0, g == 0);
      printf("%d %d %d %d\\n",
             p == (VALUE)0, p != (VALUE)0, (VALUE)0 == p, (VALUE)0 != p);
      printf("%d %d\\n", p == (VALUE)(1 - 1), p == (char)0);
      printf("%d %d %d\\n", e_ulong0() == 0, e_char0() == 0, e_enum() == 0);
      printf("%d\\n", take((VALUE)0));
      printf("%d %d %d\\n", global_init == 0,
             (1 ? (VALUE)0 : p) == 0,
             (0 ? p : (VALUE)0) == 0);
      return 0;
    }
  C

  def test_integer_cast_forms_match_gcc
    assert_matches_gcc(INTEGER_CAST_SOURCE, "integer_cast_null_pointer")
  end

  def test_aarch64_integer_cast_forms_match_gcc
    assert_aarch64_matches_gcc(INTEGER_CAST_SOURCE)
  end

  # The value must be exactly 0: a cast to an integer type of a nonzero
  # constant is an ordinary integer, not a null pointer constant, so it must
  # stay rejected comparing against a pointer -- gcc only warns here
  # ("comparison between pointer and integer") and still accepts it, but this
  # front end has no warning channel and already turns every other
  # pointer/non-null-integer comparison ("p == 1") into a hard error, so
  # "(VALUE)1" gets the same treatment rather than silently comparing the
  # wrong bits.
  def test_nonzero_integer_cast_is_not_a_null_pointer_constant
    error = compile_error(
      "typedef unsigned long VALUE; " \
      "int main(void) { int x; void *p = &x; return p == (VALUE)1; }",
      "nonzero_cast.c"
    )
    assert_match(/invalid operands/, error.message)
  end

  # A cast to a *floating* type is never an integer constant expression
  # (6.6p6 restricts a constant-expression cast to converting to an integer
  # type, outside sizeof/alignof), so it must stay excluded even though its
  # value is 0 -- matching gcc, which errors "invalid operands" comparing
  # "(double)0" against a pointer.
  def test_float_cast_is_not_a_null_pointer_constant
    error = compile_error(
      "int main(void) { int x; void *p = &x; return p == (double)0; }",
      "float_cast.c"
    )
    assert_match(/invalid operands/, error.message)
  end

  private

  def assert_matches_gcc(source, name)
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      binary = Rubycc::Compiler.new.compile(source, filename: "#{name}.c")
      File.binwrite(rubycc_obj, binary)
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = compile_with_gcc(source, File.join(dir, "#{name}_gcc.o"))
      gcc_status, gcc_out = link_and_run(gcc_obj)

      assert_equal 0, rubycc_status, "rubycc-built #{name} exited #{rubycc_status}"
      assert_equal gcc_status, rubycc_status, "#{name}: exit status differs from gcc"
      assert_equal gcc_out, rubycc_out, "#{name}: output differs from gcc"
    end
  end

  def compile_error(source, filename)
    assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: filename)
    end
  end
end
