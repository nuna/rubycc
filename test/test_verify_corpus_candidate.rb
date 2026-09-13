# frozen_string_literal: true

require "tmpdir"

require_relative "test_helper"
require_relative "../tools/verify_corpus_candidate"

class TestVerifyCorpusCandidate < Minitest::Test
  Input = CorpusCandidateValidation::Input

  def valid_env
    {
      "CANDIDATE_NAME" => "json",
      "CANDIDATE_VERSION" => "2.21.1",
      "CANDIDATE_PLATFORM" => "ruby",
      "CANDIDATE_SHA256" => "a" * 64,
      "CANDIDATE_MODE" => "build_load",
      "CANDIDATE_WORK" => "/tmp/corpus-candidate-validation-test",
      "CANDIDATE_RESULT" => "/tmp/corpus-candidate-validation-test/result.json"
    }
  end

  def test_input_accepts_fixed_ruby_candidate
    input = Input.from_env(valid_env)

    assert_nil input.validate!
    assert_equal "json", input.input_json.fetch("name")
    assert_equal "build_load", input.input_json.fetch("mode")
    assert_equal "rubycc", input.input_json.fetch("compiler")
  end

  def test_input_accepts_documented_load_sanity_and_host_control
    input = Input.from_env(valid_env.merge("CANDIDATE_MODE" => "load_sanity",
                                           "CANDIDATE_COMPILER" => "host"))

    assert_nil input.validate!
    assert_equal "load_sanity", input.input_json.fetch("mode")
    assert_equal "host", input.input_json.fetch("compiler")
  end

  def test_input_rejects_shell_metacharacters_in_name
    env = valid_env.merge("CANDIDATE_NAME" => "json; touch /tmp/unexpected")

    error = assert_raises(ArgumentError) { Input.from_env(env).validate! }
    assert_includes error.message, "unsafe characters"
  end

  def test_input_rejects_missing_or_malformed_sha
    [nil, "not-a-sha", "a" * 63].each do |sha|
      error = assert_raises(ArgumentError) do
        Input.from_env(valid_env.merge("CANDIDATE_SHA256" => sha)).validate!
      end
      assert_includes error.message, "SHA-256"
    end
  end

  def test_input_rejects_non_ruby_platform_and_unknown_mode
    platform_error = assert_raises(ArgumentError) do
      Input.from_env(valid_env.merge("CANDIDATE_PLATFORM" => "x86_64-linux")).validate!
    end
    assert_includes platform_error.message, "platform must be ruby"

    mode_error = assert_raises(ArgumentError) do
      Input.from_env(valid_env.merge("CANDIDATE_MODE" => "arbitrary_command")).validate!
    end
    assert_includes mode_error.message, "mode must be one of"

    compiler_error = assert_raises(ArgumentError) do
      Input.from_env(valid_env.merge("CANDIDATE_COMPILER" => "arbitrary_command")).validate!
    end
    assert_includes compiler_error.message, "compiler must be one of"
  end

  def test_fixed_load_recipe_requires_exact_candidate_identity
    recipe = CorpusCandidateLoadRecipes.find(
      name: "graphql-c_parser", version: "1.1.4", platform: "ruby",
      sha256: "8d3bf769ae935373ada877fe003036892b45be98c2fbcc6731dd82af2c3e0656"
    )

    refute_nil recipe
    assert_equal ["graphql/c_parser"], recipe.dig("entrypoint", "requires")
    assert_equal "graphql_c_parser", recipe.dig("entrypoint", "sanity_kind")
    assert_nil CorpusCandidateLoadRecipes.find(
      name: "graphql-c_parser", version: "1.1.4", platform: "ruby", sha256: "b" * 64
    )
    refute recipe.values.any? { |value| value.to_s.match?(/command|script|eval/) }
  end

  def test_fixed_load_recipes_require_exact_candidate_identity_for_ox_kgio_raindrops
    [
      ["ox", "2.14.29", "206736d5a8dade9dca10cf72022bc157ad6ca3eecaba3853918426ed88e12dc2", ["ox"]],
      ["kgio", "2.11.4", "bda7a2146115998a5b07154e708e0ac02c38dcee7e793c33e2e14f600fdfffc6", ["kgio"]],
      ["raindrops", "0.20.1", "aa0eb9ff6834f2d9e232ba688bd49cb30be893bc5a3452e74722c94c1fab4730", ["raindrops"]]
    ].each do |name, version, sha256, requires|
      recipe = CorpusCandidateLoadRecipes.find(name: name, version: version, platform: "ruby", sha256: sha256)

      refute_nil recipe, "expected a recipe for #{name} #{version}"
      assert_equal requires, recipe.dig("entrypoint", "requires")
      assert_equal "entrypoint_loaded", recipe.dig("entrypoint", "sanity_kind")
      assert_nil CorpusCandidateLoadRecipes.find(name: name, version: version, platform: "ruby", sha256: "b" * 64)
      refute recipe.values.any? { |value| value.to_s.match?(/command|script|eval/) }
    end
  end

  def test_entrypoint_loaded_sanity_kind_is_a_known_branch_in_the_load_script
    Dir.mktmpdir do |dir|
      input = Input.from_env(valid_env.merge("CANDIDATE_WORK" => dir, "CANDIDATE_RESULT" => File.join(dir, "result.json")))
      runner = CorpusCandidateValidation::Runner.new(input)
      recipe = {"entrypoint" => {"requires" => [], "sanity_kind" => "entrypoint_loaded"}}
      script = runner.send(:load_script_for, recipe)

      stub = File.join(dir, "stub.rb")
      File.write(stub, "")

      out, status = Open3.capture2(
        {"VERIFY_REQUIRES" => stub, "VERIFY_SANITY_KIND" => "entrypoint_loaded"},
        RbConfig.ruby, "-e", script, stub
      )

      assert status.success?, out
      assert_includes out, "documented_load=entrypoint_loaded"
    end
  end

  # The (d)-level database stays out of reach of this tool. It never runs the
  # gem's own suite, so it cannot produce the only evidence that file accepts.
  #
  # --update exists (it records a build_load pass in data/buildable_gems.json,
  # a ledger R10 does not count), so "the tool has no update mode" is no longer
  # the invariant; "the tool cannot touch the R10 numerator" is. The dispatched
  # workflow still never passes the flag -- that half is pinned on the workflow
  # file itself by test_corpus_candidate_validation_workflow.rb.
  def test_workflow_tool_cannot_update_the_verified_gems_database
    source = File.read(File.expand_path("../tools/verify_corpus_candidate.rb", __dir__))

    refute_includes source, "verified_gems"
    assert_includes source, "data/buildable_gems.json"
  end

  def test_extension_root_gate_allows_ext_and_descendants_only
    refute CorpusCandidateValidation.extension_root_outside_census?("ext")
    refute CorpusCandidateValidation.extension_root_outside_census?("ext/native")
    assert CorpusCandidateValidation.extension_root_outside_census?("lib/native")
  end
end
