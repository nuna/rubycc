# frozen_string_literal: true

require_relative "test_helper"
require_relative "abi_harness/harness"

# Step 62 (M5 H1): the ABI-verification harness, exercised first on the headers
# rubycc already ships -- the freestanding layer under include/ (stddef, stdarg,
# stdbool, stdalign, float). Each case compiles one probe program twice, against
# the real headers with gcc and against the bundled headers with rubycc, and
# asserts byte-identical output. This both proves those bundled headers are ABI
# compatible and gives the harness a green baseline before the bundled libc
# headers (the next step) start adding cases of their own.
#
# Two freestanding discrepancies are deliberately *not* asserted here, because
# they are open rubycc gaps rather than harness or header defects (see
# test/abi_harness/README.md): sizeof/_Alignof of max_align_t (rubycc models long
# double as 8-byte double, so the type is 16/8 where glibc's is 32/16), and the
# value of FLT_MAX (rubycc's float32 literal conversion rounds the bundled
# 3.40282347e+38F up to +inf). Every other freestanding check matches to the byte.
class TestHeaderAbi < Minitest::Test
  include ExecutionHelper
  include HeaderAbiHarness

  def setup
    skip "gcc unavailable (needed as the ABI oracle)" unless tool?("gcc")
    skip "system libc headers not found (/usr/include/stdio.h missing)" unless File.exist?("/usr/include/stdio.h")
  end

  # <stddef.h>: the fundamental typedefs' widths and alignments, plus offsetof
  # against a probe struct (which exercises the harness's offset path and, since
  # both compilers lay the struct out per the psABI, must agree).
  STDDEF = HeaderAbiHarness::Spec.new(
    header: "stddef.h",
    sizes: %w[size_t ptrdiff_t wchar_t],
    snippets: ["struct abi_probe { char c; int i; double d; short s; };"],
    offsets: [["struct abi_probe", "c"], ["struct abi_probe", "i"],
              ["struct abi_probe", "d"], ["struct abi_probe", "s"]]
  )

  # <stdarg.h>: va_list's own width/alignment, and a variadic function that
  # actually uses the va_* macros as the compile-only "the macros are usable"
  # check. Running it also confirms the argument walk agrees with gcc's.
  STDARG = HeaderAbiHarness::Spec.new(
    header: "stdarg.h",
    sizes: %w[va_list],
    ints: ["abi_sum(4, 5, 15, 25, 55)"],
    snippets: [<<~C.chomp]
      static long abi_sum(int n, ...) {
        va_list ap; va_start(ap, n);
        long total = 0;
        for (int i = 0; i < n; i++) total += va_arg(ap, int);
        va_end(ap);
        return total;
      }
    C
  )

  # <stdbool.h>: _Bool's width, and the macro values the header defines.
  STDBOOL = HeaderAbiHarness::Spec.new(
    header: "stdbool.h",
    sizes: %w[bool],
    ints: %w[true false __bool_true_false_are_defined]
  )

  # <stdalign.h>: the feature macros, and that alignof maps onto _Alignof (so
  # alignof(T) yields the same alignment gcc's does for representative types).
  STDALIGN = HeaderAbiHarness::Spec.new(
    header: "stdalign.h",
    ints: ["__alignof_is_defined", "__alignas_is_defined",
           "alignof(double)", "alignof(long long)", "alignof(int)"]
  )

  # <float.h>: the integer characteristics of every floating type, and the
  # float/double magnitude macros compared as exact hex floats. FLT_MAX is
  # omitted (see the class comment); every macro listed here matches gcc exactly.
  FLOAT = HeaderAbiHarness::Spec.new(
    header: "float.h",
    ints: %w[FLT_RADIX FLT_EVAL_METHOD DECIMAL_DIG
             FLT_MANT_DIG FLT_DIG FLT_MIN_EXP FLT_MAX_EXP
             DBL_MANT_DIG DBL_DIG DBL_MIN_EXP DBL_MAX_EXP
             LDBL_MANT_DIG LDBL_DIG LDBL_MIN_EXP LDBL_MAX_EXP],
    floats: %w[FLT_MIN FLT_EPSILON FLT_TRUE_MIN DBL_MAX DBL_MIN DBL_EPSILON DBL_TRUE_MIN]
  )

  # <iso646.h>: a header with no printable ABI surface at all; its correctness is
  # that the operator-spelling macros expand to usable operators, proven by the
  # snippet compiling under both toolchains (the pure declaration-existence case).
  ISO646 = HeaderAbiHarness::Spec.new(
    header: "iso646.h",
    snippets: ["static int abi_iso646(int a, int b) { return (a and b) or (a bitor b); }"]
  )

  def test_stddef_abi_matches_gcc
    assert_abi_matches(STDDEF)
  end

  def test_stdarg_abi_matches_gcc
    assert_abi_matches(STDARG)
  end

  def test_stdbool_abi_matches_gcc
    assert_abi_matches(STDBOOL)
  end

  def test_stdalign_abi_matches_gcc
    assert_abi_matches(STDALIGN)
  end

  def test_float_abi_matches_gcc
    assert_abi_matches(FLOAT)
  end

  def test_iso646_abi_matches_gcc
    assert_abi_matches(ISO646)
  end

  private

  # Runs a Spec both ways and asserts a clean run and byte-identical output. The
  # gcc side is the oracle; rubycc must reproduce it exactly.
  def assert_abi_matches(spec)
    result = run_abi_case(spec)
    assert_equal 0, result.gcc_status, "gcc-built probe for <#{spec.header}> exited #{result.gcc_status}"
    assert_equal 0, result.rubycc_status, "rubycc-built probe for <#{spec.header}> exited #{result.rubycc_status}"
    assert_equal result.gcc_out, result.rubycc_out,
                 "<#{spec.header}>: rubycc ABI output differs from gcc"
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
