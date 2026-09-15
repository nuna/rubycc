# frozen_string_literal: true

require_relative "test_helper"

# sysv-padding-eightbyte-class-1: a System V eightbyte that holds nothing but
# padding takes no register.
#
# psABI 3.2.3 classes an eightbyte no field falls in as NO_CLASS, and gcc 13.3
# gives such an eightbyte no register at all (measured 2026-09-15): the
# 16-byte `struct { float a, b; } __attribute__((aligned(16)))` travels in one
# xmm register, `struct { int a; } __attribute__((aligned(16)))` in one integer
# register, and a variadic call passing two of the first sets %al = 2. rubycc
# used to class the padding eightbyte SSE, so every such aggregate took one
# xmm register too many: a following double landed one register late, a
# variadic call's %al was two too high, and va_arg stepped over two xmm save
# slots per aggregate.
#
# One compiler building both sides agrees with itself whatever it does, so
# each case links a gcc-built translation unit against a rubycc-built one and
# requires the output of gcc building both (the oracle), in both directions.
# The aggregate is passed as a fixed and as a variadic argument behind runs of
# long and double arguments that walk it across both register files' limits,
# with a double, a long, a second aggregate and a float after it (what shows
# how many registers it consumed), and comes back as a return value.
#
# On x86-64 a third unit, always built by gcc, holds an assembly trampoline
# per variadic callee that records %al before jumping on, and the callee
# prints it, so the caller's vector-register count is compared as well.
# aarch64 runs the same shapes without the trampoline (AAPCS64 has no %al and
# classifies none of these by eightbytes), to pin that it is unchanged.
class TestSysvPaddingEightbyteClass < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # [name, declaration, type, fill (writes `v` from `s`), printf format, args].
  # Only members are printed: padding is not preserved by a by-value pass.
  SHAPES = [
    # The upper eightbyte is padding only: SSE + NO_CLASS, INTEGER + NO_CLASS.
    ["fa", "struct fa { float a, b; } __attribute__((aligned(16)));", "struct fa",
     "v.a = s + 0.25f; v.b = s - 0.75f;", "%.9g %.9g", "p->a, p->b"],
    ["f1", "struct f1 { float a; } __attribute__((aligned(16)));", "struct f1",
     "v.a = s * 1.5f;", "%.9g", "p->a"],
    ["da", "struct da { double d; } __attribute__((aligned(16)));", "struct da",
     "v.d = s / 8.0;", "%.17g", "p->d"],
    ["ia", "struct ia { int a; } __attribute__((aligned(16)));", "struct ia",
     "v.a = s * 7 + 3;", "%d", "p->a"],
    ["la", "typedef struct { long a; } __attribute__((aligned(16))) la;", "la",
     "v.a = s * 1000003L;", "%ld", "p->a"],
    ["uf", "union uf { float f; int i; } __attribute__((aligned(16)));", "union uf",
     "v.i = s * 11 + 1;", "%d", "p->i"],
    ["ufd", "union ufd { float f; double d; } __attribute__((aligned(16)));", "union ufd",
     "v.d = s + 0.125;", "%.17g", "p->d"],
    ["nest", "struct nest { struct { float a, b; } __attribute__((aligned(16))) in; };", "struct nest",
     "v.in.a = s * 2.0f; v.in.b = -s;", "%.9g %.9g", "p->in.a, p->in.b"],
    ["mixfa", "struct mixfa { int i; float f; } __attribute__((aligned(16)));", "struct mixfa",
     "v.i = s - 5; v.f = s * 0.5f;", "%d %.9g", "p->i, p->f"],
    # Controls: the upper eightbyte is a member (an array of char counts), so
    # it keeps its class.
    ["tp", "struct tp { float a, b; char pad[8]; };", "struct tp",
     "v.a = s + 0.5f; v.b = s * 3.0f; for (int k = 0; k < 8; k++) v.pad[k] = (char)(s + k);",
     "%.9g %.9g %d %d", "p->a, p->b, p->pad[0], p->pad[7]"],
    ["fa3", "struct fa3 { float a, b, c; } __attribute__((aligned(16)));", "struct fa3",
     "v.a = s; v.b = s + 0.5f; v.c = -s;", "%.9g %.9g %.9g", "p->a, p->b, p->c"],
  ].freeze

  # [long count, double count] ahead of the aggregate: nothing, the edge of
  # the xmm file (the aggregate in xmm7 with 7, spilled with 8), the edge of
  # the integer file, and both at once.
  PREFIXES = [[0, 0], [0, 5], [0, 6], [0, 7], [0, 8], [4, 0], [5, 0], [6, 0], [5, 7]].freeze

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

    x86 = target == :x86_64
    units = lambda do |callee_cc, caller_cc|
      list = [[callee_source(x86), callee_cc], [caller_source(x86), caller_cc]]
      list << [trampoline_source, :gcc] if x86
      list
    end
    oracle = run_units(target, units.call(:gcc, :gcc))
    mixed = run_units(target, units.call(callee, caller))
    assert_equal 0, oracle[0], "#{target}: the gcc oracle itself failed"
    # Per shape: one fixed and one variadic line per prefix, plus one return.
    assert_equal SHAPES.size * (2 * PREFIXES.size + 1), oracle[1].lines.size,
                 "#{target}: oracle output is incomplete"
    assert_equal oracle, mixed, "#{target}: caller #{caller} / callee #{callee} differs from gcc/gcc"
  end

  def run_units(target, units)
    target == :x86_64 ? link_units_and_run(units) : link_units_and_run_aarch64(units)
  end

  def common_prefix
    helpers = SHAPES.map do |name, decl, type, fill, format, args|
      <<~C
        #{decl}
        static #{type} make_#{name}(int s) { #{type} v; memset(&v, 0, sizeof v); #{fill} return v; }
        static void print_#{name}(const #{type} *p) { printf("#{format}", #{args}); }
      C
    end
    "#include <stdarg.h>\n#include <stdio.h>\n#include <string.h>\n\n#{helpers.join("\n")}"
  end

  def prefix_params(nlong, ndbl)
    [*(1..nlong).map { |i| "long p#{i}" }, *(1..ndbl).map { |i| "double q#{i}" }]
  end

  def prefix_sums(nlong, ndbl)
    lsum = nlong.zero? ? "0L" : (1..nlong).map { |i| "p#{i}" }.join(" + ")
    dsum = ndbl.zero? ? "0.0" : (1..ndbl).map { |i| "q#{i}" }.join(" + ")
    [lsum, dsum]
  end

  # Per shape: one fixed-argument function per prefix, one variadic reader
  # (entered through the %al trampoline on x86-64) and one returning the
  # aggregate. The arguments after the aggregate are what show how many
  # registers it took.
  def callee_source(x86)
    bodies = SHAPES.flat_map do |name, _decl, type, *|
      fixed = PREFIXES.map do |nlong, ndbl|
        params = [*prefix_params(nlong, ndbl), "#{type} x", "double d", "long l", "#{type} y", "float f"]
        lsum, dsum = prefix_sums(nlong, ndbl)
        <<~C
          void fix_#{name}_#{nlong}_#{ndbl}(#{params.join(", ")}) {
            printf("fix #{name} #{nlong} #{ndbl} %ld %.17g [", #{lsum}, #{dsum});
            print_#{name}(&x);
            printf("] %.17g %ld [", d, l);
            print_#{name}(&y);
            printf("] %.9g\\n", f);
          }
        C
      end
      al = x86 ? "(int)seen_al" : "-1"
      variadic = <<~C
        void var_#{name}(int nlong, int ndbl, ...) {
          int al = #{al};
          va_list ap;
          va_start(ap, ndbl);
          long lsum = 0;
          double dsum = 0.0;
          for (int i = 0; i < nlong; i++) lsum = lsum * 31 + va_arg(ap, long);
          for (int i = 0; i < ndbl; i++) dsum = dsum * 3.0 + va_arg(ap, double);
          #{type} x = va_arg(ap, #{type});
          double d = va_arg(ap, double);
          long l = va_arg(ap, long);
          #{type} y = va_arg(ap, #{type});
          double e = va_arg(ap, double);
          va_end(ap);
          printf("var #{name} %d %d al=%d %ld %.17g [", nlong, ndbl, al, lsum, dsum);
          print_#{name}(&x);
          printf("] %.17g %ld [", d, l);
          print_#{name}(&y);
          printf("] %.17g\\n", e);
        }
      C
      echo = <<~C
        #{type} echo_#{name}(double a, #{type} x, long b) {
          #{type} r = x;
          printf("echo #{name} %.17g %ld [", a, b);
          print_#{name}(&r);
          printf("] ");
          return r;
        }
      C
      [*fixed, variadic, echo]
    end
    extern = x86 ? "extern unsigned char seen_al;\n" : ""
    "#{common_prefix}\n#{extern}\n#{bodies.join("\n")}"
  end

  # Every variadic call goes to var_<name>_al, which on x86-64 is the gcc
  # trampoline and on aarch64 simply var_<name> under a second name.
  def caller_source(x86)
    declarations = SHAPES.flat_map do |name, _decl, type, *|
      fixed = PREFIXES.map do |nlong, ndbl|
        params = [*prefix_params(nlong, ndbl), type, "double", "long", type, "float"]
        "void fix_#{name}_#{nlong}_#{ndbl}(#{params.join(", ")});"
      end
      variadic = x86 ? "void var_#{name}_al(int nlong, int ndbl, ...);" : "void var_#{name}(int nlong, int ndbl, ...);"
      [*fixed, variadic, "#{type} echo_#{name}(double a, #{type} x, long b);"]
    end
    calls = SHAPES.each_with_index.flat_map do |(name, _decl, type, *), index|
      lines = PREFIXES.each_with_index.flat_map do |(nlong, ndbl), row|
        seed = (index * 16) + row + 1
        longs = Array.new(nlong) { |i| "#{(i * 7) + seed}L" }
        doubles = Array.new(ndbl) { |i| format("%.3f", i + (seed / 8.0)) }
        variadic = x86 ? "var_#{name}_al" : "var_#{name}"
        [
          "  { #{type} x = make_#{name}(#{seed}); #{type} y = make_#{name}(#{seed + 500}); " \
          "fix_#{name}_#{nlong}_#{ndbl}(#{[*longs, *doubles, "x", "#{seed}.5", "#{seed * 1_000_003}L", "y",
                                            "#{seed}.25f"].join(", ")}); }",
          "  { #{type} x = make_#{name}(#{seed}); #{type} y = make_#{name}(#{seed + 500}); " \
          "#{variadic}(#{[nlong, ndbl, *longs, *doubles, "x", "#{seed}.75", "#{seed * 7_000_001}L", "y",
                          "#{seed}.125"].join(", ")}); }",
        ]
      end
      lines << "  { #{type} x = make_#{name}(#{index + 900}); #{type} r = echo_#{name}(#{index}.5, x, 9L); " \
               "printf(\"ret #{name} [\"); print_#{name}(&r); printf(\"]\\n\"); }"
      lines
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

  # One trampoline per variadic callee: store %al (the caller's count of
  # vector registers used) in seen_al, then tail-jump to the real function
  # with every argument register untouched.
  def trampoline_source
    stubs = SHAPES.map do |name, *|
      "__asm__(\".text\\n.globl var_#{name}_al\\nvar_#{name}_al:\\n" \
        "  movb %al, seen_al(%rip)\\n  jmp var_#{name}\\n\");"
    end
    "unsigned char seen_al;\n#{stubs.join("\n")}\n"
  end
end
