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
end
