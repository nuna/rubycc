#!/usr/bin/env ruby
# frozen_string_literal: true

# Summarize the fixed corpus-candidate-pilot-v2 experiment without contacting
# RubyGems or GitHub.  The daily archives and logs remain ignored work; this
# reader emits only compact, reviewable evidence.

require "json"
require "fileutils"
require "optparse"
require "set"
require "time"

require_relative "../test/corpus/gems"

module CorpusCandidatePilotV2
  module_function

  STATUSES = %w[candidate error excluded needs_review no_ext review].freeze
  KNOWN_BUILD_SHAPES = %w[single-extconf multi-extconf].freeze
  DEFAULT_EVALUATION_ROOT = File.expand_path("../docs/development/corpus-candidate-evaluation", __dir__)
  DEFAULT_MANIFEST = File.join(DEFAULT_EVALUATION_ROOT, "pilot-v2-manifest.json")
  DEFAULT_RUNS = File.join(DEFAULT_EVALUATION_ROOT, "pilot-v2-runs.json")
  DEFAULT_CENSUS = File.expand_path("../test/corpus/include-census.md", __dir__)
  DEFAULT_OUTPUT = File.join(DEFAULT_EVALUATION_ROOT, "pilot-v2-metrics.json")

  def load_json(path)
    JSON.parse(File.read(path))
  end

  def split_markdown_row(line)
    line.strip.split("|", -1)[1...-1].map(&:strip)
  end

  def baseline_headers(path)
    lines = File.readlines(path, chomp: true)
    header_line = lines.find { |line| line.start_with?("| header | class |") }
    return { "bundled" => [], "gap" => [], "gem_sets" => {} } unless header_line

    columns = split_markdown_row(header_line)
    gem_names = columns.drop(2)
    headers = { "bundled" => [], "gap" => [], "gem_sets" => gem_names.to_h { |name| [name, []] } }

    lines.drop_while { |line| line != header_line }.drop(1).each do |line|
      break if line.empty? || line.start_with?("## ")
      cells = split_markdown_row(line)
      next unless cells.size == columns.size
      match = cells[0].match(/\A`([^`]+)`\z/)
      next unless match && %w[bundled gap].include?(cells[1])

      spelling = match[1]
      klass = cells[1]
      headers[klass] << spelling
      gem_names.each_with_index do |gem, index|
        headers["gem_sets"][gem] << "#{klass}:#{spelling}" if cells[index + 2] == "x"
      end
    end

    headers.each_value { |value| value.each_value(&:sort!) if value.is_a?(Hash) }
    headers["bundled"].uniq!
    headers["gap"].uniq!
    headers
  end

  def header_set(record)
    Array(record.dig("headers", "bundled")).map { |header| "bundled:#{header}" } +
      Array(record.dig("headers", "gap")).map { |header| "gap:#{header}" }
  end

  def build_shape(record)
    extensions = Array(record.dig("gemspec", "extensions")).map(&:to_s)
    directories = Array(record.dig("gemspec", "extension_directories")).map(&:to_s)
    entrypoints = extensions.map { |path| File.basename(path) }.uniq.sort
    return "no-declared-extension" if extensions.empty?
    return "extension-outside-ext" if directories.any? { |path| path != "ext" && !path.start_with?("ext/") }
    return "cargo" if entrypoints.include?("Cargo.toml")
    return "rake" if entrypoints.include?("Rakefile")

    if entrypoints.all? { |name| name == "extconf.rb" }
      entrypoints_count = extensions.length
      return entrypoints_count > 1 ? "multi-extconf" : "single-extconf"
    end

    "declared-#{entrypoints.join("+")}"
  end

  def new_header_values(record, baseline)
    {
      "new_system" => (Array(record.dig("headers", "bundled")) - baseline.fetch("bundled")).sort,
      "new_gap" => (Array(record.dig("headers", "gap")) - baseline.fetch("gap")).sort
    }
  end

  def new_shape?(record)
    !KNOWN_BUILD_SHAPES.include?(build_shape(record))
  end

  def status_counts(records)
    records.group_by { |record| record.dig("corpus", "status").to_s }
           .transform_values(&:length)
           .sort.to_h
  end

  def percentile(values, fraction)
    sorted = values.map(&:to_f).sort
    return nil if sorted.empty?

    index = [(sorted.length * fraction).ceil - 1, 0].max
    sorted.fetch(index).round(6)
  end

  def created_at_value(record)
    Time.iso8601(record["created_at"].to_s).to_f
  rescue ArgumentError
    0.0
  end

  def priority_key(record, baseline)
    headers = new_header_values(record, baseline)
    [
      headers.fetch("new_gap").empty? ? 1 : 0,
      headers.fetch("new_system").empty? ? 1 : 0,
      new_shape?(record) ? 0 : 1,
      -record["version_downloads"].to_i,
      -created_at_value(record),
      record["name"].to_s
    ]
  end

  def compact_candidate(record, window_id, artifact_path, baseline, corpus_names, popular_names)
    headers = new_header_values(record, baseline)
    {
      "name" => record.fetch("name"),
      "version" => record["version"],
      "platform" => record["platform"],
      "sha256" => record.dig("gem", "sha256"),
      "window" => window_id,
      "source_artifact" => artifact_path,
      "created_at" => record["created_at"],
      "downloads" => record["downloads"],
      "version_downloads" => record["version_downloads"],
      "new_system_headers" => headers.fetch("new_system"),
      "new_gap_headers" => headers.fetch("new_gap"),
      "build_shape" => build_shape(record),
      "new_extension_build_shape" => new_shape?(record),
      "same_existing_header_set" => existing_header_set?(record, baseline),
      "in_corpus" => corpus_names.include?(record["name"]),
      "in_popular" => popular_names.include?(record["name"])
    }
  end

  def existing_header_set?(record, baseline)
    baseline.fetch("gem_sets").any? { |_gem, headers| headers.sort == header_set(record).sort }
  end

  def aggregate_archive_stats(summaries)
    keys = %w[inspections fetch_attempts cache_hits successes failures retries bytes unique_urls]
    keys.to_h { |key| [key, summaries.sum { |summary| summary.dig("archives", key).to_i }] }
  end

  def aggregate_source_stats(summaries)
    {
      "pages" => summaries.sum { |summary| summary.dig("source_stats", "pages").to_i },
      "release_entries" => summaries.sum { |summary| summary.dig("source_stats", "release_entries").to_i },
      "unique_gem_occurrences" => summaries.sum { |summary| summary.dig("source_stats", "unique_gems").to_i }
    }
  end

  def read_windows(manifest, registry, evaluation_root)
    registry_windows = registry.fetch("windows").to_h { |window| [window.fetch("id"), window] }
    manifest.fetch("windows").map do |window|
      run = registry_windows.fetch(window.fetch("id"))
      raise "run #{window.fetch("id")} did not complete successfully" unless run["conclusion"] == "success"
      raise "run #{window.fetch("id")} has a different scanner revision" unless
        run.fetch("scanner_revision") == manifest.fetch("scanner_revision")

      classification_path = File.join(evaluation_root, window.fetch("classification"))
      summary_path = File.join(evaluation_root, window.fetch("summary"))
      classification = load_json(classification_path)
      summary = load_json(summary_path)
      raise "#{classification_path}: source mismatch" unless classification.fetch("source") == "timeframe"
      raise "#{summary_path}: source mismatch" unless summary.fetch("source") == "timeframe"

      {
        "manifest" => window,
        "run" => run,
        "classification" => classification,
        "summary" => summary,
        "classification_path" => window.fetch("classification"),
        "summary_path" => window.fetch("summary")
      }
    end
  end

  def summarize(manifest_path:, runs_path:, evaluation_root:, popular_path:, census_path:, inspections_path: nil)
    manifest = load_json(manifest_path)
    registry = load_json(runs_path)
    baseline = baseline_headers(census_path)
    corpus_names = Corpus::Gems::LIST.map { |gem| gem.fetch(:name) }.to_set
    popular = load_json(popular_path)
    popular_names = popular.fetch("records").map { |record| record["name"] }.compact.to_set
    windows = read_windows(manifest, registry, evaluation_root)
    all_records = windows.flat_map { |window| window.fetch("classification").fetch("records") }
    summaries = windows.map { |window| window.fetch("summary") }

    candidates = []
    inspectable = []
    daily = windows.map do |window|
      records = window.fetch("classification").fetch("records")
      records.each do |record|
        inspectable << record unless %w[no_ext error].include?(record.dig("corpus", "status"))
        next unless record.dig("corpus", "status") == "candidate"
        next if corpus_names.include?(record["name"]) || popular_names.include?(record["name"])

        candidates << compact_candidate(record, window.fetch("manifest").fetch("id"),
                                         window.fetch("classification_path"), baseline,
                                         corpus_names, popular_names)
      end

      summary = window.fetch("summary")
      {
        "id" => window.fetch("manifest").fetch("id"),
        "from" => window.fetch("manifest").fetch("from"),
        "to" => window.fetch("manifest").fetch("to"),
        "run_id" => window.fetch("run").fetch("run_id"),
        "run_url" => window.fetch("run").fetch("url"),
        "release_entries" => summary.dig("source_stats", "release_entries").to_i,
        "pages" => summary.dig("source_stats", "pages").to_i,
        "unique_gems" => summary.dig("source_stats", "unique_gems").to_i,
        "archive" => summary.fetch("archives"),
        "status_counts" => status_counts(records),
        "elapsed_seconds" => summary.fetch("elapsed_seconds"),
        "phases_seconds" => summary.fetch("phases_seconds"),
        "peak_work_bytes" => summary.dig("execution", "peak_work_bytes").to_i,
        "record_count" => records.length,
        "record_error_count" => records.count { |record| record.dig("corpus", "status") == "error" }
      }
    end

    original_candidates = windows.flat_map do |window|
      window.fetch("classification").fetch("records").filter_map do |record|
        next unless record.dig("corpus", "status") == "candidate"
        next if corpus_names.include?(record["name"]) || popular_names.include?(record["name"])

        [record, window]
      end
    end
    selected_by_name = original_candidates.group_by { |record, _window| record.fetch("name") }.transform_values do |pairs|
      pairs.min_by { |record, _window| priority_key(record, baseline) }
    end
    selected = selected_by_name.values.sort_by do |record, _window|
      priority_key(record, baseline)
    end.first(manifest.dig("candidate_selection", "maximum_unique_gems").to_i).map do |record, window|
      compact_candidate(record, window.fetch("manifest").fetch("id"), window.fetch("classification_path"),
                        baseline, corpus_names, popular_names)
    end

    new_headers = {
      "system" => inspectable.flat_map { |record| Array(record.dig("headers", "bundled")) }
                              .uniq.sort - baseline.fetch("bundled"),
      "gap" => inspectable.flat_map { |record| Array(record.dig("headers", "gap")) }
                           .uniq.sort - baseline.fetch("gap")
    }
    candidate_new_headers = {
      "system" => candidates.flat_map { |candidate| candidate.fetch("new_system_headers") }.uniq.sort,
      "gap" => candidates.flat_map { |candidate| candidate.fetch("new_gap_headers") }.uniq.sort
    }
    status_total = status_counts(all_records)
    total_records = all_records.length
    error_records = status_total.fetch("error", 0)
    elapsed = daily.map { |row| row.fetch("elapsed_seconds") }
    failed_windows = manifest.fetch("windows").length - windows.length
    candidate_names = candidates.map { |candidate| candidate.fetch("name") }
    unique_candidate_names = candidate_names.uniq.sort
    duplicate_occurrences = candidate_names.length - unique_candidate_names.length
    same_header_count = candidates.count { |candidate| candidate.fetch("same_existing_header_set") }

    inspection = inspections_path && load_json(inspections_path)
    review_minutes = Array(inspection && inspection["candidates"]).filter_map { |candidate| candidate["review_minutes"] }

    {
      "schema_version" => 1,
      "experiment" => manifest.fetch("experiment"),
      "manifest" => File.basename(manifest_path),
      "scanner_revision" => manifest.fetch("scanner_revision"),
      "run_registry" => File.basename(runs_path),
      "window_count" => windows.length,
      "daily" => daily,
      "source_total" => aggregate_source_stats(summaries),
      "archive_total" => aggregate_archive_stats(summaries),
      "status_total" => status_total,
      "candidate_pool" => {
        "eligible_occurrences" => candidate_names.length,
        "eligible_unique_names" => unique_candidate_names.length,
        "duplicate_occurrences" => duplicate_occurrences,
        "cross_window_duplicate_rate" => candidate_names.empty? ? 0.0 :
          (duplicate_occurrences.to_f / candidate_names.length).round(6),
        "names" => unique_candidate_names,
        "same_existing_header_set_occurrences" => same_header_count
      },
      "popular_control" => {
        "artifact" => File.basename(popular_path),
        "unique_gems" => popular_names.length,
        "status_counts" => status_counts(popular.fetch("records")),
        "candidate_names" => popular.fetch("records").filter_map do |record|
          record["name"] if record.dig("corpus", "status") == "candidate"
        end.sort,
        "review_names" => popular.fetch("records").filter_map do |record|
          record["name"] if %w[review needs_review].include?(record.dig("corpus", "status"))
        end.sort
      },
      "incremental_headers" => {
        "baseline_system_count" => baseline.fetch("bundled").length,
        "baseline_gap_count" => baseline.fetch("gap").length,
        "new_system_spellings" => new_headers.fetch("system"),
        "new_gap_spellings" => new_headers.fetch("gap"),
        "candidate_new_system_spellings" => candidate_new_headers.fetch("system"),
        "candidate_new_gap_spellings" => candidate_new_headers.fetch("gap")
      },
      "build_shapes" => {
        "known" => KNOWN_BUILD_SHAPES,
        "candidate_counts" => candidates.group_by { |candidate| candidate.fetch("build_shape") }
                                   .transform_values(&:length).sort.to_h,
        "new_candidate_shapes" => candidates.filter_map do |candidate|
          candidate.fetch("build_shape") if candidate.fetch("new_extension_build_shape")
        end.uniq.sort
      },
      "runtime" => {
        "elapsed_seconds" => {
          "p50" => percentile(elapsed, 0.50),
          "p95" => percentile(elapsed, 0.95),
          "max" => elapsed.max
        },
        "phase_seconds_total" => summaries.flat_map { |summary| summary.fetch("phases_seconds").to_a }
                                          .group_by(&:first)
                                          .transform_values { |rows| rows.sum { |row| row.last.to_f.round(6) } }
                                          .sort.to_h,
        "peak_work_bytes_max" => daily.map { |row| row.fetch("peak_work_bytes") }.max,
        "failed_windows" => failed_windows,
        "window_failure_rate" => (failed_windows.to_f / manifest.fetch("windows").length).round(6),
        "record_error_count" => error_records,
        "record_error_rate" => (error_records.to_f / total_records).round(6),
        "timeout_windows" => 0,
        "review_minutes" => {
          "candidate_count" => review_minutes.length,
          "total" => review_minutes.sum,
          "p50" => percentile(review_minutes, 0.50),
          "p95" => percentile(review_minutes, 0.95)
        }
      },
      "selected_candidates" => selected,
      "inspections" => inspection || { "status" => "not_recorded" },
      "decision_inputs" => {
        "p95_target_seconds" => manifest.dig("operating_targets", "daily_wall_time_p95_seconds"),
        "timeout_rate_target" => manifest.dig("operating_targets", "timeout_rate"),
        "window_failure_rate_target_less_than" => manifest.dig("operating_targets", "final_failure_rate_less_than"),
        "minimum_incremental_candidate" => 1,
        "corpus_changed" => false
      }
    }
  end

  def run(argv)
    options = {
      manifest: DEFAULT_MANIFEST, runs: DEFAULT_RUNS, evaluation_root: DEFAULT_EVALUATION_ROOT,
      popular: nil, census: DEFAULT_CENSUS, inspections: nil, output: DEFAULT_OUTPUT
    }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: summarize_corpus_candidate_pilot_v2.rb [options]"
      opts.on("--manifest PATH") { |path| options[:manifest] = path }
      opts.on("--runs PATH") { |path| options[:runs] = path }
      opts.on("--evaluation-root PATH") { |path| options[:evaluation_root] = path }
      opts.on("--popular PATH") { |path| options[:popular] = path }
      opts.on("--census PATH") { |path| options[:census] = path }
      opts.on("--inspections PATH") { |path| options[:inspections] = path }
      opts.on("--output PATH") { |path| options[:output] = path }
    end
    parser.parse!(argv)
    options[:popular] ||= File.join(options[:evaluation_root], "artifacts/pilot-v2/popular-control.json")
    payload = summarize(manifest_path: options.fetch(:manifest), runs_path: options.fetch(:runs),
                        evaluation_root: options.fetch(:evaluation_root), popular_path: options.fetch(:popular),
                        census_path: options.fetch(:census), inspections_path: options.fetch(:inspections))
    json = JSON.pretty_generate(payload) + "\n"
    if options[:output]
      FileUtils.mkdir_p(File.dirname(options.fetch(:output)))
      File.binwrite(options.fetch(:output), json)
    else
      $stdout.write(json)
    end
    0
  end
end

exit CorpusCandidatePilotV2.run(ARGV) if $PROGRAM_NAME == __FILE__
