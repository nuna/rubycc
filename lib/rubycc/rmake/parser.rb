# frozen_string_literal: true

require_relative "errors"
require_relative "model"
require_relative "expander"

module Rubycc
  module Rmake
    # Turns Makefile text into the raw model — variables plus explicit rules with
    # their recipes — that Makefile then resolves into suffix rules, phony
    # targets, the suffix list and a dependency graph. The parser accepts only
    # the constructs the mkmf corpus (test/fixtures/mkmf) actually emits:
    # variable assignments in all four flavours, backslash line continuation,
    # `#` comments, explicit rules (single and double colon, with tab recipes)
    # and the `.c.o:`-style two-suffix inference rules. Anything it cannot place
    # is a ParseError rather than a silent skip, so an unsupported Makefile fails
    # loudly instead of mis-building.
    class Parser
      # A variable name: letters, digits and underscore, not starting with a
      # digit. mkmf never uses dotted or otherwise exotic names, so keeping this
      # narrow is what lets a leading-dot line (`.PHONY:`, `.c.o:`) fall through
      # to rule handling instead of being mistaken for an assignment.
      NAME = /[A-Za-z_][A-Za-z0-9_]*/

      # An assignment is a name, optional spaces, then an operator anchored right
      # after the name. `+=`/`?=`/`::=`/`:=` are tried before bare `=`, and all
      # of them before a rule's `:` can match, so `all: dep` (colon then space)
      # is never read as `:=`.
      ASSIGN = /\A[ \t]*(#{NAME})[ \t]*(\+=|\?=|::=|:=|=)(.*)\z/

      # +overrides+ are command-line variable definitions (make's `VAR=value`
      # operands): they are seeded before parsing and win over any assignment the
      # Makefile makes to the same name, which is make's rule that a command-line
      # variable overrides a makefile variable. They are stored as simple
      # (already-expanded) variables so a `:=` assignment referencing one during
      # the parse sees the command-line value.
      #
      # +defaults+ are POSIX's built-in variables (currently just `MAKE`): unlike
      # +overrides+ they are ordinary variables once seeded, so a Makefile
      # assignment to the same name replaces them exactly as it would replace any
      # other pre-existing value. They are seeded first so an override (or a
      # Makefile assignment) to the same name still wins.
      def initialize(overrides: {}, defaults: {})
        @variables = {}
        @rules = []
        @order = 0
        @current_rule = nil
        @expander = Expander.new(@variables)
        @overrides = overrides || {}
        # Seeded values arrive from the process (a `VAR=value` operand, the
        # built-in MAKE) and are expanded into the Makefile's own byte text, so
        # they are taken as bytes here.
        (defaults || {}).each { |name, value| @variables[name] = Variable.new(:simple, value.to_s.b) }
        @overrides.each { |name, value| @variables[name] = Variable.new(:simple, value.to_s.b) }
      end

      attr_reader :variables, :rules

      def self.parse(text, overrides: {}, defaults: {})
        new(overrides: overrides, defaults: defaults).tap { |p| p.run(text) }
      end

      # Bytes in (lib/rubycc.rb): the Makefile grammar is spelled in ASCII, and
      # comments and recipe text are carried through.
      def run(text)
        text = text.b unless text.encoding == Encoding::BINARY
        logical_lines(text).each do |content, kind, line_no|
          if kind == :recipe
            handle_recipe(content, line_no)
          else
            handle_normal(content, line_no)
          end
        end
        self
      end

      private

      # --- physical -> logical lines (continuation handling) ---------------

      # Fold backslash-continued physical lines into logical lines, tagging each
      # as a recipe (started with a tab) or a normal line. A continuation and the
      # following line's leading whitespace collapse to a single space, matching
      # make; this is exercised by the unit tests since the corpus itself has no
      # continuations.
      def logical_lines(text)
        physical = text.split("\n", -1)
        result = []
        i = 0
        while i < physical.length
          raw = physical[i]
          start_line = i + 1
          recipe = raw.start_with?("\t")
          buf = raw
          while continuation?(buf)
            buf = drop_trailing_backslash(buf)
            i += 1
            nxt = (physical[i] || "")
            nxt = nxt.sub(/\A\t/, "") if recipe
            buf = "#{buf.rstrip} #{nxt.lstrip}"
          end
          result << [buf, recipe ? :recipe : :normal, start_line]
          i += 1
        end
        result
      end

      # A line continues when it ends with an odd number of backslashes (an even
      # number is that many escaped literal backslashes with no continuation).
      def continuation?(line)
        m = line.match(/(\\+)\z/)
        m && m[1].length.odd?
      end

      def drop_trailing_backslash(line)
        line.sub(/\\\z/, "")
      end

      # --- normal (non-recipe) lines ---------------------------------------

      def handle_normal(content, line_no)
        stripped = strip_comment(content)
        return if stripped.strip.empty?

        if (m = ASSIGN.match(stripped))
          @current_rule = nil
          apply_assignment(m[1], m[2], m[3])
        elsif stripped.include?(":")
          parse_rule(stripped, line_no)
        else
          raise ParseError.new("cannot parse line: #{content.strip.inspect}", line_number: line_no)
        end
      end

      # Strip a `#` comment. `\#` is an escaped literal hash. Recipe lines are
      # never passed here, so `#` inside a recipe stays intact for the shell.
      def strip_comment(line)
        out = +""
        i = 0
        while i < line.length
          c = line[i]
          if c == "\\" && line[i + 1] == "#"
            out << "#"
            i += 2
          elsif c == "#"
            break
          else
            out << c
            i += 1
          end
        end
        out
      end

      def apply_assignment(name, op, rhs)
        # A command-line override wins over every makefile assignment to the same
        # name (make's precedence rule), so ignore the assignment entirely.
        return if @overrides.key?(name)

        # make strips leading whitespace after the operator but keeps trailing
        # whitespace in the value (a documented make behaviour the golden tests
        # depend on, e.g. `dldflags = ... zlib ` contributes its trailing space).
        value = rhs.sub(/\A[ \t]+/, "")
        case op
        when "="
          @variables[name] = Variable.new(:recursive, value)
        when ":=", "::="
          @variables[name] = Variable.new(:simple, @expander.expand(value))
        when "?="
          @variables[name] ||= Variable.new(:recursive, value)
        when "+="
          append_assignment(name, value)
        end
      end

      def append_assignment(name, value)
        existing = @variables[name]
        if existing.nil?
          @variables[name] = Variable.new(:recursive, value)
        elsif existing.simple?
          joined = existing.value.empty? ? @expander.expand(value) : "#{existing.value} #{@expander.expand(value)}"
          @variables[name] = Variable.new(:simple, joined)
        else
          joined = existing.value.empty? ? value : "#{existing.value} #{value}"
          @variables[name] = Variable.new(:recursive, joined)
        end
      end

      # --- rules -----------------------------------------------------------

      def parse_rule(line, _line_no)
        idx = line.index(":")
        target_part = line[0...idx]
        rest = line[(idx + 1)..]
        double_colon = rest.start_with?(":")
        rest = rest[1..] if double_colon

        # An inline recipe after `;` (target: dep ; cmd). Absent from the corpus
        # but cheap and part of the grammar.
        inline = nil
        if (semi = rest.index(";"))
          inline = rest[(semi + 1)..].sub(/\A[ \t]+/, "")
          rest = rest[0...semi]
        end

        @order += 1
        rule = ExplicitRule.new(
          targets: split_words(target_part),
          prerequisites: split_words(rest),
          recipe: [],
          double_colon: double_colon,
          order: @order
        )
        rule.recipe << inline if inline
        @rules << rule
        @current_rule = rule
      end

      def handle_recipe(content, line_no)
        raise ParseError.new("recipe line has no preceding rule", line_number: line_no) if @current_rule.nil?

        # Drop only the leading recipe-marker tab; any further indentation is
        # part of the command text (the prefix scanner ignores leading blanks).
        @current_rule.recipe << content.sub(/\A\t/, "")
      end

      def split_words(text)
        text.split(/[ \t]+/).reject(&:empty?)
      end
    end
  end
end
