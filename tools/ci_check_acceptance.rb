# frozen_string_literal: true

# Verify that every required acceptance ID produced a result.
#
# Usage:
#   ruby tools/ci_check_acceptance.rb --manifest config/ci/acceptance_manifest.json \
#     --results tmp/ci/acceptance-results.json
#
# The checker consumes the structured result format from ci_result.rb. It does
# not parse Minitest logs; ci_check_skips.rb remains responsible for the legacy
# Tier A summary guard.

require "json"
require "optparse"
require "date"
require_relative "ci_result"

module Rubycc
  module CICheckAcceptance
    module_function

    def load_manifest(path)
      value = JSON.parse(File.read(path))
      unless value.is_a?(Hash) && value["version"] == CIResult::VERSION
        raise CIResult::Error, "unsupported acceptance manifest version in #{path}"
      end
      required = value["required"]
      raise CIResult::Error, "acceptance manifest required must be an array" unless required.is_a?(Array)

      entries = required.map { |entry| validate_manifest_entry(entry) }
      ids = entries.map { |entry| entry["id"] }
      duplicates = ids.group_by(&:itself).select { |_id, list| list.length > 1 }.keys
      unless duplicates.empty?
        raise CIResult::Error, "duplicate required acceptance IDs: #{duplicates.join(", ")}"
      end

      profile_context = value.fetch("profile_context", {})
      unless profile_context.is_a?(Hash) && profile_context.all? do |profile, context|
               profile.is_a?(String) && !profile.empty? && context.is_a?(Hash) &&
                 context.all? { |key, entry| key.is_a?(String) && entry.is_a?(String) && !entry.empty? }
             end
        raise CIResult::Error, "acceptance manifest profile_context must be an object of string maps"
      end

      artifacts = value.fetch("artifacts", [])
      unless artifacts.is_a?(Array)
        raise CIResult::Error, "acceptance manifest artifacts must be an array"
      end
      artifacts = artifacts.map { |artifact| validate_manifest_artifact(artifact) }
      artifact_ids = artifacts.map { |artifact| artifact.fetch("id") }
      duplicate_artifacts = artifact_ids.group_by(&:itself).select { |_id, list| list.length > 1 }.keys
      unless duplicate_artifacts.empty?
        raise CIResult::Error, "duplicate acceptance artifact IDs: #{duplicate_artifacts.join(", ")}"
      end
      known_artifact_ids = artifact_ids.to_h { |id| [id, true] }
      entries.each do |entry|
        unknown = entry.fetch("artifacts").reject { |id| known_artifact_ids.key?(id) }
        unless unknown.empty?
          raise CIResult::Error, "acceptance #{entry.fetch("id")} references unknown artifacts: #{unknown.join(", ")}"
        end
      end

      {
        "version" => value["version"], "required" => entries,
        "profile_context" => profile_context, "artifacts" => artifacts
      }
    rescue Errno::ENOENT, Errno::EACCES => e
      raise CIResult::Error, "cannot read acceptance manifest #{path}: #{e.message}", cause: e
    rescue JSON::ParserError => e
      raise CIResult::Error, "invalid JSON in acceptance manifest #{path}: #{e.message}", cause: e
    end

    def validate_manifest_entry(entry)
      raise CIResult::Error, "each acceptance manifest entry must be an object" unless entry.is_a?(Hash)

      id = entry["id"]
      CIResult.normalize_id(id)
      profiles = entry.fetch("profiles", [])
      unless profiles.is_a?(Array) && profiles.all? { |profile| profile.is_a?(String) && !profile.empty? }
        raise CIResult::Error, "profiles for #{id.inspect} must be a non-empty-string array"
      end
      states = entry.fetch("allowed_states", ["pass"])
      unless states.is_a?(Array) && states.all? { |state| CIResult::STATES.include?(state) }
        raise CIResult::Error, "allowed_states for #{id.inspect} contains an unsupported state"
      end

      artifact_ids = entry.fetch("artifacts", [])
      unless artifact_ids.is_a?(Array) && artifact_ids.all? { |artifact_id| artifact_id.is_a?(String) && !artifact_id.empty? }
        raise CIResult::Error, "artifacts for #{id.inspect} must be a string array"
      end
      if artifact_ids.uniq.length != artifact_ids.length
        raise CIResult::Error, "artifacts for #{id.inspect} must not contain duplicates"
      end

      expires = entry.fetch("expires", nil)
      if expires && (!expires.is_a?(String) || !expires.match?(/\A\d{4}-\d{2}-\d{2}\z/))
        raise CIResult::Error, "expires for #{id.inspect} must be an ISO date"
      end
      if expires && Date.iso8601(expires) < Date.today
        raise CIResult::Error, "acceptance manifest entry #{id.inspect} expired on #{expires}"
      end

      {
        "id" => id,
        "description" => entry.fetch("description", ""),
        "profiles" => profiles,
        "allowed_states" => states,
        "artifacts" => artifact_ids,
        "owner" => entry.fetch("owner", "unassigned"),
        "expires" => expires
      }
    rescue Date::Error => e
      raise CIResult::Error, "invalid expires date for #{id.inspect}: #{e.message}", cause: e
    rescue KeyError => e
      raise CIResult::Error, "acceptance manifest entry is missing #{e.key.inspect}", cause: e
    end

    def validate_manifest_artifact(artifact)
      unless artifact.is_a?(Hash)
        raise CIResult::Error, "each acceptance artifact entry must be an object"
      end

      id = artifact["id"]
      CIResult.normalize_id(id)
      kind = artifact.fetch("kind")
      unless kind.is_a?(String) && !kind.empty?
        raise CIResult::Error, "kind for artifact #{id.inspect} must be a non-empty string"
      end
      url = artifact.fetch("url")
      unless url.is_a?(String) && url.match?(%r{\Ahttps://[^\s]+\z})
        raise CIResult::Error, "url for artifact #{id.inspect} must be an HTTPS URL"
      end
      sha256 = artifact.fetch("sha256").to_s.downcase
      unless sha256.match?(/\A[0-9a-f]{64}\z/)
        raise CIResult::Error, "sha256 for artifact #{id.inspect} must be 64 hexadecimal characters"
      end
      required_fields = case kind
                        when "rubygems-gem" then %w[name version platform]
                        when "github-source-tarball" then %w[name version]
                        else []
                        end
      required_fields.each do |field|
        value = artifact[field]
        unless value.is_a?(String) && !value.empty?
          raise CIResult::Error, "#{field} for artifact #{id.inspect} must be a non-empty string"
        end
      end

      expires = artifact.fetch("expires", nil)
      if expires && (!expires.is_a?(String) || !expires.match?(/\A\d{4}-\d{2}-\d{2}\z/))
        raise CIResult::Error, "expires for artifact #{id.inspect} must be an ISO date"
      end
      if expires && Date.iso8601(expires) < Date.today
        raise CIResult::Error, "acceptance artifact #{id.inspect} expired on #{expires}"
      end

      fixture = artifact.fetch("fixture", nil)
      if fixture && (!fixture.is_a?(String) || fixture.empty? || fixture.start_with?("/") ||
                     fixture.split(/[\\\/]/).include?(".."))
        raise CIResult::Error, "fixture for artifact #{id.inspect} must be a relative path"
      end

      artifact.merge("id" => id, "kind" => kind, "url" => url, "sha256" => sha256)
    rescue KeyError => e
      raise CIResult::Error, "acceptance artifact is missing #{e.key.inspect}", cause: e
    rescue Date::Error => e
      raise CIResult::Error, "invalid artifact expires date for #{id.inspect}: #{e.message}", cause: e
    end

    def load_artifact_report(path)
      value = JSON.parse(File.read(path))
      raise CIResult::Error, "artifact report must be an array" unless value.is_a?(Array)

      entries = value.map do |entry|
        raise CIResult::Error, "each artifact report entry must be an object" unless entry.is_a?(Hash)

        id = entry.fetch("id")
        CIResult.normalize_id(id)
        %w[kind url expected_sha256 actual_sha256 bytes cache_hit].each do |field|
          raise CIResult::Error, "artifact report entry #{id.inspect} is missing #{field.inspect}" unless entry.key?(field)
        end
        expected = entry.fetch("expected_sha256").to_s.downcase
        actual = entry.fetch("actual_sha256").to_s.downcase
        unless expected.match?(/\A[0-9a-f]{64}\z/) && actual.match?(/\A[0-9a-f]{64}\z/)
          raise CIResult::Error, "artifact report digests for #{id.inspect} must be SHA-256 values"
        end
        unless entry.fetch("url").is_a?(String) && entry.fetch("url").match?(%r{\Ahttps://[^\s]+\z})
          raise CIResult::Error, "artifact report URL for #{id.inspect} must be HTTPS"
        end
        unless entry.fetch("kind").is_a?(String) && !entry.fetch("kind").empty?
          raise CIResult::Error, "artifact report kind for #{id.inspect} must be non-empty"
        end
        unless entry.fetch("bytes").is_a?(Integer) && entry.fetch("bytes").positive?
          raise CIResult::Error, "artifact report bytes for #{id.inspect} must be positive"
        end
        unless entry.fetch("cache_hit") == true || entry.fetch("cache_hit") == false
          raise CIResult::Error, "artifact report cache_hit for #{id.inspect} must be boolean"
        end

        entry.merge("id" => id, "expected_sha256" => expected, "actual_sha256" => actual)
      rescue KeyError => e
        raise CIResult::Error, "artifact report entry is missing #{e.key.inspect}", cause: e
      end
      ids = entries.map { |entry| entry.fetch("id") }
      duplicates = ids.group_by(&:itself).select { |_id, list| list.length > 1 }.keys
      raise CIResult::Error, "duplicate artifact report IDs: #{duplicates.join(", ")}" unless duplicates.empty?

      entries.to_h { |entry| [entry.fetch("id"), entry] }
    rescue Errno::ENOENT, Errno::EACCES => e
      raise CIResult::Error, "cannot read artifact report #{path}: #{e.message}", cause: e
    rescue JSON::ParserError => e
      raise CIResult::Error, "invalid artifact report #{path}: #{e.message}", cause: e
    end

    def check(manifest:, results:, profile: nil, strict: false, allow_inconclusive: false,
              artifact_report: nil)
      result_by_id = results.fetch("results").each_with_object({}) do |entry, index|
        id = entry.fetch("id")
        raise CIResult::Error, "duplicate result ID: #{id}" if index.key?(id)

        index[id] = entry
      end

      problems = []
      profile_context = manifest.fetch("profile_context", {})
      if profile && !profile_context.empty? && !profile_context.key?(profile)
        raise CIResult::Error, "unknown acceptance profile #{profile.inspect}"
      end
      required = manifest.fetch("required").select do |entry|
        profile.nil? || entry.fetch("profiles").empty? || entry.fetch("profiles").include?(profile)
      end
      problems << "no required acceptance entries selected for profile #{profile.inspect}" if profile && required.empty?

      artifact_by_id = artifact_report || {}
      manifest_artifacts = manifest.fetch("artifacts", []).to_h { |entry| [entry.fetch("id"), entry] }

      checked = required.map do |entry|
        id = entry.fetch("id")
        result = result_by_id[id]
        if result.nil?
          problems << "required acceptance #{id} was not executed"
          next entry.merge("actual_state" => nil)
        end

        state = result.fetch("state")
        if profile && result["profile"] != profile
          actual_profile = result["profile"] || "missing"
          problems << "required acceptance #{id} reported profile #{actual_profile.inspect}; " \
                      "expected #{profile.inspect}"
        end
        if state == "skipped" && strict
          problems << "required acceptance #{id} was skipped in strict mode"
        elsif state == "inconclusive"
          # This option is only for a non-strict diagnostic report. It must not
          # turn a required strict acceptance job green.
          problems << "required acceptance #{id} is inconclusive" unless allow_inconclusive && !strict
        elsif !entry.fetch("allowed_states").include?(state)
          problems << "required acceptance #{id} reported #{state.inspect} " \
                      "(allowed: #{entry.fetch("allowed_states").join(", ")})"
        end
        if profile
          expected_context = manifest.fetch("profile_context", {}).fetch(profile, {})
          expected_context.each do |key, expected|
            actual = result[key]
            problems << "required acceptance #{id} reported #{key}=#{actual.inspect}; " \
                        "expected #{expected.inspect}" unless actual == expected
          end
          if profile == "native-aarch64-smoke"
            {
              "uname_machine" => /\A(?:aarch64|arm64)\z/i,
              "ruby_host_cpu" => /\A(?:aarch64|arm64)\z/i,
              "ruby_arch" => /(?:aarch64|arm64)/i,
              "gcc_machine" => /aarch64/i
            }.each do |key, pattern|
              actual = result[key].to_s
              problems << "required acceptance #{id} reported invalid native #{key}=#{actual.inspect}" \
                unless actual.match?(pattern)
            end
          end
        end
        entry.fetch("artifacts", []).each do |artifact_id|
          expected_artifact = manifest_artifacts.fetch(artifact_id)
          actual_artifact = artifact_by_id[artifact_id]
          if actual_artifact.nil?
            problems << "required acceptance #{id} did not verify artifact #{artifact_id}"
            next
          end
          if actual_artifact.fetch("url") != expected_artifact.fetch("url")
            problems << "artifact #{artifact_id} reported URL #{actual_artifact.fetch("url").inspect}; " \
                       "expected #{expected_artifact.fetch("url").inspect}"
          end
          if actual_artifact.fetch("expected_sha256") != expected_artifact.fetch("sha256")
            problems << "artifact #{artifact_id} reported a different expected SHA-256"
          end
          unless actual_artifact.fetch("actual_sha256") == expected_artifact.fetch("sha256")
            problems << "artifact #{artifact_id} SHA-256 does not match the manifest"
          end
        end
        entry.merge("actual_state" => state, "reason" => result["reason"])
      end

      {
        "checked" => checked,
        "problems" => problems,
        "ok" => problems.empty?
      }
    end

    def print_report(report)
      report.fetch("checked").each do |entry|
        actual = entry["actual_state"] || "not-executed"
        reason = entry["reason"]
        suffix = reason.nil? || reason.empty? ? "" : " (#{reason})"
        puts format("  %-36s %s%s", entry.fetch("id"), actual, suffix)
      end

      if report.fetch("problems").empty?
        puts "ci_check_acceptance: OK"
        return
      end

      report.fetch("problems").each { |problem| warn "ci_check_acceptance: FAIL: #{problem}" }
      puts "ci_check_acceptance: FAILED"
    end

    def main(argv)
      options = { strict: false, allow_inconclusive: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby tools/ci_check_acceptance.rb --manifest PATH --results PATH [options]"
        opts.on("--manifest PATH", "acceptance manifest JSON") { |path| options[:manifest] = path }
        opts.on("--results PATH", "structured result JSON") { |path| options[:results] = path }
        opts.on("--profile NAME", "only check entries for this CI profile") { |profile| options[:profile] = profile }
        opts.on("--artifacts PATH", "verified artifact report JSON") { |path| options[:artifacts] = path }
        opts.on("--strict", "treat required skips as failures") { options[:strict] = true }
        opts.on("--allow-inconclusive", "permit inconclusive required results") do
          options[:allow_inconclusive] = true
        end
      end
      parser.parse!(argv)
      unless options[:manifest] && options[:results] && argv.empty?
        warn parser
        return 2
      end

      manifest = load_manifest(options[:manifest])
      results = CIResult.read(options[:results])
      artifact_report = options[:artifacts] && load_artifact_report(options[:artifacts])
      report = check(manifest: manifest, results: results,
                     profile: options[:profile], strict: options[:strict],
                     allow_inconclusive: options[:allow_inconclusive], artifact_report: artifact_report)
      print_report(report)
      report.fetch("ok") ? 0 : 1
    rescue CIResult::Error => e
      warn "ci_check_acceptance: #{e.message}"
      2
    end
  end
end

exit Rubycc::CICheckAcceptance.main(ARGV) if $PROGRAM_NAME == __FILE__
