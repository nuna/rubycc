# frozen_string_literal: true

require "rbconfig"
require_relative "command_line"

# The mkmf integration shim: requiring this file (before `require "mkmf"`)
# reroutes every conftest command mkmf issues — compile, link, preprocess — to
# rubycc, without patching mkmf itself. mkmf builds its probe commands out of a
# handful of RbConfig keys (`$(CC)`, `$(LDSHARED)`, `$(CPP)`, `$(PKG_CONFIG)`)
# and runs them through `system(env, *command)`, so replacing just those keys
# with the rubycc executables makes `have_header`, `have_func`, `have_library`,
# `try_compile`/`try_link`/`try_run`, `check_sizeof` and the rest resolve
# against rubycc's own compiler and linker. mkmf.log stays untouched — mkmf
# writes it — so the log's format (the "checked program was:" sections, the
# echoed command lines) is the genuine article.
#
# Two RbConfig hashes are rewritten: CONFIG, which mkmf merges into every
# conftest command's expansion context, and MAKEFILE_CONFIG, which the generated
# Makefile's `CC = …`/`LDSHARED = …` assignments are drawn from — so both the
# probe phase and the eventual build route through rubycc. The change is
# in-process only (no file on disk is modified) and idempotent: requiring the
# shim twice is a no-op.
#
# The rubycc executables shebang-launch `require "rubycc"`, which needs the
# repository's `lib/` on the load path when rubycc is run from a checkout rather
# than an installed gem. The shim prepends that directory to `RUBYLIB` so the
# value propagates to the child processes mkmf spawns.
#
# Rewriting the RbConfig keys settles *what* mkmf runs; ShellFreeCommands
# settles *how*. mkmf builds each conftest command as one string and hands it to
# `system`/`IO.popen`, which lets Ruby decide between exec'ing it and handing it
# to /bin/sh — and the environment DESIGN R5 targets has no /bin/sh. The shim
# prepends the two methods that spawn (`xsystem`, `xpopen`) and converts a string
# command into an argv array first, so nothing about the run depends on a shell
# being there. A command that genuinely needs shell interpretation is refused
# with its reason written to mkmf.log rather than being run through a shell that
# may or may not exist.
module Rubycc
  module MkmfShim
    # The repository's lib/ directory (this file lives at lib/rubycc/mkmf_shim.rb)
    # and the gcc-compatible executables that stand in for the external toolchain.
    LIB_DIR     = File.expand_path("..", __dir__)
    RUBYCC_EXE  = File.expand_path("../../exe/rubycc", __dir__)
    PKGCONF_EXE = File.expand_path("../../exe/rubycc-pkgconf", __dir__)

    # The RbConfig keys rewritten to point at rubycc. Each maps to the command
    # string mkmf embeds verbatim when it expands `$(CC)` and friends: a single
    # shell-metacharacter-free executable path (plus, for the compound tools, the
    # driver's own mode flag) so mkmf's `system(env, *command)` execs it directly.
    def self.replacements
      {
        "CC"        => RUBYCC_EXE,
        "LDSHARED"  => "#{RUBYCC_EXE} -shared",
        "CPP"       => "#{RUBYCC_EXE} -E",
        "PKG_CONFIG" => PKGCONF_EXE
      }
    end

    # Raised when a conftest command cannot be run without a shell. It is a
    # refusal, not a build failure: mkmf reads a false return as "the compiler
    # cannot build this", which would misreport an unrunnable command as a
    # missing header or a broken toolchain, so the shim stops the extconf
    # instead.
    class ShellRequiredError < Rubycc::Error; end

    # Prepended to MakeMakefile so the two methods that spawn a conftest —
    # `xsystem` (compile/link/run) and `xpopen` (the same, reading the output) —
    # receive an argv array where mkmf built a string. mkmf's own
    # `expand_command` keeps whatever shape it is given (an Array stays an Array
    # and is spawned directly; a String stays a String and reaches the shell),
    # so converting the command on the way in is the whole change: the logging,
    # the werror handling and the env hash are still mkmf's.
    #
    # The conversion runs mkmf's `$(VAR)` expansion *before* splitting, which is
    # the order a shell saw: mkmf expanded the variables and sh did the word
    # splitting. `super` expands again, on words that no longer hold `$(...)`.
    module ShellFreeCommands
      def xsystem(command, werror: false)
        super(rubycc_spawn_form(command), werror: werror)
      end

      def xpopen(command, *mode, &block)
        super(rubycc_spawn_form(command), *mode, &block)
      end

      private

      # The command as something spawnable without a shell. Arrays are already
      # that and pass through untouched (mkmf builds the pkg-config calls that
      # way); a string is expanded and split. The method name is prefixed
      # because prepending to MakeMakefile puts it on every extconf's Object.
      def rubycc_spawn_form(command)
        return command unless command.is_a?(String)

        _env, expanded = expand_command(command)
        MkmfShim.spawn_form(expanded)
      end
    end

    # Split +command+ into the argv array mkmf should spawn, or refuse it.
    # A one-word command comes back as `[[program, program]]`: `system(env, str)`
    # with a single string would put Ruby back in charge of choosing between exec
    # and the shell (it scans for metacharacters and splits on spaces), and the
    # explicit [program, argv0] form takes that choice away — `./conftest` and a
    # path with a space in it are then spawned the same way.
    def self.spawn_form(command)
      argv = CommandLine.argv(command)
      argv.length == 1 ? [[argv[0], argv[0]]] : argv
    rescue CommandLine::UnsupportedSyntaxError => e
      refuse!(e, command)
    end

    # Report a command the shim will not run. The reason goes to mkmf.log, where
    # anyone debugging a failed extension build already looks, and then the
    # exception stops the extconf: a silent false here is exactly the
    # misdiagnosis ("You have to install development tools first") that hid this
    # whole problem before.
    def self.refuse!(error, command)
      message = <<~MSG
        rubycc: refusing to run a conftest command that needs a shell (#{error.construct}):
          #{command}
        The mkmf shim spawns conftest commands as an argv array because the target
        environment has no /bin/sh (DESIGN R5), and it does not fall back to one:
        a fallback would make the result depend on whether a shell happens to be
        installed. Nothing was run.
      MSG
      log_to_mkmf(message)
      raise ShellRequiredError, message
    end

    # Append +message+ to mkmf.log through mkmf's own Logging module (which
    # opens the file if it is not open yet). Logging is best-effort: if the log
    # cannot be written the refusal itself must still be raised.
    def self.log_to_mkmf(message)
      return unless defined?(::MakeMakefile::Logging)

      ::MakeMakefile::Logging.message("%s", message)
    rescue SystemCallError, IOError
      nil
    end

    # Put ShellFreeCommands in front of MakeMakefile's own methods.
    #
    # mkmf is normally *not* loaded yet at this point: the shim is injected with
    # `RUBYOPT=-rrubycc/mkmf_shim`, which runs before extconf.rb requires mkmf.
    # Defining the module first and prepending to it works in that order because
    # mkmf reopens the module rather than replacing it, and its closing
    # `include MakeMakefile` carries the prepended module into Object with it.
    # Prepending an already-prepended module is a no-op, so this is idempotent.
    def self.prepend_shell_free_commands!
      Object.const_set(:MakeMakefile, Module.new) unless defined?(::MakeMakefile)
      ::MakeMakefile.prepend(ShellFreeCommands)
    end

    # Rewrites the toolchain keys in both RbConfig hashes and prepends the
    # repository lib/ to RUBYLIB. Idempotent: the RUBYLIB entry is added only
    # once, and re-assigning the same command strings is harmless.
    def self.install!
      configs = [RbConfig::CONFIG]
      configs << RbConfig::MAKEFILE_CONFIG if defined?(RbConfig::MAKEFILE_CONFIG)

      replacements.each do |key, value|
        configs.each do |config|
          # PKG_CONFIG is only meaningful if the host build already knew a
          # pkg-config; leave an absent key absent so mkmf's own "no pkg-config"
          # path is preserved, but override a present one (even the empty string
          # RbConfig ships when none was found) to point at rubycc-pkgconf.
          next if key == "PKG_CONFIG" && !config.key?(key)

          config[key] = value
        end
      end

      prepend_rubylib!
      prepend_shell_free_commands!
    end

    # Puts the repository lib/ at the front of RUBYLIB so a rubycc executable
    # spawned by mkmf can `require "rubycc"` from a source checkout. Skips the
    # work when the directory is already the leading entry.
    def self.prepend_rubylib!
      current = ENV["RUBYLIB"]
      entries = current.to_s.split(File::PATH_SEPARATOR)
      return if entries.first == LIB_DIR

      ENV["RUBYLIB"] = [LIB_DIR, *current&.split(File::PATH_SEPARATOR)].join(File::PATH_SEPARATOR)
    end
  end
end

Rubycc::MkmfShim.install!
