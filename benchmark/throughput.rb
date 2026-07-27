#!/usr/bin/env ruby
# frozen_string_literal: true

# Compile-throughput benchmark (Step 105, M5 H5) -- requirement N1.
#
# Measures how many preprocessed lines per second the compiler sustains on the
# C sources of real gems (json / msgpack / bigdecimal), in-process and warm, so
# the number reflects the compiler itself rather than Ruby startup. Each gem's
# extconf.rb is run once **through the mkmf shim** (the same conftest-via-rubycc
# path a `RUBYCC=1 gem install` takes) to obtain the exact -D set such an
# install would produce — running extconf under gcc instead would enable
# feature macros (e.g. bigdecimal's HAVE_RUBY_ATOMIC_H) that rubycc's own
# conftests reject, and the benchmark would then compile sources no real
# install compiles. Every .c of the extension is then compiled with
# Rubycc::Compiler the way the install would compile it (same defines, same
# include path, -fPIC).
#
# Two figures are reported per file:
#   * the headline: preprocessed lines / median wall time of a full compile
#     (source -> ELF object), after one discarded warmup;
#   * a one-shot stage breakdown (preprocess / tokenize / parse / IR) taken
#     separately, so a regression can be attributed without re-profiling.
#
# "Preprocessed lines" is the number of distinct physical (file, line) pairs
# that contribute at least one token to the phase-4 output — the lines of the
# translation unit that survive preprocessing, close to what `rubycc -E`
# emits. Counted once per file.
#
# YJIT is enabled when the host Ruby supports it (BENCH_YJIT=0 opts out); the
# report records whether it was active, because N1's acceptance (20,000
# lines/sec median) is defined with YJIT on.
#
# Each file is also compiled once with `gcc -O0` (same include paths / -D set
# / -fPIC as the rubycc compile) to give the N1 target an external reference
# point, using the same "preprocessed lines" denominator as rubycc so the two
# columns' ratio is directly comparable. This gcc figure is a wall-clock
# process invocation (fork+exec `gcc` once per sample), whereas the rubycc
# figure above is measured in-process after a warm JIT/require -- the two are
# NOT apples-to-apples in absolute terms, only the ratio is informative. See
# BENCH_GCC below to skip it.
#
# Deliberately NOT part of `rake test`: it fetches gems from rubygems.org and
# takes minutes. Run via `rake bench:throughput`.
#
# Usage:
#   ruby benchmark/throughput.rb            # 3 timed compiles per file
#   BENCH_RUNS=5 ruby benchmark/throughput.rb
#   BENCH_YJIT=0 ruby benchmark/throughput.rb
#   BENCH_GCC=0 ruby benchmark/throughput.rb        # skip the gcc -O0 reference
#   BENCH_WORK=/path ruby benchmark/throughput.rb   # gem staging dir

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
BENCH_DIR = __dir__
$LOAD_PATH.unshift File.join(ROOT, "lib")
require "rubycc/compiler"

RUNS = Integer(ENV["BENCH_RUNS"] || 3)
WORK = File.expand_path(ENV["BENCH_WORK"] || "/tmp/rubycc_bench")
TARGET_LINES_PER_SEC = 20_000

# The measured corpus: each entry is one extension directory. Versions are pinned
# so successive runs measure the same source and stay comparable over time.
# `env` seeds the extconf run (json: SIMD off -- rubycc has no SSE intrinsics,
# and a real RUBYCC=1 install builds the same scalar paths).
WORKLOADS = [
  { gem: "json", version: "2.21.1", ext: "ext/json/ext/parser",
    env: { "JSON_DISABLE_SIMD" => "1" } },
  { gem: "json", version: "2.21.1", ext: "ext/json/ext/generator",
    extra_inc: ["../parser"], env: { "JSON_DISABLE_SIMD" => "1" } },
  { gem: "msgpack", version: "1.8.3", ext: "ext/msgpack" },
  { gem: "bigdecimal", version: "4.1.2", ext: "ext/bigdecimal" }
].freeze

def sh!(*cmd, chdir:, env: {})
  out, status = Open3.capture2e(env, *cmd, chdir: chdir)
  return out if status.success?

  warn "COMMAND FAILED (exit #{status.exitstatus}): #{cmd.join(' ')} (in #{chdir})"
  warn out
  exit 1
end

def enable_yjit
  return "disabled (BENCH_YJIT=0)" if ENV["BENCH_YJIT"] == "0"

  RubyVM::YJIT.enable
  "enabled"
rescue StandardError, NoMethodError
  "unavailable (host ruby built without YJIT)"
end

def monotime
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def cpu_model
  line = File.readlines("/proc/cpuinfo").find { |l| l.start_with?("model name") }
  line ? line.split(":", 2).last.strip : "unknown"
rescue StandardError
  "unknown"
end

def gcc_available?
  ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, "gcc")) }
end

def gcc_version_line
  out, status = Open3.capture2e("gcc", "--version")
  status.success? ? out.lines.first.strip : "unknown"
rescue StandardError
  "unknown"
end

def gcc_disabled_reason
  return "disabled (BENCH_GCC=0)" if ENV["BENCH_GCC"] == "0"

  "unavailable (gcc not found on PATH)"
end

# --- staging ---------------------------------------------------------------

# Unpacked into a throughput-only staging area (WORK/tp-*): benchmark/run.rb
# shares WORK but runs extconf under the host toolchain in its own unpack
# dirs, and the two must not reuse each other's Makefiles.
def fetch_gem(name, version)
  unpack_dir = File.join(WORK, "tp-#{name}-#{version}")
  return unpack_dir if File.directory?(File.join(unpack_dir, "ext"))

  FileUtils.mkdir_p(WORK)
  gem_file = File.join(WORK, "#{name}-#{version}.gem")
  sh!("gem", "fetch", name, "--version", version, chdir: WORK) unless File.exist?(gem_file)
  FileUtils.rm_rf(unpack_dir)
  sh!("gem", "unpack", gem_file, "--target", unpack_dir, chdir: WORK)
  # `gem unpack --target` nests a <name>-<version> directory; flatten it away.
  nested = File.join(unpack_dir, "#{name}-#{version}")
  if File.directory?(nested)
    Dir.children(nested).each { |c| FileUtils.mv(File.join(nested, c), unpack_dir) }
    FileUtils.rmdir(nested)
  end
  unpack_dir
end

def extract_defines(makefile)
  line = File.readlines(makefile).find { |l| l.start_with?("CPPFLAGS") }
  raise "no CPPFLAGS in #{makefile}" unless line

  # "-DFOO=1" -> [:define, "FOO=1"], the driver's own -D representation. A
  # quoted value like -DRUBY_EXTCONF_H=\"extconf.h\" carries its quotes into
  # the macro body once the Makefile-level backslashes are stripped.
  line.scan(/-D(\S+)/).map { |(arg)| [:define, arg.gsub('\\"', '"')] }
end

def hdr_include_paths
  c = RbConfig::CONFIG
  [c["rubyarchhdrdir"], "#{c['rubyhdrdir']}/ruby/backward", c["rubyhdrdir"]]
end

# Runs extconf once (idempotent: skipped if a Makefile is present) and returns
# { sources:, defines:, include_paths: } describing how a real install would
# compile this extension directory. The mkmf shim routes every conftest
# through rubycc, so the resulting Makefile is the one a RUBYCC=1 install
# generates; this staging step is slow (one rubycc process per conftest) but
# runs only once per staged gem.
def stage_workload(spec)
  unpack_dir = fetch_gem(spec[:gem], spec[:version])
  ext_dir = File.join(unpack_dir, spec[:ext])
  makefile = File.join(ext_dir, "Makefile")
  unless File.exist?(makefile)
    sh!("ruby", "-I#{ROOT}/lib", "-rrubycc/mkmf_shim", "extconf.rb",
        chdir: ext_dir, env: spec[:env] || {})
  end
  {
    sources: Dir.glob(File.join(ext_dir, "*.c")).sort,
    defines: extract_defines(makefile),
    include_paths: [ext_dir, *(spec[:extra_inc] || []).map { |d| File.expand_path(d, ext_dir) },
                    *hdr_include_paths]
  }
end

# --- measurement -----------------------------------------------------------

# The stage-breakdown pipeline mirrors Compiler#compile for the x86_64 target,
# taking every ABI knob from the same TARGETS entry so the two cannot drift.
def target_entry
  Rubycc::Compiler::TARGETS.fetch("x86_64")
end

def preprocessor
  Rubycc::Preprocess::Preprocessor.new(char_unsigned: !target_entry[:char_signed],
                                       arch_macros: target_entry[:arch_macros],
                                       libc_arch: target_entry[:libc_arch])
end

# One-shot stage breakdown plus the file's preprocessed-line count. Fresh
# preprocessor per call: the instance is single-use state.
def stage_breakdown(source, path, defines, include_paths)
  t0 = monotime
  pp_tokens = preprocessor.preprocess(source, filename: path,
                                              include_paths: include_paths, defines: defines)
  t1 = monotime
  tokens = Rubycc::Preprocess::TokenConverter.new.convert(pp_tokens)
  t2 = monotime
  entry = target_entry
  plain_char = Rubycc::Type.plain_char(entry[:char_signed])
  program = Rubycc::Front::Parser.new(tokens, plain_char: plain_char,
                                              unnamed_bitfields_align: entry[:unnamed_bitfields_align],
                                              builtin_va_list: entry[:convention].va_list_type).parse
  t3 = monotime
  Rubycc::IR::Generator.new(plain_char: plain_char,
                            convention: entry[:convention]).generate(program, pic: true)
  t4 = monotime
  lines = pp_tokens.reject { |tok| tok.type == :eof }
                   .map { |tok| [tok.filename, tok.line] }.uniq.length
  { lines: lines,
    preprocess: t1 - t0, tokenize: t2 - t1, parse: t3 - t2, ir: t4 - t3 }
end

# Full-pipeline wall time (source -> ELF object bytes), the headline number.
def time_full_compile(source, path, defines, include_paths)
  t0 = monotime
  Rubycc::Compiler.new.compile(source, filename: path, include_paths: include_paths,
                                       defines: defines, pic: true)
  monotime - t0
end

def measure_file(path, defines, include_paths, gcc_enabled)
  source = File.read(path)
  breakdown = stage_breakdown(source, path, defines, include_paths)
  time_full_compile(source, path, defines, include_paths) # warmup, discarded
  samples = RUNS.times.map { time_full_compile(source, path, defines, include_paths) }
  sorted = samples.sort
  median = sorted.length.odd? ? sorted[sorted.length / 2] : (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2.0
  result = breakdown.merge(median: median, min: sorted.first,
                           spread: (sorted.last - sorted.first) / median,
                           lines_per_sec: breakdown[:lines] / median)
  result.merge(measure_gcc_file(path, defines, include_paths, breakdown[:lines], gcc_enabled))
end

# gcc -O0 argv for one source: same include paths / -D set / -fPIC as the
# rubycc compile above, so both sides compile the identical translation unit.
def gcc_argv(src, obj, defines, include_paths)
  ["gcc", "-O0", "-fPIC", "-c", src, "-o", obj,
   *include_paths.map { |d| "-I#{d}" },
   *defines.map { |(_type, val)| "-D#{val}" }]
end

# gcc -O0 reference: one warmup (discarded) + RUNS timed samples, median wall
# time, same "preprocessed lines" denominator as the rubycc figure so the two
# columns are directly comparable by ratio. Unlike time_full_compile above,
# this times a full `gcc` process launch each sample (fork+exec, not
# in-process), so the absolute times are NOT measuring the same thing as
# rubycc's warm in-process compile -- only the resulting ratio is meaningful.
# Returns { gcc_median:, gcc_lines_per_sec: } with nil values when gcc is
# disabled/unavailable or the compile fails (compile failure is warned, not
# fatal, so one broken workload doesn't abort the whole benchmark).
def measure_gcc_file(path, defines, include_paths, lines, gcc_enabled)
  return { gcc_median: nil, gcc_lines_per_sec: nil } unless gcc_enabled

  Dir.mktmpdir("rubycc_bench_gcc") do |dir|
    obj = File.join(dir, "#{File.basename(path, '.c')}.o")
    argv = gcc_argv(path, obj, defines, include_paths)

    warmup_out, warmup_status = Open3.capture2e(*argv)
    unless warmup_status.success?
      warn "    gcc -O0 FAILED for #{path} (exit #{warmup_status.exitstatus}), reporting '-' for this row"
      warn warmup_out
      return { gcc_median: nil, gcc_lines_per_sec: nil }
    end

    samples = RUNS.times.map do
      t0 = monotime
      Open3.capture2e(*argv)
      monotime - t0
    end
    sorted = samples.sort
    n = sorted.length
    median = n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    { gcc_median: median, gcc_lines_per_sec: lines / median }
  end
end

# --- report ----------------------------------------------------------------

def markdown_report(rows, env)
  lines = []
  lines << "# rubycc コンパイルスループット (N1)"
  lines << ""
  env.each { |k, v| lines << "- **#{k}**: #{v}" }
  lines << ""
  lines << "| gem | file | 前処理後行数 | preprocess | tokenize | parse | IR | full median | 行/秒 | gcc-O0 行/秒 | rubycc/gcc |"
  lines << "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
  rows.each do |r|
    gcc_col = r[:gcc_lines_per_sec] ? r[:gcc_lines_per_sec].round.to_s : "-"
    ratio_col = r[:gcc_lines_per_sec] ? format("%.2fx", r[:lines_per_sec] / r[:gcc_lines_per_sec]) : "-"
    lines << format("| %s | %s | %d | %.3fs | %.3fs | %.3fs | %.3fs | %.3fs%s | %d | %s | %s |",
                    r[:gem], r[:file], r[:lines], r[:preprocess], r[:tokenize],
                    r[:parse], r[:ir], r[:median], r[:spread] > 0.2 ? "*" : "", r[:lines_per_sec],
                    gcc_col, ratio_col)
  end
  lines << ""
  per_sec = rows.map { |r| r[:lines_per_sec] }.sort
  median = per_sec.length.odd? ? per_sec[per_sec.length / 2] : (per_sec[per_sec.length / 2 - 1] + per_sec[per_sec.length / 2]) / 2.0
  lines << format("**代表値(ファイル別 行/秒 の中央値): %d 行/秒** — 目標 %d 行/秒の %.1f%%",
                  median, TARGET_LINES_PER_SEC, median / TARGET_LINES_PER_SEC * 100)
  gcc_values = rows.map { |r| r[:gcc_lines_per_sec] }.compact.sort
  unless gcc_values.empty?
    n = gcc_values.length
    gcc_median = n.odd? ? gcc_values[n / 2] : (gcc_values[n / 2 - 1] + gcc_values[n / 2]) / 2.0
    lines << format("**gcc -O0 代表値(ファイル別 行/秒 の中央値): %d 行/秒** — rubycc は %.2f 倍",
                    gcc_median, median / gcc_median)
  end
  lines << ""
  lines << "`*` = spread ((max-min)/median) > 20%。stage 内訳は 1 回計測の参考値。"
  lines << "gcc-O0 はプロセス起動込みの wall time、rubycc はインプロセス(ウォーム)計測であり、両者は非対称な条件下の参考値。"
  lines.join("\n") + "\n"
end

def main
  yjit = enable_yjit
  gcc_enabled = ENV["BENCH_GCC"] != "0" && gcc_available?
  env = {
    "date" => Time.now.strftime("%Y-%m-%d %H:%M:%S %z"),
    "cpu" => cpu_model,
    "ruby" => RUBY_DESCRIPTION,
    "yjit" => yjit,
    "gcc" => gcc_enabled ? gcc_version_line : gcc_disabled_reason,
    "runs" => "#{RUNS} (+1 warmup, in-process for rubycc / per-process for gcc)",
    "workloads" => WORKLOADS.map { |w| "#{w[:gem]}-#{w[:version]}/#{w[:ext]}" }.join(", ")
  }
  rows = []
  WORKLOADS.each do |spec|
    staged = stage_workload(spec)
    staged[:sources].each do |path|
      file = File.basename(path)
      puts "==> #{spec[:gem]}: #{file}"
      r = measure_file(path, staged[:defines], staged[:include_paths], gcc_enabled)
      rows << r.merge(gem: spec[:gem], file: file)
      printf("    %d lines, full median %.3fs -> %d lines/sec (pp %.3fs / parse %.3fs / ir %.3fs)\n",
             r[:lines], r[:median], r[:lines_per_sec], r[:preprocess], r[:parse], r[:ir])
    end
  end

  report = markdown_report(rows, env)
  puts "", report
  FileUtils.mkdir_p(File.join(BENCH_DIR, "results"))
  stamp = Time.now.strftime("%Y%m%d-%H%M%S")
  File.write(File.join(BENCH_DIR, "results", "throughput-#{stamp}.md"), report)
  File.write(File.join(BENCH_DIR, "results", "throughput-#{stamp}.json"),
             JSON.pretty_generate({ env: env, rows: rows }) + "\n")
  puts "wrote benchmark/results/throughput-#{stamp}.{md,json}"
end

main if __FILE__ == $PROGRAM_NAME
