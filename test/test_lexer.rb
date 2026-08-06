# frozen_string_literal: true

require_relative "test_helper"

class TestLexer < Minitest::Test
  def lex(source, filename: "test.c")
    Rubycc::Front::Lexer.new(source, filename: filename).tokenize
  end

  def test_tokenizes_a_full_function
    tokens = lex("int main(void) { return 42; }")
    types = tokens.map(&:type)
    values = tokens.map(&:value)

    assert_equal %i[keyword ident punct keyword punct punct keyword num punct punct eof], types
    assert_equal ["int", "main", "(", "void", ")", "{", "return", 42, ";", "}", nil], values
  end

  def test_number_value_is_an_integer
    tokens = lex("return 123;")
    num = tokens.find { |t| t.type == :num }

    assert_equal 123, num.value
    assert_kind_of Integer, num.value
  end

  def test_identifiers_versus_keywords
    tokens = lex("int foo return void")
    assert_equal :keyword, tokens[0].type
    assert_equal :ident, tokens[1].type
    assert_equal "foo", tokens[1].value
    assert_equal :keyword, tokens[2].type
    assert_equal :keyword, tokens[3].type
  end

  def test_tracks_line_and_column
    source = "int main(void) {\n  return 42;\n}\n"
    tokens = lex(source)
    ret = tokens.find { |t| t.keyword?("return") }
    num = tokens.find { |t| t.type == :num }

    assert_equal 2, ret.line
    assert_equal 3, ret.column      # after two spaces of indentation
    assert_equal 2, num.line
    assert_equal 10, num.column
    assert_equal "  return 42;", ret.source_line
  end

  def test_columns_are_one_based_on_first_line
    tokens = lex("int x")
    assert_equal 1, tokens[0].line
    assert_equal 1, tokens[0].column
    assert_equal 5, tokens[1].column
  end

  def test_skips_line_comments
    tokens = lex("return 1; // trailing comment\nreturn 2;")
    values = tokens.reject(&:eof?).map(&:value)

    assert_equal ["return", 1, ";", "return", 2, ";"], values
  end

  def test_skips_block_comments
    tokens = lex("return /* inline */ 42 /* another\nmultiline */ ;")
    values = tokens.reject(&:eof?).map(&:value)

    assert_equal ["return", 42, ";"], values
  end

  def test_invalid_character_raises_compile_error
    error = assert_raises(Rubycc::CompileError) { lex("return @;") }

    assert_equal "test.c", error.filename
    assert_equal 1, error.line
    assert_equal 8, error.column
  end

  def test_unterminated_block_comment_raises
    assert_raises(Rubycc::CompileError) { lex("return /* oops") }
  end

  def test_two_character_punctuators_are_single_tokens
    %w[== != <= >=].each do |op|
      tokens = lex("x #{op} y").reject(&:eof?)
      assert_equal [:ident, :punct, :ident], tokens.map(&:type)
      assert_equal op, tokens[1].value
    end
  end

  def test_spaced_equals_lexes_as_two_tokens
    tokens = lex("x = = y").reject(&:eof?)
    assert_equal %i[ident punct punct ident], tokens.map(&:type)
    assert_equal ["x", "=", "=", "y"], tokens.map(&:value)
  end

  def test_less_or_equal_versus_less_then_equals
    combined = lex("x <= y").reject(&:eof?)
    assert_equal %i[ident punct ident], combined.map(&:type)
    assert_equal "<=", combined[1].value

    split = lex("x < = y").reject(&:eof?)
    assert_equal %i[ident punct punct ident], split.map(&:type)
    assert_equal ["x", "<", "=", "y"], split.map(&:value)
  end

  def test_bang_is_a_single_character_punctuator
    tokens = lex("!x").reject(&:eof?)
    assert_equal %i[punct ident], tokens.map(&:type)
    assert_equal "!", tokens[0].value
  end

  def test_if_and_else_are_keywords
    tokens = lex("if else").reject(&:eof?)
    assert_equal %i[keyword keyword], tokens.map(&:type)
    assert_equal %w[if else], tokens.map(&:value)
  end

  def test_switch_case_default_goto_are_keywords
    tokens = lex("switch case default goto").reject(&:eof?)
    assert_equal %i[keyword keyword keyword keyword], tokens.map(&:type)
    assert_equal %w[switch case default goto], tokens.map(&:value)
  end

  def test_logical_and_versus_bitwise_and
    combined = lex("x && y").reject(&:eof?)
    assert_equal %i[ident punct ident], combined.map(&:type)
    assert_equal "&&", combined[1].value

    split = lex("x & y").reject(&:eof?)
    assert_equal %i[ident punct ident], split.map(&:type)
    assert_equal "&", split[1].value
  end

  def test_logical_or_is_a_single_token
    tokens = lex("x || y").reject(&:eof?)
    assert_equal %i[ident punct ident], tokens.map(&:type)
    assert_equal "||", tokens[1].value
  end

  def test_increment_versus_compound_add_versus_plain_plus
    increment = lex("x ++ y").reject(&:eof?)
    assert_equal "++", increment[1].value

    compound_add = lex("x += y").reject(&:eof?)
    assert_equal "+=", compound_add[1].value

    plain_plus = lex("x + y").reject(&:eof?)
    assert_equal "+", plain_plus[1].value

    no_space = lex("x+++y").reject(&:eof?)
    assert_equal ["x", "++", "+", "y"], no_space.map(&:value)
  end

  def test_decrement_versus_compound_sub_versus_plain_minus
    assert_equal "--", lex("x -- y").reject(&:eof?)[1].value
    assert_equal "-=", lex("x -= y").reject(&:eof?)[1].value
    assert_equal "-", lex("x - y").reject(&:eof?)[1].value
  end

  def test_compound_assignment_operators_are_single_tokens
    %w[+= -= *= /= %= &= |= ^= <<= >>=].each do |op|
      tokens = lex("x #{op} y").reject(&:eof?)
      assert_equal [:ident, :punct, :ident], tokens.map(&:type)
      assert_equal op, tokens[1].value
    end
  end

  def test_bitwise_operators_are_single_character_tokens
    %w[& | ^ ~].each do |op|
      tokens = lex("x #{op} y").reject(&:eof?)
      assert_equal op, tokens[1].value
    end
  end

  def test_shift_operators_are_two_character_tokens
    %w[<< >>].each do |op|
      tokens = lex("x #{op} y").reject(&:eof?)
      assert_equal %i[ident punct ident], tokens.map(&:type)
      assert_equal op, tokens[1].value
    end
  end

  def test_shift_assignment_prefers_longest_punctuator
    # "<<=" must win over "<<", "<=" and "<"; likewise ">>=".
    assert_equal "<<=", lex("x <<= y").reject(&:eof?)[1].value
    assert_equal ">>=", lex("x >>= y").reject(&:eof?)[1].value

    # Without the trailing "=", the shift is two "<" characters, not "<" then
    # something else, and a following "=" splits off as its own token.
    assert_equal ["x", "<<", "y"], lex("x << y").reject(&:eof?).map(&:value)
    assert_equal ["x", "<<", "=", "y"], lex("x <<= y".sub("<<=", "<< =")).reject(&:eof?).map(&:value)
  end

  def test_conditional_operator_punctuators_are_single_character_tokens
    tokens = lex("a ? b : c").reject(&:eof?)
    assert_equal %i[ident punct ident punct ident], tokens.map(&:type)
    assert_equal ["a", "?", "b", ":", "c"], tokens.map(&:value)
  end

  def test_char_is_a_keyword
    tokens = lex("char c").reject(&:eof?)
    assert_equal %i[keyword ident], tokens.map(&:type)
    assert_equal %w[char c], tokens.map(&:value)
  end

  def test_struct_is_a_keyword
    tokens = lex("struct point").reject(&:eof?)
    assert_equal %i[keyword ident], tokens.map(&:type)
    assert_equal %w[struct point], tokens.map(&:value)
  end

  def test_union_is_a_keyword
    tokens = lex("union data").reject(&:eof?)
    assert_equal %i[keyword ident], tokens.map(&:type)
    assert_equal %w[union data], tokens.map(&:value)
  end

  def test_enum_and_typedef_are_keywords
    tokens = lex("enum typedef Color").reject(&:eof?)
    assert_equal %i[keyword keyword ident], tokens.map(&:type)
    assert_equal %w[enum typedef Color], tokens.map(&:value)
  end

  def test_storage_class_and_qualifier_keywords
    tokens = lex("static extern register auto const volatile inline x").reject(&:eof?)
    assert_equal %i[keyword keyword keyword keyword keyword keyword keyword ident], tokens.map(&:type)
    assert_equal %w[static extern register auto const volatile inline x], tokens.map(&:value)
  end

  def test_gcc_alternate_keyword_spellings_normalize_to_the_plain_keyword
    # gcc's reserved "__x"/"__x__" spellings (glibc leans on these under
    # -ansi/-std=c89) lex to the same :keyword token as the plain spelling, so
    # every downstream check keyed on "signed"/"const"/"volatile"/"inline"
    # sees an ordinary keyword and needs no separate case for the alias.
    tokens = lex("__signed __signed__ __const __const__ " \
                 "__volatile __volatile__ __inline __inline__").reject(&:eof?)
    assert_equal [:keyword] * 8, tokens.map(&:type)
    assert_equal %w[signed signed const const volatile volatile inline inline], tokens.map(&:value)
  end

  def test_static_assert_and_alignof_are_keywords
    tokens = lex("_Static_assert _Alignof").reject(&:eof?)
    assert_equal %i[keyword keyword], tokens.map(&:type)
    assert_equal %w[_Static_assert _Alignof], tokens.map(&:value)
  end

  def test_arrow_is_a_single_token
    tokens = lex("p->x").reject(&:eof?)
    assert_equal %i[ident punct ident], tokens.map(&:type)
    assert_equal ["p", "->", "x"], tokens.map(&:value)
  end

  def test_arrow_versus_minus_then_greater
    combined = lex("p -> x").reject(&:eof?)
    assert_equal "->", combined[1].value

    # A lone "-" followed by ">" (with a space) stays two tokens.
    split = lex("p - > x").reject(&:eof?)
    assert_equal %i[ident punct punct ident], split.map(&:type)
    assert_equal ["p", "-", ">", "x"], split.map(&:value)
  end

  def test_dot_is_a_single_character_punctuator
    tokens = lex("s.x").reject(&:eof?)
    assert_equal %i[ident punct ident], tokens.map(&:type)
    assert_equal ["s", ".", "x"], tokens.map(&:value)
  end

  def test_character_constant_is_a_num_token
    tokens = lex("'A'").reject(&:eof?)
    assert_equal [:num], tokens.map(&:type)
    assert_equal 65, tokens[0].value
    assert_kind_of Integer, tokens[0].value
  end

  # All eleven simple escape sequences of 6.4.4.4p1 (plus "\0", an octal one),
  # including "\?" -- the trigraph-avoiding spelling of a plain '?'.
  def test_character_constant_escape_sequences
    { "'\\n'" => 10, "'\\t'" => 9, "'\\r'" => 13, "'\\0'" => 0,
      "'\\\\'" => 92, "'\\''" => 39, "'\\\"'" => 34, "'\\?'" => 63,
      "'\\a'" => 7, "'\\b'" => 8, "'\\f'" => 12, "'\\v'" => 11 }.each do |source, value|
      tokens = lex(source).reject(&:eof?)
      assert_equal :num, tokens[0].type, "#{source} should lex as a :num token"
      assert_equal value, tokens[0].value, "#{source} should have value #{value}"
    end
  end

  def test_string_literal_is_a_string_token
    tokens = lex('"hello"').reject(&:eof?)
    assert_equal [:string], tokens.map(&:type)
    assert_equal "hello".b, tokens[0].value
    assert_equal Encoding::ASCII_8BIT, tokens[0].value.encoding
  end

  def test_string_literal_resolves_escapes
    tokens = lex('"a\\tb\\n"').reject(&:eof?)
    assert_equal "a\tb\n".b, tokens[0].value
  end

  def test_string_literal_has_no_trailing_nul
    tokens = lex('"hi"').reject(&:eof?)
    assert_equal 2, tokens[0].value.bytesize
  end

  def test_empty_character_constant_raises
    error = assert_raises(Rubycc::CompileError) { lex("''") }
    assert_match(/empty character constant/, error.description)
  end

  def test_multi_character_constant_raises
    error = assert_raises(Rubycc::CompileError) { lex("'ab'") }
    assert_match(/multi-character character constant/, error.description)
  end

  def test_unterminated_character_constant_raises
    error = assert_raises(Rubycc::CompileError) { lex("'a") }
    assert_match(/unterminated character constant/, error.description)
  end

  def test_unknown_escape_in_character_constant_raises
    error = assert_raises(Rubycc::CompileError) { lex("'\\q'") }
    assert_match(/unknown escape sequence in character constant/, error.description)
  end

  # --- hexadecimal and octal character escapes (6.4.4.4) -------------------

  def test_hex_escape_in_character_constant
    tokens = lex("'\\x41'").reject(&:eof?)
    assert_equal 65, tokens[0].value
  end

  def test_hex_escape_with_two_digits
    tokens = lex("'\\x7f'").reject(&:eof?)
    assert_equal 127, tokens[0].value
  end

  def test_hex_escape_in_string_literal
    tokens = lex('"\\x41\\x42"').reject(&:eof?)
    assert_equal "AB".b, tokens[0].value
  end

  def test_octal_escape_with_three_digits
    tokens = lex("'\\101'").reject(&:eof?)
    assert_equal 65, tokens[0].value
  end

  def test_octal_escape_with_one_digit
    tokens = lex("'\\7'").reject(&:eof?)
    assert_equal 7, tokens[0].value
  end

  def test_octal_escape_with_two_digits
    tokens = lex("'\\77'").reject(&:eof?)
    assert_equal 63, tokens[0].value
  end

  def test_hex_escape_out_of_range_raises
    error = assert_raises(Rubycc::CompileError) { lex("'\\x100'") }
    assert_match(/hex escape sequence out of range/, error.description)
  end

  def test_octal_escape_out_of_range_raises
    error = assert_raises(Rubycc::CompileError) { lex("'\\777'") }
    assert_match(/octal escape sequence out of range/, error.description)
  end

  def test_hex_escape_with_no_digits_raises
    error = assert_raises(Rubycc::CompileError) { lex("'\\x'") }
    assert_match(/\\x used with no following hex digits/, error.description)
  end

  def test_unterminated_string_literal_raises
    error = assert_raises(Rubycc::CompileError) { lex('"oops') }
    assert_match(/unterminated string literal/, error.description)
  end

  def test_unknown_escape_in_string_literal_raises
    error = assert_raises(Rubycc::CompileError) { lex('"a\\qb"') }
    assert_match(/unknown escape sequence in string literal/, error.description)
  end

  # --- integer type extension (Step 17): base and suffix ------------------

  def test_short_long_signed_unsigned_bool_are_keywords
    tokens = lex("short long signed unsigned _Bool").reject(&:eof?)
    assert_equal %i[keyword keyword keyword keyword keyword], tokens.map(&:type)
    assert_equal %w[short long signed unsigned _Bool], tokens.map(&:value)
  end

  def test_hexadecimal_constant_value_and_base
    tokens = lex("0x1F").reject(&:eof?)
    num = tokens.first
    assert_equal 31, num.value
    assert_equal 16, num.base
    assert_equal "", num.suffix
  end

  def test_uppercase_hexadecimal_prefix_and_digits
    tokens = lex("0X2a").reject(&:eof?)
    num = tokens.first
    assert_equal 42, num.value
    assert_equal 16, num.base
  end

  def test_octal_constant_value_and_base
    tokens = lex("010").reject(&:eof?)
    num = tokens.first
    assert_equal 8, num.value
    assert_equal 8, num.base
  end

  def test_lone_zero_is_decimal_not_octal
    tokens = lex("0").reject(&:eof?)
    num = tokens.first
    assert_equal 0, num.value
    assert_equal 10, num.base
  end

  def test_decimal_constant_has_base_ten
    tokens = lex("123").reject(&:eof?)
    num = tokens.first
    assert_equal 123, num.value
    assert_equal 10, num.base
    assert_equal "", num.suffix
  end

  def test_integer_suffix_is_normalized_to_lower_case
    { "123u" => "u", "123U" => "u", "123l" => "l", "123L" => "l",
      "123ul" => "ul", "123LU" => "lu", "123ll" => "ll", "123LL" => "ll",
      "123ull" => "ull", "123llu" => "llu" }.each do |source, suffix|
      tokens = lex(source).reject(&:eof?)
      assert_equal suffix, tokens.first.suffix, "#{source} should normalize to suffix #{suffix.inspect}"
    end
  end

  def test_suffix_free_constant_has_empty_suffix
    tokens = lex("42").reject(&:eof?)
    assert_equal "", tokens.first.suffix
  end

  def test_invalid_hexadecimal_constant_raises
    error = assert_raises(Rubycc::CompileError) { lex("0x;") }
    assert_match(/invalid hexadecimal constant/, error.description)
  end

  def test_invalid_digit_in_octal_constant_raises
    error = assert_raises(Rubycc::CompileError) { lex("08;") }
    assert_match(/invalid digit in octal constant/, error.description)
  end

  def test_invalid_integer_suffix_raises
    error = assert_raises(Rubycc::CompileError) { lex("1uu;") }
    assert_match(/invalid suffix "uu" on integer constant/, error.description)
  end

  def test_unknown_trailing_letter_on_integer_constant_raises
    error = assert_raises(Rubycc::CompileError) { lex("1z;") }
    assert_match(/invalid suffix on integer constant/, error.description)
  end

  # --- floating constants (Step 24 Phase A) --------------------------------

  def test_floating_constant_is_a_float_token
    tok = lex("1.5;").first
    assert_equal :float, tok.type
    assert_in_delta 1.5, tok.value, 1e-12
    assert_kind_of Float, tok.value
    assert_equal "", tok.suffix
  end

  def test_trailing_dot_floating_constant
    tok = lex("1.;").first
    assert_equal :float, tok.type
    assert_in_delta 1.0, tok.value, 1e-12
  end

  def test_leading_dot_floating_constant
    tok = lex(".5;").first
    assert_equal :float, tok.type
    assert_in_delta 0.5, tok.value, 1e-12
  end

  def test_exponent_floating_constant
    tok = lex("1e3;").first
    assert_equal :float, tok.type
    assert_in_delta 1000.0, tok.value, 1e-9
  end

  def test_signed_exponent_floating_constant
    tok = lex("1.5e-2;").first
    assert_equal :float, tok.type
    assert_in_delta 0.015, tok.value, 1e-12
  end

  def test_out_of_range_floating_constant_folds_to_infinity
    tok = lex("1e10000;").first
    assert_equal :float, tok.type
    assert_equal Float::INFINITY, tok.value
  end

  # Regression tests for a Ruby 3.3.x decimal-conversion issue: a floating
  # constant whose "." is followed directly by an exponent, with no fraction
  # digits in between (valid per C11 6.4.4.2, e.g. "1.e5"), used to lose the
  # exponent on Ruby <= 3.3. The reader normalizes this shape before conversion
  # so it remains correct across the supported Ruby versions.

  def test_dot_then_exponent_with_no_fraction_digits
    tok = lex("1.e5;").first
    assert_equal :float, tok.type
    assert_in_delta 100_000.0, tok.value, 1e-9
  end

  def test_dot_then_signed_exponent_with_no_fraction_digits
    tok = lex("1.e-5;").first
    assert_equal :float, tok.type
    assert_in_delta 1.0e-05, tok.value, 1e-12
  end

  def test_dot_then_uppercase_exponent_with_no_fraction_digits
    tok = lex("123.E10;").first
    assert_equal :float, tok.type
    assert_in_delta 1_230_000_000_000.0, tok.value, 1.0
  end

  def test_dot_then_exponent_with_no_fraction_digits_extreme_magnitude
    tok = lex("9007199254740992.e-256;").first
    assert_equal :float, tok.type
    assert_in_delta 9.007199254740992e-241, tok.value, 9.007199254740992e-241 * 1e-12
  end

  # Shapes that already had fraction digits (or no "." at all) were never
  # affected by the Ruby 3.3.x String#to_f bug above; kept here as
  # regression guards so a future change to the normalization does not
  # break them.

  def test_dot_with_fraction_digit_then_exponent_still_correct
    tok = lex("1.0e5;").first
    assert_equal :float, tok.type
    assert_in_delta 100_000.0, tok.value, 1e-9
  end

  def test_leading_dot_then_exponent_still_correct
    tok = lex(".5e3;").first
    assert_equal :float, tok.type
    assert_in_delta 500.0, tok.value, 1e-9
  end

  def test_no_dot_exponent_still_correct
    tok = lex("1e10;").first
    assert_equal :float, tok.type
    assert_in_delta 1.0e10, tok.value, 1.0
  end

  def test_dot_with_fraction_digit_then_signed_exponent_still_correct
    tok = lex("1.5e-256;").first
    assert_equal :float, tok.type
    assert_in_delta 1.5e-256, tok.value, 1.5e-256 * 1e-12
  end

  def test_float_suffix_marks_single_precision
    tok = lex("1.5f;").first
    assert_equal :float, tok.type
    assert_equal "f", tok.suffix
  end

  def test_long_double_suffix_is_recorded
    tok = lex("1.5L;").first
    assert_equal :float, tok.type
    assert_equal "l", tok.suffix
  end

  def test_member_access_dot_is_not_a_floating_constant
    types = lex("s.m").map(&:type)
    assert_equal %i[ident punct ident eof], types
  end

  def test_octal_looking_decimal_float_is_floating
    # "08.5" is the float 8.5, not an octal integer (the '8' would be illegal
    # octal); the floating check runs before the octal one.
    tok = lex("08.5;").first
    assert_equal :float, tok.type
    assert_in_delta 8.5, tok.value, 1e-12
  end

  def test_hexadecimal_floating_constant_raises
    error = assert_raises(Rubycc::CompileError) { lex("0x1p3;") }
    assert_match(/hexadecimal floating constants are not supported yet/, error.description)
  end

  def test_exponent_without_digits_raises
    error = assert_raises(Rubycc::CompileError) { lex("1e;") }
    assert_match(/exponent has no digits/, error.description)
  end
end
