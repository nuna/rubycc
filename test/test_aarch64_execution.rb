# frozen_string_literal: true

require_relative "test_helper"

# Differential execution tests for the AArch64 backend.
#
# test_aarch64_backend.rb checks the instruction words the generator emits
# against the encodings in the Arm Architecture Reference Manual (ARM DDI 0487).
# That catches a wrong bit field but not a wrong idea: an instruction can be
# encoded perfectly and still compute the wrong thing. These tests close that
# gap by running the code. Every case compiles the same C source twice — once
# with rubycc for the aarch64 target, once with the cross gcc — links both
# statically and runs both under qemu-aarch64, then asserts the two agree on
# exit status and standard output. The expectation is therefore a reference
# implementation of C, not a hand-computed number.
#
# Two constraints of the A2 core shape the sources below. There are no string
# literals, so output goes through putchar(int), declared by hand rather than
# pulled from a header. And only the low 8 bits of main's return value survive
# into the exit status, so anything wider is reported one character at a time.
#
# Scope follows what the A2 core lowers: control flow, integer arithmetic,
# locals, pointers to locals and direct calls. Globals, string literals,
# floating point, structs by value, varargs and indirect calls belong to A3/A4
# and are covered by the "raises UnsupportedError" tests in the encoding suite.
class TestAArch64Execution < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # Declarations the sources share. putchar is the only I/O the A2 core can
  # reach (a direct call taking an int), which makes it the whole of the stdout
  # oracle; abs is a second libc call with no string operand.
  PRELUDE = <<~C
    int putchar(int c);
    int abs(int n);
  C

  # Emits a signed value as a decimal line, so a result wider than the 8 bits an
  # exit status carries can still be compared character by character.
  PRINT_HELPERS = <<~C
    void put_long(long v) {
      int digits[24];
      int n = 0;
      unsigned long u;
      if (v < 0) { putchar(45); u = (unsigned long)(-v); } else { u = (unsigned long)v; }
      if (u == 0) { putchar(48); putchar(10); return; }
      while (u > 0) { digits[n] = (int)(u % 10); u = u / 10; n = n + 1; }
      while (n > 0) { n = n - 1; putchar(48 + digits[n]); }
      putchar(10);
    }
  C

  def source(body)
    PRELUDE + PRINT_HELPERS + body
  end

  # --- arithmetic --------------------------------------------------------

  def test_signed_arithmetic
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int a = 1234;
        int b = 37;
        put_long(a + b);
        put_long(a - b);
        put_long(a * b);
        put_long(a / b);
        put_long(a % b);
        put_long(-a);
        return (a + b) & 255;
      }
    C
  end

  def test_signed_division_truncates_toward_zero
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int i;
        int values[8];
        values[0] = 7; values[1] = -7; values[2] = 100; values[3] = -100;
        values[4] = 1; values[5] = -1; values[6] = 2147483647; values[7] = -2147483648;
        i = 0;
        while (i < 8) {
          int d;
          d = 3;
          put_long(values[i] / d);
          put_long(values[i] % d);
          d = -3;
          put_long(values[i] / d);
          put_long(values[i] % d);
          i = i + 1;
        }
        return 0;
      }
    C
  end

  def test_unsigned_arithmetic
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        unsigned int a = 4000000000u;
        unsigned int b = 7u;
        put_long((long)(unsigned long)(a + b));
        put_long((long)(unsigned long)(a - b));
        put_long((long)(unsigned long)(a * b));
        put_long((long)(unsigned long)(a / b));
        put_long((long)(unsigned long)(a % b));
        return (int)(a % 251u);
      }
    C
  end

  def test_int_overflow_wraps_around
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        unsigned int a = 2147483647u;
        unsigned int b = 3000000000u;
        put_long((long)(unsigned long)(a + a));
        put_long((long)(unsigned long)(b + b));
        put_long((long)(unsigned long)(b * b));
        return (int)((a + a) & 255u);
      }
    C
  end

  def test_long_arithmetic_is_64_bit
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        long a = 4000000000;
        long b = 123456789;
        put_long(a + b);
        put_long(a - b);
        put_long(a * b);
        put_long(a / b);
        put_long(a % b);
        put_long(-a * 3);
        put_long((long)(a * a) / 7);
        return (int)(a % 200);
      }
    C
  end

  # --- bit operations and shifts ----------------------------------------

  def test_bitwise_operators
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int a = 0x0F3C5A69;
        int b = 0x12345678;
        put_long(a & b);
        put_long(a | b);
        put_long(a ^ b);
        put_long(~a);
        put_long((long)((unsigned long)(unsigned int)(a & -1)));
        return (a ^ b) & 255;
      }
    C
  end

  def test_shifts_signed_and_unsigned
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int s = -1000000;
        unsigned int u = 4000000000u;
        int i = 0;
        while (i < 31) {
          put_long(s >> i);
          put_long((long)(unsigned long)(u >> i));
          put_long((long)(unsigned long)(unsigned int)(s << i));
          i = i + 1;
        }
        return 0;
      }
    C
  end

  def test_shifts_at_width_boundary
    # Shift counts up to 63 on a 64-bit operand: the hardware masks to 6 bits,
    # which is the range C actually defines here.
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        long s = -1234567890123;
        unsigned long u = 18000000000000000000ul;
        int i = 28;
        while (i < 40) {
          put_long(s >> (i % 64));
          put_long((long)(u >> (i % 64)));
          put_long(s << (i % 64));
          i = i + 1;
        }
        put_long(s >> 63);
        put_long((long)(u >> 63));
        put_long(1L << 62);
        return 0;
      }
    C
  end

  # --- comparisons and logical operators ---------------------------------

  def test_signed_comparisons
    assert_aarch64_matches_gcc(source(<<~C))
      int cmp(int a, int b) {
        return (a == b) + 2 * (a != b) + 4 * (a < b) + 8 * (a <= b)
             + 16 * (a > b) + 32 * (a >= b);
      }
      int main(void) {
        int xs[6];
        int i;
        xs[0] = 0; xs[1] = 1; xs[2] = -1; xs[3] = 2147483647;
        xs[4] = -2147483648; xs[5] = 42;
        i = 0;
        while (i < 6) {
          int j = 0;
          while (j < 6) {
            put_long(cmp(xs[i], xs[j]));
            j = j + 1;
          }
          i = i + 1;
        }
        return 0;
      }
    C
  end

  def test_unsigned_and_pointer_comparisons
    assert_aarch64_matches_gcc(source(<<~C))
      int ucmp(unsigned int a, unsigned int b) {
        return (a < b) + 2 * (a <= b) + 4 * (a > b) + 8 * (a >= b);
      }
      int main(void) {
        unsigned int xs[4];
        int i;
        int buf[4];
        int *p;
        int *q;
        xs[0] = 0u; xs[1] = 1u; xs[2] = 2147483648u; xs[3] = 4294967295u;
        i = 0;
        while (i < 4) {
          int j = 0;
          while (j < 4) { put_long(ucmp(xs[i], xs[j])); j = j + 1; }
          i = i + 1;
        }
        p = &buf[0];
        q = &buf[3];
        put_long(p < q);
        put_long(p > q);
        put_long(p == q);
        put_long(p != q);
        put_long(q - p);
        return 0;
      }
    C
  end

  def test_logical_operators_short_circuit
    assert_aarch64_matches_gcc(source(<<~C))
      int calls;
      int main(void) {
        int n = 0;
        int a;
        int b;
        a = 0;
        b = 5;
        if (a && (b = 9)) { n = n + 1; }
        put_long(b);
        if (a || (b = 3)) { n = n + 2; }
        put_long(b);
        a = 1;
        if (a || (b = 77)) { n = n + 4; }
        put_long(b);
        put_long(!a);
        put_long(!0);
        put_long(n);
        return n;
      }
    C
  end

  # --- control flow -------------------------------------------------------

  def test_nested_if_else
    assert_aarch64_matches_gcc(source(<<~C))
      int classify(int n) {
        if (n < 0) {
          if (n < -100) { return 1; } else { return 2; }
        } else if (n == 0) {
          return 3;
        } else {
          if (n > 100) { return 4; } else if (n > 10) { return 5; }
          return 6;
        }
      }
      int main(void) {
        int i = -200;
        while (i <= 200) { put_long(classify(i)); i = i + 37; }
        return classify(50);
      }
    C
  end

  def test_loops_and_break_continue
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int total = 0;
        int i;
        for (i = 0; i < 20; i = i + 1) {
          if (i % 3 == 0) { continue; }
          if (i == 17) { break; }
          total = total + i;
        }
        put_long(total);
        i = 0;
        while (1) {
          i = i + 1;
          if (i > 9) { break; }
          total = total + i * i;
        }
        put_long(total);
        i = 0;
        do {
          total = total - 1;
          i = i + 1;
        } while (i < 5);
        put_long(total);
        return total & 255;
      }
    C
  end

  def test_goto_and_nested_loops
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int i;
        int j;
        int found = 0;
        for (i = 0; i < 30; i = i + 1) {
          for (j = 0; j < 30; j = j + 1) {
            if (i * j == 221) { found = i * 100 + j; goto done; }
          }
        }
      done:
        put_long(found);
        i = 0;
      again:
        i = i + 3;
        if (i < 40) { goto again; }
        put_long(i);
        return found & 255;
      }
    C
  end

  def test_switch_statement
    assert_aarch64_matches_gcc(source(<<~C))
      int pick(int n) {
        int r = 0;
        switch (n) {
        case 0:
          r = 10;
          break;
        case 1:
        case 2:
          r = 20;
          break;
        case 7:
          r = 30;
          /* fall through */
        case 8:
          r = r + 5;
          break;
        default:
          r = -1;
        }
        return r;
      }
      int main(void) {
        int i;
        for (i = -1; i < 10; i = i + 1) { put_long(pick(i)); }
        return pick(7);
      }
    C
  end

  def test_conditional_expression
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int i;
        for (i = -4; i < 5; i = i + 1) {
          put_long(i < 0 ? -i : i * 2);
        }
        return 0;
      }
    C
  end

  # --- functions ----------------------------------------------------------

  def test_recursion
    assert_aarch64_matches_gcc(source(<<~C))
      int fib(int n) {
        if (n < 2) { return n; }
        return fib(n - 1) + fib(n - 2);
      }
      long fact(int n) {
        if (n <= 1) { return 1; }
        return (long)n * fact(n - 1);
      }
      int main(void) {
        int i;
        for (i = 0; i < 22; i = i + 1) { put_long(fib(i)); }
        for (i = 1; i <= 20; i = i + 1) { put_long(fact(i)); }
        return fib(15) & 255;
      }
    C
  end

  def test_mutual_recursion
    assert_aarch64_matches_gcc(source(<<~C))
      int is_odd(int n);
      int is_even(int n) {
        if (n == 0) { return 1; }
        return is_odd(n - 1);
      }
      int is_odd(int n) {
        if (n == 0) { return 0; }
        return is_even(n - 1);
      }
      int main(void) {
        int i;
        for (i = 0; i < 17; i = i + 1) { put_long(is_even(i) * 2 + is_odd(i)); }
        return is_even(30);
      }
    C
  end

  def test_six_arguments
    # Six integer arguments is the practical limit: the IR classifies a seventh
    # as :mem, which the A2 core refuses rather than guesses at.
    assert_aarch64_matches_gcc(source(<<~C))
      long mix(int a, long b, int c, long d, int e, long f) {
        return a * 1 + b * 10 + c * 100 + d * 1000 + e * 10000 + f * 100000;
      }
      int main(void) {
        put_long(mix(1, 2, 3, 4, 5, 6));
        put_long(mix(-1, -2, -3, -4, -5, -6));
        put_long(mix(0, 1000000000, 0, 2000000000, 0, 3000000000));
        return (int)(mix(1, 2, 3, 4, 5, 6) & 255);
      }
    C
  end

  def test_void_function_and_multiple_returns
    assert_aarch64_matches_gcc(source(<<~C))
      void emit(int n) {
        if (n <= 0) { return; }
        putchar(65 + n);
        return;
      }
      int sign(int n) {
        if (n < 0) { return -1; }
        if (n > 0) { return 1; }
        return 0;
      }
      int main(void) {
        int i;
        for (i = -3; i < 8; i = i + 1) { emit(i); put_long(sign(i)); }
        putchar(10);
        return 0;
      }
    C
  end

  # --- type conversions ---------------------------------------------------

  # Note on `char`: these sources always write `signed char` or `unsigned char`
  # explicitly, never plain `char`, so the byte width being converted is the only
  # variable and these tests stay squarely about code generation. Plain `char` is
  # no longer off limits — its signedness follows the target now (unsigned under
  # AAPCS64, as here), and test_plain_char_signedness.rb is where that is checked
  # against the cross gcc — but keeping the spelling explicit here means a change
  # to the target's choice cannot silently reinterpret these conversions.
  def test_integer_conversions
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        long v = 0x123456789ABCDEF0L;
        signed char c = (signed char)v;
        short s = (short)v;
        int i = (int)v;
        unsigned char uc = (unsigned char)v;
        unsigned short us = (unsigned short)v;
        unsigned int ui = (unsigned int)v;
        put_long(c);
        put_long(s);
        put_long(i);
        put_long(uc);
        put_long(us);
        put_long((long)ui);
        put_long((long)(signed char)-1);
        put_long((long)(unsigned char)-1);
        put_long((long)(short)-1);
        put_long((long)(unsigned short)-1);
        put_long((long)(int)-1);
        put_long((long)(unsigned int)-1);
        return (int)(v & 255);
      }
    C
  end

  def test_signed_unsigned_mixing
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int si = -1;
        unsigned int ui = 1u;
        long sl = -1;
        unsigned long ul = 1ul;
        put_long(si < (int)ui);
        put_long((unsigned int)si < ui);
        put_long(sl < (long)ul);
        put_long((unsigned long)sl < ul);
        put_long((long)(unsigned long)(unsigned int)si);
        put_long((long)(int)(unsigned int)4294967295u);
        put_long((long)(si + (int)ui));
        put_long((long)(unsigned long)((unsigned int)si / 3u));
        put_long((long)((unsigned long)sl >> 4));
        return 0;
      }
    C
  end

  def test_narrow_types_wrap_and_promote
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        signed char c = 120;
        short s = 32000;
        unsigned char uc = 250;
        unsigned short us = 65000;
        int i;
        for (i = 0; i < 10; i = i + 1) {
          c = (signed char)(c + 3);
          s = (short)(s + 300);
          uc = (unsigned char)(uc + 3);
          us = (unsigned short)(us + 300);
          put_long(c);
          put_long(s);
          put_long(uc);
          put_long(us);
          put_long(c * s);
          put_long(uc * us);
        }
        return 0;
      }
    C
  end

  # --- arrays and pointers ------------------------------------------------

  def test_local_array_and_subscript
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int a[10];
        int i;
        int sum = 0;
        for (i = 0; i < 10; i = i + 1) { a[i] = i * i - 3 * i; }
        for (i = 0; i < 10; i = i + 1) { sum = sum + a[i]; put_long(a[i]); }
        put_long(sum);
        return sum & 255;
      }
    C
  end

  def test_pointer_arithmetic_and_indirection
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        long a[8];
        long *p = a;
        long *q;
        int i;
        for (i = 0; i < 8; i = i + 1) { *(p + i) = (long)i * 1000000007L; }
        q = p + 7;
        put_long(q - p);
        put_long(*q);
        put_long(*(q - 3));
        while (q >= p) { put_long(*q); q = q - 1; }
        p = p + 2;
        p = p - 1;
        put_long(*p);
        put_long(p[1]);
        put_long(*&p[2]);
        return 0;
      }
    C
  end

  def test_address_of_local_and_write_through_pointer
    assert_aarch64_matches_gcc(source(<<~C))
      void add_to(int *p, int n) { *p = *p + n; }
      void swap(long *a, long *b) { long t = *a; *a = *b; *b = t; }
      int main(void) {
        int x = 10;
        long u = 111111111111L;
        long v = -222222222222L;
        int *px = &x;
        add_to(px, 5);
        add_to(&x, 7);
        put_long(x);
        *px = *px * 3;
        put_long(x);
        swap(&u, &v);
        put_long(u);
        put_long(v);
        return x & 255;
      }
    C
  end

  def test_load_store_widths
    # Exercises each access size through a pointer: ldrsb/ldrb, ldrsh/ldrh,
    # the 32-bit and 64-bit ldr, and the matching strb/strh/str forms.
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        signed char cb[4];
        unsigned char ub[4];
        short sh[4];
        unsigned short uh[4];
        int iw[4];
        long lw[4];
        signed char *cp = cb;
        unsigned char *up = ub;
        short *sp = sh;
        unsigned short *hp = uh;
        int *ip = iw;
        long *lp = lw;
        int i;
        for (i = 0; i < 4; i = i + 1) {
          cp[i] = (signed char)(-120 + i * 80);
          up[i] = (unsigned char)(-120 + i * 80);
          sp[i] = (short)(-30000 + i * 20000);
          hp[i] = (unsigned short)(-30000 + i * 20000);
          ip[i] = -2000000000 + i * 1000000000;
          lp[i] = -4000000000000L + (long)i * 3000000000000L;
        }
        for (i = 0; i < 4; i = i + 1) {
          put_long(cp[i]);
          put_long(up[i]);
          put_long(sp[i]);
          put_long(hp[i]);
          put_long(ip[i]);
          put_long(lp[i]);
          put_long((long)cp[i] * 1000);
          put_long((long)sp[i] * 1000);
          put_long((long)ip[i] * 1000);
        }
        return 0;
      }
    C
  end

  def test_pointer_as_index_into_char_buffer
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        char buf[32];
        int i;
        for (i = 0; i < 26; i = i + 1) { buf[i] = (char)(97 + i); }
        buf[26] = 10;
        for (i = 0; i < 27; i = i + 1) { putchar(buf[i]); }
        for (i = 26; i > 0; i = i - 1) { putchar(buf[i - 1]); }
        putchar(10);
        return 0;
      }
    C
  end

  # --- large frames -------------------------------------------------------

  def test_large_frame_object_beyond_scaled_offset
    # A local array big enough that the objects laid out above it sit past the
    # 4095*8 byte reach of the scaled ldr/str immediate, forcing the composed
    # address path that only unit tests had covered.
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int big[9000];
        long tail[4];
        int probe;
        int i;
        long sum = 0;
        probe = 4242;
        for (i = 0; i < 4; i = i + 1) { tail[i] = (long)i * 987654321L; }
        for (i = 0; i < 9000; i = i + 1) { big[i] = i - 4500; }
        for (i = 0; i < 9000; i = i + 1) { sum = sum + (long)big[i]; }
        for (i = 0; i < 4; i = i + 1) { sum = sum + tail[i]; }
        put_long(sum);
        put_long(probe);
        put_long(big[0]);
        put_long(big[8999]);
        put_long(*(&probe));
        return probe & 255;
      }
    C
  end

  def test_large_frame_with_calls
    assert_aarch64_matches_gcc(source(<<~C))
      long fill(long *a, int n) {
        int i;
        long s = 0;
        for (i = 0; i < n; i = i + 1) { a[i] = (long)i * 7 - 3; s = s + a[i]; }
        return s;
      }
      int main(void) {
        long a[5000];
        long b[5000];
        long marker = 123456789L;
        put_long(fill(a, 5000));
        put_long(fill(b, 5000));
        put_long(a[4999] + b[0]);
        put_long(marker);
        return (int)(marker & 255);
      }
    C
  end

  def test_many_temporaries_push_slots_past_scaled_offset
    # Drives the vreg slot count past 4095 so the *slot* access path (not just
    # the stack objects) has to compose its address.
    body = +"int main(void) {\n  long v = 1;\n"
    1400.times { |i| body << "  v = v * 3 + #{i} - (v / 5);\n" }
    body << "  put_long(v);\n  return (int)(v & 255);\n}\n"
    assert_aarch64_matches_gcc(source(body))
  end

  # --- libc calls ---------------------------------------------------------

  def test_direct_libc_calls
    assert_aarch64_matches_gcc(source(<<~C))
      int main(void) {
        int i;
        for (i = -5; i < 6; i = i + 1) { put_long(abs(i)); }
        for (i = 0; i < 10; i = i + 1) { putchar(48 + i); }
        putchar(10);
        return abs(-42);
      }
    C
  end

  # 128-bit shift (Step 95) on aarch64: the double-word lowering runs on the
  # backend's 64-bit shifts (lsl/lsr/asr), the 64-bit or that merges the carried
  # bits, and the count branches. Each result's halves are split through a union
  # rather than another shift, so only the shift under test is measured, and the
  # counts span below/at/above the 64-bit word boundary for `<<`, logical `>>`
  # and arithmetic `>>` of a negative value.
  def test_int128_shift
    assert_aarch64_matches_gcc(source(<<~C))
      typedef union { __int128 s; unsigned __int128 u; unsigned long h[2]; } S;
      void show(unsigned __int128 v) { S s; s.u = v; put_long((long)s.h[0]); put_long((long)s.h[1]); }
      int main(void) {
        S in; in.h[0] = 0x0123456789abcdefUL; in.h[1] = 0xfedcba9876543210UL;
        unsigned __int128 u = in.u;
        S si; si.h[0] = 0xffffffffffffffffUL; si.h[1] = 0x8000000000000000UL;
        __int128 sn = si.s;
        int n1 = 1, n65 = 65;
        show(u >> n1); show(u << n1); show(u >> 64); show(u << 64);
        show(u >> n65); show(u << n65); show(u >> 32);
        show((unsigned __int128)(sn >> n1));
        show((unsigned __int128)(sn >> 64));
        show((unsigned __int128)(sn >> n65));
        return 0;
      }
    C
  end

  # 128-bit multiply on aarch64: the high half of the synthesized product rests
  # on `:mulhi`, a single `umulh`, combined with the two cross products the low
  # halves make with the opposite operand's high half. SIZE_MAX * SIZE_MAX
  # exercises umulh's own high word hardest; 2**32 * 2**32 exercises the carry
  # umulh's result contributes into the top of the combined sum; the third case
  # is an ordinary product that never leaves 64 bits, to check the common case
  # is not disturbed. __builtin_mul_overflow (Step 177) computes its
  # infinite-precision product the same way, so its 64-bit boundary cases ride
  # along here too.
  def test_int128_multiply
    assert_aarch64_matches_gcc(source(<<~C))
      typedef union { unsigned __int128 u; unsigned long h[2]; } S;
      void show(unsigned __int128 v) { S s; s.u = v; put_long((long)s.h[0]); put_long((long)s.h[1]); }
      int main(void) {
        unsigned long max = 0xFFFFFFFFFFFFFFFFUL;
        unsigned long high32 = 1UL << 32;
        show((unsigned __int128)max * (unsigned __int128)max);
        show((unsigned __int128)high32 * (unsigned __int128)high32);
        show((unsigned __int128)12345UL * (unsigned __int128)6789UL);

        unsigned long bytes;
        int ov1 = __builtin_mul_overflow(max, max, &bytes);
        put_long(ov1); put_long((long)bytes);
        int ov2 = __builtin_mul_overflow(1000UL, 2000UL, &bytes);
        put_long(ov2); put_long((long)bytes);
        return 0;
      }
    C
  end

  # The same multiply, checked for the single instruction it should collapse
  # to: a synthesized 128-bit multiply's high half is one `umulh`, not a
  # software long-multiplication loop.
  def test_int128_multiply_uses_umulh
    skip_unless_aarch64_toolchain

    in_tmpdir do |dir|
      object_path = File.join(dir, "mulhi.o")
      compile_with_rubycc_aarch64(source(<<~C), object_path)
        unsigned __int128 wide_mul(unsigned long a, unsigned long b) {
          return (unsigned __int128)a * (unsigned __int128)b;
        }
      C
      listing = disassemble_aarch64(object_path)
      assert_match(/\bumulh\b/, listing)
    end
  end

  # --- bit-scan builtins --------------------------------------------------

  # __builtin_ctz / clz / ctzll / clzll on aarch64: a leading-zero count is a
  # bare CLZ and a trailing-zero count an RBIT ahead of it. The operands travel
  # through an array and a function parameter so each count is computed at run
  # time on a value in a register, not folded from a literal.
  #
  # What the cases are chosen to separate is the operand *width*. 0x80000000 has
  # a 32-bit clz of 0 but a 64-bit one of 32, and 1 has a 32-bit clz of 31
  # against 63; a scan that ran on the X view of a 4-byte operand (or on the W
  # view of an 8-byte one) would disagree with gcc on every such line. The
  # all-ones and single-bit-at-either-end values pin the ends of both ranges,
  # and 0x100000000 is the value whose two halves are only told apart by width.
  def test_bit_scan_builtins
    assert_aarch64_matches_gcc(source(<<~C))
      int ctz32(unsigned x) { return __builtin_ctz(x); }
      int clz32(unsigned x) { return __builtin_clz(x); }
      int ctz64(unsigned long x) { return __builtin_ctzll(x); }
      int clz64(unsigned long x) { return __builtin_clzll(x); }
      int main(void) {
        unsigned narrow[6];
        unsigned long wide[6];
        int i;
        narrow[0] = 1u; narrow[1] = 2u; narrow[2] = 0x8000u;
        narrow[3] = 0x80000000u; narrow[4] = 0xFFFFFFFFu; narrow[5] = 0x00F0F000u;
        wide[0] = 1ul; wide[1] = 0xFF00ul; wide[2] = 1ul << 40;
        wide[3] = 1ul << 63; wide[4] = 0xFFFFFFFFFFFFFFFFul; wide[5] = 0x100000000ul;
        for (i = 0; i < 6; i = i + 1) {
          put_long(ctz32(narrow[i]));
          put_long(clz32(narrow[i]));
        }
        for (i = 0; i < 6; i = i + 1) {
          put_long(ctz64(wide[i]));
          put_long(clz64(wide[i]));
        }
        return 0;
      }
    C
  end

  # A deduced-size array of function pointers dispatched by index (Step 98): the
  # "[]" bound is inferred from the initializer even though it sits inside the
  # parenthesized declarator "int (*ops[])(int)", and each ops[i](10) is an
  # indirect call over the AAPCS64 path. The results are split per element so the
  # dispatch itself is measured, not just the total.
  def test_function_pointer_array_dispatch
    assert_aarch64_matches_gcc(source(<<~C))
      static int add1(int x) { return x + 1; }
      static int dbl(int x) { return x * 2; }
      static int neg(int x) { return -x; }
      static int (*ops[])(int) = { 0, add1, dbl, neg };
      int main(void) {
        int i;
        for (i = 1; i < 4; i = i + 1) put_long(ops[i](10));
        put_long((long)(sizeof(ops) / sizeof(ops[0])));
        return 0;
      }
    C
  end

  # Multidimensional arrays on aarch64 (Step 99): a 2D array parameter adjusts
  # to int(*)[3] and each a[i][j] scales the row index by the row stride and the
  # column index by the element width -- the address arithmetic the AAPCS64
  # backend must get right. A static const 2D global with a nested-brace
  # initializer and a pointer-to-array are exercised too, and the halves are
  # emitted separately so the indexing is measured, not just a sum.
  def test_multidimensional_arrays
    assert_aarch64_matches_gcc(source(<<~C))
      static const long tab[2][3] = { {10, 20, 30}, {40, 50, 60} };
      static long sum2d(long a[][3], int rows) {
        long s = 0;
        for (int i = 0; i < rows; i = i + 1)
          for (int j = 0; j < 3; j = j + 1) s = s + a[i][j];
        return s;
      }
      int main(void) {
        long m[2][3];
        for (int i = 0; i < 2; i = i + 1)
          for (int j = 0; j < 3; j = j + 1) m[i][j] = tab[i][j] + i;
        long (*pm)[3] = m;
        put_long(sum2d(m, 2));
        put_long(pm[1][2]);
        put_long(m[0][1]);
        put_long((long)(sizeof(m) / sizeof(long)));
        return 0;
      }
    C
  end

  # --- disassembly sanity -------------------------------------------------

  # Every word the backend emits must decode to a real A64 instruction. objdump
  # prints an undecodable word as ".word 0x..." or "undefined", so their absence
  # is a cheap net over the whole encoding table — including the words no
  # execution test happens to reach.
  def assert_disassembles_cleanly(c_source)
    skip_unless_aarch64_toolchain

    in_tmpdir do |dir|
      object_path = File.join(dir, "sanity.o")
      compile_with_rubycc_aarch64(c_source, object_path)
      listing = disassemble_aarch64(object_path)

      bad = listing.lines.select { |line| line.match?(/\t\.word|undefined|\(unknown\)/) }
      assert_empty bad, "objdump could not decode #{bad.size} instruction(s):\n#{bad.join}"
      refute_empty listing.lines.grep(/\tret$/), "expected at least one ret in the disassembly"
    end
  end

  def test_disassembly_has_no_undecodable_words
    assert_disassembles_cleanly(source(<<~C))
      int work(int a, long b, unsigned int c, int *p, char *q, unsigned long d) {
        int arr[4];
        long i;
        int r = 0;
        for (i = 0; i < 4; i = i + 1) { arr[i] = (int)(b >> i); }
        r = a + arr[0] * 2 - arr[1] / 3 + arr[2] % 5;
        r = r ^ (int)(c >> 3) | (a << 2) & ~a;
        if (a < 0 && c > 7u) { r = -r; } else if (d >= 9ul || a != 0) { r = r + 1; }
        *p = r;
        *q = (char)r;
        return r + (int)d;
      }
      int main(void) {
        int x = 0;
        char y = 0;
        put_long(work(3, 40000000000L, 9u, &x, &y, 12ul));
        put_long(x);
        put_long(y);
        return x & 255;
      }
    C
  end

  def test_disassembly_of_large_frame_is_decodable
    assert_disassembles_cleanly(source(<<~C))
      int main(void) {
        int big[20000];
        int tail = 7;
        int i;
        for (i = 0; i < 20000; i = i + 1) { big[i] = i; }
        put_long(big[19999] + tail);
        return tail;
      }
    C
  end
end
