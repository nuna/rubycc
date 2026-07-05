# frozen_string_literal: true

require_relative "test_helper"

class TestExecutionHarness < Minitest::Test
  include ExecutionHelper

  def test_gcc_reference_path_reports_exit_status
    # Sanity check for the harness itself, using the system gcc as a
    # known-good reference compiler.
    assert_c_exit_status(42, "int main(void) { return 42; }", compiler: :gcc)
  end

  def test_rubycc_path_is_not_implemented_yet
    # Once the rubycc compiler exists, rewrite this test to call
    # assert_c_exit_status(42, ..., compiler: :rubycc) as an actual
    # execution test instead of asserting NotImplementedError.
    assert_raises(NotImplementedError) do
      assert_c_exit_status(42, "int main(void) { return 42; }", compiler: :rubycc)
    end
  end
end
