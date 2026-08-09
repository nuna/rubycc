# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "timeout"
require_relative "../../tools/ci_result"

# Fetch and unpack logic shared by opt-in acceptance tests.
#
# The normal test suite remains network-free because callers decide whether to
# enter the acceptance path. Once entered, a fetch failure is represented as a
# typed Failure instead of being silently turned into a skip. Callers may keep
# the historical developer-friendly skip behaviour in non-strict mode, while
# strict CI must fail on the same Failure.
module AcceptanceFetchHelper
  DEFAULT_RETRY_LIMIT = 2
  MAX_RETRY_LIMIT = 5
  TRANSIENT_KINDS = %i[timeout rate_limited server_error].freeze
  EXTERNAL_TRANSIENT_KINDS = (TRANSIENT_KINDS + %i[dns_failure connection_refused tls_failure]).freeze
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/i

  module_function

  # Run a potentially networked process with a real child-process timeout.
  # Timeout.timeout around Open3.capture2e alone can leave the child alive, so
  # this helper owns the process and terminates it before reporting :timeout.
  def capture2e(command, chdir:, env: {}, timeout_seconds: nil)
    timeout_seconds ||= configured_timeout
    output = +""
    status = nil
    Open3.popen2e(env, *command, chdir: chdir) do |stdin, stream, wait_thread|
      stdin.close
      begin
        Timeout.timeout(timeout_seconds) do
          output = stream.read
          status = wait_thread.value
        end
      rescue Timeout::Error => e
        begin
          Process.kill("TERM", wait_thread.pid)
        rescue Errno::ESRCH
          nil
        end
        wait_thread.join(1)
        raise Failure.new(kind: :timeout,
                          message: "command timed out after #{timeout_seconds}s",
                          command: command, output: output, attempts: 1), cause: e
      end
    end
    [output, status]
  end

  def configured_timeout
    raw = ENV.fetch("RMAKE_FETCH_TIMEOUT_SECONDS", "120")
    value = Float(raw)
    raise ArgumentError, "RMAKE_FETCH_TIMEOUT_SECONDS must be positive" unless value.positive?

    value
  rescue ArgumentError
    raise ArgumentError, "RMAKE_FETCH_TIMEOUT_SECONDS must be a positive number"
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  rescue Errno::ENOENT, Errno::EACCES => e
    raise Failure.new(kind: :checksum, message: "cannot read #{path}: #{e.message}",
                      command: nil, output: "", attempts: 1), cause: e
  end

  def normalize_sha256(value)
    digest = String(value).downcase
    return digest if digest.match?(SHA256_PATTERN)

    raise ArgumentError, "expected SHA-256 must be 64 hexadecimal characters"
  rescue TypeError
    raise ArgumentError, "expected SHA-256 must be a string"
  end

  def verify_sha256(path, expected_sha256)
    expected = normalize_sha256(expected_sha256)
    unless File.file?(path)
      raise Failure.new(kind: :checksum, message: "artifact is missing: #{path}",
                        command: nil, output: "", attempts: 1)
    end

    actual = sha256(path)
    return actual if actual == expected

    raise Failure.new(
      kind: :checksum,
      message: "SHA-256 mismatch for #{File.basename(path)} (expected #{expected}, got #{actual})",
      command: nil,
      output: "expected_sha256=#{expected}\nactual_sha256=#{actual}",
      attempts: 1
    )
  end

  def record_artifact(id:, kind:, url:, expected_sha256:, path:, cache_hit:)
    report_path = ENV["CI_ARTIFACT_REPORT_PATH"] || ENV["M2_ARTIFACT_REPORT"]
    return if report_path.nil? || report_path.empty?

    expected = normalize_sha256(expected_sha256)
    report_path = File.expand_path(report_path)
    FileUtils.mkdir_p(File.dirname(report_path))
    lock_path = "#{report_path}.lock"
    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      records = if File.file?(report_path) && File.size(report_path).positive?
                  JSON.parse(File.read(report_path))
                else
                  []
                end
      raise Rubycc::CIResult::Error, "artifact report must contain an array" unless records.is_a?(Array)

      record = {
        "id" => String(id),
        "kind" => String(kind),
        "url" => String(url),
        "expected_sha256" => expected,
        "actual_sha256" => sha256(path),
        "bytes" => File.size(path),
        "cache_hit" => !!cache_hit
      }
      records.reject! { |candidate| candidate["id"] == record["id"] }
      records << record
      File.write(report_path, JSON.pretty_generate(records) + "\n")
      record
    ensure
      lock.flock(File::LOCK_UN) if lock
    end
  rescue JSON::ParserError => e
    raise Failure.new(kind: :artifact_report, message: "invalid artifact report: #{e.message}",
                      command: nil, output: "", attempts: 1), cause: e
  end

  class Failure < StandardError
    attr_reader :kind, :command, :output, :attempts

    def initialize(kind:, message:, command: nil, output: "", attempts: 1)
      @kind = kind
      @command = command
      @output = output
      @attempts = attempts
      super("#{kind}: #{message}")
    end
  end

  class Fetcher
    def initialize(work_dir:, runner: nil, sleeper: nil, retry_limit: nil, timeout_seconds: nil)
      @work_dir = File.expand_path(work_dir)
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @retry_limit = retry_limit.nil? ? env_retry_limit : Integer(retry_limit)
      @timeout_seconds = timeout_seconds.nil? ? env_timeout_seconds : Float(timeout_seconds)
      raise ArgumentError, "timeout_seconds must be positive" unless @timeout_seconds.positive?
      @runner = runner || lambda do |command, chdir:|
        AcceptanceFetchHelper.capture2e(command, chdir: chdir, timeout_seconds: @timeout_seconds)
      end
      unless (0..MAX_RETRY_LIMIT).cover?(@retry_limit)
        raise ArgumentError, "retry_limit must be between 0 and #{MAX_RETRY_LIMIT}"
      end
    end

    def fetch_gem_file(gem_name:, version:, platform: "ruby", expected_sha256: nil,
                       artifact_id: nil, artifact_kind: "rubygems-gem", artifact_url: nil)
      validate_component!(gem_name, "gem name")
      validate_component!(version, "gem version")
      expected_sha256 = AcceptanceFetchHelper.normalize_sha256(expected_sha256) unless expected_sha256.nil?
      if artifact_id && (artifact_url.nil? || expected_sha256.nil?)
        raise ArgumentError, "artifact_id requires artifact_url and expected_sha256"
      end

      FileUtils.mkdir_p(@work_dir)
      gem_file = File.join(@work_dir, "#{gem_name}-#{version}.gem")
      verify_cached_or_fetch(
        gem_file, gem_name, version, platform, expected_sha256,
        artifact_id: artifact_id, artifact_kind: artifact_kind, artifact_url: artifact_url
      )
      gem_file
    end

    # Fetch an HTTPS artifact into a temporary sibling and atomically publish it
    # only after the digest matches. The same path is used for GitHub tarballs
    # and RubyGems packages so their retry, timeout, cache and report semantics
    # cannot drift apart.
    def fetch_url(url:, destination:, expected_sha256:, artifact_id: nil,
                  artifact_kind: "source", artifact_url: url)
      validate_url!(url)
      expected = AcceptanceFetchHelper.normalize_sha256(expected_sha256)
      if artifact_id && artifact_url != url
        raise ArgumentError, "artifact_url must match url"
      end

      destination = File.expand_path(destination, @work_dir)
      FileUtils.mkdir_p(File.dirname(destination))
      if File.file?(destination)
        AcceptanceFetchHelper.verify_sha256(destination, expected)
        AcceptanceFetchHelper.record_artifact(
          id: artifact_id, kind: artifact_kind, url: artifact_url,
          expected_sha256: expected, path: destination, cache_hit: true
        ) if artifact_id
        return destination
      end

      partial = "#{destination}.part-#{Process.pid}-#{Thread.current.object_id}"
      FileUtils.rm_f(partial)
      command = ["curl", "--fail", "--location", "--silent", "--show-error",
                 "--connect-timeout", "15", "--max-time", @timeout_seconds.to_i.to_s,
                 "-o", partial, url]
      attempts = 0

      loop do
        attempts += 1
        FileUtils.rm_f(partial)
        begin
          output, status = run(command, phase: :fetch)
        rescue Failure => failure
          kind = failure.kind
          if EXTERNAL_TRANSIENT_KINDS.include?(kind) && attempts <= @retry_limit
            @sleeper.call(2**(attempts - 1))
            next
          end
          raise Failure.new(kind: kind, message: failure.message, command: command,
                            output: failure.output, attempts: attempts)
        end

        status_success = status.respond_to?(:success?) && status.success?
        unless status_success && File.file?(partial)
          kind = classify_fetch_failure(output, status)
          if EXTERNAL_TRANSIENT_KINDS.include?(kind) && attempts <= @retry_limit
            @sleeper.call(2**(attempts - 1))
            next
          end
          raise Failure.new(kind: kind, message: "artifact download failed after #{attempts} attempt(s)",
                            command: command, output: output, attempts: attempts)
        end

        # A checksum mismatch is deliberately not retried: it is evidence that
        # the pinned upstream bytes changed or the cache/report is wrong.
        AcceptanceFetchHelper.verify_sha256(partial, expected)
        File.rename(partial, destination)
        AcceptanceFetchHelper.record_artifact(
          id: artifact_id, kind: artifact_kind, url: artifact_url,
          expected_sha256: expected, path: destination, cache_hit: false
        ) if artifact_id
        return destination
      end
    ensure
      FileUtils.rm_f(partial) if partial
    end

    def fetch_gem(gem_name:, version:, extension_subdir:, required_file: "extconf.rb", platform: "ruby",
                  expected_sha256: nil, artifact_id: nil, artifact_kind: "rubygems-gem", artifact_url: nil)
      validate_component!(extension_subdir, "extension path")
      validate_component!(required_file, "required file")

      unpacked = File.join(@work_dir, "#{gem_name}-#{version}")
      extension_dir = File.join(unpacked, extension_subdir)
      gem_file = fetch_gem_file(gem_name: gem_name, version: version, platform: platform,
                                expected_sha256: expected_sha256, artifact_id: artifact_id,
                                artifact_kind: artifact_kind, artifact_url: artifact_url)
      return extension_dir if File.file?(File.join(extension_dir, required_file))

      FileUtils.rm_rf(unpacked)
      output, status = run(["gem", "unpack", gem_file], phase: :unpack)
      unless status.respond_to?(:success?) && status.success?
        kind = output.downcase.include?("checksum") ? :checksum : :unpack
        raise_failure(kind, "gem unpack failed", ["gem", "unpack", gem_file], output)
      end

      required = File.join(extension_dir, required_file)
      return extension_dir if File.file?(required)

      raise_failure(:missing_source, "#{extension_subdir}/#{required_file} missing after unpack",
                    ["gem", "unpack", gem_file], "")
    end

    private

    def verify_cached_or_fetch(gem_file, gem_name, version, platform, expected_sha256,
                               artifact_id:, artifact_kind:, artifact_url:)
      if artifact_url
        fetch_url(
          url: artifact_url, destination: gem_file, expected_sha256: expected_sha256,
          artifact_id: artifact_id, artifact_kind: artifact_kind
        )
        return
      end

      fetch_file(gem_file, gem_name, version, platform) unless File.file?(gem_file)
      AcceptanceFetchHelper.verify_sha256(gem_file, expected_sha256) if expected_sha256
    end

    def fetch_file(gem_file, gem_name, version, platform)
      command = ["gem", "fetch", gem_name, "--version", version, "--platform", platform]
      attempts = 0

      loop do
        attempts += 1
        begin
          output, status = run(command, phase: :fetch)
        rescue Failure => failure
          kind = failure.kind
          if EXTERNAL_TRANSIENT_KINDS.include?(kind) && attempts <= @retry_limit
            @sleeper.call(2**(attempts - 1))
            next
          end

          raise Failure.new(kind: kind, message: failure.message, command: command,
                            output: failure.output, attempts: attempts)
        end
        status_success = status.respond_to?(:success?) && status.success?
        return if status_success && File.file?(gem_file)

        kind = classify_fetch_failure(output, status)
        if EXTERNAL_TRANSIENT_KINDS.include?(kind) && attempts <= @retry_limit
          @sleeper.call(2**(attempts - 1))
          next
        end

        message = if status_success
                    "gem fetch succeeded but #{File.basename(gem_file)} was not created"
                  else
                    "gem fetch failed after #{attempts} attempt(s)"
                  end
        raise Failure.new(kind: kind, message: message, command: command,
                          output: output, attempts: attempts)
      end
    end

    def run(command, phase:)
      output, status = Timeout.timeout(@timeout_seconds) do
        @runner.call(command, chdir: @work_dir)
      end
      [String(output), status]
    rescue Timeout::Error => e
      raise_failure(:timeout, "#{phase} command timed out after #{@timeout_seconds}s", command, e.message)
    rescue SystemCallError => e
      raise_failure(:environment, "#{phase} command could not start: #{e.message}", command, "")
    end

    def classify_fetch_failure(output, status)
      text = output.downcase
      return :checksum if text.include?("checksum")
      return :not_found if text.match?(/\b404\b|could not find .*gem|could not find a valid gem|no matching gem|not found/)
      return :rate_limited if text.match?(/\b429\b|too many requests|rate limit/)
      return :server_error if text.match?(/\b5\d\d\b|service unavailable|bad gateway/)
      return :timeout if text.match?(/timed out|timeout|connection reset|network is unreachable/)
      return :dns_failure if text.match?(/could not resolve|temporary failure in name resolution|name or service not known/)
      return :connection_refused if text.match?(/connection refused|failed to connect/)
      return :tls_failure if text.match?(/tls|ssl|certificate verify failed/)
      return :fetch if status.nil? || !status.respond_to?(:success?)

      :fetch
    end

    def raise_failure(kind, message, command, output, attempts: 1)
      raise Failure.new(kind: kind, message: message, command: command,
                        output: output, attempts: attempts)
    end

    def env_retry_limit
      raw = ENV.fetch("RMAKE_FETCH_RETRIES", DEFAULT_RETRY_LIMIT.to_s)
      value = Integer(raw, exception: false)
      raise ArgumentError, "RMAKE_FETCH_RETRIES must be an integer" if value.nil?

      value
    end

    def env_timeout_seconds
      raw = ENV.fetch("RMAKE_FETCH_TIMEOUT_SECONDS", "120")
      value = Float(raw)
      raise ArgumentError, "RMAKE_FETCH_TIMEOUT_SECONDS must be positive" unless value.positive?

      value
    rescue ArgumentError
      raise ArgumentError, "RMAKE_FETCH_TIMEOUT_SECONDS must be a positive number"
    end

    def validate_component!(value, label)
      value = String(value)
      raise ArgumentError, "#{label} must not be empty" if value.empty?
      raise ArgumentError, "#{label} must not contain NUL" if value.include?("\0")
      raise ArgumentError, "#{label} must be relative" if value.start_with?("/")
      raise ArgumentError, "#{label} must not contain '..'" if value.split(/[\\\/]/).include?("..")
    rescue TypeError
      raise ArgumentError, "#{label} must be a string"
    end

    def validate_url!(value)
      unless value.is_a?(String) && value.match?(%r{\Ahttps://[^\s]+\z})
        raise ArgumentError, "artifact URL must be an HTTPS URL"
      end
    end
  end

  module_function

  def strict?
    %w[1 true yes].include?(ENV.fetch("RMAKE_ACCEPTANCE_STRICT", "").downcase)
  end
end
