# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "time"

class TestCorpusCandidatePilotManifest < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze
  PATH = File.join(ROOT, "docs/development/corpus-candidate-evaluation/pilot-v2-manifest.json").freeze

  def setup
    @manifest = JSON.parse(File.read(PATH))
  end

  def test_fixes_fourteen_contiguous_completed_utc_days
    windows = @manifest.fetch("windows")

    assert_equal 14, windows.size
    windows.each_cons(2) do |left, right|
      assert_equal Time.iso8601(left.fetch("to")), Time.iso8601(right.fetch("from"))
    end
    windows.each do |window|
      from = Time.iso8601(window.fetch("from"))
      to = Time.iso8601(window.fetch("to"))
      assert_equal 86_400, to - from
      assert_equal "00:00:00", from.strftime("%H:%M:%S")
      assert_equal "00:00:00", to.strftime("%H:%M:%S")
      assert_match(/\A2026-08-\d{2}\z/, window.fetch("id"))
    end
  end

  def test_fixes_full_static_scan_and_runtime_boundary
    scan = @manifest.fetch("scan")

    assert_equal "timeframe", scan.fetch("source")
    assert_equal false, scan.fetch("selection_only")
    assert_equal 2, scan.fetch("fetch_concurrency")
    assert_equal 35, scan.fetch("timeout_minutes")
    assert_equal ".github/workflows/corpus-candidate-daily.yml", scan.fetch("workflow")
  end

  def test_fixes_candidate_priority_and_operating_targets
    selection = @manifest.fetch("candidate_selection")
    targets = @manifest.fetch("operating_targets")

    assert_equal 3, selection.fetch("maximum_unique_gems")
    assert_equal [
      "new gap header",
      "new system header",
      "new extension or build shape",
      "version_downloads descending",
      "created_at descending",
      "gem name ascending"
    ], selection.fetch("priority")
    assert_equal 900, targets.fetch("daily_wall_time_p95_seconds")
    assert_equal 0, targets.fetch("timeout_rate")
    assert_equal 0.05, targets.fetch("final_failure_rate_less_than")
  end

  def test_keeps_candidate_execution_and_repository_mutation_outside_the_scan
    inspection = @manifest.fetch("inspection")
    artifacts = @manifest.fetch("artifact_policy")

    assert_equal "inspect-corpus-candidate", inspection.fetch("local_skill")
    assert_equal true, inspection.fetch("manual_validation")
    assert_equal true, inspection.fetch("build_load_requires_explicit_request")
    assert_equal true, inspection.fetch("upstream_recipe_required")
    assert_equal false, artifacts.fetch("corpus_or_verified_gems_changes")
    assert_includes artifacts.fetch("never_commit"), "gem archives"
    assert_includes artifacts.fetch("never_commit"), "unpack trees"
  end
end
