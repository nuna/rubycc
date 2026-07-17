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
    #if __has_builtin(__builtin_no_such_thing_xyz)
    #define MISSING 1
    #else
    #define MISSING 0
    #endif
    int main(void) {
      printf("%d %d %d %d\\n", HAVE_OPERATOR, KNOWN, ALSO, MISSING);
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

  def test_unreachable_matches_gcc
    assert_matches_gcc(UNREACHABLE_SOURCE, "unreachable")
  end

  def test_memcpy_matches_gcc
    assert_matches_gcc(MEMCPY_SOURCE, "memcpy")
  end

  def test_binary_literal_matches_gcc
    assert_matches_gcc(BINARY_LITERAL_SOURCE, "binary_literal")
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
      Rubycc::Compiler.new.compile(source, filename: "choose.c")
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
      Rubycc::Compiler.new.compile(source, filename: "bin.c")
    end
    assert_match(/binary constant/, error.message)
  end

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

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
