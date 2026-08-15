# frozen_string_literal: true

require "minitest/autorun"
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
