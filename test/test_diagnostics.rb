# frozen_string_literal: true

require_relative "test_helper"

class TestDiagnostics < Minitest::Test
  def compile(source, filename: "foo.c")
    Rubycc::Compiler.new.compile(source, filename: filename)
  end

  def test_missing_semicolon_message_has_full_diagnostic
    source = "int main(void) { return 42 }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    # Structured attributes (N3).
    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_equal 28, error.column # the unexpected '}'
    assert_equal source, error.source_line
    assert_match(/expected ';'/, error.description)

    # Rendered message: header, source excerpt, and a caret line.
    lines = error.message.split("\n")
    assert_equal "foo.c:1:28: error: expected ';'", lines[0]
    assert_equal source, lines[1]
    assert_equal "#{" " * 27}^", lines[2] # caret under column 28
  end

  def test_message_includes_filename_line_and_column
    source = "int main(void) {\n  return 1 +\n}"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_match(/foo\.c:/, error.message)
    assert_includes error.message, "error:"
    # Caret line consists of spaces followed by a single caret.
    caret_line = error.message.split("\n").last
    assert_match(/\A *\^\z/, caret_line)
  end

  def test_undeclared_variable_message_has_full_diagnostic
    source = "int main(void) { return x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/undeclared variable 'x'/, error.description)
    assert_match(/foo\.c:1:\d+: error: undeclared variable 'x'/, error.message)
  end

  def test_redeclaration_message_has_full_diagnostic
    source = "int main(void) { int x; int x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/redeclaration of 'x'/, error.description)
    assert_match(/foo\.c:1:\d+: error: redeclaration of 'x'/, error.message)
  end

  def test_same_scope_redeclaration_is_still_an_error
    source = "int main(void) { int x; int x; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redeclaration of 'x'/, error.description)
  end

  def test_inner_scope_shadowing_is_not_an_error
    # Re-declaring 'x' in a nested block shadows the outer 'x' rather than
    # colliding with it, so compilation must succeed.
    source = "int main(void) { int x = 1; { int x = 2; return x; } }"
    assert_kind_of String, compile(source)
  end

  def test_variable_declared_in_block_is_not_visible_outside
    source = "int main(void) { { int x = 1; } return x; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/undeclared variable 'x'/, error.description)
  end

  def test_break_outside_loop_message_has_full_diagnostic
    source = "int main(void) { break; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/break statement not within a loop/, error.description)
    assert_match(/foo\.c:1:\d+: error: break statement not within a loop/, error.message)
  end

  def test_continue_outside_loop_message_has_full_diagnostic
    source = "int main(void) { continue; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/continue statement not within a loop/, error.description)
    assert_match(/foo\.c:1:\d+: error: continue statement not within a loop/, error.message)
  end

  def test_break_inside_if_but_outside_loop_is_still_an_error
    source = "int main(void) { if (1) break; return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/break statement not within a loop/, error.description)
  end

  def test_implicit_declaration_of_function
    source = "int main(void) { return f(1); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }

    assert_equal "foo.c", error.filename
    assert_equal 1, error.line
    assert_match(/implicit declaration of function 'f'/, error.description)
    assert_match(/foo\.c:1:\d+: error: implicit declaration of function 'f'/, error.message)
  end

  def test_too_few_arguments_to_function
    source = "int f(int a, int b) { return a + b; } int main(void) { return f(1); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/too few arguments to function 'f'/, error.description)
  end

  def test_too_many_arguments_to_function
    source = "int f(int a) { return a; } int main(void) { return f(1, 2); }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/too many arguments to function 'f'/, error.description)
  end

  def test_redefinition_of_function
    source = "int f(void) { return 1; } int f(void) { return 2; } int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redefinition of 'f'/, error.description)
  end

  def test_conflicting_types_between_prototype_and_definition
    source = "int f(int a); int f(int a, int b) { return a + b; } int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/conflicting types for 'f'/, error.description)
  end

  def test_too_many_parameters
    source = "int f(int a, int b, int c, int d, int e, int g, int h) { return a; } " \
             "int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/too many parameters \(rubycc supports up to 6\)/, error.description)
  end

  def test_parameter_name_omitted_in_definition
    source = "int f(int a, int) { return a; } int main(void) { return 0; }"
    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/parameter name omitted/, error.description)
  end
end
