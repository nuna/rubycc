# frozen_string_literal: true

require_relative "test_helper"

# Step 51 (M2 addendum): a cast to an integer type folds at compile time when
# its operand is itself a floating-point constant (a literal, or a negated
# literal) — "(unsigned long)1e2" — truncating toward zero per ISO C
# 6.3.1.4p1 before the destination type's width/signedness wrap. This is what
# lets json's vendor/jeaiii-ltoa.h spell its decimal thresholds as
# "u32(1e2)".."u64(1e15)" (u32_t/u64_t are `unsigned long` on LP64), a
# conversion the run-time float<->`unsigned long` path still does not lower
# (see TestGccBuiltins and the "conversion between 'unsigned long' and a
# floating type" diagnostic), and to use the folded value as a comparison,
# division or remainder operand. It also reaches the constant-expression
# contexts (array bound, case label) ConstantEvaluator serves.
class TestFloatIntCastFolding < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to cross-check)" unless tool?("gcc")
  end

  def test_unsigned_long_cast_of_small_double_literal
    src = <<~C
      typedef unsigned long u32_t;
      #define u32(x) ((u32_t)(x))
      int main(void) { unsigned long a = u32(1e2); return a == 100 ? 0 : 1; }
    C
    assert_matches_gcc(0, src)
  end

  def test_unsigned_long_cast_of_large_double_literal
    src = <<~C
      typedef unsigned long u64_t;
      #define u64(x) ((u64_t)(x))
      int main(void) {
        unsigned long a = u64(1e15);
        return a == 1000000000000000UL ? 0 : 1;
      }
    C
    assert_matches_gcc(0, src)
  end

  def test_negative_double_literal_truncates_toward_zero
    src = <<~C
      int main(void) { int c = (int)-2.9; return c; }
    C
    assert_matches_gcc(-2 & 0xff, src)
  end

  def test_positive_double_literal_truncates_toward_zero
    src = <<~C
      int main(void) { long d = (long)3.999; return (int)d; }
    C
    assert_matches_gcc(3, src)
  end

  def test_folded_cast_as_comparison_operand
    src = <<~C
      typedef unsigned long u32_t;
      #define u32(x) ((u32_t)(x))
      int main(void) {
        unsigned long n = 12345;
        return n < u32(1e2) ? 1 : 0;
      }
    C
    assert_matches_gcc(0, src)
  end

  def test_folded_cast_as_division_and_remainder_operand
    src = <<~C
      typedef unsigned long u32_t;
      #define u32(x) ((u32_t)(x))
      int main(void) {
        unsigned long n = 12345;
        unsigned long q = n / u32(1e2);
        unsigned long r = n % u32(1e2);
        return (int)(q * 100 + r - n);
      }
    C
    assert_matches_gcc(0, src)
  end

  def test_folded_cast_in_array_bound
    src = <<~C
      int main(void) {
        char buf[(int)4.9];
        return (int)sizeof(buf);
      }
    C
    assert_matches_gcc(4, src)
  end

  def test_folded_cast_in_case_label
    src = <<~C
      int main(void) {
        int total = 0;
        switch ((int)2.0) {
        case (int)2.0:
          total = 10;
          break;
        default:
          total = 1000;
          break;
        }
        return total;
      }
    C
    assert_matches_gcc(10, src)
  end

  # A non-constant float->unsigned long conversion (the run-time float<->int
  # gap unrelated to this fold) is still diagnosed, exactly as before.
  def test_non_constant_float_to_unsigned_long_still_rejected
    src = <<~C
      int main(void) {
        double f = 1.5;
        unsigned long a = (unsigned long)f;
        return (int)a;
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(src, filename: "cast.c")
    end
    assert_match(/conversion between 'unsigned long' and a floating type is not supported yet/, error.message)
  end

  private

  def assert_matches_gcc(expected, src)
    assert_c_exit_status(expected, src, compiler: :rubycc)
    assert_c_exit_status(expected, src, compiler: :gcc)
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
