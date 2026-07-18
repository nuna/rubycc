# frozen_string_literal: true

require_relative "errors"
require_relative "model"
require_relative "expander"
require_relative "parser"
require_relative "executor"

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

      def self.parse(text, dir: ".")
        parsed = Parser.parse(text)
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

      # Plan +goal+ and then run it through the shell-less Executor (B2). This is
      # the "make it" entry point that pairs with #plan (the "what would make do"
      # entry point). +dry_run+ prints the recipe lines without running them
      # (make -n) and matches #plan's #command_lines. Returns the Plan that was
      # executed; raises CommandFailedError / UnsupportedRecipeError on the first
      # failing or uninterpretable recipe line.
      def run(goal = nil, out: $stdout, err: $stderr, dry_run: false, env: ENV, now: Time.now)
        computed = plan(goal, now: now)
        Executor.new(dir: @dir, out: out, err: err, dry_run: dry_run, env: env).execute(computed)
        computed
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

      # Returns [stale?, mtime_or_nil]. +stale?+ propagates upward: a prerequisite
      # that will be rebuilt makes its dependents stale even if their own file is
      # newer, matching make's dry-run reasoning.
      def build(target)
        return @state[target] if @state.key?(target)

        # Tentative entry breaks any dependency cycle without looping forever.
        @state[target] = [false, file_mtime(target)]
        node = resolve(target)

        rebuilt = false
        newest = nil
        node[:prereqs].each do |p|
          stale, mtime = build(p)
          rebuilt ||= stale
          newest = newer(newest, mtime)
        end

        own = node[:mtime]
        stale = node[:phony] || own.nil? || rebuilt || (newest && own && newest > own)
        @steps << build_step(target, node) if stale && node[:recipe]

        @state[target] = [stale, own]
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
