# frozen_string_literal: true

require_relative "errors"
require_relative "model"
require_relative "expander"
require_relative "parser"
require_relative "executor"
require_relative "tool_command"

module Rubycc
  module Rmake
    # The public entry point: parse Makefile text, then answer "what would make
    # do?" for a goal as an execution Plan. It resolves the raw rules the Parser
    # produced into a working graph — a per-target index of explicit
    # prerequisites and recipes, the `.c.o:` suffix rules, the `.PHONY`/
    # `.SUFFIXES` special targets and VPATH — and walks that graph in
    # dependency order, comparing timestamps to decide which targets are stale.
    # It only plans: recipes are expanded and their `@`/`-`/`+` prefixes
    # interpreted, but nothing is run (the runner is B2).
    class Makefile
      # A target that names its own inference: `.c.o` builds `.o` from `.c`. Two
      # dots and nothing else, which is how it stays distinct from the one-dot
      # special targets `.PHONY` / `.SUFFIXES`.
      SUFFIX_TARGET = /\A(\.[^.\s]+)(\.[^.\s]+)\z/

      attr_reader :variables, :dir, :default_goal, :phony, :suffixes

      # +overrides+ are command-line variable definitions (make's `VAR=value`
      # operands) that take precedence over the Makefile's own assignments;
      # +defaults+ are POSIX's built-in variables (currently just `MAKE`, seeded
      # by CLI). Both are threaded to the Parser, which seeds them — protecting
      # +overrides+ from any Makefile assignment, but leaving +defaults+ as
      # ordinary variables a Makefile assignment can replace.
      def self.parse(text, dir: ".", overrides: {}, defaults: {})
        parsed = Parser.parse(text, overrides: overrides, defaults: defaults)
        new(parsed.variables, parsed.rules, dir: dir)
      end

      def initialize(variables, rules, dir: ".")
        @variables = variables
        @dir = dir
        @expander = Expander.new(@variables)
        @explicit = {}       # target name => {prereqs:, recipe:, double_colon:}
        @suffix_rules = []   # SuffixRule
        @phony = []
        @suffixes = []
        @default_goal = nil
        index_rules(rules)
      end

      # Compute the execution plan for +goal+ (the default goal when omitted),
      # judging staleness against the filesystem as of +now+ is implicit in the
      # file mtimes read from #dir. Returns a Plan of steps in the order make
      # would run them.
      def plan(goal = nil, now: Time.now)
        @now = now
        goal ||= @default_goal
        raise RmakeError, "no target specified and the Makefile has no default goal" if goal.nil?

        @steps = []
        @state = {}
        build(goal)
        Plan.new(@steps)
      end

      # Plan +goal+ and then run it through the shell-less Executor (B2/B3). This
      # is the "make it" entry point that pairs with #plan (the "what would make
      # do" entry point). +dry_run+ prints the recipe lines without running them
      # (make -n) and matches #plan's #command_lines.
      #
      # +tools+ turns on in-process tool substitution (B3): when truthy the
      # recipe commands that run this Makefile's compiler/linker — the ones whose
      # argv begins with the words of `$(CC)` / `$(LDSHARED)` — are run by
      # rubycc's own Driver in a forked child instead of being exec'd, so no
      # external compiler is needed. It defaults off, leaving the B2 behaviour
      # (every command exec'd) exactly as it was. +jobs+ is the maximum number of
      # independent steps to build concurrently (`-j`; default 1 = sequential).
      #
      # Returns the Plan that was executed; raises CommandFailedError /
      # UnsupportedRecipeError on the first failing or uninterpretable recipe line.
      def run(goal = nil, out: $stdout, err: $stderr, dry_run: false, env: ENV, now: Time.now,
              tools: nil, jobs: 1)
        computed = plan(goal, now: now)
        Executor.new(dir: @dir, out: out, err: err, dry_run: dry_run, env: env,
                     tools: tools ? tool_prefixes : [], jobs: jobs).execute(computed)
        computed
      end

      # The commands a `-`tools run substitutes for rubycc, each as the argv
      # prefix that names the program: the words of `$(CC)` and of `$(LDSHARED)`
      # (the compile and shared-link drivers mkmf emits), with trailing option
      # words trimmed off. `LDSHARED` is normally `$(CC) -shared`, so both
      # collapse to the same prefix and the `-shared` stays in the recipe where
      # the Driver reads it; a plain gcc Makefile gives ["gcc"].
      #
      # A prefix rather than a program name because the words that name the
      # program are not always one: the mkmf shim writes `CC = <ruby>
      # <path>/exe/rubycc`, launching the executable through the running
      # interpreter rather than through its `#!/usr/bin/env ruby` line. Matching
      # the whole prefix is what keeps `ruby -Ilib <script>` or `jruby <script>`
      # from handing the script path to the Driver as a compiler argument
      # (ToolCommand).
      def tool_prefixes
        [variable_value("CC"), variable_value("LDSHARED")]
          .map { |value| ToolCommand.prefix(value) }
          .reject(&:empty?).uniq
      end

      # The fully-expanded value of a variable (empty string when undefined).
      def variable_value(name)
        @expander.expand("$(#{name})")
      end

      private

      # --- turning raw rules into the working graph ------------------------

      def index_rules(rules)
        rules.each do |rule|
          targets = expand_words(rule.targets)
          prereqs = expand_words(rule.prerequisites)
          targets.each { |t| classify_target(t, prereqs, rule) }
        end
      end

      def classify_target(target, prereqs, rule)
        case target
        when ".PHONY"
          @phony.concat(prereqs)
        when ".SUFFIXES"
          prereqs.empty? ? @suffixes.clear : @suffixes.concat(prereqs)
        else
          if (m = SUFFIX_TARGET.match(target)) && prereqs.empty? && !rule.recipe.empty?
            @suffix_rules << SuffixRule.new(from_suffix: m[1], to_suffix: m[2], recipe: rule.recipe)
          else
            record_explicit(target, prereqs, rule)
          end
        end
      end

      def record_explicit(target, prereqs, rule)
        entry = (@explicit[target] ||= { prereqs: [], recipe: nil, double_colon: rule.double_colon? })
        entry[:prereqs].concat(prereqs)
        # The last rule to carry a recipe wins (make's behaviour for `:` rules);
        # prerequisite-only rules just contribute dependencies.
        entry[:recipe] = rule.recipe unless rule.recipe.empty?
        @default_goal ||= target
      end

      # --- dependency walk + staleness ------------------------------------

      # Returns [stale?, mtime_or_nil, exposed_steps]. +stale?+ propagates upward:
      # a prerequisite that will be rebuilt makes its dependents stale even if
      # their own file is newer, matching make's dry-run reasoning.
      #
      # +exposed_steps+ is the set of step targets a parent must wait for before
      # this target counts as ready — the dependency edges the `-j` scheduler
      # walks. A target that is itself a step exposes just itself (its own
      # prerequisite steps become that step's #prereqs and are hidden behind it);
      # a target that is not a step forwards its prerequisites' exposed steps, so
      # a phony aggregate like `all` exposes the real steps beneath it.
      def build(target)
        return @state[target] if @state.key?(target)

        # Tentative entry breaks any dependency cycle without looping forever.
        @state[target] = [false, file_mtime(target), []]
        node = resolve(target)

        rebuilt = false
        newest = nil
        dep_steps = []
        node[:prereqs].each do |p|
          stale, mtime, exposed = build(p)
          rebuilt ||= stale
          newest = newer(newest, mtime)
          dep_steps.concat(exposed)
        end

        own = node[:mtime]
        stale = node[:phony] || own.nil? || rebuilt || (newest && own && newest > own)

        if stale && node[:recipe]
          step = build_step(target, node)
          step.prereqs = dep_steps.uniq
          @steps << step
          exposed = [target]
        else
          exposed = dep_steps.uniq
        end

        @state[target] = [stale, own, exposed]
      end

      # Assemble everything needed to judge and, if stale, build +target+: its
      # prerequisites, the recipe (explicit or inferred), the automatic-variable
      # source/stem for a suffix rule, its mtime and whether it is phony.
      def resolve(target)
        entry = @explicit[target]
        prereqs = entry ? entry[:prereqs].dup : []
        recipe = entry && entry[:recipe]
        source = nil
        stem = nil

        if recipe.nil?
          inferred = infer_suffix_rule(target)
          if inferred
            rule, source, stem = inferred
            recipe = rule.recipe
            prereqs += [source]
          end
        end

        {
          target: target,
          prereqs: prereqs,
          recipe: recipe,
          source: source,
          stem: stem,
          mtime: file_mtime(target),
          phony: @phony.include?(target)
        }
      end

      # Find an inference rule for +target+: its suffix must be a known
      # `.SUFFIXES` entry and produced by some `.X.Y:` rule whose same-stem
      # source file exists (searched along VPATH). Returns [rule, source_name,
      # stem] or nil. Candidate source suffixes are tried in `.SUFFIXES` order,
      # as make does.
      def infer_suffix_rule(target)
        to_suffix = suffix_of(target)
        return nil unless to_suffix && @suffixes.include?(to_suffix)

        stem = target[0...(target.length - to_suffix.length)]
        @suffixes.each do |from|
          rule = @suffix_rules.find { |r| r.from_suffix == from && r.to_suffix == to_suffix }
          next unless rule

          resolved = resolve_prerequisite("#{stem}#{from}")
          return [rule, resolved, stem] if resolved
        end
        nil
      end

      def suffix_of(name)
        base = File.basename(name)
        dot = base.rindex(".")
        return nil if dot.nil? || dot.zero?

        base[dot..]
      end

      # --- recipe expansion ------------------------------------------------

      def build_step(target, node)
        autos = automatic_variables(target, node)
        commands = node[:recipe].map do |raw|
          expanded = @expander.expand(raw, autos)
          text, silent, ignore, force = split_prefixes(expanded)
          Command.new(text: text, silent: silent, ignore_error: ignore, force: force)
        end
        Step.new(target: target, commands: commands)
      end

      def automatic_variables(target, node)
        first = node[:source] || node[:prereqs].first || ""
        all = node[:prereqs].join(" ")
        {
          "@" => target,
          "<" => first,
          "^" => all,
          "+" => all,
          "?" => all,
          "*" => node[:stem] || strip_known_suffix(target)
        }
      end

      def strip_known_suffix(target)
        suffix = suffix_of(target)
        suffix && @suffixes.include?(suffix) ? target[0...(target.length - suffix.length)] : target
      end

      # Interpret the leading recipe-line prefixes make recognises: `@` (silent),
      # `-` (ignore errors) and `+` (run even under -n). They may appear in any
      # order and be separated by whitespace; the remaining text is the command
      # as make would print it under -n.
      def split_prefixes(line)
        silent = ignore = force = false
        i = 0
        loop do
          i += 1 while i < line.length && whitespace?(line[i])
          case line[i]
          when "@" then silent = true
          when "-" then ignore = true
          when "+" then force = true
          else break
          end
          i += 1
        end
        [line[i..] || "", silent, ignore, force]
      end

      def whitespace?(char)
        char == " " || char == "\t"
      end

      # --- filesystem / VPATH ---------------------------------------------

      def file_mtime(name)
        located = locate(name)
        located ? File.mtime(located[1]) : nil
      end

      # The name a prerequisite resolves to after VPATH search (what $< would
      # hold), or nil when no such file exists anywhere on the path.
      def resolve_prerequisite(name)
        located = locate(name)
        located && located[0]
      end

      # Search for +name+ as a plain path first, then along VPATH. Returns
      # [name_to_use, full_path] or nil. A "." VPATH entry (mkmf's srcdir) leaves
      # the name unadorned, so $< stays `parser.c` rather than `./parser.c`.
      def locate(name)
        direct = full_path(name)
        return [name, direct] if File.exist?(direct)
        return nil if absolute?(name)

        vpath_dirs.each do |d|
          candidate = (d == ".") ? name : File.join(d, name)
          full = full_path(candidate)
          return [candidate, full] if File.exist?(full)
        end
        nil
      end

      def vpath_dirs
        @vpath_dirs ||= variable_value("VPATH").split(/[:\s]+/).reject(&:empty?)
      end

      def full_path(name)
        absolute?(name) ? name : File.join(@dir, name)
      end

      def absolute?(name)
        name.start_with?("/")
      end

      # --- helpers ---------------------------------------------------------

      def expand_words(raw_words)
        raw_words.flat_map { |w| @expander.expand(w).split(/[ \t]+/) }.reject(&:empty?)
      end

      def newer(a, b)
        return b if a.nil?
        return a if b.nil?

        a > b ? a : b
      end
    end
  end
end
