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
end
