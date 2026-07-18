# frozen_string_literal: true

require "fileutils"
require_relative "errors"

module Rubycc
  module Rmake
    # Runs an execution Plan (from Makefile#plan) without a shell. The minimal
    # target environment has no /bin/sh (DESIGN R5), so each recipe line is
    # interpreted here directly: split into words (honouring quotes), joined by
    # the connectors make's recipes use (`&&`, `||`, `;`), with `>`/`>>`/`2>`
    # redirections and `VAR=value` / `cd` prefixes applied to the command they
    # front. The vocabulary is fixed by the mkmf corpus (test/fixtures/mkmf): only
    # the constructs those Makefiles actually emit are accepted, and anything else
    # raises UnsupportedRecipeError instead of being run through a shell that does
    # not exist.
    #
    # The utilities the recipes invoke (rm, mkdir, install, echo, ...) are
    # reimplemented on top of FileUtils — the "no external tool" implementation is
    # authoritative, so `/usr/bin/install` and a bare `install` behave identically
    # and no process is spawned for them. Everything the runner does not recognise
    # as a builtin (the compiler and linker, `$(CC)`/`$(LDSHARED)`) is exec'd
    # directly with an argv array; the runner never builds a shell command string.
    class Executor
      # The utilities reimplemented in-process, keyed by the command's basename so
      # that `/usr/bin/mkdir` and `mkdir` resolve to the same builtin. `:` is
      # make's $(NULLCMD); `exit` is how mkmf's `TOUCH = exit >` stamps a
      # timestamp file (the `>` creates it, `exit` succeeds).
      BUILTINS = %w[cd rm mkdir rmdir cp install echo touch true : exit].freeze

      # Per-recipe-line mutable state: the working directory a `cd` in the same
      # line has moved to, and the reason string of the most recent failure (used
      # to enrich CommandFailedError). Each recipe line starts from the Makefile's
      # base directory afresh, matching make running every line in its own shell.
      class LineState
        attr_accessor :cwd, :failure_reason

        def initialize(cwd)
          @cwd = cwd
          @failure_reason = nil
        end
      end

      # One redirection parsed off a command: which stream (:stdout/:stderr),
      # whether it truncates or appends, and the target path (relative to the
      # command's cwd).
      Redirection = Struct.new(:stream, :mode, :path)

      # One simple command: leading `VAR=value` assignments, the argv words and
      # the redirections that apply to it.
      SimpleCommand = Struct.new(:assignments, :argv, :redirections)

      def initialize(dir:, out: $stdout, err: $stderr, dry_run: false, env: ENV)
        @dir = File.expand_path(dir)
        @out = out
        @err = err
        @dry_run = dry_run
        @env = env
      end

      # Run every step of +plan+ in order. Prerequisites already precede their
      # dependents in the plan, so a straight sequential walk is a valid build
      # order. Returns the plan; raises CommandFailedError / UnsupportedRecipeError
      # at the first command that fails (and is not `-`-prefixed) or cannot be
      # interpreted.
      def execute(plan)
        plan.steps.each do |step|
          step.commands.each { |command| run_line(step.target, command) }
        end
        plan
      end

      private

      # Execute one recipe line (a Command carrying its `@`/`-` attributes). make
      # echoes the line before running it unless it is silent (`@`); under -n it
      # echoes every line and runs nothing.
      def run_line(target, command)
        echo_command(command)
        return if @dry_run

        state = LineState.new(@dir)
        ok = run_and_or_list(target, command.text, state)
        return if ok || command.ignore_error?

        raise CommandFailedError.new(target: target, command: command.text, reason: state.failure_reason)
      end

      def echo_command(command)
        @out.puts(command.text) if @dry_run || !command.silent?
      end

      # Interpret a recipe line as an and-or list: simple commands joined by
      # `&&` (run next only after success), `||` (run next only after failure)
      # and `;` (always run next). A single left-to-right status carries the
      # result, exactly as an sh and-or list evaluates. Returns the final success.
      def run_and_or_list(target, text, state)
        commands = parse_line(target, text)
        success = true
        commands.each do |connector, cmd|
          run = case connector
                when :first, :semi then true
                when :and then success
                when :or then !success
                end
          success = run_simple(target, cmd, state, text) if run
        end
        success
      end

      # --- lexing ----------------------------------------------------------

      # Split a recipe line into tokens: :word (quote-stripped), the connectors
      # :and/:or/:semi and :redirect markers. Single and double quotes protect
      # whitespace and metacharacters (the corpus needs only simple quoting, so
      # `$`/backslash inside double quotes are treated literally — expansion has
      # already happened in the planner). Genuinely unhandled shell syntax
      # (pipe, background, substitution, subshell) stops the run.
      def tokenize(target, text)
        tokens = []
        word = nil
        i = 0
        n = text.length
        while i < n
          c = text[i]
          case c
          when "'", '"'
            close = text.index(c, i + 1)
            unsupported!("unterminated quote", target, text) if close.nil?
            word = (word || +"") + text[(i + 1)...close]
            i = close + 1
          when " ", "\t"
            tokens << [:word, word] if word
            word = nil
            i += 1
          when "&"
            tokens << [:word, word] if word
            word = nil
            unsupported!("background '&'", target, text) unless text[i + 1] == "&"
            tokens << [:and]
            i += 2
          when "|"
            tokens << [:word, word] if word
            word = nil
            unsupported!("pipe '|'", target, text) unless text[i + 1] == "|"
            tokens << [:or]
            i += 2
          when ";"
            tokens << [:word, word] if word
            word = nil
            tokens << [:semi]
            i += 1
          when ">"
            tokens << [:word, word] if word
            word = nil
            if text[i + 1] == ">"
              tokens << [:redirect, :stdout, :append]
              i += 2
            else
              tokens << [:redirect, :stdout, :truncate]
              i += 1
            end
          when "<", "`", "(", ")"
            unsupported!("shell metacharacter '#{c}'", target, text)
          else
            if word.nil? && (c == "1" || c == "2") && text[i + 1] == ">"
              stream = c == "2" ? :stderr : :stdout
              if text[i + 2] == ">"
                tokens << [:redirect, stream, :append]
                i += 3
              else
                tokens << [:redirect, stream, :truncate]
                i += 2
              end
            else
              word = (word || +"") + c
              i += 1
            end
          end
        end
        tokens << [:word, word] if word
        tokens
      end

      # --- parsing ---------------------------------------------------------

      # Turn the token stream into [[connector, SimpleCommand], ...]. A leading
      # run of `VAR=value` words become that command's environment; a redirect
      # marker consumes the following word as its target path.
      def parse_line(target, text)
        tokens = tokenize(target, text)
        commands = []
        connector = :first
        assignments = []
        argv = []
        redirections = []
        i = 0

        flush = lambda do
          unless assignments.empty? && argv.empty? && redirections.empty?
            commands << [connector, SimpleCommand.new(assignments, argv, redirections)]
          end
          assignments = []
          argv = []
          redirections = []
        end

        while i < tokens.length
          tok = tokens[i]
          case tok[0]
          when :word
            w = tok[1]
            if argv.empty? && w =~ /\A[A-Za-z_][A-Za-z0-9_]*=/
              assignments << w
            else
              argv << w
            end
          when :and, :or, :semi
            flush.call
            connector = tok[0]
          when :redirect
            nxt = tokens[i + 1]
            unsupported!("redirection without a target", target, text) if nxt.nil? || nxt[0] != :word
            redirections << Redirection.new(tok[1], tok[2], nxt[1])
            i += 1
          end
          i += 1
        end
        flush.call
        commands
      end

      # --- running a simple command ---------------------------------------

      def run_simple(target, cmd, state, text)
        argv = expand_globs(cmd.argv, state.cwd)
        # A bare `VAR=value` with no command (or an empty command) is a no-op that
        # succeeds, as it would in sh.
        return true if argv.empty?

        name = File.basename(argv[0])
        if BUILTINS.include?(name)
          run_builtin(target, name, argv, cmd, state, text)
        else
          run_external(target, argv, cmd, state)
        end
      end

      # Expand `*`/`?`/`[...]` globs against the command's cwd. A pattern that
      # matches nothing is left verbatim (sh's default, and what lets `rm -f
      # *.bak` be harmless when no backup files exist). Names come back relative
      # to cwd, which is how the builtins resolve them.
      def expand_globs(words, cwd)
        words.flat_map do |w|
          next [w] unless w =~ /[*?\[]/

          matches = Dir.glob(w, base: cwd).sort
          matches.empty? ? [w] : matches
        end
      end

      # Open the command's redirections and yield the resulting stdout/stderr IO
      # (nil when a stream is not redirected). Opening a `>` target creates and
      # truncates it, which is also the whole effect of mkmf's `exit > stamp`.
      def with_redirections(redirections, cwd)
        opened = []
        streams = { stdout: nil, stderr: nil }
        redirections.each do |r|
          path = r.path == "/dev/null" ? File::NULL : absolute(r.path, cwd)
          io = File.open(path, r.mode == :append ? "a" : "w")
          opened << io
          streams[r.stream] = io
        end
        yield(streams[:stdout], streams[:stderr])
      ensure
        opened.each(&:close)
      end

      # Run an unknown command (the compiler/linker) as a real process with an
      # argv array — never a shell string — honouring the command's env, cwd and
      # redirections. A missing executable is a normal build failure.
      def run_external(target, argv, cmd, state)
        with_redirections(cmd.redirections, state.cwd) do |out_io, err_io|
          options = { chdir: state.cwd }
          options[:out] = out_io if out_io
          options[:err] = err_io if err_io
          begin
            pid = Process.spawn(env_overrides(cmd.assignments), *argv, options)
            _, status = Process.waitpid2(pid)
            state.failure_reason = "exited with status #{status.exitstatus}" unless status.success?
            status.success?
          rescue Errno::ENOENT, Errno::EACCES => e
            state.failure_reason = "cannot execute #{argv[0]}: #{e.message}"
            false
          end
        end
      end

      def env_overrides(assignments)
        assignments.each_with_object({}) do |a, h|
          name, value = a.split("=", 2)
          h[name] = value
        end
      end

      # --- builtins --------------------------------------------------------

      def run_builtin(target, name, argv, cmd, state, text)
        with_redirections(cmd.redirections, state.cwd) do |out_io, err_io|
          out = out_io || @out
          err = err_io || @err
          case name
          when "cd" then builtin_cd(argv, state)
          when "rm" then builtin_rm(argv, state)
          when "mkdir" then builtin_mkdir(target, argv, state, text)
          when "rmdir" then builtin_rmdir(argv, state)
          when "cp" then builtin_cp(target, argv, state, text)
          when "install" then builtin_install(target, argv, state, text)
          when "echo" then builtin_echo(argv, out)
          when "touch" then builtin_touch(argv, state)
          when "true", ":", "exit" then true
          else
            # BUILTINS listed it but no branch handles it — a programming error.
            unsupported!("builtin '#{name}'", target, text)
          end
        rescue RmakeError
          # Unsupported-syntax and other rmake-level errors must propagate; only
          # a utility's incidental I/O failure is turned into a soft failure.
          raise
        rescue StandardError => e
          # Turn a utility's own I/O error into a recorded failure so the line
          # reports it (and `-`/`||` can absorb it), rather than crashing rmake.
          state.failure_reason = e.message
          err.puts("rmake: #{name}: #{e.message}") if err
          false
        end
      end

      # `cd DIR`: move the rest of this recipe line into DIR. A missing directory
      # fails, so `cd x && cmd` skips cmd — the sh behaviour.
      def builtin_cd(argv, state)
        dir = argv[1]
        return false if dir.nil?

        target = absolute(dir, state.cwd)
        return false unless File.directory?(target)

        state.cwd = target
        true
      end

      # `rm [-f] [-r] FILE...`. `-f` swallows missing files; `-r`/`-R` recurses.
      def builtin_rm(argv, state)
        force = recursive = false
        files = []
        argv.drop(1).each do |a|
          if a.start_with?("-") && a != "-"
            force ||= a.include?("f")
            recursive ||= a.include?("r") || a.include?("R")
          else
            files << a
          end
        end

        ok = true
        files.each do |f|
          path = absolute(f, state.cwd)
          if File.exist?(path) || File.symlink?(path)
            recursive ? FileUtils.rm_rf(path) : FileUtils.rm(path)
          elsif !force
            state.failure_reason = "no such file: #{f}"
            ok = false
          end
        end
        ok
      end

      # `mkdir [-p] DIR...`. Without -p a pre-existing directory is an error, as
      # is a missing parent; the corpus always passes -p.
      def builtin_mkdir(target, argv, state, text)
        create_parents = false
        dirs = []
        argv.drop(1).each do |a|
          if a == "-p" || a == "--parents"
            create_parents = true
          elsif a.start_with?("-")
            unsupported!("mkdir option #{a}", target, text)
          else
            dirs << a
          end
        end

        dirs.each do |d|
          path = absolute(d, state.cwd)
          create_parents ? FileUtils.mkdir_p(path) : FileUtils.mkdir(path)
        end
        true
      end

      # `rmdir [--ignore-fail-on-non-empty] [-p] DIR...`. Removes empty
      # directories; -p also removes now-empty ancestors. A non-empty directory
      # fails unless the ignore flag is set. No operands is a no-op success.
      def builtin_rmdir(argv, state)
        ignore_nonempty = remove_parents = false
        dirs = []
        argv.drop(1).each do |a|
          case a
          when "--ignore-fail-on-non-empty" then ignore_nonempty = true
          when "-p", "--parents" then remove_parents = true
          else dirs << a unless a.start_with?("-")
          end
        end

        ok = true
        dirs.each do |d|
          ok = false unless remove_one_dir(absolute(d, state.cwd), remove_parents, ignore_nonempty, state)
        end
        ok
      end

      def remove_one_dir(path, remove_parents, ignore_nonempty, state)
        loop do
          return true unless File.directory?(path)

          unless (Dir.children(path).empty?)
            return true if ignore_nonempty

            state.failure_reason = "directory not empty: #{path}"
            return false
          end
          Dir.rmdir(path)
          break unless remove_parents

          path = File.dirname(path)
        end
        true
      end

      # `cp [-p] SRC... DEST`. When DEST is a directory each SRC is copied into
      # it; otherwise a single SRC is copied to DEST.
      def builtin_cp(target, argv, state, text)
        _flags, operands = split_flags(argv.drop(1))
        unsupported!("cp needs a source and destination", target, text) if operands.length < 2

        dest = absolute(operands.pop, state.cwd)
        operands.each do |src|
          FileUtils.cp(absolute(src, state.cwd), dest)
        end
        true
      end

      # `install [-c] [-m MODE] SRC... DEST` — mkmf's $(INSTALL_PROG)/
      # $(INSTALL_DATA). `-c` (copy) is the default here; `-m` sets the octal
      # mode. DEST is treated as a directory when it exists as one.
      def builtin_install(target, argv, state, text)
        mode = nil
        operands = []
        rest = argv.drop(1)
        i = 0
        while i < rest.length
          a = rest[i]
          if a == "-m"
            mode = rest[i + 1]
            i += 2
          elsif a == "-c"
            i += 1
          elsif a.start_with?("-") && a != "-"
            unsupported!("install option #{a}", target, text)
          else
            operands << a
            i += 1
          end
        end
        unsupported!("install needs a source and destination", target, text) if operands.length < 2

        dest = absolute(operands.pop, state.cwd)
        operands.each do |src|
          spath = absolute(src, state.cwd)
          dpath = File.directory?(dest) ? File.join(dest, File.basename(src)) : dest
          FileUtils.cp(spath, dpath)
          File.chmod(mode.to_i(8), dpath) if mode
        end
        true
      end

      # `echo [-n] WORDS...` — join the arguments with single spaces. Writes to
      # the redirected stream when one is present, else the runner's output.
      def builtin_echo(argv, out)
        args = argv.drop(1)
        newline = true
        newline = false if args.first == "-n" && (args = args.drop(1))
        out.write(args.join(" "))
        out.write("\n") if newline
        true
      end

      # `touch FILE...` — create each file or update its timestamp.
      def builtin_touch(argv, state)
        argv.drop(1).reject { |a| a.start_with?("-") }.each do |f|
          FileUtils.touch(absolute(f, state.cwd))
        end
        true
      end

      # --- helpers ---------------------------------------------------------

      # Partition argv-tail words into option flags and positional operands
      # (used by the utilities that take no option arguments of their own).
      def split_flags(words)
        flags = []
        operands = []
        words.each do |w|
          (w.start_with?("-") && w != "-" ? flags : operands) << w
        end
        [flags, operands]
      end

      def absolute(path, cwd)
        path.start_with?("/") ? path : File.expand_path(path, cwd)
      end

      def unsupported!(construct, target, command)
        raise UnsupportedRecipeError.new(construct, target: target, command: command)
      end
    end
  end
end
