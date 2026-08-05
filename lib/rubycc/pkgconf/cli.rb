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
    def self.run(argv, stdout: $stdout, stderr: $stderr, resolver: Resolver.new, filter: SystemPathFilter.new)
      Cli.new(argv, stdout: stdout, stderr: stderr, resolver: resolver, filter: filter).run
    end

    # Parses argv into requested options + module names and renders exactly
    # the options given, in the order given, onto one line — mirroring how
    # mkmf's pkg_config() invokes $PKGCONFIG with all of a single call's
    # `--#{option}` flags at once and reads back one combined line of output.
    class Cli
      def initialize(argv, stdout:, stderr:, resolver:, filter:)
        @argv = argv
        @out = stdout
        @err = stderr
        @resolver = resolver
        @filter = filter
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
      #
      # The system-path filter is applied here, once, rather than inside
      # Resolver or per rendered option: Resolver's token lists are what the
      # Requires chain says (the parser-level tests assert exactly that), while
      # every option that renders those tokens — --cflags, --cflags-only-I,
      # --cflags-only-other, --libs, --libs-only-l — has to agree on which of
      # them are suppressed. --cflags-only-other and --libs-only-l are
      # unaffected in practice, since they keep only tokens the filter never
      # touches.
      def all_cflags
        dedupe_search_paths(@filter.cflags(@modules.flat_map { |name| @resolver.cflags_tokens(name) }), "-I")
      end

      def all_libs
        dedupe_search_paths(@filter.libs(@modules.flat_map { |name| @resolver.libs_tokens(name) }), "-L")
      end

      # Collapse a repeated search-path token to its first occurrence, the way
      # the real pkg-config does. A directory named twice searches the same
      # directory twice, so dropping the later copy cannot change what is found,
      # while keeping the first preserves the order the .pc files asked for.
      #
      # This is not hypothetical tidying: zlib.pc writes
      # `Libs: -L${libdir} -L${sharedlibdir} -lz` and on this environment both
      # variables expand to the same directory, so the shim emitted that -L
      # twice where the real tool emitted it once. It went unnoticed because the
      # system-path filter happened to remove both copies on Debian; measured on
      # Alpine, where that directory is not a system directory and neither copy
      # is removed (docs/STEPS.md Step 199).
      #
      # Only search paths are collapsed. `-l` is deliberately left alone: a
      # repeated library can matter to a static link's resolution order, and no
      # measurement here covers it.
      def dedupe_search_paths(tokens, flag)
        seen = {}
        tokens.reject do |token|
          next false unless token.start_with?(flag) && token.length > flag.length

          seen.key?(token).tap { seen[token] = true }
        end
      end
    end
  end
end
