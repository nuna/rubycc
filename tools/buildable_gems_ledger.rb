# frozen_string_literal: true

# data/buildable_gems.json -- the ledger of gems rubycc can *build*: the gem
# installs and the shared object it produced can be loaded.
#
# It exists because "buildable" and "in the corpus" must not be the same
# operation. R10's pass rate has its denominator in test/corpus/gems.rb and its
# numerator in data/verified_gems.json, so recording a cheap build_load result
# in either of those would move a rate that is only allowed to mean the
# expensive claim ("the gem's own suite passed"). This file is read by neither.
#
# The claim recorded here is exactly what tools/verify_corpus_candidate.rb
# measures in --mode build_load or --mode load_sanity, and no more: rubycc
# built the gem, and its shared object loaded. load_sanity counts too because
# it proves that same claim by reading the gem the way its users actually do
# -- through its own documented entrypoint -- rather than by requiring the
# built .so on its own, which some extensions (ox, kgio, raindrops) never
# expect to happen and so fail outright. Evidence that a test suite passed
# belongs in data/verified_gems.json; CLAIM_OUT_OF_SCOPE below refuses it here,
# because a ledger whose entries make two different claims can no longer be
# counted.

require "json"
require "time"

require_relative "gem_ledger_format"

module BuildableGemsLedger
  ROOT = File.expand_path("..", __dir__)
  DEFAULT_PATH = File.join(ROOT, "data", "buildable_gems.json").freeze

  # The array key. Not "verifications": the (d)-level database uses that word,
  # and the two arrays hold different claims, so they do not share a name.
  RECORDS_KEY = "builds"

  # The vocabulary of the claim this ledger may not make. A build_load run never
  # executes the gem's own suite, so any sentence like these would be an
  # unmeasured assertion dressed as evidence.
  CLAIM_OUT_OF_SCOPE = /test suite|suite passed|tests passed|passed .{0,20}suite|examples?,? \d+ failures/i

  # A result is recordable only when the tool proved both halves of the claim:
  # the candidate installed and loaded, and the build really went through
  # rubycc (rubycc_build_evidence). A --compiler host run reports
  # "not_applicable" for the second and is therefore never recorded: it says
  # nothing about rubycc.
  #
  # "build_load_pass" and "documented_load_pass" both count. They prove the
  # same two things this ledger claims (rubycc built it, and its .so loaded);
  # they differ only in how the .so was loaded, not in what got proven.
  # documented_load_pass in fact reads the gem the way a user would -- through
  # its own documented entrypoint -- rather than requiring the built .so on
  # its own, which is why extensions that assume that entrypoint (ox, kgio,
  # raindrops) fail the plain require and need it. A recipe's sanity_kind may
  # run a stronger, gem-specific functional probe on top of that (e.g.
  # graphql_c_parser), but this ledger never repeats that probe in its
  # evidence, so recording the result does not smuggle the stronger claim in
  # under the weaker one.
  # "documented_load_failed", "fallback_or_not_loaded", and a host run's
  # "not_applicable" evidence remain unrecordable: none of them proves the
  # .so loaded through rubycc.
  def self.recordable?(result)
    %w[build_load_pass documented_load_pass].include?(result["status"]) &&
      result.dig("execution", "rubycc_build_evidence") == "pass"
  end

  # What a pass actually establishes, in the words of the traces the tool
  # checks. Deliberately free of the gem's version in both branches:
  # `versions` is a union over every version measured in this environment, so
  # a version named in the prose would go stale the moment a second one is
  # added.
  def self.evidence(result)
    case result["status"]
    when "build_load_pass"
      "RUBYCC=1 gem install succeeded with the extension built through rmake " \
        "(gem_make.out names exe/rmake and the generated Makefile names exe/rubycc), " \
        "and every shared object it produced was proven loaded by require " \
        "(tools/verify_corpus_candidate.rb --mode build_load --compiler rubycc)."
    when "documented_load_pass"
      requires = result.fetch("load_recipe").fetch("entrypoint").fetch("requires").join(", ")
      dependencies = Array(result.dig("load_recipe", "dependencies"))
      dependency_clause = dependencies.empty? ? "" :
        " Recipe dependencies (#{dependencies.map { |dep| dep.fetch("name") }.join(", ")}) " \
        "were installed with the host toolchain first, so this establishes the claim for the " \
        "candidate's own shared object only."
      "RUBYCC=1 gem install succeeded with the extension built through rmake " \
        "(gem_make.out names exe/rmake and the generated Makefile names exe/rubycc), " \
        "and every shared object it produced was proven loaded by requiring the gem's own " \
        "documented entrypoint (#{requires}) " \
        "(tools/verify_corpus_candidate.rb --mode load_sanity --compiler rubycc).#{dependency_clause}"
    end
  end

  # Merge one measurement into +db+ (parsed JSON) and return [db, how].
  #
  # The record selection rule is the one tools/verify_gem_tests.rb uses: a run
  # speaks only for the environment it ran in, so it updates that environment's
  # record and leaves every other one untouched, appending a new record when the
  # environment has none yet.
  #
  # Evidence is regenerated rather than appended to, which is where this
  # diverges from the (d)-level database. There, evidence accumulates the step
  # history that a re-run cannot reconstruct. Here it names no step and no
  # version, so a re-run produces the identical sentence and appending would
  # only duplicate it.
  def self.merge(db, name:, version:, environment:, today:, evidence:)
    raise ArgumentError, "evidence claims more than build_load: #{evidence.inspect}" if
      evidence.match?(CLAIM_OUT_OF_SCOPE)

    existing = db[name]
    entry = existing ? existing.dup : {}
    records = Array(entry[RECORDS_KEY]).map(&:dup)
    record = records.find { |r| r["environment"] == environment }

    if record
      record["versions"] = Array(record["versions"]) | [version]
      record["verified_at"] = today
      record["evidence"] = evidence
      how = "updated #{environment}"
    else
      records << {
        "versions" => [version],
        "environment" => environment,
        "verified_at" => today,
        "evidence" => evidence
      }
      how = existing ? "new environment #{environment}" : "new entry"
    end

    entry[RECORDS_KEY] = records
    # `notes` is the human's column here too: a machine cannot observe the
    # caveats worth writing down, so an existing one is kept as it stands and a
    # new entry starts empty rather than with invented prose.
    entry["notes"] = entry["notes"].to_s
    db[name] = entry
    [db, how]
  end

  # Record a build_load result, if it is one. Returns nil when the result makes
  # no recordable claim, otherwise a summary of what was written.
  def self.record(result, path: DEFAULT_PATH, environment: GemLedgerFormat.environment_string,
                  today: Time.now.strftime("%Y-%m-%d"))
    return nil unless recordable?(result)

    name = result.fetch("input").fetch("name")
    version = result.fetch("input").fetch("version")
    db = File.file?(path) ? JSON.parse(File.read(path, encoding: Encoding::UTF_8)) : {}
    db, how = merge(db, name: name, version: version, environment: environment,
                        today: today, evidence: evidence(result))
    File.write(path, GemLedgerFormat.emit(db, records_key: RECORDS_KEY))
    { "name" => name, "version" => version, "environment" => environment, "how" => how, "path" => path }
  end
end
