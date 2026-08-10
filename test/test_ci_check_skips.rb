# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tempfile"

class TestCiCheckSkips < Minitest::Test
  SCRIPT = File.expand_path("../tools/ci_check_skips.rb", __dir__).freeze

  def test_native_profile_accepts_only_manifested_skip
    log = <<~LOG
      1) Skipped:
      TestSharedObject#test_one [test/test_shared_object.rb:1]:
      x86_64 shared-object coverage is not valid on "aarch64"

      2500 runs, 1 assertions, 0 failures, 0 errors, 1 skips
    LOG

    stdout, stderr, status = run_checker(log, "native-aarch64")
    assert status.success?, "expected profile to accept the manifested skip: #{stdout}\n#{stderr}"
    assert_includes stdout, "profile=native-aarch64"
  end

  def test_native_profile_rejects_unknown_skip_reason
    log = <<~LOG
      1) Skipped:
      TestSharedObject#test_one [test/test_shared_object.rb:1]:
      a new accidental skip

      2500 runs, 1 assertions, 0 failures, 0 errors, 1 skips
    LOG

    _stdout, stderr, status = run_checker(log, "native-aarch64")
    refute status.success?
    assert_includes stderr, "unapproved skip"
  end

  def test_native_profile_cannot_be_loosened_by_environment_override
    log = <<~LOG
      1) Skipped:
      TestSharedObject#test_one [test/test_shared_object.rb:1]:
      a new accidental skip

      2500 runs, 1 assertions, 0 failures, 0 errors, 1 skips
    LOG

    _stdout, stderr, status = run_checker(log, "native-aarch64", "CI_MAX_SKIPS" => "9999")
    refute status.success?
    assert_includes stderr, "unapproved skip"
  end

  def test_native_profile_uses_its_own_budget_instead_of_x86_default
    skips = Array.new(60) do |index|
      <<~SKIP
        #{index + 1}) Skipped:
        TestSharedObject#test_#{index} [test/test_shared_object.rb:1]:
        x86_64 shared-object coverage is not valid on "aarch64"

      SKIP
    end.join
    log = "#{skips}2500 runs, 1 assertions, 0 failures, 0 errors, 60 skips\n"

    _stdout, stderr, status = run_checker(log, "native-aarch64")
    assert status.success?, "native profile must use max_skips=220, not x86 max=55: #{stderr}"
  end

  def test_native_profile_budget_cannot_be_loosened_by_environment_override
    skips = Array.new(221) do |index|
      <<~SKIP
        #{index + 1}) Skipped:
        TestSharedObject#test_#{index} [test/test_shared_object.rb:1]:
        x86_64 shared-object coverage is not valid on "aarch64"

      SKIP
    end.join
    log = "#{skips}2500 runs, 1 assertions, 0 failures, 0 errors, 221 skips\n"

    _stdout, stderr, status = run_checker(log, "native-aarch64", "CI_MAX_SKIPS" => "9999")
    refute status.success?
    assert_includes stderr, "skips exceeds CI_MAX_SKIPS=220"
  end

  def test_rejects_concatenated_or_retried_summaries
    log = <<~LOG
      2500 runs, 1 assertions, 0 failures, 0 errors, 0 skips
      2500 runs, 1 assertions, 0 failures, 0 errors, 0 skips
    LOG

    _stdout, stderr, status = run_checker(log, "native-aarch64")
    refute status.success?
    assert_includes stderr, "expected exactly one Minitest summary line"
  end

  private

  def run_checker(log, profile, env = {})
    Tempfile.create("rubycc-ci-skip") do |file|
      file.write(log)
      file.flush
      Open3.capture3(env.merge("CI_SKIP_PROFILE" => profile), RbConfig.ruby, SCRIPT, file.path)
    end
  end
end
