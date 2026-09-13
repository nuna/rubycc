# frozen_string_literal: true

require_relative "test_helper"

# Regression tests for translation phase 1's line-terminator mapping
# (C11 5.1.1.2): CRLF and a lone CR (the classic Mac OS 9 line ending) must
# fold to a single new-line character before phase 2 (backslash-newline
# splicing) ever looks at the text, matching gcc (measured 2026-09-13, gcc
# 13.3; see issues/crlf-line-splice.md). Every fixture here builds its CRLF/CR
# bytes explicitly with String#b — never relying on the file's own line
# endings, which git could normalize away.
class TestCrlfLineSplice < Minitest::Test
  include ExecutionHelper

  CRLF = "\r\n".b
  CR = "\r".b

  def scan(source)
    Rubycc::Preprocess::Scanner.new(source, filename: "crlf.c").scan
  end

  def core_tokens(source)
    scan(source).reject { |t| t.type == :newline || t.type == :eof }
                .map { |t| [t.type, t.text, t.line, t.column] }
  end

  # --- Scanner-level: translation phase 1/2 mechanics ----------------------

  def test_splice_joins_an_identifier_across_a_crlf_line_ending
    tokens = scan("long ab\\#{CRLF}cd = 1;#{CRLF}")
    joined = tokens[1]
    assert_equal [:identifier, "abcd", 1, 6], [joined.type, joined.text, joined.line, joined.column]
    eq = tokens[2]
    assert_equal [:punct, "=", 2, 4], [eq.type, eq.text, eq.line, eq.column]
  end

  def test_splice_joins_an_identifier_across_a_lone_cr_line_ending
    tokens = scan("long ab\\#{CR}cd = 1;#{CR}")
    joined = tokens[1]
    assert_equal [:identifier, "abcd", 1, 6], [joined.type, joined.text, joined.line, joined.column]
    eq = tokens[2]
    assert_equal [:punct, "=", 2, 4], [eq.type, eq.text, eq.line, eq.column]
  end

  def test_a_plain_crlf_line_ending_still_ends_a_line_comment
    tokens = core_tokens("// comment#{CRLF}int b;#{CRLF}")
    assert_equal [[:identifier, "int", 2, 1], [:identifier, "b", 2, 5], [:punct, ";", 2, 6]], tokens
  end

  def test_a_lone_cr_line_ending_ends_a_line_comment
    tokens = core_tokens("// comment#{CR}int b;#{CR}")
    assert_equal [[:identifier, "int", 2, 1], [:identifier, "b", 2, 5], [:punct, ";", 2, 6]], tokens
  end

  def test_a_lone_cr_line_ending_advances_the_line_count_once
    eof = scan("a;#{CR}b;#{CR}").last
    assert_equal [:eof, 3, 1], [eof.type, eof.line, eof.column]
  end

  # A raw CR byte that is not a line terminator at all — one sitting inside a
  # string literal — is still mapped to a new-line by phase 1, so it ends the
  # literal exactly as it does for gcc, which turns "missing terminating"
  # into a hard error (measured 2026-09-13).
  def test_a_raw_cr_byte_inside_a_string_literal_ends_it_like_gcc
    assert_includes core_tokens("char *s = \"a#{CR}b\";\n"), [:string, "\"a", 1, 11]
  end

  # The two-character escape "\r" (backslash then the letter r) has no CR
  # byte in it at all, so phase 1's CR mapping never touches it: the string's
  # spelling — and therefore its bytes once converted — survive unchanged.
  def test_the_backslash_r_escape_is_not_a_raw_cr_and_survives_untouched
    assert_includes core_tokens('char *s = "a\r\nb";' + "\n"), [:string, '"a\r\nb"', 1, 11]
  end

  # --- End-to-end: the issue's three minimal repros, gcc-differential ------

  def test_plain_crlf_file_compiles_and_runs_like_gcc
    source = "int main(void) { return 0; }#{CRLF}"
    assert_c_exit_status(0, source, compiler: :gcc)
    assert_c_exit_status(0, source, compiler: :rubycc)
  end

  def test_string_literal_continued_with_backslash_across_crlf
    source = +"static const char s[] =#{CRLF}"
    source << "    \"ab\" \\#{CRLF}"
    source << "    \"cd\";#{CRLF}"
    source << "int main(void) { return s[0] == 'a' ? 0 : 1; }#{CRLF}"
    assert_c_exit_status(0, source, compiler: :gcc)
    assert_c_exit_status(0, source, compiler: :rubycc)
  end

  def test_define_continued_with_backslash_across_crlf
    source = +"#define ADD(a, b) \\#{CRLF}"
    source << "    ((a) + (b))#{CRLF}"
    source << "int main(void) { return ADD(1, 2) - 3; }#{CRLF}"
    assert_c_exit_status(0, source, compiler: :gcc)
    assert_c_exit_status(0, source, compiler: :rubycc)
  end

  # murmurhash3 0.1.7's ext/murmurhash3/murmur3.c continues a string literal
  # this way, with CRLF endings throughout (2026-09-13).
  def test_murmurhash3_style_string_continuation_over_crlf
    source = +"static const char *hex =#{CRLF}"
    source << "        \"000102030405060708090a0b0c0d0e0f\" \\#{CRLF}"
    source << "        \"101112131415161718191a1b1c1d1e1f\";#{CRLF}"
    source << "int main(void) { return hex[0] == '0' ? 0 : 1; }#{CRLF}"
    assert_c_exit_status(0, source, compiler: :gcc)
    assert_c_exit_status(0, source, compiler: :rubycc)
  end

  # A backslash continuation whose line ending is a lone CR (no LF at all) —
  # the old Mac OS 9 convention — splices exactly like "\\\n" under gcc.
  def test_define_continued_with_backslash_across_a_lone_cr
    source = +"#define ADD(a, b) \\#{CR}"
    source << "    ((a) + (b))#{CR}"
    source << "int main(void) { return ADD(1, 2) - 3; }#{CR}"
    assert_c_exit_status(0, source, compiler: :gcc)
    assert_c_exit_status(0, source, compiler: :rubycc)
  end
end
