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

  # --- function-like macros: substitution, rescanning, painting --------------

  def test_function_macro_substitutes_its_argument
    tokens = pp("#define SQR(x) ((x) * (x))\nint y = SQR(3);").reject(&:eof?)
    values = tokens.map(&:value)
    assert_equal ["int", "y", "=", "(", "(", 3, ")", "*", "(", 3, ")", ")", ";"], values
  end

  def test_function_macro_with_several_parameters
    tokens = pp("#define ADD(a, b) a + b\nint y = ADD(4, 5);").reject(&:eof?)
    assert_equal ["int", "y", "=", 4, "+", 5, ";"], tokens.map(&:value)
  end

  def test_argument_may_contain_a_comma_inside_parentheses
    # The comma inside "(a, b)" belongs to the first argument, not the call, so
    # "x y" reproduces the parenthesized pair followed by "c".
    tokens = pp("#define PICK(x, y) x y\nint z = PICK((a, b), c);").reject(&:eof?)
    assert_equal ["int", "z", "=", "(", "a", ",", "b", ")", "c", ";"], tokens.map(&:value)
  end

  def test_empty_argument_expands_to_nothing
    tokens = pp("#define WRAP(x) [ x ]\nint y = WRAP();").reject(&:eof?)
    assert_equal ["int", "y", "=", "[", "]", ";"], tokens.map(&:value)
  end

  def test_parameterless_macro_takes_no_arguments
    tokens = pp("#define ANSWER() 42\nint y = ANSWER();").reject(&:eof?)
    assert_equal ["int", "y", "=", 42, ";"], tokens.map(&:value)
  end

  def test_invocation_may_span_newlines
    tokens = pp("#define ADD(a, b) a + b\nint y = ADD(1,\n2);").reject(&:eof?)
    assert_equal ["int", "y", "=", 1, "+", 2, ";"], tokens.map(&:value)
  end

  def test_macro_name_without_parenthesis_is_a_plain_identifier
    # A function-like macro name not followed by "(" is left as an identifier
    # (6.10.3p10), so it can be used as an ordinary name.
    tokens = pp("#define F(x) x\nint F;").reject(&:eof?)
    assert_equal [:keyword, :ident, :punct], tokens.map(&:type)
    assert_equal ["int", "F", ";"], tokens.map(&:value)
  end

  def test_nested_invocation_is_expanded
    tokens = pp("#define F(x) ((x))\nint y = F(F(1));").reject(&:eof?)
    assert_equal ["int", "y", "=", "(", "(", "(", "(", 1, ")", ")", ")", ")", ";"],
                 tokens.map(&:value)
  end

  # --- painting (6.10.3.4): the four rule-driven behaviors -------------------

  def test_self_referential_function_macro_keeps_the_literal_name
    # "#define f(x) f(x)" and "f(1)": the literal "f" is painted, so the rescanned
    # "f (1)" is not a fresh call.
    tokens = pp("#define f(x) f(x)\nf(1)").reject(&:eof?)
    assert_equal [:ident, :punct, :num, :punct], tokens.map(&:type)
    assert_equal ["f", "(", 1, ")"], tokens.map(&:value)
  end

  def test_object_macro_supplies_the_name_of_a_following_call
    # "g" expands to "f", which then meets the source "(3)": a cross-boundary
    # call that yields "3".
    tokens = pp("#define g f\n#define f(x) x\ng(3)").reject(&:eof?)
    assert_equal [3], tokens.map(&:value)
  end

  def test_macro_name_from_an_argument_still_expands
    # The inner "f" arrives through the argument, so it is not painted and forms
    # a call with the source "(1)": "f(f)(1)" yields "1".
    tokens = pp("#define f(x) x\nf(f)(1)").reject(&:eof?)
    assert_equal [1], tokens.map(&:value)
  end

  def test_mutually_recursive_function_macros_terminate
    tokens = pp("#define a b(a)\n#define b(x) x\na").reject(&:eof?)
    assert_equal [:ident], tokens.map(&:type)
    assert_equal ["a"], tokens.map(&:value)
  end

  # --- __VA_ARGS__ -----------------------------------------------------------

  def test_va_args_carries_the_variable_part
    tokens = pp("#define LIST(...) __VA_ARGS__\nint a[] = { LIST(1, 2, 3) };").reject(&:eof?)
    values = tokens.map(&:value)
    assert_equal ["int", "a", "[", "]", "=", "{", 1, ",", 2, ",", 3, "}", ";"], values
  end

  def test_va_args_can_be_empty
    tokens = pp("#define CALL(...) f(__VA_ARGS__)\nint y = CALL();").reject(&:eof?)
    assert_equal ["int", "y", "=", "f", "(", ")", ";"], tokens.map(&:value)
  end

  def test_va_args_follows_named_parameters
    tokens = pp("#define LOG(head, ...) head : __VA_ARGS__\nint y = LOG(1, 2, 3);").reject(&:eof?)
    assert_equal ["int", "y", "=", 1, ":", 2, ",", 3, ";"], tokens.map(&:value)
  end

  # --- function-like macro diagnostics ---------------------------------------

  def test_too_few_arguments_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define ADD(a, b) a + b\nint y = ADD(1);") }
    assert_match(/requires exactly 2 arguments/, error.description)
  end

  def test_too_many_arguments_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define ID(x) x\nint y = ID(1, 2);") }
    assert_match(/requires exactly 1 arguments/, error.description)
  end

  def test_arguments_to_parameterless_macro_are_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define ZERO() 0\nint y = ZERO(1);") }
    assert_match(/takes just 0/, error.description)
  end

  def test_variadic_macro_requires_its_named_parameters
    error = assert_raises(Rubycc::CompileError) { pp("#define LOG(a, b, ...) a\nint y = LOG(1);") }
    assert_match(/requires at least 2 arguments/, error.description)
  end

  def test_unterminated_invocation_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define F(x) x\nint y = F(1;") }
    assert_match(/unterminated function-like macro invocation/, error.description)
  end

  def test_duplicate_parameter_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define F(a, a) a\n") }
    assert_match(/duplicate macro parameter "a"/, error.description)
  end

  def test_redefinition_with_different_parameters_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define F(a) a\n#define F(b) b\n") }
    assert_match(/macro 'F' redefined/, error.description)
    assert_equal 2, error.line
  end

  def test_redefinition_with_different_replacement_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define F(a) a\n#define F(a) a + 1\n") }
    assert_match(/macro 'F' redefined/, error.description)
  end

  def test_identical_function_macro_redefinition_is_allowed
    tokens = pp("#define F(a) a + 1\n#define F(a) a + 1\nint y = F(2);").reject(&:eof?)
    assert_equal ["int", "y", "=", 2, "+", 1, ";"], tokens.map(&:value)
  end

  # --- "#" (stringize, 6.10.3.2) ---------------------------------------------

  def test_stringize_makes_a_string_of_its_argument
    tokens = pp("#define STR(x) #x\nchar *s = STR(hello);").reject(&:eof?)
    assert_equal [:keyword, :punct, :ident, :punct, :string, :punct], tokens.map(&:type)
    assert_equal "hello".b, tokens[4].value
  end

  def test_stringize_normalizes_internal_whitespace
    # Interior runs of whitespace collapse to a single space, with none at the
    # ends (6.10.3.2p2).
    tokens = pp("#define STR(x) #x\nchar *s = STR(  a  +  b  );").reject(&:eof?)
    assert_equal "a + b".b, tokens.find { |t| t.type == :string }.value
  end

  def test_stringize_escapes_quotes_and_backslashes
    # A " or \ inside a string/char token of the argument is backslash-escaped so
    # the spelling stays a valid literal (6.10.3.2p2): the argument "a\tb" becomes
    # the literal "\"a\\tb\"", whose decoded value is the six characters "a\tb".
    tokens = pp(%(#define STR(x) #x\nchar *s = STR("a\\tb");)).reject(&:eof?)
    assert_equal %q{"a\tb"}.b, tokens.find { |t| t.type == :string }.value
  end

  def test_stringize_uses_the_raw_unexpanded_argument
    # "#x" stringizes the argument as written, never its expansion (6.10.3.2p2).
    tokens = pp("#define N 5\n#define STR(x) #x\nchar *s = STR(N);").reject(&:eof?)
    assert_equal "N".b, tokens.find { |t| t.type == :string }.value
  end

  def test_stringize_of_va_args_keeps_the_comma_spelling
    # #__VA_ARGS__ reproduces the variable part verbatim, commas and their
    # spacing included (matching gcc: "a ,b" here).
    tokens = pp("#define S(...) #__VA_ARGS__\nchar *s = S(a ,b);").reject(&:eof?)
    assert_equal "a ,b".b, tokens.find { |t| t.type == :string }.value
  end

  def test_hash_in_object_macro_is_an_ordinary_token
    # 6.10.3.2 constrains "#" only in function-like macros; in an object macro it
    # is a plain token, which then survives to conversion as a stray "#".
    error = assert_raises(Rubycc::CompileError) { pp("#define H #x\nint y = H;") }
    assert_match(/stray '#' in program/, error.description)
  end

  def test_hash_not_followed_by_a_parameter_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define STR(x) # y\n") }
    assert_match(/'#' is not followed by a macro parameter/, error.description)
  end

  # --- "##" (paste, 6.10.3.3) ------------------------------------------------

  def test_paste_joins_two_identifiers
    tokens = pp("#define CAT(a, b) a ## b\nint CAT(foo, bar);").reject(&:eof?)
    assert_equal ["int", "foobar", ";"], tokens.map(&:value)
  end

  def test_paste_joins_number_fragments
    tokens = pp("#define CAT(a, b) a ## b\nint x = CAT(12, 3);").reject(&:eof?)
    assert_equal ["int", "x", "=", 123, ";"], tokens.map(&:value)
  end

  def test_paste_works_in_an_object_macro
    tokens = pp("#define J a ## b\nint J;").reject(&:eof?)
    assert_equal ["int", "ab", ";"], tokens.map(&:value)
  end

  def test_paste_chains_left_to_right
    tokens = pp("#define J(a, b, c) a ## b ## c\nint x = J(1, 2, 3);").reject(&:eof?)
    assert_equal ["int", "x", "=", 123, ";"], tokens.map(&:value)
  end

  def test_paste_with_an_empty_left_operand_keeps_the_right
    tokens = pp("#define P(a, b) a ## b\nint P(, y);").reject(&:eof?)
    assert_equal ["int", "y", ";"], tokens.map(&:value)
  end

  def test_paste_with_an_empty_right_operand_keeps_the_left
    tokens = pp("#define P(a, b) a ## b\nint P(x, );").reject(&:eof?)
    assert_equal ["int", "x", ";"], tokens.map(&:value)
  end

  def test_paste_of_two_empty_operands_yields_nothing
    tokens = pp("#define P(a, b) [ a ## b ]\nint x[] = { P(, ) };").reject(&:eof?)
    assert_equal ["int", "x", "[", "]", "=", "{", "[", "]", "}", ";"], tokens.map(&:value)
  end

  def test_paste_that_forms_a_macro_name_is_rescanned
    # The pasted "HELLO" is a fresh token, so rescanning expands it (6.10.3.4).
    tokens = pp("#define HELLO 42\n#define GLUE(a, b) a ## b\nint x = GLUE(HEL, LO);").reject(&:eof?)
    assert_equal ["int", "x", "=", 42, ";"], tokens.map(&:value)
  end

  def test_paste_that_forms_the_macro_name_is_painted
    # A paste re-forming the pasting macro's own name is painted, so it does not
    # re-expand and stays an identifier.
    tokens = pp("#define f(a, b) a ## b\nf(f, x)").reject(&:eof?)
    assert_equal [:ident], tokens.map(&:type)
    assert_equal ["fx"], tokens.map(&:value)
  end

  def test_invalid_paste_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define CAT(a, b) a ## b\nint x = CAT(1, +);") }
    assert_match(/pasting "1" and "\+" does not give a valid preprocessing token/, error.description)
  end

  def test_paste_at_the_start_of_a_replacement_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define BAD(x) ## x\n") }
    assert_match(/'##' cannot appear at either end of a macro expansion/, error.description)
  end

  def test_paste_at_the_end_of_a_replacement_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define BAD(x) x ##\n") }
    assert_match(/'##' cannot appear at either end of a macro expansion/, error.description)
  end

  def test_hash_and_paste_operands_mix_raw_and_expanded
    # In "#x + x", "#x" takes the raw argument while the lone "x" is expanded, so
    # F(N) with N=5 yields the string "N" plus the value 5.
    tokens = pp("#define N 5\n#define F(x) #x + x\nint a[] = { F(N) };").reject(&:eof?)
    values = tokens.map(&:value)
    assert_equal ["int", "a", "[", "]", "=", "{", "N".b, "+", 5, "}", ";"], values
  end

  # --- compiler-supplied macros (6.10.8) -------------------------------------

  def test_file_and_line_report_the_use_site
    tokens = pp("char *f = __FILE__;\nint n = __LINE__;", filename: "unit.c").reject(&:eof?)
    assert_equal "unit.c".b, tokens.find { |t| t.type == :string }.value
    assert_equal 2, tokens.find { |t| t.type == :num }.value
  end

  def test_line_inside_an_include_reports_the_header
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "inc.h"), "\n\nint marker = __LINE__;\n")
      main = File.join(dir, "main.c")
      tokens = pp("#include \"inc.h\"\n", filename: main).reject(&:eof?)
      assert_equal ["int", "marker", "=", 3, ";"], tokens.map(&:value)
    end
  end

  def test_file_inside_an_include_reports_the_header
    Dir.mktmpdir do |dir|
      header = File.join(dir, "inc.h")
      File.write(header, "char *hf = __FILE__;\n")
      main = File.join(dir, "main.c")
      tokens = pp("#include \"inc.h\"\n", filename: main).reject(&:eof?)
      assert_equal header.b, tokens.find { |t| t.type == :string }.value
    end
  end

  def test_stdc_conformance_macros
    tokens = pp("int a = __STDC__; long b = __STDC_VERSION__; int c = __RUBYCC__;").reject(&:eof?)
    nums = tokens.select { |t| t.type == :num }.map(&:value)
    assert_equal [1, 201112, 1], nums
  end

  def test_stdc_version_carries_the_long_suffix
    version = pp("__STDC_VERSION__").find { |t| t.type == :num }
    assert_equal "l", version.suffix
  end

  def test_defining_a_builtin_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define __LINE__ 5\n") }
    assert_match(/cannot define builtin macro "__LINE__"/, error.description)
  end

  def test_undefining_a_builtin_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#undef __FILE__\n") }
    assert_match(/cannot undefine builtin macro "__FILE__"/, error.description)
  end

  def test_defining_the_defined_operator_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#define defined 1\n") }
    assert_match(/"defined" cannot be used as a macro name/, error.description)
  end

  # --- predefined target macros -----------------------------------------------

  def test_x86_64_selects_its_ifdef_branch
    source = "#ifdef __x86_64__\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_lp64_expands_to_one
    tokens = pp("int a = __LP64__; int b = _LP64;").reject(&:eof?)
    assert_equal [1, 1], tokens.select { |t| t.type == :num }.map(&:value)
  end

  def test_linux_and_kin_are_predefined
    %w[__amd64__ __linux__ __gnu_linux__ __unix__ __ELF__ __STDC_HOSTED__].each do |name|
      source = "#ifdef #{name}\nint yes;\n#else\nint no;\n#endif"
      assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value),
                   "expected #{name} to be predefined"
    end
  end

  def test_linux_may_be_undefined_unlike_a_builtin
    # Unlike __FILE__ and kin, a predefined target macro is an ordinary
    # #define'd entry: #undef is allowed, matching gcc.
    source = "#undef __linux__\n#ifdef __linux__\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "no", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_gnuc_is_not_predefined
    # DESIGN R7: no gcc-compatibility macro, so a header cannot select a
    # gcc-specific path through it.
    source = "#ifdef __GNUC__\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "no", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_non_reserved_target_spellings_are_absent
    # gcc drops the non-reserved forms ("linux", "unix", "i386") under
    # -std=c11; only the reserved __..__ spellings are predefined here.
    source = "#ifdef linux\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "no", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  # --- __has_include / __has_attribute / __has_builtin (in #if) --------------

  def test_has_include_detects_a_present_header
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "there.h"), "int x;\n")
      main = File.join(dir, "main.c")
      source = "#if __has_include(\"there.h\")\nint yes;\n#else\nint no;\n#endif"
      assert_equal ["int", "yes", ";"], pp(source, filename: main).reject(&:eof?).map(&:value)
    end
  end

  def test_has_include_reports_a_missing_header_as_zero
    Dir.mktmpdir do |dir|
      main = File.join(dir, "main.c")
      source = "#if __has_include(\"gone.h\")\nint yes;\n#else\nint no;\n#endif"
      assert_equal ["int", "no", ";"], pp(source, filename: main).reject(&:eof?).map(&:value)
    end
  end

  def test_has_include_angle_form_searches_the_include_path
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "sys.h"), "int x;\n")
      source = "#if __has_include(<sys.h>)\nint yes;\n#else\nint no;\n#endif"
      tokens = Rubycc::Preprocess::Preprocessor.new
                 .run(source, filename: "main.c", include_paths: [dir]).reject(&:eof?)
      assert_equal ["int", "yes", ";"], tokens.map(&:value)
    end
  end

  def test_has_attribute_is_true_for_the_layout_attributes
    source = "#if __has_attribute(packed)\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_has_attribute_is_true_for_aligned
    source = "#if __has_attribute(aligned)\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_has_attribute_normalizes_the_underscore_spelling
    source = "#if __has_attribute(__aligned__)\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_has_attribute_is_false_for_an_unknown_attribute
    source = "#if __has_attribute(noreturn)\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "no", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_has_builtin_recognizes_the_varargs_intrinsics
    source = "#if __has_builtin(__builtin_va_start)\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_has_builtin_recognizes_expect_and_alloca
    %w[__builtin_expect __builtin_alloca].each do |builtin|
      source = "#if __has_builtin(#{builtin})\nint yes;\n#else\nint no;\n#endif"
      assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value),
                   "expected __has_builtin(#{builtin}) to be true"
    end
  end

  def test_has_builtin_is_false_for_unknown_builtins
    source = "#if __has_builtin(__builtin_unlikely)\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "no", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_has_include_outside_an_if_is_a_plain_identifier
    # Only #if folds __has_include; elsewhere it is an ordinary name.
    tokens = pp("int __has_include;").reject(&:eof?)
    assert_equal ["int", "__has_include", ";"], tokens.map(&:value)
  end

  # --- defined() answers true for the __has_* query operators ----------------

  def test_defined_is_true_for_the_query_operators
    %w[__has_builtin __has_include __has_attribute].each do |op|
      source = "#if defined(#{op})\nint yes;\n#else\nint no;\n#endif"
      assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value),
                   "expected defined(#{op}) to be 1"
    end
  end

  def test_defined_without_parens_is_true_for_a_query_operator
    source = "#if defined __has_builtin\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_defined_of_defined_stays_false
    # gcc answers defined() true for the __has_* queries but not for `defined`
    # itself, which is not among them.
    source = "#if defined(defined)\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "no", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  # --- a macro-wrapped __has_* query folds after expansion -------------------

  def test_macro_wrapped_has_builtin_is_folded_post_expansion
    %w[__builtin_va_start __builtin_expect __builtin_alloca].each do |builtin|
      source = "#define HAS(x) __has_builtin(x)\n" \
               "#if HAS(#{builtin})\nint yes;\n#else\nint no;\n#endif"
      assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value),
                   "expected macro-wrapped __has_builtin(#{builtin}) to be true"
    end
  end

  def test_macro_wrapped_has_builtin_is_false_for_unknown
    source = "#define HAS(x) __has_builtin(x)\n" \
             "#if HAS(__builtin_nope)\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "no", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_macro_wrapped_has_include_folds_after_expansion
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "there.h"), "int x;\n")
      main = File.join(dir, "main.c")
      source = "#define HAS_INC(x) __has_include(x)\n" \
               "#if HAS_INC(\"there.h\")\nint yes;\n#else\nint no;\n#endif"
      assert_equal ["int", "yes", ";"], pp(source, filename: main).reject(&:eof?).map(&:value)
    end
  end

  # --- numeric predefined macros (gcc -dM spellings) -------------------------

  def test_numeric_predefined_macros_expand_to_gcc_spellings
    # [value, base, suffix] as the converter reads back the gcc -dM spelling: the
    # value base (hex vs decimal) and integer suffix must match so a
    # gcc-differential #if agrees.
    {
      "__CHAR_BIT__" => [8, 10, ""], "__INT_MAX__" => [0x7fffffff, 16, ""],
      "__LONG_MAX__" => [0x7fffffffffffffff, 16, "l"],
      "__SIZE_MAX__" => [0xffffffffffffffff, 16, "ul"],
      "__SIZEOF_POINTER__" => [8, 10, ""], "__WINT_MAX__" => [0xffffffff, 16, "u"]
    }.each do |name, (value, base, suffix)|
      tokens = pp(name).reject(&:eof?)
      assert_equal 1, tokens.length, "#{name} should expand to one token"
      assert_equal [value, base, suffix], [tokens.first.value, tokens.first.base, tokens.first.suffix],
                   "#{name} should expand to gcc's exact spelling"
    end
  end

  def test_long_max_compares_equal_in_if
    source = "#if __LONG_MAX__ == 0x7fffffffffffffffL\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_int_and_pointer_size_macros_compare_in_if
    source = "#if __INT_MAX__ == 2147483647 && __SIZEOF_POINTER__ == 8\n" \
             "int yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_wchar_min_expression_evaluates_negative_in_if
    # __WCHAR_MIN__ is the parenthesized expression "(-__WCHAR_MAX__ - 1)",
    # which must expand as a multi-token replacement and fold in #if.
    source = "#if __WCHAR_MIN__ < 0\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "yes", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  def test_numeric_predefined_macro_is_undefinable
    source = "#undef __LONG_MAX__\n#ifdef __LONG_MAX__\nint yes;\n#else\nint no;\n#endif"
    assert_equal ["int", "no", ";"], pp(source).reject(&:eof?).map(&:value)
  end

  # --- #pragma ---------------------------------------------------------------

  def test_pragma_once_reads_a_header_only_once
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "guard.h"), "#pragma once\nint from_guard;\n")
      main = File.join(dir, "main.c")
      source = "#include \"guard.h\"\n#include \"guard.h\"\nint after;"
      tokens = pp(source, filename: main).reject(&:eof?)
      assert_equal ["int", "from_guard", ";", "int", "after", ";"], tokens.map(&:value)
    end
  end

  def test_unknown_pragma_is_ignored
    tokens = pp("#pragma GCC diagnostic push\nint x;").reject(&:eof?)
    assert_equal ["int", "x", ";"], tokens.map(&:value)
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

  # --- #include_next (GNU extension) ------------------------------------------

  def test_include_next_resumes_past_the_including_directory
    Dir.mktmpdir do |dir1|
      Dir.mktmpdir do |dir2|
        File.write(File.join(dir1, "h.h"), "#include_next <h.h>\nint from = 1;\n")
        File.write(File.join(dir2, "h.h"), "int from_dir2;\n")
        tokens = Rubycc::Preprocess::Preprocessor.new
                   .run("#include <h.h>\n", filename: "main.c", include_paths: [dir1, dir2])
                   .reject(&:eof?)
        assert_equal ["int", "from_dir2", ";", "int", "from", "=", 1, ";"], tokens.map(&:value)
      end
    end
  end

  def test_include_next_quote_form_ignores_the_includer_directory
    Dir.mktmpdir do |dir1|
      Dir.mktmpdir do |dir2|
        File.write(File.join(dir1, "h.h"), "#include_next \"h.h\"\nint from = 1;\n")
        File.write(File.join(dir2, "h.h"), "int from_dir2;\n")
        tokens = Rubycc::Preprocess::Preprocessor.new
                   .run("#include <h.h>\n", filename: "main.c", include_paths: [dir1, dir2])
                   .reject(&:eof?)
        assert_equal ["int", "from_dir2", ";", "int", "from", "=", 1, ";"], tokens.map(&:value)
      end
    end
  end

  def test_include_next_from_the_main_file_behaves_like_include
    # The main source file was never resolved along the search path, so it has
    # no -I directory to resume past; #include_next falls back to a plain
    # #include search from the front of the list.
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "h.h"), "int fromsys;\n")
      tokens = Rubycc::Preprocess::Preprocessor.new
                 .run("#include_next <h.h>\n", filename: "main.c", include_paths: [dir])
                 .reject(&:eof?)
      assert_equal ["int", "fromsys", ";"], tokens.map(&:value)
    end
  end

  def test_include_next_missing_header_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("#include_next <gone.h>\n") }
    assert_match(%r{gone\.h: No such file or directory}, error.description)
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

  # --- wide character constants (Step 28 Phase C2) ---------------------------

  # glibc's bits/wchar.h guards with "#elif L'\0' - 1 > 0"; a wide constant
  # evaluates like a plain one here (int, value 0), so 0 - 1 > 0 is false and the
  # group is dropped.
  def test_if_wide_null_character_matches_plain
    tokens = pp("#if L'\\0' - 1 > 0\nint a;\n#else\nint b;\n#endif").reject(&:eof?)
    assert_equal ["int", "b", ";"], tokens.map(&:value)
  end

  def test_wide_character_constant_value_equals_plain
    tokens = pp("int x = L'a';").reject(&:eof?)
    assert_equal [:keyword, :ident, :punct, :num, :punct], tokens.map(&:type)
    assert_equal 97, tokens[3].value
  end

  def test_identifier_named_l_is_unaffected
    # "L" only opens a wide literal when it abuts a quote; a plain identifier
    # named L (or Lx) still lexes as an identifier.
    tokens = pp("int L = 0; int Lx = 0;").reject(&:eof?)
    assert_equal %w[int L = 0 ; int Lx = 0 ;], tokens.map { |t| t.value.to_s }
  end

  def test_wide_string_literal_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("char *s = L\"ab\";") }
    assert_match(/wide string literals are not supported/, error.description)
  end

  # --- adjacent string-literal concatenation (translation phase 6) -----------

  def test_two_adjacent_string_literals_concatenate
    tokens = pp("char *s = \"abc\" \"def\";").reject(&:eof?)
    string = tokens.find { |t| t.type == :string }
    assert_equal "abcdef".b, string.value
  end

  def test_three_adjacent_string_literals_concatenate
    tokens = pp("char *s = \"a\" \"b\" \"c\";").reject(&:eof?)
    assert_equal "abc".b, tokens.find { |t| t.type == :string }.value
  end

  def test_escapes_decode_per_literal_before_concatenation
    # "\x41" is the single byte 'A'; the following "1" is not swallowed into the
    # hex escape (6.4.5p4), so the run is the two bytes "A1", never "\x411".
    tokens = pp("char *s = \"\\x41\" \"1\";").reject(&:eof?)
    assert_equal "A1".b, tokens.find { |t| t.type == :string }.value
  end

  def test_macro_produced_adjacency_concatenates
    source = "#define B \"b\"\nchar *s = \"a\" B \"c\";"
    assert_equal "abc".b, pp(source).find { |t| t.type == :string }.value
  end

  def test_stringize_result_concatenates_with_a_literal
    # Ruby's static-assert fallback abuts a #x stringize with plain literals.
    source = "#define S(x) #x \": \" \"end\"\nchar *s = S(name);"
    assert_equal "name: end".b, pp(source).find { |t| t.type == :string }.value
  end

  # --- _Pragma operator (6.10.9), accepted and discarded ---------------------

  def test_pragma_operator_written_literally_is_dropped
    tokens = pp("_Pragma(\"GCC visibility push(default)\") int x;").reject(&:eof?)
    assert_equal %w[int x ;], tokens.map(&:value)
  end

  def test_pragma_operator_produced_by_a_macro_is_dropped
    # config.h defines its export markers as _Pragma(...); the operator must be
    # recognized after macro expansion, not only when written by hand.
    source = "#define OPEN _Pragma(\"GCC visibility push(default)\")\nOPEN int y;"
    assert_equal %w[int y ;], pp(source).reject(&:eof?).map(&:value)
  end

  def test_pragma_operator_without_parenthesized_string_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("_Pragma 5;") }
    assert_match(/_Pragma takes a parenthesized string literal/, error.description)
  end

  def test_pragma_operator_with_non_string_operand_is_rejected
    error = assert_raises(Rubycc::CompileError) { pp("_Pragma(once);") }
    assert_match(/_Pragma takes a parenthesized string literal/, error.description)
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
    "#if 0\n#weird\n#\nnot ; real @ tokens\n#else\nint ok;\n#endif\n",
    # Function-like macros: a basic argument substitution and a nested call.
    "#define SQR(x) ((x) * (x))\nint a = SQR(3);\n",
    "#define ADD(a, b) ((a) + (b))\nint a = ADD(4, ADD(5, 6));\n",
    # An object macro supplying the name of a call that spans the boundary.
    "#define g f\n#define f(x) ((x) + 1)\nint a = g(3);\n",
    # __VA_ARGS__ passing the variable part through to another call.
    "#define V(...) f(__VA_ARGS__)\nint a = V(1, 2, 3);\n",
    # A call whose argument list is split across a newline.
    "#define MAX(a, b) ((a) > (b) ? (a) : (b))\nint a = MAX(10,\n20);\n",
    # A macro whose replacement calls another, and an argument-borne macro name.
    "#define F(x) x\n#define G(x) F(x)\nint a = G(7) + F(F(8));\n",
    # "#" stringizes its raw argument, normalizing interior whitespace and
    # escaping a nested string literal's quotes and backslashes.
    "#define STR(x) #x\nchar *s = STR(  a  +  b  );\n",
    "#define STR(x) #x\nchar *s = STR(\"a\\tb\");\n",
    # "#__VA_ARGS__" reproduces the variable part with its exact comma spacing.
    "#define S(...) #__VA_ARGS__\nchar *s = S(a, b, c);\n",
    # "##" pastes identifiers (the result rescanned into a macro name) and joins
    # number fragments, chaining left to right.
    "#define GLUE(a, b) a ## b\n#define HELLO 42\nint a = GLUE(HEL, LO);\n",
    "#define J(a, b, c) a ## b ## c\nint a = J(1, 2, 3);\n",
    # A placemarker: an empty paste operand leaves the other side alone.
    "#define P(a, b) [ a ## b ]\nint a[] = { P(, tail) };\n",
    # "#x" takes the raw argument while a lone "x" is expanded, in one macro.
    "#define N 5\n#define F(x) #x + x\nint a[] = { F(N) };\n"
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
