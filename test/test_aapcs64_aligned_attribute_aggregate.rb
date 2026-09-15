# frozen_string_literal: true

require_relative "test_helper"

# aapcs64-aligned-attribute-aggregate-1: which alignment decides where a
# 16-byte-aligned aggregate goes on AArch64.
#
# AAPCS64 rounds NGRN up to an even register, and a spilled argument's stack
# offset up to 16, for an argument whose *natural* alignment is 16. For a
# composite that is its members' alignment: gcc 13.3 pair-rounds a struct made
# 16-aligned by an __int128, an _Alignas(16) or an aligned(16) member, but not
# `struct { long a, b; } __attribute__((aligned(16)))`, whose 16 comes from the
# aggregate's own attribute (measured 2026-09-14). rubycc used to count the
# attribute and put that struct one register (or one stack eightbyte) late.
#
# One compiler building both sides agrees with itself whatever it does, so each
# case links a gcc-built translation unit against a rubycc-built one and
# requires the output of gcc building both (the oracle), in both directions:
# a rubycc caller must place the aggregate where a gcc callee reads it, and a
# rubycc callee (a named parameter, a va_arg) must read it where a gcc caller
# put it. Each shape runs with 0 to 9 long arguments ahead of it — odd and even
# NGRN, the last register pair, and odd and even stack offsets once x0..x7 are
# spent — as a fixed argument and as a variadic one, and comes back as a
# return value.
#
# x86-64 runs the same cases minus the shape X86_64_EXCLUDED names: System V
# counts the whole alignment, attribute included, and rubycc already agreed
# with gcc there on every 16-aligned shape. The two 32-byte-aligned shapes
# joined it with sysv-over-aligned-aggregate-stack-1, which starts such an
# aggregate on a 32-aligned stack slot as gcc does.
class TestAapcs64AlignedAttributeAggregate < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # [name, declaration, type, fill (writes `v` from `s`), meaningful bytes].
  # Only the meaningful bytes are printed: the padding of an over-aligned
  # struct is not preserved when it is passed by value.
  SHAPES = [
    # 16 from an attribute on the aggregate itself: AAPCS64 does not count it.
    ["attr_c", "struct attr_c { long a, b; } __attribute__((aligned(16)));", "struct attr_c",
     "v.a = s * 3 + 1; v.b = -s;", 16],
    ["attr_b", "struct __attribute__((aligned(16))) attr_b { long a, b; };", "struct attr_b",
     "v.a = s * 5 + 2; v.b = s << 8;", 16],
    ["tdef_c", "typedef struct { long a, b; } __attribute__((aligned(16))) tdef_c;", "tdef_c",
     "v.a = s + 7; v.b = s * 11;", 16],
    ["tdef_name", "struct tdef_name_s { long a, b; };\n" \
                  "typedef struct tdef_name_s tdef_name __attribute__((aligned(16)));", "tdef_name",
     "v.a = s * 13; v.b = s - 3;", 16],
    ["s8_attr", "struct s8_attr { long a; } __attribute__((aligned(16)));", "struct s8_attr",
     "v.a = s * 17 + 5;", 8],
    ["f2_attr", "struct f2_attr { float a, b; } __attribute__((aligned(16)));", "struct f2_attr",
     "v.a = s + 0.25f; v.b = s - 0.75f;", 8],
    ["d2_attr", "struct d2_attr { double a, b; } __attribute__((aligned(16)));", "struct d2_attr",
     "v.a = s + 0.5; v.b = s * -2.5;", 16],
    ["union_attr", "union union_attr { long a; char c[16]; } __attribute__((aligned(16)));", "union union_attr",
     "for (int k = 0; k < 16; k++) v.c[k] = (char)(s + k * 3);", 16],
    ["packed_attr", "struct packed_attr { long a, b; } __attribute__((packed, aligned(16)));",
     "struct packed_attr", "v.a = s * 19; v.b = s + 23;", 16],
    # 16 from a member: AAPCS64 counts it (an even pair, a 16-aligned slot).
    ["alignas_m", "struct alignas_m { _Alignas(16) long a; long b; };", "struct alignas_m",
     "v.a = s * 29; v.b = s + 31;", 16],
    ["int128_m", "struct int128_m { __int128 a; };", "struct int128_m",
     "long w[2] = { s * 37, -s }; memcpy(&v, w, sizeof w);", 16],
    ["nested", "struct nested_in { long a, b; } __attribute__((aligned(16)));\n" \
               "struct nested { struct nested_in i; };", "struct nested",
     "v.i.a = s * 41; v.i.b = s + 43;", 16],
    # 32-byte alignment: larger than 16 bytes, so AAPCS64 passes a copy's address.
    ["attr32", "struct attr32 { long a, b; } __attribute__((aligned(32)));", "struct attr32",
     "v.a = s * 47; v.b = s + 53;", 16],
    ["alignas32", "struct alignas32 { _Alignas(32) long a; long b; };", "struct alignas32",
     "v.a = s * 59; v.b = s + 61;", 16],
  ].freeze

# Both System V gaps that used to keep shapes off the x86-64 half are closed:
# sysv-padding-eightbyte-class-1 gave a padding-only eightbyte no register
# (f2_attr), and sysv-over-aligned-aggregate-stack-1 put a 32-byte-aligned
# MEMORY aggregate on a 32-aligned stack slot (attr32 / alignas32), both as
# gcc 13.3 does. Every shape now runs on both halves.
X86_64_EXCLUDED = [].freeze

  # Long arguments ahead of the aggregate. On aarch64, 0..6 leave room for a
  # pair (odd and even NGRN), 7 cannot fit one, and 8 and 9 put it on the
  # stack at an even and an odd offset; x86-64's six registers are crossed on
  # the way.
  PREFIXES = (0..9).to_a.freeze

  def test_rubycc_caller_gcc_callee_aarch64
    assert_mixed_matches_oracle(:aarch64, caller: :rubycc)
  end

  def test_gcc_caller_rubycc_callee_aarch64
    assert_mixed_matches_oracle(:aarch64, callee: :rubycc)
  end

  def test_rubycc_caller_gcc_callee_x86_64
    assert_mixed_matches_oracle(:x86_64, caller: :rubycc)
  end

  def test_gcc_caller_rubycc_callee_x86_64
    assert_mixed_matches_oracle(:x86_64, callee: :rubycc)
  end

  private

  def assert_mixed_matches_oracle(target, caller: :gcc, callee: :gcc)
    skip_unless_x86_64_host if target == :x86_64
    skip_unless_aarch64_toolchain if target == :aarch64

    shapes = shapes_for(target)
    units = ->(callee_cc, caller_cc) { [[callee_source(shapes), callee_cc], [caller_source(shapes), caller_cc]] }
    oracle = run_units(target, units.call(:gcc, :gcc))
    mixed = run_units(target, units.call(callee, caller))
    assert_equal 0, oracle[0], "#{target}: the gcc oracle itself failed"
    # Per shape: one fixed and one variadic line per prefix, plus one return.
    assert_equal shapes.size * (2 * PREFIXES.size + 1), oracle[1].lines.size,
                 "#{target}: oracle output is incomplete"
    assert_equal oracle, mixed, "#{target}: caller #{caller} / callee #{callee} differs from gcc/gcc"
  end

  def shapes_for(target)
    target == :x86_64 ? SHAPES.reject { |name, *| X86_64_EXCLUDED.include?(name) } : SHAPES
  end

  def run_units(target, units)
    target == :x86_64 ? link_units_and_run(units) : link_units_and_run_aarch64(units)
  end

  # Shape definitions, a maker and a printer shared by both units. The
  # printer reads the meaningful bytes back as longs so every shape, float or
  # not, prints its exact bit pattern.
  def common_prefix(shapes)
    helpers = shapes.map do |name, decl, type, fill, bytes|
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
    "#include <stdarg.h>\n#include <stdio.h>\n#include <string.h>\n\n#{helpers.join("\n")}"
  end

  def prefix_params(count)
    (1..count).map { |i| "long p#{i}" }
  end

  # Per shape: one fixed-argument function per prefix length, one variadic
  # reader, and one function returning the aggregate.
  def callee_source(shapes)
    bodies = shapes.flat_map do |name, _decl, type, *|
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
    "#{common_prefix(shapes)}\n#{bodies.join("\n")}"
  end

  def caller_source(shapes)
    declarations = shapes.flat_map do |name, _decl, type, *|
      fixed = PREFIXES.map do |count|
        "void fix_#{name}_#{count}(#{[*prefix_params(count), type, "long"].join(", ")});"
      end
      [*fixed, "void var_#{name}(int count, ...);", "#{type} echo_#{name}(long a, #{type} x, long b);"]
    end
    calls = shapes.each_with_index.flat_map do |(name, _decl, type, *), index|
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
    <<~C
      #{common_prefix(shapes)}
      #{declarations.join("\n")}

      int main(void) {
      #{calls.join("\n")}
        return 0;
      }
    C
  end
end
