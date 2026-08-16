#!/usr/bin/env ruby
# frozen_string_literal: true

# Mechanically find C-extension gems among the most popular gems on rubygems.org.
#
# The downloaded .gem is the source of truth for the gemspec's `extensions`.
# `gem specification --remote` cannot be used because the quick index serves
# empty `extensions` and `files` values. The R10 gate itself remains owned by
# test/corpus/census.rb; this tool only orchestrates it and adds the rubycc-
# specific assembler check.
#
# Usage:
#   tools/scan_popular_gems.rb [first_page] [last_page]
#   SCAN_WORK=/path/to/work tools/scan_popular_gems.rb
#   SCAN_SOURCE=auto|rubygems|bestgems|timeframe tools/scan_popular_gems.rb
#   SCAN_ARTIFACT=/path/to/scan.json tools/scan_popular_gems.rb
#   SCAN_SUMMARY=/path/to/run-summary.json tools/scan_popular_gems.rb
#   SCAN_VERBOSE=1 tools/scan_popular_gems.rb

require "fileutils"
require "digest"
require "json"
require "net/http"
require "optparse"
require "rubygems/package"
require "time"
require "tmpdir"
require "thread"
require "uri"

RUBYCC_ROOT = File.expand_path("..", __dir__)
require File.join(RUBYCC_ROOT, "test/corpus/census")

module CorpusCandidateScan
  RANKS_PER_PAGE = 10
  USER_AGENT = "rubycc-scan-popular-gems (https://github.com/nuna/rubycc)"
  PAGE_DELAY = 1.0
  API_DELAY = 0.2
  RUBYGEMS_POPULAR_CAP = 100
  DEFAULT_WORK_DIR = File.join(Dir.tmpdir, "rubycc_scan_popular")
  SUMMARY_PHASES = %w[
    timeframe_pagination
    release_selection
    v2_metadata
    ranking
    archive_fetch
    unpack_static
    artifact_write
  ].freeze
  SUMMARY_ARCHIVE_COUNTERS = %i[
    inspections fetch_attempts cache_hits successes failures retries bytes unique_urls
  ].freeze
  DEFAULT_FETCH_CONCURRENCY = 2
  MAX_FETCH_CONCURRENCY = 4

  # Source failures are kept out of the normal candidate/error buckets.  A
  # source failure means that the scanner could not establish a trustworthy
  # release or archive identity; it is never evidence that the gem has no
  # extension and never an eligible candidate.
  module SourceErrorClassification
    STATUSES = %w[
      stale_release
      v2_metadata_404
      rate_limited
      network_failure
      archive_sha_mismatch
    ].freeze

    PRIORITY = {
      "archive_sha_mismatch" => 5,
      "rate_limited" => 4,
      "network_failure" => 3,
      "v2_metadata_404" => 2,
      "stale_release" => 1
    }.freeze

    module_function

    def from_message(message, stage:)
      text = message.to_s
      kind, http_status = if stage.to_sym == :archive && text.match?(/gem_sha256_mismatch/)
                            ["archive_sha_mismatch", nil]
                          elsif stage.to_sym == :v2_metadata &&
                                text.match?(/(?:failed:|failed after .*:)\s*404\b|\b404\s+Not Found/i)
                            ["v2_metadata_404", 404]
                          elsif stage.to_sym == :archive && text.match?(/\b404\s+Not Found/i)
                            ["network_failure", 404]
                          elsif text.match?(/\b429\b|Too Many Requests/i)
                            ["rate_limited", 429]
                          elsif text.match?(/\b5\d\d\b|Net::|SocketError|timed? ?out|timeout|connection/i)
                            ["network_failure", text[/\b5\d\d\b/]&.to_i]
                          end
      return unless kind

      build(kind, stage, text, http_status: http_status)
    end

    def stale_release(reasons)
      return unless Array(reasons).any? do |reason|
        reason.match?(/source platform unavailable|yanked|v2 name\/version mismatch/)
      end

      build("stale_release", :release_selection, Array(reasons).join("; "))
    end

    def choose(errors, reasons)
      candidates = Array(errors).compact
      candidates << stale_release(reasons)
      candidates.compact.max_by { |error| PRIORITY.fetch(error.fetch("kind"), 0) }
    end

    def status?(status)
      STATUSES.include?(status.to_s)
    end

    def build(kind, stage, reason, http_status: nil)
      {
        "kind" => kind,
        "stage" => stage.to_s,
        "http_status" => http_status,
        "reason" => reason
      }.compact
    end
  end

  # The legacy rank mode is deliberately represented as data rather than read
  # from ARGV at load time. This is the boundary that makes the scanner
  # require-able from hermetic tests and from the future timeframe source.
  class Configuration
    attr_reader :first_page, :last_page, :work_dir, :source_choice, :verbose,
                :from_time, :to_time, :artifact_path, :summary_path, :selection_only,
                :fetch_concurrency

    def initialize(first_page: 11, last_page: 20, work_dir: DEFAULT_WORK_DIR,
                   source_choice: "auto", verbose: false, from_time: nil, to_time: nil,
                   artifact_path: nil, summary_path: nil, selection_only: false,
                   fetch_concurrency: DEFAULT_FETCH_CONCURRENCY)
      @first_page = Integer(first_page)
      @last_page = Integer(last_page)
      @work_dir = File.expand_path(work_dir)
      @source_choice = source_choice.to_s.downcase
      @verbose = verbose
      @from_time = from_time && parse_time(from_time, "from")
      @to_time = to_time && parse_time(to_time, "to")
      @artifact_path = artifact_path && File.expand_path(artifact_path)
      @summary_path = summary_path && File.expand_path(summary_path)
      @selection_only = !!selection_only
      @fetch_concurrency = Integer(fetch_concurrency)
      validate!
    end

    def self.from_env(argv = ARGV, env = ENV)
      args = Array(argv)
      options = {
        source_choice: env.fetch("SCAN_SOURCE", "auto"),
        from_time: env["SCAN_FROM"],
        to_time: env["SCAN_TO"],
        artifact_path: env["SCAN_ARTIFACT"],
        summary_path: env["SCAN_SUMMARY"],
        fetch_concurrency: env.fetch("SCAN_FETCH_CONCURRENCY", DEFAULT_FETCH_CONCURRENCY),
        selection_only: !env.fetch("SCAN_SELECTION_ONLY", "").empty?
      }
      parser = OptionParser.new do |opts|
        opts.on("--source SOURCE", "ranking source or timeframe") { |value| options[:source_choice] = value }
        opts.on("--from ISO8601", "timeframe start") { |value| options[:from_time] = value }
        opts.on("--to ISO8601", "timeframe end") { |value| options[:to_time] = value }
        opts.on("--artifact PATH", "write a deterministic JSON artifact") { |value| options[:artifact_path] = value }
        opts.on("--summary PATH", "write a run-time summary JSON") { |value| options[:summary_path] = value }
        opts.on("--fetch-concurrency N", Integer, "archive workers (1-#{MAX_FETCH_CONCURRENCY})") do |value|
          options[:fetch_concurrency] = value
        end
        opts.on("--selection-only", "select releases without fetching gems") { options[:selection_only] = true }
      end
      begin
        remaining = parser.parse(args)
      rescue OptionParser::ParseError => e
        raise ArgumentError, e.message
      end

      if options[:source_choice].to_s.downcase == "timeframe"
        raise ArgumentError, "timeframe source does not accept rank arguments" unless remaining.empty?
        return new(
          first_page: 1,
          last_page: 1,
          work_dir: env.fetch("SCAN_WORK", DEFAULT_WORK_DIR),
          source_choice: options[:source_choice],
          verbose: !env.fetch("SCAN_VERBOSE", "").empty?,
          from_time: options[:from_time],
          to_time: options[:to_time],
          artifact_path: options[:artifact_path],
          summary_path: options[:summary_path],
          fetch_concurrency: options[:fetch_concurrency],
          selection_only: options[:selection_only]
        )
      end

      raise ArgumentError, "expected at most first_page and last_page" if remaining.size > 2
      if options[:from_time] || options[:to_time]
        raise ArgumentError, "--from/--to require --source timeframe"
      end

      new(
        first_page: remaining[0] || 11,
        last_page: remaining[1] || 20,
        work_dir: env.fetch("SCAN_WORK", DEFAULT_WORK_DIR),
        source_choice: options[:source_choice],
        verbose: !env.fetch("SCAN_VERBOSE", "").empty?,
        artifact_path: options[:artifact_path],
        summary_path: options[:summary_path],
        fetch_concurrency: options[:fetch_concurrency],
        selection_only: options[:selection_only]
      )
    end

    def timeframe?
      source_choice == "timeframe"
    end

    def timeframe_bounds
      [from_time, to_time]
    end

    # Deliberately excludes work_dir and artifact_path: both are execution
    # locations, not scan inputs, and absolute paths would make the artifact
    # change between machines.
    def normalized_input
      input = { "source" => source_choice, "verbose" => verbose }
      if timeframe?
        input.merge!("from" => from_time.iso8601, "to" => to_time.iso8601)
      else
        input.merge!("first_page" => first_page, "last_page" => last_page)
      end
      input["selection_only"] = true if selection_only
      input
    end

    private

    def parse_time(value, name)
      return value.utc if value.is_a?(Time)

      text = value.to_s
      if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Time.strptime(text, "%Y-%m-%d").utc
      else
        Time.iso8601(text).utc
      end
    rescue ArgumentError
      raise ArgumentError, "#{name} must be an ISO 8601 timestamp: #{value.inspect}"
    end

    def validate!
      raise ArgumentError, "first_page must be >= 1" if @first_page < 1
      if @last_page < @first_page
        raise ArgumentError, "last_page (#{@last_page}) must be >= first_page (#{@first_page})"
      end
      unless %w[auto rubygems bestgems timeframe].include?(@source_choice)
        raise ArgumentError,
              "unknown SCAN_SOURCE=#{@source_choice.inspect} (expected auto, rubygems, bestgems or timeframe)"
      end

      if timeframe?
        raise ArgumentError, "timeframe source requires --from and --to" unless @from_time && @to_time
        raise ArgumentError, "timeframe requires from < to" unless @from_time < @to_time
        if @to_time - @from_time > 7 * 24 * 60 * 60
          raise ArgumentError, "timeframe cannot exceed 7 days"
        end
      elsif @from_time || @to_time
        raise ArgumentError, "--from/--to require --source timeframe"
      end
      if selection_only && !timeframe?
        raise ArgumentError, "--selection-only requires --source timeframe"
      end
      unless @fetch_concurrency.between?(1, MAX_FETCH_CONCURRENCY)
        raise ArgumentError, "fetch_concurrency must be between 1 and #{MAX_FETCH_CONCURRENCY}"
      end
    end
  end

  class HttpClient
    RETRYABLE_STATUS_CODES = [408, 429, *500..599].freeze
    RETRYABLE_ERRORS = [Errno::ECONNRESET, Errno::ETIMEDOUT, IOError, Net::OpenTimeout,
                        Net::ReadTimeout, SocketError].freeze
    DEFAULT_MAX_RETRIES = 3
    DEFAULT_BACKOFF = 1.0
    MAX_BACKOFF = 30.0

    def initialize(user_agent: USER_AGENT, open_timeout: 15, read_timeout: 60,
                   max_retries: DEFAULT_MAX_RETRIES, sleeper: Kernel.method(:sleep),
                   on_retry: nil, requester: nil)
      @user_agent = user_agent
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @max_retries = max_retries
      @sleeper = sleeper
      @on_retry = on_retry
      @requester = requester
    end

    def get(url, redirect_budget = 5)
      get_bytes(url, redirect_budget: redirect_budget)
    end

    def get_bytes(url, redirect_budget: 5)
      raise "too many redirects while fetching #{url}" if redirect_budget.negative?

      uri = URI.parse(url)
      response = request_with_retries(uri)
      code = response.code.to_i

      case code
      when 200..299 then response.body
      when 300..399
        location = response["location"]
        raise "GET #{url} redirected without a location" if location.to_s.empty?

        get_bytes(URI.join(url, location).to_s, redirect_budget: redirect_budget - 1)
      else
        raise "GET #{url} failed: #{response.code} #{response.message}"
      end
    end

    private

    def request_with_retries(uri)
      retry_number = 0
      loop do
        response = begin
          request_once(uri)
        rescue StandardError => e
          raise unless RETRYABLE_ERRORS.any? { |error_class| e.is_a?(error_class) }

          retry_request!(uri, retry_number, error: e)
          retry_number += 1
          next
        end

        if RETRYABLE_STATUS_CODES.include?(response.code.to_i)
          retry_request!(uri, retry_number, response: response)
          retry_number += 1
          next
        end

        return response
      end
    end

    def request_once(uri)
      return @requester.call(uri) if @requester

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                      open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.request(Net::HTTP::Get.new(uri, "User-Agent" => @user_agent))
      end
    end

    def retry_request!(uri, retry_number, response: nil, error: nil)
      if retry_number >= @max_retries
        raise error if error

        raise "GET #{uri} failed after #{@max_retries} retries: #{response.code} #{response.message}"
      end

      @on_retry&.call
      @sleeper.call(retry_delay(response, retry_number))
    end

    def retry_delay(response, retry_number)
      retry_after = response && response["retry-after"]
      if retry_after && retry_after.match?(/\A\d+(?:\.\d+)?\z/)
        return [retry_after.to_f, MAX_BACKOFF].min
      end

      if retry_after
        begin
          return [[Time.httpdate(retry_after) - Time.now, 0.0].max, MAX_BACKOFF].min
        rescue ArgumentError
          # Fall through to the bounded exponential delay.
        end
      end

      [DEFAULT_BACKOFF * (2**retry_number), MAX_BACKOFF].min
    end
  end

  # Stores raw HTTP response bodies by the deterministic SHA-256 of their
  # request URL. The cache is intentionally content-agnostic: response hashes
  # in the artifact make changes to a cached response visible without treating
  # a cache hit as a different scan input.
  class ResponseCache
    def initialize(directory)
      @directory = File.expand_path(directory)
      FileUtils.mkdir_p(@directory)
    end

    def fetch(url)
      cache_key = Digest::SHA256.hexdigest(url)
      path = File.join(@directory, cache_key)
      cache_hit = File.file?(path)
      body = if cache_hit
               File.binread(path)
             else
               fetched = yield
               File.binwrite(path, fetched)
               fetched
             end
      {
        body: body,
        cache_key: cache_key,
        response_sha256: Digest::SHA256.hexdigest(body),
        cache_hit: cache_hit,
        bytes: body.bytesize
      }
    end
  end

  # Keeps source request provenance while preserving the small `get(url)`
  # interface used by the source parsers and hermetic fake clients.
  class RecordingHttpClient
    def initialize(client, cache: nil)
      @client = client
      @cache = cache
      @request_records = {}
      @attempts = 0
    end

    def get(url)
      @attempts += 1
      begin
        response = if @cache
                     @cache.fetch(url) { @client.get(url) }
                   else
                     body = @client.get(url)
                     { body: body, cache_key: Digest::SHA256.hexdigest(url),
                       response_sha256: Digest::SHA256.hexdigest(body),
                       cache_hit: false, bytes: body.bytesize }
                   end
        @request_records[url] = response.merge(url: url)
        response[:body]
      rescue StandardError => e
        @request_records[url] = {
          url: url, cache_key: Digest::SHA256.hexdigest(url), response_sha256: nil,
          cache_hit: false, bytes: 0, error: "#{e.class}: #{e.message}"
        }
        raise
      end
    end

    def requests
      @request_records.values.sort_by { |record| record[:url] }
    end

    def attempts
      @attempts
    end
  end

  # --- ranking sources -----------------------------------------------------

  module RubygemsPopular
    PAGE_SIZE = 10
    LABEL = "rubygems.org /releases/popular"
    ENTRIES_INFO_RE = /data-testid="entries-info"[^>]*>(.*?)<\/p>/m
    GEM_LINK_RE = %r{href="/gems/([^"/?#]+)"}

    module_function

    def url(page)
      "https://rubygems.org/releases/popular?page=#{page}"
    end

    def fetch_page(http, page)
      html = http.get(url(page))
      info = html[ENTRIES_INFO_RE, 1]
      raise "#{url(page)}: no entries-info element -- the page layout changed" unless info

      numbers = info.scan(%r{<b>(.*?)</b>}m).flatten
      raise "#{url(page)}: cannot read the rank window from #{info.inspect}" unless numbers.size == 2

      window = numbers[0].gsub("&nbsp;", " ").split("-").map { |s| Integer(s.strip.delete(",")) }
      raise "#{url(page)}: cannot read the rank window from #{info.inspect}" unless window.size == 2

      total = Integer(numbers[1].strip.delete(","))
      names = html.scan(GEM_LINK_RE).flatten.map { |n| URI.decode_www_form_component(n) }
      raise "#{url(page)}: no gem links found -- the page layout changed" if names.empty?
      if names.uniq.size != names.size
        duplicates = names.tally.select { |_, count| count > 1 }.keys
        raise "#{url(page)}: duplicate gem links #{duplicates.inspect}"
      end

      first, last = window
      expected = last - first + 1
      unless names.size == expected
        raise "#{url(page)}: page says ranks #{first}-#{last} but #{names.size} gem links were extracted"
      end

      entries = names.each_with_index.map { |name, i| { rank: first + i, name: name } }
      { entries: entries, first: first, last: last, total: total }
    end
  end

  module BestgemsTotal
    PAGE_SIZE = 20
    LABEL = "bestgems.org total-downloads ranking"
    ROW_RE = %r{<tr><td class="right">(\d+)</td><td class="right">([\d,]+)</td><td><a href="/gems/([^"]+)">}
    HEADER_RE = %r{<em class="numeric">([\d,]+)</em>-<em class="numeric">([\d,]+)</em> of all <em class="numeric">([\d,]+)</em> gems}

    module_function

    def url(page)
      "https://bestgems.org/total?page=#{page}"
    end

    def fetch_page(http, page)
      html = http.get(url(page))
      header = HEADER_RE.match(html)
      raise "#{url(page)}: no ranking header -- the page layout changed" unless header

      first, last, total = header.captures.map { |s| Integer(s.delete(",")) }
      rows = html.scan(ROW_RE)
      raise "#{url(page)}: no ranking rows found -- the page layout changed" if rows.empty?

      expected = last - first + 1
      unless rows.size == expected
        raise "#{url(page)}: page says ranks #{first}-#{last} but #{rows.size} rows were extracted"
      end

      entries = rows.map do |rank, _downloads, name|
        { rank: Integer(rank), name: URI.decode_www_form_component(name) }
      end
      unless entries.first[:rank] == first && entries.last[:rank] == last
        raise "#{url(page)}: row ranks #{entries.first[:rank]}-#{entries.last[:rank]} " \
              "disagree with the header (#{first}-#{last})"
      end

      { entries: entries, first: first, last: last, total: total }
    end
  end

  module TimeframeVersions
    PAGE_SIZE = 30
    LABEL = "rubygems.org /api/v1/timeframe_versions"
    REQUIRED_KEYS = %w[name version platform created_at prerelease sha downloads version_downloads].freeze

    module_function

    def url(from_time, to_time, page)
      query = URI.encode_www_form(
        from: from_time.utc.iso8601,
        to: to_time.utc.iso8601,
        page: page
      )
      "https://rubygems.org/api/v1/timeframe_versions.json?#{query}"
    end

    def fetch_page(http, from_time, to_time, page)
      response = JSON.parse(http.get(url(from_time, to_time, page)))
      raise "#{url(from_time, to_time, page)}: response must be an array" unless response.is_a?(Array)
      return [] if response.empty?

      response.map.with_index do |entry, index|
        validate_entry(entry, page, index)
      end
    rescue JSON::ParserError => e
      raise "#{url(from_time, to_time, page)}: invalid JSON: #{e.message}"
    end

    def validate_entry(entry, page, index)
      unless entry.is_a?(Hash)
        raise "timeframe page #{page} entry #{index}: expected an object"
      end
      missing = REQUIRED_KEYS.reject { |key| entry.key?(key) }
      unless missing.empty?
        raise "timeframe page #{page} entry #{index}: missing #{missing.join(', ')}"
      end
      raise "timeframe page #{page} entry #{index}: prerelease must be boolean" unless [true, false].include?(entry["prerelease"])

      created_at = Time.iso8601(entry["created_at"].to_s).utc
      raise "timeframe page #{page} entry #{index}: invalid created_at" unless created_at

      entry.merge("created_at_time" => created_at)
    rescue ArgumentError
      raise "timeframe page #{page} entry #{index}: invalid created_at #{entry["created_at"].inspect}"
    end
  end

  # --- assembler detection -------------------------------------------------

  OBJS_VALUE_RE = /(?:%[wW][(\[{][^)\]}]*[)\]}]|\[[^\]]*\]|"[^"]*"|'[^']*')/m
  OBJS_ASSIGN_RE = /\$objs\s*(?:<<|\+=|=)\s*(#{OBJS_VALUE_RE})/m
  OBJS_CONCAT_RE = /\$objs\.concat\(\s*(#{OBJS_VALUE_RE})\s*\)/m
  OBJ_TOKEN_RE = %r{[\w.\-/]+\.o\b}

  module InspectionHelpers
    module_function

    def extension_dirs(extensions)
      extensions.map { |extension| File.dirname(extension.to_s) }.uniq.sort
    end

    def non_ext_extension_dirs(extensions)
      extension_dirs(extensions).reject { |dir| dir == "ext" || dir.start_with?("ext/") }
    end

    def archive_native_sources(root)
      files = Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) }
      native = files.select do |path|
        %w[.c .h .cpp .cc .cxx .c++ .hpp .hxx .hh].include?(File.extname(path).downcase)
      end
      relative = lambda { |path| path.sub(%r{\A#{Regexp.escape(root)}/}, "") }
      {
        source_files: native.map(&relative).sort,
        extconf_files: files.select { |path| File.basename(path) == "extconf.rb" }.map(&relative).sort
      }
    end

    def assembly_source_files(root, dirs)
      files = (["ext"] + dirs).flat_map { |dir| Dir.glob(File.join(root, dir, "**", "*.{S,s}")) }
      files.map { |path| path.sub(%r{\A#{Regexp.escape(root)}/}, "") }.uniq.sort
    end

    def objs_basenames(extconf_text)
      values = extconf_text.scan(OBJS_ASSIGN_RE).flatten + extconf_text.scan(OBJS_CONCAT_RE).flatten
      values.flat_map { |value| value.scan(OBJ_TOKEN_RE) }
            .map { |token| File.basename(token, ".o") }.uniq
    end

    def objs_missing_c_source(root, bases)
      bases.filter_map do |base|
        next unless Dir.glob(File.join(root, "**", "#{base}.c")).empty?

        { base: base, asm: !Dir.glob(File.join(root, "**", "#{base}.{S,s}")).empty? }
      end
    end

    def validate_fetched_spec(spec, requested_version, requested_platform)
      if requested_version && spec.version.to_s != requested_version
        raise ArgumentError, "fetched version #{spec.version} does not match requested #{requested_version}"
      end
      return unless requested_platform && spec.platform.to_s != requested_platform

      raise ArgumentError, "fetched platform #{spec.platform} does not match requested #{requested_platform}"
    end

    def validate_gem_sha!(actual, expected)
      return "not_provided" if expected.nil? || expected.to_s.empty?
      return "match" if actual.to_s.casecmp?(expected.to_s)

      raise ArgumentError, "gem_sha256_mismatch: API=#{expected} fetched=#{actual}"
    end
  end

  # A review artifact is intentionally a separate output from the human table.
  # It contains only normalized inputs and observed content hashes; run time,
  # absolute paths, cache-hit state, and interpreter details are not part of it.
  class Artifact
    SCHEMA_VERSION = 1

    class << self
      def write(path, config:, source:, requests:, results:)
        payload = {
          "schema_version" => SCHEMA_VERSION,
          "source" => source_name(config, source),
          "input" => config.normalized_input,
          "source_requests" => requests.sort_by { |request| request[:url] }.map do |request|
            {
              "url" => request[:url],
              "cache_key" => request[:cache_key],
              "response_sha256" => request[:response_sha256]
            }.tap do |record|
              record["error"] = request[:error] if request[:error]
            end
          end,
          "records" => results.sort_by { |result| record_sort_key(result) }.map { |result| record(result) }
        }
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, stable_pretty_generate(payload) + "\n")
      end

      def source_name(config, source)
        return "timeframe" if config.timeframe?
        return "rubygems" if source == RubygemsPopular
        return "bestgems" if source == BestgemsTotal

        source::LABEL
      end

      # Ruby's bundled json gem has changed how it pretty-prints empty arrays
      # across supported interpreter versions. Keep review artifacts byte
      # stable so a replay and a fixture compare the same way on every CI job.
      def stable_pretty_generate(payload)
        JSON.pretty_generate(payload).gsub(/\[\n(?:[ \t]*\n)*[ \t]*\]/, "[]")
      end

      def record_sort_key(result)
        [result[:name].to_s, result[:version].to_s, result[:platform].to_s, result[:rank].to_i]
      end

      def record(result)
        includes = result[:includes] || {}
        {
          "rank" => result[:rank],
          "name" => result[:name],
          "version" => result[:version],
          "platform" => result[:platform],
          "created_at" => result[:created_at],
          "downloads" => result[:downloads],
          "version_downloads" => result[:version_downloads],
          "selection" => {
            "note" => result[:selection_note],
            "rejections" => Array(result[:selection_rejections])
          },
          "gem" => {
            "sha256" => result[:gem_sha256],
            "api_sha256" => result[:api_sha256],
            "sha256_match" => result[:sha256_match]
          },
          "gemspec" => {
            "extensions" => Array(result[:extensions]).map(&:to_s).sort,
            "extension_directories" => Array(result[:extension_directories]).map(&:to_s).sort,
            "native_source_files" => Array(result[:native_source_files]).map(&:to_s).sort,
            "extconf_files" => Array(result[:extconf_files]).map(&:to_s).sort
          },
          "corpus" => {
            "included" => !!result[:in_corpus],
            "status" => result[:status].to_s,
            "reason" => result[:reason],
            "review_reasons" => Array(result[:review_reasons]),
            "c_files" => result[:c_files].to_i,
            "h_files" => result[:h_files].to_i
          },
          "headers" => {
            "bundled" => includes.select { |_, category| category.to_sym == :bundled }.keys.sort,
            "gap" => includes.select { |_, category| category.to_sym == :gap }.keys.sort,
            "ruby_or_self" => Array(result[:ruby_self]).map(&:to_s).sort
          }
        }.tap do |record|
          record["source_error"] = result[:source_error] if result[:source_error]
        end
      end
    end
  end

  # Runtime evidence is deliberately separate from Artifact. It contains
  # elapsed time and cache state, so it cannot be a deterministic replay
  # artifact. It never contains the absolute work or output paths.
  class RunSummary
    SCHEMA_VERSION = 1

    class << self
      def write(path, config:, source:, started_at:, finished_at:, timings:, counters:, requests:, results:,
                source_stats: {}, peak_work_bytes: nil)
        archive_stats = requests.fetch(:archives, {})
        source_errors = results.filter_map { |result| result[:source_error] }
        payload = {
          "schema_version" => SCHEMA_VERSION,
          "source" => Artifact.source_name(config, source),
          "input" => config.normalized_input,
          "started_at" => started_at.utc.iso8601,
          "finished_at" => finished_at.utc.iso8601,
          "elapsed_seconds" => (finished_at - started_at).round(6),
          "phases_seconds" => SUMMARY_PHASES.to_h { |name| [name, timings.fetch(name, 0.0).round(6)] },
          "execution" => {
            "fetch_concurrency" => config.fetch_concurrency,
            "peak_work_bytes" => peak_work_bytes
          },
          "source_stats" => source_stats,
          "requests" => {
            "attempts" => requests.fetch(:attempts) + requests.fetch(:archives, {}).fetch(:attempts, 0),
            "source_attempts" => requests.fetch(:attempts),
            "archive_attempts" => requests.fetch(:archives, {}).fetch(:attempts, 0),
            "unique_urls" => requests.fetch(:records).length + requests.fetch(:archives, {}).fetch(:unique_urls, 0),
            "cache_hits" => requests.fetch(:records).count { |record| record[:cache_hit] } +
                             requests.fetch(:archives, {}).fetch(:cache_hits, 0),
            "bytes" => requests.fetch(:records).sum { |record| record[:bytes].to_i } +
                       requests.fetch(:archives, {}).fetch(:bytes, 0)
          },
          "archives" => SUMMARY_ARCHIVE_COUNTERS.to_h do |name|
            value = if %i[bytes unique_urls].include?(name)
                      archive_stats.fetch(name, 0)
                    else
                      counters.fetch(name, 0)
                    end
            [name.to_s, value]
          end,
          "source_errors" => {
            "total" => source_errors.length,
            "by_kind" => source_errors.group_by { |error| error.fetch("kind") }
                                            .transform_values(&:length).sort.to_h,
            "by_stage" => source_errors.group_by { |error| error.fetch("stage") }
                                             .transform_values(&:length).sort.to_h
          },
          "results" => results.group_by { |result| result[:status].to_s }
                               .transform_values(&:length)
                               .sort.to_h
        }
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, JSON.pretty_generate(payload) + "\n")
      end
    end
  end

  # Downloads a source-platform archive from the URI returned by the v2
  # metadata endpoint. A completed archive is addressable by its exact
  # name/version path; a temporary `.part` file is never treated as a cache
  # hit and is removed after a failed or hash-mismatched download.
  class ArchiveFetcher
    def initialize(http_client:, work_dir:)
      @http_client = http_client
      @work_dir = work_dir
      @lock = Mutex.new
      @stats = { attempts: 0, unique_urls: 0, cache_hits: 0, bytes: 0, urls: Set.new }
    end

    def fetch(name:, version:, platform:, gem_uri:, expected_sha256:)
      validate_uri!(gem_uri)
      raise ArgumentError, "direct archive requires the ruby platform" unless platform.to_s == "ruby"
      raise ArgumentError, "direct archive requires a metadata SHA-256" if expected_sha256.to_s.empty?

      path = Corpus::Census.cached_gem_path(name, version, @work_dir)
      if path && sha256(path).casecmp?(expected_sha256.to_s)
        record_request(gem_uri, cache_hit: true, bytes: File.size(path))
        return { path: path, error: nil, cache_hit: true }
      end

      record_request(gem_uri, cache_hit: false)
      FileUtils.mkdir_p(@work_dir)
      path ||= File.join(@work_dir, "#{name}-#{version}.gem")
      partial_path = "#{path}.part"
      begin
        File.binwrite(partial_path, @http_client.get_bytes(gem_uri))
        record_bytes(File.size(partial_path))
        actual_sha256 = sha256(partial_path)
        unless actual_sha256.casecmp?(expected_sha256.to_s)
          raise ArgumentError,
                "gem_sha256_mismatch: API=#{expected_sha256} fetched=#{actual_sha256}"
        end
        File.rename(partial_path, path)
        { path: path, error: nil, cache_hit: false }
      rescue StandardError => e
        FileUtils.rm_f(partial_path)
        { path: nil, error: "#{e.class}: #{e.message}", cache_hit: false }
      end
    rescue StandardError => e
      { path: nil, error: "#{e.class}: #{e.message}", cache_hit: false }
    end

    def stats
      @lock.synchronize do
        @stats.merge(unique_urls: @stats[:urls].length).tap { |copy| copy.delete(:urls) }
      end
    end

    private

    def validate_uri!(gem_uri)
      uri = URI.parse(gem_uri.to_s)
      return if uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.query && !uri.fragment

      raise ArgumentError, "gem_uri must be an absolute HTTPS URL without query or fragment"
    rescue URI::InvalidURIError
      raise ArgumentError, "gem_uri is not a valid URL: #{gem_uri.inspect}"
    end

    def sha256(path)
      Digest::SHA256.file(path).hexdigest
    end

    def record_request(url, cache_hit:, bytes: 0)
      @lock.synchronize do
        @stats[:attempts] += 1
        @stats[:urls] << url
        @stats[:cache_hits] += 1 if cache_hit
        @stats[:bytes] += bytes.to_i
      end
    end

    def record_bytes(bytes)
      @lock.synchronize { @stats[:bytes] += bytes.to_i }
    end
  end

  class Scanner
    attr_reader :config

    def initialize(config:, http_client: nil, archive_http_client: nil,
                   sleeper: Kernel.method(:sleep),
                   out: $stdout, err: $stderr,
                   corpus_names: Corpus::Gems::LIST.map { |gem| gem[:name] },
                   bundled_headers: nil)
      @config = config
      @timings = Hash.new(0.0)
      @counters = Hash.new(0)
      @counter_lock = Mutex.new
      @sleeper = sleeper
      @raw_http_client = http_client || HttpClient.new(
        sleeper: sleeper, on_retry: -> { increment_counter(:retries) }
      )
      @archive_http_client = archive_http_client || @raw_http_client
      response_cache = (config.artifact_path || config.summary_path) &&
                       ResponseCache.new(File.join(config.work_dir, "raw_responses"))
      @http = RecordingHttpClient.new(@raw_http_client, cache: response_cache)
      @archive_fetcher = ArchiveFetcher.new(http_client: @archive_http_client, work_dir: config.work_dir)
      @out = out
      @err = err
      @corpus_names = corpus_names.to_set
      @bundled_headers = bundled_headers || Corpus::Census.bundled_headers(File.join(RUBYCC_ROOT, "include"))
      @api_cache_dir = File.join(config.work_dir, "api")
      @phase_stack = []
      @started_at = nil
      @last_source = nil
      @last_results = []
      @source_stats = { "pages" => 0, "release_entries" => 0 }
      @peak_work_bytes = 0
    end

    def run
      @started_at = Time.now.utc
      perform_scan
    ensure
      write_summary if config.summary_path && @started_at
    end

    private

    def perform_scan
      if config.timeframe?
        selected, rejected = collect_timeframe
        if config.selection_only
          results = rejected + selected.map { |entry| selection_only_result(entry) }
          return finish_selection(results, TimeframeVersions, config.from_time, config.to_time)
        end
        archives = measure_phase("archive_fetch") { fetch_timeframe_archives(selected) }
        results = rejected + selected.each_with_index.map do |entry, index|
          archive = archives.fetch(index)
          step "inspecting #{entry[:name]} #{entry[:version]} (platform=#{entry[:platform]})"
          inspect_gem(entry, archive: archive)
        end
        return finish_report(results, TimeframeVersions, config.from_time, config.to_time)
      end

      first_rank = ((config.first_page - 1) * RANKS_PER_PAGE) + 1
      last_rank = config.last_page * RANKS_PER_PAGE
      step "scanning popularity ranks #{first_rank}-#{last_rank}"
      step "work dir: #{config.work_dir} (downloaded .gem files are cached and reused)"
      FileUtils.mkdir_p(config.work_dir)

      source = select_source(first_rank, last_rank)
      ranking = measure_phase("ranking") { collect_ranking(source, first_rank, last_rank) }
      results = ranking.map do |entry|
        step "inspecting ##{entry[:rank]} #{entry[:name]}"
        inspect_gem(entry)
      end

      finish_report(results, source, first_rank, last_rank)
    end

    def measure_phase(name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      frame = { child_seconds: 0.0 }
      @phase_stack << frame
      yield
    ensure
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      @phase_stack.pop
      @timings[name] += elapsed - frame.fetch(:child_seconds)
      @phase_stack.last[:child_seconds] += elapsed if @phase_stack.any?
    end

    def increment_counter(name, amount = 1)
      @counter_lock.synchronize { @counters[name] += amount }
    end

    def write_summary
      finished_at = Time.now.utc
      source = @last_source || (config.timeframe? ? TimeframeVersions : RubygemsPopular)
      record_work_size
      RunSummary.write(
        config.summary_path,
        config: config,
        source: source,
        started_at: @started_at,
        finished_at: finished_at,
        timings: @timings,
        counters: @counters,
        requests: { attempts: @http.attempts, records: @http.requests, archives: @archive_fetcher.stats },
        results: @last_results,
        source_stats: @source_stats.merge(
          "unique_gems" => @last_results.map { |result| result[:name] }.compact.uniq.size
        ),
        peak_work_bytes: @peak_work_bytes
      )
    end

    def record_work_size
      return unless File.directory?(config.work_dir)

      bytes = Dir.glob(File.join(config.work_dir, "**", "*"), File::FNM_DOTMATCH).sum do |path|
        File.file?(path) ? File.size(path) : 0
      end
      @peak_work_bytes = [@peak_work_bytes, bytes].max
    rescue SystemCallError
      # Runtime evidence should not turn a completed static scan into a failed
      # scan merely because a temporary file disappeared while measuring it.
    end

    def step(message)
      @err.puts "==> #{message}"
    end

    def finish_report(results, source, first_rank, last_rank)
      ok = report(results, source, first_rank, last_rank)
      @last_source = source
      @last_results = results
      if config.artifact_path
        measure_phase("artifact_write") do
          Artifact.write(config.artifact_path, config: config, source: source,
                         requests: @http.requests, results: results)
        end
      end
      ok
    end

    def finish_selection(results, source, from_time, to_time)
      @last_source = source
      @last_results = results
      if config.artifact_path
        measure_phase("artifact_write") do
          Artifact.write(config.artifact_path, config: config, source: source,
                         requests: @http.requests, results: results)
        end
      end
      @out.puts "selection-only: #{results.count { |result| result[:status] == :uninspected }} selected gems"
      @out.puts "  timeframe: #{from_time.iso8601} - #{to_time.iso8601} (UTC)"
      @out.puts "  v2 source/yanked verification: deferred to the static sample"
      @out.puts "  errors: #{results.count { |result| result[:status] == :error }}"
      true
    end

    def select_source(first_rank, last_rank)
      case config.source_choice
      when "rubygems" then RubygemsPopular
      when "bestgems" then BestgemsTotal
      when "auto"
        if last_rank <= RUBYGEMS_POPULAR_CAP
          RubygemsPopular
        else
          step "ranks #{first_rank}-#{last_rank} exceed rubygems.org's #{RUBYGEMS_POPULAR_CAP}-gem popular list; " \
               "falling back to #{BestgemsTotal::LABEL} (SCAN_SOURCE=rubygems to refuse instead)"
          BestgemsTotal
        end
      end
    end

    def collect_timeframe
      records = measure_phase("timeframe_pagination") { collect_timeframe_pages }
      measure_phase("release_selection") { select_timeframe_releases(records) }
    end

    def collect_timeframe_pages
      records = []
      page = 1
      seen_pages = Set.new
      loop do
        step "timeframe: #{TimeframeVersions.url(config.from_time, config.to_time, page)}"
        entries = TimeframeVersions.fetch_page(@http, config.from_time, config.to_time, page)
        @source_stats["pages"] += 1
        @source_stats["release_entries"] += entries.size
        break if entries.empty?
        raise "timeframe page #{page} returned more than #{TimeframeVersions::PAGE_SIZE} entries" if entries.size > TimeframeVersions::PAGE_SIZE

        fingerprint = JSON.generate(entries.map { |entry| entry.reject { |key, _| key == "created_at_time" } })
        raise "timeframe page #{page} repeats a previous page" unless seen_pages.add?(fingerprint)

        entries.each do |entry|
          unless entry["created_at_time"] >= config.from_time && entry["created_at_time"] < config.to_time
            raise "timeframe page #{page} entry #{entry["name"]} #{entry["version"]} is outside the requested interval"
          end
        end
        records.concat(entries)
        page += 1
      end

      records
    end

    def select_timeframe_releases(records)
      return select_timeframe_collection(records) if config.selection_only

      selected = []
      rejected = []

      records.group_by { |entry| entry["name"] }.sort_by { |name, _| name }.each do |name, entries|
        candidates = entries.group_by { |entry| entry["version"] }.values.map do |versions|
          versions.max_by { |entry| [entry["platform"] == "ruby" ? 1 : 0, entry["created_at_time"].to_f] }
        end
        candidates.sort! do |left, right|
          by_time = right["created_at_time"] <=> left["created_at_time"]
          next by_time unless by_time.zero?

          by_version = Gem::Version.new(right["version"]) <=> Gem::Version.new(left["version"])
          next by_version unless by_version.zero?

          (right["platform"] == "ruby" ? 1 : 0) <=> (left["platform"] == "ruby" ? 1 : 0)
        end

        discarded = []
        source_errors = []
        chosen = nil
        candidates.each do |candidate|
          if candidate["prerelease"]
            discarded << "#{candidate["version"]}: prerelease"
            next
          end

          details = timeframe_version_details(candidate["name"], candidate["version"])
          if details[:error]
            discarded << "#{candidate["version"]}: #{details[:error]}"
            source_errors << details[:source_error] if details[:source_error]
            next
          end
          unless details["name"] == candidate["name"] && details["version"] == candidate["version"]
            discarded << "#{candidate["version"]}: v2 name/version mismatch"
            next
          end
          unless details["platform"] == "ruby"
            discarded << "#{candidate["version"]}: source platform unavailable (#{details["platform"]})"
            next
          end
          if details["yanked"]
            discarded << "#{candidate["version"]}: yanked"
            next
          end

          chosen = candidate.merge(
            "v2" => details,
            "platform" => "ruby",
            "selection_note" => selection_note(candidates, discarded, candidate)
          )
          break
        rescue ArgumentError
          discarded << "#{candidate["version"]}: invalid version"
        end

        if chosen
          selected << {
            source: :timeframe,
            name: chosen["name"],
            version: chosen["version"],
            platform: chosen["platform"],
            created_at: chosen["created_at"],
            downloads: chosen["v2"]["downloads"] || chosen["downloads"],
            version_downloads: chosen["v2"]["version_downloads"] || chosen["version_downloads"],
            sha: chosen["v2"]["sha"] || chosen["sha"],
            api_sha: chosen["v2"]["sha"],
            gem_uri: chosen["v2"]["gem_uri"],
            selection_note: chosen["selection_note"],
            selection_rejections: discarded
          }
        else
          rejected << rejected_timeframe_result(
            name, discarded,
            source_error: SourceErrorClassification.choose(source_errors, discarded)
          )
        end
      end

      [selected, rejected]
    end

    # Evaluation mode measures the complete release stream before spending
    # network and build time on a small, predeclared sample. The timeframe
    # payload still provides deterministic prerelease/platform ordering; v2
    # yanked/source verification is intentionally deferred and never counted
    # as a static [1] result.
    def select_timeframe_collection(records)
      selected = []
      rejected = []

      records.group_by { |entry| entry["name"] }.sort_by { |name, _| name }.each do |name, entries|
        candidates = entries.group_by { |entry| entry["version"] }.values.map do |versions|
          versions.max_by { |entry| [entry["platform"] == "ruby" ? 1 : 0, entry["created_at_time"].to_f] }
        end
        candidates.sort_by! do |entry|
          [-entry["created_at_time"].to_f, Gem::Version.new(entry["version"])]
        rescue ArgumentError
          [Float::INFINITY, Gem::Version.new("0")]
        end
        discarded = candidates.drop(1).map { |entry| "#{entry["version"]}: duplicate release" }
        chosen = candidates.find { |entry| !entry["prerelease"] }
        if chosen
          selected << {
            source: :timeframe, name: chosen["name"], version: chosen["version"],
            platform: chosen["platform"], created_at: chosen["created_at"],
            downloads: chosen["downloads"], version_downloads: chosen["version_downloads"],
            sha: chosen["sha"], api_sha: nil,
            selection_note: "selection-only: v2 source/yanked verification deferred; " \
                            "releases considered: #{candidates.map { |entry| entry["version"] }.join(', ')}; " \
                            "selected #{chosen["version"]}",
            selection_rejections: discarded + candidates.select { |entry| entry["prerelease"] }.map { |entry| "#{entry["version"]}: prerelease" }
          }
        else
          rejected << rejected_timeframe_result(name, candidates.map { |entry| "#{entry["version"]}: prerelease" })
        end
      end

      [selected, rejected]
    end

    def selection_note(candidates, discarded, chosen)
      versions = candidates.map { |entry| entry["version"] }.join(", ")
      note = "timeframe releases considered: #{versions}; selected #{chosen["version"]}"
      discarded.empty? ? note : "#{note}; discarded: #{discarded.join('; ')}"
    end

    def rejected_timeframe_result(name, reasons, source_error: nil)
      {
        rank: nil, name: name, version: nil, platform: nil, created_at: nil,
        downloads: nil, version_downloads: nil, extensions: [],
        status: source_error ? source_error.fetch("kind").to_sym : :error,
        source_error: source_error,
        reason: "no non-prerelease, non-yanked ruby source release: #{reasons.join('; ')}",
        selection_rejections: reasons, c_files: 0, h_files: 0, notes: [],
        in_corpus: @corpus_names.include?(name)
      }
    end

    def selection_only_result(entry)
      {
        rank: nil, name: entry[:name], version: entry[:version], platform: entry[:platform],
        created_at: entry[:created_at], downloads: entry[:downloads],
        version_downloads: entry[:version_downloads], selection_note: entry[:selection_note],
        selection_rejections: Array(entry[:selection_rejections]),
        gem_sha256: nil, api_sha256: entry[:api_sha], sha256_match: "not_fetched",
        extensions: [], extension_directories: [], native_source_files: [], extconf_files: [],
        review_reasons: [], status: :uninspected,
        reason: "selection-only: static archive inspection deferred to the sample stage",
        c_files: 0, h_files: 0, notes: [], in_corpus: @corpus_names.include?(entry[:name])
      }
    end

    def timeframe_version_details(name, version)
      @timeframe_version_cache ||= {}
      key = [name, version]
      return @timeframe_version_cache[key] if @timeframe_version_cache.key?(key)

      details = measure_phase("v2_metadata") do
        encoded_name = URI.encode_www_form_component(name)
        encoded_version = URI.encode_www_form_component(version)
        url = "https://rubygems.org/api/v2/rubygems/#{encoded_name}/versions/#{encoded_version}.json?platform=ruby"
        details = JSON.parse(@http.get(url))
        required = %w[name version platform yanked sha gem_uri]
        missing = required.reject { |field| details.is_a?(Hash) && details.key?(field) }
        raise "v2 response missing #{missing.join(', ')}" unless missing.empty?
        unless [true, false].include?(details["yanked"])
          raise "v2 response yanked must be boolean"
        end
        uri = URI.parse(details["gem_uri"].to_s)
        unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
          raise "v2 response gem_uri must be an absolute HTTPS URL without query or fragment"
        end

        details
      end

      @timeframe_version_cache[key] = details
    rescue JSON::ParserError => e
      @timeframe_version_cache[key] = { error: "invalid v2 JSON: #{e.message}" }
    rescue StandardError => e
      message = "v2 lookup failed: #{e.message}"
      @timeframe_version_cache[key] = {
        error: message,
        source_error: SourceErrorClassification.from_message(message, stage: :v2_metadata)
      }
    end

    def collect_ranking(source, first_rank, last_rank)
      entries = []
      first_page = ((first_rank - 1) / source::PAGE_SIZE) + 1
      last_page = ((last_rank - 1) / source::PAGE_SIZE) + 1

      (first_page..last_page).each do |page|
        expected_first = ((page - 1) * source::PAGE_SIZE) + 1
        step "ranking: #{source.url(page)} (expecting rank #{expected_first}...)"
        result = source.fetch_page(@http, page)

        @source_stats["pages"] += 1
        @source_stats["release_entries"] += result[:entries].size

        if last_rank > result[:total]
          raise "#{source::LABEL} ranks only #{result[:total]} gems; ranks up to #{last_rank} were requested"
        end
        unless result[:first] == expected_first
          raise "#{source.url(page)}: expected the page to start at rank #{expected_first} " \
                "but it reports #{result[:first]} -- the site paginates differently than assumed"
        end

        entries.concat(result[:entries])
        @sleeper.call(PAGE_DELAY) unless page == last_page
      end

      slice = entries.select { |entry| entry[:rank].between?(first_rank, last_rank) }
      unless slice.size == last_rank - first_rank + 1
        raise "collected #{slice.size} gems for ranks #{first_rank}-#{last_rank} " \
              "(expected #{last_rank - first_rank + 1})"
      end
      slice
    end

    def gem_downloads(name)
      FileUtils.mkdir_p(@api_cache_dir)
      url = "https://rubygems.org/api/v1/gems/#{URI.encode_www_form_component(name)}.json"
      path = File.join(@api_cache_dir, "#{name}.json")
      if config.artifact_path
        # Artifact mode must record the request on every replay. RecordingHttpClient
        # then serves the body from raw_responses/ instead of making the second
        # artifact silently omit a request just because api/ already exists.
        body = @http.get(url)
        File.write(path, body)
      elsif !File.file?(path)
        body = @http.get(url)
        File.write(path, body)
        @sleeper.call(API_DELAY)
      end
      JSON.parse(File.read(path))["downloads"]
    rescue StandardError => e
      @err.puts "    downloads unavailable for #{name}: #{e.class}: #{e.message}"
      nil
    end

    def fetch_timeframe_archives(entries)
      return [] if entries.empty?

      queue = Queue.new
      entries.each_index { |index| queue << index }
      results = Array.new(entries.length)
      workers = Array.new([config.fetch_concurrency, entries.length].min) do
        Thread.new do
          loop do
            index = queue.pop(true)
            entry = entries.fetch(index)
            results[index] = fetch_gem_for_scan(entry[:name], entry[:version], entry)
          rescue ThreadError
            break
          rescue StandardError => e
            increment_counter(:failures)
            results[index] = [nil, "#{e.class}: #{e.message}"] if index
          end
        end
      end
      workers.each(&:join)
      results
    end

    # Timeframe entries use the v2 gem_uri when present. Rank-based scans have
    # no immutable archive URI, so they retain the legacy gem fetch fallback.
    def fetch_gem_for_scan(name, version, entry = nil)
      if entry && entry[:gem_uri]
        fetched = @archive_fetcher.fetch(
          name: name, version: version, platform: entry[:platform], gem_uri: entry[:gem_uri],
          expected_sha256: entry[:api_sha]
        )
        increment_counter(:cache_hits) if fetched[:cache_hit]
        increment_counter(:fetch_attempts) unless fetched[:cache_hit]
        fetched[:path] ? increment_counter(:successes) : increment_counter(:failures)
        return [fetched[:path], fetched[:error]]
      end

      cached = Corpus::Census.cached_gem_path(name, version, config.work_dir)
      increment_counter(:cache_hits) if cached
      increment_counter(:fetch_attempts) unless cached
      gem_path, fetch_error = Corpus::Census.fetch_gem(name, version, config.work_dir)
      gem_path ? increment_counter(:successes) : increment_counter(:failures)
      [gem_path, fetch_error]
    end

    # Inspect one gem without executing any code from the gem. extconf.rb is
    # read as text for the assembler check; the R10 helpers own the gate.
    def inspect_gem(entry, archive: nil)
      name = entry[:name]
      result = {
        rank: entry[:rank], name: name, version: nil, platform: entry[:platform],
        created_at: entry[:created_at], downloads: nil, version_downloads: entry[:version_downloads],
        extensions: [], selection_note: entry[:selection_note],
        selection_rejections: Array(entry[:selection_rejections]),
        gem_sha256: nil, api_sha256: entry[:api_sha], sha256_match: "not_provided",
        extension_directories: [], native_source_files: [], extconf_files: [], review_reasons: [],
        status: nil, reason: nil, c_files: 0, h_files: 0, notes: [],
        in_corpus: @corpus_names.include?(name)
      }

      requested_version = entry[:version]
      increment_counter(:inspections)
      gem_path, fetch_error = if archive
                                archive
                              else
                                measure_phase("archive_fetch") do
                                  fetch_gem_for_scan(name, requested_version, entry)
                                end
                              end
      unless gem_path
        source_error = SourceErrorClassification.from_message(fetch_error, stage: :archive)
        result[:source_error] = source_error
        result[:status] = source_error ? source_error.fetch("kind").to_sym : :error
        result[:reason] = source_error ? source_error.fetch("reason") :
          "gem fetch failed: #{fetch_error.to_s.lines.map(&:strip).reject(&:empty?).last}"
        return result
      end

      measure_phase("unpack_static") do
      result[:gem_sha256] = Digest::SHA256.file(gem_path).hexdigest
      result[:sha256_match] = InspectionHelpers.validate_gem_sha!(result[:gem_sha256], result[:api_sha256])

      spec = Gem::Package.new(gem_path).spec
      result[:version] = spec.version.to_s
      result[:platform] = spec.platform.to_s
      result[:extensions] = spec.extensions.to_a
      result[:extension_directories] = InspectionHelpers.extension_dirs(result[:extensions])
      InspectionHelpers.validate_fetched_spec(spec, requested_version, entry[:platform])
      result[:downloads] = entry.key?(:downloads) ? entry[:downloads] : gem_downloads(name)
      result[:notes] << entry[:selection_note] if entry[:selection_note]
      mini_portile = spec.dependencies.select { |dependency| dependency.name.to_s.include?("mini_portile") }
      unless mini_portile.empty?
        result[:notes] << "gemspec depends on #{mini_portile.map { |d| "#{d.name} #{d.requirement}" }.join(', ')}"
      end

      root = Corpus::Census.unpack_gem(gem_path, config.work_dir)
      native = InspectionHelpers.archive_native_sources(root)
      result[:native_source_files] = native[:source_files]
      result[:extconf_files] = native[:extconf_files]
      if result[:extensions].empty?
        if result[:native_source_files].any? || result[:extconf_files].any?
          result[:review_reasons] << "undeclared_native_source: archive contains " \
                                     "#{result[:native_source_files].size} native source(s) and " \
                                     "#{result[:extconf_files].size} extconf.rb file(s)"
          result[:status] = :review
          result[:reason] = result[:review_reasons].join("; ")
        else
          result[:status] = :no_ext
        end
        return result
      end

      outside = InspectionHelpers.non_ext_extension_dirs(result[:extensions])
      unless outside.empty?
        extra = outside.sum { |dir| Dir.glob(File.join(root, dir, "**", "*.{c,h,cc,cpp,cxx}")).size }
        result[:review_reasons] << "extension_outside_census_root: #{outside.join(', ')}"
        result[:notes] << "extension(s) outside ext/: #{outside.join(', ')} " \
                          "(#{extra} C/C++ files there are not covered by the census helpers)"
      end

      cpp = Corpus::Census.ext_cpp_files(root)
      unless cpp.empty?
        names = cpp.map { |path| File.basename(path) }.uniq.sort
        shown = names.first(3).join(", ")
        shown += ", ... (#{names.size} distinct names)" if names.size > 3
        result[:status] = :excluded
        result[:reason] = "C++ sources present (#{cpp.size} files: #{shown})"
        return result
      end

      extconf_text = Corpus::Census.read_extconf(root)
      if Corpus::Census.configure_dependency?(extconf_text)
        result[:status] = :excluded
        result[:reason] = "configure / mini_portile dependency in extconf.rb"
        return result
      end

      analysis = Corpus::Census.classify_source_files(Corpus::Census.ext_source_files(root), @bundled_headers)
      result[:includes] = analysis[:includes]
      result[:ruby_self] = analysis[:ruby_self]
      result[:c_files] = analysis[:ext_c_files]
      result[:h_files] = analysis[:ext_h_files]

      findings = []
      asm_files = InspectionHelpers.assembly_source_files(root, outside)
      unless asm_files.empty?
        shown = asm_files.first(3).join(", ")
        shown += ", ... (#{asm_files.size} files)" if asm_files.size > 3
        findings << "#{asm_files.size} assembly source#{asm_files.size == 1 ? '' : 's'} bundled (#{shown})"
      end

      missing_objs = InspectionHelpers.objs_missing_c_source(
        root, InspectionHelpers.objs_basenames(extconf_text)
      )
      unless missing_objs.empty?
        findings << missing_objs.map do |missing|
          suffix = missing[:asm] ? " (built from bundled #{missing[:base]}.S)" : ""
          "$objs lists #{missing[:base]}.o with no #{missing[:base]}.c#{suffix}"
        end.join("; ")
      end

      unless findings.empty?
        if result[:review_reasons].empty?
          result[:status] = :needs_review
          result[:reason] = findings.join("; ")
        else
          result[:review_reasons].concat(findings)
          result[:status] = :review
          result[:reason] = result[:review_reasons].join("; ")
        end
        return result
      end

      unless result[:review_reasons].empty?
        result[:status] = :review
        result[:reason] = result[:review_reasons].join("; ")
        return result
      end

      result[:status] = :candidate
      result
      end
    rescue StandardError => e
      source_error = SourceErrorClassification.from_message(e.message, stage: :archive)
      result[:source_error] = source_error
      result[:status] = source_error ? source_error.fetch("kind").to_sym : :error
      result[:reason] = source_error ? source_error.fetch("reason") : "#{e.class}: #{e.message}"
      result
    end

    def humanize(number)
      return "—" if number.nil?

      number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end

    def print_table(title, headers, rows)
      @out.puts
      @out.puts title
      if rows.empty?
        @out.puts "  (none)"
        return
      end

      widths = headers.each_with_index.map do |header, i|
        ([header] + rows.map { |row| row[i].to_s }).map(&:length).max
      end
      separator = widths.map { |width| "-" * width }.join("-+-")
      @out.puts "  " + headers.each_with_index.map { |header, i| header.ljust(widths[i]) }.join(" | ")
      @out.puts "  " + separator
      rows.each do |row|
        @out.puts "  " + row.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i]) }.join(" | ")
      end
    end

    def note_suffix(result)
      result[:notes].empty? ? "" : "  [#{result[:notes].join('; ')}]"
    end

    def report(results, source, first_rank, last_rank)
      source_errors = results.select { |result| SourceErrorClassification.status?(result[:status]) }
      non_extension_results = %i[no_ext review error].map(&:to_s) + SourceErrorClassification::STATUSES
      with_ext = results.reject { |result| non_extension_results.include?(result[:status].to_s) }
      candidates = with_ext.select { |result| result[:status] == :candidate && !result[:in_corpus] }
      needs_review = with_ext.select { |result| result[:status] == :needs_review && !result[:in_corpus] }
      reviews = results.select { |result| result[:status] == :review && !result[:in_corpus] }
      in_corpus = results.select { |result| result[:in_corpus] && !%i[no_ext error].include?(result[:status]) }
      excluded = with_ext.select { |result| result[:status] == :excluded && !result[:in_corpus] }
      no_ext = results.select { |result| result[:status] == :no_ext }
      errors = results.select { |result| result[:status] == :error }

      @out.puts "=" * 100
      @out.puts "popular-gem C-extension scan"
      @out.puts "  ranking source : #{source::LABEL}"
      if config.timeframe?
        @out.puts "  timeframe      : #{first_rank.iso8601} - #{last_rank.iso8601} (UTC)"
      else
        @out.puts "  rank range     : #{first_rank}-#{last_rank} (pages #{config.first_page}-#{config.last_page} x #{RANKS_PER_PAGE} ranks)"
      end
      @out.puts "  work dir       : #{config.work_dir}"
      @out.puts "  scanned at     : #{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}"
      @out.puts "=" * 100

      print_table(
        "[1] C extension, passes the R10 machine gate, NOT yet in test/corpus/gems.rb (add candidates)",
        %w[rank gem version downloads ext\ .c/.h extensions],
        candidates.sort_by { |result| result[:rank] }.map do |result|
          [result[:rank], result[:name], result[:version], humanize(result[:downloads]),
           "#{result[:c_files]}/#{result[:h_files]}", result[:extensions].join(", ") + note_suffix(result)]
        end
      )

      print_table(
        "[1b] C extension, passes the R10 machine gate, but needs an assembler (verify by hand before adding)",
        %w[rank gem version downloads ext\ .c/.h reason],
        needs_review.sort_by { |result| result[:rank] }.map do |result|
          [result[:rank], result[:name], result[:version], humanize(result[:downloads]),
           "#{result[:c_files]}/#{result[:h_files]}", result[:reason] + note_suffix(result)]
        end
      )

      print_table(
        "[R] review required (not a normal candidate; inspect the recorded reason)",
        %w[rank gem version downloads reason],
        reviews.sort_by { |result| [result[:rank].to_i, result[:name]] }.map do |result|
          [result[:rank], result[:name], result[:version], humanize(result[:downloads]), result[:reason]]
        end
      )

      print_table(
        "[2] C extension, excluded by the R10 machine gate",
        %w[rank gem version downloads reason],
        excluded.sort_by { |result| result[:rank] }.map do |result|
          [result[:rank], result[:name], result[:version], humanize(result[:downloads]), result[:reason] + note_suffix(result)]
        end
      )

      print_table(
        "[3] C extension, already in test/corpus/gems.rb",
        %w[rank gem version downloads gate ext\ .c/.h],
        in_corpus.sort_by { |result| result[:rank] }.map do |result|
          gate = case result[:status]
                 when :candidate then "ok"
                 when :needs_review then "needs assembler: #{result[:reason]}"
                 when :review then "review: #{result[:reason]}"
                 else "excluded: #{result[:reason]}"
                 end
          counts = %i[candidate needs_review review].include?(result[:status]) ? "#{result[:c_files]}/#{result[:h_files]}" : "—"
          [result[:rank], result[:name], result[:version], humanize(result[:downloads]), gate, counts]
        end
      )

      print_table(
        "[E] errors (fetch / unpack / gemspec)",
        %w[rank gem error],
        errors.sort_by { |result| result[:rank] }.map { |result| [result[:rank], result[:name], result[:reason]] }
      )

      print_table(
        "[S] source errors (not candidates; release/archive identity unavailable)",
        %w[rank gem status stage reason],
        source_errors.sort_by { |result| [result[:rank].to_i, result[:name].to_s] }.map do |result|
          [result[:rank], result[:name], result[:status], result.dig(:source_error, "stage"), result[:reason]]
        end
      )

      if config.verbose
        print_table(
          "[0] no C extension (SCAN_VERBOSE)",
          %w[rank gem version],
          no_ext.sort_by { |result| result[:rank] }.map { |result| [result[:rank], result[:name], result[:version]] }
        )
      end

      @out.puts
      @out.puts "-" * 100
      @out.puts "summary"
      scanned_label = config.timeframe? ? "timeframe #{first_rank.iso8601} - #{last_rank.iso8601}" : "ranks #{first_rank}-#{last_rank}"
      @out.puts "  scanned                     : #{results.size} gems (#{scanned_label})"
      @out.puts "  with a C extension          : #{with_ext.size}"
      @out.puts "    add candidates       [1]  : #{candidates.size}#{candidates.empty? ? '' : "  (#{candidates.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "    needs review         [1b] : #{needs_review.size}#{needs_review.empty? ? '' : "  (#{needs_review.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "    review required      [R]  : #{reviews.size}#{reviews.empty? ? '' : "  (#{reviews.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "    R10-excluded         [2]  : #{excluded.size}#{excluded.empty? ? '' : "  (#{excluded.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "    already in corpus    [3]  : #{in_corpus.size}#{in_corpus.empty? ? '' : "  (#{in_corpus.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "  without a C extension       : #{no_ext.size}#{config.verbose ? '' : '  (run with SCAN_VERBOSE=1 to list)'}"
      @out.puts "  errors                      : #{errors.size}#{errors.empty? ? '' : "  (#{errors.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "  source errors               : #{source_errors.size}#{source_errors.empty? ? '' : "  (#{source_errors.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "-" * 100

      errors.size < results.size
    end
  end

  module CLI
    module_function

    def run(argv = ARGV, env = ENV, out: $stdout, err: $stderr)
      config = Configuration.from_env(argv, env)
      Scanner.new(config: config, out: out, err: err).run ? 0 : 1
    rescue ArgumentError => e
      err.puts "argument error: #{e.message}"
      1
    rescue StandardError => e
      err.puts "scan failed (#{e.class}): #{e.message}"
      1
    end
  end
end

exit CorpusCandidateScan::CLI.run if $PROGRAM_NAME == __FILE__
