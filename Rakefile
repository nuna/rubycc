# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.pattern = "test/**/test_*.rb"
  t.verbose = true
end

task default: :test

# M5 H5 (Step 105): compile-throughput benchmark (requirement N1, preprocessed
# lines/sec on real gem sources). On-demand dev task; NOT part of `rake test`
# (fetches gems from rubygems.org, takes minutes). Reports land in
# benchmark/results/throughput-*.{md,json}.
namespace :bench do
  desc "Measure compile throughput (lines/sec) on real gem C sources (network required; not part of `rake test`)"
  task :throughput do
    ruby "benchmark/throughput.rb"
  end
end

# M5 H3 (Step 92): corpus C-extension #include census. On-demand dev task; NOT
# part of `rake test` (which stays network-free). It fetches the gems listed in
# test/corpus/gems.rb and regenerates the committed snapshot
# test/corpus/include-census.md. Re-run and commit the snapshot to update it.
namespace :corpus do
  desc "Census corpus C-extension #include usage into test/corpus/include-census.md (network required; not part of `rake test`)"
  task :census do
    require_relative "test/corpus/census"
    path = Corpus::Census.run_and_write_report
    puts "wrote #{path}"
  end

  desc "Scan cached R10 corpus provenance and variadic candidates (cache required; no network; not part of `rake test`)"
  task :r10_scan do
    cache = ENV["R10_CORPUS_CACHE"] || ENV["RUBYCC_CORPUS_CACHE"]
    abort "set R10_CORPUS_CACHE or RUBYCC_CORPUS_CACHE to an existing corpus cache" if cache.to_s.empty?

    ruby "tools/r10_corpus_scan.rb", "--cache", cache
  end

  desc "Validate and render the reviewed R10 classification ledger (cache-free; not part of `rake test`)"
  task :r10_manual_validate do
    ruby "tools/r10_manual_classification.rb", "--render"
  end
end

# M4 acceptance support: run named test files on AArch64 without an AArch64
# machine, in an arm64 container the host's binfmt handler emulates. This is
# NOT a substitute for the native runner (docs/CI.md is explicit that QEMU does
# not stand in for native integration) and NOT a gate on the whole suite: the
# emulation costs about 23x the native ARM runner's time per test (measured
# against weekly run 31500900897), so a full suite is an hour where the runner
# takes two and a half minutes. What it is for is the loop this repository kept
# paying for by hand -- dispatch the native job, wait, discover that the change
# only ever ran on x86-64, fix, dispatch again. Running the files a change
# touches here first turns that round trip into minutes.
#
# Requires Docker with an arm64 binfmt handler registered *with the F flag*, so
# the interpreter resolves inside the container's mount namespace:
#
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
#
# The host's own qemu-user registration is not enough on its own (Debian's
# handler is registered "PO", and its interpreter path does not exist inside the
# container image), which fails as a bare "exec ...: no such file or directory".
namespace :test do
  desc "Run FILES (test paths) on AArch64 in an emulated arm64 container (Docker + binfmt required; not part of `rake test`)"
  task :qemu_aarch64 do
    files = ENV["FILES"].to_s.split
    abort "set FILES to the test files to run, e.g. FILES='test/test_preprocessor.rb'" if files.empty?

    missing = files.reject { |path| File.file?(path) }
    abort "no such test file: #{missing.join(", ")}" unless missing.empty?

    # The image carries an AArch64 Ruby and an AArch64 gcc, so the differential
    # tests compare against a native compiler rather than a cross one. The
    # checkout is mounted, and bundler is pointed at a directory inside it so the
    # arm64 gems never mix with the host's.
    image = ENV.fetch("QEMU_IMAGE", "ruby:4.0")
    root = File.expand_path(__dir__)
    command = "bundle install --quiet && bundle exec ruby -Itest -e '" \
              "ARGV.each { |f| require File.expand_path(f) }' -- #{files.join(" ")}"
    # Everything the container writes lands in the checkout through the mount,
    # so it runs as the invoking user: a root-owned tmp/ and .bundle would
    # otherwise be left behind for the host to trip over. HOME follows for the
    # same reason (bundler and rubygems both write under it), and tmp/ is
    # already git-ignored.
    sh "docker", "run", "--rm", "--platform", "linux/arm64",
       "--user", "#{Process.uid}:#{Process.gid}",
       "-v", "#{root}:/w", "-w", "/w",
       "-e", "HOME=/w/tmp/qemu-aarch64-home",
       "-e", "BUNDLE_PATH=/w/tmp/qemu-aarch64-bundle",
       "-e", "CI_SKIP_PROFILE=native-aarch64",
       image, "bash", "-lc", command
  end
end
