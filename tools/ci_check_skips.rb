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
# Thresholds: CI_MAX_SKIPS / CI_MIN_RUNS below are tightened to the numbers
# the first green run on CI actually measured: 2,547 runs / 52 skips on CI,
# versus 2,547 runs / 47 skips on a developer machine. The 5-skip gap between
# the two splits into two independent effects, not one:
#   -1  CI has a real `pkg-config` binary installed, so
#       test_matches_real_pkg_config_for_zlib runs instead of skipping.
#   +6  test_rmake_golden.rb's `make -n` comparison skips on CI: its fixture
#       Makefile embeds this development machine's absolute Ruby header path,
#       which does not exist on the CI runner. That is a structural
#       difference the CI environment cannot resolve by itself.
# The thresholds below are that measurement plus a small margin (skips 52 ->
# 55, runs 2,547 -> 2,500) rather than the measurement itself, so that adding
# tests over time does not immediately trip CI_MIN_RUNS (more tests only ever
# raise the run count) while still catching a real regression rather than
# only a catastrophic one. Re-tighten these whenever the suite's size changes
# meaningfully.
#
# Usage:
#   ruby tools/ci_check_skips.rb <logfile>
#
# The log is expected to be the output of `rake test TESTOPTS="--verbose"`.
# Standard library only; no gems, so it runs before/without bundler if needed.

DEFAULT_MAX_SKIPS = 55
DEFAULT_MIN_RUNS = 2500

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

# The last summary line wins: `rake test` prints one summary per run, and a
# retried or multi-process invocation would leave earlier ones in the log.
def find_summary(lines)
  match = nil
  lines.each do |line|
    found = SUMMARY_PATTERN.match(line)
    match = found if found
  end
  return nil if match.nil?

  Summary.new(*match.captures.map { |capture| Integer(capture, 10) })
end

# Collects the reason text of every "N) Skipped:" block. The block is three
# parts: the header, a "Class#test [location]:" line, then the reason, which
# runs until a blank line (Minitest wraps long reasons onto several lines).
def collect_skip_reasons(lines)
  reasons = []
  index = 0

  while index < lines.length
    unless SKIP_HEADER_PATTERN.match?(lines[index])
      index += 1
      next
    end

    index += 1
    # Tolerate a missing location line rather than losing the whole block.
    index += 1 if index < lines.length && SKIP_LOCATION_PATTERN.match?(lines[index])

    reason = []
    while index < lines.length && !lines[index].strip.empty? && !SKIP_HEADER_PATTERN.match?(lines[index])
      reason << lines[index].strip
      index += 1
    end

    reasons << reason.join(" ") unless reason.empty?
  end

  reasons
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

def main(argv)
  # Keep the report and the failure lines in order when CI merges the two streams.
  $stdout.sync = true
  $stderr.sync = true

  die "usage: ruby tools/ci_check_skips.rb <logfile>" unless argv.length == 1

  path = argv[0]
  die "cannot read log file: #{path}" unless File.file?(path) && File.readable?(path)

  # CI logs mix tool output of unknown encoding; read as binary and scrub so a
  # stray byte cannot abort the guard itself.
  lines = File.read(path, mode: "rb").force_encoding(Encoding::UTF_8).scrub("?").lines

  summary = find_summary(lines)
  if summary.nil?
    die "no Minitest summary line found in #{path} " \
        "(the run probably died before finishing; check the log tail)"
  end

  max_skips = positive_env("CI_MAX_SKIPS", DEFAULT_MAX_SKIPS)
  min_runs = positive_env("CI_MIN_RUNS", DEFAULT_MIN_RUNS)

  puts "log: #{path}"
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

  unless problems.empty?
    puts
    problems.each { |problem| warn "ci_check_skips: FAIL: #{problem}" }
    exit 1
  end

  puts
  puts "ci_check_skips: OK (skips <= #{max_skips}, runs >= #{min_runs})"
  exit 0
end

main(ARGV) if $PROGRAM_NAME == __FILE__
