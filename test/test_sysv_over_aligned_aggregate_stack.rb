# frozen_string_literal: true

require_relative "test_helper"

# sysv-over-aligned-aggregate-stack-1: where an aggregate aligned to 32 or 64
# bytes goes in the stack argument area on x86-64.
#
# gcc 13.3 starts such an aggregate (always MEMORY class: it is at least as
# long as its alignment) at an argument-area offset that is a multiple of its
# alignment, for a type attribute and an _Alignas member alike: after one to
# three stacked longs a 32-aligned one sits at offset 32 and a 64-aligned one
# at 64, and the long after it follows at its end. The area itself is aligned
# that far in absolute terms, because the callee's va_arg rounds the overflow
# *pointer* up, not an offset (measured 2026-09-15). rubycc used to align to
# at most 16 and kept the area only 16-aligned.
#
# Each case links a gcc-built translation unit against a rubycc-built one and
# requires the output of gcc building both (the oracle), in both directions:
# a rubycc caller must place the aggregate where a gcc callee reads it, and a
# rubycc callee (a named parameter, a va_arg) must read it where a gcc caller
# put it. Every shape runs with 0 to 9 long arguments ahead of it (0 to 3 of
# them on the stack once the six integer registers are spent) as a fixed and
# as a variadic argument, and comes back as a return value. Further cases put
# two over-aligned arguments in one call, mix one with a double and a 16-byte
# aligned struct in a variable part, call through a function pointer, call
# after __builtin_alloca has moved rsp, and pass one on from a callee that
# received it.
#
# The aarch64 half runs the same source. AAPCS64 passes every one of these
# shapes by reference, so it only guards that half against the change.
class TestSysvOverAlignedAggregateStack < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # [name, declaration, type, fill (writes `v` from `s`), meaningful bytes].
  # Only the meaningful bytes are printed: the padding of an over-aligned
  # struct is not preserved when it is passed by value.
  SHAPES = [
    ["a32", "struct a32 { long a, b; } __attribute__((aligned(32)));", "struct a32",
     "v.a = s * 3 + 1; v.b = -s;", 16],
    ["m32", "struct m32 { _Alignas(32) long a; long b; };", "struct m32",
     "v.a = s * 5 + 2; v.b = s << 8;", 16],
    ["a32w", "struct a32w { long a[5]; } __attribute__((aligned(32)));", "struct a32w",
     "for (int k = 0; k < 5; k++) v.a[k] = s * 7 + k;", 40],
    ["d32", "struct d32 { double d[3]; } __attribute__((aligned(32)));", "struct d32",
     "v.d[0] = s + 0.5; v.d[1] = -s * 0.25; v.d[2] = s * 3.0;", 24],
    ["a64", "struct a64 { long a, b; } __attribute__((aligned(64)));", "struct a64",
     "v.a = s * 11; v.b = s + 13;", 16],
    ["m64", "struct m64 { _Alignas(64) long a; long b; };", "struct m64",
     "v.a = s * 17; v.b = s - 19;", 16],
    ["a64w", "struct a64w { long a[9]; } __attribute__((aligned(64)));", "struct a64w",
     "for (int k = 0; k < 9; k++) v.a[k] = s * 23 - k;", 72],
  ].freeze

  # Long arguments ahead of the aggregate: 0..5 leave some integer registers
  # free (the aggregate is on the stack at offset 0 regardless), 6..9 put 0 to
  # 3 longs on the stack ahead of it.
  PREFIXES = (0..9).to_a.freeze

  def test_rubycc_caller_gcc_callee_x86_64
    assert_mixed_matches_oracle(:x86_64, caller: :rubycc)
  end

  def test_gcc_caller_rubycc_callee_x86_64
    assert_mixed_matches_oracle(:x86_64, callee: :rubycc)
  end

  def test_rubycc_caller_gcc_callee_aarch64
    assert_mixed_matches_oracle(:aarch64, caller: :rubycc)
  end

  def test_gcc_caller_rubycc_callee_aarch64
    assert_mixed_matches_oracle(:aarch64, callee: :rubycc)
  end

  private

  def assert_mixed_matches_oracle(target, caller: :gcc, callee: :gcc)
    skip_unless_x86_64_host if target == :x86_64
    skip_unless_aarch64_toolchain if target == :aarch64

    units = ->(callee_cc, caller_cc) { [[callee_source, callee_cc], [caller_source, caller_cc]] }
    oracle = run_units(target, units.call(:gcc, :gcc))
    mixed = run_units(target, units.call(callee, caller))
    assert_equal 0, oracle[0], "#{target}: the gcc oracle itself failed"
    assert oracle[1].end_with?("done\n"), "#{target}: oracle output is incomplete"
    assert_equal oracle, mixed, "#{target}: caller #{caller} / callee #{callee} differs from gcc/gcc"
  end

  def run_units(target, units)
    target == :x86_64 ? link_units_and_run(units) : link_units_and_run_aarch64(units)
  end

  # Shape definitions, a maker and a printer shared by both units. The
  # printer reads the meaningful bytes back as longs so every shape, double
  # or not, prints its exact bit pattern.
  def common_prefix
    helpers = SHAPES.map do |name, decl, type, fill, bytes|
      <<~C
        #{decl}
        static #{type} make_#{name}(long s) { #{type} v; memset(&v, 0, sizeof v); #{fill} return v; }
        static void print_#{name}(const #{type} *p) {
          long w[#{bytes / 8}];
          memcpy(w, p, sizeof w);
          for (int i = 0; i < #{bytes / 8}; i++) printf(" %lx", w[i]);
        }
      C
    end
    <<~C
      #include <stdarg.h>
      #include <stdio.h>
      #include <string.h>

      struct i128 { __int128 v; };

      #{helpers.join("\n")}
    C
  end

  def prefix_params(count)
    (1..count).map { |i| "long p#{i}" }
  end

  # Per shape: one fixed-argument function per prefix length, one variadic
  # reader, and one function returning the aggregate; then the mixed cases.
  def callee_source
    bodies = SHAPES.flat_map do |name, _decl, type, *|
      fixed = PREFIXES.map do |count|
        params = [*prefix_params(count), "#{type} x", "long tail"]
        sum = count.zero? ? "0L" : (1..count).map { |i| "p#{i}" }.join(" + ")
        <<~C
          void fix_#{name}_#{count}(#{params.join(", ")}) {
            printf("fix #{name} #{count} %ld [", #{sum});
            print_#{name}(&x);
            printf("] %ld\\n", tail);
          }
        C
      end
      variadic = <<~C
        void var_#{name}(int count, ...) {
          va_list ap;
          va_start(ap, count);
          long sum = 0;
          for (int i = 0; i < count; i++) sum = sum * 31 + va_arg(ap, long);
          #{type} x = va_arg(ap, #{type});
          long mid = va_arg(ap, long);
          #{type} y = va_arg(ap, #{type});
          long tail = va_arg(ap, long);
          va_end(ap);
          printf("var #{name} %d %ld [", count, sum);
          print_#{name}(&x);
          printf("] %ld [", mid);
          print_#{name}(&y);
          printf("] %ld\\n", tail);
        }
      C
      echo = <<~C
        #{type} echo_#{name}(long a, #{type} x, long b) {
          #{type} r = x;
          long w;
          memcpy(&w, &r, sizeof w);
          w += a * 1000 + b;
          memcpy(&r, &w, sizeof w);
          return r;
        }
      C
      [*fixed, variadic, echo]
    end
    <<~C
      #{common_prefix}
      #{bodies.join("\n")}

      /* Three over-aligned aggregates in one fixed list, behind a stacked long. */
      void two(long p1, long p2, long p3, long p4, long p5, long p6, long p7,
               struct a32 x, struct a64 y, struct m32 z, long tail) {
        printf("two %ld [", p1 + p2 + p3 + p4 + p5 + p6 + p7);
        print_a32(&x);
        printf("] [");
        print_a64(&y);
        printf("] [");
        print_m32(&z);
        printf("] %ld\\n", tail);
      }

      /* A variable part mixing over-aligned aggregates with a double (xmm) and
         a 16-byte aligned struct. */
      void mix(int count, ...) {
        va_list ap;
        va_start(ap, count);
        long sum = 0;
        for (int i = 0; i < count; i++) sum = sum * 31 + va_arg(ap, long);
        struct a32 x = va_arg(ap, struct a32);
        double d = va_arg(ap, double);
        struct m64 y = va_arg(ap, struct m64);
        struct i128 z = va_arg(ap, struct i128);
        struct a32w w = va_arg(ap, struct a32w);
        long tail = va_arg(ap, long);
        va_end(ap);
        long zw[2];
        memcpy(zw, &z, sizeof zw);
        printf("mix %d %ld [", count, sum);
        print_a32(&x);
        printf("] %a [", d);
        print_m64(&y);
        printf("] [%lx %lx] [", zw[0], zw[1]);
        print_a32w(&w);
        printf("] %ld\\n", tail);
      }

      /* Receives an over-aligned aggregate and passes it on as a caller. */
      void sink_a64(long p1, long p2, long p3, long p4, long p5, long p6, long p7, struct a64 x, long tail);
      void fwd(long a, struct a64 x, long tail) {
        sink_a64(a, a + 1, a + 2, a + 3, a + 4, a + 5, a + 6, x, tail + 1);
      }
    C
  end

  def caller_source
    declarations = SHAPES.flat_map do |name, _decl, type, *|
      fixed = PREFIXES.map do |count|
        "void fix_#{name}_#{count}(#{[*prefix_params(count), type, "long"].join(", ")});"
      end
      [*fixed, "void var_#{name}(int count, ...);", "#{type} echo_#{name}(long a, #{type} x, long b);"]
    end
    calls = SHAPES.each_with_index.flat_map do |(name, _decl, type, *), index|
      lines = PREFIXES.flat_map do |count|
        seed = (index * 16) + count + 1
        prefix = (1..count).map { |i| "#{(i * 7) + seed}L" }
        [
          "  { #{type} x = make_#{name}(#{seed}); " \
          "fix_#{name}_#{count}(#{[*prefix, "x", "#{seed * 1_000_003}L"].join(", ")}); }",
          "  { #{type} x = make_#{name}(#{seed}); #{type} y = make_#{name}(#{seed + 500}); " \
          "var_#{name}(#{[count, *prefix, "x", "#{seed + 1000}L", "y", "#{seed * 7_000_001}L"].join(", ")}); }",
        ]
      end
      lines << "  { #{type} x = make_#{name}(#{index + 900}); #{type} r = echo_#{name}(#{index + 3}L, x, 9L); " \
               "printf(\"ret #{name} [\"); print_#{name}(&r); printf(\"]\\n\"); }"
      lines
    end
    mix_calls = PREFIXES.map do |count|
      prefix = (1..count).map { |i| "#{(i * 13) + count}L" }
      "  { struct a32 x = make_a32(#{count + 40}); struct m64 y = make_m64(#{count + 50}); " \
        "struct i128 z; long zw[2] = { #{count} * 99L, -#{count}L }; memcpy(&z, zw, sizeof z); " \
        "struct a32w w = make_a32w(#{count + 60}); " \
        "mix(#{[count, *prefix, "x", "#{count}.5", "y", "z", "w", "#{count * 1_000_007}L"].join(", ")}); }"
    end
    <<~C
      #{common_prefix}
      #{declarations.join("\n")}
      void two(long, long, long, long, long, long, long, struct a32, struct a64, struct m32, long);
      void mix(int count, ...);
      void fwd(long a, struct a64 x, long tail);

      void sink_a64(long p1, long p2, long p3, long p4, long p5, long p6, long p7, struct a64 x, long tail) {
        printf("sink %ld [", p1 + p2 + p3 + p4 + p5 + p6 + p7);
        print_a64(&x);
        printf("] %ld\\n", tail);
      }

      /* A call made after __builtin_alloca has moved rsp by `n` bytes. */
      static void after_alloca(int n) {
        char *p = __builtin_alloca(n);
        memset(p, 0x5a, n);
        struct a32 x = make_a32(n);
        struct m64 y = make_m64(n + 1);
        fix_a32_7(1L, 2L, 3L, 4L, 5L, 6L, 7L, x, n + p[n - 1]);
        var_m64(8, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, y, 9L, y, (long)n);
      }

      int main(void) {
      #{calls.join("\n")}
      #{mix_calls.join("\n")}
        {
          struct a32 x = make_a32(71); struct a64 y = make_a64(72); struct m32 z = make_m32(73);
          two(1L, 2L, 3L, 4L, 5L, 6L, 7L, x, y, z, 74L);
        }
        {
          void (*fp)(long, long, long, long, long, long, long, struct m32, long) = fix_m32_7;
          void (*vp)(int, ...) = var_a64w;
          struct m32 x = make_m32(81);
          struct a64w w = make_a64w(82);
          fp(1L, 2L, 3L, 4L, 5L, 6L, 7L, x, 83L);
          vp(7, 1L, 2L, 3L, 4L, 5L, 6L, 7L, w, 84L, w, 85L);
        }
        for (int n = 1; n <= 72; n += 13) after_alloca(n);
        { struct a64 x = make_a64(91); fwd(92L, x, 93L); }
        printf("done\\n");
        return 0;
      }
    C
  end
end
