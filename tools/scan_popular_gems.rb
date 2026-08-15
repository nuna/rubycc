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
#   SCAN_SOURCE=auto|rubygems|bestgems tools/scan_popular_gems.rb
#   SCAN_VERBOSE=1 tools/scan_popular_gems.rb

require "fileutils"
require "json"
require "net/http"
require "rubygems/package"
require "tmpdir"
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

  # The legacy rank mode is deliberately represented as data rather than read
  # from ARGV at load time. This is the boundary that makes the scanner
  # require-able from hermetic tests and from the future timeframe source.
  class Configuration
    attr_reader :first_page, :last_page, :work_dir, :source_choice, :verbose

    def initialize(first_page: 11, last_page: 20, work_dir: DEFAULT_WORK_DIR,
                   source_choice: "auto", verbose: false)
      @first_page = Integer(first_page)
      @last_page = Integer(last_page)
      @work_dir = File.expand_path(work_dir)
      @source_choice = source_choice.to_s.downcase
      @verbose = verbose
      validate!
    end

    def self.from_env(argv = ARGV, env = ENV)
      args = Array(argv)
      raise ArgumentError, "expected at most first_page and last_page" if args.size > 2

      new(
        first_page: args[0] || 11,
        last_page: args[1] || 20,
        work_dir: env.fetch("SCAN_WORK", DEFAULT_WORK_DIR),
        source_choice: env.fetch("SCAN_SOURCE", "auto"),
        verbose: !env.fetch("SCAN_VERBOSE", "").empty?
      )
    end

    private

    def validate!
      raise ArgumentError, "first_page must be >= 1" if @first_page < 1
      if @last_page < @first_page
        raise ArgumentError, "last_page (#{@last_page}) must be >= first_page (#{@first_page})"
      end
      return if %w[auto rubygems bestgems].include?(@source_choice)

      raise ArgumentError,
            "unknown SCAN_SOURCE=#{@source_choice.inspect} (expected auto, rubygems or bestgems)"
    end
  end

  class HttpClient
    def initialize(user_agent: USER_AGENT)
      @user_agent = user_agent
    end

    def get(url, redirect_budget = 5)
      raise "too many redirects while fetching #{url}" if redirect_budget.negative?

      uri = URI.parse(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: 15, read_timeout: 60) do |http|
        http.request(Net::HTTP::Get.new(uri, "User-Agent" => @user_agent))
      end

      case response
      when Net::HTTPSuccess then response.body
      when Net::HTTPRedirection
        get(URI.join(url, response["location"]).to_s, redirect_budget - 1)
      else
        raise "GET #{url} failed: #{response.code} #{response.message}"
      end
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

  # --- assembler detection -------------------------------------------------

  OBJS_VALUE_RE = /(?:%[wW][(\[{][^)\]}]*[)\]}]|\[[^\]]*\]|"[^"]*"|'[^']*')/m
  OBJS_ASSIGN_RE = /\$objs\s*(?:<<|\+=|=)\s*(#{OBJS_VALUE_RE})/m
  OBJS_CONCAT_RE = /\$objs\.concat\(\s*(#{OBJS_VALUE_RE})\s*\)/m
  OBJ_TOKEN_RE = %r{[\w.\-/]+\.o\b}

  module InspectionHelpers
    module_function

    def non_ext_extension_dirs(extensions)
      extensions.map { |extension| File.dirname(extension.to_s) }
                 .reject { |dir| dir == "ext" || dir.start_with?("ext/") }
                 .uniq
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
  end

  class Scanner
    attr_reader :config

    def initialize(config:, http_client: HttpClient.new, sleeper: Kernel.method(:sleep),
                   out: $stdout, err: $stderr,
                   corpus_names: Corpus::Gems::LIST.map { |gem| gem[:name] })
      @config = config
      @http = http_client
      @sleeper = sleeper
      @out = out
      @err = err
      @corpus_names = corpus_names.to_set
      @api_cache_dir = File.join(config.work_dir, "api")
    end

    def run
      first_rank = ((config.first_page - 1) * RANKS_PER_PAGE) + 1
      last_rank = config.last_page * RANKS_PER_PAGE
      step "scanning popularity ranks #{first_rank}-#{last_rank}"
      step "work dir: #{config.work_dir} (downloaded .gem files are cached and reused)"
      FileUtils.mkdir_p(config.work_dir)

      source = select_source(first_rank, last_rank)
      ranking = collect_ranking(source, first_rank, last_rank)
      results = ranking.map do |entry|
        step "inspecting ##{entry[:rank]} #{entry[:name]}"
        inspect_gem(entry)
      end

      report(results, source, first_rank, last_rank)
    end

    private

    def step(message)
      @err.puts "==> #{message}"
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

    def collect_ranking(source, first_rank, last_rank)
      entries = []
      first_page = ((first_rank - 1) / source::PAGE_SIZE) + 1
      last_page = ((last_rank - 1) / source::PAGE_SIZE) + 1

      (first_page..last_page).each do |page|
        expected_first = ((page - 1) * source::PAGE_SIZE) + 1
        step "ranking: #{source.url(page)} (expecting rank #{expected_first}...)"
        result = source.fetch_page(@http, page)

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
      path = File.join(@api_cache_dir, "#{name}.json")
      unless File.file?(path)
        body = @http.get("https://rubygems.org/api/v1/gems/#{URI.encode_www_form_component(name)}.json")
        File.write(path, body)
        @sleeper.call(API_DELAY)
      end
      JSON.parse(File.read(path))["downloads"]
    rescue StandardError => e
      @err.puts "    downloads unavailable for #{name}: #{e.class}: #{e.message}"
      nil
    end

    # Inspect one gem without executing any code from the gem. extconf.rb is
    # read as text for the assembler check; the R10 helpers own the gate.
    def inspect_gem(entry)
      name = entry[:name]
      result = {
        rank: entry[:rank], name: name, version: nil, downloads: nil, extensions: [],
        status: nil, reason: nil, c_files: 0, h_files: 0, notes: [],
        in_corpus: @corpus_names.include?(name)
      }

      gem_path, fetch_error = Corpus::Census.fetch_gem(name, nil, config.work_dir)
      unless gem_path
        result[:status] = :error
        result[:reason] = "gem fetch failed: #{fetch_error.to_s.lines.map(&:strip).reject(&:empty?).last}"
        return result
      end

      spec = Gem::Package.new(gem_path).spec
      result[:version] = spec.version.to_s
      result[:extensions] = spec.extensions.to_a
      if result[:extensions].empty?
        result[:status] = :no_ext
        return result
      end

      result[:downloads] = gem_downloads(name)
      mini_portile = spec.dependencies.select { |dependency| dependency.name.to_s.include?("mini_portile") }
      unless mini_portile.empty?
        result[:notes] << "gemspec depends on #{mini_portile.map { |d| "#{d.name} #{d.requirement}" }.join(', ')}"
      end

      root = Corpus::Census.unpack_gem(gem_path, config.work_dir)
      outside = InspectionHelpers.non_ext_extension_dirs(result[:extensions])
      unless outside.empty?
        extra = outside.sum { |dir| Dir.glob(File.join(root, dir, "**", "*.{c,h,cc,cpp,cxx}")).size }
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

      Corpus::Census.ext_source_files(root).each do |path|
        path.end_with?(".h") ? (result[:h_files] += 1) : (result[:c_files] += 1)
      end

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
        result[:status] = :needs_review
        result[:reason] = findings.join("; ")
        return result
      end

      result[:status] = :candidate
      result
    rescue StandardError => e
      result[:status] = :error
      result[:reason] = "#{e.class}: #{e.message}"
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
      with_ext = results.reject { |result| %i[no_ext error].include?(result[:status]) }
      candidates = with_ext.select { |result| result[:status] == :candidate && !result[:in_corpus] }
      needs_review = with_ext.select { |result| result[:status] == :needs_review && !result[:in_corpus] }
      in_corpus = with_ext.select { |result| result[:in_corpus] }
      excluded = with_ext.select { |result| result[:status] == :excluded && !result[:in_corpus] }
      no_ext = results.select { |result| result[:status] == :no_ext }
      errors = results.select { |result| result[:status] == :error }

      @out.puts "=" * 100
      @out.puts "popular-gem C-extension scan"
      @out.puts "  ranking source : #{source::LABEL}"
      @out.puts "  rank range     : #{first_rank}-#{last_rank} (pages #{config.first_page}-#{config.last_page} x #{RANKS_PER_PAGE} ranks)"
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
                 else "excluded: #{result[:reason]}"
                 end
          counts = %i[candidate needs_review].include?(result[:status]) ? "#{result[:c_files]}/#{result[:h_files]}" : "—"
          [result[:rank], result[:name], result[:version], humanize(result[:downloads]), gate, counts]
        end
      )

      print_table(
        "[E] errors (fetch / unpack / gemspec)",
        %w[rank gem error],
        errors.sort_by { |result| result[:rank] }.map { |result| [result[:rank], result[:name], result[:reason]] }
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
      @out.puts "  scanned                     : #{results.size} gems (ranks #{first_rank}-#{last_rank})"
      @out.puts "  with a C extension          : #{with_ext.size}"
      @out.puts "    add candidates       [1]  : #{candidates.size}#{candidates.empty? ? '' : "  (#{candidates.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "    needs review         [1b] : #{needs_review.size}#{needs_review.empty? ? '' : "  (#{needs_review.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "    R10-excluded         [2]  : #{excluded.size}#{excluded.empty? ? '' : "  (#{excluded.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "    already in corpus    [3]  : #{in_corpus.size}#{in_corpus.empty? ? '' : "  (#{in_corpus.map { |r| r[:name] }.join(', ')})"}"
      @out.puts "  without a C extension       : #{no_ext.size}#{config.verbose ? '' : '  (run with SCAN_VERBOSE=1 to list)'}"
      @out.puts "  errors                      : #{errors.size}#{errors.empty? ? '' : "  (#{errors.map { |r| r[:name] }.join(', ')})"}"
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
