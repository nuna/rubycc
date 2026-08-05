# frozen_string_literal: true

require_relative "test_helper"

# A macro invocation may emit declarations that already end in semicolons and
# then be followed by the invocation's own semicolon. GCC accepts the resulting
# empty external declaration; pg's gvl_wrappers.h relies on that GNU extension.
class TestEmptyExternalDeclaration < Minitest::Test
  include ExecutionHelper

  SOURCE = <<~C
    #define DECLARE(type, name) type name;
    #define FOR_EACH(fn) fn(int, value)
    FOR_EACH(DECLARE);
    int main(void) { return value == 0 ? 0 : 1; }
  C

  def test_stray_file_scope_semicolon_after_macro_declarations
    assert_c_program(SOURCE, exit_status: 0)
  end
end
