# frozen_string_literal: true

require "json"
require "msgpack"
require "sqlite3"
require "pg"

value = {"rubycc" => "distroless", "ok" => true}
raise "JSON round-trip failed" unless JSON.parse(JSON.generate(value)) == value
raise "MessagePack round-trip failed" unless MessagePack.unpack(MessagePack.pack(value)) == value

database = SQLite3::Database.new(":memory:")
database.execute("CREATE TABLE checks (value INTEGER)")
database.execute("INSERT INTO checks VALUES (42)")
raise "SQLite runtime check failed" unless database.get_first_value("SELECT value FROM checks") == 42
database.close

raise "libpq runtime check failed" unless PG.library_version.to_i.positive?

forbidden = %w[
  /bin/sh
  /usr/bin/sh
  /bin/dash
  /bin/bash
  /usr/bin/bash
  /usr/bin/cc
  /usr/bin/gcc
  /usr/bin/clang
  /usr/bin/make
]
present = forbidden.select { |path| File.exist?(path) }
raise "distroless check failed: #{present.join(", ")}" unless present.empty?
raise "libc development headers remain" if Dir.exist?("/usr/include")
raise "Ruby development headers remain" unless Dir.glob("/usr/local/include/ruby*").empty?

puts "rubycc distroless sample: PASS"
