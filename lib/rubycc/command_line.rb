# frozen_string_literal: true

module Rubycc
  # The base error is normally provided by lib/rubycc.rb. This file is loadable
  # on its own (the mkmf shim pulls it in without the compiler behind it), so
  # define a stand-in only when the full library has not been required yet.
  Error = Class.new(StandardError) unless defined?(Error)

  # Splitting a command line the way a POSIX shell would — and *only* the part a
  # shell does before it execs: word splitting and quote removal. The point is to
  # run a command that was written as one string without /bin/sh, which the
  # minimal target environment does not have (DESIGN R5).
  #
  # Two callers share this: rmake, which interprets Makefile recipe lines
  # (connectors, redirections, `VAR=value` prefixes and all), and the mkmf shim,
  # which turns the single conftest command string mkmf builds into an argv array
  # before mkmf spawns it. Both need exactly the same word-splitting rules, so
  # the splitter lives here rather than in either of them.
  #
  # Nothing here expands anything: no variables, no globs, no command
  # substitution. A construct that would need a shell to interpret raises
  # UnsupportedSyntaxError — the caller reports it. Falling back to a shell is
  # not an option we keep in reserve: a fallback would make the result depend on
  # whether a shell happens to exist, which is the very thing this code exists to
  # remove.
  module CommandLine
    # A construct the splitter does not interpret (a pipe, background `&`,
    # command substitution, an unterminated quote, ...). It names the construct
    # and the line it was found in; callers wrap it in their own error type with
    # whatever context they have (rmake adds the target, the mkmf shim writes the
    # reason to mkmf.log).
    class UnsupportedSyntaxError < Rubycc::Error
      attr_reader :construct, :command

      def initialize(construct, command)
        @construct = construct
        @command = command
        super("unsupported shell construct (#{construct}): #{command.inspect}")
      end
    end

    # One redirection parsed off a command: which stream (:stdout/:stderr),
    # whether it truncates or appends, and the target path (relative to the
    # command's cwd).
    Redirection = Struct.new(:stream, :mode, :path)

    # One simple command: leading `VAR=value` assignments, the argv words and
    # the redirections that apply to it.
    SimpleCommand = Struct.new(:assignments, :argv, :redirections)

    # Characters after which a backslash inside double quotes keeps its
    # special meaning (POSIX quote removal, XCU 2.2 / 2.2.3): only these five
    # make the backslash consume — and remove itself along with — the next
    # character; before a newline both vanish (line continuation). Before any
    # other character the backslash inside double quotes is left in the word
    # verbatim: `"a\b"` stays `a\b`, while `"a\"b"` becomes `a"b`. Verified
    # against /bin/sh (dash).
    DQUOTE_BACKSLASH_SPECIAL = ["$", "`", '"', "\\", "\n"].freeze

    # The word that names each connector in a diagnostic.
    CONNECTOR_NAMES = { and: "&&", or: "||", semi: ";" }.freeze

    module_function

    # Split +text+ into tokens: :word (quote-stripped), the connectors
    # :and/:or/:semi and :redirect markers. Single quotes protect everything
    # verbatim — backslash has no special meaning inside them. Double quotes
    # strip a backslash only before `$`/`` ` ``/`"`/`\`/newline
    # (DQUOTE_BACKSLASH_SPECIAL); elsewhere the backslash stays in the word.
    # Outside any quote, a backslash preserves the literal value of the
    # following character and disappears itself, except before a newline
    # where both vanish (line continuation) — this is POSIX quote removal,
    # verified against /bin/sh. mkmf relies on the outside-quotes rule: it
    # writes `-DSYSCONFDIR=\"...\"` expecting the shell to unescape the
    # backslash-quotes into a literal `"` in the word. Genuinely unhandled
    # shell syntax (pipe, background, substitution, subshell) stops the split.
    def tokenize(text)
      tokens = []
      word = nil
      i = 0
      n = text.length
      while i < n
        c = text[i]
        case c
        when "'"
          close = text.index(c, i + 1)
          unsupported!("unterminated quote", text) if close.nil?
          word = (word || +"") + text[(i + 1)...close]
          i = close + 1
        when '"'
          segment, i = scan_double_quoted(text, i)
          word = (word || +"") + segment
        when "\\"
          nxt = text[i + 1]
          if nxt.nil?
            # A lone trailing backslash with nothing to escape is kept
            # literally (verified against /bin/sh).
            word = (word || +"") + c
            i += 1
          elsif nxt == "\n"
            i += 2 # line continuation: backslash and newline both vanish
          else
            word = (word || +"") + nxt
            i += 2
          end
        when " ", "\t"
          tokens << [:word, word] if word
          word = nil
          i += 1
        when "&"
          tokens << [:word, word] if word
          word = nil
          unsupported!("background '&'", text) unless text[i + 1] == "&"
          tokens << [:and]
          i += 2
        when "|"
          tokens << [:word, word] if word
          word = nil
          unsupported!("pipe '|'", text) unless text[i + 1] == "|"
          tokens << [:or]
          i += 2
        when ";"
          tokens << [:word, word] if word
          word = nil
          tokens << [:semi]
          i += 1
        when ">"
          tokens << [:word, word] if word
          word = nil
          if text[i + 1] == ">"
            tokens << [:redirect, :stdout, :append]
            i += 2
          else
            tokens << [:redirect, :stdout, :truncate]
            i += 1
          end
        when "<", "`", "(", ")"
          unsupported!("shell metacharacter '#{c}'", text)
        else
          if word.nil? && (c == "1" || c == "2") && text[i + 1] == ">"
            stream = c == "2" ? :stderr : :stdout
            if text[i + 2] == ">"
              tokens << [:redirect, stream, :append]
              i += 3
            else
              tokens << [:redirect, stream, :truncate]
              i += 2
            end
          else
            word = (word || +"") + c
            i += 1
          end
        end
      end
      tokens << [:word, word] if word
      tokens
    end

    # Scan a double-quoted segment starting at +i+ (text[i] == '"'). Applies
    # the backslash-removal rule that is special to double quotes (see
    # DQUOTE_BACKSLASH_SPECIAL) and returns [content, index_after_closing_quote].
    def scan_double_quoted(text, i)
      n = text.length
      j = i + 1
      buf = +""
      loop do
        unsupported!("unterminated quote", text) if j >= n

        c = text[j]
        if c == '"'
          j += 1
          break
        elsif c == "\\" && j + 1 < n && DQUOTE_BACKSLASH_SPECIAL.include?(text[j + 1])
          nxt = text[j + 1]
          buf << nxt unless nxt == "\n" # backslash-newline vanishes entirely
          j += 2
        else
          buf << c
          j += 1
        end
      end
      [buf, j]
    end

    # Turn +text+ into [[connector, SimpleCommand], ...]: the simple commands it
    # holds, each tagged with the connector that precedes it (:first for the
    # leading one, then :and/:or/:semi). A leading run of `VAR=value` words
    # becomes that command's environment; a redirect marker consumes the
    # following word as its target path.
    def parse(text)
      tokens = tokenize(text)
      commands = []
      connector = :first
      assignments = []
      argv = []
      redirections = []
      i = 0

      flush = lambda do
        unless assignments.empty? && argv.empty? && redirections.empty?
          commands << [connector, SimpleCommand.new(assignments, argv, redirections)]
        end
        assignments = []
        argv = []
        redirections = []
      end

      while i < tokens.length
        tok = tokens[i]
        case tok[0]
        when :word
          w = tok[1]
          if argv.empty? && w =~ /\A[A-Za-z_][A-Za-z0-9_]*=/
            assignments << w
          else
            argv << w
          end
        when :and, :or, :semi
          flush.call
          connector = tok[0]
        when :redirect
          nxt = tokens[i + 1]
          unsupported!("redirection without a target", text) if nxt.nil? || nxt[0] != :word
          redirections << Redirection.new(tok[1], tok[2], nxt[1])
          i += 1
        end
        i += 1
      end
      flush.call
      commands
    end

    # The argv array of +text+ read as one plain command — a program word and
    # its arguments, nothing else. Anything a shell would have to interpret
    # beyond word splitting and quote removal (a connector, a redirection, an
    # environment assignment, an empty command) raises UnsupportedSyntaxError
    # rather than being approximated. This is the mkmf shim's entry point: the
    # conftest commands mkmf builds are plain commands, and one that is not has
    # to be reported, not guessed at.
    def argv(text)
      commands = parse(text)
      unsupported!("empty command", text) if commands.empty?
      if commands.length > 1
        unsupported!("command connector '#{CONNECTOR_NAMES[commands[1][0]]}'", text)
      end

      command = commands.first[1]
      unsupported!("redirection", text) unless command.redirections.empty?
      unsupported!("environment assignment '#{command.assignments.first}'", text) \
        unless command.assignments.empty?

      command.argv
    end

    # The inverse of the splitter for one word: +word+ spelled so that #argv
    # (and a POSIX shell, and Shellwords, which is what RubyGems splits
    # `ENV["MAKE"]` with) reads it back as this exact single word. Needed because
    # a tool command has to be carried as *one string* — `CC = <ruby> <exe>` in a
    # Makefile, `ENV["MAKE"]` for RubyGems — and an installation path is allowed
    # to contain a space.
    #
    # A word of ordinary path characters is left alone, so the common case stays
    # readable; anything else is single-quoted (which protects every character
    # but a single quote), and a word containing a single quote is spelled with
    # the `'\''` idiom every one of those splitters understands.
    def quote(word)
      return word if word.match?(/\A[A-Za-z0-9_@%+=:,.\/-]+\z/)

      "'" + word.gsub("'", %q('"'"')) + "'"
    end

    def unsupported!(construct, text)
      raise UnsupportedSyntaxError.new(construct, text)
    end
  end
end
