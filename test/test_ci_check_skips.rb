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

  # The guard used to pin the exact test-name/reason set with a SHA-256, which
  # made a renamed test fail even though its reason was approved. That layer was
  # removed on purpose: it could only be regenerated from a CI log, so every
  # commit touching a skip line cost a push/fail/recompute round trip. This test
  # records the accepted trade-off so the loss of detection is not silent.
  def test_enforced_baseline_no_longer_pins_the_exact_skip_set
    log = <<~LOG
      1) Skipped:
      TestSharedObject#test_renamed_but_same_reason [test/test_shared_object.rb:1]:
      x86_64 shared-object coverage is not valid on "aarch64"

      2500 runs, 1 assertions, 0 failures, 0 errors, 1 skips
    LOG

    stdout, stderr, status = run_checker(log, "native-aarch64",
                                          "CI_ENFORCE_SKIP_BASELINE" => "1")
    assert status.success?,
           "an approved reason under a new test name must pass: #{stdout}\n#{stderr}"
  end

  # The allow list is what remains of the per-skip checking, so its two failure
  # modes -- an unapproved reason and a rule used more often than budgeted --
  # are covered here as well as under enforcement.
  def test_enforced_baseline_still_rejects_an_unapproved_reason
    log = <<~LOG
      1) Skipped:
      TestSharedObject#test_one [test/test_shared_object.rb:1]:
      libfoo-dev is not installed in this environment

      2500 runs, 1 assertions, 0 failures, 0 errors, 1 skips
    LOG

    _stdout, stderr, status = run_checker(log, "native-aarch64",
                                           "CI_ENFORCE_SKIP_BASELINE" => "1")
    refute status.success?
    assert_includes stderr, "unapproved skip"
  end

  def test_profile_rejects_a_rule_used_more_often_than_its_max_count
    # native-x86 budgets this reason at max_count=2; three uses must fail even
    # though the total stays far below max_skips.
    skips = Array.new(3) do |index|
      <<~SKIP
        #{index + 1}) Skipped:
        TestNativeAArch64Smoke#test_#{index} [test/test_native_aarch64_smoke.rb:1]:
        native AArch64 smoke runs only on an AArch64 Ruby runner

      SKIP
    end.join
    log = "#{skips}2500 runs, 1 assertions, 0 failures, 0 errors, 3 skips\n"

    _stdout, stderr, status = run_checker(log, "native-x86")
    refute status.success?
    assert_includes stderr, "above max_count=2"
  end

  def test_profile_accepts_a_rule_used_up_to_its_max_count
    skips = Array.new(2) do |index|
      <<~SKIP
        #{index + 1}) Skipped:
        TestNativeAArch64Smoke#test_#{index} [test/test_native_aarch64_smoke.rb:1]:
        native AArch64 smoke runs only on an AArch64 Ruby runner

      SKIP
    end.join
    log = "#{skips}2500 runs, 1 assertions, 0 failures, 0 errors, 2 skips\n"

    stdout, stderr, status = run_checker(log, "native-x86")
    assert status.success?, "max_count=2 must accept two uses: #{stdout}\n#{stderr}"
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
    assert status.success?, "native profile must use max_skips=245, not x86 max=55: #{stderr}"
  end

  def test_native_profile_budget_cannot_be_loosened_by_environment_override
    skips = Array.new(246) do |index|
      <<~SKIP
        #{index + 1}) Skipped:
        TestSharedObject#test_#{index} [test/test_shared_object.rb:1]:
        x86_64 shared-object coverage is not valid on "aarch64"

      SKIP
    end.join
    log = "#{skips}2500 runs, 1 assertions, 0 failures, 0 errors, 246 skips\n"

    _stdout, stderr, status = run_checker(log, "native-aarch64", "CI_MAX_SKIPS" => "9999")
    refute status.success?
    assert_includes stderr, "skips exceeds CI_MAX_SKIPS=245"
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
