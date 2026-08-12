#!/usr/bin/env ruby
# frozen_string_literal: true

# Build the machine-readable provenance/candidate artifact for the R10 corpus.
#
# This tool deliberately does not run gem installs or upstream suites.  It
# reuses the local corpus census (with a cache supplied by the caller) and the
# heuristic variadic scanner, then records the boundary between those machine
# observations and the still-pending manual/control/rubycc review.

require "digest"
require "json"
require "optparse"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "test"))
require "corpus/gems"
require "corpus/census"
require_relative "scan_corpus_variadics"

module R10CorpusScan
  module_function

  SCHEMA_VERSION = 1
  TOOL_NAME = "r10_corpus_scan"
  MANUAL_PENDING = "pending"
  NOT_RUN = "not-run-by-this-scan"

  LIMITATIONS = [
    "The corpus census is a machine gate, not a gem install or upstream-suite result.",
    "The variadic scanner is lexical and heuristic; no finding or empty result proves presence or absence.",
    "Macro expansion, generated-source selection, preprocessor conditions, and platform gates remain for manual review.",
    "This artifact records gem .gem SHA-256 provenance; upstream source-tarball SHA-256 is not collected here.",
    "Existing data/verified_gems.json records are referenced but are not re-executed by this scan."
  ].freeze

  def build(repo_root:, cache_dir:)
    include_root = File.join(repo_root, "include")
    bundled = Corpus::Census.bundled_headers(include_root)
    results = Corpus::Gems::LIST.map do |spec|
      Corpus::Census.census_gem(spec, cache_dir, bundled)
    end

    skipped = results.select { |result| result[:status] == :skipped }
    unless skipped.empty?
      names = skipped.map { |result| result[:name] }.join(", ")
      raise "R10 cache is incomplete; no artifact generated for: #{names}"
    end

    verified = Corpus::Census.verified_gem_names(
      File.join(repo_root, "data", "verified_gems.json")
    )
    ok_results = results.select { |result| result[:status] == :ok }

    targets = ok_results.map do |result|
      spec = Corpus::Gems::LIST.find { |entry| entry[:name] == result[:name] }
      build_target(result, spec, cache_dir, verified)
    end

    {
      "schema_version" => SCHEMA_VERSION,
      "tool" => TOOL_NAME,
      "machine_gate" => {
        "candidate_count" => results.size,
        "status_ok_count" => ok_results.size,
        "excluded_count" => results.count { |result| result[:status] == :excluded },
        "skipped_count" => skipped.size,
        "verified_record_count" => targets.count { |target| target.dig("verification", "recorded_in_data_verified_gems") },
        "manual_classification_pending_count" => targets.count { |target| target.dig("classification", "manual") == MANUAL_PENDING },
        "scanner_findings_count" => targets.sum { |target| target.dig("scanner", "summary", "total_findings") }
      },
      "limitations" => LIMITATIONS,
      "targets" => targets,
      "excluded" => results.reject { |result| result[:status] == :ok }.map do |result|
        excluded_record(result, cache_dir)
      end
    }
  end

  def build_target(result, spec, cache_dir, verified)
    gem_path = gem_path_for(result, cache_dir)
    source_root = source_root_for(result, cache_dir)
    ext_root = File.join(source_root, "ext")
    scanner = CorpusVariadicsScanner::Scanner.new(roots: [ext_root]).scan
    name = result[:name]
    recorded = verified.include?(name)

    {
      "name" => name,
      "version" => result[:version],
      "r10_profile" => result[:r10_profile] || "default-source",
      "r10_extconf_args" => Array(result[:r10_extconf_args]),
      "machine_gate" => {
        "status" => "ok",
        "ext_c_files" => result[:ext_c_files],
        "ext_h_files" => result[:ext_h_files]
      },
      "provenance" => {
        "gem_url" => "https://rubygems.org/downloads/#{name}-#{result[:version]}.gem",
        "gem_sha256" => Digest::SHA256.file(gem_path).hexdigest,
        "source_tarball_sha256" => nil,
        "cache_relative_path" => relative_to(cache_dir, gem_path),
        "unpacked_relative_path" => relative_to(cache_dir, source_root)
      },
      "generated_source" => {
        "status" => "not-reviewed",
        "commands" => nil,
        "note" => "R10-3 manual review must inspect extconf/Rake/generated translation units."
      },
      "scanner" => {
        "files_scanned" => scanner["files_scanned"],
        "summary" => scanner["summary"],
        "findings" => scanner["findings"],
        "errors" => scanner["errors"],
        "not_proof" => scanner["not_proof"],
        "not_acceptance_gate" => scanner["not_acceptance_gate"]
      },
      "classification" => {
        "manual" => MANUAL_PENDING,
        "pending_reason" => "R10-3 manual review is not complete; scanner output is a candidate list only.",
        "reviewer" => nil,
        "reviewed_at" => nil,
        "next_action" => "Review selected build path, macros/generated source, and each scanner candidate."
      },
      "verification" => {
        "recorded_in_data_verified_gems" => recorded,
        "record_path" => recorded ? "data/verified_gems.json" : nil,
        "control" => NOT_RUN,
        "rubycc" => NOT_RUN,
        "extension_load" => recorded ? "recorded in data/verified_gems.json; not re-run" : NOT_RUN,
        "upstream_suite" => recorded ? "recorded in data/verified_gems.json; not re-run" : NOT_RUN
      }
    }
  end

  def excluded_record(result, cache_dir)
    gem_path = gem_path_for(result, cache_dir)
    {
      "name" => result[:name],
      "version" => result[:version],
      "r10_profile" => result[:r10_profile] || "default-source",
      "r10_extconf_args" => Array(result[:r10_extconf_args]),
      "status" => result[:status].to_s,
      "reason" => result[:reason],
      "provenance" => gem_path && File.file?(gem_path) ? {
        "gem_url" => "https://rubygems.org/downloads/#{result[:name]}-#{result[:version]}.gem",
        "gem_sha256" => Digest::SHA256.file(gem_path).hexdigest,
        "cache_relative_path" => relative_to(cache_dir, gem_path)
      } : nil
    }
  end

  def gem_path_for(result, cache_dir)
    path = File.join(cache_dir, "#{result[:name]}-#{result[:version]}.gem")
    raise "missing cached gem: #{path}" unless File.file?(path)

    path
  end

  def source_root_for(result, cache_dir)
    path = File.join(cache_dir, "unpacked", "#{result[:name]}-#{result[:version]}")
    raise "missing unpacked source: #{path}" unless Dir.exist?(path)

    path
  end

  def relative_to(root, path)
    path.delete_prefix("#{File.expand_path(root)}/")
  end

  def markdown(artifact)
    gate = artifact.fetch("machine_gate")
    lines = []
    lines << "# R10 corpus machine scan"
    lines << ""
    lines << "**Generated artifact. Do not hand-edit.** Rebuild with `ruby tools/r10_corpus_scan.rb --cache DIR`."
    lines << ""
    lines << "This document records the machine-gate boundary, `.gem` provenance, and the heuristic variadic candidate scan for the 34 current R10 machine-gate targets. It is not a claim that manual classification or the R10 install/suite requirement is complete."
    lines << ""
    lines << "## Current boundary"
    lines << ""
    lines << "| candidate gems | machine-gate `ok` | excluded | verified records | scanner findings | manual classifications pending |"
    lines << "|---:|---:|---:|---:|---:|---:|"
    lines << "| #{gate["candidate_count"]} | #{gate["status_ok_count"]} | #{gate["excluded_count"]} | #{gate["verified_record_count"]} | #{gate["scanner_findings_count"]} | #{gate["manual_classification_pending_count"]} |"
    lines << ""
    lines << "`status: ok` is only the census machine gate. The 29 existing `data/verified_gems.json` records are evidence from earlier install/extension-load/upstream-suite runs; this scan does not rerun them. A missing record is not converted to skip or pass."
    lines << ""
    lines << "## Limitations and open evidence"
    lines << ""
    artifact.fetch("limitations").each { |limitation| lines << "- #{limitation}" }
    lines << ""
    lines << "The manual classification column is intentionally `pending` for all targets, including gems with zero lexical findings. The next task is R10-3: inspect the selected extconf/Rake path, macro expansion, generated source, and platform conditions, then classify each relevant candidate as (a) actual use, (b) false positive, or (c) requires more evidence."
    lines << ""
    lines << "## Target ledger"
    lines << ""
    lines << "| gem | version | profile | extconf args | gem SHA-256 | files | findings | candidate kinds | manual | control/rubycc/suite | next action |"
    lines << "|---|---|---|---|---|---:|---:|---|---|---|---|"
    artifact.fetch("targets").each do |target|
      summary = target.dig("scanner", "summary") || {}
      kinds = (summary["by_kind"] || {}).keys.join(", ")
      kinds = "—" if kinds.empty?
      verification = target.fetch("verification")
      verification_state = verification["recorded_in_data_verified_gems"] ? "recorded; not rerun" : "not run"
      args = target.fetch("r10_extconf_args").empty? ? "—" : target.fetch("r10_extconf_args").join(" ")
      lines << "| #{target["name"]} | #{target["version"]} | #{target["r10_profile"]} | #{args} | `#{target.dig("provenance", "gem_sha256")}` | #{target.dig("scanner", "files_scanned")} | #{summary["total_findings"]} | #{kinds} | #{target.dig("classification", "manual")} | #{verification_state} | #{target.dig("classification", "next_action")} |"
    end
    lines << ""
    lines << "## Candidate details"
    lines << ""
    candidates = artifact.fetch("targets").select { |target| target.dig("scanner", "summary", "total_findings").to_i.positive? }
    if candidates.empty?
      lines << "No lexical candidates were reported. This is not an absence proof."
    else
      lines << "The following are scanner candidates for R10-3 review; they are not implementation conclusions."
      lines << ""
      candidates.each do |target|
        lines << "### #{target["name"]} #{target["version"]}"
        lines << ""
        target.dig("scanner", "findings").each do |finding|
          detail = finding["details"].map { |key, value| "#{key}=#{value}" }.join(", ")
          lines << "- `#{finding["path"]}:#{finding["line"]}:#{finding["column"]}` **#{finding["kind"]}** (#{finding["confidence"]}); `#{finding["evidence"]}`; #{detail}"
        end
        lines << ""
      end
    end
    lines << "## Excluded from the machine-gate denominator"
    lines << ""
    lines << "| gem | version | status | reason |"
    lines << "|---|---|---|---|"
    artifact.fetch("excluded").each do |entry|
      lines << "| #{entry["name"]} | #{entry["version"]} | #{entry["status"]} | #{entry["reason"].to_s.gsub("|", "\\|")} |"
    end
    lines << ""
    lines.join("\n")
  end

  def write(artifact, json_path:, markdown_path:)
    File.write(json_path, JSON.pretty_generate(artifact) + "\n")
    File.write(markdown_path, markdown(artifact))
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    repo_root: ROOT,
    cache_dir: ENV["R10_CORPUS_CACHE"] || ENV["RUBYCC_CORPUS_CACHE"],
    json_path: File.join(ROOT, "data", "r10_corpus_scan.json"),
    markdown_path: File.join(ROOT, "docs", "development", "R10-CORPUS-SCAN.md")
  }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/r10_corpus_scan.rb --cache DIR [options]"
    opts.on("--cache DIR", "existing corpus census cache; no network is used") { |value| options[:cache_dir] = value }
    opts.on("--json PATH", "JSON artifact path") { |value| options[:json_path] = value }
    opts.on("--markdown PATH", "Markdown report path") { |value| options[:markdown_path] = value }
  end
  parser.parse!
  abort "--cache DIR (or R10_CORPUS_CACHE) is required" if options[:cache_dir].to_s.empty?

  artifact = R10CorpusScan.build(repo_root: options[:repo_root], cache_dir: options[:cache_dir])
  R10CorpusScan.write(artifact, json_path: options[:json_path], markdown_path: options[:markdown_path])
  warn "generated #{options[:json_path]}"
  warn "generated #{options[:markdown_path]}"
end
