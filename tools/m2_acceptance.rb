#!/usr/bin/env ruby
# frozen_string_literal: true

# M2 受け入れ(docs/development/ROADMAP.md §5)を再現するツール。
#
# extconf.rb が生成した Makefile のビルドコマンドを手動で rubycc に置き換えて
# json / msgpack をビルドし、それぞれの gem 自身のテストスイートに合格することを
# 確認する。ネットワーク(rubygems.org・GitHub)と Ruby ヘッダが必要(mkmf の probe
# 自体は環境の gcc で行ってよい — M2 の前提)。ネットワーク・rspec 等の外部依存を
# 持つため常設テストスイートには含めない、手動/CI 実行用のツール。
# 実測合格の記録は docs/development/STEPS.md の Step 54。
#
# Usage(`ruby` を省かないこと。tools/ は実行ビット無しで追跡しているので、
# `bundle exec tools/...` は "not executable" で拒否される):
#   ruby tools/m2_acceptance.rb [work_dir]
#   M2_WORK=/path/to/work ruby tools/m2_acceptance.rb

require "fileutils"
require "json"
require "rbconfig"
require "rubygems"
require_relative "scan_corpus_variadics"
require_relative "ci_result"
require_relative "ci_check_acceptance"
require_relative "../test/support/acceptance_fetch_helper"

RUBYCC_ROOT = File.expand_path("..", __dir__)
WORK_DIR = File.expand_path(ARGV[0] || ENV["M2_WORK"] || "/tmp/rubycc_m2")
RUBYCC_CMD = ["ruby", "-I#{RUBYCC_ROOT}/lib", "#{RUBYCC_ROOT}/exe/rubycc"].freeze

# Generous ceiling for the test-suite runs (json/msgpack finish in well under
# a minute each in practice); this only guards against a genuine hang.
TEST_TIMEOUT = 600
COMMAND_TIMEOUT = Float(ENV.fetch("M2_COMMAND_TIMEOUT_SECONDS", "300"))
raise "M2_COMMAND_TIMEOUT_SECONDS must be positive" unless COMMAND_TIMEOUT.positive?

GEMS = {
  "json" => {
    version: "2.21.1",
    gem_artifact: "gem-json-2.21.1-ruby",
    source_artifact: "source-json-2.21.1-github"
  },
  "msgpack" => {
    version: "1.8.3",
    gem_artifact: "gem-msgpack-1.8.3-ruby",
    source_artifact: "source-msgpack-1.8.3-github"
  }
}.freeze

M2_TEST_GEMS = {
  "test-unit" => "3.6.1",
  "test-unit-ruby-core" => "1.0.5",
  "rspec" => "3.13.2"
}.freeze

MANIFEST_PATH = File.expand_path("../config/ci/acceptance_manifest.json", __dir__)
ACCEPTANCE_MANIFEST = Rubycc::CICheckAcceptance.load_manifest(MANIFEST_PATH)

def step(msg)
  puts "==> #{msg}"
end

def record_ci_result(id, state, reason = nil, **details)
  path = ENV["CI_RESULT_PATH"]
  return if path.nil? || path.empty?

  path = File.expand_path(path)
  FileUtils.mkdir_p(File.dirname(path))
  lock_path = "#{path}.lock"
  File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
    lock.flock(File::LOCK_EX)
    document = if File.file?(path) && File.size(path).positive?
                 Rubycc::CIResult.read(path)
               else
                 Rubycc::CIResult.document(results: [], metadata: ci_metadata)
               end
    existing_profile = document.fetch("metadata", {})["profile"]
    current_profile = ci_metadata.fetch(:profile)
    if existing_profile && existing_profile != current_profile
      raise Rubycc::CIResult::Error, "acceptance result file mixes profiles: " \
                                    "#{existing_profile.inspect} and #{current_profile.inspect}"
    end
    results = document.fetch("results")
    raise Rubycc::CIResult::Error, "duplicate acceptance result ID: #{id}" \
      if results.any? { |entry| entry["id"] == id }

    results << Rubycc::CIResult.result(id: id, state: state, reason: reason,
                                       **ci_metadata, **details)
    Rubycc::CIResult.write(path, results: results, metadata: document.fetch("metadata", ci_metadata))
  ensure
    lock.flock(File::LOCK_UN) if lock
  end
end

def artifact_entry(id)
  entry = ACCEPTANCE_MANIFEST.fetch("artifacts").find { |candidate| candidate.fetch("id") == id }
  return entry if entry

  raise "acceptance artifact #{id.inspect} is not in #{MANIFEST_PATH}"
end

def ci_metadata
  {
    profile: ENV.fetch("CI_PROFILE", "acceptance-live"),
    host: ENV["CI_HOST"],
    target: ENV["CI_TARGET"],
    runner: ENV["CI_RUNNER"],
    libc: ENV["CI_LIBC"],
    network: ENV.fetch("CI_NETWORK", "live")
  }.compact
end

def write_variadic_scan(roots)
  report = CorpusVariadicsScanner::Scanner.new(roots: roots).scan
  path = ENV["M2_VARIADIC_REPORT"]
  return report if path.nil? || path.empty?

  path = File.expand_path(path)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.pretty_generate(report) + "\n")
  report
end

# Runs cmd and aborts the whole tool on failure. Used for steps that are
# preconditions for everything after them (fetch/unpack/extconf/build).
def run!(*cmd, chdir: nil, env: {})
  chdir ||= Dir.pwd
  stdout, status = AcceptanceFetchHelper.capture2e(
    cmd, chdir: chdir, env: env, timeout_seconds: COMMAND_TIMEOUT
  )
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
  output, status = AcceptanceFetchHelper.capture2e(
    cmd, chdir: chdir, env: env, timeout_seconds: TEST_TIMEOUT
  )
  [output, status&.success? || false]
rescue AcceptanceFetchHelper::Failure => e
  [e.output.to_s.empty? ? e.message : e.output, false]
end

def ensure_gem(name)
  version = M2_TEST_GEMS.fetch(name)
  return if Gem::Specification.find_all_by_name(name, "= #{version}").any?

  step "installing #{name} #{version} (missing)"
  run!("gem", "install", name, "--version", version, "--no-document")
end

# --- material fetch (idempotent: skipped once already merged) ------------

def fetch_gem(name)
  spec = GEMS.fetch(name)
  version = spec.fetch(:version)
  unpack_dir = File.join(WORK_DIR, "#{name}-#{version}")
  sentinel = File.join(unpack_dir, ".m2_fetched")
  gem_file = File.join(WORK_DIR, "#{name}-#{version}.gem")
  gem_artifact = artifact_entry(spec.fetch(:gem_artifact))
  source_artifact = artifact_entry(spec.fetch(:source_artifact))
  unless gem_artifact.values_at("name", "version", "platform") == [name, version, "ruby"]
    raise "gem artifact metadata for #{name}-#{version} does not match GEMS"
  end
  unless source_artifact.values_at("name", "version") == [name, version]
    raise "source artifact metadata for #{name}-#{version} does not match GEMS"
  end
  fetcher = AcceptanceFetchHelper::Fetcher.new(work_dir: WORK_DIR)
  gem_file = fetcher.fetch_url(
    url: gem_artifact.fetch("url"), destination: gem_file,
    expected_sha256: gem_artifact.fetch("sha256"), artifact_id: gem_artifact.fetch("id"),
    artifact_kind: gem_artifact.fetch("kind"), artifact_url: gem_artifact.fetch("url")
  )

  tarball = File.join(WORK_DIR, "#{name}-#{version}-src.tar.gz")
  fetcher.fetch_url(
    url: source_artifact.fetch("url"), destination: tarball,
    expected_sha256: source_artifact.fetch("sha256"), artifact_id: source_artifact.fetch("id"),
    artifact_kind: source_artifact.fetch("kind"), artifact_url: source_artifact.fetch("url")
  )

  if File.exist?(sentinel)
    step "reusing fetched #{name} #{version} at #{unpack_dir}"
    return unpack_dir
  end

  step "unpacking fetched #{name} #{version} (pinned gem + GitHub source tarball)"

  FileUtils.rm_rf(unpack_dir)
  run!("gem", "unpack", gem_file, chdir: WORK_DIR)

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

  # rubycc has no SSE intrinsics / inline-asm support (docs/development/STEPS.md Step 44:
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
  rspec = File.join(Gem.bindir, "rspec")
  raise "rspec executable is missing from #{Gem.bindir}" unless File.executable?(rspec)

  step "running msgpack test suite"
  out, ok = run(
    rspec, "-I#{mpext_dir}", "-Ilib", "--no-color", "spec",
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

variadic_report = write_variadic_scan([json_dir, msgpack_dir])
step "variadic candidate scan: #{variadic_report.fetch("summary").inspect}"

mpext_dir = File.join(WORK_DIR, "mpext")
jext_dir = File.join(WORK_DIR, "jext")
FileUtils.rm_rf(mpext_dir)
FileUtils.rm_rf(jext_dir)

build_msgpack(msgpack_dir)
build_json(json_dir)

json_result = test_json(json_dir, jext_dir)
msgpack_result = test_msgpack(msgpack_dir, mpext_dir)
record_ci_result(
  "m2-json-suite", json_result[:pass] ? "pass" : "fail", json_result[:summary],
  gem_artifact: GEMS.fetch("json").fetch(:gem_artifact),
  source_artifact: GEMS.fetch("json").fetch(:source_artifact)
)
record_ci_result(
  "m2-msgpack-suite", msgpack_result[:pass] ? "pass" : "fail", msgpack_result[:summary],
  gem_artifact: GEMS.fetch("msgpack").fetch(:gem_artifact),
  source_artifact: GEMS.fetch("msgpack").fetch(:source_artifact)
)

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
