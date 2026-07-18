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
  end
end
