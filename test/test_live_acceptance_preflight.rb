# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class TestLiveAcceptancePreflight < Minitest::Test
  SCRIPT = File.expand_path("../tools/live_acceptance_preflight.rb", __dir__)

  def test_records_a_passing_live_context_without_network_access
    Dir.mktmpdir do |dir|
      env = {
        "CI_PROFILE" => "acceptance-live",
        "CI_NETWORK" => "live",
        "RMAKE_ACCEPTANCE_STRICT" => "1",
        "CI_RESULT_PATH" => File.join(dir, "results.json"),
        "CI_ARTIFACT_REPORT_PATH" => File.join(dir, "artifacts.json")
      }
      _output, status = Open3.capture2e(env, RbConfig.ruby, SCRIPT)

      assert status.success?
      result = JSON.parse(File.read(env.fetch("CI_RESULT_PATH"))).fetch("results").first
      assert_equal "acceptance-live-preflight", result.fetch("id")
      assert_equal "pass", result.fetch("state")
      assert_equal "live", result.fetch("network")
      assert result.fetch("ruby_ok")
      assert result.fetch("rmake_available")
      assert result.fetch("rubycc_available")
    end
  end

  def test_records_failure_when_external_tools_are_missing
    Dir.mktmpdir do |dir|
      empty_path = File.join(dir, "empty-bin")
      Dir.mkdir(empty_path)
      result_path = File.join(dir, "results.json")
      env = {
        "PATH" => empty_path,
        "CI_PROFILE" => "acceptance-live",
        "CI_NETWORK" => "live",
        "RMAKE_ACCEPTANCE_STRICT" => "1",
        "CI_RESULT_PATH" => result_path,
        "CI_ARTIFACT_REPORT_PATH" => File.join(dir, "artifacts.json")
      }
      _output, status = Open3.capture2e(env, RbConfig.ruby, SCRIPT)

      refute status.success?
      result = JSON.parse(File.read(result_path)).fetch("results").first
      assert_equal "fail", result.fetch("state")
      assert_includes result.fetch("reason"), "curl executable is unavailable"
    end
  end
end
