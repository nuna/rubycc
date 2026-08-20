# frozen_string_literal: true

require "fileutils"
require_relative "errors"
require_relative "tool_command"
require_relative "../command_line"

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
    #
    # B3 adds two things on top of that. First, in-process tool substitution: when
    # +tools+ carries the argv prefixes of `$(CC)`/`$(LDSHARED)` (which may be two
    # words or more — the mkmf shim writes `<ruby> <path>/exe/rubycc`), a command
    # whose argv begins with one of them is not exec'd but run by rubycc's own
    # Driver — inside a forked child, so a compiler crash cannot take rmake down
    # and the Driver's per-invocation state stays isolated. Second, a `-j`
    # scheduler that forks independent stale steps up to +jobs+ at a time,
    # honouring the plan's dependency edges and buffering each worker's output to
    # flush it whole when the step finishes (make -O's un-interleaved output).
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

      # The parsed shapes come from the shared splitter (Rubycc::CommandLine),
      # which rmake and the mkmf shim both use; they are named here too so the
      # runner reads as it did when it owned the parser.
      Redirection = CommandLine::Redirection
      SimpleCommand = CommandLine::SimpleCommand

      def initialize(dir:, out: $stdout, err: $stderr, dry_run: false, env: ENV,
                     tools: [], jobs: 1)
        @dir = File.expand_path(dir)
        @out = out
        @err = err
        @dry_run = dry_run
        @env = env
        # Each tool is an argv prefix (the words that name the program). A bare
        # string is accepted as the one-word prefix it describes.
        @tools = Array(tools).map { |tool| Array(tool) }
        @jobs = [jobs.to_i, 1].max
        # In sequential mode a substituted tool is fork-isolated for its own sake;
        # a parallel worker is already a forked step child, so it runs the Driver
        # in-process rather than forking a second time.
        @isolate_tool = true
      end

      # Run every step of +plan+. With +jobs+ == 1 (or under -n) this is a
      # straight sequential walk: prerequisites already precede their dependents
      # in the plan, so the order is a valid build order. With +jobs+ > 1 the
      # steps are dispatched by the parallel scheduler instead. Returns the plan;
      # raises CommandFailedError / UnsupportedRecipeError at the first command
      # that fails (and is not `-`-prefixed) or cannot be interpreted.
      def execute(plan)
        if @jobs > 1 && !@dry_run
          execute_parallel(plan)
        else
          plan.steps.each do |step|
            step.commands.each { |command| run_line(step.target, command) }
          end
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

      # --- parsing ---------------------------------------------------------

      # Split a recipe line into words and connectors with the shared splitter.
      # Kept as a method of the runner because a failure has to name the target
      # whose recipe was at fault, which only the runner knows.
      def tokenize(target, text)
        CommandLine.tokenize(text)
      rescue CommandLine::UnsupportedSyntaxError => e
        unsupported!(e.construct, target, text)
      end

      # Turn the line into [[connector, SimpleCommand], ...]. A leading run of
      # `VAR=value` words become that command's environment; a redirect marker
      # consumes the following word as its target path.
      def parse_line(target, text)
        CommandLine.parse(text)
      rescue CommandLine::UnsupportedSyntaxError => e
        unsupported!(e.construct, target, text)
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
        elsif (driver_argv = tool_arguments(argv))
          run_tool(driver_argv, cmd, state)
        else
          run_external(target, argv, cmd, state)
        end
      end

      # The arguments to hand rubycc's Driver when +argv+ runs one of the
      # substituted tools, or nil when it does not (in which case the command is
      # run as an ordinary external process). A tool is matched by its whole argv
      # prefix — the words `$(CC)`/`$(LDSHARED)` expand to, which for the mkmf
      # shim's `<ruby> <path>/exe/rubycc` is two of them — and exactly those words
      # are dropped, so what reaches the Driver is what the recipe added. The
      # longest matching prefix wins, since a longer one describes the command
      # more completely. With substitution off (@tools empty) nothing matches,
      # which keeps the default path (exec every unknown command) untouched.
      def tool_arguments(argv)
        return nil if @tools.empty?

        prefix = @tools.select { |candidate| ToolCommand.match?(argv, candidate) }.max_by(&:length)
        prefix && argv.drop(prefix.length)
      end

      # Run a substituted compiler/linker command through rubycc's Driver, which
      # takes the gcc-style argv minus the words that named the program (see
      # #tool_arguments). The compile line and the `-shared` link line map through
      # the same Driver entry point (it selects its mode from the flags), so the
      # two need no special-casing here. Sequential runs fork for crash isolation;
      # a parallel worker is already isolated and runs the Driver in-process.
      def run_tool(driver_argv, cmd, state)
        ok, reason = @isolate_tool ? fork_driver(driver_argv, state.cwd, cmd) \
                                   : inline_driver(driver_argv, state.cwd, cmd)
        state.failure_reason = reason unless ok
        ok
      end

      # rubycc's Driver, loaded on first use so rmake stays loadable on its own
      # (the whole compiler/linker stack it drags in is not needed for a plain
      # Makefile parse/plan). The umbrella `rubycc` is required rather than just
      # `rubycc/driver` so every constant the link path reaches — the ELF reader's
      # error classes the archive writer rescues among them — is defined; loading
      # only the driver leaves some of those unresolved.
      def driver_class
        require "rubycc" unless defined?(Rubycc::Driver)
        Rubycc::Driver
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

      # --- in-process tool invocation (Driver) -----------------------------

      # Run the Driver in a forked child (sequential mode). The child chdirs,
      # applies the command's `VAR=value` prefixes, points the Driver's streams at
      # the command's redirections or a capture pipe, and exits with the Driver's
      # status; the parent drains the pipe, waits, and forwards whatever the child
      # printed to its own output. `exit!` is used so the child never runs Ruby's
      # at_exit hooks (Minitest's reporter among them). Returns [ok?, reason].
      def fork_driver(driver_argv, cwd, cmd)
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          status = 1
          begin
            Dir.chdir(cwd)
            env_overrides(cmd.assignments).each { |k, v| ENV[k] = v }
            out_io, err_io = redirection_ios(cmd.redirections, cwd)
            status = driver_class.run(driver_argv, stdout: out_io || writer, stderr: err_io || writer)
            [out_io, err_io].compact.each(&:close)
          rescue Exception => e # rubocop:disable Lint/RescueException
            safe_puts(writer, "rmake: rubycc: #{e.class}: #{e.message}")
            status = 1
          end
          writer.flush
          exit!(status)
        end
        writer.close
        output = reader.read
        reader.close
        _, status = Process.waitpid2(pid)
        @out.write(output) unless output.empty?
        status.success? ? [true, nil] : [false, tool_reason(status)]
      end

      # Run the Driver in the current process (parallel mode: the caller is
      # already an isolated step worker). chdir is block-scoped so a step's later
      # commands are unaffected. Returns [ok?, reason].
      def inline_driver(driver_argv, cwd, cmd)
        out_io, err_io = redirection_ios(cmd.redirections, cwd)
        status = 1
        Dir.chdir(cwd) do
          with_env(env_overrides(cmd.assignments)) do
            status = driver_class.run(driver_argv, stdout: out_io || @out, stderr: err_io || @err)
          end
        end
        [out_io, err_io].compact.each(&:close)
        status.zero? ? [true, nil] : [false, "rubycc exited with status #{status}"]
      rescue Exception => e # rubocop:disable Lint/RescueException
        [false, "#{e.class}: #{e.message}"]
      end

      def tool_reason(status)
        if status.signaled?
          "rubycc terminated by signal #{status.termsig}"
        else
          "rubycc exited with status #{status.exitstatus}"
        end
      end

      # Temporarily overlay ENV with +overrides+ for the block, restoring it after
      # (used so a tool line's `VAR=value` prefix does not leak into later work).
      def with_env(overrides)
        return yield if overrides.empty?

        saved = overrides.keys.to_h { |k| [k, ENV[k]] }
        overrides.each { |k, v| ENV[k] = v }
        begin
          yield
        ensure
          saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
        end
      end

      # Open a command's redirections and return [stdout_io, stderr_io] (nil for a
      # stream that is not redirected). The non-block sibling of #with_redirections,
      # used where the Driver needs the IO objects handed to it directly.
      def redirection_ios(redirections, cwd)
        out_io = err_io = nil
        redirections.each do |r|
          path = r.path == "/dev/null" ? File::NULL : absolute(r.path, cwd)
          io = File.open(path, r.mode == :append ? "a" : "w")
          r.stream == :stderr ? (err_io = io) : (out_io = io)
        end
        [out_io, err_io]
      end

      def safe_puts(io, message)
        io.puts(message)
      rescue StandardError
        nil
      end

      # --- parallel scheduling (-j) ----------------------------------------

      # Build +plan+ with up to @jobs step workers running at once. Each ready
      # step (all its prerequisite steps finished) is forked; the worker runs the
      # whole step in-process with its output captured, so a step's lines stay
      # together and a compiler crash is contained. On a worker failure no new
      # step is launched, the ones already running are drained, and then the
      # failure is raised — make's default "-k off" behaviour.
      def execute_parallel(plan)
        remaining = plan.steps.dup
        done = {}
        running = {}
        failure = nil

        loop do
          while failure.nil? && running.size < @jobs && (step = next_ready(remaining, done, running))
            remaining.delete(step)
            launch_step(step, running)
          end
          break if running.empty?

          pid, status = Process.wait2
          finished = running.delete(pid)
          next unless finished

          @out.write(finished[:thread].value)
          if status.success?
            done[finished[:step].target] = true
          else
            failure ||= [finished[:step], status]
          end
        end

        return unless failure

        step, status = failure
        raise CommandFailedError.new(target: step.target,
                                     command: "recipe for #{step.target}",
                                     reason: tool_reason(status))
      end

      # The first remaining step all of whose prerequisite steps have finished and
      # none of which is still running. nil when nothing is currently runnable
      # (every remaining step waits on an in-flight one).
      def next_ready(remaining, done, running)
        pending = running.values.map { |r| r[:step].target }
        remaining.find do |step|
          step.prereqs.all? { |p| done[p] } && pending.none? { |t| step.prereqs.include?(t) }
        end
      end

      # Fork a worker for +step+. The child funnels every stream (builtin echo,
      # the Driver, any spawned helper) into a capture pipe by reopening its
      # stdout/stderr, then runs the step's recipe lines with tool substitution
      # inline (it is already isolated). The parent records the child's pid and a
      # thread that drains the pipe so a large transcript cannot dead-lock the
      # write.
      def launch_step(step, running)
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          run_step_worker(step, writer)
        end
        writer.close
        running[pid] = { step: step, reader: reader, thread: Thread.new { reader.read } }
      end

      def run_step_worker(step, writer)
        $stdout.reopen(writer)
        $stderr.reopen(writer)
        @out = $stdout
        @err = $stderr
        @isolate_tool = false
        step.commands.each { |command| run_line(step.target, command) }
        writer.flush
        exit!(0)
      rescue RmakeError => e
        safe_puts(writer, e.message)
        exit!(1)
      rescue Exception => e # rubocop:disable Lint/RescueException
        safe_puts(writer, "rmake: #{e.class}: #{e.message}")
        exit!(1)
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
