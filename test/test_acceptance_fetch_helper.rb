# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "fileutils"
require "tmpdir"
require "rbconfig"
require_relative "support/acceptance_fetch_helper"

class TestAcceptanceFetchHelper < Minitest::Test
  FakeStatus = Struct.new(:success?)

  def setup
    @saved_acceptance_environment = ENV.to_hash
    ENV.delete("CI_NETWORK")
    ENV.delete("CI_FIXTURE_ROOT")
  end

  def teardown
    ENV.replace(@saved_acceptance_environment)
  end

  def test_fetches_unpacks_and_returns_the_requested_extension
    Dir.mktmpdir do |dir|
      calls = []
      runner = lambda do |command, chdir:|
        calls << command
        if command[1] == "fetch"
          FileUtils.touch(File.join(chdir, "json-2.21.1.gem"))
        else
          ext = File.join(chdir, "json-2.21.1", "ext/json/ext/parser")
          FileUtils.mkdir_p(ext)
          File.write(File.join(ext, "parser.c"), "/* fixture */\n")
        end
        ["", FakeStatus.new(true)]
      end

      path = AcceptanceFetchHelper::Fetcher.new(work_dir: dir, runner: runner).fetch_gem(
        gem_name: "json", version: "2.21.1", extension_subdir: "ext/json/ext/parser",
        required_file: "parser.c"
      )

      assert_equal File.join(dir, "json-2.21.1/ext/json/ext/parser"), path
      assert_equal %w[fetch unpack], calls.map { |command| command[1] }
    end
  end

  def test_retries_transient_fetch_failures_but_not_not_found
    Dir.mktmpdir do |dir|
      attempts = 0
      delays = []
      runner = lambda do |command, chdir:|
        attempts += 1
        if attempts < 3
          [attempts == 1 ? "HTTP 503 Service Unavailable" : "HTTP 429 Too Many Requests",
           FakeStatus.new(false)]
        elsif command[1] == "fetch"
          FileUtils.touch(File.join(chdir, "gem-1.0.gem"))
          ["", FakeStatus.new(true)]
        else
          FileUtils.mkdir_p(File.join(chdir, "gem-1.0/ext"))
          File.write(File.join(chdir, "gem-1.0/ext/extconf.rb"), "# fixture\n")
          ["", FakeStatus.new(true)]
        end
      end

      AcceptanceFetchHelper::Fetcher.new(
        work_dir: dir, runner: runner, sleeper: ->(seconds) { delays << seconds }, retry_limit: 2
      ).fetch_gem(gem_name: "gem", version: "1.0", extension_subdir: "ext")

      assert_equal [1, 2], delays
      assert_equal 4, attempts, "the successful fetch must be followed by unpack"
    end

    Dir.mktmpdir do |dir|
      runner = ->(_command, chdir:) { ["HTTP 404 Not Found", FakeStatus.new(false)] }
      error = assert_raises(AcceptanceFetchHelper::Failure) do
        AcceptanceFetchHelper::Fetcher.new(
          work_dir: dir, runner: runner, sleeper: ->(_seconds) {}, retry_limit: 5
        ).fetch_gem(gem_name: "missing", version: "1.0", extension_subdir: "ext")
      end
      assert_equal :not_found, error.kind
      assert_equal 1, error.attempts
    end
  end

  def test_checksum_and_unpack_failures_are_typed
    Dir.mktmpdir do |dir|
      runner = ->(_command, chdir:) do
        FileUtils.touch(File.join(chdir, "gem-1.0.gem"))
        ["checksum mismatch", FakeStatus.new(false)]
      end
      error = assert_raises(AcceptanceFetchHelper::Failure) do
        AcceptanceFetchHelper::Fetcher.new(work_dir: dir, runner: runner).fetch_gem(
          gem_name: "gem", version: "1.0", extension_subdir: "ext"
        )
      end
      assert_equal :checksum, error.kind
    end

    Dir.mktmpdir do |dir|
      runner = lambda do |command, chdir:|
        if command[1] == "fetch"
          FileUtils.touch(File.join(chdir, "gem-1.0.gem"))
          ["", FakeStatus.new(true)]
        else
          ["archive is corrupt", FakeStatus.new(false)]
        end
      end
      error = assert_raises(AcceptanceFetchHelper::Failure) do
        AcceptanceFetchHelper::Fetcher.new(work_dir: dir, runner: runner).fetch_gem(
          gem_name: "gem", version: "1.0", extension_subdir: "ext"
        )
      end
      assert_equal :unpack, error.kind
    end
  end

  def test_expected_sha256_is_verified_before_unpack
    Dir.mktmpdir do |dir|
      unpack_called = false
      runner = lambda do |command, chdir:|
        if command[1] == "fetch"
          File.write(File.join(chdir, "gem-1.0.gem"), "pinned artifact")
          ["", FakeStatus.new(true)]
        else
          unpack_called = true
          FileUtils.mkdir_p(File.join(chdir, "gem-1.0/ext"))
          File.write(File.join(chdir, "gem-1.0/ext/extconf.rb"), "# fixture\n")
          ["", FakeStatus.new(true)]
        end
      end
      expected = Digest::SHA256.hexdigest("pinned artifact")

      path = AcceptanceFetchHelper::Fetcher.new(work_dir: dir, runner: runner).fetch_gem(
        gem_name: "gem", version: "1.0", extension_subdir: "ext", expected_sha256: expected
      )

      assert File.file?(File.join(path, "extconf.rb"))
      assert unpack_called
      assert_equal expected, AcceptanceFetchHelper.sha256(File.join(dir, "gem-1.0.gem"))
    end
  end

  def test_expected_sha256_mismatch_stops_before_unpack
    Dir.mktmpdir do |dir|
      calls = []
      runner = lambda do |command, chdir:|
        calls << command[1]
        File.write(File.join(chdir, "gem-1.0.gem"), "tampered artifact") if command[1] == "fetch"
        ["", FakeStatus.new(true)]
      end

      error = assert_raises(AcceptanceFetchHelper::Failure) do
        AcceptanceFetchHelper::Fetcher.new(work_dir: dir, runner: runner).fetch_gem(
          gem_name: "gem", version: "1.0", extension_subdir: "ext", expected_sha256: "0" * 64
        )
      end

      assert_equal :checksum, error.kind
      assert_equal ["fetch"], calls
      assert_includes error.output, "expected_sha256=#{'0' * 64}"
      refute File.exist?(File.join(dir, "gem-1.0", "ext"))
    end
  end

  def test_invalid_expected_sha256_is_rejected
    error = assert_raises(ArgumentError) do
      AcceptanceFetchHelper::Fetcher.new(work_dir: Dir.tmpdir).fetch_gem_file(
        gem_name: "gem", version: "1.0", expected_sha256: "not-a-digest"
      )
    end

    assert_includes error.message, "64 hexadecimal"
  end

  def test_pinned_fetch_writes_an_artifact_record_and_marks_cache_hits
    Dir.mktmpdir do |dir|
      report = File.join(dir, "artifacts.json")
      saved = ENV.to_hash
      ENV["CI_ARTIFACT_REPORT_PATH"] = report
      runner = lambda do |command, chdir:|
        if command[0] == "curl"
          output_path = command.fetch(command.index("-o") + 1)
          File.write(output_path, "pinned")
        end
        ["", FakeStatus.new(true)]
      end
      expected = Digest::SHA256.hexdigest("pinned")
      fetcher = AcceptanceFetchHelper::Fetcher.new(work_dir: dir, runner: runner)

      fetcher.fetch_gem_file(
        gem_name: "gem", version: "1.0", expected_sha256: expected,
        artifact_id: "gem-1.0-ruby", artifact_url: "https://example.invalid/gem-1.0.gem"
      )
      first = JSON.parse(File.read(report)).first
      refute first.fetch("cache_hit")
      assert_equal expected, first.fetch("actual_sha256")

      fetcher.fetch_gem_file(
        gem_name: "gem", version: "1.0", expected_sha256: expected,
        artifact_id: "gem-1.0-ruby", artifact_url: "https://example.invalid/gem-1.0.gem"
      )
      second = JSON.parse(File.read(report)).first
      assert second.fetch("cache_hit")
    ensure
      ENV.replace(saved) if saved
    end
  end

  def test_fixture_mode_copies_a_pinned_archive_without_invoking_the_runner
    Dir.mktmpdir do |root|
      fixture = File.join(root, "json-2.21.1.gem")
      File.write(fixture, "committed gem archive")
      expected = Digest::SHA256.file(fixture).hexdigest
      destination_root = Dir.mktmpdir
      saved = ENV.to_hash
      ENV["CI_NETWORK"] = "fixture"
      ENV["CI_FIXTURE_ROOT"] = root

      runner = lambda do |_command, **|
        flunk "fixture mode must not invoke a network-capable runner"
      end
      destination = AcceptanceFetchHelper::Fetcher.new(
        work_dir: destination_root, runner: runner
      ).fetch_url(
        url: "https://rubygems.org/downloads/json-2.21.1.gem",
        destination: "json-2.21.1.gem",
        expected_sha256: expected,
        fixture_path: "json-2.21.1.gem"
      )

      assert_equal File.read(fixture), File.read(destination)
    ensure
      ENV.replace(saved) if saved
      FileUtils.rm_rf(destination_root) if destination_root
    end
  end

  def test_fixture_mode_reports_a_missing_archive_without_network_fallback
    Dir.mktmpdir do |root|
      saved = ENV.to_hash
      ENV["CI_NETWORK"] = "fixture"
      ENV["CI_FIXTURE_ROOT"] = root

      runner = lambda do |_command, **|
        flunk "fixture mode must not fall back to a network command"
      end
      error = assert_raises(AcceptanceFetchHelper::Failure) do
        AcceptanceFetchHelper::Fetcher.new(work_dir: root, runner: runner).fetch_url(
          url: "https://rubygems.org/downloads/missing.gem",
          destination: "missing.gem",
          expected_sha256: "0" * 64,
          fixture_path: "missing.gem"
        )
      end

      assert_equal :environment, error.kind
      assert_includes error.message, "fixture archive is missing"
    ensure
      ENV.replace(saved) if saved
    end
  end

  def test_fetch_process_timeout_is_bounded_and_typed
    Dir.mktmpdir do |dir|
      runner = lambda do |_command, chdir:|
        sleep 0.05
        ["", FakeStatus.new(false)]
      end
      error = assert_raises(AcceptanceFetchHelper::Failure) do
        AcceptanceFetchHelper::Fetcher.new(
          work_dir: dir, runner: runner, retry_limit: 0, timeout_seconds: 0.01
        ).fetch_gem(gem_name: "slow", version: "1.0", extension_subdir: "ext")
      end
      assert_equal :timeout, error.kind
      assert_equal 1, error.attempts
    end
  end

  def test_capture2e_terminates_a_real_child_on_timeout
    Dir.mktmpdir do |dir|
      error = assert_raises(AcceptanceFetchHelper::Failure) do
        AcceptanceFetchHelper.capture2e(
          [RbConfig.ruby, "-e", "sleep 10"], chdir: dir, timeout_seconds: 0.01
        )
      end
      assert_equal :timeout, error.kind
      assert_includes error.message, "timed out"
    end
  end
end
