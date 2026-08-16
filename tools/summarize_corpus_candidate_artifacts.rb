#!/usr/bin/env ruby
# frozen_string_literal: true

# Summarize saved candidate-scan artifacts without contacting RubyGems. This is
# deliberately a reader for the artifact boundary: it must not infer a result
# from a live API or from a missing cache file.

require "json"
require "optparse"

module CorpusCandidateEvaluation
  module_function

  def summarize(path, raw_dir: nil)
    artifact = JSON.parse(File.read(path))
    records = Array(artifact.fetch("records"))
    counts = {
      "unique_gems" => records.size,
      "corpus" => 0,
      "candidate" => 0,
      "uninspected" => 0,
      "assembly_review" => 0,
      "excluded" => 0,
      "review" => 0,
      "error" => 0,
      "no_ext" => 0
    }
    rejection_counts = Hash.new(0)
    candidate_names = []
    selected_names = []
    new_selection_names = []

    records.each do |record|
      corpus = record.fetch("corpus")
      status = corpus.fetch("status")
      if status == "uninspected"
        selected_names << record.fetch("name")
        new_selection_names << record.fetch("name") unless corpus.fetch("included")
      end
      if corpus.fetch("included") && status != "error" && status != "no_ext"
        counts["corpus"] += 1
      elsif status == "candidate"
        counts["candidate"] += 1
        candidate_names << record.fetch("name")
      elsif status == "uninspected"
        counts["uninspected"] += 1
        candidate_names << record.fetch("name")
      elsif status == "needs_review"
        counts["assembly_review"] += 1
      elsif status == "excluded"
        counts["excluded"] += 1
      elsif status == "review"
        counts["review"] += 1
      elsif status == "no_ext"
        counts["no_ext"] += 1
      else
        counts["error"] += 1
      end

      record.fetch("selection").fetch("rejections").each do |reason|
        category = case reason
                   when /prerelease/ then "prerelease"
                   when /yanked/ then "yanked"
                   when /duplicate release/ then "duplicate_release"
                   when /source platform unavailable/ then "source_platform_missing"
                   when /v2 lookup failed|v2 response|invalid v2/ then "source_lookup_error"
                   else "other"
                   end
        rejection_counts[category] += 1
      end
    end

    raw = raw_timeframe_stats(artifact, raw_dir)
    {
      "artifact" => File.basename(path),
      "source" => artifact.fetch("source"),
      "input" => artifact.fetch("input"),
      "version_entries" => raw[:version_entries],
      "raw_timeframe_responses" => raw[:response_count],
      "unique_gems" => counts["unique_gems"],
      "counts" => counts,
      "selection_rejections" => rejection_counts.sort.to_h,
      "api_requests" => Array(artifact["source_requests"]).size,
      "candidate_names" => candidate_names.sort,
      "selected_names" => selected_names.sort,
      "new_selection_names" => new_selection_names.sort,
      "review_gems" => counts["review"] + counts["assembly_review"]
    }
  end

  def raw_timeframe_stats(artifact, raw_dir)
    return { response_count: nil, version_entries: nil } unless raw_dir

    requests = Array(artifact["source_requests"]).select do |request|
      request.fetch("url").include?("/api/v1/timeframe_versions.json")
    end
    entries = requests.sum do |request|
      path = File.join(raw_dir, request.fetch("cache_key"))
      body = File.binread(path)
      response = JSON.parse(body)
      response.is_a?(Array) ? response.size : 0
    end
    { response_count: requests.size, version_entries: entries }
  end

  def run(argv)
    options = { timeframes: [], raw_dirs: [], popular: nil, output: nil }
    OptionParser.new do |parser|
      parser.banner = "Usage: summarize_corpus_candidate_artifacts.rb [options]"
      parser.on("--timeframe PATH", "saved timeframe artifact (repeatable)") { |path| options[:timeframes] << path }
      parser.on("--raw-dir PATH", "raw response cache for the preceding timeframe (repeatable)") { |path| options[:raw_dirs] << path }
      parser.on("--popular PATH", "saved popular-source artifact") { |path| options[:popular] = path }
      parser.on("--output PATH", "write JSON to PATH instead of stdout") { |path| options[:output] = path }
    end.parse!(argv)
    raise ArgumentError, "--raw-dir count must equal --timeframe count" unless options[:raw_dirs].empty? || options[:raw_dirs].size == options[:timeframes].size
    raise ArgumentError, "at least one artifact is required" if options[:timeframes].empty? && !options[:popular]

    raw_dirs = options[:raw_dirs].empty? ? Array.new(options[:timeframes].size) : options[:raw_dirs]
    payload = {
      "schema_version" => 1,
      "timeframes" => options[:timeframes].zip(raw_dirs).map { |path, raw_dir| summarize(path, raw_dir: raw_dir) },
      "popular" => options[:popular] && summarize(options[:popular])
    }
    json = JSON.pretty_generate(payload) + "\n"
    if options[:output]
      File.binwrite(options[:output], json)
    else
      $stdout.write(json)
    end
    0
  end
end

exit CorpusCandidateEvaluation.run(ARGV) if $PROGRAM_NAME == __FILE__
