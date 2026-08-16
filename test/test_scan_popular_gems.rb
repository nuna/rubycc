# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

require_relative "../tools/scan_popular_gems"

class TestScanPopularGems < Minitest::Test
  SCRIPT = File.expand_path("../tools/scan_popular_gems.rb", __dir__)

  class FakeHttp
    attr_reader :urls

    def initialize(responses)
      @responses = responses
      @urls = []
    end

    def get(url)
      @urls << url
      @responses.fetch(url)
    end
  end

  class FakeArchiveHttp
    attr_reader :calls, :max_active

    def initialize(body, delay: 0)
      @body = body
      @delay = delay
      @calls = []
      @active = 0
      @max_active = 0
      @lock = Mutex.new
    end

    def get_bytes(url)
      @lock.synchronize do
        @calls << url
        @active += 1
        @max_active = [@max_active, @active].max
      end
      sleep @delay if @delay.positive?
      @body
    ensure
      @lock.synchronize { @active -= 1 }
    end
  end

  FakeResponse = Struct.new(:code, :message, :body, :headers) do
    def [](key)
      headers[key.downcase]
    end
  end

  def test_require_has_no_network_argv_or_exit_side_effect
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path("..", __dir__)}", "-e", "require #{SCRIPT.inspect}"
    )

    assert status.success?, stderr
    assert_empty stdout
    assert_empty stderr
  end

  def test_legacy_configuration_is_parsed_only_when_requested
    config = CorpusCandidateScan::Configuration.from_env(
      ["12", "20"],
      "SCAN_WORK" => "tmp/scan", "SCAN_SOURCE" => "bestgems", "SCAN_VERBOSE" => "1"
    )

    assert_equal 12, config.first_page
    assert_equal 20, config.last_page
    assert_equal File.expand_path("tmp/scan"), config.work_dir
    assert_equal "bestgems", config.source_choice
    assert config.verbose

    summary_config = CorpusCandidateScan::Configuration.from_env(
      ["--summary", "tmp/summary.json"], "SCAN_WORK" => "tmp/scan"
    )
    assert_equal File.expand_path("tmp/summary.json"), summary_config.summary_path

    concurrency_config = CorpusCandidateScan::Configuration.from_env(
      [], "SCAN_FETCH_CONCURRENCY" => "4"
    )
    assert_equal 4, concurrency_config.fetch_concurrency

    error = assert_raises(ArgumentError) do
      CorpusCandidateScan::Configuration.new(fetch_concurrency: 5)
    end
    assert_includes error.message, "between 1 and 4"
  end

  def test_configuration_rejects_invalid_legacy_arguments
    error = assert_raises(ArgumentError) do
      CorpusCandidateScan::Configuration.from_env(["0", "2"])
    end
    assert_includes error.message, "first_page must be >= 1"

    error = assert_raises(ArgumentError) do
      CorpusCandidateScan::Configuration.from_env(["1", "2", "3"])
    end
    assert_includes error.message, "at most first_page and last_page"
  end

  def test_timeframe_configuration_requires_a_bounded_iso8601_window
    config = CorpusCandidateScan::Configuration.from_env(
      ["--source", "timeframe", "--from", "2026-08-01T00:00:00Z", "--to", "2026-08-02T00:00:00Z"],
      {}
    )

    assert config.timeframe?
    assert_equal Time.utc(2026, 8, 1), config.from_time
    assert_equal Time.utc(2026, 8, 2), config.to_time

    error = assert_raises(ArgumentError) do
      CorpusCandidateScan::Configuration.from_env(
        ["--source", "timeframe", "--from", "2026-08-01", "--to", "2026-08-09"], {}
      )
    end
    assert_includes error.message, "cannot exceed 7 days"
  end

  def test_artifact_records_provenance_and_replays_raw_response_deterministically
    Dir.mktmpdir do |work_dir|
      from = Time.utc(2026, 8, 1)
      to = Time.utc(2026, 8, 2)
      url = CorpusCandidateScan::TimeframeVersions.url(from, to, 1)
      body = '[{"name":"example-gem","version":"1.0.0"}]'
      cache = CorpusCandidateScan::ResponseCache.new(File.join(work_dir, "raw_responses"))
      first_client = CorpusCandidateScan::RecordingHttpClient.new(FakeHttp.new(url => body), cache: cache)

      assert_equal body, first_client.get(url)
      record = {
        rank: nil, name: "example-gem", version: "1.0.0", platform: "ruby",
        created_at: "2026-08-01T12:00:00Z", downloads: 100, version_downloads: 10,
        selection_note: "selected 1.0.0", selection_rejections: [],
        gem_sha256: "a" * 64, api_sha256: "a" * 64, sha256_match: "match",
        extensions: ["ext/example/extconf.rb"], extension_directories: ["ext/example"],
        native_source_files: [], extconf_files: [],
        status: :candidate, reason: nil, review_reasons: [], c_files: 1, h_files: 0,
        in_corpus: false, includes: { "stdio.h" => :bundled, "cpuid.h" => :gap },
        ruby_self: ["ruby.h"]
      }
      config = CorpusCandidateScan::Configuration.new(
        source_choice: "timeframe", from_time: from, to_time: to,
        work_dir: work_dir, artifact_path: File.join(work_dir, "artifact.json")
      )
      CorpusCandidateScan::Artifact.write(
        config.artifact_path, config: config, source: CorpusCandidateScan::TimeframeVersions,
        requests: first_client.requests, results: [record]
      )
      first = File.binread(config.artifact_path)

      unavailable = Object.new
      def unavailable.get(_url)
        raise "network should not be called during raw-response replay"
      end
      replay_client = CorpusCandidateScan::RecordingHttpClient.new(unavailable, cache: cache)
      assert_equal body, replay_client.get(url)
      CorpusCandidateScan::Artifact.write(
        config.artifact_path, config: config, source: CorpusCandidateScan::TimeframeVersions,
        requests: replay_client.requests, results: [record]
      )

      assert_equal first, File.binread(config.artifact_path)
      golden = File.read(File.expand_path("fixtures/corpus_candidate_artifact.json", __dir__))
      assert_equal golden, first
      artifact = JSON.parse(first)
      assert_equal 1, artifact.fetch("schema_version")
      assert_equal({ "from" => "2026-08-01T00:00:00Z", "source" => "timeframe",
                     "to" => "2026-08-02T00:00:00Z", "verbose" => false }, artifact.fetch("input"))
      assert_equal url, artifact.fetch("source_requests").fetch(0).fetch("url")
      assert_equal 64, artifact.fetch("source_requests").fetch(0).fetch("response_sha256").length
      assert_equal "cpuid.h", artifact.fetch("records").fetch(0).fetch("headers").fetch("gap").fetch(0)
    end
  end

  def test_artifact_schema_names_all_scan_sources_consistently
    config = CorpusCandidateScan::Configuration.new(first_page: 1, last_page: 1, work_dir: Dir.tmpdir)

    assert_equal "rubygems", CorpusCandidateScan::Artifact.source_name(
      config, CorpusCandidateScan::RubygemsPopular
    )
    assert_equal "bestgems", CorpusCandidateScan::Artifact.source_name(
      config, CorpusCandidateScan::BestgemsTotal
    )

    timeframe = CorpusCandidateScan::Configuration.new(
      source_choice: "timeframe", from_time: "2026-08-01", to_time: "2026-08-02", work_dir: Dir.tmpdir
    )
    assert_equal "timeframe", CorpusCandidateScan::Artifact.source_name(
      timeframe, CorpusCandidateScan::TimeframeVersions
    )
  end

  def test_recording_client_keeps_failed_requests_in_runtime_provenance
    url = "https://rubygems.org/api/v2/rubygems/missing/versions/1.0.0.json?platform=ruby"
    unavailable = Object.new
    def unavailable.get(_url)
      raise "synthetic 404"
    end
    client = CorpusCandidateScan::RecordingHttpClient.new(unavailable)

    assert_raises(RuntimeError) { client.get(url) }

    record = client.requests.fetch(0)
    assert_equal url, record.fetch(:url)
    assert_nil record.fetch(:response_sha256)
    assert_includes record.fetch(:error), "synthetic 404"
  end

  def test_timeframe_source_paginates_to_an_empty_page_and_selects_source_release
    config = CorpusCandidateScan::Configuration.from_env(
      ["--source", "timeframe", "--from", "2026-08-01T00:00:00Z", "--to", "2026-08-02T00:00:00Z"], {}
    )
    record = {
      "name" => "example-gem", "version" => "1.0.0", "platform" => "x86_64-linux",
      "created_at" => "2026-08-01T12:00:00Z", "prerelease" => false, "sha" => "feed",
      "downloads" => 100, "version_downloads" => 10
    }
    v2 = record.merge("platform" => "ruby", "yanked" => false,
                      "gem_uri" => "https://rubygems.org/gems/example-gem-1.0.0.gem")
    responses = {
      CorpusCandidateScan::TimeframeVersions.url(config.from_time, config.to_time, 1) => JSON.generate([record]),
      CorpusCandidateScan::TimeframeVersions.url(config.from_time, config.to_time, 2) => JSON.generate([]),
      "https://rubygems.org/api/v2/rubygems/example-gem/versions/1.0.0.json?platform=ruby" => JSON.generate(v2)
    }
    http = FakeHttp.new(responses)
    scanner = CorpusCandidateScan::Scanner.new(config: config, http_client: http,
                                               sleeper: ->(_seconds) {})

    selected, rejected = scanner.send(:collect_timeframe)

    assert_empty rejected
    assert_equal [{
      source: :timeframe, name: "example-gem", version: "1.0.0", platform: "ruby",
      created_at: "2026-08-01T12:00:00Z", downloads: 100, version_downloads: 10,
      sha: "feed", api_sha: "feed", gem_uri: "https://rubygems.org/gems/example-gem-1.0.0.gem",
      selection_note: "timeframe releases considered: 1.0.0; selected 1.0.0",
      selection_rejections: []
    }], selected
    assert_equal 3, http.urls.size
  end

  def test_selection_only_records_release_selection_without_fetching_a_gem
    Dir.mktmpdir do |work_dir|
      config = CorpusCandidateScan::Configuration.from_env(
        ["--source", "timeframe", "--from", "2026-08-01", "--to", "2026-08-02", "--selection-only"],
        "SCAN_WORK" => work_dir
      )
      record = {
        "name" => "example-gem", "version" => "1.0.0", "platform" => "ruby",
        "created_at" => "2026-08-01T12:00:00Z", "prerelease" => false, "sha" => "feed",
        "downloads" => 100, "version_downloads" => 10
      }
      responses = {
        CorpusCandidateScan::TimeframeVersions.url(config.from_time, config.to_time, 1) => JSON.generate([record]),
        CorpusCandidateScan::TimeframeVersions.url(config.from_time, config.to_time, 2) => JSON.generate([]),
        "https://rubygems.org/api/v2/rubygems/example-gem/versions/1.0.0.json?platform=ruby" => JSON.generate(record.merge("yanked" => false))
      }
      output = StringIO.new
      scanner = CorpusCandidateScan::Scanner.new(config: config, http_client: FakeHttp.new(responses),
                                                 sleeper: ->(_seconds) {}, out: output)

      assert scanner.run
      assert_includes output.string, "selection-only"
      refute Dir.glob(File.join(config.work_dir, "*.gem")).any?
    end
  end

  def test_run_summary_records_runtime_phases_without_absolute_paths
    Dir.mktmpdir do |work_dir|
      summary_path = File.join(work_dir, "summary.json")
      config = CorpusCandidateScan::Configuration.from_env(
        ["--source", "timeframe", "--from", "2026-08-01", "--to", "2026-08-02", "--selection-only"],
        "SCAN_WORK" => work_dir, "SCAN_SUMMARY" => summary_path
      )
      record = {
        "name" => "example-gem", "version" => "1.0.0", "platform" => "ruby",
        "created_at" => "2026-08-01T12:00:00Z", "prerelease" => false, "sha" => "feed",
        "downloads" => 100, "version_downloads" => 10
      }
      responses = {
        CorpusCandidateScan::TimeframeVersions.url(config.from_time, config.to_time, 1) => JSON.generate([record]),
        CorpusCandidateScan::TimeframeVersions.url(config.from_time, config.to_time, 2) => JSON.generate([])
      }
      output = StringIO.new
      scanner = CorpusCandidateScan::Scanner.new(config: config, http_client: FakeHttp.new(responses),
                                                 sleeper: ->(_seconds) {}, out: output)

      assert scanner.run

      summary = JSON.parse(File.read(summary_path))
      assert_equal 1, summary.fetch("schema_version")
      assert_equal "timeframe", summary.fetch("source")
      assert_equal 2, summary.fetch("requests").fetch("attempts")
      assert_equal 2, summary.fetch("requests").fetch("unique_urls")
      assert_operator summary.fetch("requests").fetch("bytes"), :>, 0
      assert_equal 0, summary.fetch("archives").fetch("inspections")
      assert_equal 0, summary.fetch("archives").fetch("fetch_attempts")
      assert_equal 2, summary.fetch("source_stats").fetch("pages")
      assert_equal 1, summary.fetch("source_stats").fetch("release_entries")
      assert_equal 1, summary.fetch("source_stats").fetch("unique_gems")
      assert_operator summary.fetch("execution").fetch("peak_work_bytes"), :>=, 0
      assert_equal CorpusCandidateScan::SUMMARY_PHASES.to_h { |phase| [phase, 0.0] }.keys.sort,
                   summary.fetch("phases_seconds").keys.sort
      assert_equal ["uninspected"], summary.fetch("results").keys
      refute_includes File.read(summary_path), work_dir
    end
  end

  def test_timeframe_source_rejects_repeated_nonempty_pages
    config = CorpusCandidateScan::Configuration.from_env(
      ["--source", "timeframe", "--from", "2026-08-01", "--to", "2026-08-02"], {}
    )
    record = {
      "name" => "example-gem", "version" => "1.0.0", "platform" => "ruby",
      "created_at" => "2026-08-01T12:00:00Z", "prerelease" => false, "sha" => "feed",
      "downloads" => 100, "version_downloads" => 10
    }
    body = JSON.generate([record])
    responses = {
      CorpusCandidateScan::TimeframeVersions.url(config.from_time, config.to_time, 1) => body,
      CorpusCandidateScan::TimeframeVersions.url(config.from_time, config.to_time, 2) => body
    }
    scanner = CorpusCandidateScan::Scanner.new(config: config, http_client: FakeHttp.new(responses),
                                               sleeper: ->(_seconds) {})

    error = assert_raises(RuntimeError) do
      scanner.send(:collect_timeframe)
    end
    assert_includes error.message, "repeats a previous page"
  end

  def test_timeframe_response_requires_the_documented_release_fields
    from = Time.utc(2026, 8, 1)
    to = Time.utc(2026, 8, 2)
    url = CorpusCandidateScan::TimeframeVersions.url(from, to, 1)
    incomplete = { "name" => "example-gem", "version" => "1.0.0" }

    error = assert_raises(RuntimeError) do
      CorpusCandidateScan::TimeframeVersions.fetch_page(FakeHttp.new(url => JSON.generate([incomplete])),
                                                         from, to, 1)
    end
    assert_includes error.message, "missing platform"
  end

  def test_v2_metadata_requires_a_fixed_https_gem_uri
    config = CorpusCandidateScan::Configuration.from_env(
      ["--source", "timeframe", "--from", "2026-08-01", "--to", "2026-08-02"], {}
    )
    url = "https://rubygems.org/api/v2/rubygems/example-gem/versions/1.0.0.json?platform=ruby"
    response = {
      "name" => "example-gem", "version" => "1.0.0", "platform" => "ruby",
      "yanked" => false, "sha" => "a" * 64
    }
    scanner = CorpusCandidateScan::Scanner.new(
      config: config, http_client: FakeHttp.new(url => JSON.generate(response)),
      sleeper: ->(_seconds) {}
    )

    details = scanner.send(:timeframe_version_details, "example-gem", "1.0.0")

    assert_includes details.fetch(:error), "missing gem_uri"
  end

  def test_timeframe_selection_skips_prerelease_and_yanked_release
    config = CorpusCandidateScan::Configuration.from_env(
      ["--source", "timeframe", "--from", "2026-08-01", "--to", "2026-08-02"], {}
    )
    records = [
      ["2.0.0", "2026-08-01T14:00:00Z", true],
      ["1.0.0", "2026-08-01T13:00:00Z", false],
      ["0.9.0", "2026-08-01T12:00:00Z", false]
    ].map do |version, created_at, prerelease|
      {
        "name" => "example-gem", "version" => version, "platform" => "ruby",
        "created_at" => created_at, "prerelease" => prerelease, "sha" => version,
        "downloads" => 100, "version_downloads" => 10
      }
    end
    responses = {
      CorpusCandidateScan::TimeframeVersions.url(config.from_time, config.to_time, 1) => JSON.generate(records),
      CorpusCandidateScan::TimeframeVersions.url(config.from_time, config.to_time, 2) => JSON.generate([])
    }
    records.each do |record|
      responses["https://rubygems.org/api/v2/rubygems/example-gem/versions/#{record["version"]}.json?platform=ruby"] = JSON.generate(
        record.merge(
          "yanked" => record["version"] == "1.0.0",
          "gem_uri" => "https://rubygems.org/gems/example-gem-#{record["version"]}.gem"
        )
      )
    end
    scanner = CorpusCandidateScan::Scanner.new(config: config, http_client: FakeHttp.new(responses),
                                               sleeper: ->(_seconds) {})

    selected, rejected = scanner.send(:collect_timeframe)

    assert_empty rejected
    assert_equal "0.9.0", selected.fetch(0).fetch(:version)
    assert_includes selected.fetch(0).fetch(:selection_note), "2.0.0: prerelease"
    assert_includes selected.fetch(0).fetch(:selection_note), "1.0.0: yanked"
  end

  def test_fetched_spec_must_match_the_requested_version_and_platform
    spec = Gem::Specification.new do |gem|
      gem.name = "example-gem"
      gem.version = "1.0.0"
      gem.platform = "ruby"
    end

    assert_nil CorpusCandidateScan::InspectionHelpers.validate_fetched_spec(spec, "1.0.0", "ruby")
    error = assert_raises(ArgumentError) do
      CorpusCandidateScan::InspectionHelpers.validate_fetched_spec(spec, "2.0.0", "ruby")
    end
    assert_includes error.message, "does not match requested 2.0.0"
  end

  def test_gem_sha_mismatch_is_a_hard_error
    assert_equal "not_provided", CorpusCandidateScan::InspectionHelpers.validate_gem_sha!("a" * 64, nil)
    assert_equal "match", CorpusCandidateScan::InspectionHelpers.validate_gem_sha!("a" * 64, "A" * 64)

    error = assert_raises(ArgumentError) do
      CorpusCandidateScan::InspectionHelpers.validate_gem_sha!("a" * 64, "b" * 64)
    end
    assert_includes error.message, "gem_sha256_mismatch"
  end

  def test_direct_archive_fetch_verifies_sha_and_reuses_only_a_completed_cache
    Dir.mktmpdir do |work_dir|
      body = "hermetic gem bytes"
      url = "https://rubygems.org/gems/example-gem-1.0.0.gem"
      http = FakeArchiveHttp.new(body)
      fetcher = CorpusCandidateScan::ArchiveFetcher.new(http_client: http, work_dir: work_dir)
      expected_sha = Digest::SHA256.hexdigest(body)

      first = fetcher.fetch(
        name: "example-gem", version: "1.0.0", platform: "ruby", gem_uri: url,
        expected_sha256: expected_sha
      )
      second = fetcher.fetch(
        name: "example-gem", version: "1.0.0", platform: "ruby", gem_uri: url,
        expected_sha256: expected_sha
      )

      assert File.file?(first.fetch(:path))
      assert_equal first.fetch(:path), second.fetch(:path)
      assert second.fetch(:cache_hit)
      assert_equal [url], http.calls
      assert_empty Dir.glob(File.join(work_dir, "*.part"))
      assert_equal 2, fetcher.stats.fetch(:attempts)
      assert_equal 1, fetcher.stats.fetch(:cache_hits)
    end
  end

  def test_direct_archive_sha_mismatch_removes_partial_and_keeps_no_completed_archive
    Dir.mktmpdir do |work_dir|
      url = "https://rubygems.org/gems/example-gem-1.0.0.gem"
      fetcher = CorpusCandidateScan::ArchiveFetcher.new(
        http_client: FakeArchiveHttp.new("partial body"), work_dir: work_dir
      )

      result = fetcher.fetch(
        name: "example-gem", version: "1.0.0", platform: "ruby", gem_uri: url,
        expected_sha256: "0" * 64
      )

      assert_nil result.fetch(:path)
      assert_includes result.fetch(:error), "gem_sha256_mismatch"
      assert_empty Dir.glob(File.join(work_dir, "*.gem"))
      assert_empty Dir.glob(File.join(work_dir, "*.part"))

      resumed = CorpusCandidateScan::ArchiveFetcher.new(
        http_client: FakeArchiveHttp.new("partial body"), work_dir: work_dir
      ).fetch(
        name: "example-gem", version: "1.0.0", platform: "ruby", gem_uri: url,
        expected_sha256: Digest::SHA256.hexdigest("partial body")
      )
      assert File.file?(resumed.fetch(:path))
    end
  end

  def test_http_client_retries_rate_limit_and_timeout_hermetically
    sleeps = []
    retries = 0
    responses = [
      FakeResponse.new("429", "Too Many Requests", "busy", { "retry-after" => "0" }),
      FakeResponse.new("200", "OK", "archive", {})
    ]
    client = CorpusCandidateScan::HttpClient.new(
      requester: ->(_uri) { responses.shift }, sleeper: ->(seconds) { sleeps << seconds },
      on_retry: -> { retries += 1 }
    )

    assert_equal "archive", client.get_bytes("https://rubygems.org/gems/example.gem")
    assert_equal 1, retries
    assert_equal [0.0], sleeps

    timeout_sleeps = []
    calls = 0
    timeout_client = CorpusCandidateScan::HttpClient.new(
      max_retries: 2, requester: ->(_uri) { calls += 1; raise Net::ReadTimeout, "timed out" },
      sleeper: ->(seconds) { timeout_sleeps << seconds }
    )
    assert_raises(Net::ReadTimeout) { timeout_client.get_bytes("https://rubygems.org/gems/example.gem") }
    assert_equal 3, calls
    assert_equal [1.0, 2.0], timeout_sleeps
  end

  def test_timeframe_archive_workers_respect_configured_bound
    Dir.mktmpdir do |work_dir|
      body = "same archive body"
      http = FakeArchiveHttp.new(body, delay: 0.01)
      config = CorpusCandidateScan::Configuration.new(
        source_choice: "timeframe", from_time: "2026-08-01", to_time: "2026-08-02",
        work_dir: work_dir, fetch_concurrency: 2
      )
      scanner = CorpusCandidateScan::Scanner.new(
        config: config, http_client: FakeHttp.new({}), archive_http_client: http,
        sleeper: ->(_seconds) {}
      )
      sha = Digest::SHA256.hexdigest(body)
      entries = 4.times.map do |index|
        {
          name: "example-gem-#{index}", version: "1.0.0", platform: "ruby",
          gem_uri: "https://rubygems.org/gems/example-gem-#{index}-1.0.0.gem", api_sha: sha
        }
      end

      results = scanner.send(:fetch_timeframe_archives, entries)

      assert_equal 4, results.count { |path, error| path && error.nil? }
      assert_operator http.max_active, :<=, 2
      assert_equal 4, http.calls.length
    end
  end

  def test_direct_and_legacy_fetch_paths_classify_the_same_gem_fixture
    Dir.mktmpdir do |root|
      fixture_dir = File.join(root, "fixture")
      direct_dir = File.join(root, "direct")
      fallback_dir = File.join(root, "fallback")
      FileUtils.mkdir_p(fixture_dir)
      gem_path = build_fixture_gem(fixture_dir)
      body = File.binread(gem_path)
      sha = Digest::SHA256.hexdigest(body)
      gem_uri = "https://rubygems.org/gems/example-gem-1.0.0.gem"
      entry = {
        rank: nil, name: "example-gem", version: "1.0.0", platform: "ruby",
        created_at: "2026-08-01T12:00:00Z", downloads: 1, version_downloads: 1,
        selection_note: nil, selection_rejections: [], api_sha: sha, gem_uri: gem_uri
      }
      direct_config = CorpusCandidateScan::Configuration.new(
        source_choice: "timeframe", from_time: "2026-08-01", to_time: "2026-08-02",
        work_dir: direct_dir
      )
      direct_fetch = CorpusCandidateScan::ArchiveFetcher.new(
        http_client: FakeArchiveHttp.new(body), work_dir: direct_dir
      ).fetch(
        name: entry[:name], version: entry[:version], platform: entry[:platform],
        gem_uri: gem_uri, expected_sha256: sha
      )
      direct_scanner = CorpusCandidateScan::Scanner.new(
        config: direct_config, http_client: FakeHttp.new({}), sleeper: ->(_seconds) {}
      )
      direct = direct_scanner.send(:inspect_gem, entry, archive: [direct_fetch.fetch(:path), nil])

      FileUtils.mkdir_p(fallback_dir)
      FileUtils.cp(gem_path, File.join(fallback_dir, "example-gem-1.0.0.gem"))
      fallback_config = CorpusCandidateScan::Configuration.new(
        first_page: 1, last_page: 1, work_dir: fallback_dir
      )
      fallback_scanner = CorpusCandidateScan::Scanner.new(
        config: fallback_config, http_client: FakeHttp.new({}), sleeper: ->(_seconds) {}
      )
      fallback_entry = entry.reject { |key, _| key == :gem_uri || key == :api_sha }
      fallback = fallback_scanner.send(:inspect_gem, fallback_entry)

      classification = lambda do |result|
        result.values_at(:name, :version, :platform, :status, :reason, :extensions,
                         :extension_directories, :native_source_files, :extconf_files,
                         :review_reasons, :c_files, :h_files, :includes, :ruby_self)
      end
      assert_equal classification.call(fallback), classification.call(direct)
    end
  end

  def test_rubygems_page_parser_uses_injected_http_client
    url = CorpusCandidateScan::RubygemsPopular.url(1)
    html = <<~HTML
      <p data-testid="entries-info">Displaying rubygems <b>1&nbsp;-&nbsp;1</b> of <b>1</b> in total</p>
      <a href="/gems/example-gem">example-gem</a>
    HTML
    http = FakeHttp.new(url => html)

    result = CorpusCandidateScan::RubygemsPopular.fetch_page(http, 1)

    assert_equal [{ rank: 1, name: "example-gem" }], result[:entries]
    assert_equal [url], http.urls
  end

  def test_ranking_collection_can_skip_sleep_and_network_is_injected
    url = CorpusCandidateScan::RubygemsPopular.url(1)
    html = <<~HTML
      <p data-testid="entries-info">Displaying rubygems <b>1&nbsp;-&nbsp;1</b> of <b>1</b> in total</p>
      <a href="/gems/example-gem">example-gem</a>
    HTML
    http = FakeHttp.new(url => html)
    config = CorpusCandidateScan::Configuration.new(first_page: 1, last_page: 1,
                                                     work_dir: Dir.tmpdir)
    scanner = CorpusCandidateScan::Scanner.new(config: config, http_client: http,
                                               sleeper: ->(_seconds) {})

    result = scanner.send(:collect_ranking, CorpusCandidateScan::RubygemsPopular, 1, 1)

    assert_equal [{ rank: 1, name: "example-gem" }], result
  end

  def test_native_archive_and_extension_outside_diagnostics_are_explicit
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "ext", "example"))
      File.write(File.join(root, "lib", "native.c"), "")
      File.write(File.join(root, "lib", "extconf.rb"), "")

      native = CorpusCandidateScan::InspectionHelpers.archive_native_sources(root)

      assert_equal ["lib/native.c"], native[:source_files]
      assert_equal ["lib/extconf.rb"], native[:extconf_files]
      assert_equal ["lib/native"], CorpusCandidateScan::InspectionHelpers.non_ext_extension_dirs(["lib/native/extconf.rb"])
    end
  end

  def test_review_report_has_a_separate_bucket_from_assembly_review
    config = CorpusCandidateScan::Configuration.new(first_page: 1, last_page: 1, work_dir: Dir.tmpdir)
    output = StringIO.new
    scanner = CorpusCandidateScan::Scanner.new(config: config, out: output, sleeper: ->(_seconds) {})
    common = {
      rank: 1, name: "review-gem", version: "1.0.0", platform: "ruby", downloads: 1,
      extensions: ["lib/native/extconf.rb"], c_files: 1, h_files: 0, notes: [],
      in_corpus: false, includes: {}, ruby_self: [], review_reasons: []
    }
    review = common.merge(status: :review, reason: "extension_outside_census_root: lib/native")
    assembly = common.merge(name: "assembly-gem", status: :needs_review,
                            reason: "1 assembly source bundled (ext/asm.S)")

    scanner.send(:report, [review, assembly], CorpusCandidateScan::RubygemsPopular, 1, 2)

    assert_includes output.string, "[R] review required"
    assert_includes output.string, "[1b] C extension"
    assert_includes output.string, "review-gem"
    assert_includes output.string, "assembly-gem"
  end

  private

  def build_fixture_gem(directory)
    FileUtils.mkdir_p(File.join(directory, "ext", "example"))
    FileUtils.mkdir_p(File.join(directory, "lib"))
    File.write(File.join(directory, "ext", "example", "extconf.rb"),
               "require 'mkmf'\ncreate_makefile('example')\n")
    File.write(File.join(directory, "ext", "example", "example.c"),
               "#include <stdio.h>\nvoid example(void) {}\n")
    File.write(File.join(directory, "lib", "example.rb"), "module Example; end\n")
    specification = Gem::Specification.new do |gem|
      gem.name = "example-gem"
      gem.version = "1.0.0"
      gem.summary = "hermetic scanner fixture"
      gem.authors = ["rubycc"]
      gem.email = ["rubycc@example.invalid"]
      gem.licenses = ["MIT"]
      gem.homepage = "https://example.invalid/rubycc-fixture"
      gem.required_ruby_version = ">= 3.0"
      gem.files = ["ext/example/extconf.rb", "ext/example/example.c", "lib/example.rb"]
      gem.extensions = ["ext/example/extconf.rb"]
      gem.require_paths = ["lib"]
    end
    Dir.chdir(directory) { File.expand_path(Gem::Package.build(specification)) }
  end
end
