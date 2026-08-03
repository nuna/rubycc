# frozen_string_literal: true

require_relative "errors"
require_relative "makefile"

module Rubycc
  module Rmake
    # The command-line front end to rmake (M3 / ROADMAP §6 B6). It exists so
    # RubyGems can drive rubycc's builds by setting `ENV["MAKE"]` to this program:
    # Gem::Ext::Builder invokes `$(MAKE)` as three separate processes shaped like
    #
    #   rmake DESTDIR= sitearchdir=<tmp> sitelibdir=<tmp> clean
    #   rmake DESTDIR= sitearchdir=<tmp> sitelibdir=<tmp>          (default goal)
    #   rmake DESTDIR= sitearchdir=<tmp> sitelibdir=<tmp> install
    #
    # so the argument grammar it must accept is: command-line variable definitions
    # (`VAR=value`, which override the Makefile's own assignments), zero or more
    # target names (an absent target builds the default goal) and, though RubyGems
    # does not pass them, the `-j`/`-f` options make users expect. Because rmake is
    # rubycc's build-only make, tool substitution (`$(CC)`/`$(LDSHARED)` routed to
    # rubycc's Driver) is always on — a `CC = gcc` left in the Makefile is still
    # built by rubycc.
    #
    # It is a plain method object rather than an OptionParser front end: the mkmf
    # invocation shape is fixed and narrow, so hand-parsing keeps the accepted
    # grammar explicit (and the "everything routes to rubycc" contract obvious).
    class CLI
      DEFAULT_MAKEFILE = "Makefile"

      # Run rmake with +argv+ in +dir+, returning the process exit status
      # (0 success, 2 for any make-level failure — the code GNU make uses). +out+
      # and +err+ are injectable so the CLI can be exercised without spawning.
      def self.run(argv, dir: Dir.pwd, out: $stdout, err: $stderr)
        new(dir: dir, out: out, err: err).run(argv)
      end

      def initialize(dir:, out:, err:)
        @dir = dir
        @out = out
        @err = err
      end

      def run(argv)
        options = parse_argv(argv)

        makefile_path = File.expand_path(options[:file] || DEFAULT_MAKEFILE, @dir)
        unless File.file?(makefile_path)
          @err.puts("rmake: #{options[:file] || DEFAULT_MAKEFILE}: No such file")
          return 2
        end

        mk = Makefile.parse(File.read(makefile_path), dir: @dir, overrides: options[:overrides],
                             defaults: { "MAKE" => make_default })
        goals = options[:targets].empty? ? [nil] : options[:targets]
        # Tool substitution is always on: rmake is rubycc's build CLI, so the
        # compiler/linker words in every recipe are handed to rubycc's Driver.
        goals.each { |goal| mk.run(goal, out: @out, err: @err, tools: :rubycc, jobs: options[:jobs]) }
        0
      rescue RmakeError => e
        @err.puts("rmake: #{e.message}")
        2
      end

      private

      # Split +argv+ into { overrides:, targets:, jobs:, file: }. Anything that is
      # not a recognised option or a `VAR=value` definition is a target name.
      def parse_argv(argv)
        overrides = {}
        targets = []
        # Default to all cores: rmake is invoked by `gem install` as a plain
        # `make`, so a serial default would leave multi-file extensions
        # building one recipe at a time (H5). The scheduler's dependency DAG
        # is unaffected, and each step's output is buffered and flushed whole
        # (like `-O`), so parallel output never interleaves and the built
        # artifacts match a serial run; an explicit `-j1` still gets the old
        # serial behaviour.
        jobs = processor_count
        file = nil

        i = 0
        while i < argv.length
          arg = argv[i]
          case arg
          when "-f", "--file", "--makefile"
            file = argv[i + 1]
            i += 1
          when /\A-f(.+)\z/, /\A--file=(.+)\z/, /\A--makefile=(.+)\z/
            file = Regexp.last_match(1)
          when "-j", "--jobs"
            # A bare -j (its argument omitted, as make allows) means "as many as
            # possible"; approximate that with the processor count.
            if (nxt = argv[i + 1]) && nxt =~ /\A\d+\z/
              jobs = nxt.to_i
              i += 1
            else
              jobs = processor_count
            end
          when /\A-j(\d+)\z/, /\A--jobs=(\d+)\z/
            jobs = Regexp.last_match(1).to_i
          when /\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/m
            overrides[Regexp.last_match(1)] = Regexp.last_match(2)
          when /\A-/
            # An unrecognised option: rmake is a narrow make, so ignore flags it
            # does not model rather than abort a build over an option that does
            # not change what gets built.
          else
            targets << arg
          end
          i += 1
        end

        { overrides: overrides, targets: targets, jobs: [jobs, 1].max, file: file }
      end

      def processor_count
        require "etc"
        Etc.nprocessors
      rescue StandardError
        1
      end

      # POSIX requires make to define `MAKE` built in, so `$(MAKE)` in a recipe
      # (a recursive-make invocation, e.g. `cd sub && $(MAKE)`) expands to
      # something runnable rather than the empty string a silently-undefined
      # variable would give — which would collapse the recipe line to `cd sub &&`
      # and turn a recursive build into a no-op. The value is an absolute path to
      # this very program, so the recursive invocation is rmake again, never a
      # bare "make" that would hand the recursive build to a host GNU make (or
      # fail outright) instead of rubycc.
      #
      # `ENV["MAKE"]` is honoured first because RubyGems' rubygems_plugin sets it
      # to rmake before invoking `$(MAKE)` at the top level, and that value must
      # propagate unchanged into any recipe this run itself expands.
      def make_default
        env_make = ENV["MAKE"]
        return env_make if env_make && !env_make.empty?

        File.expand_path($PROGRAM_NAME)
      end
    end
  end
end
