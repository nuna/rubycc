# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../tools/summarize_corpus_candidate_pilot_v2"

class TestSummarizeCorpusCandidatePilotV2 < Minitest::Test
  def write_json(path, payload)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(payload) + "\n")
  end

  def test_baseline_headers_and_build_shape_are_explicit
    Dir.mktmpdir do |root|
      census = File.join(root, "include-census.md")
      File.write(census, <<~MARKDOWN)
        ## gem × system header matrix

        | header | class | existing |
        |--------|-------|----------|
        | `stdio.h` | bundled | x |
        | `old.h` | gap | x |
      MARKDOWN

      baseline = CorpusCandidatePilotV2.baseline_headers(census)
      assert_equal ["stdio.h"], baseline.fetch("bundled")
      assert_equal ["old.h"], baseline.fetch("gap")
      assert_equal ["bundled:stdio.h", "gap:old.h"], baseline.dig("gem_sets", "existing")
      assert_equal "single-extconf", CorpusCandidatePilotV2.build_shape(
        "gemspec" => { "extensions" => ["ext/extconf.rb"], "extension_directories" => ["ext"] }
      )
      assert_equal "cargo", CorpusCandidatePilotV2.build_shape(
        "gemspec" => { "extensions" => ["ext/native/Cargo.toml"], "extension_directories" => ["ext/native"] }
      )
    end
  end

  def test_summary_validates_fixed_window_and_exposes_incremental_metrics
    Dir.mktmpdir do |root|
      evaluation_root = File.join(root, "evaluation")
      manifest_path = File.join(evaluation_root, "pilot-v2-manifest.json")
      runs_path = File.join(evaluation_root, "pilot-v2-runs.json")
      census_path = File.join(root, "include-census.md")
      popular_path = File.join(evaluation_root, "artifacts/pilot-v2/popular-control.json")
      classification_path = File.join(evaluation_root, "artifacts/pilot-v2/2026-08-02/classification.json")
      summary_path = File.join(evaluation_root, "artifacts/pilot-v2/2026-08-02/run-summary.json")

      File.write(census_path, <<~MARKDOWN)
        ## gem × system header matrix

        | header | class | existing |
        |--------|-------|----------|
        | `stdio.h` | bundled | x |
        | `old.h` | gap | x |
      MARKDOWN
      manifest = {
        "experiment" => "corpus-candidate-pilot-v2", "scanner_revision" => "scanner",
        "windows" => [{
          "id" => "2026-08-02", "from" => "2026-08-02T00:00:00Z", "to" => "2026-08-03T00:00:00Z",
          "classification" => "artifacts/pilot-v2/2026-08-02/classification.json",
          "summary" => "artifacts/pilot-v2/2026-08-02/run-summary.json"
        }],
        "candidate_selection" => { "maximum_unique_gems" => 1 },
        "operating_targets" => { "daily_wall_time_p95_seconds" => 900, "timeout_rate" => 0,
                                  "final_failure_rate_less_than" => 0.05 }
      }
      write_json(manifest_path, manifest)
      write_json(runs_path, { "windows" => [{ "id" => "2026-08-02", "run_id" => 1,
                                              "url" => "https://example.test/run/1",
                                              "conclusion" => "success", "scanner_revision" => "scanner" }] })
      record = {
        "name" => "new-gem", "version" => "1.0.0", "platform" => "ruby",
        "created_at" => "2026-08-02T12:00:00Z", "version_downloads" => 42,
        "gem" => { "sha256" => "a" * 64 },
        "gemspec" => { "extensions" => ["ext/extconf.rb"], "extension_directories" => ["ext"],
                       "native_source_files" => ["ext/new_gem.c"], "extconf_files" => ["ext/extconf.rb"] },
        "corpus" => { "status" => "candidate", "included" => false },
        "headers" => { "bundled" => ["stdio.h"], "gap" => ["new.h"], "ruby_or_self" => [] }
      }
      source_error_record = {
        "name" => "stale-gem", "version" => nil, "platform" => nil,
        "corpus" => { "status" => "v2_metadata_404", "included" => false,
                       "reason" => "metadata not found", "review_reasons" => [], "c_files" => 0, "h_files" => 0 },
        "source_error" => { "kind" => "v2_metadata_404", "stage" => "v2_metadata", "http_status" => 404,
                             "reason" => "metadata not found" },
        "headers" => { "bundled" => [], "gap" => [], "ruby_or_self" => [] }
      }
      write_json(classification_path, { "source" => "timeframe", "records" => [record, source_error_record] })
      write_json(summary_path, {
        "source" => "timeframe", "elapsed_seconds" => 12.5,
        "source_stats" => { "pages" => 2, "release_entries" => 3, "unique_gems" => 1 },
        "execution" => { "peak_work_bytes" => 100 },
        "archives" => { "inspections" => 1, "fetch_attempts" => 1, "cache_hits" => 0,
                         "successes" => 1, "failures" => 0, "retries" => 0, "bytes" => 10, "unique_urls" => 1 },
        "phases_seconds" => { "archive_fetch" => 1.0 },
        "results" => { "candidate" => 1, "v2_metadata_404" => 1 },
        "source_errors" => { "total" => 1, "by_kind" => { "v2_metadata_404" => 1 },
                              "by_stage" => { "v2_metadata" => 1 } }
      })
      write_json(popular_path, { "records" => [{ "name" => "popular-gem", "corpus" => { "status" => "no_ext" } }] })

      result = CorpusCandidatePilotV2.summarize(
        manifest_path: manifest_path, runs_path: runs_path, evaluation_root: evaluation_root,
        popular_path: popular_path, census_path: census_path
      )

      assert_equal 1, result.fetch("window_count")
      assert_equal 3, result.dig("source_total", "release_entries")
      assert_equal ["new.h"], result.dig("incremental_headers", "candidate_new_gap_spellings")
      assert_equal 1, result.dig("candidate_pool", "eligible_unique_names")
      assert_equal "new-gem", result.fetch("selected_candidates").fetch(0).fetch("name")
      assert_equal 12.5, result.dig("runtime", "elapsed_seconds", "p95")
      assert_equal 0.0, result.dig("runtime", "window_failure_rate")
      assert_equal({ "v2_metadata_404" => 1 }, result.dig("daily", 0, "source_error_counts"))
      assert_equal 1, result.dig("runtime", "source_error_count")
      assert_equal 0.5, result.dig("runtime", "source_error_rate")
    end
  end

  def test_failed_window_is_counted_separately_from_source_errors
    Dir.mktmpdir do |root|
      evaluation_root = File.join(root, "evaluation")
      manifest_path = File.join(evaluation_root, "pilot-v2-manifest.json")
      runs_path = File.join(evaluation_root, "pilot-v2-runs.json")
      census_path = File.join(root, "include-census.md")
      popular_path = File.join(evaluation_root, "artifacts/pilot-v2/popular-control.json")
      classification_path = File.join(evaluation_root, "artifacts/pilot-v2/2026-08-02/classification.json")
      summary_path = File.join(evaluation_root, "artifacts/pilot-v2/2026-08-02/run-summary.json")
      File.write(census_path, "| header | class | existing |\n|--------|-------|----------|\n")
      windows = [
        ["2026-08-02", "2026-08-02T00:00:00Z", "2026-08-03T00:00:00Z",
         "artifacts/pilot-v2/2026-08-02/classification.json", "artifacts/pilot-v2/2026-08-02/run-summary.json"],
        ["2026-08-03", "2026-08-03T00:00:00Z", "2026-08-04T00:00:00Z",
         "artifacts/pilot-v2/2026-08-03/classification.json", "artifacts/pilot-v2/2026-08-03/run-summary.json"]
      ]
      write_json(manifest_path, {
        "experiment" => "corpus-candidate-pilot-v2", "scanner_revision" => "scanner",
        "windows" => windows.map do |id, from, to, classification, summary|
          { "id" => id, "from" => from, "to" => to, "classification" => classification, "summary" => summary }
        end,
        "candidate_selection" => { "maximum_unique_gems" => 1 },
        "operating_targets" => { "daily_wall_time_p95_seconds" => 900, "timeout_rate" => 0,
                                  "final_failure_rate_less_than" => 0.05 }
      })
      write_json(runs_path, { "windows" => [
        { "id" => "2026-08-02", "run_id" => 1, "url" => "https://example.test/run/1",
          "conclusion" => "success", "scanner_revision" => "scanner" },
        { "id" => "2026-08-03", "run_id" => 2, "url" => "https://example.test/run/2",
          "conclusion" => "failure", "failure_reason" => "runner timeout", "scanner_revision" => "scanner" }
      ] })
      write_json(classification_path, { "source" => "timeframe", "records" => [] })
      write_json(summary_path, {
        "source" => "timeframe", "elapsed_seconds" => 1.0,
        "source_stats" => { "pages" => 1, "release_entries" => 0, "unique_gems" => 0 },
        "execution" => { "peak_work_bytes" => 0 }, "archives" => {}, "phases_seconds" => {}, "results" => {}
      })
      write_json(popular_path, { "records" => [] })

      result = CorpusCandidatePilotV2.summarize(
        manifest_path: manifest_path, runs_path: runs_path, evaluation_root: evaluation_root,
        popular_path: popular_path, census_path: census_path
      )

      assert_equal 2, result.fetch("window_count")
      assert_equal 1, result.fetch("completed_window_count")
      assert_equal 1, result.dig("runtime", "failed_windows")
      assert_equal 0.5, result.dig("runtime", "window_failure_rate")
      assert_equal 1, result.dig("runtime", "timeout_windows")
      assert_equal "failed", result.dig("daily", 1, "status")
      assert_equal 0, result.dig("runtime", "source_error_count")
    end
  end

  def test_percentile_uses_nearest_rank
    assert_equal 2.0, CorpusCandidatePilotV2.percentile([1, 2, 3, 4], 0.50)
    assert_equal 4.0, CorpusCandidatePilotV2.percentile([1, 2, 3, 4], 0.95)
    assert_nil CorpusCandidatePilotV2.percentile([], 0.95)
  end
end
