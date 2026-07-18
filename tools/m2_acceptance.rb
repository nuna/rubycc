#!/usr/bin/env ruby
# frozen_string_literal: true

# M2 受け入れ(docs/ROADMAP.md §5)を再現するツール。
#
# extconf.rb が生成した Makefile のビルドコマンドを手動で rubycc に置き換えて
# json / msgpack をビルドし、それぞれの gem 自身のテストスイートに合格することを
# 確認する。ネットワーク(rubygems.org・GitHub)と Ruby ヘッダが必要(mkmf の probe
# 自体は環境の gcc で行ってよい — M2 の前提)。ネットワーク・rspec 等の外部依存を
# 持つため常設テストスイートには含めない、手動/CI 実行用のツール。
# 実測合格の記録は docs/STEPS.md の Step 54。
#
# Usage:
#   tools/m2_acceptance.rb [work_dir]
#   M2_WORK=/path/to/work tools/m2_acceptance.rb

require "fileutils"
require "open3"
require "rbconfig"
require "rubygems"
require "timeout"

RUBYCC_ROOT = File.expand_path("..", __dir__)
WORK_DIR = File.expand_path(ARGV[0] || ENV["M2_WORK"] || "/tmp/rubycc_m2")
RUBYCC_CMD = ["ruby", "-I#{RUBYCC_ROOT}/lib", "#{RUBYCC_ROOT}/exe/rubycc"].freeze

# Generous ceiling for the test-suite runs (json/msgpack finish in well under
# a minute each in practice); this only guards against a genuine hang.
TEST_TIMEOUT = 600

GEMS = {
  "json" => {
    version: "2.21.1",
    tarball: "https://github.com/ruby/json/archive/refs/tags/v2.21.1.tar.gz"
  },
  "msgpack" => {
    version: "1.8.3",
    tarball: "https://github.com/msgpack/msgpack-ruby/archive/refs/tags/v1.8.3.tar.gz"
  }
}.freeze

def step(msg)
  puts "==> #{msg}"
end

# Runs cmd and aborts the whole tool on failure. Used for steps that are
# preconditions for everything after them (fetch/unpack/extconf/build).
def run!(*cmd, chdir: nil, env: {})
  chdir ||= Dir.pwd
  stdout, status = Open3.capture2e(env, *cmd, chdir: chdir)
  unless status.success?
    warn "FAILED (exit #{status.exitstatus}): #{cmd.join(' ')}  (in #{chdir})"
    warn stdout
    exit 1
  end
  stdout
end

# Runs cmd and returns [combined_output, success?] without aborting -- used
# for the two test-suite runs, whose PASS/FAIL outcome is the thing being
# reported rather than a build precondition. Bounded by TEST_TIMEOUT so a
# genuine hang doesn't block the tool forever.
def run(*cmd, chdir: nil, env: {})
  chdir ||= Dir.pwd
  output = +""
  status = nil
  Timeout.timeout(TEST_TIMEOUT) do
    output, status = Open3.capture2e(env, *cmd, chdir: chdir)
  end
  [output, status&.success? || false]
rescue Timeout::Error
  ["timed out after #{TEST_TIMEOUT}s", false]
end

def download(url, dest)
  return if File.exist?(dest)

  run!("curl", "-sL", "-o", dest, url)
end

def ensure_gem(name)
  return if Gem::Specification.find_all_by_name(name).any?

  step "installing #{name} (missing)"
  run!("gem", "install", name, "--no-document")
end

# --- material fetch (idempotent: skipped once already merged) ------------

def fetch_gem(name)
  version = GEMS.fetch(name).fetch(:version)
  unpack_dir = File.join(WORK_DIR, "#{name}-#{version}")
  sentinel = File.join(unpack_dir, ".m2_fetched")
  if File.exist?(sentinel)
    step "reusing fetched #{name} #{version} at #{unpack_dir}"
    return unpack_dir
  end

  step "fetching #{name} #{version} (gem + GitHub source tarball)"
  gem_file = File.join(WORK_DIR, "#{name}-#{version}.gem")
  run!("gem", "fetch", name, "--version", version, chdir: WORK_DIR) unless File.exist?(gem_file)

  FileUtils.rm_rf(unpack_dir)
  run!("gem", "unpack", gem_file, chdir: WORK_DIR)

  tarball = File.join(WORK_DIR, "#{name}-#{version}-src.tar.gz")
  download(GEMS.fetch(name).fetch(:tarball), tarball)
  # The gem package has ext/lib but no test/spec; merge the GitHub source
  # tarball's contents (which do) into the same directory the gem unpacked
  # into, stripping its single top-level directory component.
  run!("tar", "xzf", tarball, "--strip-components=1", "-C", unpack_dir)

  FileUtils.touch(sentinel)
  unpack_dir
end

# --- rubycc build (redone on every run, even when materials are cached) --

def hdr_incflags
  config = RbConfig::CONFIG
  ["-I#{config['rubyarchhdrdir']}", "-I#{config['rubyhdrdir']}/ruby/backward", "-I#{config['rubyhdrdir']}"]
end

def run_extconf(dir, env: {})
  step "running extconf.rb in #{dir}"
  run!("ruby", "extconf.rb", chdir: dir, env: env)
end

def extract_defines(makefile_path)
  line = File.readlines(makefile_path).find { |l| l.start_with?("CPPFLAGS") }
  raise "no CPPFLAGS line found in #{makefile_path}" unless line

  line.scan(/-D[A-Za-z0-9_=]+/)
end

def build_shared(out_so, incflags, defines, sources, chdir:)
  FileUtils.mkdir_p(File.dirname(out_so))
  step "building #{out_so} (rubycc)"
  run!(*RUBYCC_CMD, "-shared", "-fPIC", "-o", out_so, *incflags, *defines, *sources, chdir: chdir)
end

def build_msgpack(unpack_dir)
  ext_dir = File.join(unpack_dir, "ext/msgpack")
  run_extconf(ext_dir)
  defines = extract_defines(File.join(ext_dir, "Makefile"))
  incflags = ["-I."] + hdr_incflags
  sources = Dir.glob(File.join(ext_dir, "*.c")).map { |p| File.basename(p) }.sort

  out_so = File.join(WORK_DIR, "mpext/msgpack/msgpack.so")
  build_shared(out_so, incflags, defines, sources, chdir: ext_dir)
  out_so
end

def build_json(unpack_dir)
  parser_dir = File.join(unpack_dir, "ext/json/ext/parser")
  generator_dir = File.join(unpack_dir, "ext/json/ext/generator")

  # rubycc has no SSE intrinsics / inline-asm support (docs/STEPS.md Step 44:
  # x86intrin.h is stubbed empty on the assumption every real intrinsic use is
  # behind a feature macro rubycc never defines). json's own simd/conf.rb
  # probes gcc for a genuinely usable SSE2+cpuid.h path and, when found,
  # generator.c/parser.c unconditionally use _mm_* intrinsics and
  # __builtin_cpu_supports, which rubycc cannot compile. JSON_DISABLE_SIMD=1
  # is the gem's own documented switch (extconf.rb: enable_config(
  # 'parser-use-simd'/'generator-use-simd')) to skip that path cleanly;
  # everything the fallback path uses (__has_builtin-guarded __builtin_memcpy
  # etc.) rubycc already supports.
  simd_off = { "JSON_DISABLE_SIMD" => "1" }
  run_extconf(parser_dir, env: simd_off)
  run_extconf(generator_dir, env: simd_off)

  parser_defs = extract_defines(File.join(parser_dir, "Makefile"))
  generator_defs = extract_defines(File.join(generator_dir, "Makefile"))

  parser_inc = ["-I."] + hdr_incflags
  generator_inc = ["-I.", "-I../parser"] + hdr_incflags

  parser_so = File.join(WORK_DIR, "jext/json/ext/parser.so")
  generator_so = File.join(WORK_DIR, "jext/json/ext/generator.so")

  build_shared(parser_so, parser_inc, parser_defs, ["parser.c"], chdir: parser_dir)
  build_shared(generator_so, generator_inc, generator_defs, ["generator.c"], chdir: generator_dir)

  [parser_so, generator_so]
end

# --- gem test suites -------------------------------------------------------

def test_json(unpack_dir, jext_dir)
  step "verifying JSON.parser resolves to the rubycc-built C extension"
  check_out, check_ok = run(
    "ruby", "-I#{jext_dir}", "-Ilib",
    "-e", 'require "json"; abort unless JSON.parser.to_s == "JSON::Ext::Parser"',
    chdir: unpack_dir
  )
  return { pass: false, summary: "JSON::Ext::Parser was not selected:\n#{check_out}" } unless check_ok

  ensure_gem("test-unit")
  ensure_gem("test-unit-ruby-core")

  step "running json test suite"
  out, ok = run(
    "ruby", "-I#{jext_dir}", "-Ilib", "-Itest",
    "-e", 'Dir["test/json/*_test.rb"].sort.each { |f| require File.expand_path(f) }',
    chdir: unpack_dir
  )
  { pass: ok, summary: out.lines.last(6).join }
end

def test_msgpack(unpack_dir, mpext_dir)
  ensure_gem("rspec")

  step "running msgpack test suite"
  out, ok = run(
    "rspec", "-I#{mpext_dir}", "-Ilib", "--no-color", "spec",
    "--exclude-pattern", "spec/jruby/**/*",
    chdir: unpack_dir
  )
  { pass: ok, summary: out.lines.last(6).join }
end

# --- main -------------------------------------------------------------------

step "rubycc M2 acceptance"
step "work dir: #{WORK_DIR}"
FileUtils.mkdir_p(WORK_DIR)

json_dir = fetch_gem("json")
msgpack_dir = fetch_gem("msgpack")

mpext_dir = File.join(WORK_DIR, "mpext")
jext_dir = File.join(WORK_DIR, "jext")
FileUtils.rm_rf(mpext_dir)
FileUtils.rm_rf(jext_dir)

build_msgpack(msgpack_dir)
build_json(json_dir)

json_result = test_json(json_dir, jext_dir)
msgpack_result = test_msgpack(msgpack_dir, mpext_dir)

puts
puts "==================== M2 acceptance summary ===================="
[
  ["json #{GEMS['json'][:version]}", json_result],
  ["msgpack #{GEMS['msgpack'][:version]}", msgpack_result]
].each do |label, result|
  puts "#{result[:pass] ? 'PASS' : 'FAIL'}  #{label}"
  result[:summary].to_s.strip.each_line { |line| puts "  #{line.chomp}" }
end
puts "=================================================================="

exit(json_result[:pass] && msgpack_result[:pass] ? 0 : 1)
