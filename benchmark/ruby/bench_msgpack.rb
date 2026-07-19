# frozen_string_literal: true

# MessagePack C-extension workload: pack + unpack a mid-sized structure in a
# loop.
#
# A representative nested structure (arrays of record hashes with mixed value
# types) is built once, then each iteration packs it to a binary blob and
# unpacks that blob back to Ruby objects. This drives the packer and unpacker C
# extensions -- the native code paths whose gcc-vs-rubycc codegen we compare --
# so whichever msgpack/msgpack.so is on the load path is what gets measured.
#
# The harness (benchmark/run.rb) selects the .so via $LOAD_PATH, runs this
# script as a child process, and times the whole run. Work is fixed; a checksum
# is printed so the harness can confirm the two builds agree.

require "msgpack"

RECORDS = 2000
ITERATIONS = 500

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
      "nested" => { "x" => i, "y" => -i, "label" => "n#{i % 97}" }
    }
  end
}

checksum = 0
ITERATIONS.times do
  blob = MessagePack.pack(doc)
  restored = MessagePack.unpack(blob)
  checksum += restored["records"].length
end

puts "msgpack checksum=#{checksum} bytes=#{MessagePack.pack(doc).bytesize}"
