#!/usr/bin/env ruby
# frozen_string_literal: true

# M3 着手前作業(docs/development/ROADMAP.md §6 冒頭)。
#
# rmake / conftest 対応の一次資料は「実物の mkmf が生成した Makefile と conftest」。
# 仕様書(POSIX make)から演繹せず、代表 gem の extconf.rb を実際に実行して生成物
# (Makefile・mkmf.log・extconf.h)を test/fixtures/mkmf/ にコーパス化し、そこから
# 逆算で B1〜B5 の機能セットを決める。conftest ソース自体は probe 後に mkmf が削除
# するが、mkmf.log に "checked program was:" として全文が残るのでそれで代替する。
#
# sqlite3 / pg はこの環境にシステム dev ヘッダ(sqlite3.h / libpq-fe.h)が無く
# extconf.rb が失敗するため対象外(test/fixtures/mkmf/README.md 参照。dev ライブラリ
# 導入後の環境で本ツールを再実行すれば追加できる)。
#
# Usage:
#   tools/collect_mkmf_corpus.rb [work_dir]
#   CORPUS_WORK=/path/to/work tools/collect_mkmf_corpus.rb

require "fileutils"
require "open3"
require "rbconfig"
require "rubygems"
require "time"

RUBYCC_ROOT = File.expand_path("..", __dir__)
WORK_DIR = File.expand_path(ARGV[0] || ENV["CORPUS_WORK"] || "/tmp/rubycc_corpus")
FIXTURES_ROOT = File.join(RUBYCC_ROOT, "test/fixtures/mkmf")

# The parser Makefile is also used by the network acceptance test. Keep the
# committed fixture reproducible when the collector runs on another machine:
# retain the mkmf.log as collected evidence, but replace only these Makefile
# assignments with a fixed logical x86_64 fixture identity. The acceptance
# helper then injects the current Ruby's RbConfig values before building.
PORTABLE_JSON_PARSER_ASSIGNMENTS = {
  /^topdir = .*$/ => "topdir = /rubycc-fixture/ruby-4.0.6/include/ruby-4.0.6",
  /^arch_hdrdir = .*$/ => "arch_hdrdir = /rubycc-fixture/ruby-4.0.6/include/ruby-4.0.6/x86_64-linux",
  /^prefix = \$\(DESTDIR\).*$/ => "prefix = $(DESTDIR)/rubycc-fixture/ruby-4.0.6",
  /^arch = .*$/ => "arch = x86_64-linux",
  /^ruby_version = .*$/ => "ruby_version = 4.0.6"
}.freeze

# name => { version: "x.y.z" | :latest, ext_dirs: { fixture_ext_name => relative_path },
#           extconf_env: { ... } (optional) }
GEMS = {
  "json" => {
    version: "2.21.1",
    ext_dirs: {
      "parser" => "ext/json/ext/parser",
      "generator" => "ext/json/ext/generator"
    },
    # rubycc has no SSE intrinsics / inline-asm support (docs/development/STEPS.md Step 44):
    # json's simd/conf.rb probes gcc for a usable SSE2+cpuid.h path and, when found,
    # generator.c/parser.c unconditionally use _mm_* intrinsics, which real gcc-built
    # mkmf output would reflect but which is irrelevant to the Makefile/conftest shape
    # we're corpus-ing here. JSON_DISABLE_SIMD=1 is the gem's own documented switch
    # (extconf.rb: enable_config('parser-use-simd'/'generator-use-simd')) and keeps
    # this collection consistent with tools/m2_acceptance.rb's build of the same gem.
    extconf_env: { "JSON_DISABLE_SIMD" => "1" }
  },
  "msgpack" => {
    version: "1.8.3",
    ext_dirs: { "msgpack" => "ext/msgpack" }
  },
  "racc" => {
    version: :latest,
    ext_dirs: { "cparse" => "ext/racc/cparse" }
  },
  "redcarpet" => {
    version: :latest,
    ext_dirs: { "redcarpet" => "ext/redcarpet" }
  },
  "bigdecimal" => {
    version: :latest,
    ext_dirs: { "bigdecimal" => "ext/bigdecimal" }
  }
}.freeze

# Environment variables cleared before running extconf.rb so the probe reflects
# a plain, unmodified environment (mkmf's own compiler/tool discovery) rather
# than anything leaked from this repo's own Bundler/rubycc setup.
CLEAN_ENV_UNSET = %w[
  RUBYOPT BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_PATH
  CC CXX LD AR CFLAGS CXXFLAGS LDFLAGS CPPFLAGS MAKE RUBYCC
].freeze

def step(msg)
  puts "==> #{msg}"
end

def clean_env(extra = {})
  CLEAN_ENV_UNSET.each_with_object({}) { |k, h| h[k] = nil }.merge(extra)
end

def normalize_fixture_makefile(name, ext_name, text)
  return text unless name == "json" && ext_name == "parser"

  PORTABLE_JSON_PARSER_ASSIGNMENTS.each do |pattern, replacement|
    count = text.scan(pattern).size
    raise "JSON parser Makefile expected one #{pattern.inspect} assignment, got #{count}" unless count == 1

    text = text.sub(pattern, replacement)
  end
  text
end

# --- material fetch (idempotent: skipped once already fetched/unpacked) ----

def fetch_gem(name, defn)
  pinned = defn[:version] != :latest
  version = pinned ? defn[:version] : nil

  gem_file =
    if pinned
      File.join(WORK_DIR, "#{name}-#{version}.gem")
    else
      Dir.glob(File.join(WORK_DIR, "#{name}-*.gem")).max_by { |p| File.mtime(p) }
    end

  if gem_file.nil? || !File.exist?(gem_file)
    step "fetching #{name}#{pinned ? " #{version}" : ' (latest)'}"
    args = ["gem", "fetch", name]
    args += ["--version", version] if pinned
    stdout, status = Open3.capture2e(*args, chdir: WORK_DIR)
    raise "gem fetch failed for #{name}:\n#{stdout}" unless status.success?

    match = stdout.match(/Downloaded #{Regexp.escape(name)}-(\S+)/)
    raise "could not parse version from `gem fetch` output for #{name}:\n#{stdout}" unless match

    version = match[1]
    gem_file = File.join(WORK_DIR, "#{name}-#{version}.gem")
  else
    version ||= File.basename(gem_file, ".gem").sub("#{name}-", "")
  end

  unpack_dir = File.join(WORK_DIR, "#{name}-#{version}")
  sentinel = File.join(unpack_dir, ".corpus_fetched")
  if File.exist?(sentinel)
    step "reusing unpacked #{name} #{version}"
  else
    step "unpacking #{name} #{version}"
    FileUtils.rm_rf(unpack_dir)
    stdout, status = Open3.capture2e("gem", "unpack", gem_file, chdir: WORK_DIR)
    raise "gem unpack failed for #{name} #{version}:\n#{stdout}" unless status.success?

    FileUtils.touch(sentinel)
  end

  [unpack_dir, version]
end

# --- extconf.rb execution and fixture collection ---------------------------

def collect_ext(name, version, ext_name, ext_dir, extra_env)
  unless File.exist?(File.join(ext_dir, "extconf.rb"))
    return { ok: false, reason: "extconf.rb not found at #{ext_dir}" }
  end

  step "running extconf.rb: #{name} #{version} / #{ext_name}"
  stdout, status = Open3.capture2e(clean_env(extra_env), "ruby", "extconf.rb", chdir: ext_dir)
  unless status.success?
    return { ok: false, reason: "extconf.rb failed (exit #{status.exitstatus}):\n#{stdout}" }
  end

  makefile = File.join(ext_dir, "Makefile")
  return { ok: false, reason: "extconf.rb succeeded but produced no Makefile" } unless File.exist?(makefile)

  mkmf_log = File.join(ext_dir, "mkmf.log")
  extconf_h = File.join(ext_dir, "extconf.h")

  dest_dir = File.join(FIXTURES_ROOT, "#{name}-#{version}", ext_name)
  FileUtils.rm_rf(dest_dir)
  FileUtils.mkdir_p(dest_dir)
  makefile_text = File.read(makefile)
  File.write(File.join(dest_dir, "Makefile"), normalize_fixture_makefile(name, ext_name, makefile_text))
  FileUtils.cp(mkmf_log, dest_dir) if File.exist?(mkmf_log)
  FileUtils.cp(extconf_h, dest_dir) if File.exist?(extconf_h)

  makefile_lines = File.readlines(File.join(dest_dir, "Makefile")).size
  conftest_count =
    if File.exist?(File.join(dest_dir, "mkmf.log"))
      File.read(File.join(dest_dir, "mkmf.log")).scan("checked program was:").size
    else
      0
    end

  { ok: true, dest_dir: dest_dir, makefile_lines: makefile_lines, conftest_count: conftest_count }
end

def write_provenance(name, version, ext_results)
  gem_dir = File.join(FIXTURES_ROOT, "#{name}-#{version}")
  return unless Dir.exist?(gem_dir)

  exts_summary = ext_results.map do |ext_name, r|
    if r[:ok]
      "  #{ext_name}: ok (Makefile #{r[:makefile_lines]} lines, #{r[:conftest_count]} conftest entries in mkmf.log)"
    else
      "  #{ext_name}: FAILED - #{r[:reason].to_s.lines.first&.strip}"
    end
  end.join("\n")

  File.write(File.join(gem_dir, "provenance.txt"), <<~TXT)
    gem: #{name} #{version}
    collected_at: #{Time.now.utc.iso8601}
    ruby_version: #{RUBY_VERSION} (#{RUBY_PLATFORM})
    cc: #{RbConfig::CONFIG['CC']}
    rubygems_version: #{Gem::VERSION}
    collector: tools/collect_mkmf_corpus.rb
    exts:
    #{exts_summary}
  TXT
end

# --- main --------------------------------------------------------------

step "rubycc mkmf corpus collection"
step "work dir: #{WORK_DIR}"
FileUtils.mkdir_p(WORK_DIR)
FileUtils.mkdir_p(FIXTURES_ROOT)

all_results = {}

GEMS.each do |name, defn|
  begin
    unpack_dir, version = fetch_gem(name, defn)
  rescue => e
    warn "SKIP #{name}: fetch/unpack failed (#{e.message.lines.first&.strip})"
    all_results[name] = { version: nil, exts: {} }
    next
  end

  ext_results = {}
  defn[:ext_dirs].each do |ext_name, rel_path|
    ext_dir = File.join(unpack_dir, rel_path)
    ext_results[ext_name] = collect_ext(name, version, ext_name, ext_dir, defn[:extconf_env] || {})
  end

  write_provenance(name, version, ext_results)
  all_results[name] = { version: version, exts: ext_results }
end

puts
puts "==================== mkmf corpus collection summary ===================="
total_ok = 0
all_results.each do |name, result|
  if result[:exts].empty?
    puts "SKIP  #{name} (gem fetch/unpack failed)"
    next
  end

  result[:exts].each do |ext_name, r|
    label = "#{name} #{result[:version]} / #{ext_name}"
    if r[:ok]
      total_ok += 1
      puts "OK    #{label}  (Makefile #{r[:makefile_lines]} lines, #{r[:conftest_count]} conftest entries)"
    else
      puts "FAIL  #{label}"
      puts "        #{r[:reason].to_s.lines.first&.strip}"
    end
  end
end
puts "==========================================================================="

exit(total_ok.positive? ? 0 : 1)
