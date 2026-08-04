# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/doctor"
require "stringio"
require "json"
require "tmpdir"

# Step 67 (ROADMAP §6 "M3 完了後のツール"): `rubycc doctor`, the adoption-check
# command. These tests pin the parts that must be correct regardless of the
# network: the shipped verified_gems.json schema, the Gemfile.lock/Gemfile
# parsers, the verified-database version matching, and the decision flow that
# turns per-gem outcomes into a report and an exit code (the network fetch and
# the on-the-spot build are injected as a fake builder here). The real networked
# end-to-end — build an unverified gem for real — is opt-in behind
# RMAKE_ACCEPTANCE=1.
class TestDoctor < Minitest::Test
  Doctor  = Rubycc::Doctor
  DATA    = Doctor::VerifiedGems::DEFAULT_PATH
  R       = Doctor::Builder::Result

  # --- verified_gems.json schema (always on) --------------------------------

  def test_verified_gems_json_is_valid_and_matches_schema
    raw = JSON.parse(File.read(DATA))
    assert_kind_of Hash, raw
    refute_empty raw

    raw.each do |name, attrs|
      assert_kind_of String, name
      %w[verifications notes].each do |key|
        assert attrs.key?(key), "#{name}: missing #{key.inspect}"
      end
      assert_kind_of Array, attrs["verifications"], "#{name}: verifications must be an array"
      # An entry with no verification would assert nothing at all; the gem
      # simply should not be in the database in that case.
      refute_empty attrs["verifications"], "#{name}: verifications must not be empty"
      assert_kind_of String, attrs["notes"], "#{name}: notes must be a string"

      attrs["verifications"].each do |record|
        %w[versions environment verified_at evidence].each do |key|
          assert record.key?(key), "#{name}: verification missing #{key.inspect}"
        end
        assert_kind_of Array, record["versions"], "#{name}: versions must be an array"
        refute_empty record["versions"], "#{name}: versions must not be empty"
        record["versions"].each do |req|
          # Every entry must be a valid Gem::Requirement grammar (exact or range).
          Gem::Requirement.new(req)
        end
        assert_match(/\A\d{4}-\d{2}-\d{2}\z/, record["verified_at"], "#{name}: verified_at YYYY-MM-DD")
        %w[environment evidence].each do |key|
          assert_kind_of String, record[key], "#{name}: #{key} must be a string"
        end
      end
    end
  end

  def test_verified_gems_json_holds_only_confirmed_gems
    raw = JSON.parse(File.read(DATA))
    assert_equal %w[bigdecimal date digest erb etc io-console io-nonblock io-wait json msgpack nkf psych racc redcarpet
                    stackprof stringio strscan zlib],
                 raw.keys.sort

    # `versions` lives inside each verification record, so the assertion is
    # "some environment verified this version", which is what doctor reports.
    all_versions = ->(name) { raw.fetch(name)["verifications"].flat_map { |v| v["versions"] } }
    assert_includes all_versions["json"], "2.21.1"
    assert_includes all_versions["msgpack"], "1.8.3"
    assert_includes all_versions["bigdecimal"], "4.1.2"
    assert_includes all_versions["date"], "3.5.1"
    assert_includes all_versions["racc"], "1.8.1"
    assert_includes all_versions["redcarpet"], "3.6.1"
    assert_includes all_versions["nkf"], "0.3.0"
    assert_includes all_versions["stackprof"], "0.2.28"
    assert_includes all_versions["strscan"], "3.1.6"
    assert_includes all_versions["stringio"], "3.2.0"
    # etc was recorded in Step 162 but never pinned here; the allow-list above
    # only fixes *which* gems may appear, so a version pin is the separate check.
    assert_includes all_versions["etc"], "1.4.6"
    assert_includes all_versions["io-nonblock"], "0.3.2"
    assert_includes all_versions["io-wait"], "0.4.0"
    assert_includes all_versions["erb"], "6.0.1.1"
    assert_includes all_versions["io-console"], "0.8.2"
    assert_includes all_versions["digest"], "3.2.1"
    assert_includes all_versions["zlib"], "3.2.3"
    assert_includes all_versions["psych"], "5.3.1"

    # The first record from a libc other than glibc (Step 183). It is pinned
    # because the nested schema was built for exactly this -- one gem, one
    # entry, one verification per environment -- and until this run every
    # environment string in the file was the same one, so nothing proved the
    # per-environment half of the schema was reachable.
    io_wait_envs = raw.fetch("io-wait")["verifications"].map { |v| v["environment"] }
    assert_includes io_wait_envs, "musl x86_64 / ruby 4.0.6"
  end

  # --- gemspec packaging ----------------------------------------------------

  def test_gemspec_ships_data_and_doctor_exe
    root = File.expand_path("..", __dir__)
    spec = Dir.chdir(root) { Gem::Specification.load(File.join(root, "rubycc.gemspec")) }
    assert_includes spec.files, "data/verified_gems.json", "the verified-gems data must be packaged"
    assert_includes spec.files, "exe/rubycc-doctor", "the doctor executable must be packaged"
    assert_includes spec.executables, "rubycc-doctor", "rubycc-doctor must be a registered command"
  end

  # --- VerifiedGems matching ------------------------------------------------

  def build_db(hash)
    Doctor::VerifiedGems.new(hash)
  end

  # One verification record with the fields the schema requires, so fixtures only
  # have to name the parts the test under discussion actually cares about.
  def verification(versions, environment: "x", verified_at: "2026-07-17", evidence: "y")
    { "versions" => Array(versions), "environment" => environment,
      "verified_at" => verified_at, "evidence" => evidence }
  end

  def entry(*records, notes: "")
    { "verifications" => records, "notes" => notes }
  end

  def test_verified_exact_version_match
    db = build_db("json" => entry(verification("2.21.1")))
    assert db.verified?("json", "2.21.1")
    refute db.verified?("json", "2.21.0")
    refute db.verified?("json", nil)
    refute db.verified?("other", "2.21.1")
  end

  def test_verified_range_match
    db = build_db("foo" => entry(verification(">= 1.8, < 2")))
    assert db.verified?("foo", "1.8.3")
    assert db.verified?("foo", "1.9.0")
    refute db.verified?("foo", "2.0.0")
    refute db.verified?("foo", "1.7.0")
  end

  # Being verified in *any* environment is what "verified" means, but a caller
  # that reports where it held needs the per-environment breakdown.
  def test_matching_verifications_returns_every_environment_that_covers_the_version
    db = build_db(
      "foo" => entry(
        verification(["1.0.0", "1.1.0"], environment: "glibc x86_64 / ruby 3.4.5", verified_at: "2026-07-17"),
        verification("1.1.0", environment: "musl x86_64 / ruby 3.4.5", verified_at: "2026-08-02")
      )
    )
    both = db.matching_verifications("foo", "1.1.0")
    assert_equal ["glibc x86_64 / ruby 3.4.5", "musl x86_64 / ruby 3.4.5"], both.map(&:environment)

    only_glibc = db.matching_verifications("foo", "1.0.0")
    assert_equal ["glibc x86_64 / ruby 3.4.5"], only_glibc.map(&:environment)

    assert_empty db.matching_verifications("foo", "2.0.0")
    assert_empty db.matching_verifications("missing", "1.1.0")

    # The convenience union stays de-duplicated and in record order.
    assert_equal ["1.0.0", "1.1.0"], db["foo"].versions
  end

  def test_shipped_database_verifies_json_and_msgpack
    db = Doctor::VerifiedGems.load
    assert db.verified?("json", "2.21.1")
    assert db.verified?("msgpack", "1.8.3")
    refute db.verified?("json", "9.9.9")
  end

  # --- Gemfile.lock parser --------------------------------------------------

  LOCK = <<~LOCK
    PATH
      remote: .
      specs:
        myapp (0.1.0)

    GEM
      remote: https://rubygems.org/
      specs:
        json (2.21.1)
        msgpack (1.8.3)
        nokogiri (1.16.0)
          racc (~> 1.4)
        racc (1.8.1)
        rake (13.2.1)

    PLATFORMS
      ruby
      x86_64-linux

    DEPENDENCIES
      json
      msgpack
      nokogiri
      rake

    BUNDLED WITH
       2.6.9
  LOCK

  def test_lock_parser_reads_resolved_specs
    result = Doctor::Gemfile.parse_lock(LOCK)
    assert_equal :lock, result.origin

    gem_entries = result.entries.select { |e| e.source == :gem }
    assert_equal %w[json msgpack nokogiri racc rake], gem_entries.map(&:name).sort
    json = gem_entries.find { |e| e.name == "json" }
    assert_equal "2.21.1", json.version
  end

  def test_lock_parser_reads_dependencies_and_direct
    result = Doctor::Gemfile.parse_lock(LOCK)
    nokogiri = result.entries.find { |e| e.name == "nokogiri" }
    assert_equal ["racc"], nokogiri.dependencies
    assert_equal %w[json msgpack nokogiri rake], result.direct.sort
  end

  def test_lock_parser_marks_path_source
    result = Doctor::Gemfile.parse_lock(LOCK)
    myapp = result.entries.find { |e| e.name == "myapp" }
    assert_equal :path, myapp.source
  end

  # --- Gemfile (no lock) fallback parser ------------------------------------

  def test_gemfile_parser_reads_gem_lines
    text = <<~GEMFILE
      source "https://rubygems.org"
      gem "json"
      gem "rake", "~> 13.0"
      gem 'msgpack', '1.8.3'
      # gem "commented_out"
    GEMFILE
    result = Doctor::Gemfile.parse_gemfile(text)
    assert_equal :gemfile, result.origin
    names = result.entries.map(&:name)
    assert_equal %w[json msgpack rake], names.sort
    refute_includes names, "commented_out"
    assert_nil result.entries.find { |e| e.name == "json" }.version
    assert_equal "13.0", result.entries.find { |e| e.name == "rake" }.version
    assert_equal "1.8.3", result.entries.find { |e| e.name == "msgpack" }.version
  end

  def test_load_prefers_lock_over_gemfile
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), %(gem "json"\n))
      File.write(File.join(dir, "Gemfile.lock"), LOCK)
      result = Doctor::Gemfile.load(File.join(dir, "Gemfile"))
      assert_equal :lock, result.origin
    end
  end

  def test_load_returns_nil_when_absent
    Dir.mktmpdir do |dir|
      assert_nil Doctor::Gemfile.load(File.join(dir, "Gemfile"))
    end
  end

  # --- decision flow (fake builder, no network) -----------------------------

  # A builder stub keyed by gem name, so the flow can be exercised offline.
  class FakeBuilder
    def initialize(map)
      @map = map
      @calls = []
    end
    attr_reader :calls

    def build(entry)
      @calls << entry.name
      @map[entry.name] || R.new(status: :no_ext)
    end
  end

  def run_cli(lock_text, builder_map, verified: nil, argv_extra: [])
    Dir.mktmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write("#{gemfile}.lock", lock_text)
      out = StringIO.new
      err = StringIO.new
      # Leave `verified` nil unless a caller injects one directly: CLI.run
      # falls back to `--data` (when given via argv_extra) or the shipped
      # database on its own, so forcing a load here would shadow `--data`.
      code = Doctor::CLI.run(["--gemfile", gemfile, *argv_extra],
                             out: out, err: err,
                             verified: verified, builder: FakeBuilder.new(builder_map))
      [code, out.string, err.string]
    end
  end

  # Writes a test-only verified_gems.json with exactly the given entries and
  # yields its path. Tests that need to control which gems doctor treats as
  # verified use this instead of the shipped data/verified_gems.json, so they
  # don't break every time the shipped database gains a newly verified gem.
  def with_temp_verified_db(entries)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "verified_gems.json")
      File.write(path, JSON.generate(entries))
      yield path
    end
  end

  def test_flow_verified_gems_need_no_build
    map = { "rake" => R.new(status: :no_ext) }
    code, out, = run_cli(LOCK, map)
    assert_includes out, "json 2.21.1"
    assert_includes out, "verified"
    assert_includes out, "msgpack 1.8.3"
    # json/msgpack are verified so only the unverified nokogiri/racc/rake are built
    assert_includes out, "no C extension" # rake
  end

  def test_flow_failure_yields_exit_1_and_needs_attention
    # Use a test-only verified DB (via --data) rather than the shipped
    # data/verified_gems.json: this test checks what happens to a gem that is
    # NOT verified (it gets built on the spot, or fails). Pinning that
    # behaviour to the shipped database would make the test start failing
    # every time the corpus grows and a gem it names becomes verified. Only
    # json/msgpack (already resolved verified elsewhere in the flow) are
    # listed here; racc is deliberately left out so it takes the build path.
    db_entries = {
      "json"    => entry(verification("2.21.1")),
      "msgpack" => entry(verification("1.8.3"))
    }
    map = {
      "rake"     => R.new(status: :no_ext),
      "racc"     => R.new(status: :built, sos: ["racc.so"], require_ok: true),
      "nokogiri" => R.new(status: :failed, stage: :compile, reason: "boom")
    }
    with_temp_verified_db(db_entries) do |db_path|
      code, out, = run_cli(LOCK, map, argv_extra: ["--data", db_path])
      assert_equal 1, code
      assert_includes out, "✘"
      assert_includes out, "compile: boom"
      assert_includes out, "NEEDS ATTENTION"
      assert_includes out, "built on the spot"
    end
  end

  def test_flow_all_handled_yields_exit_0_and_adoptable
    map = {
      "rake"     => R.new(status: :no_ext),
      "racc"     => R.new(status: :built, sos: ["racc.so"], require_ok: true),
      "nokogiri" => R.new(status: :built, sos: ["nokogiri.so"], require_ok: true)
    }
    code, out, = run_cli(LOCK, map)
    assert_equal 0, code
    assert_includes out, "ADOPTABLE"
  end

  def test_flow_unknown_is_not_adoptable
    map = {
      "rake"     => R.new(status: :no_ext),
      "racc"     => R.new(status: :built, sos: ["racc.so"], require_ok: true),
      "nokogiri" => R.new(status: :unknown, reason: "offline")
    }
    code, out, = run_cli(LOCK, map)
    assert_equal 1, code
    assert_includes out, "undetermined"
  end

  def test_flow_max_builds_budget_caps_builds
    # Every unverified gem would build, but a budget of 1 stops after the first.
    map = Hash.new { R.new(status: :built, sos: ["x.so"], require_ok: true) }
    code, out, = run_cli(LOCK, map, argv_extra: ["--max-builds", "1"])
    assert_includes out, "skipped (build budget reached)"
    assert_equal 1, code # skipped-budget C-ext gems are not "handled"
  end

  def test_flow_local_source_is_skipped
    map = Hash.new { R.new(status: :no_ext) }
    _code, out, = run_cli(LOCK, map)
    assert_includes out, "myapp 0.1.0"
    assert_includes out, "local/vcs source (skipped)"
  end

  # --- networked end-to-end (opt-in) ----------------------------------------

  def test_e2e_verified_detection
    skip "set RMAKE_ACCEPTANCE=1 for the doctor end-to-end" unless ENV["RMAKE_ACCEPTANCE"] == "1"

    lock = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          json (2.21.1)

      DEPENDENCIES
        json

      BUNDLED WITH
         2.6.9
    LOCK
    Dir.mktmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write("#{gemfile}.lock", lock)
      out = StringIO.new
      # Real builder + real DB: json is verified, so no build/network happens.
      code = Doctor::CLI.run(["--gemfile", gemfile], out: out, err: StringIO.new)
      assert_equal 0, code
      assert_includes out.string, "verified"
      assert_includes out.string, "ADOPTABLE"
    end
  end

  def test_e2e_on_the_spot_build
    skip "set RMAKE_ACCEPTANCE=1 for the doctor end-to-end" unless ENV["RMAKE_ACCEPTANCE"] == "1"

    # racc has a small C extension (ext/racc/cparse). We pass an empty
    # test-only verified DB via --data so this test exercises the real fetch
    # -> extconf -> rmake -> require path regardless of whether racc happens
    # to be verified in the shipped data/verified_gems.json.
    lock = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          racc (1.8.1)

      DEPENDENCIES
        racc

      BUNDLED WITH
         2.6.9
    LOCK
    Dir.mktmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write("#{gemfile}.lock", lock)
      with_temp_verified_db({}) do |db_path|
        out = StringIO.new
        code = Doctor::CLI.run(["--gemfile", gemfile, "--timeout", "300", "--data", db_path],
                                out: out, err: StringIO.new)
        assert_equal 0, code, "racc should build on the spot:\n#{out.string}"
        assert_includes out.string, "built on the spot"
      end
    end
  end
end
