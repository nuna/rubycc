# frozen_string_literal: true

require "minitest/autorun"
require "open3"

require_relative "../tools/verify_gem_tests"

class TestVerifyGemTestsCli < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_list_includes_explicit_system_library_profiles_without_network
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "tools/verify_gem_tests.rb"), "--list")
    assert_predicate status, :success?, stderr
    assert_empty stderr
    assert_match(/sqlite3\s+\|\s+2\.9\.5\s+\|/, stdout)
    assert_match(/pg\s+\|\s+1\.6\.3\s+\|/, stdout)
    assert_match(/yajl-ruby\s+\|\s+1\.4\.3\s+\|/, stdout)
    assert_match(/SQLite3::SQLITE_PACKAGED_LIBRARIES == false/, stdout)
    assert_match(/PG::IS_BINARY_GEM == false/, stdout)
  end

  def test_help_describes_machine_readable_evidence_without_changing_database
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "tools/verify_gem_tests.rb"), "--help")
    assert_predicate status, :success?, stderr
    assert_empty stderr
    assert_match(/--json PATH\s+write machine-readable run evidence/, stdout)
    assert_match(/does not update the verification database/, stdout)
  end

  def test_json_evidence_uses_logical_paths
    source = File.read(File.expand_path("../tools/verify_gem_tests.rb", __dir__))
    assert_includes source, '"work_dir" => "<VERIFY_WORK>"'
    assert_includes source, '[WORK_DIR, "<VERIFY_WORK>"]'
    assert_includes source, '[RUBYCC_ROOT, "<RUBYCC_ROOT>"]'
    assert_includes source, '[RbConfig::CONFIG["prefix"], "<RUBY_PREFIX>"]'
    assert_includes source, '[Dir.home, "<HOME>"]'
    assert_includes source, "source_from_gem: true"
  end

  def test_zero_test_summary_cannot_be_accepted_as_a_suite_result
    summary = parse_summary("0 tests, 0 assertions, 0 failures, 0 errors\n", :test_unit)
    refute_nil summary
    refute usable_summary?(summary)
  end
end
