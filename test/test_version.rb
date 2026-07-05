# frozen_string_literal: true

require_relative "test_helper"

class TestVersion < Minitest::Test
  def test_version_is_defined
    refute_nil Rubycc::VERSION
  end

  def test_version_is_semver
    assert_match(/\A\d+\.\d+\.\d+\z/, Rubycc::VERSION)
  end
end
