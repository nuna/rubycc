# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class TestWeeklyWorkflow < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/weekly.yml", __dir__).freeze

  def setup
    @workflow = YAML.load_file(WORKFLOW)
    @jobs = @workflow.fetch("jobs")
  end

  def test_acceptance_only_is_a_choice_and_runs_fixture_and_live
    options = @workflow.fetch("on").fetch("workflow_dispatch").fetch("inputs").fetch("only").fetch("options")
    assert_includes options, "acceptance"

    expected = "inputs.verify_step == '' && (inputs.only == '' || inputs.only == 'acceptance')"
    assert_equal expected, @jobs.fetch("acceptance-fixture").fetch("if")
    assert_equal expected, @jobs.fetch("acceptance").fetch("if")
  end

  def test_acceptance_only_does_not_enable_unrelated_weekly_jobs
    unrelated = @jobs.keys - %w[dispatch-contract acceptance-fixture acceptance]
    unrelated.each do |name|
      condition = @jobs.fetch(name).fetch("if", "").to_s
      refute_includes condition, "inputs.only == 'acceptance'", "#{name} is enabled by acceptance-only"
    end
  end

  # Every native AArch64 mechanism in this repository only reports on an AArch64
  # runner, so a native guarantee that exists solely behind a manual dispatch is
  # not a guarantee. The focused smoke therefore runs on the weekly schedule
  # (where `only` is empty), while the expensive full native suite stays
  # dispatch-only. Both halves are pinned so neither can drift into the other.
  def test_native_aarch64_smoke_runs_on_the_weekly_schedule
    smoke = @jobs.fetch("native-aarch64-smoke")
    assert_equal "inputs.verify_step == '' && (inputs.only == '' || inputs.only == 'aarch64')",
                 smoke.fetch("if")
    assert_equal "ubuntu-24.04-arm", smoke.fetch("runs-on")

    assert_equal "inputs.verify_step == '' && inputs.only == 'aarch64'",
                 @jobs.fetch("aarch64").fetch("if"),
                 "the full native suite stays dispatch-only; only the smoke is scheduled"
  end

  def test_invalid_manual_input_has_an_explicit_failing_contract
    contract = @jobs.fetch("dispatch-contract")
    assert_equal "github.event_name == 'workflow_dispatch'", contract.fetch("if")
    script = contract.fetch("steps").fetch(0).fetch("run")
    assert_includes script, "verify_step and only cannot be combined"
  end

  def test_fixture_job_runs_real_acceptance_inputs_in_a_network_namespace
    steps = @jobs.fetch("acceptance-fixture").fetch("steps")
    run = steps.find { |step| step.fetch("name", "").include?("without network") }
    refute_nil run
    script = run.fetch("run")

    assert_includes script, "unshare --user --map-root-user --net"
    assert_includes script, "test/test_mkmf_conftest.rb"
    assert_includes script, "test/test_rmake_tools.rb"
    assert_includes script, "test/test_gem_install.rb"

    env = run.fetch("env")
    assert_equal "fixture", env.fetch("CI_NETWORK")
    assert_equal "1", env.fetch("RMAKE_ACCEPTANCE_STRICT")
    assert_equal "${{ github.workspace }}", env.fetch("CI_FIXTURE_ROOT")
  end
end
