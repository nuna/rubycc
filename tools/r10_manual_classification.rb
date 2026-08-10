#!/usr/bin/env ruby
# frozen_string_literal: true

# Validate and render the human-reviewed R10 classification ledger.
#
# The machine scan remains immutable evidence. This ledger is a separate,
# hand-reviewed layer: it must account for every scanner finding, record the
# selected source/build path, and keep compiler/install/suite verification
# explicitly separate from source classification.

require "date"
require "json"
require "optparse"

ROOT = File.expand_path("..", __dir__)
VERIFY_GEM_TOOL = File.expand_path("verify_gem_tests.rb", __dir__)
require VERIFY_GEM_TOOL

module R10ManualClassification
  module_function

  SCHEMA_VERSION = 2
  TOOL_NAME = "r10_manual_classification"
  MANUAL_STATES = %w[actual_use false_positive needs_more_evidence no_candidate].freeze
  ZERO_REVIEW_STATES = %w[scoped_no_candidate non_target_variadic_wrapper needs_more_evidence].freeze
  ZERO_REVIEW_LABELS = {
    "scoped_no_candidate" => "a0",
    "non_target_variadic_wrapper" => "b0",
    "needs_more_evidence" => "c"
  }.freeze
  SELECTED_IN_BUILD_STATES = %w[
    yes no preprocessor_inactive textual_include generated_checked_in not_applicable
  ].freeze
  GENERATED_SOURCE_STATES = %w[
    not_applicable not_present_in_snapshot checked_in_source generated_checked_in
    generated_not_reproduced textual_include source_snapshot_inspected
  ].freeze
  VERIFICATION_STATES = %w[not_run recorded_not_rerun pass fail inconclusive].freeze
  ARTIFACT_SUITE_STATES = %w[pass fail inconclusive not_run].freeze

  POLICY = {
    "actual_use" => "The selected source/build path uses the candidate in the relevant variadic or va_arg operation.",
    "false_positive" => "Source inspection shows the candidate is not the operation described by the scanner, or is outside the selected extension path.",
    "needs_more_evidence" => "The source/build path cannot establish the operation without generated-source, preprocessor, platform, or compiler evidence.",
    "no_candidate" => "The selected extension source has no scanner finding; this is not an absence proof for generated or gated code.",
    "zero_finding_review" => "A zero-finding target has a separate scoped assessment: a0 (no target operation in the reviewed profile), b0 (non-target variadic code), or c (more evidence required)."
  }.freeze

  def load(path)
    JSON.parse(File.read(path))
  end

  def scan_key(finding)
    [finding.fetch("path"), finding.fetch("line"), finding.fetch("column"), finding.fetch("kind")].join(":")
  end

  def scan_targets(scan)
    scan.fetch("targets").to_h { |target| [target.fetch("name"), target] }
  end

  def init_from_scan(scan, reviewer:, reviewed_at:)
    targets = scan.fetch("targets").map do |target|
      findings = target.dig("scanner", "findings") || []
      source = target.fetch("provenance").fetch("unpacked_relative_path")
      {
        "name" => target.fetch("name"),
        "version" => target.fetch("version"),
        "r10_profile" => target.fetch("r10_profile"),
        "r10_extconf_args" => target.fetch("r10_extconf_args"),
        "provenance" => {
          "gem_url" => target.dig("provenance", "gem_url"),
          "gem_sha256" => target.dig("provenance", "gem_sha256"),
          "source_tarball_sha256" => nil,
          "source_tree_sha256" => nil,
          "source_provenance" => "source tree is unpacked from the cached .gem; source tarball SHA is not separately collected",
          "cache_relative_path" => target.dig("provenance", "cache_relative_path"),
          "unpacked_relative_path" => source
        },
        "selected_build_path" => {
          "source_root" => source,
          "ext_roots" => [],
          "extconf_files" => [],
          "rakefiles" => [],
          "build_entrypoints" => [],
          "translation_units" => [],
          "non_selected_sources" => [],
          "preprocessor_constraints" => [],
          "source_selection_status" => "review_required",
          "generated_source" => {
            "status" => "review_required",
            "files" => [],
            "commands" => []
          },
          "selection_basis" => "manual review required; machine scan inventory is not a build selection proof"
        },
        "manual" => findings.empty? ? "no_candidate" : "needs_more_evidence",
        "rationale" => "REVIEW_REQUIRED",
        "candidate_reviews" => findings.map do |finding|
          {
            "finding_key" => scan_key(finding),
            "classification" => "needs_more_evidence",
            "selected_in_build" => "unknown",
            "rationale" => "REVIEW_REQUIRED",
            "source_evidence" => [],
            "control_rubycc_required" => true
          }
        end,
        "zero_finding_review" => findings.empty? ? {
          "classification" => "needs_more_evidence",
          "profile_scope" => "REVIEW_REQUIRED",
          "selected_in_build" => "unknown",
          "rationale" => "REVIEW_REQUIRED",
          "source_evidence" => [],
          "follow_up" => {
            "required" => true,
            "next_action" => "REVIEW_REQUIRED",
            "owner" => "REVIEW_REQUIRED",
            "due" => "1970-01-01"
          }
        } : nil,
        "unresolved" => ["Manual source/build-path review is required."],
        "verification" => {
          "control" => "not_run",
          "rubycc" => "not_run",
          "extension_load" => "not_run",
          "upstream_suite" => "not_run"
        },
        "verification_evidence" => {
          "control" => { "state" => "not_run", "environment" => nil, "run_id" => nil, "artifact" => nil, "evidence" => [] },
          "rubycc" => { "state" => "not_run", "environment" => nil, "run_id" => nil, "artifact" => nil, "evidence" => [] },
          "extension_load" => { "state" => "not_run", "environment" => nil, "run_id" => nil, "artifact" => nil, "evidence" => [] },
          "upstream_suite" => { "state" => "not_run", "environment" => nil, "run_id" => nil, "artifact" => nil, "evidence" => [] }
        },
        "reviewer" => reviewer,
        "reviewed_at" => reviewed_at
      }
    end

    {
      "schema_version" => SCHEMA_VERSION,
      "tool" => TOOL_NAME,
      "source_scan" => "data/r10_corpus_scan.json",
      "review_policy" => POLICY,
      "targets" => targets
    }
  end

  def artifact_path(relative)
    return nil unless relative.is_a?(String) && !relative.empty? && !relative.start_with?("/")

    path = File.expand_path(relative, ROOT)
    return nil unless path == ROOT || path.start_with?(ROOT + "/")
    return nil unless File.file?(path)

    path
  end

  def artifact_result(artifact, name, mode)
    results = artifact.fetch(mode) { [] }
    results.find { |result| result["name"] == name }
  end

  def summary_valid?(result)
    summary = result["summary"]
    return false unless summary.is_a?(Hash)
    return false unless summary["tests"].is_a?(Integer) && summary["tests"].positive?
    return false unless summary["failures"].is_a?(Integer) && summary["errors"].is_a?(Integer)
    return false unless summary["other"].is_a?(Hash)

    summary["failures"].zero? && summary["errors"].zero?
  end

  def summary_shape_valid?(result)
    summary = result["summary"]
    summary.is_a?(Hash) &&
      summary["tests"].is_a?(Integer) && summary["tests"].positive? &&
      summary["failures"].is_a?(Integer) && summary["errors"].is_a?(Integer) &&
      summary["other"].is_a?(Hash)
  end

  def summary_matches_verify_tool?(result)
    return false unless summary_shape_valid?(result)

    summary = result.fetch("summary")
    runner = result.dig("recipe", "runner").to_s.to_sym
    parsed = parse_summary("#{summary.fetch("line")}\n", runner)
    return false unless parsed

    %w[tests assertions failures errors other].all? do |key|
      summary[key] == parsed[key.to_sym]
    end
  rescue KeyError, TypeError
    false
  end

  def non_empty_evidence?(result)
    Array(result["evidence"]).any? { |entry| !entry.to_s.empty? }
  end

  def build_state_for(result)
    return "pass" if result["sanity"] == true && non_empty_evidence?(result)
    return "fail" if result["sanity"] == false
    return "inconclusive" if result["profile_state"] == "inconclusive"
    return "fail" if result["status"] == "fail" && result["sanity"].nil?

    "inconclusive"
  end

  def extension_load_state_for(result)
    case result["sanity"]
    when true then "pass"
    when false then "fail"
    when nil then "not_run"
    else "inconclusive"
    end
  end

  def suite_state_for(result)
    return "pass" if result["status"] == "pass" && summary_valid?(result)
    if result["status"] == "fail" && summary_shape_valid?(result)
      summary = result.fetch("summary")
      return "fail" if summary["failures"].positive? || summary["errors"].positive?
    end
    return "not_run" if result["sanity"].nil? && result["summary"].nil?

    "inconclusive"
  end

  def compiler_suite_state(control, rubycc)
    left = suite_state_for(control)
    right = suite_state_for(rubycc)
    return "not_run" if left == "not_run" && right == "not_run"
    return "pass" if left == "pass" && right == "pass"
    return "fail" if (left == "pass") ^ (right == "pass")

    "inconclusive"
  end

  def expected_recipe(name)
    recipe_evidence(name, RECIPES.fetch(name))
  end

  def validate_result_metadata(errors, name, target, scan_target, artifact, result, mode, expected_state)
    if result.nil?
      errors << "#{name}: #{mode} artifact has no result"
      return
    end

    errors << "#{name}: #{mode} artifact result version differs" unless result["version"] == target["version"]
    errors << "#{name}: #{mode} artifact mode differs" unless result["mode"] == mode
    errors << "#{name}: #{mode} artifact environment differs" unless artifact["environment"] == target.dig("verification_evidence", mode, "environment")

    build_state = build_state_for(result)
    errors << "#{name}: #{mode} build_state is missing or disagrees with derived #{build_state}" unless
      %w[pass fail inconclusive not_run].include?(result["build_state"]) && result["build_state"] == build_state
    errors << "#{name}: #{mode} build state #{build_state} disagrees with ledger #{expected_state}" unless build_state == expected_state

    load_state = extension_load_state_for(result)
    errors << "#{name}: #{mode} extension_load_state is missing or disagrees with derived #{load_state}" unless
      ARTIFACT_SUITE_STATES.include?(result["extension_load_state"]) && result["extension_load_state"] == load_state

    suite_state = suite_state_for(result)
    errors << "#{name}: #{mode} suite_state is missing or disagrees with derived #{suite_state}" unless
      ARTIFACT_SUITE_STATES.include?(result["suite_state"]) && result["suite_state"] == suite_state
    errors << "#{name}: #{mode} summary cannot be reproduced by verify_gem_tests" if
      result["summary"] && !summary_matches_verify_tool?(result)
    if result["status"] == "pass"
      errors << "#{name}: #{mode} pass result has no valid non-empty suite summary" unless
        summary_valid?(result) && summary_matches_verify_tool?(result)
      errors << "#{name}: #{mode} pass result has no explicit pass suite state" unless suite_state == "pass"
    end

    expected_gem_sha = scan_target.dig("provenance", "gem_sha256")
    provenance = result["provenance"]
    unless provenance.is_a?(Hash)
      errors << "#{name}: #{mode} artifact provenance is missing"
      return
    end
    errors << "#{name}: #{mode} artifact gem SHA differs from machine scan" unless provenance["gem_sha256"] == expected_gem_sha
    expected_source = expected_recipe(name)
    errors << "#{name}: #{mode} artifact gem URL differs from the recipe" unless
      provenance["gem_url"] == "https://rubygems.org/downloads/#{name}-#{target["version"]}.gem"
    errors << "#{name}: #{mode} artifact source kind differs from the recipe" unless provenance["source_kind"] == expected_source["source_kind"]
    errors << "#{name}: #{mode} artifact source URL differs from the recipe" unless provenance["source_url"] == expected_source["source_url"]
    errors << "#{name}: #{mode} artifact source SHA is missing or malformed" unless provenance["source_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)

    recipe = result["recipe"]
    errors << "#{name}: #{mode} artifact recipe is missing or does not match current RECIPES" unless recipe == expected_source
    errors << "#{name}: #{mode} artifact execution context is missing" unless result["execution_context"].is_a?(Hash)
    if result["execution_context"].is_a?(Hash)
      errors << "#{name}: #{mode} execution environment differs" unless result.dig("execution_context", "environment") == artifact["environment"]
      errors << "#{name}: #{mode} execution mode differs" unless result.dig("execution_context", "rubycc_mode") == mode
    end
    errors << "#{name}: #{mode} artifact Rubycc revision is missing" if result["rubycc_revision"].to_s.empty?
    errors << "#{name}: #{mode} artifact dirty-state is missing" unless [true, false].include?(result["rubycc_worktree_dirty"])
  rescue KeyError => error
    errors << "#{name}: #{mode} artifact metadata is incomplete: #{error.message}"
  end

  def verification_artifact_errors(target, scan_target, cache)
    errors = []
    name = target.fetch("name")
    evidence = target.fetch("verification_evidence")
    paths = evidence.values.filter_map { |entry| entry["artifact"] }.uniq
    artifacts = paths.to_h do |relative|
      path = artifact_path(relative)
      if path.nil?
        errors << "#{name}: verification artifact must be an existing repository-relative path: #{relative.inspect}"
        next [relative, nil]
      end
      artifact = cache[path] ||= load(path)
      [relative, artifact]
    rescue JSON::ParserError, KeyError => error
      errors << "#{name}: verification artifact #{relative.inspect} is invalid: #{error.message}"
      [relative, nil]
    end

    artifacts.each_value do |artifact|
      next unless artifact

      errors << "#{name}: verification artifact kind is missing" unless artifact["artifact_kind"] == "r10-gem-verification-summary"
      errors << "#{name}: verification artifact schema is not current" unless artifact["schema_version"].to_i >= 2
      errors << "#{name}: verification artifact environment is missing" if artifact["environment"].to_s.empty?
      errors << "#{name}: verification artifact architecture is missing" if artifact["architecture"].to_s.empty?
      errors << "#{name}: verification artifact must state whether it contains AArch64 evidence" unless [true, false].include?(artifact["aarch64_evidence"])
    end

    artifact_for = lambda do |field|
      relative = evidence.dig(field, "artifact")
      [relative, artifacts[relative]]
    end

    result_for = lambda do |field, mode, required|
      relative, artifact = artifact_for.call(field)
      if artifact.nil?
        errors << "#{name}: #{field} artifact is required for ledger state #{target.dig("verification", field)}" if required
        return [relative, nil, nil]
      end

      result = artifact_result(artifact, name, mode)
      errors << "#{name}: #{field} artifact has no #{mode} result" unless result
      [relative, artifact, result]
    end

    %w[control rubycc].each do |field|
      state = target.dig("verification", field)
      _relative, artifact = artifact_for.call(field)
      if state == "recorded_not_rerun"
        errors << "#{name}: #{field} recorded_not_rerun must not point at a measured artifact" if artifact
        next
      end

      required = %w[pass fail inconclusive].include?(state)
      _relative, artifact, result = result_for.call(field, field, required)
      next unless artifact && result
      validate_result_metadata(errors, name, target, scan_target, artifact, result, field, state)
    end

    load_field = "extension_load"
    _load_relative, load_artifact = artifact_for.call(load_field)
    load_expected = target.dig("verification", load_field)
    if load_artifact.nil?
      errors << "#{name}: extension_load artifact is required for ledger state #{load_expected}" if %w[pass fail inconclusive].include?(load_expected)
    else
      control = artifact_result(load_artifact, name, "control")
      rubycc = artifact_result(load_artifact, name, "rubycc")
      if control && rubycc
        validate_result_metadata(errors, name, target, scan_target, load_artifact, control, "control", target.dig("verification", "control"))
        validate_result_metadata(errors, name, target, scan_target, load_artifact, rubycc, "rubycc", target.dig("verification", "rubycc"))
        control_state = extension_load_state_for(control)
        rubycc_state = extension_load_state_for(rubycc)
        derived = if control_state == "pass" && rubycc_state == "pass"
                    "pass"
                  elsif control_state == "not_run" && rubycc_state == "not_run"
                    "not_run"
                  elsif [control_state, rubycc_state].include?("fail")
                    "fail"
                  else
                    "inconclusive"
                  end
        errors << "#{name}: extension load state #{derived} disagrees with ledger #{load_expected}" unless derived == load_expected
      else
        errors << "#{name}: extension_load artifact must contain both control and rubycc results"
      end
    end

    suite_field = "upstream_suite"
    _suite_relative, suite_artifact = artifact_for.call(suite_field)
    suite_expected = target.dig("verification", suite_field)
    if suite_artifact.nil?
      errors << "#{name}: upstream_suite artifact is required for ledger state #{suite_expected}" if %w[pass fail inconclusive].include?(suite_expected)
    else
      control = artifact_result(suite_artifact, name, "control")
      rubycc = artifact_result(suite_artifact, name, "rubycc")
      if control && rubycc
        validate_result_metadata(errors, name, target, scan_target, suite_artifact, control, "control", target.dig("verification", "control"))
        validate_result_metadata(errors, name, target, scan_target, suite_artifact, rubycc, "rubycc", target.dig("verification", "rubycc"))
        derived = compiler_suite_state(control, rubycc)
        errors << "#{name}: upstream suite state #{derived} disagrees with ledger #{suite_expected}" unless derived == suite_expected
      else
        errors << "#{name}: upstream_suite artifact must contain both control and rubycc results"
      end
    end

    errors.uniq
  end

  def validate(ledger, scan)
    errors = []
    artifact_cache = {}
    errors << "schema_version must be #{SCHEMA_VERSION}" unless ledger["schema_version"] == SCHEMA_VERSION
    errors << "tool must be #{TOOL_NAME}" unless ledger["tool"] == TOOL_NAME
    errors << "review_policy is incomplete" unless POLICY.keys.all? { |key| ledger.dig("review_policy", key) == POLICY[key] }

    expected = scan_targets(scan)
    actual = ledger.fetch("targets", [])
    names = actual.map { |target| target["name"] }
    errors << "target names are duplicated" unless names.uniq.size == names.size
    errors << "target set differs: #{(expected.keys - names).inspect} / #{(names - expected.keys).inspect}" unless names.sort == expected.keys.sort

    actual.each do |target|
      name = target["name"] || "<missing name>"
      source = expected[name]
      unless source
        errors << "#{name}: missing from machine scan"
        next
      end

      errors << "#{name}: version differs" unless target["version"] == source["version"]
      errors << "#{name}: profile differs" unless target["r10_profile"] == source["r10_profile"]
      errors << "#{name}: extconf args differ" unless target["r10_extconf_args"] == source["r10_extconf_args"]
      errors << "#{name}: gem SHA differs" unless target.dig("provenance", "gem_sha256") == source.dig("provenance", "gem_sha256")
      errors << "#{name}: source_tarball_sha256 key is missing" unless target.dig("provenance").key?("source_tarball_sha256")
      errors << "#{name}: source_tree_sha256 is missing" if target.dig("provenance", "source_tree_sha256").to_s.empty?
      errors << "#{name}: source_provenance is missing" if target.dig("provenance", "source_provenance").to_s.empty?
      errors << "#{name}: source path must be relative" if target.dig("provenance", "unpacked_relative_path").to_s.start_with?("/")

      manual = target["manual"]
      errors << "#{name}: invalid manual state #{manual.inspect}" unless MANUAL_STATES.include?(manual)
      errors << "#{name}: rationale is missing" if target["rationale"].to_s.empty? || target["rationale"] == "REVIEW_REQUIRED"
      errors << "#{name}: reviewer is missing" if target["reviewer"].to_s.empty?
      begin
        Date.iso8601(target.fetch("reviewed_at"))
      rescue ArgumentError, KeyError
        errors << "#{name}: reviewed_at must be ISO-8601 date"
      end

      path = target["selected_build_path"] || {}
      %w[source_root ext_roots extconf_files rakefiles build_entrypoints translation_units non_selected_sources preprocessor_constraints source_selection_status generated_source selection_basis].each do |key|
        errors << "#{name}: selected_build_path.#{key} is missing" unless path.key?(key)
      end
      errors << "#{name}: generated-source status is unresolved" if path.dig("generated_source", "status") == "review_required"
      errors << "#{name}: invalid generated-source status" unless GENERATED_SOURCE_STATES.include?(path.dig("generated_source", "status"))
      errors << "#{name}: source selection status is unresolved" if path["source_selection_status"].to_s.empty? || path["source_selection_status"] == "review_required"
      errors << "#{name}: source root must be relative" if path["source_root"].to_s.start_with?("/")
      %w[ext_roots extconf_files rakefiles build_entrypoints translation_units non_selected_sources].each do |key|
        Array(path[key]).each do |value|
          errors << "#{name}: #{key} contains an absolute path" if value.to_s.start_with?("/")
        end
      end
      errors << "#{name}: unresolved item is still REVIEW_REQUIRED" if Array(target["unresolved"]).any? { |item| item == "Manual source/build-path review is required." }

      findings = source.dig("scanner", "findings") || []
      expected_keys = findings.map { |finding| scan_key(finding) }
      reviews = target.fetch("candidate_reviews", [])
      review_keys = reviews.map { |review| review["finding_key"] }
      errors << "#{name}: candidate review keys differ" unless review_keys.sort == expected_keys.sort
      errors << "#{name}: candidate review keys are duplicated" unless review_keys.uniq.size == review_keys.size
      reviews.each do |review|
        unless MANUAL_STATES.include?(review["classification"]) && review["classification"] != "no_candidate"
          errors << "#{name}: invalid candidate classification #{review["classification"].inspect}"
        end
        errors << "#{name}: candidate #{review["finding_key"]} rationale is missing" if review["rationale"].to_s.empty? || review["rationale"] == "REVIEW_REQUIRED"
        errors << "#{name}: candidate #{review["finding_key"]} lacks source evidence" if Array(review["source_evidence"]).empty?
        errors << "#{name}: candidate #{review["finding_key"]} has invalid selected_in_build" unless SELECTED_IN_BUILD_STATES.include?(review["selected_in_build"])
      end

      if findings.empty?
        errors << "#{name}: no-candidate target must not have candidate reviews" unless reviews.empty?
        errors << "#{name}: zero-finding target must use no_candidate" unless manual == "no_candidate"
        zero_review = target["zero_finding_review"] || {}
        zero_state = zero_review["classification"]
        errors << "#{name}: zero-finding assessment is missing" unless ZERO_REVIEW_STATES.include?(zero_state)
        errors << "#{name}: zero-finding profile_scope is missing" if zero_review["profile_scope"].to_s.empty? || zero_review["profile_scope"] == "REVIEW_REQUIRED"
        errors << "#{name}: zero-finding selected_in_build is invalid" unless SELECTED_IN_BUILD_STATES.include?(zero_review["selected_in_build"])
        errors << "#{name}: zero-finding rationale is missing" if zero_review["rationale"].to_s.empty? || zero_review["rationale"] == "REVIEW_REQUIRED"
        errors << "#{name}: zero-finding source evidence is missing" if Array(zero_review["source_evidence"]).empty?
        if zero_state == "needs_more_evidence"
          follow_up = zero_review["follow_up"] || {}
          errors << "#{name}: zero-finding follow-up is required" unless follow_up["required"] == true
          errors << "#{name}: zero-finding next action is missing" if follow_up["next_action"].to_s.empty? || follow_up["next_action"] == "REVIEW_REQUIRED"
          errors << "#{name}: zero-finding owner is missing" if follow_up["owner"].to_s.empty? || follow_up["owner"] == "REVIEW_REQUIRED"
          begin
            Date.iso8601(follow_up.fetch("due"))
          rescue ArgumentError, KeyError
            errors << "#{name}: zero-finding due must be ISO-8601 date"
          end
        elsif zero_review.dig("follow_up", "required") == true
          errors << "#{name}: non-c zero-finding assessment cannot require follow-up"
        end
      elsif manual == "no_candidate"
        errors << "#{name}: target with findings cannot be no_candidate"
      else
        errors << "#{name}: candidate target must not have zero-finding assessment" unless target["zero_finding_review"].nil?
        expected_manual = if reviews.any? { |review| review["classification"] == "actual_use" }
                            "actual_use"
                          elsif reviews.any? { |review| review["classification"] == "needs_more_evidence" }
                            "needs_more_evidence"
                          else
                            "false_positive"
                          end
        errors << "#{name}: manual state #{manual.inspect} disagrees with candidate classifications (expected #{expected_manual})" unless manual == expected_manual
      end

      verification = target.fetch("verification", {})
      errors << "#{name}: verification fields are incomplete" unless verification.keys.sort == %w[control extension_load rubycc upstream_suite].sort
      verification.each do |field, state|
        errors << "#{name}: invalid verification state #{field}=#{state.inspect}" unless VERIFICATION_STATES.include?(state)
      end
      verification_evidence = target.fetch("verification_evidence", {})
      errors << "#{name}: verification_evidence fields are incomplete" unless verification_evidence.keys.sort == verification.keys.sort
      verification_evidence.each do |field, evidence|
        errors << "#{name}: verification_evidence.#{field}.state disagrees" unless evidence["state"] == verification[field]
        errors << "#{name}: verification_evidence.#{field}.evidence is missing" if %w[pass fail inconclusive].include?(verification[field]) && Array(evidence["evidence"]).empty?
        if %w[pass fail inconclusive].include?(verification[field])
          errors << "#{name}: verification_evidence.#{field}.environment is missing" if evidence["environment"].to_s.empty?
          errors << "#{name}: verification_evidence.#{field}.artifact or run_id is missing" if evidence["artifact"].to_s.empty? && evidence["run_id"].to_s.empty?
        end
      end
      errors.concat(verification_artifact_errors(target, source, artifact_cache))
    end

    errors
  end

  def markdown(ledger, scan)
    by_name = scan_targets(scan)
    lines = []
    lines << "# R10 manual classification"
    lines << ""
    lines << "This is a human-reviewed source/build-path ledger for the 34 machine-gate targets. It does not by itself prove gem install, extension load, or upstream-suite success."
    lines << ""
    lines << "## Summary"
    lines << ""
    counts = ledger.fetch("targets").group_by { |target| target.fetch("manual") }.transform_values(&:size)
    zero_counts = ledger.fetch("targets").select { |target| (by_name.fetch(target.fetch("name")).dig("scanner", "findings") || []).empty? }.group_by { |target| target.dig("zero_finding_review", "classification") }.transform_values(&:size)
    lines << "| target count | actual use | false positive | needs more evidence | no candidate |"
    lines << "|---:|---:|---:|---:|---:|"
    lines << "| #{ledger.fetch("targets").size} | #{counts.fetch("actual_use", 0)} | #{counts.fetch("false_positive", 0)} | #{counts.fetch("needs_more_evidence", 0)} | #{counts.fetch("no_candidate", 0)} |"
    lines << ""
    lines << "Zero-finding scoped assessments: `a0`=#{zero_counts.fetch("scoped_no_candidate", 0)}, `b0`=#{zero_counts.fetch("non_target_variadic_wrapper", 0)}, `c`=#{zero_counts.fetch("needs_more_evidence", 0)}. These labels do not replace the machine-scan state `no_candidate`; `c` is not a pass."
    lines << ""
    lines << "`no_candidate` means the selected extension source had no lexical candidate. It is not an absence proof for generated code or unselected platform branches. `source_tree_sha256` identifies the reviewed unpacked snapshot; `source_tarball_sha256` is null because it was not separately collected. Verification fields remain explicit when not run."
    lines << ""
    lines << "## Critical review and integration"
    lines << ""
    lines << "Three independent source reviews were integrated. They found that the first draft overclaimed the zero-result set and listed inventory files as compiler-selected units. The ledger now separates declared source selection from compiler verification, includes root-source/textual-include/generated-source boundaries, records nkf preprocessor exclusion and http_parser.rb vendor exclusions, and keeps external-library/profile risks unresolved."
    lines << ""
    lines << "The resulting trade-off is deliberate: 20 zero-finding targets are `a0` only within their declared profile, one is `b0` because non-target va_list formatting exists, and eight are `c` until preprocessed/source-selection or external-ABI evidence is collected. This improves false-pass resistance at the cost of leaving R10 source classification and install/suite acceptance incomplete."
    lines << ""
    lines << "## Target ledger"
    lines << ""
    lines << "| gem | version | profile | manual | zero review | findings | selected source/build path | generated source | control | rubycc | extension load | upstream suite |"
    lines << "|---|---|---|---|---|---:|---|---|---|---|---|---|"
    ledger.fetch("targets").each do |target|
      source = by_name.fetch(target.fetch("name"))
      path = target.fetch("selected_build_path")
      generated = path.dig("generated_source", "status")
      verification = target.fetch("verification")
      zero_review = target["zero_finding_review"]
      zero_label = zero_review ? "#{ZERO_REVIEW_LABELS.fetch(zero_review.fetch("classification"))} / #{zero_review.fetch("classification")}" : "—"
      lines << "| #{target["name"]} | #{target["version"]} | #{target["r10_profile"]} | #{target["manual"]} | #{zero_label} | #{source.dig("scanner", "summary", "total_findings")} | `#{path["source_root"]}`; ext=#{path["ext_roots"].join(", ")} | #{generated} | #{verification["control"]} | #{verification["rubycc"]} | #{verification["extension_load"]} | #{verification["upstream_suite"]} |"
    end
    lines << ""
    recorded = ledger.fetch("targets").select do |target|
      target.fetch("verification").values.any? { |state| state != "not_run" }
    end
    unless recorded.empty?
      lines << "## Recorded verification evidence"
      lines << ""
      lines << "These are local x86_64 / Ruby evidence records. They do not establish AArch64 behavior. Build, extension load, and upstream-suite claims remain separate; an identical control/rubycc suite failure is recorded as `inconclusive`, never as a pass."
      lines << ""
      recorded.each do |target|
        lines << "### #{target["name"]} #{target["version"]}"
        lines << ""
        target.fetch("verification_evidence").each do |field, evidence|
          next if evidence.fetch("state") == "not_run"

          lines << "- `#{field}`: **#{evidence.fetch("state")}**, environment=`#{evidence.fetch("environment")}`, run=`#{evidence.fetch("run_id")}`, artifact=`#{evidence.fetch("artifact")}` — #{Array(evidence.fetch("evidence")).join("; ")}"
        end
        lines << ""
      end
    end
    lines << "## Zero-finding assessments"
    lines << ""
    ledger.fetch("targets").each do |target|
      review = target["zero_finding_review"]
      next unless review

      lines << "- `#{target["name"]} #{target["version"]}`: **#{ZERO_REVIEW_LABELS.fetch(review.fetch("classification"))}** (`#{review.fetch("classification")}`), scope=`#{review.fetch("profile_scope")}`, selected=`#{review.fetch("selected_in_build")}` — #{review.fetch("rationale")}"
      lines << "  - source evidence: #{Array(review["source_evidence"]).join("; ")}"
      if review.dig("follow_up", "required")
        lines << "  - follow-up: #{review.dig("follow_up", "next_action")} (owner=#{review.dig("follow_up", "owner")}, due=#{review.dig("follow_up", "due")})"
      end
    end
    lines << ""
    lines << "## Candidate review details"
    lines << ""
    ledger.fetch("targets").each do |target|
      next if target.fetch("candidate_reviews").empty?

      lines << "### #{target["name"]} #{target["version"]}"
      lines << ""
      target.fetch("candidate_reviews").each do |review|
        lines << "- `#{review["finding_key"]}`: **#{review["classification"]}**, selected=`#{review["selected_in_build"]}` — #{review["rationale"]}"
        lines << "  - source evidence: #{Array(review["source_evidence"]).join("; ")}"
      end
      lines << ""
    end
    lines.join("\n")
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    artifact: File.join(ROOT, "data", "r10_manual_classification.json"),
    scan: File.join(ROOT, "data", "r10_corpus_scan.json"),
    markdown: File.join(ROOT, "docs", "R10-MANUAL-CLASSIFICATION.md")
  }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/r10_manual_classification.rb [options]"
    opts.on("--init-from-scan", "write a draft ledger from the machine scan") { options[:init] = true }
    opts.on("--validate", "validate the committed ledger") { options[:validate] = true }
    opts.on("--render", "validate and render the Markdown report") { options[:render] = true }
    opts.on("--artifact PATH") { |value| options[:artifact] = value }
    opts.on("--scan PATH") { |value| options[:scan] = value }
    opts.on("--markdown PATH") { |value| options[:markdown] = value }
  end
  parser.parse!

  scan = R10ManualClassification.load(options[:scan])
  if options[:init]
    ledger = R10ManualClassification.init_from_scan(scan, reviewer: "REVIEW_REQUIRED", reviewed_at: "1970-01-01")
    File.write(options[:artifact], JSON.pretty_generate(ledger) + "\n")
    puts "wrote draft #{options[:artifact]}"
    exit 0
  end

  ledger = R10ManualClassification.load(options[:artifact])
  errors = R10ManualClassification.validate(ledger, scan)
  abort errors.map { |error| "ERROR: #{error}" }.join("\n") unless errors.empty?
  puts "r10_manual_classification: OK (#{ledger.fetch("targets").size} targets)"
  if options[:render]
    File.write(options[:markdown], R10ManualClassification.markdown(ledger, scan))
    puts "wrote #{options[:markdown]}"
  end
end
