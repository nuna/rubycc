# frozen_string_literal: true

require_relative "test_helper"

# Cross-translation-unit execution tests for passing and returning a 128-bit
# integer by value (Step 94). A __int128 travels as a 16-byte, two-INTEGER
# aggregate, and the two targets place it by rules that disagree in ways nothing
# about a single-compiler build reveals:
#
#   * AAPCS64 rounds a 16-byte-aligned argument up to an even integer register,
#     so a __int128 after one long lands in x2:x3, not x1:x2. System V has no
#     such rule — its __int128 takes two *consecutive* registers of any parity.
#   * Both conventions 16-align a __int128 that spills onto the stack, padding a
#     stack eightbyte when the running offset is odd.
#
# A placement bug is silent when one compiler builds both the caller and the
# callee: they agree with each other and compute the right value regardless of
# which registers or slots they chose. It surfaces only when a rubycc caller
# must meet a gcc callee (or the reverse). So every case here is differential
# *and* cross-TU: the caller and the callee are separate translation units built
# by different compilers, and every rubycc/gcc mix must match the all-gcc run.
#
# The values are split into their two 8-byte halves through a union, never by a
# 128-bit shift, so the tests exercise the by-value ABI alone and not 128-bit
# arithmetic (a separate, still-unimplemented feature).
class TestInt128Abi < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # The callee translation unit: functions that receive and return __int128 by
  # value, each probing one placement rule.
  DEFS = <<~C
    typedef union { __int128 v; unsigned long h[2]; } Split;

    unsigned long lo_of(__int128 x) { Split s; s.v = x; return s.h[0]; }
    unsigned long hi_of(__int128 x) { Split s; s.v = x; return s.h[1]; }

    static unsigned long sum(__int128 x) { Split s; s.v = x; return s.h[0] + s.h[1]; }

    /* A __int128 after one leading long: x0 taken, the 16-byte value rounds up
       to the even pair x2:x3 on AAPCS64 (x1 padded). */
    unsigned long probe_odd1(long a, __int128 b) { return a + sum(b); }

    /* After three leading longs (an odd count of integer registers): the value
       lands in x4:x5 on AAPCS64, x3 padded. */
    unsigned long probe_odd3(long a, long b, long c, __int128 d) {
      return a + b + c + sum(d);
    }

    /* Two int128s back to back: first x0:x1 (even, no pad), second x2:x3. */
    unsigned long probe_two(__int128 a, __int128 b) { return sum(a) + sum(b); }

    /* Eight longs fill the integer registers, so the trailing int128 spills to a
       stack slot that is already 16-aligned (no pad). */
    unsigned long probe_stack(long a, long b, long c, long d,
                              long e, long f, long g, long h, __int128 i) {
      return a + b + c + d + e + f + g + h + sum(i);
    }

    /* Nine longs: eight in registers, the ninth spills to stack eightbyte #0, so
       the int128 arrives on an ODD stack offset and must be padded up to a
       16-byte boundary on both targets. */
    unsigned long probe_stack_pad(long a, long b, long c, long d, long e,
                                  long f, long g, long h, long spill, __int128 j) {
      return a + b + c + d + e + f + g + h + spill + sum(j);
    }

    /* Returning a __int128 by value, assembled from two halves through memory. */
    __int128 make128(unsigned long hi, unsigned long lo) {
      Split s; s.h[0] = lo; s.h[1] = hi; return s.v;
    }

    unsigned __int128 umake(unsigned long lo, unsigned long hi) {
      Split s; s.h[0] = lo; s.h[1] = hi; return s.v;
    }
  C

  # The caller translation unit: builds values, calls across the unit boundary
  # and prints each result as plain longs, so the output is comparable without
  # 128-bit printf support.
  MAIN = <<~C
    int printf(const char *, ...);

    typedef union { __int128 v; unsigned long h[2]; } Split;

    unsigned long lo_of(__int128 x);
    unsigned long hi_of(__int128 x);
    unsigned long probe_odd1(long a, __int128 b);
    unsigned long probe_odd3(long a, long b, long c, __int128 d);
    unsigned long probe_two(__int128 a, __int128 b);
    unsigned long probe_stack(long a, long b, long c, long d,
                              long e, long f, long g, long h, __int128 i);
    unsigned long probe_stack_pad(long a, long b, long c, long d, long e,
                                  long f, long g, long h, long spill, __int128 j);
    __int128 make128(unsigned long hi, unsigned long lo);
    unsigned __int128 umake(unsigned long lo, unsigned long hi);

    int main(void) {
      Split s;
      s.h[0] = 0x99aabbccddeeff00UL;
      s.h[1] = 0x1122334455667788UL;
      __int128 v = s.v;

      printf("lo=%lu hi=%lu\\n", lo_of(v), hi_of(v));
      printf("odd1=%lu\\n", probe_odd1(7, v));
      printf("odd3=%lu\\n", probe_odd3(1, 2, 3, v));
      printf("two=%lu\\n", probe_two(v, v));
      printf("stk=%lu\\n", probe_stack(1, 2, 3, 4, 5, 6, 7, 8, v));
      printf("stkpad=%lu\\n", probe_stack_pad(1, 2, 3, 4, 5, 6, 7, 8, 9, v));

      __int128 m = make128(0x0102030405060708UL, 0x1112131415161718UL);
      printf("m.lo=%lu m.hi=%lu\\n", lo_of(m), hi_of(m));

      unsigned __int128 u = umake(0xaaaaaaaaaaaaaaaaUL, 0x5555555555555555UL);
      Split us; us.v = (__int128)u;
      printf("u.lo=%lu u.hi=%lu\\n", us.h[0], us.h[1]);

      return 0;
    }
  C

  # Every mix of who compiles which unit must match the all-gcc reference. The
  # all-rubycc run is included too: it cannot catch a placement bug (it is
  # self-consistent), but it guards against a rubycc build that fails to compile
  # or run the sources at all.
  MIXES = [
    [%i[rubycc gcc], "rubycc caller, gcc callee"],
    [%i[gcc rubycc], "gcc caller, rubycc callee"],
    [%i[rubycc rubycc], "rubycc caller and callee"]
  ].freeze

  def test_int128_by_value_abi_x86_64
    skip_unless_x86_execution
    oracle_status, oracle_stdout = link_units_and_run([[MAIN, :gcc], [DEFS, :gcc]])

    MIXES.each do |(main_cc, defs_cc), label|
      status, stdout = link_units_and_run([[MAIN, main_cc], [DEFS, defs_cc]])
      assert_equal oracle_status, status, "x86_64 exit status mismatch (#{label})"
      assert_equal oracle_stdout, stdout, "x86_64 stdout mismatch (#{label})"
    end
  end

  def test_int128_by_value_abi_aarch64
    skip_unless_aarch64_toolchain

    oracle_status, oracle_stdout = link_units_and_run_aarch64([[MAIN, :gcc], [DEFS, :gcc]])

    MIXES.each do |(main_cc, defs_cc), label|
      status, stdout = link_units_and_run_aarch64([[MAIN, main_cc], [DEFS, defs_cc]])
      assert_equal oracle_status, status, "aarch64 exit status mismatch (#{label})"
      assert_equal oracle_stdout, stdout, "aarch64 stdout mismatch (#{label})"
    end
  end
end
