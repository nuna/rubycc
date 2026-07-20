# frozen_string_literal: true

require_relative "test_helper"

# Differential execution tests for AAPCS64 aggregate passing and returning.
#
# How a struct travels is the part of a calling convention the two targets
# disagree about most, and the disagreement is silent. System V AMD64 cuts every
# aggregate on eightbyte boundaries, so struct { float a, b; } is one SSE
# eightbyte carried whole in xmm0. AAPCS64 6.4.2 calls the same struct a
# Homogeneous Floating-point Aggregate and gives each member a vector register
# of its own, s0 and s1. Classify it by the wrong convention and the code still
# assembles, still links and still runs — it simply reads the second float out
# of a register the caller never wrote. Nothing about the shape of the failure
# says "unsupported"; it says 0.0.
#
# So every case here is differential: the same source is built for aarch64 twice,
# once by rubycc and once by the cross gcc, linked statically and run under
# qemu-aarch64, and the two runs must agree on exit status and stdout. The
# reference is a real implementation of the ABI rather than a hand-computed
# expectation, which is the only way to be sure of a rule this easy to
# misremember.
#
# Each member contributes to the printed result with a weight of its own, so a
# callee that reads the right number of registers but the wrong ones — the
# characteristic HFA failure — changes the output rather than merely the count.
class TestAArch64AggregateExecution < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # --- homogeneous floating aggregates -------------------------------------

  # The case the whole file exists for. Two, three and four floats are HFAs of
  # one to four members, each landing in its own single-precision register;
  # under System V's rules the first would have been a single eightbyte in one
  # register and the rest would have shifted down behind it.
  def test_float_hfa_arguments
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct F2 { float a, b; };
      struct F3 { float a, b, c; };
      struct F4 { float a, b, c, d; };
      float f2(struct F2 s){ return s.a + s.b * 10; }
      float f3(struct F3 s){ return s.a + s.b * 10 + s.c * 100; }
      float f4(struct F4 s){ return s.a + s.b * 10 + s.c * 100 + s.d * 1000; }
      int main(void){
        struct F2 x = {1, 2};
        struct F3 y = {1, 2, 3};
        struct F4 z = {1, 2, 3, 4};
        printf("%.1f %.1f %.1f\\n", f2(x), f3(y), f4(z));
        return 0;
      }
    C
  end

  # Doubles form HFAs the same way, and four of them are 32 bytes — well past
  # the 16-byte limit that sends any *other* aggregate by reference, which is
  # why the HFA test has to come first when an aggregate is classified.
  def test_double_hfa_arguments
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct D2 { double a, b; };
      struct D3 { double a, b, c; };
      struct D4 { double a, b, c, d; };
      double d2(struct D2 s){ return s.a + s.b * 10; }
      double d3(struct D3 s){ return s.a + s.b * 10 + s.c * 100; }
      double d4(struct D4 s){ return s.a + s.b * 10 + s.c * 100 + s.d * 1000; }
      int main(void){
        struct D2 x = {1, 2};
        struct D3 y = {1, 2, 3};
        struct D4 z = {1, 2, 3, 4};
        printf("%.1f %.1f %.1f\\n", d2(x), d3(y), d4(z));
        return 0;
      }
    C
  end

  # An HFA is recognized through nesting and through arrays, not just as a flat
  # run of members: a struct of two single-float structs plus a float is three
  # members, and so is a struct wrapping float[3].
  def test_nested_and_array_hfa_arguments
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct Inner { float x, y; };
      struct Nest { struct Inner in; float z; };
      struct Arr { float v[3]; };
      struct One { float a; };
      float nest(struct Nest s){ return s.in.x + s.in.y * 10 + s.z * 100; }
      float arr(struct Arr s){ return s.v[0] + s.v[1] * 10 + s.v[2] * 100; }
      float one(struct One s){ return s.a; }
      int main(void){
        struct Nest n = {{1, 2}, 3};
        struct Arr a = {{4, 5, 6}};
        struct One o = {7};
        printf("%.1f %.1f %.1f\\n", nest(n), arr(a), one(o));
        return 0;
      }
    C
  end

  # A member count of five, or a mixture of floating types, or a member that is
  # not floating at all, all disqualify an aggregate from HFA treatment — it
  # then follows the ordinary size rule instead. A struct padded out of shape by
  # an alignment attribute is disqualified too: it has two float members but
  # occupies 16 bytes, so it travels in the integer pair.
  def test_aggregates_that_are_not_hfas
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct F5 { float a, b, c, d, e; };
      struct FD { float a; double b; };
      struct Mix { int a; float b; };
      struct AL { float a, b; } __attribute__((aligned(16)));
      float f5(struct F5 s){ return s.a + s.b * 10 + s.c * 100 + s.d * 1000 + s.e * 10000; }
      double fd(struct FD s){ return s.a + s.b * 10; }
      float mix(struct Mix s){ return s.a + s.b * 10; }
      float al(struct AL s){ return s.a + s.b * 10; }
      int main(void){
        struct F5 v = {1, 2, 3, 4, 5};
        struct FD w = {1, 2};
        struct Mix x = {3, 4};
        struct AL y; y.a = 5; y.b = 6;
        printf("%.1f %.1f %.1f %.1f\\n", f5(v), fd(w), mix(x), al(y));
        return 0;
      }
    C
  end

  # --- integer-register and by-reference aggregates ------------------------

  # An aggregate of 16 bytes or less that is not an HFA takes one or two whole
  # integer registers, whatever its members are — a packed struct included,
  # since AAPCS64 has no counterpart to the psABI's "unaligned fields go to
  # memory" escape.
  def test_small_non_hfa_aggregate_arguments
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct S1 { char c; };
      struct I2 { int a, b; };
      struct L2 { long a, b; };
      struct T12 { int a, b, c; };
      struct PK { char c; int i; } __attribute__((packed));
      struct Bit { int a : 3; int b : 5; };
      long s1(struct S1 s){ return s.c; }
      long i2(struct I2 s){ return s.a + s.b * 10; }
      long l2(struct L2 s){ return s.a + s.b * 10; }
      long t12(struct T12 s){ return s.a + s.b * 10 + s.c * 100; }
      long pk(struct PK s){ return s.c + s.i * 10; }
      long bit(struct Bit s){ return s.a + s.b * 10; }
      int main(void){
        struct S1 a = {1};
        struct I2 b = {2, 3};
        struct L2 c = {4, 5};
        struct T12 d = {6, 7, 8};
        struct PK e; e.c = 9; e.i = 1;
        struct Bit f; f.a = 2; f.b = 3;
        printf("%ld %ld %ld %ld %ld %ld\\n", s1(a), i2(b), l2(c), t12(d), pk(e), bit(f));
        return 0;
      }
    C
  end

  # Past 16 bytes an aggregate travels by reference: the caller copies it and
  # passes the copy's address. The callee must not see the caller's own object,
  # so the callee writes through its parameter and the caller prints the
  # original afterwards — if the copy were skipped, the two would agree and the
  # test would notice.
  def test_large_aggregates_are_passed_by_reference
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct Big { long a, b, c, d, e; };
      long consume(struct Big s){
        s.a = 100;
        return s.a + s.b * 10 + s.c * 100 + s.d * 1000 + s.e * 10000;
      }
      int main(void){
        struct Big b = {1, 2, 3, 4, 5};
        long got = consume(b);
        printf("%ld %ld\\n", got, b.a);
        return 0;
      }
    C
  end

  # --- returning aggregates ------------------------------------------------

  # Every return shape at once: an HFA of floats comes back in s0..s3, one of
  # doubles in d0..d3, a small non-HFA in x0/x1, and anything larger through the
  # buffer whose address the caller puts in x8.
  def test_aggregate_return_values
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct F2 { float a, b; };
      struct F4 { float a, b, c, d; };
      struct D2 { double a, b; };
      struct I2 { int a, b; };
      struct T12 { int a, b, c; };
      struct Big { long a, b, c, d, e; };
      struct F2 mf2(float v){ struct F2 s; s.a = v; s.b = v + 1; return s; }
      struct F4 mf4(float v){ struct F4 s; s.a = v; s.b = v + 1; s.c = v + 2; s.d = v + 3; return s; }
      struct D2 md2(double v){ struct D2 s; s.a = v; s.b = v + 1; return s; }
      struct I2 mi2(int v){ struct I2 s; s.a = v; s.b = v + 1; return s; }
      struct T12 mt12(int v){ struct T12 s; s.a = v; s.b = v + 1; s.c = v + 2; return s; }
      struct Big mbig(long v){
        struct Big s; s.a = v; s.b = v + 1; s.c = v + 2; s.d = v + 3; s.e = v + 4; return s;
      }
      int main(void){
        struct F2 a = mf2(1);
        struct F4 b = mf4(2);
        struct D2 c = md2(3);
        struct I2 d = mi2(4);
        struct T12 e = mt12(5);
        struct Big f = mbig(6);
        printf("%.1f %.1f %.1f %.1f\\n", a.a, a.b, b.a, b.d);
        printf("%.1f %.1f %d %d\\n", c.a, c.b, d.a, d.b);
        printf("%d %d %d %ld %ld %ld\\n", e.a, e.b, e.c, f.a, f.c, f.e);
        return 0;
      }
    C
  end

  # A struct-returning call feeding a struct-taking one, f(g(s)), with no named
  # variable in between: the result buffer of the inner call has to be the
  # argument copy of the outer, in every return shape at once.
  def test_chained_struct_returning_calls
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct F2 { float a, b; };
      struct L2 { long a, b; };
      struct Big { long a, b, c, d, e; };
      struct F2 gf(float v){ struct F2 s; s.a = v; s.b = v + 1; return s; }
      struct L2 gl(long v){ struct L2 s; s.a = v; s.b = v + 1; return s; }
      struct Big gb(long v){
        struct Big s; s.a = v; s.b = v + 1; s.c = v + 2; s.d = v + 3; s.e = v + 4; return s;
      }
      float ff(struct F2 s){ return s.a + s.b * 10; }
      long fl(struct L2 s){ return s.a + s.b * 10; }
      long fb(struct Big s){ return s.a + s.b * 10 + s.c * 100 + s.d * 1000 + s.e * 10000; }
      int main(void){
        printf("%.1f %ld %ld\\n", ff(gf(1)), fl(gl(2)), fb(gb(3)));
        return 0;
      }
    C
  end

  # --- placement boundaries ------------------------------------------------

  # An aggregate mixed in among scalars must not disturb their placement, and
  # the two register files advance independently: the ints keep counting through
  # x0.. while the HFA takes v registers of its own.
  def test_aggregates_mixed_with_scalar_arguments
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct F2 { float a, b; };
      struct L2 { long a, b; };
      double mixed(int p, struct F2 f, long q, struct L2 l, double r){
        return p + f.a * 10 + f.b * 100 + q * 1000 + l.a * 10000 + l.b * 100000 + r * 1000000;
      }
      int main(void){
        struct F2 f = {1, 2};
        struct L2 l = {3, 4};
        printf("%.1f\\n", mixed(5, f, 6, l, 7));
        return 0;
      }
    C
  end

  # What happens when an aggregate does not fit is where the two conventions
  # differ most sharply. AAPCS64 6.4.2 stage C declares the file it overflowed
  # exhausted, so an int following a spilled two-register struct goes to the
  # stack as well — where System V would have handed it the register the struct
  # could not use. The other file is untouched, though: a spilled HFA leaves the
  # integer registers alone, so the ints after it still start at x0.
  def test_aggregates_that_run_out_of_registers
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct F2 { float a, b; };
      struct L2 { long a, b; };
      long gp_spill(int a,int b,int c,int d,int e,int f,int g,struct L2 h,int i){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h.a*8+h.b*9+i*10;
      }
      double fp_spill(float a,float b,float c,float d,float e,float f,float g,
                      struct F2 h,int i,int j){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h.a*8+h.b*9+i*10+j*11;
      }
      int main(void){
        struct L2 l = {1, 2};
        struct F2 s = {3, 4};
        printf("%ld %.1f\\n", gp_spill(1,2,3,4,5,6,7,l,8), fp_spill(1,2,3,4,5,6,7,s,8,9));
        return 0;
      }
    C
  end

  # --- whole-object copies -------------------------------------------------

  # Assignment of a struct is a copy, not an alias, at every size the copy
  # lowering treats differently: unrolled for a few eightbytes, looped past the
  # unroll limit, and with a tail for a size that is not a multiple of eight.
  def test_struct_assignment_copies
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct Small { int a, b; };
      struct Odd { char v[13]; };
      struct Wide { long v[20]; };
      int main(void){
        struct Small a = {1, 2}, b;
        b = a; a.a = 9;
        struct Odd c, d;
        for (int i = 0; i < 13; i++) c.v[i] = (char)(i + 1);
        d = c; c.v[0] = 99;
        struct Wide e, f;
        for (int i = 0; i < 20; i++) e.v[i] = i * 3;
        f = e; e.v[0] = 77;
        printf("%d %d %d %d\\n", b.a, b.b, a.a, (int)d.v[0]);
        printf("%d %d %ld %ld\\n", (int)d.v[12], (int)c.v[0], f.v[0], f.v[19]);
        return 0;
      }
    C
  end
end
