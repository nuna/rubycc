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
    cache = steps.find { |step| step.fetch("uses", "").start_with?("actions/cache@") }
    refute_nil cache
    assert_equal "tmp/ci/acceptance-fixtures", cache.fetch("with").fetch("path")
    assert_includes cache.fetch("with").fetch("key"), "hashFiles('config/ci/acceptance_manifest.json')"

    prepare = steps.find { |step| step.fetch("name", "").include?("Prepare and verify") }
    refute_nil prepare
    assert_includes prepare.fetch("run"), "tools/ci_prepare_acceptance_fixtures.rb"
    assert_includes prepare.fetch("run"), "test/test_acceptance_fixtures.rb"

    run = steps.find { |step| step.fetch("name", "").include?("without network") }
    refute_nil run
    script = run.fetch("run")

    assert_includes script, "sudo -E env"
    assert_includes script, "unshare --net"
    assert_includes script, "setpriv"
    assert_includes script, "test/test_mkmf_conftest.rb"
    assert_includes script, "test/test_rmake_tools.rb"
    assert_includes script, "test/test_gem_install.rb"

    env = run.fetch("env")
    assert_equal "fixture", env.fetch("CI_NETWORK")
    assert_equal "1", env.fetch("RMAKE_ACCEPTANCE_STRICT")
    assert_equal "${{ github.workspace }}/tmp/ci/acceptance-fixtures", env.fetch("CI_FIXTURE_ROOT")
  end

  def test_fixture_job_blocks_network_via_root_owned_namespace_and_verifies_the_blackhole
    steps = @jobs.fetch("acceptance-fixture").fetch("steps")

    verify_no_network = steps.find { |step| step.fetch("name", "").include?("Verify the namespace really has no network") }
    refute_nil verify_no_network
    verify_script = verify_no_network.fetch("run")
    assert_includes verify_script, "sudo -E env"
    assert_includes verify_script, "unshare --net"
    assert_includes verify_script, "setpriv"

    fixture_run = steps.find { |step| step.fetch("name", "").include?("without network") }
    refute_nil fixture_run

    verify_index = steps.index(verify_no_network)
    fixture_index = steps.index(fixture_run)

    assert_operator verify_index, :<, fixture_index,
                     "the network blackhole check must run before the fixture step"
  end
end
