#!/usr/bin/env ruby
# frozen_string_literal: true

# Validate one fixed corpus candidate and, only after the static gate passes,
# optionally build/load it in an isolated GEM_HOME.  The workflow supplies the
# candidate fields through environment variables so shell quoting is never used
# to construct a command or a URL.  Upstream suites remain delegated to the
# reviewed recipes in tools/verify_gem_tests.rb.

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "rubygems/package"
require "timeout"

module CorpusCandidateValidation
  ROOT = File.expand_path("..", __dir__).freeze
  VERIFY_TOOL = File.join(ROOT, "tools", "verify_gem_tests.rb").freeze
  SHA256 = /\A[0-9a-f]{64}\z/i
  NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/
  VERSION = /\A[a-zA-Z0-9][a-zA-Z0-9.+~_-]*\z/
  PLATFORM = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/
  MODES = %w[build_load upstream].freeze
  NATIVE_C_CPP = /\.(?:c|h|cc|cpp|cxx|hh|hpp|hxx)\z/i
  NATIVE_ADDITIONAL = /\.(?:go|rs|m|mm|swift|S|asm)\z|\/(?:go\.mod|go\.sum|Cargo\.toml|Cargo\.lock)\z/i
  BUILD_MANIFEST = %r{(?:^|/)(?:Rakefile|extconf\.rb|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock)$}i
  CLEARED_ENV = {
    "RUBYOPT" => nil,
    "RUBYLIB" => nil,
    "BUNDLE_GEMFILE" => nil,
    "BUNDLE_BIN_PATH" => nil,
    "BUNDLE_PATH" => nil,
    "BUNDLER_VERSION" => nil,
    "BUNDLER_SETUP" => nil,
    "RUBYGEMS_GEMDEPS" => nil
  }.freeze

  Input = Struct.new(:name, :version, :platform, :sha256, :mode, :work_dir, :result_path,
                     keyword_init: true) do
    def self.from_env(env, overrides = {})
      work_dir = overrides.fetch(:work_dir) { env["CANDIDATE_WORK"] }
      result_path = overrides.fetch(:result_path) { env["CANDIDATE_RESULT"] }
      new(
        name: env["CANDIDATE_NAME"],
        version: env["CANDIDATE_VERSION"],
        platform: env["CANDIDATE_PLATFORM"],
        sha256: env["CANDIDATE_SHA256"],
        mode: overrides.fetch(:mode) { env["CANDIDATE_MODE"] },
        work_dir: work_dir,
        result_path: result_path
      )
    end

    def validate!
      errors = []
      errors << "name is missing or contains unsafe characters" unless name.to_s.match?(NAME)
      errors << "version is missing or contains unsafe characters" unless version.to_s.match?(VERSION)
      errors << "platform must be ruby" unless platform == "ruby"
      errors << "SHA-256 must be 64 hexadecimal characters" unless sha256.to_s.match?(SHA256)
      errors << "mode must be one of #{MODES.join(', ')}" unless MODES.include?(mode)
      errors << "work directory must be an absolute path" unless absolute_path?(work_dir)
      errors << "result path must be an absolute path" unless absolute_path?(result_path)
      raise ArgumentError, errors.join("; ") unless errors.empty?
    end

    def input_json
      {
        "name" => name,
        "version" => version,
        "platform" => platform,
        "expected_sha256" => sha256.to_s.downcase,
        "mode" => mode,
        "source" => "workflow_dispatch"
      }
    end

    private

    def absolute_path?(path)
      path.is_a?(String) && path.start_with?(File::SEPARATOR)
    end
  end

  class CommandRunner
    Result = Struct.new(:output, :success, :status, keyword_init: true)

    def initialize(work_dir:)
      @work_dir = work_dir
    end

    def call(argv, env: {}, chdir: ROOT, timeout_seconds: 120)
      output = +""
      status = nil
      Open3.popen2e(CLEARED_ENV.merge(env), *argv, chdir: chdir) do |stdin, stream, wait_thread|
        stdin.close
        begin
          Timeout.timeout(timeout_seconds) do
            output = stream.read
            status = wait_thread.value
          end
        rescue Timeout::Error
          begin
            Process.kill("TERM", wait_thread.pid)
          rescue Errno::ESRCH
            nil
          end
          wait_thread.join(1)
          return Result.new(output: "#{output}\ncommand timed out after #{timeout_seconds}s", success: false,
                            status: nil)
        end
      end
      Result.new(output: output, success: status&.success? || false, status: status)
    rescue SystemCallError => e
      Result.new(output: "#{e.class}: #{e.message}", success: false, status: nil)
    end
  end

  class ValidationStop < StandardError
    attr_reader :result

    def initialize(result)
      @result = result
      super(result.fetch("reason", "validation stopped"))
    end
  end

  class Runner
    def initialize(input, preflight_only: false)
      @input = input
      @preflight_only = preflight_only
      @work_dir = input.work_dir.to_s.empty? ? File.join(Dir.tmpdir, "corpus-candidate-validation") :
                                                 File.expand_path(input.work_dir)
      @result_path = input.result_path.to_s.empty? ? File.join(@work_dir, "result.json") :
                                                     File.expand_path(input.result_path)
      @commands = CommandRunner.new(work_dir: @work_dir)
    end

    def run
      @input.validate!
      FileUtils.mkdir_p(@work_dir)
      result = base_result
      preflight!(result)

      if result.fetch("gate_status") != "candidate"
        write_result(result)
        return result.fetch("exit_code")
      end

      if @input.mode == "upstream"
        recipe_gate!(result)
        if result.fetch("gate_status") != "candidate"
          write_result(result)
          return result.fetch("exit_code")
        end
      end

      if @preflight_only
        result["status"] = "ready"
        result["next_action"] = "Run the separate build/load and reviewed upstream recipe jobs."
        write_result(result)
        return 0
      end

      build_and_load!(result)
      write_result(result)
      result.fetch("exit_code")
    rescue ValidationStop => e
      write_result(e.result)
      e.result.fetch("exit_code", 1)
    rescue ArgumentError => e
      write_result(input_rejected_result(e.message))
      1
    rescue StandardError => e
      result = base_result
      result["status"] = "infrastructure_failure"
      result["gate_status"] = "infrastructure_failure"
      result["reason"] = "#{e.class}: #{e.message}"
      result["next_action"] = "Review the runner log and retry after correcting the environment."
      write_result(result)
      1
    end

    private

    def base_result
      {
        "schema_version" => 1,
        "tool" => "verify_corpus_candidate",
        "status" => "not_run",
        "gate_status" => "not_run",
        "exit_code" => 0,
        "input" => @input.input_json,
        "identity" => nil,
        "static" => nil,
        "recipe" => nil,
        "execution" => {
          "ruby" => RUBY_DESCRIPTION,
          "work_dir" => "<CANDIDATE_WORK>",
          "build_load" => "not_run",
          "sanity" => "not_run"
        },
        "upstream" => { "status" => "not_run" },
        "reason" => nil,
        "next_action" => nil
      }
    end

    def input_rejected_result(reason)
      result = base_result
      result["status"] = "input_rejected"
      result["gate_status"] = "input_rejected"
      result["exit_code"] = 1
      result["reason"] = reason
      result["next_action"] = "Supply validated name, version, ruby platform, SHA-256, mode, and isolated paths."
      result
    end

    def preflight!(result)
      archive, cache_hit = fetch_archive!
      result["identity"] = archive_identity(archive, cache_hit)

      package = Gem::Package.new(archive)
      spec = package.spec
      result["identity"]["gemspec"] = {
        "name" => spec.name,
        "version" => spec.version.to_s,
        "platform" => spec.platform.to_s
      }
      unless spec.name == @input.name && spec.version.to_s == @input.version && spec.platform.to_s == @input.platform
        result["status"] = "identity_mismatch"
        result["gate_status"] = "identity_mismatch"
        result["exit_code"] = 1
        result["reason"] = "gemspec does not match requested name/version/platform"
        result["next_action"] = "Use the archive whose gemspec matches the fixed dispatch identity."
        return
      end

      root = extract_archive(package)
      files = archive_files(root)
      extensions = Array(spec.extensions).map(&:to_s).sort
      extconf_files = files.select { |path| path.match?(%r{(?:^|/)extconf\.rb\z}i) }.sort
      native_sources = files.select { |path| path.match?(NATIVE_C_CPP) }.sort
      additional_native_sources = files.select { |path| path.match?(NATIVE_ADDITIONAL) }.sort
      build_manifests = files.select { |path| path.match?(BUILD_MANIFEST) }.sort
      extension_roots = extensions.map { |path| File.dirname(path) }.uniq.sort
      extension_root = extension_roots.one? ? extension_roots.first : nil

      static_status = if extensions.empty?
                        native_sources.empty? && additional_native_sources.empty? && extconf_files.empty? ?
                          "no_ext" : "review_required"
                      elsif additional_native_sources.any? || extconf_files.empty? ||
                            extension_roots.any? { |path| path != "." && !path.start_with?("ext/") }
                        "review_required"
                      else
                        "candidate"
                      end

      result["static"] = {
        "status" => static_status,
        "r10" => "not_run",
        "extensions" => extensions,
        "extension_root" => extension_root,
        "extension_roots" => extension_roots,
        "native_sources" => native_sources,
        "additional_native_sources" => additional_native_sources,
        "extconf_files" => extconf_files,
        "build_manifests" => build_manifests,
        "headers" => { "system" => [], "gap" => [] }
      }

      result["status"] = static_status
      result["gate_status"] = static_status == "candidate" ? "candidate" : static_status
      result["next_action"] = case static_status
                               when "no_ext"
                                 "Do not build/load: the archive has no declared or observed native extension."
                               when "review_required"
                                 "Stop for local review of the undeclared or unsupported native build shape."
                               else
                                 "Static gate passed; continue only in the explicitly requested mode."
                               end
      result["exit_code"] = 0
    end

    def fetch_archive!
      archive_dir = File.join(@work_dir, "packages")
      FileUtils.mkdir_p(archive_dir)
      archive = File.join(archive_dir, "#{@input.name}-#{@input.version}.gem")
      expected = @input.sha256.downcase
      if File.file?(archive)
        actual = Digest::SHA256.file(archive).hexdigest
        return [archive, true] if actual == expected
      end

      partial = "#{archive}.part"
      FileUtils.rm_f(partial)
      url = "https://rubygems.org/gems/#{@input.name}-#{@input.version}.gem"
      command = ["curl", "--fail", "--location", "--silent", "--show-error",
                 "--connect-timeout", "15", "--max-time", "120", "-o", partial, url]
      fetched = @commands.call(command, timeout_seconds: 150)
      unless fetched.success && File.file?(partial)
        result = base_result
        result["status"] = "environment_insufficient"
        result["gate_status"] = "environment_insufficient"
        result["exit_code"] = 1
        result["reason"] = "archive fetch failed: #{portable(fetched.output).lines.last.to_s.strip}"
        result["next_action"] = "Retry with network access to rubygems.org or inspect the runner failure."
        raise ValidationStop, result
      end

      actual = Digest::SHA256.file(partial).hexdigest
      unless actual == expected
        FileUtils.rm_f(partial)
        result = base_result
        result["status"] = "checksum_mismatch"
        result["gate_status"] = "checksum_mismatch"
        result["exit_code"] = 1
        result["identity"] = { "expected_sha256" => expected, "archive_sha256" => actual }
        result["reason"] = "archive SHA-256 does not match the dispatch input"
        result["next_action"] = "Obtain the exact archive identified by the fixed SHA-256 before any unpack or execution."
        raise ValidationStop, result
      end

      File.rename(partial, archive)
      [archive, false]
    end

    def archive_identity(archive, cache_hit)
      {
        "archive_sha256" => Digest::SHA256.file(archive).hexdigest,
        "archive_bytes" => File.size(archive),
        "cache_hit" => cache_hit,
        "url" => "https://rubygems.org/gems/#{@input.name}-#{@input.version}.gem"
      }
    end

    def extract_archive(package)
      unpack_dir = File.join(@work_dir, "unpacked")
      FileUtils.mkdir_p(unpack_dir)
      package.extract_files(unpack_dir)
      children = Dir.children(unpack_dir).map { |name| File.join(unpack_dir, name) }
      children.one? && File.directory?(children.first) ? children.first : unpack_dir
    end

    def archive_files(root)
      Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).filter_map do |path|
        next unless File.file?(path)

        path.delete_prefix("#{root}/")
      end.sort
    end

    def recipe_gate!(result)
      listed = @commands.call([RbConfig.ruby, VERIFY_TOOL, "--list"], timeout_seconds: 30)
      unless listed.success
        result["status"] = "environment_insufficient"
        result["gate_status"] = "environment_insufficient"
        result["exit_code"] = 1
        result["reason"] = "could not inspect the reviewed recipe catalog"
        result["next_action"] = "Restore the repository Ruby environment and retry recipe lookup."
        return
      end

      row = listed.output.lines.find do |line|
        line.match?(/^\s*#{Regexp.escape(@input.name)}\s+\S+\s+\S+/)
      end
      unless row
        result["status"] = "recipe_missing"
        result["gate_status"] = "recipe_missing"
        result["recipe"] = { "status" => "missing" }
        result["next_action"] = "Add and review a fixed recipe before requesting upstream test mode."
        return
      end

      recipe_version = row.split.fetch(1)
      result["recipe"] = { "status" => "ready", "version" => recipe_version,
                             "catalog" => "tools/verify_gem_tests.rb" }
      unless recipe_version == @input.version
        result["status"] = "recipe_version_mismatch"
        result["gate_status"] = "recipe_version_mismatch"
        result["next_action"] = "Dispatch the exact version pinned by the reviewed recipe."
        return
      end
    end

    def build_and_load!(result)
      home = File.join(@work_dir, "home")
      gem_home = File.join(@work_dir, "gemhome")
      rubycc_package = File.join(@work_dir, "packages", "rubycc.gem")
      FileUtils.mkdir_p(home)
      FileUtils.mkdir_p(gem_home)
      env = {
        "HOME" => home,
        "GEM_HOME" => gem_home,
        "GEM_PATH" => gem_home,
        "RUBYCC" => "0"
      }

      build = @commands.call(gem_command("build", "rubycc.gemspec", "--output", rubycc_package),
                             env: env, timeout_seconds: 900)
      install_rubycc = build.success && @commands.call(
        gem_command("install", rubycc_package, "--install-dir", gem_home, "--local", "--no-document"),
        env: env, timeout_seconds: 900
      )
      install_rubycc = CommandRunner::Result.new(output: "not run", success: false, status: nil) unless build.success

      candidate_env = env.merge("RUBYCC" => "1")
      archive = File.join(@work_dir, "packages", "#{@input.name}-#{@input.version}.gem")
      install_candidate = if install_rubycc.success
                            @commands.call(
                              gem_command("install", archive, "--install-dir", gem_home, "--local",
                                          "--ignore-dependencies", "--no-document"),
                              env: candidate_env, timeout_seconds: 1_800
                            )
                          else
                            CommandRunner::Result.new(output: "not run", success: false, status: nil)
                          end

      outputs = [build.output, install_rubycc.output, install_candidate.output].compact.join("\n")
      result["execution"]["build_output_tail"] = portable(outputs).lines.last(40).map(&:chomp)
      unless build.success && install_rubycc.success && install_candidate.success
        result["status"] = "build_failed"
        result["gate_status"] = "build_failed"
        result["execution"]["build_load"] = "build_failed"
        result["exit_code"] = 1
        result["reason"] = "rubycc or candidate gem installation failed"
        result["next_action"] = "Review the structured build log; do not treat this as a corpus addition."
        return
      end

      gem_dir = File.join(gem_home, "gems", "#{@input.name}-#{@input.version}")
      makeouts = Dir.glob(File.join(gem_home, "extensions", "**", "#{@input.name}-#{@input.version}", "gem_make.out"))
      makefiles = Dir.glob(File.join(gem_dir, "**", "Makefile"))
      rubycc_trace = makeouts.any? { |path| File.read(path).match?(%r{rubycc-[^/\s]+/exe/rmake}) } &&
                     makefiles.any? { |path| File.read(path).match?(%r{rubycc-[^/\s]+/exe/rubycc}) }
      result["execution"]["rubycc_build_evidence"] = rubycc_trace ? "pass" : "missing"
      unless rubycc_trace
        result["status"] = "build_failed"
        result["gate_status"] = "build_failed"
        result["execution"]["build_load"] = "build_failed"
        result["exit_code"] = 1
        result["reason"] = "candidate install succeeded without proving a rubycc build"
        result["next_action"] = "Discard the result and investigate the missing rubycc build evidence."
        return
      end

      shared_objects = Dir.glob(File.join(gem_dir, "**", "*.so")).sort
      if shared_objects.empty?
        result["status"] = "fallback_or_not_loaded"
        result["gate_status"] = "fallback_or_not_loaded"
        result["execution"]["build_load"] = "fallback_or_not_loaded"
        result["exit_code"] = 1
        result["reason"] = "candidate install produced no shared object"
        result["next_action"] = "Do not count a pure-Ruby or non-loaded result as a build/load pass."
        return
      end

      load_script = <<~'RUBY'
        paths = ARGV
        abort "no shared objects supplied" if paths.empty?
        paths.each do |path|
          require path
          real = File.realpath(path)
          loaded = $LOADED_FEATURES.any? { |entry| File.expand_path(entry) == real }
          abort "shared object was not loaded: #{real}" unless loaded
        end
        puts "loaded=#{paths.length}"
      RUBY
      load_env = candidate_env.merge("RUBYLIB" => File.join(gem_dir, "lib"))
      loaded = @commands.call([RbConfig.ruby, "-e", load_script, *shared_objects],
                              env: load_env, timeout_seconds: 120)
      result["execution"]["load_output_tail"] = portable(loaded.output).lines.last(20).map(&:chomp)
      if loaded.success
        result["status"] = "build_load_pass"
        result["gate_status"] = "build_load_pass"
        result["execution"]["build_load"] = "build_load_pass"
        result["execution"]["sanity"] = "all_shared_objects_loaded"
        result["next_action"] = "Review the report and run upstream mode only when a reviewed recipe exists."
      else
        result["status"] = "fallback_or_not_loaded"
        result["gate_status"] = "fallback_or_not_loaded"
        result["execution"]["build_load"] = "fallback_or_not_loaded"
        result["execution"]["sanity"] = "load_failed"
        result["reason"] = "one or more built shared objects could not be proven loaded"
        result["next_action"] = "Investigate the load/sanity failure; do not call the build verified."
      end
      result["exit_code"] = loaded.success ? 0 : 1
    end

    def gem_command(*args)
      [RbConfig.ruby, "-S", "gem", *args]
    end

    def portable(text)
      text.to_s.gsub(@work_dir, "<CANDIDATE_WORK>").gsub(ROOT, "<RUBYCC_ROOT>")
    end

    def write_result(result)
      FileUtils.mkdir_p(File.dirname(@result_path))
      File.write(@result_path, JSON.pretty_generate(result) + "\n")
    end
  end

  module_function

  def parse_options(argv)
    options = { mode: nil, work_dir: nil, result_path: nil, preflight_only: false }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: CANDIDATE_NAME=... CANDIDATE_VERSION=... ruby tools/verify_corpus_candidate.rb [options]"
      opts.on("--mode MODE", MODES, "build_load or upstream") { |value| options[:mode] = value }
      opts.on("--work-dir PATH", "isolated work directory") { |value| options[:work_dir] = value }
      opts.on("--result PATH", "structured result path") { |value| options[:result_path] = value }
      opts.on("--preflight-only", "stop after identity/static/recipe checks") { options[:preflight_only] = true }
      opts.on("--help", "show this help") { puts opts; exit 0 }
    end
    parser.parse!(argv)
    options
  end

  def main(argv, env: ENV)
    options = parse_options(argv)
    input = Input.from_env(env, options.compact)
    Runner.new(input, preflight_only: options.fetch(:preflight_only)).run
  rescue OptionParser::ParseError => e
    warn e.message
    1
  end
end

exit(CorpusCandidateValidation.main(ARGV)) if $PROGRAM_NAME == __FILE__
