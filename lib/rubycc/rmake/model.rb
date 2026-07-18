# frozen_string_literal: true

module Rubycc
  module Rmake
    # A make variable. The flavor decides *when* the right-hand side is expanded:
    # a recursive (`=`) variable keeps its text verbatim and is expanded afresh
    # on every reference, so it can see values defined later; a simple (`:=`)
    # variable is expanded once at definition and thereafter holds a plain
    # string. `?=` produces a recursive variable (only when the name is unset)
    # and `+=` appends in whichever flavor the variable already has.
    class Variable
      attr_reader :flavor, :value

      def initialize(flavor, value)
        @flavor = flavor
        @value = value
      end

      def simple?
        @flavor == :simple
      end

      def recursive?
        @flavor == :recursive
      end
    end

    # An explicit rule as written: its target and prerequisite words and recipe
    # lines are stored unexpanded, because make expands them against the final
    # variable table (all mkmf assignments precede the rules that use them). A
    # `::` rule sets +double_colon+; +order+ is the read order, used only to pick
    # the default goal (the first non-special target seen).
    class ExplicitRule
      attr_reader :targets, :prerequisites, :recipe, :order

      def initialize(targets:, prerequisites:, recipe:, double_colon:, order:)
        @targets = targets
        @prerequisites = prerequisites
        @recipe = recipe
        @double_colon = double_colon
        @order = order
      end

      def double_colon?
        @double_colon
      end
    end

    # A double-suffix inference rule such as `.c.o:` — build a `to_suffix` file
    # from a same-stem `from_suffix` file using +recipe+.
    class SuffixRule
      attr_reader :from_suffix, :to_suffix, :recipe

      def initialize(from_suffix:, to_suffix:, recipe:)
        @from_suffix = from_suffix
        @to_suffix = to_suffix
        @recipe = recipe
      end
    end

    # One shell command in an execution step: its expanded text with the
    # recipe-line prefixes already interpreted. +silent+ (`@`), +ignore_error+
    # (`-`) and +force+ (`+`) are retained as attributes so a dumper can show
    # them; B1 only plans, it does not run anything.
    class Command
      attr_reader :text, :silent, :ignore_error, :force

      def initialize(text:, silent:, ignore_error:, force:)
        @text = text
        @silent = silent
        @ignore_error = ignore_error
        @force = force
      end

      def silent?
        @silent
      end

      def ignore_error?
        @ignore_error
      end

      def force?
        @force
      end
    end

    # A single node of the execution plan: the target that would be (re)built and
    # the ordered, fully-expanded commands that would build it. +prereqs+ names
    # the other steps that must complete before this one may start — the edges a
    # parallel scheduler (B3 `-j`) needs. It is empty for a step with no stale
    # step among its prerequisites, and the sequential runner ignores it entirely
    # (the plan is already emitted in a valid dependency order).
    class Step
      attr_reader :target, :commands
      attr_accessor :prereqs

      def initialize(target:, commands:, prereqs: [])
        @target = target
        @commands = commands
        @prereqs = prereqs
      end
    end

    # The result of Makefile#plan: the steps in the order make would run them
    # (prerequisites before dependents). It carries no execution logic — the
    # recipe runner is B2.
    class Plan
      attr_reader :steps

      def initialize(steps)
        @steps = steps
      end

      # The command texts in execution order, one per line — the shape a
      # `make -n` transcript takes, used by the golden tests.
      def command_lines
        @steps.flat_map { |step| step.commands.map(&:text) }
      end

      # A human-readable dump that, unlike #command_lines, keeps the target
      # boundaries and the +@+/+-+/+++ prefix attributes visible.
      def dump
        @steps.map do |step|
          lines = step.commands.map do |cmd|
            flags = +""
            flags << "@" if cmd.silent?
            flags << "-" if cmd.ignore_error?
            flags << "+" if cmd.force?
            "    #{flags.empty? ? '' : "#{flags} "}#{cmd.text}"
          end
          (["#{step.target}:"] + lines).join("\n")
        end.join("\n")
      end
    end
  end
end
