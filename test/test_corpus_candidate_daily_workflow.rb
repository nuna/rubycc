# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "yaml"

class TestCorpusCandidateDailyWorkflow < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze
  WORKFLOW = File.join(ROOT, ".github/workflows/corpus-candidate-daily.yml").freeze

  def setup
    @workflow = YAML.load_file(WORKFLOW)
    @trigger = @workflow.fetch("on")
    @job = @workflow.fetch("jobs").fetch("scan")
    @steps = @job.fetch("steps")
  end

  def step_using(action)
    @steps.find { |step| step["uses"] == action } || flunk("missing step using #{action}")
  end

  def run_scripts
    @steps.filter_map { |step| step["run"] }.join("\n")
  end

  def test_only_schedule_and_manual_replay_can_start_the_workflow
    assert_equal %w[schedule workflow_dispatch], @trigger.keys
    refute @trigger.key?("push")
    refute @trigger.key?("pull_request")
    assert_equal "17 1 * * *", @trigger.fetch("schedule").fetch(0).fetch("cron")
    refute_equal "0", @trigger.fetch("schedule").fetch(0).fetch("cron").split.first
  end

  def test_manual_replay_requires_exact_utc_boundaries
    inputs = @trigger.fetch("workflow_dispatch").fetch("inputs")
    %w[from to].each do |name|
      assert_equal true, inputs.fetch(name).fetch("required"), name
      assert_equal "string", inputs.fetch(name).fetch("type"), name
    end

    window = @steps.find { |step| step["id"] == "window" }
    refute_nil window
    script = window.fetch("run")
    assert_includes script, "GITHUB_EVENT_NAME"
    assert_includes script, "Time.now.utc"
    assert_includes script, "Time.iso8601"
    assert_includes script, "to - from == 86_400"
  end

  def test_runner_and_execution_boundary_are_fixed
    assert_equal "ubuntu-24.04", @job.fetch("runs-on")
    assert_equal 35, @job.fetch("timeout-minutes")
    refute @job.key?("strategy"), "daily scan must remain a single x64 job"
    assert_equal({ "contents" => "read" }, @workflow.fetch("permissions"))

    concurrency = @workflow.fetch("concurrency")
    assert_equal "corpus-candidate-daily-scan", concurrency.fetch("group")
    assert_equal false, concurrency.fetch("cancel-in-progress")

    checkout = step_using("actions/checkout@v7")
    assert_equal false, checkout.fetch("with").fetch("persist-credentials")
    ruby = step_using("ruby/setup-ruby@v1")
    assert_equal "4.0", ruby.fetch("with").fetch("ruby-version")
    assert_equal false, ruby.fetch("with").fetch("bundler-cache")
  end

  def test_scan_is_static_and_does_not_install_or_run_gem_code
    script = run_scripts
    assert_includes script, "ruby tools/scan_popular_gems.rb"
    assert_includes script, "--source timeframe"
    assert_includes script, "--artifact"
    assert_includes script, "--summary"
    assert_includes script, "--fetch-concurrency 2"

    forbidden = [
      /gem\s+install/i,
      /gem\s+test/i,
      /extconf\.rb/i,
      /(?:^|\s)make(?:\s|$)/,
      /bundle\s+(?:install|exec)/i,
      /rake\s+test/i
    ]
    forbidden.each do |pattern|
      refute_match pattern, script, "static workflow contains #{pattern.inspect}"
    end
    refute_match(/secrets\./, File.read(WORKFLOW))
  end

  def test_artifact_is_compact_and_distinguishes_interval_and_scanner_revision
    upload = step_using("actions/upload-artifact@v7")
    options = upload.fetch("with")
    assert_equal [
      "${{ runner.temp }}/corpus-candidate-output/classification.json",
      "${{ runner.temp }}/corpus-candidate-output/run-summary.json",
      "${{ runner.temp }}/corpus-candidate-output/scan.log"
    ], options.fetch("path").lines.map(&:strip)
    assert_equal "35", options.fetch("retention-days").to_s
    assert_includes options.fetch("name"), "steps.window.outputs.key"
    assert_includes options.fetch("name"), "github.sha"
    refute_includes options.fetch("path"), ".gem"
    refute_includes options.fetch("path"), "raw_responses"
  end

  def test_working_artifacts_are_ignored_outside_the_workflow_report
    candidate = "docs/development/corpus-candidate-evaluation/artifacts/arbitrary-output.json"
    _stdout, _stderr, status = Open3.capture3("git", "check-ignore", "--no-index", candidate,
                                               chdir: ROOT)
    assert status.success?, "#{candidate} must remain outside the commit set"
  end
end
