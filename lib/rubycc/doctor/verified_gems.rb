# frozen_string_literal: true

require "json"

module Rubycc
  module Doctor
    # The build-verified gem database (data/verified_gems.json), the primary
    # reference rubycc doctor consults before ever attempting a build. A gem whose
    # resolved version satisfies one of the recorded `versions` entries is reported
    # as verified with no network access and no build.
    #
    # The schema is documented in data/README.md. Version entries are matched with
    # Gem::Requirement, so both exact pins ("2.21.1") and ranges (">= 1.8, < 2")
    # work.
    class VerifiedGems
      # data/verified_gems.json relative to this file (lib/rubycc/doctor/).
      DEFAULT_PATH = File.expand_path("../../../data/verified_gems.json", __dir__)

      # A single verified-gem record, mirroring the JSON schema.
      Record = Struct.new(:name, :versions, :verified_at, :environment, :evidence, :notes, keyword_init: true)

      # Load the database from +path+ (defaults to the shipped file).
      def self.load(path = DEFAULT_PATH)
        new(JSON.parse(File.read(path)))
      end

      def initialize(raw)
        @records = {}
        raw.each do |name, attrs|
          @records[name] = Record.new(
            name: name,
            versions: Array(attrs["versions"]),
            verified_at: attrs["verified_at"],
            environment: attrs["environment"],
            evidence: attrs["evidence"],
            notes: attrs["notes"]
          )
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

      # The Record that verifies +name+ at +version+, or nil. A version satisfies a
      # record when it meets at least one of the record's `versions` requirements.
      def match(name, version)
        record = @records[name]
        return nil unless record && version

        gem_version = Gem::Version.new(version)
        satisfied = record.versions.any? do |req|
          # A range entry may be comma-joined (">= 1.8, < 2"); split it into the
          # individual constraints Gem::Requirement expects as separate arguments.
          Gem::Requirement.new(*req.split(",").map(&:strip)).satisfied_by?(gem_version)
        rescue ArgumentError
          false
        end
        satisfied ? record : nil
      end
    end
  end
end
