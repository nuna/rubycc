# frozen_string_literal: true

require_relative "test_helper"

class TestPreprocessor < Minitest::Test
  include ExecutionHelper

  def pp(source, filename: "test.c")
    Rubycc::Preprocess::Preprocessor.new.run(source, filename: filename)
  end

  def lex(source, filename: "test.c")
    Rubycc::Front::Lexer.new(source, filename: filename).tokenize
  end

  # The full attribute tuple of a token, so equivalence can be asserted as a
  # single array comparison (positions, base and suffix included).
  def token_tuple(token)
    %i[type value base suffix line column source_line filename].map do |field|
      token.public_send(field)
    end
  end

  # Proves a preprocessed stream is indistinguishable from the streaming lexer's.
  def assert_same_tokens(source)
    expected = lex(source).map { |t| token_tuple(t) }
    actual = pp(source).map { |t| token_tuple(t) }
    assert_equal expected, actual, "token streams differ for #{source.inspect}"
  end

  # --- equivalence with the streaming lexer on directive-free source ---------

  def test_matches_lexer_on_a_full_function
    assert_same_tokens("int main(void) { return 42; }")
  end

  def test_matches_lexer_across_multiple_lines
    assert_same_tokens("int add(int a, int b) {\n  return a + b;\n}\n")
  end

  def test_matches_lexer_on_numeric_variety
    assert_same_tokens("int x = 0x1F + 010 + 42u + 1.5f + .5 + 1e3;")
  end

  def test_matches_lexer_on_literals_and_operators
    assert_same_tokens(%(char *s = "a\\tb"; int c = 'x'; int y = a <<= b ? c : d;))
  end

  def test_matches_lexer_with_comments
    source = "int a; // trailing\nint /* inline */ b; /* spanning\ncomment */ int c;"
    assert_same_tokens(source)
  end

  def test_matches_lexer_on_empty_source
    assert_same_tokens("")
    assert_same_tokens("   \n  \n")
  end

  # --- line continuation (translation phase 2) -------------------------------

  def test_continuation_between_tokens
    # A backslash-newline between (whitespace-separated) tokens joins the
    # logical line; the token after it keeps its own physical line.
    tokens = pp("int \\\nmain").reject(&:eof?)
    assert_equal %i[keyword ident], tokens.map(&:type)
    assert_equal %w[int main], tokens.map(&:value)
    assert_equal [1, 2], tokens.map(&:line)
    assert_equal [1, 1], tokens.map(&:column)
  end

  def test_continuation_inside_identifier
    # A token split across a continuation is spliced into one, reported at its
    # starting position.
    tokens = pp("int ma\\\nin;").reject(&:eof?)
    assert_equal %i[keyword ident punct], tokens.map(&:type)
    assert_equal ["int", "main", ";"], tokens.map(&:value)
    ident = tokens[1]
    assert_equal 1, ident.line     # begins on the first physical line
    assert_equal 5, ident.column
  end

  def test_continuation_inside_string_literal
    tokens = pp(%("ab\\\ncd")).reject(&:eof?)
    assert_equal [:string], tokens.map(&:type)
    assert_equal "abcd".b, tokens[0].value
    assert_equal 1, tokens[0].line
  end

  def test_continuation_at_end_of_line_comment
    # A backslash at the end of a // comment continues the comment onto the next
    # physical line, so the "code" there is still commented out (gcc behavior).
    tokens = pp("int a; // comment \\\nint b;").reject(&:eof?)
    assert_equal ["int", "a", ";"], tokens.map(&:value)
  end

  # --- block comments spanning newlines --------------------------------------

  def test_block_comment_newline_preserves_line_numbers
    source = "int a;\n/* line two\nline three */\nint b;"
    tokens = pp(source).reject(&:eof?)
    values = tokens.map(&:value)
    assert_equal ["int", "a", ";", "int", "b", ";"], values
    b = tokens.find { |t| t.value == "b" }
    assert_equal 4, b.line      # the comment's two newlines were counted
    assert_equal "int b;", b.source_line
  end

  # --- diagnostics -----------------------------------------------------------

  def test_invalid_directive_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#nonsense\nint x;") }
    assert_match(/invalid preprocessing directive '#nonsense'/, error.description)
    assert_equal 1, error.line
  end

  def test_null_directive_is_ignored
    # A "#" alone on a line does nothing (6.10p2); the surrounding code survives.
    tokens = pp("#\nint x;").reject(&:eof?)
    assert_equal %i[keyword ident punct], tokens.map(&:type)
    assert_equal ["int", "x", ";"], tokens.map(&:value)
  end

  def test_stray_hash_in_program_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("int x = a # b;") }
    assert_match(/stray '#' in program/, error.description)
    assert_equal 1, error.line
    assert_equal 11, error.column
  end

  def test_unterminated_block_comment_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("int a; /* oops") }
    assert_match(/unterminated block comment/, error.description)
  end

  def test_unterminated_string_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp('char *s = "oops;') }
    assert_match(/unterminated string literal/, error.description)
  end

  def test_stray_at_character_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("int x = @;") }
    assert_match(/unexpected character/, error.description)
  end

  # --- object-like macros: #define, #undef, expansion ------------------------

  def test_simple_object_macro_is_substituted
    tokens = pp("#define ANSWER 42\nint x = ANSWER;").reject(&:eof?)
    assert_equal [:keyword, :ident, :punct, :num, :punct], tokens.map(&:type)
    assert_equal ["int", "x", "=", 42, ";"], tokens.map(&:value)
  end

  def test_macro_replacement_can_span_several_tokens
    tokens = pp("#define SUM 1 + 2 + 3\nint x = SUM;").reject(&:eof?)
    values = tokens.map(&:value)
    assert_equal ["int", "x", "=", 1, "+", 2, "+", 3, ";"], values
  end

  def test_empty_macro_expands_to_nothing
    tokens = pp("#define BLANK\nint BLANK y;").reject(&:eof?)
    assert_equal ["int", "y", ";"], tokens.map(&:value)
  end

  def test_nested_macros_are_rescanned
    source = "#define A B\n#define B C\n#define C 7\nint x = A;"
    tokens = pp(source).reject(&:eof?)
    assert_equal ["int", "x", "=", 7, ";"], tokens.map(&:value)
  end

  def test_self_referential_macro_stops_and_keeps_the_name
    tokens = pp("#define A A\nint x = A;").reject(&:eof?)
    assert_equal [:keyword, :ident, :punct, :ident, :punct], tokens.map(&:type)
    assert_equal ["int", "x", "=", "A", ";"], tokens.map(&:value)
  end

  def test_mutually_referential_macros_stop
    # A -> B -> A halts when A is met again while already expanding.
    tokens = pp("#define A B\n#define B A\nint x = A;").reject(&:eof?)
    assert_equal ["int", "x", "=", "A", ";"], tokens.map(&:value)
  end

  def test_undef_stops_expansion
    source = "#define A 1\nint p = A;\n#undef A\nint q = A;"
    tokens = pp(source).reject(&:eof?)
    values = tokens.map(&:value)
    # The first use expands, the second (after #undef) stays an identifier.
    assert_equal ["int", "p", "=", 1, ";", "int", "q", "=", "A", ";"], values
  end

  def test_undef_of_unknown_macro_is_allowed
    tokens = pp("#undef NEVER_DEFINED\nint x;").reject(&:eof?)
    assert_equal ["int", "x", ";"], tokens.map(&:value)
  end

  def test_identical_redefinition_is_allowed
    tokens = pp("#define A 1\n#define A 1\nint x = A;").reject(&:eof?)
    assert_equal ["int", "x", "=", 1, ";"], tokens.map(&:value)
  end

  def test_conflicting_redefinition_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define A 1\n#define A 2\n") }
    assert_match(/macro 'A' redefined/, error.description)
    assert_equal 2, error.line
  end

  def test_function_like_macro_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define F(x) x\n") }
    assert_match(/function-like macros are not supported yet/, error.description)
  end

  def test_object_macro_replacement_may_begin_with_parenthesis
    # A space before "(" makes it part of the replacement, not a parameter list.
    tokens = pp("#define X (1)\nint y = X;").reject(&:eof?)
    assert_equal ["int", "y", "=", "(", 1, ")", ";"], tokens.map(&:value)
  end

  def test_expanded_token_is_located_at_the_use_site
    # The "42" comes from line 1's #define but is diagnosed at its use on line 2.
    tokens = pp("#define ANSWER 42\nint x = ANSWER;").reject(&:eof?)
    answer = tokens.find { |t| t.value == 42 }
    assert_equal 2, answer.line
    assert_equal "int x = ANSWER;", answer.source_line
  end

  # --- #include --------------------------------------------------------------

  def test_quote_include_reads_relative_to_the_includer
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "inc.h"), "int included = 7;\n")
      main = File.join(dir, "main.c")
      tokens = pp("#include \"inc.h\"\nint here;", filename: main).reject(&:eof?)
      assert_equal ["int", "included", "=", 7, ";", "int", "here", ";"],
                   tokens.map(&:value)
    end
  end

  def test_angle_include_searches_the_include_path
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "sys.h"), "int fromsys;\n")
      tokens = Rubycc::Preprocess::Preprocessor.new
                 .run("#include <sys.h>\nint here;", filename: "main.c", include_paths: [dir])
                 .reject(&:eof?)
      assert_equal ["int", "fromsys", ";", "int", "here", ";"], tokens.map(&:value)
    end
  end

  def test_nested_include_shares_the_macro_table
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "outer.h"), "#include \"inner.h\"\nint after = VAL;\n")
      File.write(File.join(dir, "inner.h"), "#define VAL 9\n")
      main = File.join(dir, "main.c")
      tokens = pp("#include \"outer.h\"\n", filename: main).reject(&:eof?)
      assert_equal ["int", "after", "=", 9, ";"], tokens.map(&:value)
    end
  end

  def test_included_tokens_report_the_header_location
    Dir.mktmpdir do |dir|
      header = File.join(dir, "inc.h")
      File.write(header, "\nint from_header;\n")
      main = File.join(dir, "main.c")
      tokens = pp("#include \"inc.h\"\n", filename: main).reject(&:eof?)
      from = tokens.find { |t| t.value == "from_header" }
      assert_equal header, from.filename   # N3: points at the includee
      assert_equal 2, from.line
    end
  end

  def test_missing_include_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#include \"nope.h\"\n") }
    assert_match(%r{nope\.h: No such file or directory}, error.description)
    assert_equal 1, error.line
  end

  def test_self_including_header_hits_the_depth_limit
    Dir.mktmpdir do |dir|
      loop_h = File.join(dir, "loop.h")
      File.write(loop_h, "#include \"loop.h\"\n")
      main = File.join(dir, "main.c")
      error = assert_raises(Rubycc::CompileError) { pp("#include \"loop.h\"\n", filename: main) }
      assert_match(/#include nested too deeply/, error.description)
    end
  end

  # --- #error ----------------------------------------------------------------

  def test_error_directive_reports_its_message_and_line
    error = assert_raises(Rubycc::CompileError) { pp("int x;\n#error stop right here\n") }
    assert_match(/stop right here/, error.description)
    assert_equal 2, error.line
  end

  # --- conditional inclusion: #if / #ifdef / #ifndef / #elif / #else / #endif -

  def test_if_true_keeps_its_group
    tokens = pp("#if 1\nint a;\n#endif").reject(&:eof?)
    assert_equal ["int", "a", ";"], tokens.map(&:value)
  end

  def test_if_false_drops_its_group
    tokens = pp("#if 0\nint a;\n#endif\nint b;").reject(&:eof?)
    assert_equal ["int", "b", ";"], tokens.map(&:value)
  end

  def test_if_evaluates_arithmetic_and_comparison
    tokens = pp("#if 2 * 3 + 1 == 7\nint a;\n#endif").reject(&:eof?)
    assert_equal ["int", "a", ";"], tokens.map(&:value)
  end

  def test_elif_chain_selects_the_first_true_group
    source = "#if 0\nint a;\n#elif 0\nint b;\n#elif 1\nint c;\n#else\nint d;\n#endif"
    assert_equal ["int", "c", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_else_group_runs_when_no_branch_taken
    source = "#if 0\nint a;\n#elif 0\nint b;\n#else\nint c;\n#endif"
    assert_equal ["int", "c", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_ifdef_and_ifndef_consult_the_macro_table
    source = "#define ON\n#ifdef ON\nint a;\n#endif\n#ifndef OFF\nint b;\n#endif"
    assert_equal ["int", "a", ";", "int", "b", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_defined_operator_in_both_forms
    source = "#define M 1\n#if defined M && defined(M)\nint a;\n#endif\n" \
             "#if defined ABSENT\nint b;\n#endif"
    assert_equal ["int", "a", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_unexpanded_identifiers_are_zero
    # An identifier that is not a macro evaluates to 0 (6.10.1p4), so the group
    # is dropped; the same name still becomes an ordinary identifier in code.
    tokens = pp("#if UNDEFINED_NAME\nint a;\n#endif\nint UNDEFINED_NAME;").reject(&:eof?)
    assert_equal ["int", "UNDEFINED_NAME", ";"], tokens.map(&:value)
  end

  def test_macro_is_expanded_inside_the_expression
    source = "#define WIDTH 4\n#if WIDTH * 2 == 8\nint a;\n#endif"
    assert_equal ["int", "a", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_conditional_operator_in_if_expression
    tokens = pp("#if 1 ? 0 : 1\nint a;\n#else\nint b;\n#endif").reject(&:eof?)
    assert_equal ["int", "b", ";"], tokens.map(&:value)
  end

  def test_nested_conditionals
    source = "#if 1\n#if 0\nint a;\n#else\nint b;\n#endif\n#endif"
    assert_equal ["int", "b", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_skipped_group_ignores_malformed_content
    # A skipped group's contents are dropped whole: an unknown directive, a bare
    # "#", an unbalanced token — none is diagnosed, matching gcc.
    source = "#if 0\n#nonsense\n#\n@ not even tokens? maybe\n#define BROKEN(\n#else\nint a;\n#endif"
    assert_equal ["int", "a", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_undef_then_redefine_changes_the_condition
    source = "#define V 1\n#if V\nint a;\n#endif\n#undef V\n#define V 0\n#if V\nint b;\n#else\nint c;\n#endif"
    assert_equal ["int", "a", ";", "int", "c", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_endif_without_if_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("int x;\n#endif") }
    assert_match(/#endif without #if/, error.description)
    assert_equal 2, error.line
  end

  def test_elif_after_else_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#if 0\n#else\n#elif 1\n#endif") }
    assert_match(/#elif after #else/, error.description)
    assert_equal 3, error.line
  end

  def test_unterminated_conditional_points_at_the_if
    error = assert_raises(Rubycc::CompileError) { pp("int x;\n#if 1\nint y;") }
    assert_match(/unterminated conditional directive/, error.description)
    assert_equal 2, error.line
  end

  def test_if_with_no_expression_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#if\nint x;\n#endif") }
    assert_match(/#if with no expression/, error.description)
  end

  def test_division_by_zero_in_if_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#if 1 / 0\n#endif") }
    assert_match(/division by zero/, error.description)
  end

  def test_floating_constant_in_if_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#if 1.5\n#endif") }
    assert_match(/floating constant in preprocessor expression/, error.description)
  end

  def test_bad_defined_operator_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#if defined 3\n#endif") }
    assert_match(/operator 'defined' requires an identifier/, error.description)
  end

  # --- gcc -E differential ---------------------------------------------------

  # Each source exercises a facet of translation phase 4; the token stream
  # rubycc produces must be indistinguishable (by type and value, base and
  # suffix on numbers) from lexing gcc's own "-E -P" output. Positions differ
  # between the two paths and are deliberately not compared.
  PP_DIFFERENTIAL_SOURCES = [
    # Object macros: a plain one, and one expanded by rescanning nested macros.
    "#define ANSWER 42\nint a = ANSWER;\n",
    "#define A 6\n#define B 7\n#define AREA (A * B)\nint a = AREA;\n",
    # #if 0 excludes a group, #if 1 keeps one.
    "#if 0\nint dropped;\n#endif\nint kept;\n",
    "#if 1\nint kept;\n#else\nint dropped;\n#endif\n",
    # Arithmetic, comparison, logical and conditional operators in #if.
    "#if (2 + 3) * 4 == 20 && 5 % 2 == 1\nint a;\n#else\nint b;\n#endif\n",
    "#if 1 << 4 > 8 ? 1 : 0\nint a;\n#endif\n",
    # defined in parenthesized and bare forms.
    "#define HAVE 1\n#if defined(HAVE) && defined NOPE\nint a;\n#else\nint b;\n#endif\n",
    # #ifdef / #ifndef against the macro table.
    "#define FLAG\n#ifdef FLAG\nint a;\n#endif\n#ifndef OTHER\nint b;\n#endif\n",
    # An #elif chain and nested conditionals.
    "#if 0\nint a;\n#elif 0\nint b;\n#elif 1\nint c;\n#else\nint d;\n#endif\n",
    "#if 1\n#if 0\nint a;\n#else\nint b;\n#endif\nint c;\n#endif\n",
    # #undef then redefine, and a skipped group full of content gcc discards.
    "#define V 1\n#if V\nint a;\n#endif\n#undef V\n#define V 2\nint b = V;\n",
    "#if 0\n#weird\n#\nnot ; real @ tokens\n#else\nint ok;\n#endif\n"
  ].freeze

  def test_matches_gcc_preprocessor_output
    PP_DIFFERENTIAL_SOURCES.each do |source|
      expected = lex(preprocess_with_gcc(source)).map { |t| pp_signature(t) }
      actual = pp(source).map { |t| pp_signature(t) }
      assert_equal expected, actual, "token streams differ from gcc -E for #{source.inspect}"
    end
  end

  private

  # A token's identity for the gcc differential: what it is and what it means,
  # with the numeric base/suffix that distinguish integer constants, but no
  # source position (which the two preprocessing paths legitimately disagree on).
  def pp_signature(token)
    [token.type, token.value, token.base, token.suffix]
  end
end
