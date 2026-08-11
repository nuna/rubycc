# frozen_string_literal: true

require_relative "test_helper"

# Step 52 (M2 addendum): the run-time conversion between a 64-bit *unsigned*
# integer (`unsigned long` / `unsigned long long`) and a floating type, which
# Step 51 left as a compile-time-only fold. cvtsi2s*/cvttss2si are signed-only,
# so the generator synthesizes both directions branchwise from the signed
# primitives: `unsigned long` -> float/double halves-and-doubles a value whose
# top bit is set (keeping a sticky low bit for correct rounding), and
# float/double -> `unsigned long` subtracts 2^63 before a signed truncation and
# restores the top bit. The results are cross-checked bit-for-bit against gcc
# (via %a as well as %g/%lu). This is what unblocks json's vendor/jeaiii-ltoa.h
# "u32((10 * (1 << 24) / 1e3 + 1) * n)" run-time conversion.
class TestUnsignedLongFloatConversion < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to cross-check)" unless tool?("gcc")
  end

  def test_unsigned_long_to_double
    src = <<~C
      #include <stdio.h>
      int main(void) {
        unsigned long xs[] = {
          0UL, 1UL, (1UL << 62), (1UL << 63), (1UL << 63) + 1,
          0xFFFFFFFFFFFFFFFFUL, 0x8000000000000401UL, 12345678901234567UL
        };
        for (int i = 0; i < 8; i++) {
          double d = (double)xs[i];
          printf("%a %g\\n", d, d);
        }
        return 0;
      }
    C
    assert_same_stdout_as_gcc(src)
  end

  def test_unsigned_long_to_float
    src = <<~C
      #include <stdio.h>
      int main(void) {
        unsigned long xs[] = {
          0UL, 1UL, (1UL << 62), (1UL << 63), (1UL << 63) + 1,
          0xFFFFFFFFFFFFFFFFUL, 0x8000000000000401UL, 12345678901234567UL
        };
        for (int i = 0; i < 8; i++) {
          float f = (float)xs[i];
          printf("%a %g\\n", (double)f, (double)f);
        }
        return 0;
      }
    C
    assert_same_stdout_as_gcc(src)
  end

  def test_double_to_unsigned_long
    src = <<~C
      #include <stdio.h>
      int main(void) {
        double ds[] = {
          0.0, 1.9, 4.611686018427388e18, 9223372036854775808.0,
          9223372036854776832.0, 1.5e19, 1.8446744073709548e19
        };
        for (int i = 0; i < 7; i++) {
          unsigned long u = (unsigned long)ds[i];
          printf("%lu\\n", u);
        }
        return 0;
      }
    C
    assert_same_stdout_as_gcc(src)
  end

  def test_float_to_unsigned_long
    src = <<~C
      #include <stdio.h>
      int main(void) {
        float fs[] = {0.0f, 1.9f, 4.611686e18f, 9223372036854775808.0f, 1.5e19f};
        for (int i = 0; i < 5; i++) {
          unsigned long u = (unsigned long)fs[i];
          printf("%lu\\n", u);
        }
        return 0;
      }
    C
    assert_same_stdout_as_gcc(src)
  end

  def test_round_trips_within_domain
    src = <<~C
      #include <stdio.h>
      int main(void) {
        unsigned long xs[] = {0UL, 1UL, (1UL << 63), 12345678901234567UL};
        for (int i = 0; i < 4; i++) {
          printf("%lu %lu\\n", (unsigned long)(double)xs[i], (unsigned long)(float)xs[i]);
        }
        return 0;
      }
    C
    assert_same_stdout_as_gcc(src)
  end

  def test_jeaiii_mixed_expression
    src = <<~C
      #include <stdio.h>
      typedef unsigned long u32_t;
      int main(void) {
        unsigned long ns[] = {0, 1, 7, 123, 999, 1000000, 4294967295UL};
        for (int i = 0; i < 7; i++) {
          unsigned long n = ns[i];
          u32_t f0 = (u32_t)((10 * (1 << 24) / 1e3 + 1) * n);
          printf("%lu\\n", f0);
        }
        return 0;
      }
    C
    assert_same_stdout_as_gcc(src)
  end

  # The 32-bit unsigned side was already meant to work; confirm it still does,
  # including the (INT_MAX, UINT_MAX] range. x86 uses its 64-bit signed
  # conversion for that range, while AArch64 uses the native unsigned W-form.
  def test_unsigned_int_and_float_still_work
    src = <<~C
      #include <stdio.h>
      int main(void) {
        // Keep every float round-trip inside UINT_MAX. 4294967295.0f rounds
        // to 2^32, which is outside the destination type and therefore would
        // make the comparison depend on undefined C behavior.
        unsigned int us[] = {0u, 1u, 2147483648u, 4000000000u, 4294967040u};
        for (int i = 0; i < 5; i++) {
          double d = (double)us[i];
          float f = (float)us[i];
          printf("%g %g %u %u\\n", d, (double)f, (unsigned int)d, (unsigned int)f);
        }
        return 0;
      }
    C
    assert_same_stdout_as_gcc(src)
  end

  def test_returns_correct_value_at_run_time
    src = <<~C
      int main(void) {
        double f = 1.5;
        unsigned long a = (unsigned long)f;
        return (int)a;
      }
    C
    assert_c_exit_status(1, src, compiler: :rubycc)
    assert_c_exit_status(1, src, compiler: :gcc)
  end

  private

  def assert_same_stdout_as_gcc(src)
    in_tmpdir do |dir|
      rubycc_obj = compile_with_rubycc(src, File.join(dir, "rubycc.o"))
      gcc_obj = compile_with_gcc(src, File.join(dir, "gcc.o"))
      _, rubycc_stdout = link_and_run(rubycc_obj)
      _, gcc_stdout = link_and_run(gcc_obj)
      assert_equal gcc_stdout, rubycc_stdout, "rubycc stdout diverged from gcc"
    end
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
