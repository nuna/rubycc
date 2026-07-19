# frozen_string_literal: true

require "optparse"

require_relative "gemfile"
require_relative "verified_gems"
require_relative "builder"

module Rubycc
  module Doctor
    # `rubycc doctor` — tells a Ruby application developer whether rubycc can
    # build the C extensions their app depends on.
    #
    # It reads the app's Gemfile.lock (or Gemfile), and for each gem: reports it
    # verified when the shipped build-verified database (data/verified_gems.json)
    # already covers that name+version; otherwise fetches and builds it on the
    # spot through the same extconf -> rmake -> rubycc path a real install takes,
    # reporting exactly where any failure occurred. Gems with no C extension need
    # rubycc at all and are marked as such.
    #
    # The verified check is offline and instant; only unverified gems reach the
    # network. The bottom line is an adoption verdict and an exit code (0 when
    # every C-extension gem is verified or built, 1 otherwise).
    class CLI
      # Per-status display: symbol + label. Ordering of keys is the report legend.
      STATUS = {
        verified:       ["✔", "verified"],
        built:          ["✔", "built on the spot"],
        no_ext:         ["-", "no C extension"],
        failed:         ["✘", "FAILED"],
        unknown:        ["?", "unknown"],
        local:          ["-", "local/vcs source (skipped)"],
        skipped_budget: ["?", "skipped (build budget reached)"]
      }.freeze

      def self.run(argv, out: $stdout, err: $stderr, verified: nil, builder: nil)
        new(out: out, err: err, verified: verified, builder: builder).run(argv)
      end

      def initialize(out:, err:, verified: nil, builder: nil)
        @out = out
        @err = err
        @verified = verified
        @builder = builder
      end

      def run(argv)
        options = parse(argv)
        return 0 if options[:help]

        result = Gemfile.load(options[:gemfile])
        unless result
          @err.puts("rubycc doctor: no Gemfile.lock or Gemfile found at #{options[:gemfile]}")
          return 2
        end

        verified = @verified || VerifiedGems.load
        rows = evaluate(result, verified, options)
        report(result, rows)
        exit_code(rows)
      rescue OptionParser::ParseError => e
        @err.puts("rubycc doctor: #{e.message}")
        2
      end

      private

      # A row of the report: the gem, its resolved status and an optional note.
      Row = Struct.new(:name, :version, :status, :note, keyword_init: true)

      def parse(argv)
        options = { gemfile: File.expand_path("Gemfile"), timeout: 300, max_builds: nil }
        parser = OptionParser.new do |o|
          o.banner = "Usage: rubycc-doctor [options]"
          o.on("--gemfile PATH", "Gemfile path (default ./Gemfile; .lock preferred)") { |v| options[:gemfile] = File.expand_path(v) }
          o.on("--timeout SECONDS", Integer, "Per-gem build timeout (default 300)") { |v| options[:timeout] = v }
          o.on("--max-builds N", Integer, "Cap the number of on-the-spot builds") { |v| options[:max_builds] = v }
          o.on("--data PATH", "verified_gems.json path (default: bundled)") { |v| options[:data] = File.expand_path(v) }
          o.on("-h", "--help", "Show this help") { @out.puts(o); options[:help] = true }
        end
        parser.parse(argv)
        @verified ||= VerifiedGems.load(options[:data]) if options[:data]
        options
      end

      # Walk every gem and resolve its status, honouring the build budget.
      def evaluate(result, verified, options)
        builder = @builder || Builder.new(cache_dir: build_cache, timeout: options[:timeout], out: @out)
        builds_done = 0

        result.entries.map do |entry|
          if entry.source != :gem
            next Row.new(name: entry.name, version: entry.version, status: :local)
          end

          if (record = verified.match(entry.name, entry.version))
            note = "verified #{record.verified_at} (#{record.environment})"
            next Row.new(name: entry.name, version: entry.version, status: :verified, note: note)
          end

          if options[:max_builds] && builds_done >= options[:max_builds]
            next Row.new(name: entry.name, version: entry.version, status: :skipped_budget)
          end

          @out.puts("  building #{entry.name} #{entry.version}...") if @out
          bresult = builder.build(entry)
          builds_done += 1 unless bresult.status == :no_ext
          Row.new(name: entry.name, version: entry.version, status: bresult.status, note: note_for(bresult))
        end
      end

      # The note column for a build result.
      def note_for(bresult)
        case bresult.status
        when :failed  then "#{bresult.stage}: #{bresult.reason}"
        when :built   then bresult.require_ok ? "require OK" : bresult.reason
        when :unknown then bresult.reason
        end
      end

      def report(result, rows)
        if result.origin == :gemfile
          @out.puts("Note: no Gemfile.lock found; parsed #{result.path} for direct gems only " \
                    "(versions may be missing, dependency closure not resolved).")
          @out.puts
        end

        width = rows.map { |r| "#{r.name} #{r.version}".length }.max || 0
        rows.each do |row|
          symbol, label = STATUS[row.status]
          line = format("  %s  %-#{width}s  %s", symbol, "#{row.name} #{row.version}".strip, label)
          line += "  (#{row.note})" if row.note && !row.note.empty?
          @out.puts(line)
        end

        summary(rows)
      end

      # The adoption verdict: over the gems that actually have C extensions, are
      # they all handled (verified or built)?
      def summary(rows)
        cext = rows.reject { |r| %i[no_ext local].include?(r.status) }
        failed = cext.count { |r| r.status == :failed }
        # A gem skipped for the build budget was never checked, so it is
        # undetermined for adoption purposes, exactly like an offline "unknown".
        unknown = cext.count { |r| %i[unknown skipped_budget].include?(r.status) }
        ok = cext.count { |r| %i[verified built].include?(r.status) }

        @out.puts
        @out.puts("C-extension gems: #{cext.size}  (verified/built #{ok}, failed #{failed}, unknown #{unknown})")
        @out.puts(
          if cext.empty?
            "Verdict: no C-extension gems to build — rubycc is not required."
          elsif failed.zero? && unknown.zero?
            "Verdict: ADOPTABLE — every C-extension gem is verified or builds with rubycc."
          else
            parts = []
            parts << "#{failed} to address" if failed.positive?
            parts << "#{unknown} undetermined" if unknown.positive?
            "Verdict: NEEDS ATTENTION — #{parts.join(', ')}."
          end
        )
      end

      # Exit 0 only when every C-extension gem is verified or built.
      def exit_code(rows)
        cext = rows.reject { |r| %i[no_ext local].include?(r.status) }
        cext.all? { |r| %i[verified built].include?(r.status) } ? 0 : 1
      end

      def build_cache
        require "tmpdir"
        dir = File.join(Dir.tmpdir, "rubycc-doctor")
        FileUtils.mkdir_p(dir)
        dir
      end
    end
  end
end
