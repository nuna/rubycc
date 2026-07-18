# frozen_string_literal: true

module Rubycc
  module Pkgconf
    PROG = "rubycc-pkgconf"

    # The exact option vocabulary mkmf's mkmf.rb#pkg_config can invoke
    # $PKGCONFIG with (tallied against this environment's mkmf.rb — see the
    # Step 59 report): `--exists` to probe availability, and, as `--#{option}`
    # for each entry of pkg_config's own *options argument or of its built-in
    # default path, `--modversion`/`--cflags`/`--cflags-only-I`/
    # `--cflags-only-other`/`--libs`/`--libs-only-l`. No other pkg-config
    # option (--static, --print-requires, ...) is in scope.
    KNOWN_OPTIONS = %w[exists modversion cflags cflags-only-I cflags-only-other libs libs-only-l].freeze

    # Runs the shim for +argv+ and returns the process exit status: 0 on
    # success, 1 if a named module (or one of its Requires) cannot be found,
    # the .pc text is malformed, or an unknown option/no module was given —
    # the same pass/fail contract mkmf's xsystem(... "--exists" ...) and
    # get[...] calls rely on.
    def self.run(argv, stdout: $stdout, stderr: $stderr, resolver: Resolver.new)
      Cli.new(argv, stdout: stdout, stderr: stderr, resolver: resolver).run
    end

    # Parses argv into requested options + module names and renders exactly
    # the options given, in the order given, onto one line — mirroring how
    # mkmf's pkg_config() invokes $PKGCONFIG with all of a single call's
    # `--#{option}` flags at once and reads back one combined line of output.
    class Cli
      def initialize(argv, stdout:, stderr:, resolver:)
        @argv = argv
        @out = stdout
        @err = stderr
        @resolver = resolver
        @options = []
        @modules = []
      end

      def run
        parse_argv
        return 1 if @options.empty?

        if @modules.empty?
          @err.puts "#{PROG}: no package name specified"
          return 1
        end

        if @options.include?("exists")
          @modules.all? { |name| @resolver.exists?(name) } ? 0 : 1
        else
          render
        end
      rescue PkgconfError => e
        @err.puts "#{PROG}: #{e.message}"
        1
      end

      private

      def parse_argv
        @argv.each do |arg|
          if arg.start_with?("--")
            option = arg[2..]
            unless KNOWN_OPTIONS.include?(option)
              @err.puts "#{PROG}: unknown option '#{arg}'"
              @options.clear
              return
            end
            @options << option
          else
            @modules << arg
          end
        end
      end

      def render
        parts = @options.map { |option| render_option(option) }
        @out.puts parts.reject(&:empty?).join(" ")
        0
      end

      def render_option(option)
        case option
        when "modversion"        then @modules.map { |name| @resolver.load(name).version.to_s }.join(" ")
        when "cflags"             then all_cflags.join(" ")
        when "cflags-only-I"      then all_cflags.select { |t| t.start_with?("-I") }.join(" ")
        when "cflags-only-other"  then all_cflags.reject { |t| t.start_with?("-I") }.join(" ")
        when "libs"                then all_libs.join(" ")
        when "libs-only-l"         then all_libs.select { |t| t.start_with?("-l") }.join(" ")
        end
      end

      # Multiple module arguments are concatenated in the order given — the
      # "複数モジュール" case mkmf's pkg_config() call shape allows for.
      def all_cflags
        @modules.flat_map { |name| @resolver.cflags_tokens(name) }
      end

      def all_libs
        @modules.flat_map { |name| @resolver.libs_tokens(name) }
      end
    end
  end
end
