# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../tools/summarize_corpus_candidate_artifacts"

class TestSummarizeCorpusCandidateArtifacts < Minitest::Test
  def artifact(source: "timeframe", status: "candidate", included: false, rejections: [])
    {
      "schema_version" => 1,
      "source" => source,
      "input" => { "source" => source, "verbose" => false },
      "source_requests" => [],
      "records" => [{
        "name" => "example-gem", "selection" => { "rejections" => rejections },
        "corpus" => { "included" => included, "status" => status }
      }]
    }
  end

  def test_summary_counts_statuses_and_selection_reasons
    Dir.mktmpdir do |root|
      path = File.join(root, "scan.json")
      File.write(path, JSON.generate(artifact(rejections: ["1.0.0: prerelease", "0.9.0: yanked"])))

      summary = CorpusCandidateEvaluation.summarize(path)

      assert_equal 1, summary["unique_gems"]
      assert_equal 1, summary.dig("counts", "candidate")
      assert_equal 1, summary.dig("selection_rejections", "prerelease")
      assert_equal 1, summary.dig("selection_rejections", "yanked")
      assert_equal ["example-gem"], summary["candidate_names"]
    end
  end

  def test_timeframe_entry_count_reads_only_saved_timeframe_responses
    Dir.mktmpdir do |root|
      raw_dir = File.join(root, "raw")
      Dir.mkdir(raw_dir)
      url = "https://rubygems.org/api/v1/timeframe_versions.json?page=1"
      cache_key = "a" * 64
      path = File.join(root, "scan.json")
      File.write(File.join(raw_dir, cache_key), JSON.generate([{ "name" => "a" }, { "name" => "b" }]))
      data = artifact
      data["source_requests"] = [{ "url" => url, "cache_key" => cache_key }]
      File.write(path, JSON.generate(data))

      summary = CorpusCandidateEvaluation.summarize(path, raw_dir: raw_dir)

      assert_equal 1, summary["raw_timeframe_responses"]
      assert_equal 2, summary["version_entries"]
    end
  end
end
