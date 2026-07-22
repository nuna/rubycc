# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.pattern = "test/**/test_*.rb"
  t.verbose = true
end

task default: :test

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
end
