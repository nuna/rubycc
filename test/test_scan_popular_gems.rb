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

  def test_timeframe_source_paginates_to_an_empty_page_and_selects_source_release
    config = CorpusCandidateScan::Configuration.from_env(
      ["--source", "timeframe", "--from", "2026-08-01T00:00:00Z", "--to", "2026-08-02T00:00:00Z"], {}
    )
    record = {
      "name" => "example-gem", "version" => "1.0.0", "platform" => "x86_64-linux",
      "created_at" => "2026-08-01T12:00:00Z", "prerelease" => false, "sha" => "feed",
      "downloads" => 100, "version_downloads" => 10
    }
    v2 = record.merge("platform" => "ruby", "yanked" => false)
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
      sha: "feed", selection_note: "timeframe releases considered: 1.0.0; selected 1.0.0"
    }], selected
    assert_equal 3, http.urls.size
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
        record.merge("yanked" => record["version"] == "1.0.0")
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
end
