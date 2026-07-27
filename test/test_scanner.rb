# frozen_string_literal: true

require_relative "test_helper"

# Direct tests of the preprocessing-token Scanner (translation phases 2-3),
# pinned on the invariants a scanning strategy could silently break: physical
# line/column truthfulness across backslash-newline splices, unterminated
# literals kept verbatim, longest-match punctuators, and the space_before flag
# the directive layer depends on. Broader behavior is covered end-to-end by
# test_preprocessor.rb; these cases fix the token-level contract itself.
class TestScanner < Minitest::Test
  def scan(source)
    Rubycc::Preprocess::Scanner.new(source, filename: "scan.c").scan
  end

  # [type, text, line, column] of every non-newline, non-eof token.
  def core_tokens(source)
    scan(source).reject { |t| t.type == :newline || t.type == :eof }
                .map { |t| [t.type, t.text, t.line, t.column] }
  end

  def test_splice_joins_an_identifier_across_lines
    tokens = scan("long ab\\\ncd = 1;\n")
    joined = tokens[1]
    assert_equal [:identifier, "abcd", 1, 6], [joined.type, joined.text, joined.line, joined.column]
    assert_equal "long ab\\", joined.source_line
    # The token after the continuation is located on the second physical line.
    eq = tokens[2]
    assert_equal [:punct, "=", 2, 4], [eq.type, eq.text, eq.line, eq.column]
  end

  def test_consecutive_splices_advance_the_line_count_once_each
    tokens = scan("lo\\\n\\\nng x;\n")
    assert_equal [:identifier, "long", 1, 1], tokens[0].then { |t| [t.type, t.text, t.line, t.column] }
    assert_equal [:identifier, "x", 3, 4], tokens[1].then { |t| [t.type, t.text, t.line, t.column] }
  end

  def test_double_backslash_leaves_one_backslash_as_other_token
    # "\\\n" splices the *second* backslash with the newline; the first stays
    # a real character and becomes an :other token.
    tokens = scan("\\\\\n\n")
    assert_equal [[:other, "\\", 1, 1]], core_tokens("\\\\\n\n")
    assert_equal :newline, tokens[1].type
    assert_equal 2, tokens[1].line
  end

  def test_trailing_splice_before_eof_advances_the_line
    eof = scan("int x;\\\n").last
    assert_equal [:eof, 2, 1], [eof.type, eof.line, eof.column]
  end

  def test_unterminated_string_keeps_partial_text_without_the_newline
    assert_includes core_tokens("char *s = \"abc\nint x;\n"), [:string, "\"abc", 1, 11]
  end

  def test_string_ending_in_backslash_at_eof_keeps_the_backslash
    assert_equal [:string, "\"abc\\"], core_tokens("\"abc\\").first[0, 2]
  end

  def test_escaped_quote_does_not_close_a_string
    assert_includes core_tokens("char *s = \"a\\\"b\";\n"), [:string, "\"a\\\"b\"", 1, 11]
  end

  def test_wide_literals_require_the_prefix_to_abut_the_quote
    tokens = core_tokens("L\"wide\" L'w' Lident L 'c'\n")
    assert_equal [[:string, "L\"wide\""], [:char, "L'w'"], [:identifier, "Lident"],
                  [:identifier, "L"], [:char, "'c'"]],
                 tokens.map { |t| t[0, 2] }
  end

  def test_pp_number_admits_a_sign_only_after_an_exponent
    assert_equal [[:pp_number, "1e+5"], [:pp_number, "1e5"], [:punct, "+"],
                  [:pp_number, "0x1p+2"], [:pp_number, ".5"]],
                 core_tokens("1e+5 1e5+ 0x1p+2 .5\n").map { |t| t[0, 2] }
  end

  def test_punctuators_match_longest_first
    assert_equal [%w[<<=], %w[...], %w[##], %w[->], %w[.]],
                 core_tokens("<<= ... ## -> .\n").map { |t| [t[1]] }
  end

  def test_space_before_distinguishes_function_like_from_object_macro
    tokens = scan("#define F(x)\n#define G (x)\n")
    f_paren = tokens[3]
    g_paren = tokens[10]
    assert_equal ["(", false], [f_paren.text, f_paren.space_before]
    assert_equal ["(", true], [g_paren.text, g_paren.space_before]
  end

  def test_a_splice_alone_does_not_count_as_space
    tokens = scan("+\\\n-\n")
    minus = tokens[1]
    assert_equal ["-", false], [minus.text, minus.space_before]
  end

  def test_block_comment_emits_its_newlines_with_true_positions
    tokens = scan("int a; /* one\ntwo */ int b;\n")
    newline = tokens.find { |t| t.type == :newline }
    assert_equal [1, 14], [newline.line, newline.column]
    b = tokens.find { |t| t.text == "b" }
    assert_equal [2, 12], [b.line, b.column]
  end

  def test_unterminated_block_comment_reports_the_opening_position
    error = assert_raises(Rubycc::CompileError) { scan("int a;\n  /* never ends\n") }
    assert_match(/unterminated block comment/, error.message)
    assert_equal [2, 3], [error.line, error.column]
  end

  def test_line_comment_continues_across_a_splice
    assert_equal [[:identifier, "int"], [:identifier, "b"], [:punct, ";"]],
                 core_tokens("// comment\\\nstill comment\nint b;\n").map { |t| t[0, 2] }
  end

  def test_multibyte_characters_count_as_single_columns
    x = scan("/* あ */ int x;\n").find { |t| t.text == "x" }
    assert_equal [1, 13], [x.line, x.column]
  end
end
