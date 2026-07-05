# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class TestCli < Minitest::Test
  EXE_PATH = File.expand_path("../exe/rubycc", __dir__)

  def test_version_flag_prints_version_and_exits_zero
    stdout, status = Open3.capture2("ruby", "-Ilib", EXE_PATH, "--version")

    assert_equal "rubycc #{Rubycc::VERSION}\n", stdout
    assert status.success?
  end

  def test_no_arguments_exits_with_error
    _stdout, stderr, status = Open3.capture3("ruby", "-Ilib", EXE_PATH)

    assert_equal 1, status.exitstatus
    assert_match(/C compilation is not yet implemented/, stderr)
  end
end
