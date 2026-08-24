# frozen_string_literal: true

require "json"

module Rubycc
  module Doctor
    # The build-verified gem database (data/verified_gems.json), the primary
    # reference rubycc doctor consults before ever attempting a build. A gem whose
    # resolved version satisfies one of the recorded `versions` entries is reported
    # as verified with no network access and no build.
    #
    # The schema is documented in data/README.md. One gem is one entry, and an
    # entry holds a list of verifications -- one per environment it was confirmed
    # in, in insertion (oldest-first) order:
    #
    #   { "json": { "verifications": [ { "versions": ["2.21.1"],
    #                                    "environment": "glibc x86_64 / ruby 3.4.5",
    #                                    "verified_at": "2026-07-17",
    #                                    "evidence": "..." } ],
    #               "notes": "..." } }
    #
    # `versions` sits inside each record rather than once at the entry level
    # because the versions actually exercised may differ per environment; hoisting
    # them would claim more than was measured. The absence of a record is itself
    # the statement that the gem is unverified in that environment.
    #
    # Version entries are matched with Gem::Requirement, so both exact pins
    # ("2.21.1") and ranges (">= 1.8, < 2") work.
    class VerifiedGems
      # data/verified_gems.json relative to this file (lib/rubycc/doctor/).
      DEFAULT_PATH = File.expand_path("../../../data/verified_gems.json", __dir__)

      # One environment's verification of a gem, mirroring the JSON schema.
      Verification = Struct.new(:versions, :environment, :verified_at, :evidence, keyword_init: true)

      # A verified-gem entry: the gem's name, every verification recorded for it,
      # and the human-owned notes.
      Record = Struct.new(:name, :verifications, :notes, keyword_init: true) do
        # Every version any environment verified, de-duplicated and in the order
        # the records list them. Callers that only ask "which versions are known
        # good at all?" (the schema test, listings) want this rather than a
        # per-environment breakdown.
        def versions
          verifications.flat_map(&:versions).uniq
        end
      end

      # Load the database from +path+ (defaults to the shipped file).
      #
      # The encoding is named rather than inherited from the locale: JSON *is*
      # UTF-8 (RFC 8259 §8.1), so there is nothing to guess. The shipped file's
      # notes carry non-ASCII punctuation, which a locale-tagged read rejects.
      def self.load(path = DEFAULT_PATH)
        new(JSON.parse(File.read(path, encoding: Encoding::UTF_8)))
      end

      def initialize(raw)
        @records = {}
        raw.each do |name, attrs|
          verifications = Array(attrs["verifications"]).map do |v|
            Verification.new(
              versions: Array(v["versions"]),
              environment: v["environment"],
              verified_at: v["verified_at"],
              evidence: v["evidence"]
            )
          end
          @records[name] = Record.new(name: name, verifications: verifications, notes: attrs["notes"])
        end
      end

      # All records (used by the schema test and for listing).
      attr_reader :records

      # The record for +name+, or nil.
      def [](name)
        @records[name]
      end

      # Whether +name+ at +version+ is verified. A nil version can never match an
      # exact pin, so an unknown version is treated as not verified.
      def verified?(name, version)
        !match(name, version).nil?
      end

      # The Record that verifies +name+ at +version+, or nil. A version satisfies
      # an entry when at least one of its verifications covers it -- being
      # verified in any one environment is what "verified" has always meant here,
      # and splitting the schema per environment must not narrow it.
      def match(name, version)
        record = @records[name]
        return nil if record.nil? || matching_verifications(name, version).empty?

        record
      end

      # Every Verification of +name+ whose `versions` cover +version+, in the
      # order they are recorded; empty when nothing matches. This is what a caller
      # asks when it needs to say *where* the version was verified, not just
      # whether it was.
      def matching_verifications(name, version)
        record = @records[name]
        return [] unless record && version

        gem_version = Gem::Version.new(version)
        record.verifications.select do |verification|
          verification.versions.any? do |req|
            # A range entry may be comma-joined (">= 1.8, < 2"); split it into the
            # individual constraints Gem::Requirement expects as separate arguments.
            Gem::Requirement.new(*req.split(",").map(&:strip)).satisfied_by?(gem_version)
          rescue ArgumentError
            false
          end
        end
      end
    end
  end
end
