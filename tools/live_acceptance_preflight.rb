# frozen_string_literal: true

# Fail-fast preflight for the live acceptance job.  It records the measured
# execution context before any networked test starts, so a missing tool or an
# incorrectly configured job cannot be mistaken for a skipped acceptance.

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "ci_result"

module Rubycc
  module LiveAcceptancePreflight
    module_function

    ROOT = File.expand_path("..", __dir__).freeze

    def command_path(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
        candidate = File.join(directory, name)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    def command_version(path, *args)
      output, status = Open3.capture2e(path, *args)
      { "path" => path, "output" => output.to_s.lines.first.to_s.strip,
        "ok" => status.success? }
    rescue SystemCallError => e
      { "path" => path, "output" => "#{e.class}: #{e.message}", "ok" => false }
    end

    def capture_command(*command)
      output, status = Open3.capture2e(*command)
      [output, status.success?]
    rescue SystemCallError => e
      ["#{e.class}: #{e.message}", false]
    end

    def record_result(path, result)
      path = File.expand_path(path)
      FileUtils.mkdir_p(File.dirname(path))
      lock_path = "#{path}.lock"
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        document = if File.file?(path) && File.size(path).positive?
                     Rubycc::CIResult.read(path)
                   else
                     Rubycc::CIResult.document(results: [], metadata: result.slice(
                       "profile", "host", "target", "runner", "libc", "network"
                     ))
                   end
        results = document.fetch("results")
        if results.any? { |entry| entry["id"] == result["id"] }
          raise Rubycc::CIResult::Error, "duplicate live preflight result"
        end
        results << result
        Rubycc::CIResult.write(path, results: results, metadata: document.fetch("metadata"))
      ensure
        lock.flock(File::LOCK_UN) if lock
      end
    end

    def run
      configured_result_path = ENV.fetch("CI_RESULT_PATH", "tmp/ci/acceptance-results.json")
      result_path = configured_result_path.empty? ? "tmp/ci/acceptance-results.json" : configured_result_path
      profile = ENV.fetch("CI_PROFILE", "acceptance-live")
      network = ENV.fetch("CI_NETWORK", "live")
      strict = ENV.fetch("RMAKE_ACCEPTANCE_STRICT", "")
      ruby = command_version(RbConfig.ruby, "-v")
      gem = command_path("gem")
      curl = command_path("curl")
      rmake = File.join(ROOT, "exe/rmake")
      rubycc = File.join(ROOT, "exe/rubycc")
      uname, uname_ok = capture_command("uname", "-m")

      context = {
        "profile" => profile,
        "network" => network,
        "strict" => strict,
        "uname_machine" => uname.to_s.strip,
        "uname_ok" => uname_ok,
        "ruby_path" => RbConfig.ruby,
        "ruby_version" => ruby.fetch("output"),
        "ruby_ok" => ruby.fetch("ok"),
        "ruby_host_cpu" => RbConfig::CONFIG["host_cpu"].to_s,
        "ruby_arch" => RbConfig::CONFIG["arch"].to_s,
        "gem" => gem && command_version(gem, "--version"),
        "curl" => curl && command_version(curl, "--version"),
        "rmake_path" => rmake,
        "rmake_available" => File.file?(rmake),
        "rubycc_path" => rubycc,
        "rubycc_available" => File.file?(rubycc),
        "artifact_report_path" => ENV["CI_ARTIFACT_REPORT_PATH"].to_s,
        "result_path" => File.expand_path(result_path)
      }

      failures = []
      failures << "CI_PROFILE must be acceptance-live" unless profile == "acceptance-live"
      failures << "CI_NETWORK must be live" unless network == "live"
      failures << "RMAKE_ACCEPTANCE_STRICT must be 1" unless strict == "1"
      failures << "Ruby is unavailable" unless ruby.fetch("ok")
      failures << "gem executable is unavailable" unless gem
      failures << "curl executable is unavailable" unless curl
      failures << "exe/rmake is unavailable" unless File.file?(rmake)
      failures << "exe/rubycc is unavailable" unless File.file?(rubycc)
      failures << "CI_RESULT_PATH is empty" if configured_result_path.empty?
      failures << "CI_ARTIFACT_REPORT_PATH is empty" if ENV.fetch("CI_ARTIFACT_REPORT_PATH", "").empty?
      failures << "uname failed" unless uname_ok

      metadata = {
        "profile" => profile,
        "network" => network
      }
      result = Rubycc::CIResult.result(
        id: "acceptance-live-preflight",
        state: failures.empty? ? "pass" : "fail",
        reason: failures.empty? ? nil : failures.join("; "),
        **metadata,
        **context
      )
      record_result(result_path, result)

      puts JSON.pretty_generate(context)
      return 0 if failures.empty?

      warn "acceptance-live-preflight: fail: #{failures.join("; ")}"
      1
    rescue SystemCallError => e
      warn "acceptance-live-preflight: #{e.class}: #{e.message}"
      1
    end
  end
end

exit Rubycc::LiveAcceptancePreflight.run if $PROGRAM_NAME == __FILE__
