# frozen_string_literal: true

# JSON C-extension workload: parse + generate a mid-sized document in a loop.
#
# The document is built once (a list of record hashes with mixed value types),
# then each iteration serialises it to a string and parses that string back.
# This exercises both the generator and parser C extensions -- the hot native
# code paths whose codegen we are comparing between gcc and rubycc builds -- so
# whichever json/ext/*.so is on the load path is what gets measured.
#
# The harness (benchmark/run.rb) selects the .so by controlling $LOAD_PATH, runs
# this script as a child process, and times the whole run. The iteration count
# is fixed here so every variant does identical work; a checksum is printed so
# the harness can confirm the two builds agree.

require "json"

RECORDS = 2000
ITERATIONS = 400

doc = {
  "generated_by" => "rubycc-benchmark",
  "count" => RECORDS,
  "records" => Array.new(RECORDS) do |i|
    {
      "id" => i,
      "name" => "record-#{i}",
      "active" => i.even?,
      "score" => (i * 1.5) - 0.25,
      "tags" => ["alpha", "beta", "gamma"].take((i % 3) + 1),
      "nested" => { "x" => i, "y" => -i, "label" => "n#{i % 97}" },
      "notes" => nil
    }
  end
}

checksum = 0
ITERATIONS.times do
  str = JSON.generate(doc)
  parsed = JSON.parse(str)
  checksum += parsed["records"].length
end

puts "json checksum=#{checksum} impl=#{JSON.parser}"
