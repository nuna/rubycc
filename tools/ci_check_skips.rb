# frozen_string_literal: true

# CI guard against runaway skips.
#
# Why this exists: a great deal of this suite is differential -- it compiles the
# same source with the system gcc (or the aarch64 cross toolchain, or qemu, or
# pkg-config) and compares against rubycc. Every one of those helpers, except
# gcc itself, skips rather than fails when its tool is missing. That is the
# right behaviour for a developer laptop, but on CI it is a trap: if an apt
# package silently stops being installed, hundreds of tests turn into skips and
# the job still reports green. The suite would then be "passing" while checking
# almost nothing.
#
# So CI reads the Minitest summary line back out of the run log and fails when
# the shape of the run changes: too many skips, or too few runs (a truncated or
# partially-loaded suite). It also prints a histogram of skip reasons, which is
# what you actually want when the numbers move -- it names the missing tool
# instead of leaving you to diff two 3,000-line logs.
#
# Thresholds: the current host measurement is 2,986 runs / 42 skips. The
# rmake-golden path is now logical-path based, so the old CI-only header-path
# skip gap is no longer an expected difference. The values below retain a
# small operational margin while still catching missing toolchains or a
# truncated suite. Re-tighten them whenever the suite's size changes
# meaningfully; acceptance profiles use stable IDs instead of this aggregate
# guard because their run/skip shape is intentionally different.
#
# Usage:
#   ruby tools/ci_check_skips.rb <logfile> [profile]
#
# The log is expected to be the output of `rake test TESTOPTS="--verbose"`.
# Standard library only; no gems, so it runs before/without bundler if needed.

require "json"

DEFAULT_MAX_SKIPS = 55
DEFAULT_MIN_RUNS = 2500
SKIP_PROFILE_PATH = File.expand_path("../config/ci/skip-baseline.json", __dir__).freeze

# The Minitest summary line, e.g.
#   2531 runs, 9204 assertions, 0 failures, 0 errors, 47 skips
SUMMARY_PATTERN = /^\s*(\d+)\s+runs?,\s+(\d+)\s+assertions?,\s+(\d+)\s+failures?,\s+
                   (\d+)\s+errors?,\s+(\d+)\s+skips?/x.freeze

# The header of a Minitest --verbose skip report, e.g. "  1) Skipped:".
SKIP_HEADER_PATTERN = /^\s*\d+\)\s+Skipped:\s*$/.freeze

# The line after the header: "Class#test_name [/path/to/test.rb:12]:".
# Leading whitespace is tolerated; Minitest's indentation has varied.
SKIP_LOCATION_PATTERN = /^\s*\S.*\[[^\]]+\]:\s*$/.freeze

Summary = Struct.new(:runs, :assertions, :failures, :errors, :skips)
SkipEntry = Struct.new(:test_name, :reason)

def die(message)
  warn "ci_check_skips: #{message}"
  exit 1
end

def positive_env(name, default)
  raw = ENV[name]
  return default if raw.nil? || raw.empty?

  value = Integer(raw, exception: false)
  die "#{name} must be a non-negative integer (got #{raw.inspect})" if value.nil? || value.negative?

  value
end

# Exactly one summary is expected: accepting the last one would let a retry or
# a concatenated partial run hide failures/skips from the earlier run.
def find_summary(lines)
  matches = lines.filter_map { |line| SUMMARY_PATTERN.match(line) }
  return nil unless matches.one?

  Summary.new(*matches.first.captures.map { |capture| Integer(capture, 10) })
end

# Collects the reason text of every "N) Skipped:" block. The block is three
# parts: the header, a "Class#test [location]:" line, then the reason, which
# runs until a blank line (Minitest wraps long reasons onto several lines).
def collect_skip_entries(lines)
  entries = []
  index = 0

  while index < lines.length
    unless SKIP_HEADER_PATTERN.match?(lines[index])
      index += 1
      next
    end

    index += 1
    # Tolerate a missing location line rather than losing the whole block.
    location = nil
    if index < lines.length && SKIP_LOCATION_PATTERN.match?(lines[index])
      location = lines[index].strip.sub(/\s+\[[^\]]+\]:\z/, "")
      index += 1
    end

    reason = []
    while index < lines.length && !lines[index].strip.empty? && !SKIP_HEADER_PATTERN.match?(lines[index])
      reason << lines[index].strip
      index += 1
    end

    entries << SkipEntry.new(location, reason.join(" ")) unless reason.empty?
  end

  entries
end

def collect_skip_reasons(lines)
  collect_skip_entries(lines).map(&:reason)
end

# Skip reasons often carry a temp path or a pid, which would otherwise split one
# cause into dozens of histogram rows. Collapse those to placeholders so the
# histogram groups by cause.
def normalize_reason(reason)
  reason
    .gsub(%r{(?<![\w/])/[\w./+-]+}, "<path>")
    .gsub(/\d+/, "<n>")
end

def build_histogram(reasons)
  buckets = Hash.new { |hash, key| hash[key] = { count: 0, example: nil } }
  reasons.each do |reason|
    bucket = buckets[normalize_reason(reason)]
    bucket[:count] += 1
    bucket[:example] ||= reason
  end
  buckets.sort_by { |key, bucket| [-bucket[:count], key] }
end

def print_histogram(histogram, total_skips)
  if histogram.empty?
    if total_skips.positive?
      puts "note: could not parse any --verbose skip detail block " \
           "(was the run made with TESTOPTS=\"--verbose\"?); checking counts only"
    else
      puts "skip reasons: (none)"
    end
    return
  end

  puts "skip reasons (#{histogram.sum { |_key, bucket| bucket[:count] }} parsed of #{total_skips} reported):"
  width = histogram.first[1][:count].to_s.length
  histogram.each do |key, bucket|
    puts format("  %*d  %s", width, bucket[:count], key)
    puts format("  %*s  e.g. %s", width, "", bucket[:example]) if bucket[:example] != key
  end
end

def read_skip_profile(name)
  return nil if name.nil? || name.empty? || name == "default"

  unless File.file?(SKIP_PROFILE_PATH)
    die "skip profile #{name.inspect} requested but #{SKIP_PROFILE_PATH} is missing"
  end

  profiles = JSON.parse(File.read(SKIP_PROFILE_PATH)).fetch("profiles")
  profiles.fetch(name)
rescue JSON::ParserError, KeyError => e
  die "invalid or unknown skip profile #{name.inspect}: #{e.message}"
end

def profile_skip_problems(entries, profile)
  rules = profile.fetch("allowed_skips").map do |rule|
    {
      test_pattern: Regexp.new(rule.fetch("test_pattern")),
      reason: rule.fetch("reason"),
      max_count: Integer(rule.fetch("max_count")),
      min_count: Integer(rule.fetch("min_count", 0))
    }
  rescue RegexpError, ArgumentError, KeyError => e
    die "invalid skip profile rule: #{e.message}"
  end

  counts = Array.new(rules.length, 0)
  problems = []
  entries.each do |entry|
    matches = rules.each_index.select do |index|
      rule = rules[index]
      rule[:test_pattern].match?(entry.test_name.to_s) && normalize_reason(entry.reason) == rule[:reason]
    end

    if matches.empty?
      problems << "unapproved skip #{entry.test_name.inspect}: #{normalize_reason(entry.reason).inspect}"
      next
    end

    if matches.length > 1
      problems << "skip manifest rules overlap for #{entry.test_name.inspect}: #{matches.inspect}"
      next
    end

    counts[matches.fetch(0)] += 1
  end

  rules.each_with_index do |rule, index|
    count = counts[index]
    if count < rule[:min_count]
      problems << "skip rule #{index} matched #{count} times, below min_count=#{rule[:min_count]}"
    elsif count > rule[:max_count]
      problems << "skip rule #{index} matched #{count} times, above max_count=#{rule[:max_count]}"
    end
  end

  expected = profile["expected_skips"]
  if expected && entries.length != expected
    problems << "profile expected_skips=#{expected}, got #{entries.length}"
  end

  problems
end

def main(argv)
  # Keep the report and the failure lines in order when CI merges the two streams.
  $stdout.sync = true
  $stderr.sync = true

  die "usage: ruby tools/ci_check_skips.rb <logfile> [profile]" unless (1..2).cover?(argv.length)

  path = argv[0]
  profile_name = argv[1] || ENV.fetch("CI_SKIP_PROFILE", "default")
  profile = read_skip_profile(profile_name)
  die "cannot read log file: #{path}" unless File.file?(path) && File.readable?(path)

  # CI logs mix tool output of unknown encoding; read as binary and scrub so a
  # stray byte cannot abort the guard itself.
  lines = File.read(path, mode: "rb").force_encoding(Encoding::UTF_8).scrub("?").lines

  summary = find_summary(lines)
  if summary.nil?
    die "expected exactly one Minitest summary line in #{path} " \
        "(the run probably died, was retried, or was concatenated; check the log)"
  end

  configured_max_skips = positive_env("CI_MAX_SKIPS", DEFAULT_MAX_SKIPS)
  configured_min_runs = positive_env("CI_MIN_RUNS", DEFAULT_MIN_RUNS)
  # A named profile is the checked-in contract for that runner. An explicit
  # environment override may tighten it for a local/CI diagnostic, but an
  # unset (or empty) override must not accidentally replace the profile with
  # the x86 default. In particular, the native profile legitimately contains
  # more than the default x86-only skip budget because it records exact
  # architecture-specific fixtures.
  max_skips = if profile
                profile_max = Integer(profile.fetch("max_skips"))
                raw = ENV["CI_MAX_SKIPS"]
                raw.nil? || raw.empty? ? profile_max : [configured_max_skips, profile_max].min
              else
                configured_max_skips
              end
  min_runs = if profile
               profile_min = Integer(profile.fetch("min_runs"))
               raw = ENV["CI_MIN_RUNS"]
               raw.nil? || raw.empty? ? profile_min : [configured_min_runs, profile_min].max
             else
               configured_min_runs
             end

  puts "log: #{path}"
  puts "skip profile: #{profile_name}"
  puts "summary: #{summary.runs} runs, #{summary.assertions} assertions, " \
       "#{summary.failures} failures, #{summary.errors} errors, #{summary.skips} skips"
  print_histogram(build_histogram(collect_skip_reasons(lines)), summary.skips)

  problems = []
  problems << "#{summary.failures} failures reported" if summary.failures.positive?
  problems << "#{summary.errors} errors reported" if summary.errors.positive?
  problems << "#{summary.skips} skips exceeds CI_MAX_SKIPS=#{max_skips}; " \
              "an external tool is probably missing (see histogram above)" if summary.skips > max_skips
  problems << "#{summary.runs} runs is below CI_MIN_RUNS=#{min_runs}; " \
              "the suite did not load or finish completely" if summary.runs < min_runs

  if profile
    entries = collect_skip_entries(lines)
    problems.concat(profile_skip_problems(entries, profile))
    problems << "only #{entries.length}/#{summary.skips} skip details were parsed" if entries.length != summary.skips
  end

  unless problems.empty?
    puts
    problems.each { |problem| warn "ci_check_skips: FAIL: #{problem}" }
    exit 1
  end

  puts
  puts "ci_check_skips: OK (profile=#{profile_name}, skips <= #{max_skips}, runs >= #{min_runs})"
  exit 0
end

main(ARGV) if $PROGRAM_NAME == __FILE__
