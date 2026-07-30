#!/usr/bin/env ruby
# frozen_string_literal: true

# Mechanically find C-extension gems among the most popular gems on rubygems.org.
#
# test/corpus/gems.rb documents (Step 119) how the popular-gems part of the corpus
# was picked: fetch every gem on the popular ranking, inspect each *downloaded*
# .gem's gemspec `extensions`, and keep the ones that pass R10. That was done by
# hand and left no tool behind; this script is that procedure, repeatable.
#
# The one trap worth repeating: `gem specification --remote <name> extensions`
# always answers empty, because rubygems.org's quick index serves `extensions`
# and `files` empty (true even for nokogiri). The only reliable source is the
# gemspec inside the downloaded .gem, which is what this tool reads.
#
# The R10 gate is NOT reimplemented here: test/corpus/census.rb owns it and this
# tool calls into it (Census.ext_cpp_files / read_extconf / configure_dependency?),
# so a candidate reported here gets the same verdict from `rake corpus:census`.
#
# R10 passing is not the same as "buildable by rubycc": R10's machine gate only
# looks for C++ sources and a configure/mini_portile dependency, because that is
# all R10 (pure-C extensions) is about. It has no notion of "requires an
# assembler" -- rubycc simply has no assembler backend, which is a separate,
# tool-specific reason a gem cannot build here. bcrypt is the case that exposed
# this gap: its ext/ tree is pure C (no .cpp, no configure), so it sails through
# the R10 gate -- but its extconf.rb assigns
#   $objs = %w(bcrypt_ext.o crypt_blowfish.o x86.o crypt_gensalt.o wrapper.o)
# and there is no x86.c anywhere in the gem, because x86.o is built from the
# bundled ext/mri/x86.S, which a .S/.s file scan also finds -- measured, both
# checks flag bcrypt. ffi is the case that needs the file scan on its own: it
# bundles 48 .S files under ext/ffi_c/libffi that never appear in $objs at all
# (its build compiles them some other way), so the $objs check alone would miss
# it. The reverse case -- an $objs entry whose assembly source is generated, or
# named differently -- is exactly what the $objs check covers, so this tool runs
# both, never just one. Both gems
# were found by hand in Step 139; the checks below (see "assembler detection")
# are that discovery made automatic and repeatable, without touching
# test/corpus/census.rb's R10 semantics.
#
# Ranking sources
#   rubygems — https://rubygems.org/releases/popular?page=N (10 gems/page).
#              Hard-capped by the site at 100 gems / 10 pages: page 11 and beyond
#              silently serve page 1 again, so the tool verifies the rank window
#              the page reports about itself and refuses to scan past the cap.
#   bestgems — https://bestgems.org/total?page=N (20 gems/page), the all-time
#              download ranking over every gem, used for ranks beyond 100 where
#              rubygems.org exposes no ranking at all. Its counts track
#              rubygems.org's own `downloads` field (a day or so behind).
#
# Pages are always 10 ranks wide regardless of source, so page N means ranks
# (N-1)*10+1 .. N*10 and pages 1..10 mean the same gems the site's own popular
# pages 1..10 show.
#
# Usage:
#   tools/scan_popular_gems.rb [first_page] [last_page]   # default 11 20
#   SCAN_WORK=/path/to/work tools/scan_popular_gems.rb    # .gem cache (default: tmpdir)
#   SCAN_SOURCE=auto|rubygems|bestgems tools/scan_popular_gems.rb
#   SCAN_VERBOSE=1 tools/scan_popular_gems.rb             # also list the no-extension gems

require "fileutils"
require "json"
require "net/http"
require "rubygems/package"
require "tmpdir"
require "uri"

RUBYCC_ROOT = File.expand_path("..", __dir__)

# Brings in Corpus::Census (the R10 gate + gem fetch/unpack helpers) and, via its
# own require_relative, Corpus::Gems::LIST (the committed corpus membership).
require File.join(RUBYCC_ROOT, "test/corpus/census")

FIRST_PAGE = Integer(ARGV[0] || 11)
LAST_PAGE = Integer(ARGV[1] || 20)
WORK_DIR = File.expand_path(ENV["SCAN_WORK"] || File.join(Dir.tmpdir, "rubycc_scan_popular"))
SOURCE_CHOICE = (ENV["SCAN_SOURCE"] || "auto").downcase
VERBOSE = !(ENV["SCAN_VERBOSE"] || "").empty?

RANKS_PER_PAGE = 10
USER_AGENT = "rubycc-scan-popular-gems (https://github.com/nuna/rubycc)"
PAGE_DELAY = 1.0  # between ranking pages -- be a good citizen
API_DELAY = 0.2   # between rubygems.org API calls
RUBYGEMS_POPULAR_CAP = 100 # gems, as advertised by the page itself

CORPUS_NAMES = Corpus::Gems::LIST.map { |g| g[:name] }.freeze

def step(msg)
  warn "==> #{msg}"
end

# --- HTTP ------------------------------------------------------------------

def http_get(url, redirect_budget = 5)
  raise "too many redirects while fetching #{url}" if redirect_budget.negative?

  uri = URI.parse(url)
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                             open_timeout: 15, read_timeout: 60) do |http|
    http.request(Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT))
  end

  case response
  when Net::HTTPSuccess then response.body
  when Net::HTTPRedirection then http_get(URI.join(url, response["location"]).to_s, redirect_budget - 1)
  else raise "GET #{url} failed: #{response.code} #{response.message}"
  end
end

# --- ranking sources -------------------------------------------------------
#
# Each source exposes page_size, label and fetch_page(page) -> {entries:, first:,
# last:, total:}. `entries` is [{rank:, name:}] in ranking order. A page that
# cannot be parsed raises: zero gems never means "no popular gems", it means the
# HTML changed and every downstream conclusion would be silently wrong.

module RubygemsPopular
  PAGE_SIZE = 10
  LABEL = "rubygems.org /releases/popular"

  # <p ... data-testid="entries-info">Displaying rubygems <b>1&nbsp;-&nbsp;10</b> of <b>100</b> in total</p>
  ENTRIES_INFO_RE = /data-testid="entries-info"[^>]*>(.*?)<\/p>/m
  GEM_LINK_RE = %r{href="/gems/([^"/?#]+)"}

  module_function

  def url(page)
    "https://rubygems.org/releases/popular?page=#{page}"
  end

  def fetch_page(page)
    html = http_get(url(page))

    info = html[ENTRIES_INFO_RE, 1]
    raise "#{url(page)}: no entries-info element -- the page layout changed" unless info

    numbers = info.scan(%r{<b>(.*?)</b>}m).flatten
    raise "#{url(page)}: cannot read the rank window from #{info.inspect}" unless numbers.size == 2

    window = numbers[0].gsub("&nbsp;", " ").split("-").map { |s| Integer(s.strip.delete(",")) }
    raise "#{url(page)}: cannot read the rank window from #{info.inspect}" unless window.size == 2

    total = Integer(numbers[1].strip.delete(","))
    names = html.scan(GEM_LINK_RE).flatten.map { |n| URI.decode_www_form_component(n) }
    raise "#{url(page)}: no gem links found -- the page layout changed" if names.empty?
    raise "#{url(page)}: duplicate gem links #{names.tally.select { |_, c| c > 1 }.keys.inspect}" if names.uniq.size != names.size

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

  # <tr><td class="right">1</td><td class="right">3,594,939,758</td><td><a href="/gems/bundler">
  ROW_RE = %r{<tr><td class="right">(\d+)</td><td class="right">([\d,]+)</td><td><a href="/gems/([^"]+)">}
  # <em class="numeric">1</em>-<em class="numeric">20</em> of all <em class="numeric">195,429</em> gems.
  HEADER_RE = %r{<em class="numeric">([\d,]+)</em>-<em class="numeric">([\d,]+)</em> of all <em class="numeric">([\d,]+)</em> gems}

  module_function

  def url(page)
    "https://bestgems.org/total?page=#{page}"
  end

  def fetch_page(page)
    html = http_get(url(page))

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

def select_source(first_rank, last_rank)
  case SOURCE_CHOICE
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
  else
    abort "unknown SCAN_SOURCE=#{SOURCE_CHOICE.inspect} (expected auto, rubygems or bestgems)"
  end
end

# Walk the source's pages covering [first_rank, last_rank] and return the slice.
# Every page is cross-checked against the rank window it advertises, so the
# silent page-1 wraparound rubygems.org does past its cap becomes a hard error.
def collect_ranking(source, first_rank, last_rank)
  entries = []
  first_page = ((first_rank - 1) / source::PAGE_SIZE) + 1
  last_page = ((last_rank - 1) / source::PAGE_SIZE) + 1

  (first_page..last_page).each do |page|
    expected_first = ((page - 1) * source::PAGE_SIZE) + 1
    step "ranking: #{source.url(page)} (expecting rank #{expected_first}...)"
    result = source.fetch_page(page)

    if last_rank > result[:total]
      raise "#{source::LABEL} ranks only #{result[:total]} gems; ranks up to #{last_rank} were requested"
    end
    unless result[:first] == expected_first
      raise "#{source.url(page)}: expected the page to start at rank #{expected_first} " \
            "but it reports #{result[:first]} -- the site paginates differently than assumed"
    end

    entries.concat(result[:entries])
    sleep PAGE_DELAY unless page == last_page
  end

  slice = entries.select { |e| e[:rank].between?(first_rank, last_rank) }
  unless slice.size == last_rank - first_rank + 1
    raise "collected #{slice.size} gems for ranks #{first_rank}-#{last_rank} " \
          "(expected #{last_rank - first_rank + 1})"
  end
  slice
end

# --- per-gem inspection ----------------------------------------------------

API_CACHE_DIR = File.join(WORK_DIR, "api")

# Total downloads from rubygems.org's API. Cached on disk so re-runs stay off
# the network; nil (with a note) when the gem has no API entry.
def gem_downloads(name)
  FileUtils.mkdir_p(API_CACHE_DIR)
  path = File.join(API_CACHE_DIR, "#{name}.json")
  unless File.file?(path)
    body = http_get("https://rubygems.org/api/v1/gems/#{URI.encode_www_form_component(name)}.json")
    File.write(path, body)
    sleep API_DELAY
  end
  JSON.parse(File.read(path))["downloads"]
rescue StandardError => e
  warn "    downloads unavailable for #{name}: #{e.class}: #{e.message}"
  nil
end

# Extension directories declared by the gemspec that live outside ext/. The
# census helpers only look under ext/, so such a gem would otherwise be reported
# as "0 .c files" with no explanation.
def non_ext_extension_dirs(extensions)
  extensions.map { |e| File.dirname(e.to_s) }
            .reject { |d| d == "ext" || d.start_with?("ext/") }
            .uniq
end

# --- assembler detection ----------------------------------------------------
#
# rubycc has no assembler backend, so a gem that needs one cannot build here
# even after clearing the R10 machine gate (R10 only cares about C++ sources
# and configure/mini_portile, not assembly). Two independent checks are run
# because either alone can miss a gem -- see the header comment above for the
# measured bcrypt/ffi cases.

# The right-hand side of an $objs assignment: a %w/%W literal, an array literal,
# or a single quoted string.
OBJS_VALUE_RE = /(?:%[wW][(\[{][^)\]}]*[)\]}]|\[[^\]]*\]|"[^"]*"|'[^']*')/m
OBJS_ASSIGN_RE = /\$objs\s*(?:<<|\+=|=)\s*(#{OBJS_VALUE_RE})/m
OBJS_CONCAT_RE = /\$objs\.concat\(\s*(#{OBJS_VALUE_RE})\s*\)/m
OBJ_TOKEN_RE = %r{[\w.\-/]+\.o\b}

# .S/.s files anywhere under ext/ and any extension dirs living outside ext/
# (the latter via `dirs`, already computed from the gemspec's `extensions` by
# non_ext_extension_dirs). Returned as paths relative to root.
def assembly_source_files(root, dirs)
  files = (["ext"] + dirs).flat_map { |d| Dir.glob(File.join(root, d, "**", "*.{S,s}")) }
  files.map { |p| p.sub(%r{\A#{Regexp.escape(root)}/}, "") }.uniq.sort
end

# Object-file basenames (without ".o") referenced by $objs in extconf.rb text:
# %w/%W literals, quoted-string array literals, and << / += / .concat(...) appends.
def objs_basenames(extconf_text)
  values = extconf_text.scan(OBJS_ASSIGN_RE).flatten + extconf_text.scan(OBJS_CONCAT_RE).flatten
  values.flat_map { |v| v.scan(OBJ_TOKEN_RE) }.map { |t| File.basename(t, ".o") }.uniq
end

# $objs entries with no matching <base>.c anywhere in the gem tree, each noting
# whether a bundled <base>.S/.s explains it (built from assembly instead).
def objs_missing_c_source(root, bases)
  bases.filter_map do |base|
    next unless Dir.glob(File.join(root, "**", "#{base}.c")).empty?
    asm = !Dir.glob(File.join(root, "**", "#{base}.{S,s}")).empty?
    { base: base, asm: asm }
  end
end

# Inspect one gem: fetch the .gem (cached), read its real gemspec, and -- only
# when it declares an extension -- unpack it and run the census R10 gate.
# Never raises: any failure is recorded as :error and the scan continues.
def inspect_gem(entry)
  name = entry[:name]
  result = {
    rank: entry[:rank], name: name, version: nil, downloads: nil, extensions: [],
    status: nil, reason: nil, c_files: 0, h_files: 0, notes: [],
    in_corpus: CORPUS_NAMES.include?(name)
  }

  gem_path, fetch_error = Corpus::Census.fetch_gem(name, nil, WORK_DIR)
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

  mini_portile = spec.dependencies.select { |d| d.name.to_s.include?("mini_portile") }
  unless mini_portile.empty?
    result[:notes] << "gemspec depends on #{mini_portile.map { |d| "#{d.name} #{d.requirement}" }.join(', ')}"
  end

  root = Corpus::Census.unpack_gem(gem_path, WORK_DIR)

  outside = non_ext_extension_dirs(result[:extensions])
  unless outside.empty?
    extra = outside.sum { |d| Dir.glob(File.join(root, d, "**", "*.{c,h,cc,cpp,cxx}")).size }
    result[:notes] << "extension(s) outside ext/: #{outside.join(', ')} " \
                      "(#{extra} C/C++ files there are not covered by the census helpers)"
  end

  # R10 gate -- verdict delegated to test/corpus/census.rb, not reimplemented.
  cpp = Corpus::Census.ext_cpp_files(root)
  unless cpp.empty?
    names = cpp.map { |p| File.basename(p) }.uniq.sort
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

  # rubycc has no assembler backend: run both assembler checks (see the
  # "assembler detection" section above for why neither alone is sufficient).
  findings = []

  asm_files = assembly_source_files(root, outside)
  unless asm_files.empty?
    shown = asm_files.first(3).join(", ")
    shown += ", ... (#{asm_files.size} files)" if asm_files.size > 3
    # The paths are relative to the gem root, so they say for themselves which
    # extension dir each one came from (ext/ or one of `outside`).
    findings << "#{asm_files.size} assembly source#{asm_files.size == 1 ? '' : 's'} bundled (#{shown})"
  end

  missing_objs = objs_missing_c_source(root, objs_basenames(extconf_text))
  unless missing_objs.empty?
    findings << missing_objs.map { |m|
      suffix = m[:asm] ? " (built from bundled #{m[:base]}.S)" : ""
      "$objs lists #{m[:base]}.o with no #{m[:base]}.c#{suffix}"
    }.join("; ")
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

# --- reporting -------------------------------------------------------------

def humanize(number)
  return "—" if number.nil?

  number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end

def print_table(title, headers, rows)
  puts
  puts title
  if rows.empty?
    puts "  (none)"
    return
  end

  widths = headers.each_with_index.map do |h, i|
    ([h] + rows.map { |r| r[i].to_s }).map(&:length).max
  end
  sep = widths.map { |w| "-" * w }.join("-+-")
  puts "  " + headers.each_with_index.map { |h, i| h.ljust(widths[i]) }.join(" | ")
  puts "  " + sep
  rows.each do |row|
    puts "  " + row.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join(" | ")
  end
end

def note_suffix(result)
  result[:notes].empty? ? "" : "  [#{result[:notes].join('; ')}]"
end

def report(results, source, first_rank, last_rank)
  with_ext = results.reject { |r| r[:status] == :no_ext || r[:status] == :error }
  candidates = with_ext.select { |r| r[:status] == :candidate && !r[:in_corpus] }
  needs_review = with_ext.select { |r| r[:status] == :needs_review && !r[:in_corpus] }
  in_corpus = with_ext.select { |r| r[:in_corpus] }
  excluded = with_ext.select { |r| r[:status] == :excluded && !r[:in_corpus] }
  no_ext = results.select { |r| r[:status] == :no_ext }
  errors = results.select { |r| r[:status] == :error }

  puts "=" * 100
  puts "popular-gem C-extension scan"
  puts "  ranking source : #{source::LABEL}"
  puts "  rank range     : #{first_rank}-#{last_rank} (pages #{FIRST_PAGE}-#{LAST_PAGE} x #{RANKS_PER_PAGE} ranks)"
  puts "  work dir       : #{WORK_DIR}"
  puts "  scanned at     : #{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}"
  puts "=" * 100

  print_table(
    "[1] C extension, passes the R10 machine gate, NOT yet in test/corpus/gems.rb (add candidates)",
    %w[rank gem version downloads ext\ .c/.h extensions],
    candidates.sort_by { |r| r[:rank] }.map do |r|
      [r[:rank], r[:name], r[:version], humanize(r[:downloads]),
       "#{r[:c_files]}/#{r[:h_files]}", r[:extensions].join(", ") + note_suffix(r)]
    end
  )

  print_table(
    "[1b] C extension, passes the R10 machine gate, but needs an assembler (verify by hand before adding)",
    %w[rank gem version downloads ext\ .c/.h reason],
    needs_review.sort_by { |r| r[:rank] }.map do |r|
      [r[:rank], r[:name], r[:version], humanize(r[:downloads]),
       "#{r[:c_files]}/#{r[:h_files]}", r[:reason] + note_suffix(r)]
    end
  )

  print_table(
    "[2] C extension, excluded by the R10 machine gate",
    %w[rank gem version downloads reason],
    excluded.sort_by { |r| r[:rank] }.map do |r|
      [r[:rank], r[:name], r[:version], humanize(r[:downloads]), r[:reason] + note_suffix(r)]
    end
  )

  print_table(
    "[3] C extension, already in test/corpus/gems.rb",
    %w[rank gem version downloads gate ext\ .c/.h],
    in_corpus.sort_by { |r| r[:rank] }.map do |r|
      gate =
        case r[:status]
        when :candidate then "ok"
        when :needs_review then "needs assembler: #{r[:reason]}"
        else "excluded: #{r[:reason]}"
        end
      counts = %i[candidate needs_review].include?(r[:status]) ? "#{r[:c_files]}/#{r[:h_files]}" : "—"
      [r[:rank], r[:name], r[:version], humanize(r[:downloads]), gate, counts]
    end
  )

  print_table(
    "[E] errors (fetch / unpack / gemspec)",
    %w[rank gem error],
    errors.sort_by { |r| r[:rank] }.map { |r| [r[:rank], r[:name], r[:reason]] }
  )

  if VERBOSE
    print_table(
      "[0] no C extension (SCAN_VERBOSE)",
      %w[rank gem version],
      no_ext.sort_by { |r| r[:rank] }.map { |r| [r[:rank], r[:name], r[:version]] }
    )
  end

  puts
  puts "-" * 100
  puts "summary"
  puts "  scanned                     : #{results.size} gems (ranks #{first_rank}-#{last_rank})"
  puts "  with a C extension          : #{with_ext.size}"
  puts "    add candidates       [1]  : #{candidates.size}#{candidates.empty? ? '' : "  (#{candidates.map { |r| r[:name] }.join(', ')})"}"
  puts "    needs review         [1b] : #{needs_review.size}#{needs_review.empty? ? '' : "  (#{needs_review.map { |r| r[:name] }.join(', ')})"}"
  puts "    R10-excluded         [2]  : #{excluded.size}#{excluded.empty? ? '' : "  (#{excluded.map { |r| r[:name] }.join(', ')})"}"
  puts "    already in corpus    [3]  : #{in_corpus.size}#{in_corpus.empty? ? '' : "  (#{in_corpus.map { |r| r[:name] }.join(', ')})"}"
  puts "  without a C extension       : #{no_ext.size}#{VERBOSE ? '' : '  (run with SCAN_VERBOSE=1 to list)'}"
  puts "  errors                      : #{errors.size}#{errors.empty? ? '' : "  (#{errors.map { |r| r[:name] }.join(', ')})"}"
  puts "-" * 100

  errors.size < results.size
end

# --- main ------------------------------------------------------------------

abort "first_page must be >= 1" if FIRST_PAGE < 1
abort "last_page (#{LAST_PAGE}) must be >= first_page (#{FIRST_PAGE})" if LAST_PAGE < FIRST_PAGE

first_rank = ((FIRST_PAGE - 1) * RANKS_PER_PAGE) + 1
last_rank = LAST_PAGE * RANKS_PER_PAGE

step "scanning popularity ranks #{first_rank}-#{last_rank}"
step "work dir: #{WORK_DIR} (downloaded .gem files are cached and reused)"
FileUtils.mkdir_p(WORK_DIR)

source = select_source(first_rank, last_rank)
# A ranking failure is fatal on purpose: an empty or wrong ranking would turn
# every conclusion below it into a confident lie.
ranking =
  begin
    collect_ranking(source, first_rank, last_rank)
  rescue StandardError => e
    abort "ranking scrape failed (#{e.class}): #{e.message}"
  end

results = ranking.map do |entry|
  step "inspecting ##{entry[:rank]} #{entry[:name]}"
  inspect_gem(entry)
end

ok = report(results, source, first_rank, last_rank)
exit(ok ? 0 : 1)
