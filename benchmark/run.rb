#!/usr/bin/env ruby
# frozen_string_literal: true

# rubycc-vs-gcc execution-speed benchmark harness (Step 66).
#
# Builds each workload three ways -- gcc -O2, gcc -O0, and rubycc (which is
# -O0-equivalent: no optimization, no register allocation) -- runs every build
# N times after one discarded warmup, and reports the median wall-clock time
# plus the rubycc/gcc slowdown ratios. It covers two families:
#
#   * C-only compute kernels (benchmark/c/*.c): self-contained programs that do
#     a fixed amount of work and print a checksum. The harness times the whole
#     process; the program never times itself.
#
#   * Ruby programs that lean on a C extension (benchmark/ruby/bench_*.rb): the
#     json and msgpack gems are fetched, unpacked, and their .so is built once
#     per compiler variant (reusing the tools/m2_acceptance.rb build flow); the
#     same Ruby script is then run against each build so the only moving part is
#     which compiler produced the native code.
#
# This is deliberately NOT part of `rake test` -- it takes minutes and shells
# out to gcc and the network. Timing is wall time via CLOCK_MONOTONIC; run it on
# an otherwise-idle machine.
#
# Usage:
#   ruby benchmark/run.rb                 # everything, 5 timed runs each
#   BENCH_RUNS=7 ruby benchmark/run.rb    # more samples
#   BENCH_ONLY=c ruby benchmark/run.rb    # C kernels only
#   BENCH_ONLY=ruby ruby benchmark/run.rb # json/msgpack only
#   BENCH_WORK=/path ruby benchmark/run.rb# where gem material/.so are staged
#
# Results are printed as a Markdown table and saved under benchmark/results/
# with the environment captured alongside.

require "fileutils"
require "json"
require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
BENCH_DIR = __dir__
RUBYCC_CMD = ["ruby", "-I#{ROOT}/lib", "#{ROOT}/exe/rubycc"].freeze

RUNS = Integer(ENV["BENCH_RUNS"] || 5)
WARMUP = 1
ONLY = ENV["BENCH_ONLY"] # nil | "c" | "ruby"
WORK = File.expand_path(ENV["BENCH_WORK"] || "/tmp/rubycc_bench")

GEMS = {
  "json" => "2.21.1",
  "msgpack" => "1.8.3"
}.freeze

def sh!(*cmd, chdir: ROOT, env: {})
  out, status = Open3.capture2e(env, *cmd, chdir: chdir)
  return out if status.success?

  warn "COMMAND FAILED (exit #{status.exitstatus}): #{cmd.join(' ')} (in #{chdir})"
  warn out
  exit 1
end

# --- timing ----------------------------------------------------------------

# Runs cmd (argv array) with the given load-path/env once and returns its wall
# time in seconds, or raises if it exits non-zero. Child stdout is captured so
# the caller can checksum-compare variants; stderr is surfaced on failure.
def time_once(cmd, env: {})
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, status = Open3.capture2e(env, *cmd)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  raise "run failed (exit #{status.exitstatus}): #{cmd.join(' ')}\n#{out}" unless status.success?

  [t1 - t0, out.strip]
end

# One warmup (discarded) + RUNS timed samples. Returns { samples:, median:,
# min:, spread:, output: }. `spread` is (max-min)/median, flagged in the report
# when large so a noisy measurement is not read as signal.
def measure(cmd, env: {})
  time_once(cmd, env: env) if WARMUP.positive?
  samples = []
  output = nil
  RUNS.times do
    dt, out = time_once(cmd, env: env)
    samples << dt
    output = out
  end
  sorted = samples.sort
  n = sorted.length
  median = n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  { samples: samples, median: median, min: sorted.first, spread: (sorted.last - sorted.first) / median, output: output }
end

def median_ratio(a, b)
  b.zero? ? Float::NAN : a / b
end

# --- environment -----------------------------------------------------------

def cpu_model
  line = File.readlines("/proc/cpuinfo").find { |l| l.start_with?("model name") }
  line ? line.split(":", 2).last.strip : "unknown"
rescue StandardError
  "unknown"
end

def environment
  {
    "date" => Time.now.strftime("%Y-%m-%d %H:%M:%S %z"),
    "cpu" => cpu_model,
    "cores" => (`nproc`.strip rescue "?"),
    "kernel" => (`uname -sr`.strip rescue "?"),
    "ruby" => RUBY_DESCRIPTION,
    "gcc" => (`gcc --version`.lines.first.strip rescue "?"),
    "runs" => RUNS,
    "warmup" => WARMUP
  }
end

# --- C kernels -------------------------------------------------------------

C_VARIANTS = {
  "gcc-O2" => ->(src, out) { ["gcc", "-O2", "-o", out, src] },
  "gcc-O0" => ->(src, out) { ["gcc", "-O0", "-o", out, src] },
  "rubycc" => ->(src, out) { [*RUBYCC_CMD, "-o", out, src] }
}.freeze

def run_c_benchmarks
  bindir = File.join(WORK, "cbin")
  FileUtils.mkdir_p(bindir)
  sources = Dir.glob(File.join(BENCH_DIR, "c", "*.c")).sort
  rows = []
  sources.each do |src|
    name = File.basename(src, ".c")
    puts "==> C kernel: #{name}"
    result = { name: name, variants: {} }
    outputs = {}
    C_VARIANTS.each do |variant, build|
      exe = File.join(bindir, "#{name}.#{variant}")
      sh!(*build.call(src, exe))
      m = measure([exe])
      outputs[variant] = m[:output]
      result[:variants][variant] = m
      printf("    %-8s median=%.3fs (min=%.3fs spread=%.1f%%)\n", variant, m[:median], m[:min], m[:spread] * 100)
    end
    unless outputs.values.uniq.length == 1
      warn "    WARNING: output mismatch across variants for #{name}: #{outputs.inspect}"
    end
    result[:output] = outputs.values.first
    rows << result
  end
  rows
end

# --- Ruby / C-extension workloads ------------------------------------------

def hdr_incflags
  c = RbConfig::CONFIG
  ["-I#{c['rubyarchhdrdir']}", "-I#{c['rubyhdrdir']}/ruby/backward", "-I#{c['rubyhdrdir']}"]
end

def fetch_gem(name)
  version = GEMS.fetch(name)
  unpack_dir = File.join(WORK, "#{name}-#{version}")
  return unpack_dir if File.directory?(File.join(unpack_dir, "lib"))

  gem_file = File.join(WORK, "#{name}-#{version}.gem")
  sh!("gem", "fetch", name, "--version", version, chdir: WORK) unless File.exist?(gem_file)
  FileUtils.rm_rf(unpack_dir)
  sh!("gem", "unpack", gem_file, chdir: WORK)
  unpack_dir
end

def extract_defines(makefile)
  line = File.readlines(makefile).find { |l| l.start_with?("CPPFLAGS") }
  raise "no CPPFLAGS in #{makefile}" unless line

  line.scan(/-D[A-Za-z0-9_=]+/)
end

# Compiler variants used for the C extensions. rubycc takes no -O; gcc is built
# at both -O2 and -O0 so the Ruby-side table carries the same two ratios as the
# C-kernel table.
def so_compilers
  {
    "gcc-O2" => ->(args) { ["gcc", "-O2", "-shared", "-fPIC", *args] },
    "gcc-O0" => ->(args) { ["gcc", "-O0", "-shared", "-fPIC", *args] },
    "rubycc" => ->(args) { [*RUBYCC_CMD, "-shared", "-fPIC", *args] }
  }
end

# Builds json's parser.so + generator.so for one compiler variant into
# <stage>/json/ext/. SIMD is disabled for every variant (rubycc has no SSE
# intrinsics; disabling it for gcc too keeps the source identical so the table
# reflects compiler codegen, not an algorithm difference). Returns the load-path
# dir that holds json/ext/*.so.
def build_json_so(unpack_dir, variant, compiler)
  parser_dir = File.join(unpack_dir, "ext/json/ext/parser")
  generator_dir = File.join(unpack_dir, "ext/json/ext/generator")
  simd_off = { "JSON_DISABLE_SIMD" => "1" }
  sh!("ruby", "extconf.rb", chdir: parser_dir, env: simd_off)
  sh!("ruby", "extconf.rb", chdir: generator_dir, env: simd_off)
  parser_defs = extract_defines(File.join(parser_dir, "Makefile"))
  generator_defs = extract_defines(File.join(generator_dir, "Makefile"))

  stage = File.join(WORK, "jext-#{variant}")
  ext = File.join(stage, "json/ext")
  FileUtils.mkdir_p(ext)
  sh!(*compiler.call(["-o", File.join(ext, "parser.so"), "-I."] + hdr_incflags + parser_defs + ["parser.c"]), chdir: parser_dir)
  sh!(*compiler.call(["-o", File.join(ext, "generator.so"), "-I.", "-I../parser"] + hdr_incflags + generator_defs + ["generator.c"]), chdir: generator_dir)
  stage
end

# Builds msgpack.so for one compiler variant into <stage>/msgpack/. Returns the
# load-path dir that holds msgpack/msgpack.so.
def build_msgpack_so(unpack_dir, variant, compiler)
  ext_dir = File.join(unpack_dir, "ext/msgpack")
  sh!("ruby", "extconf.rb", chdir: ext_dir)
  defines = extract_defines(File.join(ext_dir, "Makefile"))
  sources = Dir.glob(File.join(ext_dir, "*.c")).map { |p| File.basename(p) }.sort

  stage = File.join(WORK, "mpext-#{variant}")
  mp = File.join(stage, "msgpack")
  FileUtils.mkdir_p(mp)
  sh!(*compiler.call(["-o", File.join(mp, "msgpack.so"), "-I."] + hdr_incflags + defines + sources), chdir: ext_dir)
  stage
end

RUBY_WORKLOADS = {
  "json" => {
    script: "bench_json.rb",
    builder: :build_json_so,
    libdir: ->(unpack) { File.join(unpack, "lib") }
  },
  "msgpack" => {
    script: "bench_msgpack.rb",
    builder: :build_msgpack_so,
    libdir: ->(unpack) { File.join(unpack, "lib") }
  }
}.freeze

def run_ruby_benchmarks
  rows = []
  RUBY_WORKLOADS.each do |name, spec|
    puts "==> Ruby workload: #{name} (#{GEMS[name]})"
    unpack_dir = fetch_gem(name)
    libdir = spec[:libdir].call(unpack_dir)
    script = File.join(BENCH_DIR, "ruby", spec[:script])
    result = { name: name, variants: {} }
    outputs = {}
    so_compilers.each do |variant, compiler|
      stage = send(spec[:builder], unpack_dir, variant, compiler)
      cmd = ["ruby", "-I#{stage}", "-I#{libdir}", script]
      m = measure(cmd)
      outputs[variant] = m[:output]
      result[:variants][variant] = m
      printf("    %-8s median=%.3fs (min=%.3fs spread=%.1f%%)\n", variant, m[:median], m[:min], m[:spread] * 100)
    end
    unless outputs.values.map { |o| o.split("impl=").first.strip }.uniq.length == 1
      warn "    WARNING: checksum mismatch across variants for #{name}: #{outputs.inspect}"
    end
    result[:output] = outputs.values.first
    rows << result
  end
  rows
end

# --- reporting -------------------------------------------------------------

def render_table(title, rows)
  lines = []
  lines << "### #{title}"
  lines << ""
  lines << "| benchmark | gcc-O2 (s) | gcc-O0 (s) | rubycc (s) | rubycc/gcc-O2 | rubycc/gcc-O0 |"
  lines << "|---|---|---|---|---|---|"
  rows.each do |r|
    o2 = r[:variants]["gcc-O2"][:median]
    o0 = r[:variants]["gcc-O0"][:median]
    rc = r[:variants]["rubycc"][:median]
    flag = r[:variants].values.map { |m| m[:spread] }.max > 0.20 ? " *" : ""
    lines << format("| %s%s | %.3f | %.3f | %.3f | %.2fx | %.2fx |",
                    r[:name], flag, o2, o0, rc, median_ratio(rc, o2), median_ratio(rc, o0))
  end
  lines << ""
  lines << "`*` = sample spread (max-min)/median exceeded 20% for some variant; treat that row as approximate."
  lines << ""
  lines.join("\n")
end

def render_env(env)
  lines = ["### Environment", ""]
  env.each { |k, v| lines << "- **#{k}**: #{v}" }
  lines << ""
  lines.join("\n")
end

# --- main ------------------------------------------------------------------

FileUtils.mkdir_p(WORK)
env = environment
puts render_env(env)
puts

c_rows = ONLY == "ruby" ? [] : run_c_benchmarks
ruby_rows = ONLY == "c" ? [] : run_ruby_benchmarks

report = +""
report << render_env(env) << "\n"
report << render_table("C compute kernels (standalone executables)", c_rows) << "\n" unless c_rows.empty?
report << render_table("Ruby workloads via C extension", ruby_rows) << "\n" unless ruby_rows.empty?

puts
puts "==================== results ===================="
puts report

FileUtils.mkdir_p(File.join(BENCH_DIR, "results"))
stamp = Time.now.strftime("%Y%m%d-%H%M%S")
out_path = File.join(BENCH_DIR, "results", "bench-#{stamp}.md")
File.write(out_path, report)
raw_path = File.join(BENCH_DIR, "results", "bench-#{stamp}.json")
File.write(raw_path, JSON.pretty_generate(
  "environment" => env,
  "c" => c_rows,
  "ruby" => ruby_rows
))
puts "saved: #{out_path}"
puts "saved: #{raw_path}"
