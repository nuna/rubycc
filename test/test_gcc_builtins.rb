# frozen_string_literal: true

require_relative "test_helper"

# Step 44 (M2 addendum): the gcc builtins and small extensions CRuby's config.h
# bakes in as always-available (probed once under gcc) and that its headers and
# the json/msgpack gems then use unconditionally — __has_builtin,
# __builtin_constant_p, __builtin_choose_expr, __builtin_ctz/clz(ll),
# __builtin_unreachable, __builtin_memcpy — plus C23 binary literals. Each is
# cross-checked against gcc where it has an observable value, and the
# compile-time-only forms are checked for compiling (and for the diagnostics
# they must still raise).
class TestGccBuiltins < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # __has_builtin answers 1 for the builtins rubycc's front end recognizes and 0
  # for one it does not (__builtin_bswap64), and #ifdef __has_builtin is true —
  # so the honest operator lets a header take its fallback path for a missing
  # builtin instead of calling one rubycc cannot lower.
  HAS_BUILTIN_SOURCE = <<~C
    #include <stdio.h>
    #ifdef __has_builtin
    #define HAVE_OPERATOR 1
    #else
    #define HAVE_OPERATOR 0
    #endif
    #if __has_builtin(__builtin_ctz)
    #define KNOWN 1
    #else
    #define KNOWN 0
    #endif
    #if __has_builtin(__builtin_memcpy)
    #define ALSO 1
    #else
    #define ALSO 0
    #endif
    #if __has_builtin(__builtin_popcount) && __has_builtin(__builtin_popcountl) && \\
        __has_builtin(__builtin_popcountll)
    #define COUNTS 1
    #else
    #define COUNTS 0
    #endif
    #if __has_builtin(__builtin_ctzl) && __has_builtin(__builtin_clzl)
    #define LONG_SCANS 1
    #else
    #define LONG_SCANS 0
    #endif
    #if __has_builtin(__builtin_no_such_thing_xyz)
    #define MISSING 1
    #else
    #define MISSING 0
    #endif
    int main(void) {
      printf("%d %d %d %d %d %d\\n", HAVE_OPERATOR, KNOWN, ALSO, COUNTS, LONG_SCANS, MISSING);
      return 0;
    }
  C

  # __builtin_constant_p: 1 for an expression that folds to a constant, 0 for one
  # that does not (a variable, a function call) — never an error — and its
  # operand is not evaluated, so a call in it has no side effect.
  CONSTANT_P_SOURCE = <<~C
    #include <stdio.h>
    int calls = 0;
    int bump(void) { calls++; return 7; }
    int main(void) {
      int v = 5;
      int a = __builtin_constant_p(2 + 3);
      int b = __builtin_constant_p(v);
      int c = __builtin_constant_p(bump());
      int d = __builtin_constant_p(v * 2 + 1);
      printf("%d %d %d %d %d\\n", a, b, c, d, calls);
      return 0;
    }
  C

  # __builtin_choose_expr picks one operand at compile time by its constant first
  # argument: the whole expression takes the chosen operand's value AND type
  # (checked with sizeof), the unchosen operand is not evaluated, and the form
  # nests and works in a static initializer.
  CHOOSE_EXPR_SOURCE = <<~C
    #include <stdio.h>
    int calls = 0;
    int bump(void) { calls++; return 99; }
    static int picked = __builtin_choose_expr(1, 41, 42);
    int main(void) {
      long chosen_long = __builtin_choose_expr(1, 7L, (char)0);
      char chosen_char = __builtin_choose_expr(0, 7L, (char)3);
      int value = __builtin_choose_expr(0, bump(), 55);
      int nested = __builtin_choose_expr(1, __builtin_choose_expr(0, 1, 2), 3);
      printf("%zu %zu %d %d %d %d\\n",
             sizeof(chosen_long), sizeof(chosen_char),
             value, calls, nested, picked);
      return 0;
    }
  C

  # __builtin_ctz/clz and their "ll" forms over representative values, matched
  # against gcc's own lowering (x == 0 is undefined, so it is never tested).
  BIT_SCAN_SOURCE = <<~C
    #include <stdio.h>
    int main(void) {
      unsigned a = 1, b = 2, c = 0x8000, d = 0x80000000u;
      unsigned long e = 1UL << 63, f = 0xFF00UL, g = 1UL << 40;
      printf("%d %d %d %d\\n",
             __builtin_ctz(a), __builtin_ctz(b), __builtin_ctz(c), __builtin_ctz(d));
      printf("%d %d %d %d\\n",
             __builtin_clz(a), __builtin_clz(b), __builtin_clz(c), __builtin_clz(d));
      printf("%d %d %d\\n",
             __builtin_ctzll(e), __builtin_ctzll(f), __builtin_ctzll(g));
      printf("%d %d %d\\n",
             __builtin_clzll(e), __builtin_clzll(f), __builtin_clzll(g));
      return 0;
    }
  C

  # The "l" spellings of the two scans, which name `long` where the plain form
  # names `int` and the "ll" one `long long`. On both targets rubycc emits for
  # `long` is 8 bytes, so every "l" answer must equal its "ll" neighbour's — and
  # must differ from the 32-bit form wherever the width is what decides (the
  # clz of 1 is 31 at 32 bits and 63 at 64). The comparison against gcc is what
  # settles the width question: gcc is counting in a real `long`.
  LONG_BIT_SCAN_SOURCE = <<~C
    #include <stdio.h>
    int ctz_l(unsigned long x) { return __builtin_ctzl(x); }
    int clz_l(unsigned long x) { return __builtin_clzl(x); }
    int ctz_ll(unsigned long long x) { return __builtin_ctzll(x); }
    int clz_ll(unsigned long long x) { return __builtin_clzll(x); }
    int main(void) {
      unsigned long values[6];
      int i;
      values[0] = 1UL; values[1] = 0xFF00UL; values[2] = 1UL << 40;
      values[3] = 1UL << 63; values[4] = 0xFFFFFFFFFFFFFFFFUL; values[5] = 0x100000000UL;
      for (i = 0; i < 6; i++) {
        printf("%d %d %d %d\\n", ctz_l(values[i]), ctz_ll(values[i]),
               clz_l(values[i]), clz_ll(values[i]));
      }
      printf("%d %d\\n", __builtin_clzl(1UL), __builtin_ctzl(1UL << 40));
      return 0;
    }
  C

  # __builtin_popcount and its "l"/"ll" forms over representative values: zero,
  # a single bit at either end, every bit, each half alone, and two mottled
  # patterns. The operands travel through an array and a function parameter so
  # the count runs on a value in a register — a literal would be folded by the
  # constant evaluator and would say nothing about what the backends emit.
  # Unlike a bit scan, zero is a defined operand here and counts 0.
  #
  # The last three lines are about the operand's *width*, which is the builtin's
  # and not the argument's: a signed -1 counts 32 bits through the plain form
  # and 64 through the "ll" one, a `signed char` of -1 counts the 32 bits its
  # promotion and conversion leave, and a value whose high half is set counts
  # only its low half through the 4-byte form.
  POPCOUNT_SOURCE = <<~C
    #include <stdio.h>
    int count_int(unsigned x) { return __builtin_popcount(x); }
    int count_long(unsigned long x) { return __builtin_popcountl(x); }
    int count_long_long(unsigned long long x) { return __builtin_popcountll(x); }
    int count_of_char(signed char c) { return __builtin_popcount(c); }
    int count_low_half(unsigned long long x) { return __builtin_popcount(x); }
    int main(void) {
      unsigned narrow[7];
      unsigned long long wide[7];
      int i;
      narrow[0] = 0u; narrow[1] = 1u; narrow[2] = 0x80000000u; narrow[3] = 0xFFFFFFFFu;
      narrow[4] = 0xFFFF0000u; narrow[5] = 0x0000FFFFu; narrow[6] = 0xDEADBEEFu;
      wide[0] = 0ull; wide[1] = 1ull; wide[2] = 1ull << 63;
      wide[3] = 0xFFFFFFFFFFFFFFFFull; wide[4] = 0xFFFFFFFF00000000ull;
      wide[5] = 0x00000000FFFFFFFFull; wide[6] = 0x0123456789ABCDEFull;
      for (i = 0; i < 7; i++) {
        printf("%d %d %d\\n", count_int(narrow[i]), count_long((unsigned long)wide[i]),
               count_long_long(wide[i]));
      }
      printf("%d %d\\n", count_int(-1), count_long_long(-1));
      printf("%d %d\\n", count_of_char(-1), count_low_half(0xFFFFFFFF00000001ull));
      printf("%d %d %d\\n", __builtin_popcount(-1), __builtin_popcountl(0xFFFFul),
             __builtin_popcountll(0xF0F0F0F0F0F0F0F0ull));
      /* The whole expression is an int whatever the operand's width was, which
         sizeof reads off the type alone (the operand is not evaluated). */
      printf("%zu %zu\\n", sizeof(__builtin_popcount(narrow[0])),
             sizeof(__builtin_popcountll(wide[0])));
      return 0;
    }
  C

  # The same counts in the contexts that need a *constant*, which is the shape a
  # header takes when it sizes something by a bit mask: a static initializer, an
  # array bound, an enumerator, a _Static_assert and a case label. None of these
  # reaches a backend at all — the constant evaluator answers them — so they are
  # the second of the two paths a fold has to agree with gcc on.
  #
  # A preprocessor "#if" is deliberately absent: a builtin call is not a
  # constant expression there (gcc reports "missing binary operator before token
  # '('", the identifier having been replaced by 0), so the only constant
  # contexts to match are the translation-time ones below.
  POPCOUNT_CONSTANT_SOURCE = <<~C
    #include <stdio.h>
    static int folded = __builtin_popcount(0xFFu);
    static char sized[__builtin_popcountll(0xF0F0F0F0F0F0F0F0ULL)];
    enum { LOW_BITS = __builtin_popcountl(0xFFFFUL), NEGATIVE = __builtin_popcount(-1) };
    int main(void) {
      _Static_assert(__builtin_popcount(0x10101) == 3, "a set-bit count folds");
      _Static_assert(__builtin_popcount(0) == 0, "zero is a defined operand");
      _Static_assert(__builtin_ctzl(1UL << 40) == 40, "the l spelling folds too");
      _Static_assert(__builtin_clzl(1UL) == 63, "and counts in 64 bits");
      switch (folded) {
        case __builtin_popcount(255): puts("the case label folded"); break;
        default: puts("unreachable"); break;
      }
      printf("%d %zu %d %d\\n", folded, sizeof(sized), (int)LOW_BITS, (int)NEGATIVE);
      return 0;
    }
  C

  # __builtin_unreachable compiles in the two shapes CRuby's UNREACHABLE_RETURN
  # takes: the comma expression "(__builtin_unreachable(), value)" and a plain
  # statement after a return. It is only reached on a path the program never
  # takes, so its runtime behavior stays defined.
  UNREACHABLE_SOURCE = <<~C
    #include <stdio.h>
    int classify(int x) {
      if (x > 0) return 1;
      if (x < 0) return -1;
      if (x == 0) return 0;
      return (__builtin_unreachable(), 999);
    }
    int pick(int x) {
      switch (x) {
        case 1: return 10;
        default: return 20;
      }
      __builtin_unreachable();
    }
    int main(void) {
      printf("%d %d %d %d\\n", classify(5), classify(-3), classify(0), pick(1));
      return 0;
    }
  C

  # __builtin_memcpy copies bytes for a buffer and a whole struct, matched
  # against gcc; it works with no <string.h> in sight (gcc's builtin, which
  # rubycc seeds a prototype for).
  MEMCPY_SOURCE = <<~C
    #include <stdio.h>
    struct rec { int id; char name[8]; long stamp; };
    int main(void) {
      char dst[12];
      __builtin_memcpy(dst, "hello!!\\0abc", 12);
      struct rec a = { 1, "abc", 99 };
      struct rec b;
      __builtin_memcpy(&b, &a, sizeof a);
      printf("%s %d %s %ld\\n", dst, b.id, b.name, b.stamp);
      return 0;
    }
  C

  # Binary literals (0b.../0B...) with and without suffixes, and inside a #if
  # constant expression through a macro — all matched against gcc.
  BINARY_LITERAL_SOURCE = <<~C
    #include <stdio.h>
    #define RECURSIVE 0b0001
    #define WIDE 0B1010
    #if (RECURSIVE | WIDE) == 0b1011
    #define GUARD 1
    #else
    #define GUARD 0
    #endif
    int main(void) {
      int a = 0b0;
      int b = 0b101;
      unsigned long c = 0b1111000011110000UL;
      long d = 0B10000000000000000000000000000000L;
      printf("%d %d %lu %ld %d %d\\n", a, b, c, d, RECURSIVE | WIDE, GUARD);
      return 0;
    }
  C

  # __builtin_add/sub/mul_overflow over the shapes their users write: an
  # unsigned wrap that is still stored, a computation that fits, a signed
  # overflow at INT_MAX, an unsigned underflow at 0, the size_t product ruby's
  # allocation paths check, operands whose types differ from the destination's
  # (where the infinite-precision rule shows: int -1 plus unsigned 1 is 0, not
  # UINT_MAX), and a destination narrower than the operands. Every value and
  # every 0/1 answer is matched against gcc.
  OVERFLOW_SOURCE = <<~C
    #include <stdio.h>
    #include <limits.h>
    #include <stddef.h>
    int main(void) {
      unsigned char uc;
      int wrapped = __builtin_add_overflow(200, 100, &uc);

      int sum;
      int fits = __builtin_add_overflow(2000000, 40, &sum);

      int big;
      int at_max = __builtin_add_overflow(INT_MAX, 1, &big);
      int low;
      int at_min = __builtin_sub_overflow(INT_MIN, 1, &low);

      unsigned under;
      int borrowed = __builtin_sub_overflow(0u, 1u, &under);

      size_t bytes;
      size_t count = (size_t)1 << 40;
      int too_many = __builtin_mul_overflow(count, (size_t)0x10000000, &bytes);
      size_t room;
      int room_ok = __builtin_mul_overflow((size_t)12345, sizeof(long), &room);
      size_t all;
      int all_over = __builtin_mul_overflow((size_t)-1, (size_t)2, &all);

      int a = -1;
      unsigned b = 1;
      unsigned mixed;
      int mixed_over = __builtin_add_overflow(a, b, &mixed);
      int negative;
      int neg_over = __builtin_sub_overflow(a, b, &negative);

      char narrow;
      int narrowed = __builtin_add_overflow(300, 27, &narrow);

      long product;
      int signed_product = __builtin_mul_overflow(-3000000000L, 4L, &product);
      long small;
      int small_ok = __builtin_mul_overflow(-100000L, 3L, &small);

      printf("%d %u\\n", wrapped, uc);
      printf("%d %d\\n", fits, sum);
      printf("%d %d %d %d\\n", at_max, big, at_min, low);
      printf("%d %u\\n", borrowed, under);
      printf("%d %zu %d %zu %d %zu\\n",
             too_many, bytes, room_ok, room, all_over, all);
      printf("%d %u %d %d\\n", mixed_over, mixed, neg_over, negative);
      printf("%d %d\\n", narrowed, narrow);
      printf("%d %ld %d %ld\\n", signed_product, product, small_ok, small);
      return 0;
    }
  C

  # The overflow builtins over every combination of operand signedness at the
  # 64-bit boundary, where the 128-bit intermediate is worked hardest: two
  # unsigned maxima multiply to nearly 2**128, a negative long times an unsigned
  # long stays under 2**127, and the results land in destinations of both
  # signednesses. Matched against gcc.
  OVERFLOW_EXTREMES_SOURCE = <<~C
    #include <stdio.h>
    #include <limits.h>
    int main(void) {
      unsigned long um = ULONG_MAX, half = 1UL << 63;
      long lmin = LONG_MIN, lmax = LONG_MAX;
      unsigned long ur;
      long lr;
      int r[12];
      r[0] = __builtin_mul_overflow(um, um, &ur);
      printf("%d %lu\\n", r[0], ur);
      r[1] = __builtin_mul_overflow(um, 1UL, &ur);
      printf("%d %lu\\n", r[1], ur);
      r[2] = __builtin_mul_overflow(half, 2UL, &ur);
      printf("%d %lu\\n", r[2], ur);
      r[3] = __builtin_mul_overflow(lmin, 2L, &lr);
      printf("%d %ld\\n", r[3], lr);
      r[4] = __builtin_mul_overflow(lmin, -1L, &lr);
      printf("%d %ld\\n", r[4], lr);
      r[5] = __builtin_mul_overflow(lmin, lmin, &lr);
      printf("%d %ld\\n", r[5], lr);
      r[6] = __builtin_mul_overflow(-1L, um, &ur);
      printf("%d %lu\\n", r[6], ur);
      r[7] = __builtin_mul_overflow(-1L, um, &lr);
      printf("%d %ld\\n", r[7], lr);
      r[8] = __builtin_add_overflow(um, um, &ur);
      printf("%d %lu\\n", r[8], ur);
      r[9] = __builtin_add_overflow(lmax, lmax, &lr);
      printf("%d %ld\\n", r[9], lr);
      r[10] = __builtin_sub_overflow(lmin, lmax, &lr);
      printf("%d %ld\\n", r[10], lr);
      r[11] = __builtin_sub_overflow(0UL, um, &lr);
      printf("%d %ld\\n", r[11], lr);
      return 0;
    }
  C

  def test_has_builtin_matches_gcc
    assert_matches_gcc(HAS_BUILTIN_SOURCE, "has_builtin")
  end

  def test_constant_p_matches_gcc
    assert_matches_gcc(CONSTANT_P_SOURCE, "constant_p")
  end

  def test_choose_expr_matches_gcc
    assert_matches_gcc(CHOOSE_EXPR_SOURCE, "choose_expr")
  end

  def test_bit_scan_matches_gcc
    assert_matches_gcc(BIT_SCAN_SOURCE, "bit_scan")
  end

  def test_long_spelled_bit_scans_match_gcc
    assert_matches_gcc(LONG_BIT_SCAN_SOURCE, "long_bit_scan")
  end

  def test_popcount_matches_gcc
    assert_matches_gcc(POPCOUNT_SOURCE, "popcount")
  end

  def test_popcount_in_constant_contexts_matches_gcc
    assert_matches_gcc(POPCOUNT_CONSTANT_SOURCE, "popcount_constant")
  end

  # The operand has to be an integer: there is nothing to count in a double, and
  # gcc rejects it too. The diagnostic names the operand's own token.
  def test_popcount_of_non_integer_rejected
    source = <<~C
      int main(void) {
        double d = 1.0;
        return __builtin_popcount(d);
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "popcount_type.c", target: host_target)
    end
    assert_match(/argument to a bit-count builtin is not of integer type/, error.message)
  end

  def test_unreachable_matches_gcc
    assert_matches_gcc(UNREACHABLE_SOURCE, "unreachable")
  end

  def test_memcpy_matches_gcc
    assert_matches_gcc(MEMCPY_SOURCE, "memcpy")
  end

  def test_binary_literal_matches_gcc
    assert_matches_gcc(BINARY_LITERAL_SOURCE, "binary_literal")
  end

  def test_overflow_builtins_match_gcc
    assert_matches_gcc(OVERFLOW_SOURCE, "overflow")
  end

  def test_overflow_builtins_at_the_64_bit_boundary_match_gcc
    assert_matches_gcc(OVERFLOW_EXTREMES_SOURCE, "overflow_extremes")
  end

  # The overflow builtins take exactly three arguments; a call with any other
  # count is an arity diagnostic rather than a punctuator mismatch.
  def test_overflow_builtin_wrong_argument_count_rejected
    source = <<~C
      int main(void) {
        int r;
        return __builtin_add_overflow(1, &r);
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "overflow_arity.c", target: host_target)
    end
    assert_match(/__builtin_add_overflow' expects 3 arguments, have 2/, error.message)
  end

  # The third argument must be a pointer to an integer object: there is nowhere
  # else to put the result, and its type is what the range check is against.
  def test_overflow_builtin_non_integer_destination_rejected
    source = <<~C
      int main(void) {
        double d;
        return __builtin_mul_overflow(2, 3, &d);
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "overflow_dest.c", target: host_target)
    end
    assert_match(/last argument to '__builtin_mul_overflow' is not a pointer to an integer/,
                 error.message)
  end

  # Both value operands must be integers.
  def test_overflow_builtin_non_integer_operand_rejected
    source = <<~C
      int main(void) {
        int r;
        int *p = &r;
        return __builtin_sub_overflow(p, 1, &r);
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "overflow_operand.c", target: host_target)
    end
    assert_match(/argument to '__builtin_sub_overflow' is not of integer type/, error.message)
  end

  # A 128-bit operand has no wider intermediate to be checked exactly in, so it
  # is refused rather than answered from a truncated computation.
  def test_overflow_builtin_128_bit_operand_rejected
    source = <<~C
      int main(void) {
        unsigned __int128 wide = 1;
        unsigned long r;
        return __builtin_add_overflow(wide, 1UL, &r);
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "overflow_wide.c", target: host_target)
    end
    assert_match(/'__builtin_add_overflow' does not support 128-bit operands/, error.message)
  end

  # ... and neither has a 128-bit destination.
  def test_overflow_builtin_128_bit_destination_rejected
    source = <<~C
      int main(void) {
        unsigned __int128 wide;
        return __builtin_mul_overflow(2, 3, &wide);
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "overflow_wide_dest.c", target: host_target)
    end
    assert_match(/'__builtin_mul_overflow' does not support a 128-bit result type/, error.message)
  end

  # __has_builtin reports the three overflow builtins present, which is how
  # <stdckdint.h>-style headers pick the builtin path over a fallback.
  def test_has_builtin_reports_overflow_builtins_present
    source = <<~C
      int main(void) {
      #if __has_builtin(__builtin_add_overflow) && __has_builtin(__builtin_sub_overflow) \\
          && __has_builtin(__builtin_mul_overflow)
        return 0;
      #else
        return 1;
      #endif
      }
    C
    assert_c_exit_status(0, source)
  end

  # A __builtin_choose_expr whose first argument is not a constant expression is
  # a diagnostic — the selector must be foldable at compile time.
  def test_choose_expr_non_constant_selector_rejected
    source = <<~C
      int main(void) {
        int n = 1;
        return __builtin_choose_expr(n, 1, 2);
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "choose.c", target: host_target)
    end
    assert_match(/__builtin_choose_expr.*not a constant/, error.message)
  end

  # __has_builtin answers honestly: it is 0 for a builtin gcc has but rubycc does
  # not lower (__builtin_bswap64), which is exactly what lets json's parser.c take
  # its portable fallback instead of calling one rubycc cannot emit. (This cannot
  # be a gcc-differential check, since gcc's __has_builtin(__builtin_bswap64) is
  # 1.) The program returns 0 only when the operator reports the builtin absent.
  def test_has_builtin_reports_unsupported_builtin_absent
    source = <<~C
      int main(void) {
      #if __has_builtin(__builtin_bswap64)
        return 1;
      #else
        return 0;
      #endif
      }
    C
    assert_c_exit_status(0, source)
  end

  # A binary constant with no digits after "0b" is rejected.
  def test_empty_binary_literal_rejected
    source = <<~C
      int main(void) { return 0b; }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "bin.c", target: host_target)
    end
    assert_match(/binary constant/, error.message)
  end

  def assert_matches_gcc(source, name)
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      binary = Rubycc::Compiler.new.compile(source, filename: "#{name}.c", target: host_target)
      File.binwrite(rubycc_obj, binary)
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = compile_with_gcc(source, File.join(dir, "#{name}_gcc.o"))
      gcc_status, gcc_out = link_and_run(gcc_obj)

      assert_equal 0, rubycc_status, "rubycc-built #{name} exited #{rubycc_status}"
      assert_equal gcc_status, rubycc_status, "#{name}: exit status differs from gcc"
      assert_equal gcc_out, rubycc_out, "#{name}: output differs from gcc"
    end
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
