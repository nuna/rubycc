# frozen_string_literal: true

require_relative "../command_line"

module Rubycc
  module Rmake
    # Which leading words of a command name the program it runs, so rmake can
    # tell a `$(CC)` recipe line from any other command.
    #
    # rmake substitutes rubycc's own Driver for the compiler and linker
    # (Executor's tool substitution), and has to recognise those lines in a
    # recipe. Matching a single program *name* was enough while `$(CC)` was one
    # word, but the mkmf shim now writes `CC = <ruby> <path>/exe/rubycc`: the
    # executables carry a `#!/usr/bin/env ruby` shebang, which a host without
    # /usr/bin/env cannot resolve (DESIGN R5), so they are launched through the
    # running interpreter. A rule that guessed which word was "the interpreter"
    # would have to recognise interpreters by name, and would then mis-split
    # `jruby <script>` or `ruby -Ilib <script>` — feeding the script path, or an
    # interpreter flag, to the Driver as if it were a compiler argument.
    #
    # So nothing is guessed. The Makefile already states the command: the tool is
    # whatever `$(CC)` (and `$(LDSHARED)`) expands to, and a recipe line runs that
    # tool exactly when its argv *starts with* those words. Matching is prefix
    # matching, and the words that matched are the words to drop before handing
    # the rest to the Driver.
    #
    # The one adjustment is at the tail: `LDSHARED = $(CC) -shared` names the same
    # program as `$(CC)` with a mode flag that belongs to the *Driver*, not to the
    # launcher. Trailing option words are therefore trimmed off a prefix, so the
    # link line keeps its `-shared` while the words that name the program are
    # still all dropped. A prefix never ends in an option word, so trimming can
    # never eat a flag the Driver needs.
    module ToolCommand
      module_function

      # The words of +value+ (an expanded `$(CC)`/`$(LDSHARED)`) that name the
      # program, or [] when it names none. Quotes are honoured — a path with a
      # space in it is one word — and a value the splitter cannot read yields no
      # prefix at all, which leaves those recipe lines to be spawned normally.
      def prefix(value)
        words = CommandLine.argv(value)
        words.pop while !words.empty? && option?(words.last)
        words
      rescue CommandLine::UnsupportedSyntaxError
        []
      end

      # Whether +argv+ runs the program named by +prefix+: every prefix word must
      # appear, in order, at the front of argv. Each word matches literally or by
      # basename, so a Makefile saying `gcc` still recognises a recipe's
      # `/usr/bin/gcc` (and vice versa). An empty prefix matches nothing.
      def match?(argv, prefix)
        return false if prefix.empty? || prefix.length > argv.length

        prefix.each_with_index.all? { |word, i| same_word?(argv[i], word) }
      end

      def same_word?(actual, expected)
        actual == expected || File.basename(actual) == File.basename(expected)
      end

      # An option word: `-shared`, `-E`, `-Ilib`. A lone `-` is a file name by
      # convention, not an option.
      def option?(word)
        word.start_with?("-") && word != "-"
      end
    end
  end
end
