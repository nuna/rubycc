# frozen_string_literal: true

require_relative "test_helper"

# The GNU extension escape "\e"/"\E" (ESC, 0x1B): not one of the eleven simple
# escapes in C11 6.4.4.4, but gcc 13.3 accepts it unconditionally (only warning
# under -pedantic). Measured 2026-09-13, issues/escape-sequence-e.md; the real
# case is string_undump 0.1.1's `return "\e";`.
class TestEscapeSequenceE < Minitest::Test
  include ExecutionHelper

  def lex(source, filename: "test.c")
    Rubycc::Front::Lexer.new(source, filename: filename).tokenize
  end

  # --- lexer-level: character constants -------------------------------------

  def test_lowercase_e_escape_in_character_constant_is_esc
    tokens = lex("'\\e'").reject(&:eof?)
    assert_equal :num, tokens[0].type
    assert_equal 0x1B, tokens[0].value
  end

  def test_uppercase_e_escape_in_character_constant_is_esc
    tokens = lex("'\\E'").reject(&:eof?)
    assert_equal :num, tokens[0].type
    assert_equal 0x1B, tokens[0].value
  end

  # --- lexer-level: string literals ------------------------------------------

  def test_lowercase_e_escape_in_string_literal_is_esc
    tokens = lex('"\\e[0m"').reject(&:eof?)
    assert_equal :string, tokens[0].type
    assert_equal "\x1B[0m".b, tokens[0].value
  end

  def test_uppercase_e_escape_in_string_literal_is_esc
    tokens = lex('"\\E"').reject(&:eof?)
    assert_equal "\x1B".b, tokens[0].value
  end

  # --- gcc-differential execution: character constant -----------------------
  #
  # gcc's own object is the oracle here, run to completion, not merely
  # compiled: the accepted-condition asks for "0x1B" to be confirmed by
  # execution, not just a successful build.

  def test_lowercase_e_character_constant_exits_with_esc_on_gcc
    assert_c_exit_status(27, "int main(void) { return '\\e'; }", compiler: :gcc)
  end

  def test_lowercase_e_character_constant_exits_with_esc_on_rubycc
    assert_c_exit_status(27, "int main(void) { return '\\e'; }", compiler: :rubycc)
  end

  def test_uppercase_e_character_constant_exits_with_esc_on_gcc
    assert_c_exit_status(27, "int main(void) { return '\\E'; }", compiler: :gcc)
  end

  def test_uppercase_e_character_constant_exits_with_esc_on_rubycc
    assert_c_exit_status(27, "int main(void) { return '\\E'; }", compiler: :rubycc)
  end

  # --- gcc-differential execution: string literal ----------------------------

  def test_string_literal_escape_e_bytes_on_gcc
    assert_c_program(<<~C, exit_status: 0, stdout: "27 91 48 109\n", compiler: :gcc)
      int printf(const char *fmt, ...);
      int main(void) {
        const char *s = "\\e[0m";
        printf("%d %d %d %d\\n", (unsigned char)s[0], (unsigned char)s[1],
               (unsigned char)s[2], (unsigned char)s[3]);
        return 0;
      }
    C
  end

  def test_string_literal_escape_e_bytes_on_rubycc
    assert_c_program(<<~C, exit_status: 0, stdout: "27 91 48 109\n", compiler: :rubycc)
      int printf(const char *fmt, ...);
      int main(void) {
        const char *s = "\\e[0m";
        printf("%d %d %d %d\\n", (unsigned char)s[0], (unsigned char)s[1],
               (unsigned char)s[2], (unsigned char)s[3]);
        return 0;
      }
    C
  end

  # --- wide character constant (L'\e') ---------------------------------------
  #
  # rubycc supports the "L" prefix only for character constants (a wide string
  # literal is diagnosed, lib/rubycc/preprocess/token_converter.rb#decode_string);
  # a wide character constant's value equals the plain constant's for the
  # single-byte characters this subset lexes, so "\e" resolves the same way.

  def test_wide_character_constant_escape_e_on_gcc
    assert_c_exit_status(27, "int main(void) { return L'\\e'; }", compiler: :gcc)
  end

  def test_wide_character_constant_escape_e_on_rubycc
    assert_c_exit_status(27, "int main(void) { return L'\\e'; }", compiler: :rubycc)
  end

  # --- out-of-standard escapes other than \e/\E: behavior unchanged ---------
  #
  # Measured on this host (gcc 13.3, 2026-09-13): gcc -Wall -Wextra warns
  # "unknown escape sequence: '\q'" for an escaped letter but *not* for an
  # escaped punctuation character such as '\%' (silently drops the backslash
  # in both cases; exit status/byte value equals the plain character). Neither
  # case is required by any known corpus gem, so rubycc's existing
  # "unknown escape sequence" diagnostic for both is kept unchanged here.

  def test_unrecognized_letter_escape_still_raises_in_character_constant
    error = assert_raises(Rubycc::CompileError) { lex("'\\q'") }
    assert_match(/unknown escape sequence in character constant/, error.description)
  end

  def test_unrecognized_punctuation_escape_still_raises_in_character_constant
    error = assert_raises(Rubycc::CompileError) { lex("'\\%'") }
    assert_match(/unknown escape sequence in character constant/, error.description)
  end

  def test_unrecognized_punctuation_escape_still_raises_in_string_literal
    error = assert_raises(Rubycc::CompileError) { lex('"\\%"') }
    assert_match(/unknown escape sequence in string literal/, error.description)
  end
end
