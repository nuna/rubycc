# frozen_string_literal: true

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

  def test_workflow_tool_does_not_offer_database_update_mode
    source = File.read(File.expand_path("../tools/verify_corpus_candidate.rb", __dir__))

    refute_includes source, "data/verified_gems.json"
    refute_includes source, "--update"
  end

  def test_extension_root_gate_allows_ext_and_descendants_only
    refute CorpusCandidateValidation.extension_root_outside_census?("ext")
    refute CorpusCandidateValidation.extension_root_outside_census?("ext/native")
    assert CorpusCandidateValidation.extension_root_outside_census?("lib/native")
  end
end
