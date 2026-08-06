# frozen_string_literal: true

require_relative "test_helper"

# The commuted subscript "i[e]". ISO C 6.5.2.1p2 defines "E1[E2]" as
# "(*((E1)+(E2)))", and that addition commutes, so the index may be written on
# either side: "0[x]" designates exactly the object "x[0]" does. Only the
# operands' types say which side is the pointer.
#
# google-protobuf's bundled upb reaches this through the ARRAY_SIZE macro it
# borrows from Chromium — "(sizeof(x) / sizeof(0[x])) / (!(sizeof(x) %
# sizeof(0[x])))", whose reversed subscript is what makes the macro reject a
# pointer argument — so the spelling has to work under sizeof as well as in an
# ordinary lvalue position.
#
# gcc is the oracle for every value here; the two diagnostics at the end are
# the operand combinations it refuses, checked to make sure the commuted form
# widens what is accepted without letting a bare "1[2]" through.
class TestCommutedSubscript < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # The commuted form in every lvalue context: read, write, compound
  # assignment, increment, address-of, and through a pointer as well as an
  # array. The struct row pins that a member access still reaches the right
  # element, and the multidimensional case that only the innermost subscript is
  # commuted.
  LVALUE_SOURCE = <<~C
    #include <stdio.h>
    int a[4] = { 10, 20, 30, 40 };
    struct cell { int x; int y; };
    struct cell cells[3] = { { 1, 2 }, { 3, 4 }, { 5, 6 } };
    int grid[2][3] = { { 1, 2, 3 }, { 4, 5, 6 } };
    int main(void) {
      int *p = a;
      int i = 2;
      printf("%d %d %d %d\\n", 0[a], 2[a], 1[p], i[a]);
      2[a] = 99;
      1[p] += 5;
      0[a]++;
      printf("%d %d %d\\n", a[0], a[1], a[2]);
      printf("%d %d\\n", 1[cells].x, 2[cells].y);
      printf("%d %d\\n", 2[grid[0]], 1[grid[1]]);
      printf("%d %d\\n", &2[a] == &a[2], (int)(&2[a] - a));
      return 0;
    }
  C

  # The type-only paths: sizeof and _Alignof of a commuted subscript, and the
  # upb ARRAY_SIZE macro itself, which divides by an expression that is zero
  # unless the array's size is a whole multiple of one element's.
  SIZEOF_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>

    /* upb's spelling, borrowed from Chromium. */
    #define ARRAY_SIZE(x) \\
      ((sizeof(x) / sizeof(0 [x])) / ((size_t)(!(sizeof(x) % sizeof(0 [x])))))

    struct cell { int x; double y; };
    static int counts[17];
    static struct cell cells[5];
    static char text[] = "hello";

    int main(void) {
      double m[3][4];
      printf("%zu %zu %zu\\n", ARRAY_SIZE(counts), ARRAY_SIZE(cells), ARRAY_SIZE(text));
      printf("%zu %zu\\n", sizeof(0[counts]), sizeof(1[cells]));
      printf("%zu %zu\\n", ARRAY_SIZE(m), sizeof(0[m]));
      printf("%zu %zu\\n", _Alignof(int), sizeof(&0[cells]));
      return 0;
    }
  C

  # A static initializer, where the address has to fold at compile time rather
  # than be computed: the commuted subscript names the same address constant
  # the ordinary spelling does, on either side of the brackets.
  ADDRESS_CONSTANT_SOURCE = <<~C
    #include <stdio.h>
    static int a[4] = { 10, 20, 30, 40 };
    static int *first = &0[a];
    static int *third = &2[a];
    static int *also_third = &a[2];
    int main(void) {
      printf("%d %d %d %d\\n", *first, *third, third == also_third, (int)(third - first));
      return 0;
    }
  C

  def test_lvalue_contexts_match_gcc
    assert_matches_gcc(LVALUE_SOURCE, "commuted_subscript_lvalue")
  end

  def test_sizeof_contexts_match_gcc
    assert_matches_gcc(SIZEOF_SOURCE, "commuted_subscript_sizeof")
  end

  def test_address_constants_match_gcc
    assert_matches_gcc(ADDRESS_CONSTANT_SOURCE, "commuted_subscript_address")
  end

  def test_aarch64_lvalue_contexts_match_gcc
    assert_aarch64_matches_gcc(LVALUE_SOURCE)
  end

  def test_aarch64_sizeof_contexts_match_gcc
    assert_aarch64_matches_gcc(SIZEOF_SOURCE)
  end

  # Neither operand a pointer: gcc says "subscripted value is neither array nor
  # pointer nor vector", and commuting must not turn that into an accepted
  # expression.
  def test_two_integer_operands_are_rejected
    error = compile_error("int main(void) { return 1[2]; }", "two_integers.c")
    assert_match(/subscripted value is neither array nor pointer/, error.message)
  end

  # Both operands pointers: gcc reports the *other* one as the index
  # ("array subscript is not an integer"), since the left is taken as the
  # pointer. Measured against gcc, which gives the same wording.
  def test_two_pointer_operands_are_rejected
    source = "int main(void) { int a[2]; int *p = a; return p[p]; }"
    error = compile_error(source, "two_pointers.c")
    assert_match(/array subscript is not an integer/, error.message)
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

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
