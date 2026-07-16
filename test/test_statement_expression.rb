# frozen_string_literal: true

require_relative "test_helper"

# Step 40: the GNU statement-expression extension "( { block-item* } )". The
# braces are a compound-statement with its own scope; when its last block-item
# is an expression-statement, that expression's value and type become the whole
# construct's, otherwise the construct is void. These tests exercise the value,
# the type (through sizeof), the block scope, the void form, nesting, side
# effects on the enclosing scope, and the __extension__-prefixed spelling, each
# checked for a matching exit status and stdout against the system gcc.
class TestStatementExpression < Minitest::Test
  include ExecutionHelper

  def test_yields_last_expression_value
    assert_c_exit_status(5, "int main(void) { return ({ int a = 2; a + 3; }); }")
  end

  def test_single_expression_body
    assert_c_exit_status(1, "int main(void) { return ({ 1; }); }")
  end

  def test_nested_statement_expression
    src = "int main(void) { " \
          "return ({ int n = ({ int m = 4; m * 2; }); n + 1; }); }"
    assert_c_exit_status(9, src)
  end

  def test_block_scope_is_independent
    # The inner "a" belongs to the statement expression's block and does not
    # disturb the outer "a"; the construct's value is the inner sum.
    src = "int main(void) { int a = 10; " \
          "int b = ({ int a = 1; a + 2; }); return a + b; }"
    assert_c_exit_status(13, src)
  end

  def test_side_effects_reach_enclosing_scope
    src = "int main(void) { int x = 0; " \
          "int y = ({ x = 7; x + 1; }); return x + y; }"
    assert_c_exit_status(15, src)
  end

  def test_void_statement_expression_when_last_item_is_a_declaration
    # A block whose last item is a declaration (not an expression-statement) is
    # void; evaluated only for effect here, it must still compile and run.
    src = "int main(void) { int r = 3; ({ r = 8; int q = 1; }); return r; }"
    assert_c_exit_status(8, src)
  end

  def test_void_statement_expression_when_last_item_is_a_loop
    src = "int main(void) { int s = 0; " \
          "({ for (int i = 0; i < 4; i++) s += i; }); return s; }"
    assert_c_exit_status(6, src)
  end

  def test_sizeof_statement_expression_uses_the_result_type_only
    # sizeof measures the last expression's type without running the block, so
    # the "long q" makes the result 8 bytes even though the body is not executed.
    src = "int printf(const char *, ...); " \
          "int main(void) { printf(\"%zu\\n\", sizeof(({ long q = 0; q + 1; }))); return 0; }"
    assert_c_program(src, exit_status: 0, stdout: "8\n")
  end

  def test_sizeof_statement_expression_does_not_evaluate_the_body
    # If the body ran, "n" would become 1 and the program would return 1; since
    # sizeof only inspects the type, "n" stays 0.
    src = "int main(void) { int n = 0; " \
          "unsigned long s = sizeof(({ n = 1; n; })); (void)s; return n; }"
    assert_c_exit_status(0, src)
  end

  def test_extension_prefixed_statement_expression
    assert_c_exit_status(9, "int main(void) { return __extension__ ({ int t = 10; t - 1; }); }")
  end

  def test_statement_expression_result_feeds_printf
    src = "int printf(const char *, ...); " \
          "int main(void) { printf(\"%d\\n\", ({ int a = 20; a + 22; })); return 0; }"
    assert_c_program(src, exit_status: 0, stdout: "42\n")
  end

  # --- differential checks against the system gcc ---------------------------

  DIFF_PROGRAMS = {
    "value and side effect" =>
      "int printf(const char *, ...); " \
      "int main(void) { int c = 0; " \
      "  int v = ({ c++; int a = 2; a * a + c; }); " \
      "  printf(\"%d %d\\n\", v, c); return v; }",
    "nested and void arms" =>
      "int printf(const char *, ...); " \
      "int main(void) { " \
      "  int r = ({ int t = 0; for (int i = 1; i <= 3; i++) t += i; t; }); " \
      "  ({ int u = ({ r + 1; }); printf(\"%d\\n\", u); }); return r; }",
    "conditional with a void statement-expression arm" =>
      "int printf(const char *, ...); " \
      "int main(void) { int i = 1; " \
      "  (i ? printf(\"taken\\n\") : ({ int z = 0; while (z) z--; })); return 0; }"
  }.freeze

  DIFF_PROGRAMS.each do |name, source|
    define_method("test_matches_gcc_#{name.gsub(/\W+/, "_")}") do
      assert_equal program_output(source, compiler: :gcc),
                   program_output(source, compiler: :rubycc)
    end
  end

  private

  # Compiles and runs `source`, returning [exit_status, stdout] for comparison.
  def program_output(source, compiler:)
    in_tmpdir do |dir|
      object_path = File.join(dir, "test.o")
      compile_source(source, object_path, compiler)
      link_and_run(object_path)
    end
  end
end
