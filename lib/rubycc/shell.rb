# frozen_string_literal: true

require_relative "command_line"

module Rubycc
  # The small piece of shell grammar rubycc interprets itself: `for`, `if`,
  # brace groups and shell variables, layered on top of the word splitter in
  # Rubycc::CommandLine. Automake and libtool write their install rules as one
  # long line of exactly these constructs
  #
  #     list=...; for p in $list; do if test -f $p; then ...; fi; done; \
  #     test -z "$list2" || { ...; }
  #
  # and rmake has to run them without /bin/sh, which the minimal target
  # environment does not have (DESIGN R5).
  #
  # == Why a library and not an executable
  #
  # A `sh`-alike binary would have nothing pointing at it: `#!/bin/sh` and
  # Ruby's own `system` carry the path to the interpreter baked in, so shipping
  # one would not make anybody use it. And starting a process per recipe line is
  # the cost rmake was built to avoid (M3 B3 runs the compiler in-process). As a
  # library the interpreter is called where the recipe already is; if a command
  # line ever needs one, a thin wrapper around #run is all it takes.
  #
  # == The division of labour
  #
  # * CommandLine is the token layer: quoting, word splitting, connectors,
  #   redirections. It is shared with the mkmf shim and knows no grammar.
  # * Shell is the syntax layer: it recognises the compound commands, keeps the
  #   shell variables, and expands parameters.
  # * Running a *simple* command is neither one's business. Shell hands each one
  #   to the runner the caller supplied (rmake's Executor, which owns the
  #   builtins, the tool table and the redirections). Nothing about make —
  #   targets, tools, `$(...)` — is known here.
  #
  # == What is deliberately absent
  #
  # Subshells, pipelines, command substitution, `case`, `while`, `until`,
  # functions, background commands, here-documents, `export`, `shift` and the
  # positional parameters all raise UnsupportedSyntaxError. The list grows only
  # when a recipe that has to build actually needs an entry, because every
  # construct interpreted here is one that must keep behaving identically
  # forever — approximating a shell is the failure mode this code exists to
  # avoid, not a goal.
  class Shell
    # Refusals come out as CommandLine's error: the two layers are one refusal
    # surface to a caller (rmake wraps whichever it gets in
    # UnsupportedRecipeError), and which layer noticed is an implementation
    # detail — an unterminated quote is caught while splitting, a stray `fi`
    # while parsing.
    UnsupportedSyntaxError = CommandLine::UnsupportedSyntaxError

    # A list of commands joined by connectors: [[connector, node], ...] where
    # connector is :first, :semi, :and or :or.
    List = Struct.new(:items)
    # One simple command, kept as the *source text* it occupied. Expansion
    # happens when it runs, not when it is parsed, because a variable set
    # earlier in the same line has to be visible to it.
    Simple = Struct.new(:text)
    # `for NAME in WORDS; do BODY; done`. +words+ is source text too, for the
    # same reason and because its expansion is what gets field-split.
    For = Struct.new(:name, :words, :body)
    # `if`: +clauses+ is [[condition, body], ...] with one entry per `if`/`elif`.
    If = Struct.new(:clauses, :else_body)
    # `{ BODY; }` — no subshell, so it is just its body's status.
    Group = Struct.new(:body)

    # A portable variable name.
    NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze
    # The default IFS: an unquoted expansion is split on runs of these.
    IFS = /[ \t\n]+/.freeze

    # The variables set so far. The caller owns the hash — rmake keeps one per
    # recipe line, since make starts a fresh shell for every line and a variable
    # must not leak into the next one. A name not set here is looked up in
    # +environment+, the same table the caller will hand to the processes it
    # spawns: `echo $PATH` and a child's own view of PATH must not disagree
    # inside one recipe. A name in neither expands to the empty string, as in a
    # shell without `set -u` -- which is why an unset path variable silently
    # yields `/lib` rather than an error, exactly as it would under sh.
    attr_reader :variables

    # +runner+ (a block or a callable) receives one CommandLine::SimpleCommand —
    # assignments, argv and redirections, already expanded and quote-stripped —
    # and returns whether it succeeded.
    def initialize(variables: {}, environment: {}, runner: nil, &block)
      @variables = variables
      @environment = environment
      @runner = runner || block
      raise ArgumentError, "Shell needs a runner for simple commands" unless @runner
    end

    # Interpret one line of shell text and return whether it succeeded. The
    # whole line is parsed before anything runs, so a construct this shell does
    # not interpret is reported instead of half-executed — which is also what a
    # shell does with a syntax error.
    def run(text)
      evaluate(Parser.new(text).parse)
    end

    private

    def evaluate(node)
      case node
      when List then evaluate_list(node)
      when Simple then evaluate_simple(node)
      when For then evaluate_for(node)
      when If then evaluate_if(node)
      when Group then evaluate_list(node.body)
      end
    end

    # An and-or list: `&&` runs the next command only after success, `||` only
    # after failure, `;` always. One status carries left to right; an empty list
    # is a success, as an empty shell script is.
    def evaluate_list(list)
      status = true
      list.items.each do |connector, node|
        run = case connector
              when :first, :semi then true
              when :and then status
              when :or then !status
              end
        status = evaluate(node) if run
      end
      status
    end

    # `for NAME in WORDS; do BODY; done`: the word list is expanded once, up
    # front, and the body runs once per field with NAME set. Zero fields means
    # zero iterations and a success — which is exactly what makes the Automake
    # idiom (`list=; for p in $list; ...`) a no-op rather than an error.
    def evaluate_for(node)
      status = true
      fields(node.words).each do |value|
        @variables[node.name] = value
        status = evaluate_list(node.body)
      end
      status
    end

    # The first clause whose condition succeeds decides the status; with no
    # clause taken and no `else`, an `if` succeeds (POSIX).
    def evaluate_if(node)
      node.clauses.each do |condition, body|
        return evaluate_list(body) if evaluate_list(condition)
      end
      node.else_body ? evaluate_list(node.else_body) : true
    end

    # Expand the command's source, split it back into words, and either record
    # an assignment or hand the command to the runner.
    def evaluate_simple(node)
      commands = CommandLine.parse(expand(node.text))
      # Expanded values are respelled as quoted words (see #fields_text), so an
      # expansion cannot introduce a connector and produce a second command.
      unsupported!("expansion produced #{commands.length} commands", node.text) if commands.length > 1
      return true if commands.empty?

      command = commands.first[1]
      # `VAR=value` on its own sets a shell variable that lives for the rest of
      # the line; `VAR=value cmd` is the command's environment instead and is
      # the runner's business, which is why only the command-less form is
      # intercepted here. Both are what POSIX describes (XCU 2.9.1).
      return assign(command.assignments) if command.argv.empty?

      !!@runner.call(command)
    end

    def assign(assignments)
      assignments.each do |assignment|
        name, value = assignment.split("=", 2)
        @variables[name] = value
      end
      true
    end

    # The fields an unquoted word list expands to (the `for` operand).
    # CommandLine.tokenize rather than .parse: `for x in a=1` iterates over the
    # word `a=1`, which .parse would have read as an assignment.
    def fields(text)
      CommandLine.tokenize(expand(text)).map do |token|
        unsupported!("redirection in a `for` word list", text) unless token[0] == :word
        token[1]
      end
    end

    # --- expansion --------------------------------------------------------

    # Rewrite +text+ with its parameters expanded, leaving text that
    # CommandLine can split. Expanding into text rather than into finished
    # words is what keeps the two layers apart: the splitting rules stay in one
    # place. It works because an expanded value is written back *quoted* —
    # unquoted, a value is split into fields on IFS and each field respelled as
    # one word (CommandLine.quote), so a value holding a space becomes two
    # words while one holding a `;` or a quote becomes data, never syntax. That
    # is the POSIX order — expansion, then field splitting, and no further
    # interpretation of the result (XCU 2.6).
    def expand(text)
      out = +""
      i = 0
      n = text.length
      while i < n
        c = text[i]
        case c
        when "'"
          close = text.index("'", i + 1)
          unsupported!("unterminated quote", text) if close.nil?
          out << text[i..close] # single quotes suppress expansion entirely
          i = close + 1
        when '"'
          segment, i = expand_double_quoted(text, i)
          out << segment
        when "\\"
          # A backslash escape is carried over untouched for the splitter to
          # remove; `\$` must not expand.
          out << text[i, 2]
          i += 2
        when "`"
          unsupported!("command substitution '`'", text)
        when "$"
          name, i = read_parameter(text, i)
          out << (name ? fields_text(lookup(name)) : "$")
        else
          out << c
          i += 1
        end
      end
      out
    end

    # Expand inside a double-quoted segment, which keeps its quotes: the value
    # is not field-split there, so it only needs the four characters that are
    # special between double quotes escaped (CommandLine strips exactly those
    # backslashes again).
    def expand_double_quoted(text, i)
      out = +'"'
      j = i + 1
      n = text.length
      loop do
        unsupported!("unterminated quote", text) if j >= n

        case (c = text[j])
        when '"'
          out << c
          j += 1
          break
        when "\\"
          out << text[j, 2]
          j += 2
        when "`"
          unsupported!("command substitution '`'", text)
        when "$"
          name, j = read_parameter(text, j)
          out << (name ? quote_in_double_quotes(lookup(name)) : "$")
        else
          out << c
          j += 1
        end
      end
      [out, j]
    end

    # Read the parameter starting at the `$` in +text+ at +i+. Returns
    # [name, index_after] — with a nil name when the `$` names nothing and so
    # stands for itself, which is how `$` before a space or a `/` behaves in a
    # shell. Anything beyond a plain variable name is refused rather than
    # approximated: `${x:-y}` and the positional and special parameters would
    # each need semantics of their own.
    def read_parameter(text, i)
      nxt = text[i + 1]
      case nxt
      when "{"
        close = text.index("}", i + 2)
        unsupported!("unterminated '${'", text) if close.nil?
        name = text[(i + 2)...close]
        unsupported!("parameter expansion '${#{name}}'", text) unless name.match?(NAME)
        [name, close + 1]
      when "(" then unsupported!("command substitution '$('", text)
      when /[A-Za-z_]/
        j = i + 1
        j += 1 while j < text.length && text[j].match?(/[A-Za-z0-9_]/)
        [text[(i + 1)...j], j]
      when /[0-9@*#?!$\-]/ then unsupported!("special parameter '$#{nxt}'", text)
      else [nil, i + 1]
      end
    end

    # A variable set in this line wins; otherwise the environment answers, and a
    # name in neither expands to the empty string (this shell has no `set -u`).
    def lookup(name)
      @variables.fetch(name) { @environment[name] || "" }
    end

    # +value+ as the text of the fields it splits into, each respelled so the
    # splitter reads it back as one word. An empty (or all-blank) value yields
    # no words at all, which is why `for p in $empty` iterates zero times and
    # `cmd $empty` is `cmd`.
    #
    # The one place this rewrite is not the shell's answer: a value that looks
    # like `a=1` expanding into the command-name position is read back as an
    # assignment, where a shell would have decided that before expanding. No
    # recipe writes that, and telling the two apart would mean moving the
    # assignment rule out of the splitter, where both callers need it.
    def fields_text(value)
      value.split(IFS).reject(&:empty?).map { |field| CommandLine.quote(field) }.join(" ")
    end

    def quote_in_double_quotes(value)
      value.gsub(/[\\"$`]/) { |c| "\\#{c}" }
    end

    def unsupported!(construct, text)
      raise UnsupportedSyntaxError.new(construct, text)
    end

    # Builds the syntax tree of one line. It works on CommandLine's tokens plus
    # their spans: the structure is decided by the *unexpanded* words (a shell
    # recognises its grammar before it expands anything), and each simple
    # command is remembered as the slice of the line it came from so that its
    # expansion can be deferred to the moment it runs.
    class Parser
      # The words this grammar gives a meaning to. A word outside the list is
      # an ordinary command name; one inside it that turns up where the grammar
      # does not expect it (a stray `fi`) is a syntax error, not a command.
      KEYWORDS = CommandLine::COMPOUND_WORDS

      def initialize(text)
        @text = text
        @tokens = CommandLine.tokenize_spans(text)
        @i = 0
      end

      def parse
        list = parse_list([])
        unsupported!("unexpected #{describe(peek)}") unless at_end?
        list
      end

      private

      def parse_list(stops)
        items = []
        connector = :first
        loop do
          break if at_end? || stops.include?(bare_word)

          items << [connector, parse_command]
          break unless (next_connector = connector_type)

          connector = next_connector
          @i += 1
        end
        List.new(items)
      end

      def parse_command
        case (word = bare_word)
        when "for" then parse_for
        when "if" then parse_if
        when "{" then parse_group
        else
          # Every keyword the grammar expects is consumed by the clause that
          # expects it, so one reaching here is misplaced.
          unsupported!("unexpected '#{word}'") if KEYWORDS.include?(word)
          parse_simple
        end
      end

      # Everything up to the next connector. Only the first word of a command
      # can be a keyword (XCU 2.9), so `echo done` needs no special care: the
      # scan stops at connectors and nothing else.
      def parse_simple
        # A reserved word no layer interprets (`while`, `case`, `!`) is refused
        # while parsing, not when the command would run, so that the line is
        # rejected as a whole: `echo a; while ...` must not echo first.
        # CommandLine refuses it again when the command is split, for a caller
        # that reaches it without coming through here.
        if (word = bare_word) && CommandLine::RESERVED_WORDS.include?(word)
          unsupported!("shell reserved word '#{word}'")
        end

        start = @i
        @i += 1 while !at_end? && connector_type.nil?
        # Nothing at all (`;;`, a leading `;`) is an empty command, which the
        # splitter has always let through as a no-op success.
        Simple.new(start == @i ? "" : source(start, @i - 1))
      end

      def parse_for
        @i += 1
        name = bare_word
        unsupported!("`for` without a variable name") unless name&.match?(NAME)

        @i += 1
        # `for x; do ...` iterates over the positional parameters, which this
        # shell does not have; only the explicit word list is interpreted.
        unsupported!("`for` without `in`") unless bare_word == "in"

        @i += 1
        words = parse_for_words
        # The word list is closed by the `;` (POSIX's sequential_sep), not by
        # the `do` itself: `for p in a do b; do ...` loops over three words,
        # `do` among them. Verified against /bin/sh, which likewise refuses
        # `for p in a b do ...; done` for the missing separator.
        unsupported!("`for` word list without a `;` before `do`") unless connector_type == :semi

        @i += 1
        expect!("do")
        body = parse_list(%w[done])
        expect!("done")
        For.new(name, words, body)
      end

      # The operand list of a `for`, kept as source text.
      def parse_for_words
        start = @i
        @i += 1 while word?
        start == @i ? "" : source(start, @i - 1)
      end

      def parse_if
        @i += 1
        clauses = []
        loop do
          condition = parse_list(%w[then])
          expect!("then")
          clauses << [condition, parse_list(%w[elif else fi])]
          break unless bare_word == "elif"

          @i += 1
        end
        else_body = nil
        if bare_word == "else"
          @i += 1
          else_body = parse_list(%w[fi])
        end
        expect!("fi")
        If.new(clauses, else_body)
      end

      def parse_group
        @i += 1
        body = parse_list(%w[}])
        expect!("}")
        Group.new(body)
      end

      # --- token access ---------------------------------------------------

      def peek
        @tokens[@i]
      end

      def at_end?
        @i >= @tokens.length
      end

      def word?
        !at_end? && peek[0][0] == :word
      end

      def connector_type
        return nil if at_end?

        type = peek[0][0]
        %i[semi and or].include?(type) ? type : nil
      end

      # The word at the cursor when it is spelled bare, else nil — the form the
      # grammar reads, since quoting takes a word's keyword-hood away: `"for"`
      # is a command named `for`, not a loop (XCU 2.9). The span is what tells
      # the two apart, quote removal having already made them equal.
      def bare_word
        return nil unless word?

        raw = @text[peek[1]]
        raw == peek[0][1] ? raw : nil
      end

      def expect!(word)
        unsupported!("expected `#{word}`, found #{describe(peek)}") unless bare_word == word

        @i += 1
      end

      # The source text spanning tokens +first+ through +last+, inclusive.
      def source(first, last)
        @text[@tokens[first][1].begin...@tokens[last][1].end]
      end

      def describe(token)
        return "end of line" if token.nil?

        case token[0][0]
        when :word then "'#{token[0][1]}'"
        when :semi then "';'"
        when :and then "'&&'"
        when :or then "'||'"
        else "a redirection"
        end
      end

      def unsupported!(construct)
        raise UnsupportedSyntaxError.new(construct, @text)
      end
    end
  end
end
