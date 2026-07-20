# frozen_string_literal: true

require_relative "test_helper"

# Differential execution tests for the first half of the aarch64 ABI work
# (M4 A4): indirect calls, and floating-point arithmetic, comparison,
# conversion, argument passing and return.
#
# test_aarch64_backend.rb checks that each new instruction word matches the
# encoding the Arm Architecture Reference Manual (ARM DDI 0487) gives for it.
# That is necessary but not sufficient: FCMP's condition codes, the width a
# float slot is moved at, and the independence of the x0..x7 and v0..v7
# argument sequences are all choices a correct encoding says nothing about.
# These tests decide them by running the code — the same source built for
# aarch64 by rubycc and by the cross gcc, both linked statically and run under
# qemu-aarch64, with the two runs required to agree on exit status and stdout.
#
# Floating results are compared through printf rather than through the exit
# status, which carries only eight bits; %f/%g put the whole value on the
# stream, so a wrong low bit shows up as a differing digit.
class TestAArch64FloatExecution < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # --- floating arithmetic -------------------------------------------------

  def test_double_arithmetic
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        double a = 12.34;
        double b = 56.78;
        printf("%f\\n", a + b);
        printf("%f\\n", a - b);
        printf("%f\\n", a * b);
        printf("%f\\n", a / b);
        printf("%f\\n", -a);
        return 0;
      }
    C
  end

  # The single-precision forms of the same four instructions, whose results
  # differ from the double ones in the digits printf shows.
  def test_float_arithmetic_rounds_at_single_precision
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        float a = 12.34f;
        float b = 56.78f;
        printf("%.9g\\n", (double)(a + b));
        printf("%.9g\\n", (double)(a - b));
        printf("%.9g\\n", (double)(a * b));
        printf("%.9g\\n", (double)(a / b));
        printf("%.9g\\n", (double)(1.0f / 3.0f));
        return 0;
      }
    C
  end

  # Compound assignment and the increment forms reach the same instructions
  # through a different path in the generator.
  def test_floating_compound_assignment
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        double d = 10.0;
        d += 2.5;  printf("%f\\n", d);
        d -= 0.25; printf("%f\\n", d);
        d *= 4.0;  printf("%f\\n", d);
        d /= 3.0;  printf("%f\\n", d);
        float f = 1.5f;
        f += 0.25f; printf("%f\\n", (double)f);
        return 0;
      }
    C
  end

  # --- floating comparison -------------------------------------------------

  # Every ordering and equality operator over the three orderings a pair of
  # ordinary values can be in. FCMP's flags have to read the same way an
  # x86 ucomis does for each.
  #
  # Each row prints three results at a time rather than six: a printf of a
  # format plus six ints is seven integer arguments, which the System V
  # classification the IR still uses spills to the stack, and a stack-passed
  # argument is not something this backend places yet.
  def test_floating_comparisons_over_every_ordering
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      void row(double a, double b) {
        printf("%d %d %d ", a < b, a <= b, a == b);
        printf("%d %d %d\\n", a >= b, a > b, a != b);
      }
      int main(void) {
        row(1.0, 2.0);
        row(2.0, 2.0);
        row(2.0, 1.0);
        row(-1.0, 1.0);
        row(0.0, -0.0);
        return 0;
      }
    C
  end

  def test_float_comparisons_over_every_ordering
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      void row(float a, float b) {
        printf("%d %d %d ", a < b, a <= b, a == b);
        printf("%d %d %d\\n", a >= b, a > b, a != b);
      }
      int main(void) {
        row(1.0f, 2.0f);
        row(2.0f, 2.0f);
        row(2.0f, 1.0f);
        return 0;
      }
    C
  end

  # The NaN rule: <, <=, > and >= are all false against a NaN, "==" is false
  # and "!=" is true. This is what picks MI/LS/GT/GE out of the condition codes
  # rather than the LT/LE/GT/GE an integer compare uses, and it is invisible to
  # an encoding test. The NaN is built at run time (0.0 / 0.0) so no constant
  # folding can decide the answer at compile time.
  def test_nan_comparisons_are_all_false_except_not_equal
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      double zero(void) { return 0.0; }
      int main(void) {
        double nan = zero() / zero();
        double one = 1.0;
        printf("%d %d %d ", nan < one, nan <= one, nan == one);
        printf("%d %d %d\\n", nan >= one, nan > one, nan != one);
        printf("%d %d %d ", one < nan, one <= nan, one == nan);
        printf("%d %d %d\\n", one >= nan, one > nan, one != nan);
        printf("%d %d %d ", nan < nan, nan <= nan, nan == nan);
        printf("%d %d %d\\n", nan >= nan, nan > nan, nan != nan);
        return 0;
      }
    C
  end

  def test_nan_comparisons_at_single_precision
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      float zero(void) { return 0.0f; }
      int main(void) {
        float nan = zero() / zero();
        float one = 1.0f;
        printf("%d %d %d ", nan < one, nan <= one, nan == one);
        printf("%d %d %d\\n", nan >= one, nan > one, nan != one);
        return 0;
      }
    C
  end

  # A floating comparison used as a branch condition rather than as a value,
  # which reaches the same FCMP through the generator's control-flow path.
  def test_floating_comparison_drives_control_flow
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        double x = 0.5;
        int steps = 0;
        while (x < 100.0) { x = x * 1.5; steps = steps + 1; }
        printf("%d %f\\n", steps, x);
        if (x > 100.0) printf("above\\n"); else printf("below\\n");
        printf("%d\\n", x != 0.0 ? 1 : 0);
        return steps;
      }
    C
  end

  # --- conversions ---------------------------------------------------------

  # Signed integers of every width to both floating widths, and back. The
  # round trip through a float loses precision for a large long, which is part
  # of what is being compared.
  def test_signed_integer_and_floating_conversions
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        char c = -7;
        short s = -30000;
        int i = -1234567;
        long l = -1234567890123L;
        printf("%f %f %f %f\\n", (double)c, (double)s, (double)i, (double)l);
        printf("%.9g %.9g %.9g %.9g\\n", (double)(float)c, (double)(float)s,
               (double)(float)i, (double)(float)l);
        double d = -3.99;
        printf("%d %d %ld\\n", (int)d, (int)(-d), (long)(d * 1000000.0));
        printf("%d %d\\n", (int)(float)-2.75f, (int)3.99f);
        return 0;
      }
    C
  end

  # Unsigned sources and destinations, which pick UCVTF/FCVTZU out of the
  # conversion encoding. The `unsigned long` cases ride the branchwise sequence
  # the generator synthesizes from the signed primitives, so they exercise the
  # interaction between that lowering and this backend.
  def test_unsigned_integer_and_floating_conversions
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        unsigned char uc = 200;
        unsigned short us = 60000;
        unsigned int ui = 4000000000u;
        unsigned long ul = 18000000000000000000UL;
        printf("%f %f %f %f\\n", (double)uc, (double)us, (double)ui, (double)ul);
        printf("%.9g %.9g\\n", (double)(float)ui, (double)(float)ul);
        double d = 4000000000.0;
        printf("%u %lu\\n", (unsigned int)d, (unsigned long)d);
        printf("%lu\\n", (unsigned long)1.8e19);
        printf("%u\\n", (unsigned int)(float)3000000000.0f);
        return 0;
      }
    C
  end

  # float <-> double in both directions, including a value that is not
  # representable in single precision and so is rounded by the narrowing.
  def test_float_and_double_convert_both_ways
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        double d = 0.1;
        float f = (float)d;
        printf("%.17g\\n", (double)f);
        printf("%.17g\\n", d);
        float small = 1.0f / 3.0f;
        double widened = (double)small;
        printf("%.17g\\n", widened);
        printf("%.9g\\n", (double)(float)1e300);
        printf("%.9g\\n", (double)(float)1e-300);
        return 0;
      }
    C
  end

  # --- argument passing and return -----------------------------------------

  # Eight floating arguments exactly fill v0..v7, the boundary the AAPCS64
  # allocation rule turns on. A ninth would spill, which this backend refuses,
  # so eight is the case that must work.
  def test_eight_floating_arguments_fill_the_vector_registers
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      double sum8(double a, double b, double c, double d,
                  double e, double f, double g, double h) {
        printf("%f %f %f %f %f %f %f %f\\n", a, b, c, d, e, f, g, h);
        return a + b + c + d + e + f + g + h;
      }
      int main(void) {
        printf("%f\\n", sum8(1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0));
        return 0;
      }
    C
  end

  # Integers and floating values interleaved: each sequence advances its own
  # counter, so the fourth double is in v3 even though it is the eighth
  # argument. Getting this wrong would shift every later value by one register.
  def test_mixed_integer_and_floating_arguments_allocate_independently
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      void show(int a, double b, int c, double d, int e, double f) {
        printf("%d %f %d %f %d %f\\n", a, b, c, d, e, f);
      }
      double mix(double a, int b, float c, long d, double e) {
        printf("%f %d %.9g %ld %f\\n", a, b, (double)c, d, e);
        return a + b + c + d + e;
      }
      int main(void) {
        show(1, 2.5, 3, 4.5, 5, 6.5);
        printf("%f\\n", mix(1.5, 2, 3.5f, 4L, 5.5));
        return 0;
      }
    C
  end

  # A float parameter and a float return, which move at four bytes rather than
  # eight — the width choice the slot round-trip has to get right in both
  # directions.
  def test_float_parameters_and_return_use_the_single_width
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      float scale(float x, float k) { return x * k; }
      double widen(float x) { return (double)x + 0.5; }
      float narrow(double x) { return (float)(x / 3.0); }
      int main(void) {
        printf("%.9g\\n", (double)scale(1.5f, 3.25f));
        printf("%.17g\\n", widen(0.1f));
        printf("%.9g\\n", (double)narrow(1.0));
        return 0;
      }
    C
  end

  # A float argument to a variadic function is promoted to double by the usual
  # argument conversions, and on this platform a variadic call places it in the
  # same vector register a fixed call would — so printf("%f") needs nothing
  # special from the backend.
  def test_variadic_calls_pass_floating_values_in_the_vector_registers
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        float f = 2.5f;
        double d = 1.25;
        printf("%f %f\\n", (double)f, d);
        printf("%d %f %d %f\\n", 1, 2.5, 3, 4.5);
        printf("%f %f %f %f %f %f %f %f\\n",
               1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
        printf("%s %f %c\\n", "tag", 9.75, 'x');
        return 0;
      }
    C
  end

  # Floating values living in globals and arrays, read and written through
  # ordinary loads and stores rather than held in a parameter register.
  def test_floating_globals_and_arrays
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      double table[4] = { 1.5, 2.5, 3.5, 4.5 };
      float ftable[3];
      double total;
      int main(void) {
        int i;
        for (i = 0; i < 4; i = i + 1) total = total + table[i];
        printf("%f\\n", total);
        for (i = 0; i < 3; i = i + 1) ftable[i] = (float)i / 4.0f;
        printf("%.9g %.9g %.9g\\n", (double)ftable[0], (double)ftable[1], (double)ftable[2]);
        table[2] = table[0] * table[1];
        printf("%f\\n", table[2]);
        return 0;
      }
    C
  end

  # --- indirect calls ------------------------------------------------------

  def test_call_through_a_function_pointer
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int twice(int x) { return x * 2; }
      int square(int x) { return x * x; }
      int main(void) {
        int (*p)(int) = twice;
        printf("%d\\n", p(21));
        p = square;
        printf("%d\\n", p(7));
        printf("%d\\n", (*p)(8));
        printf("%d\\n", (&square == p));
        return 0;
      }
    C
  end

  # A dispatch table, the shape an indirect call is usually reached through:
  # the target is a value loaded out of memory, not a name the linker resolves.
  def test_dispatch_table
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int add(int a, int b) { return a + b; }
      int sub(int a, int b) { return a - b; }
      int mul(int a, int b) { return a * b; }
      int (*ops[3])(int, int) = { add, sub, mul };
      int main(void) {
        int i;
        for (i = 0; i < 3; i = i + 1) printf("%d\\n", ops[i](12, 4));
        return 0;
      }
    C
  end

  # A callback taking and returning floating values, so the indirect branch and
  # the vector argument registers have to work together.
  def test_indirect_call_with_floating_arguments_and_result
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      double apply(double (*f)(double, double), double a, double b) { return f(a, b); }
      double sum(double a, double b) { return a + b; }
      double prod(double a, double b) { return a * b; }
      float fscale(float x) { return x * 10.0f; }
      int main(void) {
        printf("%f\\n", apply(sum, 1.5, 2.25));
        printf("%f\\n", apply(prod, 1.5, 2.25));
        float (*fp)(float) = fscale;
        printf("%.9g\\n", (double)fp(0.25f));
        return 0;
      }
    C
  end

  # An indirect call with eight integer arguments: the target address is loaded
  # after the arguments are placed, into a register that is not one of them, so
  # a full argument list cannot displace it.
  def test_indirect_call_with_a_full_argument_list
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int sum6(int a, int b, int c, int d, int e, int f) {
        return a + b + c + d + e + f;
      }
      int main(void) {
        int (*p)(int, int, int, int, int, int) = sum6;
        printf("%d\\n", p(1, 2, 4, 8, 16, 32));
        return 0;
      }
    C
  end

  # An indirect call to a variadic function, which is how a program reaches
  # printf without naming it at the call site.
  def test_indirect_variadic_call
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int (*pf)(const char *, ...) = printf;
      int main(void) {
        pf("%d %s %f\\n", 42, "text", 2.5);
        printf("%d\\n", pf("x\\n"));
        return 0;
      }
    C
  end

  # A function pointer stored in a struct and one returned by another function:
  # both make the branch target an ordinary computed value.
  def test_function_pointer_through_a_struct_and_a_returned_pointer
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int base(void) { return 7; }
      struct ops { int (*get)(void); };
      int (*chooser(int which))(void) { return which ? base : 0; }
      int main(void) {
        struct ops o;
        o.get = base;
        printf("%d\\n", o.get());
        printf("%d\\n", chooser(1)());
        printf("%d\\n", chooser(0) == 0);
        return 0;
      }
    C
  end

  # Recursion through a function pointer, which puts the indirect branch on a
  # path that also has to preserve the return address across it.
  def test_recursion_through_a_function_pointer
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      long fact(long n);
      long (*fp)(long) = fact;
      long fact(long n) { return n <= 1 ? 1 : n * fp(n - 1); }
      int main(void) {
        printf("%ld\\n", fp(10));
        return 0;
      }
    C
  end

  # The whole layer under -fPIC, where the function pointer's initializer and
  # the callee's address come out of the GOT rather than being formed directly.
  def test_floating_and_indirect_calls_under_pic
    assert_aarch64_matches_gcc(<<~C, pic: true)
      #include <stdio.h>
      double half(double x) { return x / 2.0; }
      int main(void) {
        double (*p)(double) = half;
        printf("%f\\n", p(9.0));
        printf("%f\\n", half(3.0) + 0.5);
        return 0;
      }
    C
  end
end
