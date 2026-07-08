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

  def test_character_constant_escape_sequences
    { "'\\n'" => 10, "'\\t'" => 9, "'\\r'" => 13, "'\\0'" => 0,
      "'\\\\'" => 92, "'\\''" => 39, "'\\\"'" => 34, "'\\a'" => 7,
      "'\\b'" => 8, "'\\f'" => 12, "'\\v'" => 11 }.each do |source, value|
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

  def test_unterminated_string_literal_raises
    error = assert_raises(Rubycc::CompileError) { lex('"oops') }
    assert_match(/unterminated string literal/, error.description)
  end

  def test_unknown_escape_in_string_literal_raises
    error = assert_raises(Rubycc::CompileError) { lex('"a\\qb"') }
    assert_match(/unknown escape sequence in string literal/, error.description)
  end
end
