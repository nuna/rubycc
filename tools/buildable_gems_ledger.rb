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
# --mode build_load measures, and no more. Evidence that a test suite passed
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
  # the candidate installed and loaded (build_load_pass), and the build really
  # went through rubycc (rubycc_build_evidence). A --compiler host run reports
  # "not_applicable" for the second and is therefore never recorded: it says
  # nothing about rubycc.
  #
  # The documented-entrypoint modes (load_sanity) end in "documented_load_pass",
  # a different and recipe-specific claim; they are not written here either.
  def self.recordable?(result)
    result["status"] == "build_load_pass" &&
      result.dig("execution", "rubycc_build_evidence") == "pass"
  end

  # What a build_load pass actually establishes, in the words of the two traces
  # the tool checks. Deliberately free of the gem's version: `versions` is a
  # union over every version measured in this environment, so a version named in
  # the prose would go stale the moment a second one is added.
  def self.evidence(result)
    "RUBYCC=1 gem install succeeded with the extension built through rmake " \
      "(gem_make.out names exe/rmake and the generated Makefile names exe/rubycc), " \
      "and every shared object it produced was proven loaded by require " \
      "(tools/verify_corpus_candidate.rb --mode build_load --compiler rubycc)."
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
