# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/doctor"
require "json"
require "fileutils"
require "stringio"
require "tmpdir"

require_relative "corpus/census"
require_relative "../tools/buildable_gems_ledger"

# data/buildable_gems.json -- the ledger of gems rubycc can *build* (install +
# load the shared object it produced), written by
# tools/verify_corpus_candidate.rb --mode build_load --update.
#
# Two things must stay true of it, and both are the reason the file exists at
# all rather than the gems simply being added to test/corpus/gems.rb:
#
#   1. R10 does not count it. Its denominator is the corpus gem list and its
#      numerator is data/verified_gems.json; a cheap build_load result must not
#      be able to move a rate that means the expensive claim. These tests pin
#      that by *watching what the R10 paths read*, not by grepping for a name.
#   2. The two ledgers' claims do not mix. A build_load run never executes the
#      gem's own suite, so no record here may say that one passed.
class TestBuildableGems < Minitest::Test
  Doctor = Rubycc::Doctor
  CENSUS = Corpus::Census
  LEDGER = BuildableGemsLedger
  PATH = BuildableGemsLedger::DEFAULT_PATH

  # Records every path handed to a File class method while a block runs, so a
  # test can ask what a code path actually opened. Inert outside #reading_paths:
  # prepending cannot be undone, and a permanently active recorder would slow
  # (and observe) every other test in the process.
  module PathRecorder
    class << self
      attr_accessor :sink
    end

    %i[read open file? exist? readlines binread foreach size].each do |name|
      define_method(name) do |*args, **kwargs, &block|
        PathRecorder.sink << args.first.to_s if PathRecorder.sink && !args.empty?
        super(*args, **kwargs, &block)
      end
    end
  end
  File.singleton_class.prepend(PathRecorder)

  def reading_paths
    PathRecorder.sink = []
    yield
    PathRecorder.sink
  ensure
    PathRecorder.sink = nil
  end

  def shipped
    JSON.parse(File.read(PATH, encoding: Encoding::UTF_8))
  end

  # --- schema (holds for the empty ledger too) ------------------------------

  def test_ledger_is_valid_json_and_matches_schema
    raw = shipped
    assert_kind_of Hash, raw

    raw.each do |name, attrs|
      assert_kind_of String, name
      %w[builds notes].each { |key| assert attrs.key?(key), "#{name}: missing #{key.inspect}" }
      assert_kind_of Array, attrs["builds"], "#{name}: builds must be an array"
      # An entry with no build record would assert nothing at all; the gem
      # simply should not be in the ledger in that case.
      refute_empty attrs["builds"], "#{name}: builds must not be empty"
      assert_kind_of String, attrs["notes"], "#{name}: notes must be a string"

      attrs["builds"].each do |record|
        %w[versions environment verified_at evidence].each do |key|
          assert record.key?(key), "#{name}: build record missing #{key.inspect}"
        end
        assert_kind_of Array, record["versions"], "#{name}: versions must be an array"
        refute_empty record["versions"], "#{name}: versions must not be empty"
        record["versions"].each { |req| Gem::Requirement.new(req) }
        assert_match(/\A\d{4}-\d{2}-\d{2}\z/, record["verified_at"], "#{name}: verified_at YYYY-MM-DD")
        %w[environment evidence].each do |key|
          assert_kind_of String, record[key], "#{name}: #{key} must be a string"
        end
        refute_empty record["evidence"], "#{name}: evidence must not be empty"
      end
    end
  end

  # The ledger ships empty and must stay legible while it is: the emitter has to
  # produce a parsable file for a database with no entries at all.
  def test_empty_ledger_is_written_as_an_empty_object
    assert_equal({}, JSON.parse(GemLedgerFormat.emit({}, records_key: "builds")))
    assert_equal "{}\n", GemLedgerFormat.emit({}, records_key: "builds")
  end

  # The two files differ in what they claim, not in how they are written. A
  # second copy of the emitter would let the house style drift, so the shared
  # one has to reproduce the (d)-level database byte for byte.
  def test_house_style_is_shared_with_the_verified_gems_database
    raw = File.read(Doctor::VerifiedGems::DEFAULT_PATH, encoding: Encoding::UTF_8)
    assert_equal raw, GemLedgerFormat.emit(JSON.parse(raw), records_key: "verifications")
  end

  # `builds`, not `verifications`: a name shared between two different claims is
  # the first step to counting them together.
  def test_records_live_under_builds_and_never_under_verifications
    assert_equal "builds", LEDGER::RECORDS_KEY
    shipped.each_value { |attrs| refute attrs.key?("verifications"), "build records must not be called verifications" }
  end

  # --- claim strength -------------------------------------------------------

  def test_no_record_claims_a_gem_test_suite_passed
    shipped.each do |name, attrs|
      attrs["builds"].each do |record|
        refute_match LEDGER::CLAIM_OUT_OF_SCOPE, record["evidence"],
                     "#{name}: (d)-level claims belong in data/verified_gems.json"
      end
      refute_match LEDGER::CLAIM_OUT_OF_SCOPE, attrs["notes"].to_s,
                   "#{name}: notes must not claim a suite result either"
    end
  end

  def test_generated_evidence_names_only_what_a_build_load_run_measures
    evidence = LEDGER.evidence(build_load_pass)

    refute_match LEDGER::CLAIM_OUT_OF_SCOPE, evidence
    assert_includes evidence, "exe/rmake"
    assert_includes evidence, "exe/rubycc"
    assert_includes evidence, "--mode build_load"
    # Version-free on purpose: `versions` is a union over every version measured
    # in this environment, so prose naming one of them goes stale at the second.
    refute_includes evidence, "1.2.0"
  end

  def test_generated_evidence_for_a_documented_load_pass_names_the_entrypoint_and_mode
    evidence = LEDGER.evidence(documented_load_pass(requires: ["ox"], dependencies: []))

    refute_match LEDGER::CLAIM_OUT_OF_SCOPE, evidence
    assert_includes evidence, "exe/rmake"
    assert_includes evidence, "exe/rubycc"
    assert_includes evidence, "ox"
    assert_includes evidence, "--mode load_sanity"
    refute_includes evidence, "2.14.29"
  end

  def test_generated_evidence_for_a_documented_load_pass_with_dependencies_names_the_host_install
    evidence = LEDGER.evidence(
      documented_load_pass(requires: ["ox"], dependencies: [{ "name" => "bigdecimal", "version" => "4.1.2" }])
    )

    refute_match LEDGER::CLAIM_OUT_OF_SCOPE, evidence
    assert_includes evidence, "bigdecimal"
    assert_includes evidence, "host toolchain"
  end

  def test_merge_refuses_evidence_that_claims_more_than_a_build
    error = assert_raises(ArgumentError) do
      LEDGER.merge({}, name: "debug_inspector", version: "1.2.0", environment: "e",
                       today: "2026-09-12", evidence: "the gem's own test suite passed 10 tests")
    end
    assert_match(/claims more than build_load/, error.message)
  end

  # --- what counts as a recordable result -----------------------------------

  def build_load_pass(status: "build_load_pass", rubycc_build_evidence: "pass")
    {
      "status" => status,
      "input" => { "name" => "debug_inspector", "version" => "1.2.0" },
      "execution" => { "rubycc_build_evidence" => rubycc_build_evidence }
    }
  end

  def documented_load_pass(requires:, dependencies:, rubycc_build_evidence: "pass")
    {
      "status" => "documented_load_pass",
      "input" => { "name" => "ox", "version" => "2.14.29" },
      "execution" => { "rubycc_build_evidence" => rubycc_build_evidence },
      "load_recipe" => {
        "dependencies" => dependencies,
        "entrypoint" => { "requires" => requires, "sanity_kind" => "entrypoint_loaded" }
      }
    }
  end

  def test_only_a_rubycc_build_or_documented_load_pass_is_recordable
    assert LEDGER.recordable?(build_load_pass)
    # load_sanity's pass proves the same two things through the gem's own
    # documented entrypoint instead of a bare require, so it counts too.
    assert LEDGER.recordable?(build_load_pass(status: "documented_load_pass"))

    # A host-compiler control proves nothing about rubycc...
    refute LEDGER.recordable?(build_load_pass(rubycc_build_evidence: "not_applicable"))
    refute LEDGER.recordable?(build_load_pass(rubycc_build_evidence: "missing"))
    refute LEDGER.recordable?(build_load_pass(status: "documented_load_pass", rubycc_build_evidence: "not_applicable"))
    # ...and neither does anything short of a load.
    refute LEDGER.recordable?(build_load_pass(status: "build_failed"))
    refute LEDGER.recordable?(build_load_pass(status: "fallback_or_not_loaded"))
    refute LEDGER.recordable?(build_load_pass(status: "documented_load_failed"))
  end

  def test_record_writes_nothing_for_a_result_that_earned_no_claim
    in_temp_ledger("{}\n") do |path|
      assert_nil LEDGER.record(build_load_pass(status: "build_failed"), path: path)
      assert_equal "{}\n", File.read(path)
    end
  end

  def test_record_writes_a_documented_load_pass
    in_temp_ledger("{}\n") do |path|
      summary = LEDGER.record(documented_load_pass(requires: ["ox"], dependencies: []),
                               path: path, environment: "e", today: "2026-09-13")
      refute_nil summary
      record = JSON.parse(File.read(path)).fetch("ox").fetch("builds").first
      assert_includes record.fetch("evidence"), "ox"
      assert_includes record.fetch("evidence"), "--mode load_sanity"
    end
  end

  def test_record_writes_nothing_for_documented_load_failure_or_fallback_or_host
    in_temp_ledger("{}\n") do |path|
      assert_nil LEDGER.record(documented_load_pass(requires: ["ox"], dependencies: [])
                                  .merge("status" => "documented_load_failed"), path: path)
      assert_nil LEDGER.record(build_load_pass(status: "fallback_or_not_loaded"), path: path)
      assert_nil LEDGER.record(build_load_pass(rubycc_build_evidence: "not_applicable"), path: path)
      assert_equal "{}\n", File.read(path)
    end
  end

  # --- record selection (same rule as tools/verify_gem_tests.rb) ------------

  def in_temp_ledger(initial)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "buildable_gems.json")
      File.write(path, initial)
      yield path
    end
  end

  def test_record_creates_an_entry_then_updates_only_its_own_environment
    in_temp_ledger("{}\n") do |path|
      first = LEDGER.record(build_load_pass, path: path, environment: "glibc x86_64 / ruby 3.4.5",
                                             today: "2026-09-12")
      assert_equal "new entry", first.fetch("how")

      # Same environment, a second version: the record is updated in place and
      # `versions` becomes the union.
      newer = build_load_pass
      newer["input"]["version"] = "1.3.0"
      second = LEDGER.record(newer, path: path, environment: "glibc x86_64 / ruby 3.4.5", today: "2026-09-20")
      assert_equal "updated glibc x86_64 / ruby 3.4.5", second.fetch("how")

      # A different environment appends rather than overwriting: a run only ever
      # speaks for the machine it ran on.
      third = LEDGER.record(build_load_pass, path: path, environment: "musl x86_64 / ruby 4.0.6",
                                             today: "2026-09-21")
      assert_equal "new environment musl x86_64 / ruby 4.0.6", third.fetch("how")

      builds = JSON.parse(File.read(path)).fetch("debug_inspector").fetch("builds")
      assert_equal ["glibc x86_64 / ruby 3.4.5", "musl x86_64 / ruby 4.0.6"], builds.map { |b| b["environment"] }
      assert_equal ["1.2.0", "1.3.0"], builds.first.fetch("versions")
      assert_equal "2026-09-20", builds.first.fetch("verified_at")
      # Regenerated, not appended: the sentence names no step and no version, so
      # a re-run produces exactly the one already there.
      assert_equal LEDGER.evidence(newer), builds.first.fetch("evidence")
      assert_equal ["1.2.0"], builds.last.fetch("versions")
    end
  end

  # `notes` is the human's column in this ledger too, so a re-run must not
  # silently drop a caveat no measurement can rediscover.
  def test_record_keeps_human_written_notes
    entry = { "debug_inspector" => { "builds" => [], "notes" => "needs -fno-common on this host" } }
    in_temp_ledger(JSON.generate(entry)) do |path|
      LEDGER.record(build_load_pass, path: path, environment: "e", today: "2026-09-12")
      assert_equal "needs -fno-common on this host",
                   JSON.parse(File.read(path)).fetch("debug_inspector").fetch("notes")
    end
  end

  # --- R10 does not count this ledger ---------------------------------------

  # The census is what computes the R10 rate. Its inputs are the corpus gem list
  # and data/verified_gems.json; if the build ledger ever became a third one,
  # a build_load result would start moving the rate.
  def test_the_census_r10_path_never_reads_the_build_ledger
    results = [{ name: "debug_inspector", status: :ok, includes: {}, ruby_self: [], ext_c_files: 1,
                 ext_h_files: 0, requested_version: "1.2.0", version: "1.2.0", r10_profile: "default-source",
                 r10_extconf_args: [] }]
    root = File.expand_path("..", __dir__)

    paths = reading_paths do
      verified = CENSUS.verified_gem_names(CENSUS.default_verified_gems_path(root))
      CENSUS.render_report(results, Set.new, verified)
    end

    refute_empty paths, "the recorder saw nothing, so it is not proving anything"
    assert paths.any? { |path| path.end_with?("verified_gems.json") },
           "the R10 numerator must still come from the (d)-level database"
    refute paths.any? { |path| path.include?("buildable_gems") },
           "the R10 path read the build ledger: #{paths.inspect}"
  end

  # The other half: a gem that is *only* in the build ledger contributes nothing
  # to the numerator, whatever the census reads.
  def test_a_build_ledger_entry_does_not_raise_the_r10_rate
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "data"))
      File.write(File.join(root, "data", "verified_gems.json"), "{}\n")
      File.write(File.join(root, "data", "buildable_gems.json"),
                 JSON.generate("debug_inspector" => { "builds" => [], "notes" => "" }))

      verified = CENSUS.verified_gem_names(CENSUS.default_verified_gems_path(root))
      summary = CENSUS.r10_summary(["debug_inspector"], verified)

      assert_equal 1, summary.fetch(:denominator)
      assert_equal 0, summary.fetch(:numerator)
      assert_in_delta 0.0, summary.fetch(:rate)
    end
  end

  # doctor's verdict comes from the same database as the R10 numerator. A gem in
  # the build ledger and nowhere else must still take the build path, and the
  # ledger must not even be among the files doctor opens.
  def test_doctor_neither_reads_the_build_ledger_nor_calls_its_gems_verified
    lock = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          debug_inspector (1.2.0)

      DEPENDENCIES
        debug_inspector
    LOCK

    builder = FakeBuilder.new
    out = StringIO.new
    paths = nil

    Dir.mktmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write("#{gemfile}.lock", lock)
      data = File.join(dir, "verified_gems.json")
      File.write(data, "{}\n")
      File.write(File.join(dir, "buildable_gems.json"),
                 JSON.generate("debug_inspector" => { "builds" => [], "notes" => "" }))

      paths = reading_paths do
        Doctor::CLI.run(["--gemfile", gemfile, "--data", data], out: out, err: StringIO.new, builder: builder)
      end
    end

    assert_equal ["debug_inspector"], builder.calls,
                 "a gem the build ledger lists is not verified: doctor must still build it"
    assert_includes out.string, "built on the spot"
    refute paths.any? { |path| path.include?("buildable_gems") },
           "doctor read the build ledger: #{paths.inspect}"
  end

  # A stand-in for the on-the-spot builder, so the decision flow runs offline.
  class FakeBuilder
    def initialize
      @calls = []
    end
    attr_reader :calls

    def build(entry)
      @calls << entry.name
      Doctor::Builder::Result.new(status: :built, sos: ["debug_inspector.so"], require_ok: true)
    end
  end
end
