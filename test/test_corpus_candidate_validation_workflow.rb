# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class TestCorpusCandidateValidationWorkflow < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze
  WORKFLOW = File.join(ROOT, ".github/workflows/corpus-candidate-validation.yml").freeze

  def setup
    @workflow = YAML.load_file(WORKFLOW)
    @trigger = @workflow.fetch("on")
    @jobs = @workflow.fetch("jobs")
  end

  def all_steps
    @jobs.values.flat_map { |job| job.fetch("steps") }
  end

  def run_scripts
    all_steps.filter_map { |step| step["run"] }.join("\n")
  end

  def test_workflow_dispatch_is_the_only_trigger_and_inputs_are_fixed
    assert_equal ["workflow_dispatch"], @trigger.keys
    inputs = @trigger.fetch("workflow_dispatch").fetch("inputs")
    %w[name version platform sha256 mode].each do |name|
      assert_equal true, inputs.fetch(name).fetch("required"), name
    end
    assert_equal "ruby", inputs.fetch("platform").fetch("default")
    assert_equal %w[build_load upstream], inputs.fetch("mode").fetch("options")
  end

  def test_permissions_runner_timeout_and_no_matrix_are_bounded
    assert_equal({ "contents" => "read" }, @workflow.fetch("permissions"))
    assert_equal({ "preflight" => 10, "build_load" => 30, "upstream" => 90 },
                 @jobs.transform_values { |job| job.fetch("timeout-minutes") })
    @jobs.each_value { |job| refute job.key?("strategy"), "candidate validation must not be a matrix" }
    @jobs.each_value { |job| assert_equal "ubuntu-24.04", job.fetch("runs-on") }
  end

  def test_checkout_does_not_persist_credentials_and_cache_is_not_used
    all_steps.select { |step| step["uses"] == "actions/checkout@v7" }.each do |checkout|
      assert_equal false, checkout.fetch("with").fetch("persist-credentials")
    end
    refute run_scripts.match?(/actions\/cache|cache-(?:restore|save)/i)
    refute File.read(WORKFLOW).match?(/secrets\./)
  end

  def test_candidate_values_are_environment_inputs_to_the_ruby_tool
    %w[CANDIDATE_NAME CANDIDATE_VERSION CANDIDATE_PLATFORM CANDIDATE_SHA256].each do |key|
      assert_includes File.read(WORKFLOW), "#{key}: ${{ inputs."
    end
    run_scripts.lines.each do |line|
      refute_includes line, "inputs.name", "dispatch input must not be concatenated in a shell command"
      refute_includes line, "inputs.version", "dispatch input must not be concatenated in a shell command"
    end
    assert_includes run_scripts, "tools/verify_corpus_candidate.rb"
    assert_includes run_scripts, "--preflight-only"
  end

  def test_build_load_and_upstream_control_are_separate
    build = @jobs.fetch("build_load")
    upstream = @jobs.fetch("upstream")
    assert_includes build.fetch("steps").map { |step| step["name"] },
                    "Build and load the candidate in an isolated GEM_HOME"
    upstream_names = upstream.fetch("steps").map { |step| step["name"] }
    assert_includes upstream_names, "Run the host compiler control recipe"
    assert_includes upstream_names, "Run the rubycc upstream recipe without updating the database"
    assert_includes run_scripts, "verify_gem_tests.rb --control"
    assert_includes run_scripts, "verify_gem_tests.rb --json"
    refute_includes File.read(WORKFLOW), "--update"
  end

  def test_uploaded_reports_are_structured_and_short_lived
    uploads = all_steps.select { |step| step["uses"] == "actions/upload-artifact@v7" }
    refute_empty uploads
    uploads.each do |upload|
      options = upload.fetch("with")
      assert_equal "14", options.fetch("retention-days").to_s
      paths = options.fetch("path")
      refute_includes paths, ".gem"
      refute_includes paths, "GEM_HOME"
      refute_includes paths, "unpacked"
    end
  end
end
