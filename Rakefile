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
