# frozen_string_literal: true

require "json"
require "minitest/autorun"

class TestR10CorpusScan < Minitest::Test
  ARTIFACT = File.expand_path("../data/r10_corpus_scan.json", __dir__)

  def setup
    @artifact = JSON.parse(File.read(ARTIFACT))
  end

  def test_snapshot_records_the_current_machine_gate_boundary
    gate = @artifact.fetch("machine_gate")
    assert_equal 39, gate.fetch("candidate_count")
    assert_equal 34, gate.fetch("status_ok_count")
    assert_equal 5, gate.fetch("excluded_count")
    assert_equal 0, gate.fetch("skipped_count")
    assert_equal 29, gate.fetch("verified_record_count")
    assert_equal 34, gate.fetch("manual_classification_pending_count")
  end

  def test_every_target_has_provenance_and_explicit_pending_evidence
    targets = @artifact.fetch("targets")
    assert_equal 34, targets.size

    targets.each do |target|
      sha = target.dig("provenance", "gem_sha256")
      assert_match(/\A[0-9a-f]{64}\z/, sha, target.fetch("name"))
      assert_nil target.dig("provenance", "source_tarball_sha256")
      assert_equal "pending", target.dig("classification", "manual")
      assert_equal "not-reviewed", target.dig("generated_source", "status")
      assert_equal "not-run-by-this-scan", target.dig("verification", "control")
      assert_equal "not-run-by-this-scan", target.dig("verification", "rubycc")
      assert_equal true, target.dig("scanner", "not_proof")
      assert_equal true, target.dig("scanner", "not_acceptance_gate")
    end
  end

  def test_profiles_keep_their_exact_machine_gate_arguments
    profiles = @artifact.fetch("targets").to_h { |target| [target.fetch("name"), target] }
    assert_equal "pg-native-source", profiles.fetch("pg").fetch("r10_profile")
    assert_equal [], profiles.fetch("pg").fetch("r10_extconf_args")
    assert_equal "sqlite3-system-libraries", profiles.fetch("sqlite3").fetch("r10_profile")
    assert_equal ["--enable-system-libraries"], profiles.fetch("sqlite3").fetch("r10_extconf_args")
  end

  def test_machine_exclusions_are_not_represented_as_pending_targets
    excluded = @artifact.fetch("excluded").to_h { |entry| [entry.fetch("name"), entry] }
    assert_equal %w[byebug debug fcntl thin unicorn], excluded.keys.sort
    assert_empty(@artifact.fetch("targets").map { |target| target.fetch("name") } & excluded.keys)
  end
end
