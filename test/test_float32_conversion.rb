# frozen_string_literal: true

require_relative "test_helper"

# Verifies Generator#double_to_binary32_bits, the correctly-rounded
# binary64 -> binary32 conversion that replaced Array#pack("e") after the
# latter turned out to saturate a magnitude past FLT_MAX straight to
# infinity instead of rounding it to FLT_MAX (round-to-nearest,
# ties-to-even keeps some of that range). The method is private, so it is
# exercised through #send; nothing here depends on Generator's other state.
class TestFloat32Conversion < Minitest::Test
  include ExecutionHelper

  Generator = Rubycc::IR::Generator

  def setup
    @gen = Generator.new
  end

  def test_flt_max_literal_rounds_down_instead_of_saturating_to_infinity
    # The FLT_MAX decimal literal float.h ships (10 significant digits) is
    # itself not exactly FLT_MAX as a double, but within half a binary32 ULP
    # of it, so it must round to FLT_MAX's own bit pattern (0x7f7fffff), not
    # to infinity.
    assert_equal 0x7f7fffff, bits(3.40282347e+38)
  end

  def test_exact_tie_between_flt_max_and_infinity_rounds_to_even_infinity
    # 2**128 - 2**103 is exactly halfway between FLT_MAX (2**128 - 2**104)
    # and 2**128 (which binary32 represents as infinity, its exponent field
    # having no value that large). 2**128's zero mantissa is the "even"
    # candidate, so the tie rounds up to infinity.
    tie = (2**128) - (2**103)
    assert_equal 0x7f800000, bits(tie.to_f)
  end

  def test_just_below_the_tie_still_rounds_to_flt_max
    # One double ULP below the exact tie (the double exponent here is 127,
    # so its ULP is 2**(127-52) = 2**75): still on the FLT_MAX side, and
    # unambiguously so (not itself a tie).
    tie = (2**128) - (2**103)
    just_below = tie - (2**75)
    assert_equal 0x7f7fffff, bits(just_below.to_f)
  end

  def test_ties_to_even_rounds_down_to_the_even_mantissa
    # 1.0 + 2**-24 sits exactly halfway between 1.0 (mantissa ...0, even) and
    # 1.0 + 2**-23 (mantissa ...1, odd); ties-to-even keeps 1.0.
    assert_equal 0x3f800000, bits(1.0 + (2.0**-24))
  end

  def test_ties_to_even_rounds_up_to_the_even_mantissa
    # 1.0 + 3*2**-24 == 1.0 + 1.5*2**-23 sits exactly halfway between
    # 1.0 + 2**-23 (odd) and 1.0 + 2*2**-23 (even); ties-to-even rounds up.
    assert_equal 0x3f800002, bits(1.0 + (3 * (2.0**-24)))
  end

  def test_flt_true_min_subnormal_round_trips
    assert_equal 0x00000001, bits(1.401298464324817e-45)
  end

  def test_half_of_flt_true_min_underflows_to_zero_by_ties_to_even
    # Exactly halfway between binary32's zero and its smallest subnormal;
    # zero is the even candidate.
    assert_equal 0x00000000, bits(1.401298464324817e-45 / 2)
  end

  def test_signed_zero
    assert_equal 0x00000000, bits(0.0)
    assert_equal 0x80000000, bits(-0.0)
  end

  def test_infinities
    assert_equal 0x7f800000, bits(Float::INFINITY)
    assert_equal 0xff800000, bits(-Float::INFINITY)
  end

  def test_nan_is_a_quiet_nan
    assert_equal 0x7fc00000, bits(Float::NAN)
  end

  def test_negative_flt_max_literal
    assert_equal 0xff7fffff, bits(-3.40282347e+38)
  end

  def test_pack_float_four_bytes_matches_the_bit_pattern
    assert_equal [0x7f7fffff].pack("L<"), @gen.send(:pack_float, 3.40282347e+38, 4)
  end

  def test_pack_float_eight_bytes_is_still_the_plain_double_encoding
    value = 3.40282347e+38
    assert_equal [value].pack("E"), @gen.send(:pack_float, value, 8)
  end

  def test_float_bit_pattern_eight_bytes_is_still_the_plain_double_encoding
    value = Math::PI
    assert_equal [value].pack("E").unpack1("Q<"),
                 @gen.send(:float_bit_pattern, value, Rubycc::Type::Double)
  end

  # End-to-end: the FLT_MAX decimal literal compiled and run, cross-checked
  # against gcc rather than a hardcoded value, matching this project's other
  # gcc-diff execution tests.
  def test_flt_max_literal_matches_gcc_at_run_time
    skip "gcc unavailable (needed to cross-check)" unless tool?("gcc")
    src = <<~C
      #include <float.h>
      #include <stdio.h>
      int main(void) {
        float f = 3.40282347e+38F;
        printf("%a %d\\n", (double)f, f == FLT_MAX);
        return 0;
      }
    C
    assert_same_stdout_as_gcc(src)
  end

  private

  def bits(value)
    @gen.send(:double_to_binary32_bits, value)
  end

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
