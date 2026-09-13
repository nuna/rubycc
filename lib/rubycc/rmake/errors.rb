# frozen_string_literal: true

module Rubycc
  # The base error is normally provided by lib/rubycc.rb. rmake is loadable on
  # its own (B1 ships no CLI wiring), so define a stand-in only when the full
  # library has not been required yet.
  Error = Class.new(StandardError) unless defined?(Error)

  module Rmake
    # Raised for a defect in the Makefile the user handed us: a syntax rmake's
    # mkmf-subset does not accept, or a runaway variable expansion. rmake never
    # parses C, so this is deliberately distinct from CompileError; it names the
    # make-level construct at fault so the failure points back at the Makefile.
    class RmakeError < Rubycc::Error; end

    # A line the parser cannot classify as an assignment, a rule, a recipe, or a
    # directive that mkmf is known to emit. Carries the 1-based source line so
    # the offending text can be located in the generated Makefile.
    class ParseError < RmakeError
      attr_reader :line_number

      def initialize(message, line_number:)
        @line_number = line_number
        super("Makefile:#{line_number}: #{message}")
      end
    end

    # Raised when variable expansion exceeds its depth budget, which in practice
    # means a reference cycle (`A = $(B)` / `B = $(A)`). It is a DoS fail-safe,
    # not a diagnosis of the exact cycle — the budget stops unbounded recursion
    # before it can exhaust the Ruby stack.
    class ExpansionError < RmakeError; end

    # Raised while planning when a name the build needs is neither an existing
    # file nor something the Makefile can make: no explicit rule names it as a
    # target, no inference rule applies to it, and it is not .PHONY. Planning
    # stops at that name rather than leaving the gap to surface later as a
    # confusing failure of whatever consumes it (a link that cannot find an
    # object). The wording follows GNU make's diagnostic, so a log reads the
    # same whichever make produced it: `No rule to make target 'x.o', needed by
    # 'prog'.  Stop.`, and without the `needed by` part for a goal given on the
    # command line.
    class NoRuleError < RmakeError
      attr_reader :target, :needed_by

      def initialize(target:, needed_by: nil)
        @target = target
        @needed_by = needed_by
        detail = needed_by ? ", needed by '#{needed_by}'" : ""
        super("No rule to make target '#{target}'#{detail}.  Stop.")
      end
    end

    # Base for a failure that happens while *running* a plan (as opposed to
    # parsing or planning it). It always names the target whose recipe was
    # executing and the exact expanded recipe line at fault, so a build failure
    # points back at "which command of which target" the way make's own
    # `*** [target] Error` line does (N3).
    class ExecutionError < RmakeError
      attr_reader :target, :command

      def initialize(message, target:, command:)
        @target = target
        @command = command
        super("#{target}: #{message}: #{command.inspect}")
      end
    end

    # A recipe command exited non-zero (or an internal utility reported failure)
    # and the line was not marked to ignore errors (`-`). Carries the exit reason
    # when one is known (a missing external tool, a utility's own message).
    class CommandFailedError < ExecutionError
      def initialize(target:, command:, reason: nil)
        super(reason ? "recipe command failed (#{reason})" : "recipe command failed",
              target: target, command: command)
      end
    end

    # The shell-less runner met a construct it does not interpret (a pipe,
    # background `&`, command substitution, an unterminated quote, ...). Since
    # rubycc runs recipes without /bin/sh, an unhandled construct must fail
    # loudly with the offending target and line rather than be silently dropped —
    # this is the signal that a gem's recipe needs to be added to the runner's
    # scope or the gem listed as unsupported (ROADMAP §6 B2).
    class UnsupportedRecipeError < ExecutionError
      def initialize(construct, target:, command:)
        super("unsupported shell construct (#{construct})", target: target, command: command)
      end
    end
  end
end
