# frozen_string_literal: true

require_relative "test_helper"

# sysv-unnamed-bitfield-class-1: an unnamed bit-field occupies storage, and
# both ABIs' argument classification has to count it.
#
# An unnamed bit-field declares no member, so rubycc's layout recorded nothing
# for it and the classification saw an eightbyte with no field in it. gcc 13.3
# counts the bits: `struct { float f; int : 8; }` rides rdi, not xmm0, and
# `union { double d; int : 8; }` rides x0, not d0 (measured 2026-09-16). A
# *zero-width* bit-field occupies nothing and changes neither answer, which is
# the line this test draws — it stays SSE on x86-64 and an HFA on aarch64.
#
# The member-less shapes (`struct { int : 8; }` and kin) carry the second rule
# the same measurement turned up: gcc gives an aggregate no program can name a
# field of no room at all in the x86-64 stack argument area, while still handing
# it a register when one is free. aarch64 gcc treats it as any other aggregate.
#
# One compiler building both sides agrees with itself whatever it does, so each
# case links a gcc-built translation unit against a rubycc-built one and
# requires the output of gcc building both (the oracle), in both directions.
# Each shape travels as a fixed and as a variadic argument behind runs of long
# and double arguments that walk it across both register files' limits, with a
# double, a long, a second aggregate and a float after it (what shows how many
# registers and stack slots it consumed), and comes back as a return value.
#
# On x86-64 a third unit, always built by gcc, holds an assembly trampoline per
# variadic callee that records %al before jumping on, and the callee prints it,
# so the caller's vector-register count is compared as well.
class TestSysvUnnamedBitfieldClass < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # [name, declaration, type, fill (writes `v` from `s`), printf format, args].
  # Only members are printed: a by-value pass preserves nothing else, and the
  # member-less shapes print nothing at all — for those the arguments around
  # them are the whole measurement.
  SHAPES = [
    # The unnamed bit-field shares the float's eightbyte: SSE + INTEGER is
    # INTEGER, so the aggregate rides an integer register on x86-64.
    ["fu", "struct fu { float f; int : 8; };", "struct fu",
     "v.f = s + 0.25f;", "%.9g", "p->f"],
    # Bit-field first, then the float.
    ["uf", "struct uf { int : 8; float f; };", "struct uf",
     "v.f = s * 1.5f;", "%.9g", "p->f"],
    # The bit-field is the whole second eightbyte (INTEGER), the floats the
    # first (SSE).
    ["ffu", "struct ffu { float a, b; int : 8; };", "struct ffu",
     "v.a = s; v.b = -s;", "%.9g %.9g", "p->a, p->b"],
    # Three floats and a bit-field: the second eightbyte is SSE + INTEGER.
    ["f3u", "struct f3u { float a, b, c; int : 8; };", "struct f3u",
     "v.a = s; v.b = s + 0.5f; v.c = -s;", "%.9g %.9g %.9g", "p->a, p->b, p->c"],
    # A double keeps the first eightbyte SSE and the bit-field takes the second.
    ["du", "struct du { double d; int : 8; };", "struct du",
     "v.d = s / 8.0;", "%.17g", "p->d"],
    # The reverse order: INTEGER then SSE.
    ["ud", "struct ud { int : 8; double d; };", "struct ud",
     "v.d = s - 0.25;", "%.17g", "p->d"],
    # A named bit-field next to an unnamed one.
    ["nu", "struct nu { int a : 4; int : 8; float f; };", "struct nu",
     "v.a = s & 7; v.f = s * 2.0f;", "%d %.9g", "p->a, p->f"],
    # A union: the bit-field overlays the float/double member at offset 0 and
    # makes the eightbyte INTEGER — and disqualifies the AAPCS64 HFA the lone
    # member would otherwise form.
    ["ud8", "union ud8 { double d; int : 8; };", "union ud8",
     "v.d = s * 3.0;", "%.17g", "p->d"],
    ["uf4", "union uf4 { float f; int : 8; };", "union uf4",
     "v.f = s * 0.5f;", "%.9g", "p->f"],
    # No member at all: nothing to print, everything to place.
    ["only", "struct only { int : 8; };", "struct only", "(void)s;", "", nil],
    ["only8", "struct only8 { int : 8; } __attribute__((aligned(8)));", "struct only8",
     "(void)s;", "", nil],
    # 16 bytes of which only the first eightbyte holds the bit-field: one
    # register, the upper eightbyte NO_CLASS as the padding rule says.
    ["only16", "struct only16 { int : 8; } __attribute__((aligned(16)));", "struct only16",
     "(void)s;", "", nil],
    # Member-less through a member of its own.
    ["nest", "struct nest { struct { int : 8; } in; };", "struct nest", "(void)s;", "", nil],
    # Member-less and past both conventions' register limit: MEMORY class on
    # x86-64 (but with no room in the stack area either) and by reference on
    # aarch64.
    ["only32", "struct only32 { int : 8; } __attribute__((aligned(32)));", "struct only32",
     "(void)s;", "", nil],
    # Controls: a *zero-width* bit-field occupies nothing, so these stay SSE on
    # x86-64 and homogeneous floating aggregates on aarch64.
    ["z1", "struct z1 { float f; int : 0; };", "struct z1",
     "v.f = s * 0.25f;", "%.9g", "p->f"],
    ["z2", "struct z2 { float a; int : 0; float b; };", "struct z2",
     "v.a = s; v.b = s + 1.5f;", "%.9g %.9g", "p->a, p->b"],
  ].freeze

  # [long count, double count] ahead of the aggregate: nothing, the edge of the
  # xmm file, past it, the edge of the integer file, past it, and both at once.
  PREFIXES = [[0, 0], [0, 7], [0, 8], [4, 0], [6, 0], [5, 7]].freeze

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
      body = args ? %(printf("#{format}", #{args});) : "(void)p;"
      <<~C
        #{decl}
        static #{type} make_#{name}(int s) { #{type} v; memset(&v, 0, sizeof v); #{fill} return v; }
        static void print_#{name}(const #{type} *p) { #{body} }
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
  # registers and stack slots it took.
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

  # One trampoline per variadic callee: store %al (the caller's count of vector
  # registers used) in seen_al, then tail-jump to the real function with every
  # argument register untouched.
  def trampoline_source
    stubs = SHAPES.map do |name, *|
      "__asm__(\".text\\n.globl var_#{name}_al\\nvar_#{name}_al:\\n" \
        "  movb %al, seen_al(%rip)\\n  jmp var_#{name}\\n\");"
    end
    "unsigned char seen_al;\n#{stubs.join("\n")}\n"
  end
end
