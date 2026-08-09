# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class TestNativeAArch64Preflight < Minitest::Test
  SCRIPT = File.expand_path("../tools/native_aarch64_preflight.rb", __dir__).freeze

  def test_preflight_records_real_binary_header_and_loader_probes
    Dir.mktmpdir("rubycc-native-preflight-test") do |dir|
      result_path = File.join(dir, "results.json")
      context_path = File.join(dir, "context.json")
      stdout, stderr, status = Open3.capture3(
        {
          "CI_PROFILE" => "native-aarch64-smoke",
          "CI_RESULT_PATH" => result_path,
          "CI_NATIVE_CONTEXT_PATH" => context_path,
          "CI_HOST" => "aarch64",
          "CI_TARGET" => "aarch64",
          "CI_RUNNER" => "native-aarch64",
          "CI_LIBC" => "glibc",
          "CI_NETWORK" => "none"
        },
        RbConfig.ruby,
        SCRIPT
      )

      assert File.file?(result_path), "preflight did not write results: #{stderr}"
      assert File.file?(context_path), "preflight did not write context: #{stderr}"
      result = JSON.parse(File.read(result_path)).fetch("results").fetch(0)
      context = JSON.parse(File.read(context_path))

      assert_equal "native-aarch64-preflight", result.fetch("id")
      assert_equal context.fetch("ruby_header_probe_ok"), result.fetch("ruby_header_probe_ok")
      assert_equal context.fetch("fiddle_probe_ok"), result.fetch("fiddle_probe_ok")
      assert_equal context.fetch("ruby_dependencies_ok"), result.fetch("ruby_dependencies_ok")
      assert context.key?("ruby_elf"), "ELF inspection was not recorded"

      if result.fetch("state") == "pass"
        assert status.success?, "a passing preflight exited unsuccessfully: #{stdout}\n#{stderr}"
      else
        refute status.success?, "a failing preflight exited successfully: #{stdout}\n#{stderr}"
      end
    end
  end
end
