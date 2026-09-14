# frozen_string_literal: true

require_relative "test_helper"

# variadic-aggregate-argument-1: structs and unions passed by value in the
# variable part of a call, and fetched back with va_arg(ap, struct T).
#
# One compiler building both sides would agree with itself whatever it did, so
# every case links a gcc-built translation unit against a rubycc-built one and
# requires the output of gcc building both (the oracle). Both directions run:
# a rubycc caller must place the aggregate where a gcc va_arg looks for it, and
# a rubycc va_arg must find it where a gcc caller put it. Both targets run, the
# aarch64 side through the cross gcc and qemu-aarch64.
#
# The shapes cover each classification either convention can give an
# aggregate: at most 8 bytes, 9 to 16, more than 16, integer-only, all-double,
# all-float (one packed SSE eightbyte on x86-64, an HFA of singles on
# aarch64), mixed integer/floating eightbytes, a four-member HFA larger than 16
# bytes (MEMORY on x86-64 but vector registers on aarch64), 16-byte alignment,
# and unions — `union semun` among them, which semian 0.28.4 passes to semctl.
#
# Each call puts a run of int and double arguments ahead of the aggregate, and
# the prefixes range across both register files' limits on both targets (six
# integer registers on x86-64 and eight on aarch64, eight vector registers on
# each), so the aggregate lands in registers, on the stack, and at the edge
# where it does not fit. An int, a double, a second aggregate and a long follow
# it, which is what shows the state an aggregate leaves behind: System V hands
# a spilled aggregate's registers to a later argument, AAPCS64 declares the
# file exhausted.
class TestVariadicAggregateArgument < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # [name, declaration, statements filling `v` from `s`, printf format, args].
  AGGREGATES = [
    ["s4", "struct s4 { int a; };", "v.a = s * 10 + 1;", "%d", "p->a"],
    ["u4", "union u4 { int i; float f; };", "v.i = s * 10 + 2;", "%d", "p->i"],
    ["s6", "struct s6 { char c[6]; };",
     "for (int k = 0; k < 6; k++) v.c[k] = (char)('a' + s + k);",
     "%c%c%c%c%c%c", "p->c[0], p->c[1], p->c[2], p->c[3], p->c[4], p->c[5]"],
    ["semun", "union semun { int val; void *buf; unsigned short *array; long l; };",
     "v.l = s * 1000003L + 7;", "%ld", "p->l"],
    ["d1", "struct d1 { double d; };", "v.d = s + 0.5;", "%.17g", "p->d"],
    ["f2", "struct f2 { float a, b; };", "v.a = s + 0.25f; v.b = s - 0.75f;", "%.9g %.9g", "p->a, p->b"],
    ["s12", "struct s12 { int a, b, c; };", "v.a = s; v.b = -s * 3; v.c = s * 5 + 1;",
     "%d %d %d", "p->a, p->b, p->c"],
    ["s16", "struct s16 { long a, b; };", "v.a = s * 100000007L; v.b = -s - 1;", "%ld %ld", "p->a, p->b"],
    ["mix", "struct mix { long a; double d; };", "v.a = s * 11; v.d = s / 4.0;", "%ld %.17g", "p->a, p->d"],
    ["dmix", "struct dmix { double d; int i; };", "v.d = s * 1.5; v.i = s + 40;", "%.17g %d", "p->d, p->i"],
    ["d2", "struct d2 { double a, b; };", "v.a = s + 0.125; v.b = s * -2.5;", "%.17g %.17g", "p->a, p->b"],
    ["f3", "struct f3 { float a, b, c; };", "v.a = s; v.b = s + 0.5f; v.c = -s;",
     "%.9g %.9g %.9g", "p->a, p->b, p->c"],
    ["f4", "struct f4 { float a, b, c, d; };", "v.a = s; v.b = s * 2; v.c = s * 3; v.d = s * 4 + 0.5f;",
     "%.9g %.9g %.9g %.9g", "p->a, p->b, p->c, p->d"],
    ["s20", "struct s20 { int a[5]; };", "for (int k = 0; k < 5; k++) v.a[k] = s * 100 + k;",
     "%d %d %d %d %d", "p->a[0], p->a[1], p->a[2], p->a[3], p->a[4]"],
    ["s24", "struct s24 { long a, b, c; };", "v.a = s; v.b = s << 20; v.c = -s * 9;",
     "%ld %ld %ld", "p->a, p->b, p->c"],
    ["d4", "struct d4 { double a, b, c, d; };", "v.a = s; v.b = s + 0.5; v.c = s * 0.25; v.d = -s;",
     "%.17g %.17g %.17g %.17g", "p->a, p->b, p->c, p->d"],
    # 16-byte alignment through a member, which AAPCS64 counts (an even
    # register pair). A type-level __attribute__((aligned(16))) is not used
    # here: aarch64 gcc 13.3 gives it no even pair, fixed or variadic, while
    # rubycc's shared aggregate plan does (measured 2026-09-14) — a named-
    # argument disagreement this step does not change.
    ["a16", "struct a16 { _Alignas(16) long a; long b; };", "v.a = s * 3; v.b = s * 7 + 1;",
     "%ld %ld", "p->a, p->b"],
  ].freeze

  # [int count, double count] ahead of the aggregate. The two named
  # parameters take two integer registers first.
  PREFIXES = [
    [0, 0], [3, 0], [4, 0], [5, 0], [6, 0], [7, 0], [9, 0],
    [0, 6], [0, 7], [0, 8], [0, 9], [3, 3], [5, 7], [6, 8],
  ].freeze

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

    oracle = run_units(target, [[callee_source, :gcc], [caller_source, :gcc]])
    mixed = run_units(target, [[callee_source, callee], [caller_source, caller]])
    assert_equal 0, oracle[0], "#{target}: the gcc oracle itself failed"
    assert_equal AGGREGATES.size * PREFIXES.size, oracle[1].lines.size, "#{target}: oracle output is incomplete"
    assert_equal oracle, mixed, "#{target}: caller #{caller} / callee #{callee} differs from gcc/gcc"
  end

  def run_units(target, units)
    target == :x86_64 ? link_units_and_run(units) : link_units_and_run_aarch64(units)
  end

  def type_name(decl)
    decl[/\A(struct|union) \w+/]
  end

  def common_prefix
    helpers = AGGREGATES.map do |name, decl, fill, format, args|
      type = type_name(decl)
      <<~C
        #{decl}
        static #{type} make_#{name}(int s) { #{type} v; #{fill} return v; }
        static void print_#{name}(const #{type} *p) { printf("#{format}", #{args}); }
      C
    end
    "#include <stdarg.h>\n#include <stdio.h>\n\n#{helpers.join("\n")}"
  end

  # One variadic reader per aggregate: the int and double prefix, the
  # aggregate, a trailing int and double, a second aggregate and a long.
  def callee_source
    readers = AGGREGATES.map do |name, decl, *|
      type = type_name(decl)
      <<~C
        void take_#{name}(int nint, int ndbl, ...) {
          va_list ap;
          va_start(ap, ndbl);
          long isum = 0;
          double dsum = 0.0;
          for (int i = 0; i < nint; i++) isum = isum * 31 + va_arg(ap, int);
          for (int i = 0; i < ndbl; i++) dsum = dsum * 3.0 + va_arg(ap, double);
          #{type} x = va_arg(ap, #{type});
          int after_i = va_arg(ap, int);
          double after_d = va_arg(ap, double);
          #{type} y = va_arg(ap, #{type});
          long tail = va_arg(ap, long);
          va_end(ap);
          printf("#{name} %d %d %ld %.17g [", nint, ndbl, isum, dsum);
          print_#{name}(&x);
          printf("] %d %.17g [", after_i, after_d);
          print_#{name}(&y);
          printf("] %ld\\n", tail);
        }
      C
    end
    "#{common_prefix}\n#{readers.join("\n")}"
  end

  def caller_source
    declarations = AGGREGATES.map { |name, *| "void take_#{name}(int nint, int ndbl, ...);" }
    calls = AGGREGATES.each_with_index.flat_map do |(name, decl, *), index|
      type = type_name(decl)
      PREFIXES.each_with_index.map do |(nint, ndbl), row|
        seed = index * 16 + row + 1
        ints = Array.new(nint) { |i| (i * 7) + seed }
        doubles = Array.new(ndbl) { |i| format("%.3f", i + (seed / 8.0)) }
        args = [nint, ndbl, *ints, *doubles, "x", seed + 1000, "#{seed}.5",
                "make_#{name}(#{seed + 1})", "#{seed * 1_000_003}L"]
        "  { #{type} x = make_#{name}(#{seed}); take_#{name}(#{args.join(", ")}); }"
      end
    end
    <<~C
      #{common_prefix}
      #{declarations.join("\n")}

      int main(void) {
      #{calls.join("\n")}
        return 0;
      }
    C
  end
end
