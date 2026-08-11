# frozen_string_literal: true

require "fileutils"
require_relative "../../tools/ci_result"

# Optional result sink for acceptance tests.
#
# No environment variable means no file is written, so the ordinary network-
# free test suite keeps its existing behaviour. CI sets CI_RESULT_PATH and
# CI_PROFILE to make the required acceptance IDs observable without parsing
# Minitest's human-readable output.
module AcceptanceResultReporter
  module_function

  # External service unavailability means the live acceptance is unknown. It
  # must never become product-green; strict CI records it as inconclusive and
  # the structured checker still rejects that state.
  INCONCLUSIVE_FAILURE_KINDS = %i[
    timeout rate_limited server_error dns_failure connection_refused tls_failure environment
  ].freeze

  def enabled?
    path = ENV["CI_RESULT_PATH"]
    !path.nil? && !path.empty?
  end

  def with_result(id, **details)
    yield
    record(id, "pass", nil, **details)
  rescue Minitest::Skip => e
    record(id, "skipped", e.message, **details)
    raise
  rescue Minitest::Assertion => e
    record(id, "fail", failure_reason(e), **details)
    raise
  rescue StandardError => e
    state = inconclusive_failure?(e) ? "inconclusive" : "fail"
    record(id, state, failure_reason(e), **details)
    raise
  end

  def inconclusive_failure?(error)
    error.respond_to?(:kind) && INCONCLUSIVE_FAILURE_KINDS.include?(error.kind)
  end

  def failure_reason(error)
    reason = "#{error.class}: #{error.message}"
    output = error.output if error.respond_to?(:output)
    output = String(output).strip unless output.nil?
    output && !output.empty? ? "#{reason}\n#{output}" : reason
  end

  def record(id, state, reason = nil, **details)
    return unless enabled?

    path = ENV.fetch("CI_RESULT_PATH")
    FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
    lock_path = "#{path}.lock"
    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      # A CI step may create the destination before the first test starts
      # (for example with `mktemp` or an artifact staging action). An empty
      # file is still the absence of a result document, not malformed JSON.
      document = if File.file?(path) && File.size(path).positive?
                   Rubycc::CIResult.read(path)
                 else
                   Rubycc::CIResult.document(results: [], metadata: metadata)
                 end
      existing_profile = document.fetch("metadata", {})["profile"]
      current_profile = metadata.fetch(:profile)
      if existing_profile && existing_profile != current_profile
        raise Rubycc::CIResult::Error, "acceptance result file mixes profiles: " \
                                      "#{existing_profile.inspect} and #{current_profile.inspect}"
      end
      results = document.fetch("results")
      raise Rubycc::CIResult::Error, "duplicate acceptance result ID: #{id}" if results.any? { |entry| entry["id"] == id }

      results << Rubycc::CIResult.result(id: id, state: state, reason: reason, **metadata, **details)
      Rubycc::CIResult.write(path, results: results, metadata: document.fetch("metadata", metadata))
    ensure
      lock.flock(File::LOCK_UN) if lock
    end
  end

  def metadata
    {
      profile: ENV.fetch("CI_PROFILE", "acceptance-live"),
      host: ENV["CI_HOST"],
      target: ENV["CI_TARGET"],
      runner: ENV["CI_RUNNER"],
      libc: ENV["CI_LIBC"],
      network: ENV.fetch("CI_NETWORK", "live")
    }.compact
  end
end
