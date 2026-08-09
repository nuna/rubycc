# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"
require_relative "../tools/ci_result"
require_relative "../tools/ci_check_acceptance"
require_relative "support/acceptance_fetch_helper"
require_relative "support/acceptance_result_reporter"

class TestCIResult < Minitest::Test
  def test_document_round_trips_structured_result
    Dir.mktmpdir do |dir|
      path = File.join(dir, "results.json")
      Rubycc::CIResult.write(
        path,
        results: [Rubycc::CIResult.result(
          id: "mkmf-json-extconf", state: "pass", profile: "acceptance-fixture",
          runner: "native", network: "fixture"
        )],
        metadata: { profile: "acceptance-fixture" }
      )

      document = Rubycc::CIResult.read(path)
      assert_equal 1, document.fetch("version")
      assert_equal "pass", document.fetch("results").first.fetch("state")
      assert_equal "fixture", document.fetch("results").first.fetch("network")
      assert_equal "acceptance-fixture", document.fetch("metadata").fetch("profile")
    end
  end

  def test_committed_acceptance_manifest_is_valid_and_not_expired
    path = File.expand_path("../config/ci/acceptance_manifest.json", __dir__)
    manifest = Rubycc::CICheckAcceptance.load_manifest(path)
    assert_equal ["acceptance-fixture", "acceptance-live", "native-aarch64-smoke"],
                 manifest.fetch("profile_context").keys.sort
    assert_equal 15, manifest.fetch("required").length
    assert_equal manifest.fetch("required").length,
                 manifest.fetch("required").map { |entry| entry.fetch("id") }.uniq.length
    assert_equal 4, manifest.fetch("artifacts").length
    assert manifest.fetch("artifacts").all? { |entry| entry.fetch("sha256").match?(/\A[0-9a-f]{64}\z/) }
    live_entries = manifest.fetch("required").select { |entry| entry.fetch("profiles").include?("acceptance-live") }
    assert live_entries.reject { |entry| entry.fetch("id") == "acceptance-live-preflight" }
      .all? { |entry| entry.fetch("artifacts").any? }
  end

  def test_artifact_report_loader_rejects_duplicate_or_malformed_records
    report = [{
      "id" => "artifact", "kind" => "gem", "url" => "https://example.invalid/a.gem",
      "expected_sha256" => "0" * 64, "actual_sha256" => "0" * 64,
      "bytes" => 1, "cache_hit" => false
    }]
    loaded = Rubycc::CICheckAcceptance.load_artifact_report(write_json(report))
    assert_equal false, loaded.fetch("artifact").fetch("cache_hit")

    error = assert_raises(Rubycc::CIResult::Error) do
      Rubycc::CICheckAcceptance.load_artifact_report(write_json(report + report))
    end
    assert_includes error.message, "duplicate artifact report IDs"
  end

  def test_manifest_rejects_an_unpinned_or_non_https_artifact
    manifest = {
      "version" => 1,
      "artifacts" => [{
        "id" => "artifact",
        "kind" => "gem",
        "url" => "http://example.invalid/artifact.gem",
        "sha256" => "0" * 63
      }],
      "required" => []
    }
    error = assert_raises(Rubycc::CIResult::Error) do
      Rubycc::CICheckAcceptance.load_manifest(write_json(manifest))
    end
    assert_match(/HTTPS URL|64 hexadecimal/, error.message)
  end

  def test_rejects_unknown_state_and_duplicate_manifest_ids
    error = assert_raises(Rubycc::CIResult::Error) do
      Rubycc::CIResult.result(id: "x", state: "green")
    end
    assert_includes error.message, "unsupported result state"

    manifest = { "version" => 1, "required" => [{ "id" => "x" }, { "id" => "x" }] }
    error = assert_raises(Rubycc::CIResult::Error) do
      Rubycc::CICheckAcceptance.load_manifest(write_json(manifest))
    end
    assert_includes error.message, "duplicate"
  end

  def test_checker_detects_missing_and_strict_skipped_results
    manifest = {
      "version" => 1,
      "required" => [
        { "id" => "fixture-pass", "allowed_states" => ["pass"] },
        { "id" => "fixture-skip", "allowed_states" => ["pass"] },
        { "id" => "fixture-missing", "allowed_states" => ["pass"] }
      ]
    }
    results = Rubycc::CIResult.document(results: [
      Rubycc::CIResult.result(id: "fixture-pass", state: "pass"),
      Rubycc::CIResult.result(id: "fixture-skip", state: "skipped", reason: "offline")
    ])

    report = Rubycc::CICheckAcceptance.check(manifest: manifest, results: results, strict: true)
    refute report.fetch("ok")
    assert_equal 2, report.fetch("problems").length
    assert report.fetch("problems").any? { |message| message.include?("fixture-skip") }
    assert report.fetch("problems").any? { |message| message.include?("fixture-missing") }
  end

  def test_inconclusive_is_not_allowed_by_default
    manifest = { "version" => 1, "required" => [{ "id" => "live", "allowed_states" => ["pass"] }] }
    results = Rubycc::CIResult.document(results: [
      Rubycc::CIResult.result(id: "live", state: "inconclusive", reason: "rubygems unavailable")
    ])

    report = Rubycc::CICheckAcceptance.check(manifest: manifest, results: results)
    refute report.fetch("ok")
    assert_includes report.fetch("problems").first, "inconclusive"

    allowed = Rubycc::CICheckAcceptance.check(
      manifest: manifest, results: results, allow_inconclusive: true
    )
    assert allowed.fetch("ok"), "the caller must opt in explicitly to inconclusive results"

    strict_allowed = Rubycc::CICheckAcceptance.check(
      manifest: manifest, results: results, strict: true, allow_inconclusive: true
    )
    refute strict_allowed.fetch("ok"), "strict acceptance must never green-light inconclusive results"
  end

  def test_checker_only_requires_ids_for_the_selected_profile
    manifest = {
      "version" => 1,
      "required" => [
        { "id" => "fixture", "profiles" => ["acceptance-fixture"], "allowed_states" => ["pass"] },
        { "id" => "live", "profiles" => ["acceptance-live"], "allowed_states" => ["pass"] }
      ]
    }
    results = Rubycc::CIResult.document(results: [
      Rubycc::CIResult.result(id: "fixture", state: "pass", profile: "acceptance-fixture")
    ])

    report = Rubycc::CICheckAcceptance.check(
      manifest: manifest, results: results, profile: "acceptance-fixture", strict: true
    )
    assert report.fetch("ok")
    assert_equal ["fixture"], report.fetch("checked").map { |entry| entry.fetch("id") }
  end

  def test_checker_rejects_a_result_from_another_profile
    manifest = {
      "version" => 1,
      "required" => [{ "id" => "fixture", "profiles" => ["acceptance-fixture"], "allowed_states" => ["pass"] }]
    }
    results = Rubycc::CIResult.document(results: [
      Rubycc::CIResult.result(id: "fixture", state: "pass", profile: "acceptance-live")
    ])

    report = Rubycc::CICheckAcceptance.check(
      manifest: manifest, results: results, profile: "acceptance-fixture"
    )
    refute report.fetch("ok")
    assert_includes report.fetch("problems").first, "expected \"acceptance-fixture\""
  end

  def test_checker_rejects_a_result_with_the_wrong_network_context
    manifest = {
      "version" => 1,
      "profile_context" => { "acceptance-fixture" => { "network" => "fixture" } },
      "required" => [{ "id" => "fixture", "profiles" => ["acceptance-fixture"], "allowed_states" => ["pass"] }]
    }
    results = Rubycc::CIResult.document(results: [
      Rubycc::CIResult.result(id: "fixture", state: "pass", profile: "acceptance-fixture", network: "live")
    ])

    report = Rubycc::CICheckAcceptance.check(
      manifest: manifest, results: results, profile: "acceptance-fixture", strict: true
    )
    refute report.fetch("ok")
    assert_includes report.fetch("problems").first, "network=\"live\""
  end

  def test_checker_requires_and_verifies_pinned_artifact_reports
    digest = "a" * 64
    manifest = {
      "version" => 1,
      "profile_context" => { "live" => { "network" => "live" } },
      "artifacts" => [{
        "id" => "gem-fixture", "kind" => "rubygems-gem", "name" => "fixture",
        "version" => "1.0", "platform" => "ruby", "url" => "https://example.invalid/fixture.gem",
        "sha256" => digest
      }],
      "required" => [{
        "id" => "live", "profiles" => ["live"], "allowed_states" => ["pass"],
        "artifacts" => ["gem-fixture"]
      }]
    }
    results = Rubycc::CIResult.document(results: [
      Rubycc::CIResult.result(id: "live", state: "pass", profile: "live", network: "live")
    ])

    missing = Rubycc::CICheckAcceptance.check(
      manifest: manifest, results: results, profile: "live", strict: true
    )
    refute missing.fetch("ok")
    assert_includes missing.fetch("problems").first, "gem-fixture"

    artifact_report = {
      "gem-fixture" => {
        "id" => "gem-fixture", "kind" => "rubygems-gem", "url" => "https://example.invalid/fixture.gem",
        "expected_sha256" => digest, "actual_sha256" => digest, "bytes" => 10, "cache_hit" => false
      }
    }
    verified = Rubycc::CICheckAcceptance.check(
      manifest: manifest, results: results, profile: "live", strict: true,
      artifact_report: artifact_report
    )
    assert verified.fetch("ok")

    artifact_report["gem-fixture"]["actual_sha256"] = "b" * 64
    mismatch = Rubycc::CICheckAcceptance.check(
      manifest: manifest, results: results, profile: "live", strict: true,
      artifact_report: artifact_report
    )
    refute mismatch.fetch("ok")
    assert mismatch.fetch("problems").any? { |problem| problem.include?("does not match") }
  end

  def test_checker_rejects_an_unknown_profile_instead_of_checking_zero_entries
    manifest = {
      "version" => 1,
      "profile_context" => { "known" => { "network" => "none" } },
      "required" => [{ "id" => "known", "profiles" => ["known"], "allowed_states" => ["pass"] }]
    }
    error = assert_raises(Rubycc::CIResult::Error) do
      Rubycc::CICheckAcceptance.check(
        manifest: manifest,
        results: Rubycc::CIResult.document(results: []),
        profile: "typo",
        strict: true
      )
    end
    assert_includes error.message, "unknown acceptance profile"
  end

  def test_result_reporter_records_pass_and_external_inconclusive_failure
    Dir.mktmpdir do |dir|
      path = File.join(dir, "results.json")
      saved = ENV.to_hash
      ENV["CI_RESULT_PATH"] = path
      ENV["CI_PROFILE"] = "acceptance-live"
      ENV["CI_NETWORK"] = "live"

      AcceptanceResultReporter.with_result("reporter-pass") {}
      error = assert_raises(AcceptanceFetchHelper::Failure) do
        AcceptanceResultReporter.with_result("reporter-timeout") do
          raise AcceptanceFetchHelper::Failure.new(kind: :timeout, message: "service did not answer")
        end
      end
      assert_equal :timeout, error.kind

      results = Rubycc::CIResult.read(path).fetch("results").to_h { |entry| [entry.fetch("id"), entry] }
      assert_equal "pass", results.fetch("reporter-pass").fetch("state")
      assert_equal "inconclusive", results.fetch("reporter-timeout").fetch("state")
      assert_equal "live", results.fetch("reporter-timeout").fetch("network")

      assert_raises(Minitest::Assertion) do
        AcceptanceResultReporter.with_result("reporter-assertion") do
          raise Minitest::Assertion, "required preflight failed"
        end
      end
      assert_equal "fail", Rubycc::CIResult.read(path).fetch("results").to_h { |entry| [entry.fetch("id"), entry] }
        .fetch("reporter-assertion").fetch("state")
    ensure
      ENV.replace(saved) if saved
    end
  end

  def test_result_reporter_initializes_an_existing_empty_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "results.json")
      File.write(path, "")
      saved = ENV.to_hash
      ENV["CI_RESULT_PATH"] = path
      ENV["CI_PROFILE"] = "acceptance-fixture"
      ENV["CI_NETWORK"] = "fixture"

      AcceptanceResultReporter.with_result("reporter-empty-file") {}

      result = Rubycc::CIResult.read(path).fetch("results").first
      assert_equal "pass", result.fetch("state")
      assert_equal "acceptance-fixture", result.fetch("profile")
    ensure
      ENV.replace(saved) if saved
    end
  end

  private

  def write_json(value)
    file = Tempfile.new(["ci-manifest", ".json"])
    file.write(JSON.generate(value))
    file.close
    file.path
  end
end
