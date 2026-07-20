# frozen_string_literal: true

require_relative "test_helper"

# Plain `char`'s signedness is implementation-defined (6.2.5p15) and every ABI
# pins it: signed under the x86-64 System V psABI, unsigned under AAPCS64. It is
# therefore a property of the compilation target, not of the compiler, and
# `char`, `signed char` and `unsigned char` are three distinct types whatever
# the target — only the first one moves.
#
# The checks below come in three layers. The type/front-end ones assert the
# distinctness and the per-target resolution directly; the x86-64 execution ones
# are the regression guard that the default target still treats plain `char` as
# signed (they would have passed before this became target-dependent, which is
# the point); and the aarch64 ones run the same programs through the cross
# toolchain, where rubycc's answer must agree with a gcc that has plain `char`
# unsigned.
class TestPlainCharSignedness < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  Type = Rubycc::Type

  # --- the type layer -------------------------------------------------------

  def test_three_character_types_are_distinct
    refute_equal Type::Char, Type::SChar
    refute_equal Type::Char, Type::UChar
    refute_equal Type::SChar, Type::UChar
    refute_equal Type::Char, Type::UnsignedChar
  end

  def test_character_types_are_one_byte_wide
    [Type::Char, Type::UnsignedChar, Type::SChar, Type::UChar].each do |type|
      assert_equal 1, type.size, "#{type} should be one byte wide"
      assert_equal 1, type.alignment, "#{type} should be byte aligned"
    end
  end

  def test_explicit_signedness_is_fixed
    assert_predicate Type::SChar, :signed?
    assert_predicate Type::UChar, :unsigned?
  end

  def test_plain_char_picks_the_targets_instance
    assert_same Type::Char, Type.plain_char(true)
    assert_same Type::UnsignedChar, Type.plain_char(false)
    assert_predicate Type.plain_char(true), :signed?
    assert_predicate Type.plain_char(false), :unsigned?
  end

  # Both plain-char instances spell themselves "char", so a diagnostic and
  # #char? read the same whichever target is in play, while `signed char` and
  # `unsigned char` are not plain `char` at all.
  def test_plain_char_spelling_and_predicate
    assert_equal "char", Type::Char.to_s
    assert_equal "char", Type::UnsignedChar.to_s
    assert_predicate Type::Char, :char?
    assert_predicate Type::UnsignedChar, :char?
    refute_predicate Type::SChar, :char?
    refute_predicate Type::UChar, :char?
  end

  def test_character_predicate_names_the_three_character_types
    [Type::Char, Type::UnsignedChar, Type::SChar, Type::UChar].each do |type|
      assert Type.character?(type), "#{type} should be a character type"
    end
    [Type::Bool, Type::Short, Type::Int].each do |type|
      refute Type.character?(type), "#{type} should not be a character type"
    end
  end

  # --- the parser layer -----------------------------------------------------

  # The declared type of "<spelling> c;" as one target's parser resolves it.
  def parse_char_type(spelling, **options)
    source = "int main(void) { #{spelling} c; return 0; }"
    tokens = Rubycc::Preprocess::Preprocessor.new.run(source, filename: "t.c", system_includes: false)
    Rubycc::Front::Parser.new(tokens, **options).parse.functions.first.body.first.type
  end

  def test_parser_defaults_plain_char_to_the_signed_instance
    assert_same Type::Char, parse_char_type("char")
  end

  def test_parser_resolves_plain_char_to_the_given_instance
    assert_same Type::UnsignedChar, parse_char_type("char", plain_char: Type::UnsignedChar)
  end

  # The explicitly signed spellings ignore the target's choice entirely.
  def test_parser_keeps_explicit_signedness_target_independent
    assert_same Type::SChar, parse_char_type("signed char", plain_char: Type::UnsignedChar)
    assert_same Type::UChar, parse_char_type("unsigned char", plain_char: Type::UnsignedChar)
  end

  # --- the preprocessor layer -----------------------------------------------

  def defined_char_unsigned?(**options)
    source = "#ifdef __CHAR_UNSIGNED__\nint yes;\n#else\nint no;\n#endif"
    tokens = Rubycc::Preprocess::Preprocessor.new(**options)
                                             .run(source, filename: "t.c", system_includes: false)
    tokens.any? { |tok| tok.type == :ident && tok.value == "yes" }
  end

  def test_char_unsigned_macro_follows_the_target
    refute defined_char_unsigned?, "__CHAR_UNSIGNED__ must stay undefined where char is signed"
    assert defined_char_unsigned?(char_unsigned: true),
           "__CHAR_UNSIGNED__ must be predefined where char is unsigned"
  end

  # --- x86-64: plain char stays signed --------------------------------------

  # The regression guard: making the signedness target-dependent must not have
  # moved the default target off the System V psABI's signed plain `char`.
  def test_x86_64_plain_char_sign_extends
    assert_c_program(<<~C, exit_status: 0, stdout: "-16 -16 -16 -16\n")
      int printf(const char *fmt, ...);
      char g = (char)0xF0;
      char gs[] = "\\xF0";
      int main(void) {
        char c = (char)0xF0;
        printf("%d %d %d %d\\n", c, (int)g, (int)gs[0], "\\xF0"[0]);
        return 0;
      }
    C
  end

  def test_x86_64_plain_char_compares_as_signed
    assert_c_program(<<~C, exit_status: 0, stdout: "1 0 1\n")
      int printf(const char *fmt, ...);
      int main(void) {
        char c = (char)0xF0;
        printf("%d %d %d\\n", c < 0, c > 100, c == -16);
        return 0;
      }
    C
  end

  def test_x86_64_char_limits_are_the_signed_range
    assert_c_program(<<~C, exit_status: 0, stdout: "-128 127 signed\n")
      #include <limits.h>
      int printf(const char *fmt, ...);
      int main(void) {
      #ifdef __CHAR_UNSIGNED__
        printf("%d %d unsigned\\n", CHAR_MIN, CHAR_MAX);
      #else
        printf("%d %d signed\\n", CHAR_MIN, CHAR_MAX);
      #endif
        return 0;
      }
    C
  end

  # --- aarch64: plain char is unsigned --------------------------------------

  # The case that first exposed the fixed signedness: a plain `char` holding
  # 0xF0 widens to 240 under AAPCS64, where rubycc used to say -16. The explicit
  # spellings in the same program pin down that only plain `char` moved.
  def test_aarch64_plain_char_zero_extends
    assert_aarch64_matches_gcc(<<~C)
      int printf(const char *fmt, ...);
      char g = (char)0xF0;
      char gs[] = "\\xF0";
      int main(void) {
        char c = (char)0xF0;
        printf("%d %d %d %d\\n", c, (int)g, (int)gs[0], "\\xF0"[0]);
        printf("%d %d\\n", (int)(signed char)0xF0, (int)(unsigned char)0xF0);
        printf("%ld %lu\\n", (long)c, (unsigned long)c);
        return 0;
      }
    C
  end

  def test_aarch64_plain_char_compares_as_unsigned
    assert_aarch64_matches_gcc(<<~C)
      int printf(const char *fmt, ...);
      int main(void) {
        char c = (char)0xF0;
        int n = -16;
        printf("%d %d %d %d\\n", c < 0, c > 100, c == -16, c == n);
        signed char s = (signed char)0xF0;
        printf("%d %d\\n", s < 0, s == n);
        return 0;
      }
    C
  end

  def test_aarch64_plain_char_arithmetic
    assert_aarch64_matches_gcc(<<~C)
      int printf(const char *fmt, ...);
      int main(void) {
        char a = (char)0xF0;
        char b = 3;
        printf("%d %d %d %d\\n", a + b, a - b, a / b, a % b);
        printf("%d %d\\n", a >> 2, (int)(char)(a * 2));
        return 0;
      }
    C
  end

  def test_aarch64_char_limits_follow_the_abi
    assert_aarch64_matches_gcc(<<~C)
      #include <limits.h>
      int printf(const char *fmt, ...);
      int main(void) {
        printf("%d %d %d %d %d\\n", CHAR_MIN, CHAR_MAX, SCHAR_MIN, SCHAR_MAX, UCHAR_MAX);
      #ifdef __CHAR_UNSIGNED__
        printf("unsigned\\n");
      #else
        printf("signed\\n");
      #endif
        return 0;
      }
    C
  end

  # A whole string walked through plain `char`: the bytes past 0x7F are what
  # separate the two signedness choices, and the sum of them is the oracle.
  def test_aarch64_plain_char_string_walk
    assert_aarch64_matches_gcc(<<~C)
      int printf(const char *fmt, ...);
      static int total(const char *s) {
        int sum = 0;
        while (*s) sum += *s++;
        return sum;
      }
      int main(void) {
        printf("%d\\n", total("\\x01\\x7F\\x80\\xFF"));
        char buf[5] = "\\x01\\x7F\\x80\\xFF";
        printf("%d\\n", total(buf));
        for (int i = 0; i < 4; i++) printf("%d ", buf[i]);
        printf("\\n");
        return 0;
      }
    C
  end

  # A plain `char` switch: the case labels are compared after promotion, so the
  # target's signedness decides which arm a byte past 0x7F reaches.
  def test_aarch64_plain_char_switch
    assert_aarch64_matches_gcc(<<~C)
      int printf(const char *fmt, ...);
      static int classify(char c) {
        switch (c) {
          case 240: return 1;
          case -16: return 2;
          default: return 0;
        }
      }
      int main(void) {
        printf("%d\\n", classify((char)0xF0));
        return 0;
      }
    C
  end
end
