# frozen_string_literal: true

require "open3"
require "fileutils"
require "timeout"
require "tmpdir"

require_relative "fetcher"

module Rubycc
  module Doctor
    # The on-the-fly build a gem gets when it is not in the verified database: the
    # same path RubyGems takes for a `gem install`, driven by hand so each stage's
    # outcome can be reported separately.
    #
    # Per gem: fetch the .gem, read its real extensions list; with none it needs
    # no C toolchain (no_ext). For each extension, run its extconf.rb with the
    # mkmf_shim loaded (so mkmf's conftests and the Makefile it writes route to
    # rubycc), then build the generated Makefile with rmake (which always
    # substitutes rubycc for the compiler/linker). On success the freshly built
    # .so is required in a child process to prove its Init function dlopens.
    #
    # A failure is pinned to a stage — extconf, compile, link, require or the
    # per-gem timeout — with a short summary of the tool's stderr.
    class Builder
      # Repository lib/ (this file lives at lib/rubycc/doctor/) and the executables
      # the build shells out to.
      REPO_LIB   = File.expand_path("../..", __dir__)
      REPO_ROOT  = File.expand_path("../../..", __dir__)
      RMAKE_EXE  = File.join(REPO_ROOT, "exe", "rmake")
      MKMF_SHIM_REQUIRE = "-rrubycc/mkmf_shim"

      # The outcome of building one gem.
      #   status  : :no_ext | :built | :failed | :unknown
      #   stage   : nil, or the failing stage (:extconf/:compile/:link/:require/:timeout)
      #   reason  : short human-readable explanation (stderr summary etc.)
      #   sos     : produced .so paths (on :built)
      #   require_ok : whether the require smoke check passed (:built only; a
      #                failed require does not demote the build — the .so was made —
      #                but is noted)
      Result = Struct.new(:status, :stage, :reason, :sos, :require_ok, keyword_init: true)

      # +timeout+ is the per-gem ceiling in seconds. +out+ receives progress lines.
      def initialize(cache_dir:, timeout: 300, out: nil)
        @cache_dir = cache_dir
        @timeout = timeout
        @out = out
      end

      # Build +entry+ (a Gemfile::Entry). Returns a Result. Never raises: every
      # failure mode is folded into a Result the CLI can print.
      def build(entry)
        fetcher = Fetcher.new(@cache_dir)
        version = entry.version || fetcher.latest_version(entry.name)
        return Result.new(status: :unknown, reason: "could not resolve a version") unless version

        gem_path =
          begin
            fetcher.download(entry.name, version)
          rescue Fetcher::FetchError => e
            return Result.new(status: :unknown, reason: "fetch failed (offline?): #{e.message}")
          end

        spec = fetcher.spec(gem_path)
        return Result.new(status: :no_ext) if spec.extensions.empty?

        Timeout.timeout(@timeout) { build_extensions(entry.name, version, gem_path, spec) }
      rescue Timeout::Error
        Result.new(status: :failed, stage: :timeout, reason: "exceeded #{@timeout}s")
      rescue StandardError => e
        Result.new(status: :failed, stage: :internal, reason: "#{e.class}: #{e.message}")
      end

      private

      # Unpack the gem and drive extconf -> rmake -> require for each extension.
      def build_extensions(name, version, gem_path, spec)
        dir = File.join(@cache_dir, "#{name}-#{version}")
        FileUtils.rm_rf(dir)
        FileUtils.mkdir_p(dir)
        Gem::Package.new(gem_path).extract_files(dir)

        sos = []
        spec.extensions.each do |ext_rel|
          ext_dir = File.join(dir, File.dirname(ext_rel))
          extconf = File.basename(ext_rel)

          result = build_one(ext_dir, extconf)
          return result unless result.status == :built

          sos.concat(result.sos)
        end

        require_ok = sos.all? { |so| require_check(so) }
        Result.new(status: :built, sos: sos, require_ok: require_ok,
                   reason: require_ok ? nil : "built, but the require smoke check failed")
      end

      # extconf -> rmake -> locate .so for a single extension directory.
      def build_one(ext_dir, extconf)
        log("extconf: #{ext_dir}/#{extconf}")
        out, ok = run(RbConfig.ruby, "-I#{REPO_LIB}", MKMF_SHIM_REQUIRE, extconf, chdir: ext_dir)
        unless ok && File.file?(File.join(ext_dir, "Makefile"))
          return Result.new(status: :failed, stage: :extconf, reason: summarize(out))
        end

        log("rmake: #{ext_dir}")
        out, ok = run(RbConfig.ruby, RMAKE_EXE, chdir: ext_dir)
        unless ok
          stage = Dir.glob(File.join(ext_dir, "**", "*.o")).empty? ? :compile : :link
          return Result.new(status: :failed, stage: stage, reason: summarize(out))
        end

        sos = Dir.glob(File.join(ext_dir, "**", "*.so"))
        return Result.new(status: :failed, stage: :link, reason: "rmake reported success but produced no .so") if sos.empty?

        Result.new(status: :built, sos: sos)
      end

      # Prove the built object dlopens and its Init function runs, in a child
      # process so a crash cannot take the doctor down. Requiring a .so by absolute
      # path invokes Init_<basename>, which is the load we want to confirm.
      def require_check(so)
        _out, ok = run(RbConfig.ruby, "-e", "require #{so.dump}")
        ok
      end

      # Run a command with the build environment, returning [combined_output, ok?].
      def run(*cmd, chdir: nil)
        env = { "RUBYLIB" => [REPO_LIB, ENV["RUBYLIB"]].compact.join(File::PATH_SEPARATOR) }
        opts = {}
        opts[:chdir] = chdir if chdir
        out, status = Open3.capture2e(env, *cmd, **opts)
        [out, status.success?]
      rescue StandardError => e
        ["#{e.class}: #{e.message}", false]
      end

      # The last few non-empty lines of a tool's output — enough to name the error
      # without dumping a whole build log into the report.
      def summarize(output)
        lines = output.to_s.lines.map(&:chomp).reject(&:empty?)
        lines.last(8).join("\n")
      end

      def log(msg)
        @out&.puts("    #{msg}")
      end
    end
  end
end
