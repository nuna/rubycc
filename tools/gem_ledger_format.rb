# frozen_string_literal: true

# The on-disk shape shared by the two gem ledgers this repository keeps:
#
#   data/verified_gems.json   (d)-level  -- written by tools/verify_gem_tests.rb
#   data/buildable_gems.json  build_load -- written by tools/verify_corpus_candidate.rb
#
# What the two files *claim* is deliberately different (see data/README.md);
# what they *look like* must not be. Two copies of the emitter would let the
# house style drift, and two copies of the environment spelling would let the
# same machine be recorded under two different names -- at which point the
# records could no longer be compared or joined at all.
#
# Nothing here knows which claim it is formatting: callers pass the key their
# array of records lives under.

require "json"
require "rbconfig"

module GemLedgerFormat
  # The key order every record is written in. Both ledgers describe a record the
  # same way -- which versions, measured where, when, and on what evidence --
  # because that is the part of the two claims that is genuinely the same.
  RECORD_KEY_ORDER = %w[versions environment verified_at evidence].freeze

  module_function

  # "glibc x86_64 / ruby 3.4.5" -- the shape the existing entries use. The libc is
  # read from RbConfig's arch triplet, which is how MRI itself distinguishes a musl
  # build ("x86_64-linux-musl") from a glibc one ("x86_64-linux").
  def environment_string
    arch = RbConfig::CONFIG["arch"].to_s
    libc =
      if arch.include?("musl") then "musl"
      elsif arch.include?("linux") then "glibc"
      else arch.split("-").last
      end
    "#{libc} #{RbConfig::CONFIG['host_cpu']} / ruby #{RUBY_VERSION}"
  end

  # The ledgers' exact house style: two-space indent, one key per line, and
  # `versions` as a single-line inline array. JSON.pretty_generate would explode
  # every array over three lines and rewrite every existing entry, so the files
  # get this tiny emitter instead. The nesting is fixed (entry -> records ->
  # record), so the indentation is hard-coded per level rather than made generic.
  #
  # +records_key+ is the entry key holding the array ("verifications" for the
  # (d)-level database, "builds" for the build_load ledger).
  def emit(db, records_key:)
    return "{}\n" if db.empty?

    entries = db.map do |name, attrs|
      fields = [records_key, "notes"].map do |key|
        rendered = key == records_key ? emit_records(Array(attrs[key])) : JSON.generate(attrs[key])
        "    #{JSON.generate(key)}: #{rendered}"
      end
      "  #{JSON.generate(name)}: {\n#{fields.join(",\n")}\n  }"
    end
    "{\n#{entries.join(",\n")}\n}\n"
  end

  # The record array of one entry, one record per brace block.
  def emit_records(records)
    blocks = records.map do |record|
      fields = RECORD_KEY_ORDER.map do |key|
        value = record[key]
        rendered =
          if key == "versions"
            "[#{Array(value).map { |v| JSON.generate(v) }.join(', ')}]"
          else
            JSON.generate(value)
          end
        "        #{JSON.generate(key)}: #{rendered}"
      end
      "      {\n#{fields.join(",\n")}\n      }"
    end
    "[\n#{blocks.join(",\n")}\n    ]"
  end
end
