# frozen_string_literal: true

require_relative "errors"

module Rubycc
  module Rmake
    # Turns raw make text with `$(...)` / `${...}` / `$x` references into its
    # expanded string. It implements exactly the reference forms the mkmf corpus
    # uses (test/fixtures/mkmf): plain variable references, nested references,
    # the `$(var:from=to)` substitution reference, and the automatic variables
    # ($@, $<, $^, $*, and their D/F directory/file variants). Undefined
    # variables expand to the empty string, matching make.
    #
    # Recursive (`=`) variables are stored unexpanded and expanded on every
    # reference; simple (`:=`) variables are stored already-expanded. That split
    # lives in the Variable value object, so the expander only has to re-expand
    # whatever text a recursive variable holds — which is where an `A=$(B)` /
    # `B=$(A)` cycle would otherwise recurse forever, so every variable
    # dereference spends one unit of the depth budget below.
    class Expander
      # DoS fail-safe: the maximum number of nested variable dereferences during
      # a single expansion. A reference cycle between recursive variables would
      # recurse without bound; this cap converts that into an ExpansionError long
      # before the Ruby stack is exhausted. Legitimate mkmf variable chains
      # (e.g. rubyarchhdrdir -> rubyhdrdir -> includedir -> prefix) are well
      # under a dozen deep, so the limit is generous.
      MAX_EXPANSION_DEPTH = 200

      # Base characters of the automatic variables rmake recognises. Each may be
      # written bare ($@) or parenthesised ($(@)), and the parenthesised form may
      # carry a D/F modifier ($(@D) = directory part, $(@F) = file part).
      AUTOMATIC_CHARS = %w[@ < ^ ? * + %].freeze

      # variables:: Hash{String => Variable}
      def initialize(variables)
        @variables = variables
      end

      # Expand +text+. +autos+ is a Hash{String => String} keyed by automatic
      # variable base character (e.g. {"@" => "foo.o", "<" => "foo.c"}); pass nil
      # outside a recipe, where automatic variables expand to "".
      def expand(text, autos = nil, depth = 0)
        guard_depth(depth)
        out = +""
        i = 0
        n = text.length
        while i < n
          c = text[i]
          if c == "$"
            consumed, value = expand_reference(text, i, autos, depth)
            out << value
            i += consumed
          else
            out << c
            i += 1
          end
        end
        out
      end

      private

      def guard_depth(depth)
        return if depth <= MAX_EXPANSION_DEPTH

        raise ExpansionError,
              "variable expansion exceeded #{MAX_EXPANSION_DEPTH} levels " \
              "(likely a reference cycle between recursive variables)"
      end

      # Parse one reference starting at the `$` at +i+. Returns [chars_consumed,
      # expanded_value].
      def expand_reference(text, i, autos, depth)
        nxt = text[i + 1]
        case nxt
        when nil
          # Trailing bare `$` — emit it literally.
          [1, "$"]
        when "$"
          [2, "$"]
        when "(", "{"
          close = (nxt == "(" ? ")" : "}")
          inner, len = read_balanced(text, i + 2, nxt, close)
          [2 + len, expand_parenthesised(inner, autos, depth)]
        else
          # Single-character reference: $@, $<, $x ...
          [2, resolve_name(nxt, autos, depth)]
        end
      end

      # Read up to the matching close bracket, honouring nesting so that
      # `$(a$(b))` is read whole. Returns [inner_without_brackets,
      # chars_consumed_including_close]. An unterminated reference is treated as
      # extending to end of text (make is similarly lenient).
      def read_balanced(text, start, open, close)
        depth = 1
        i = start
        n = text.length
        while i < n
          c = text[i]
          if c == open
            depth += 1
          elsif c == close
            depth -= 1
            return [text[start...i], (i - start) + 1] if depth.zero?
          end
          i += 1
        end
        [text[start..], n - start]
      end

      def expand_parenthesised(inner, autos, depth)
        # Substitution reference: $(var:from=to). Split on the first ':' and then
        # the remainder on the first '=' so a replacement text may itself contain
        # '=' or spaces (e.g. `$(ECHO1:0=@ echo)`).
        if (colon = inner.index(":")) && inner.index("=", colon)
          name = inner[0...colon]
          from, to = inner[(colon + 1)..].split("=", 2)
          value = resolve_name(expand(name, autos, depth + 1), autos, depth)
          return substitute_suffix(value, expand(from, autos, depth + 1), expand(to.to_s, autos, depth + 1))
        end

        name = expand(inner, autos, depth + 1)
        resolve_name(name, autos, depth)
      end

      # Resolve a fully-expanded variable/automatic name to its value.
      def resolve_name(name, autos, depth)
        auto = automatic_value(name, autos)
        return auto unless auto.nil?

        var = @variables[name]
        return "" if var.nil?

        var.simple? ? var.value : expand(var.value, autos, depth + 1)
      end

      # Returns the automatic-variable value for +name+, or nil when +name+ is
      # not an automatic variable. Outside a recipe (+autos+ nil) the automatic
      # variables are defined but empty, matching make.
      def automatic_value(name, autos)
        base = name
        modifier = nil
        if name.length == 2 && (name[1] == "D" || name[1] == "F") && AUTOMATIC_CHARS.include?(name[0])
          base = name[0]
          modifier = name[1]
        end
        return nil unless AUTOMATIC_CHARS.include?(base) && name.length <= 2

        raw = autos ? autos.fetch(base, "") : ""
        case modifier
        when "D" then directory_parts(raw)
        when "F" then file_parts(raw)
        else raw
        end
      end

      # make's $(var:from=to) replaces +from+ at the end of each whitespace-
      # separated word with +to+ (equivalent to $(patsubst %from,%to,var)).
      def substitute_suffix(value, from, to)
        value.split(/\s+/).reject(&:empty?).map do |word|
          word.end_with?(from) ? word[0, word.length - from.length] + to : word
        end.join(" ")
      end

      # $(@D): directory part of each word, "." when a word has no directory,
      # trailing slash stripped.
      def directory_parts(value)
        value.split(/\s+/).reject(&:empty?).map do |word|
          slash = word.rindex("/")
          slash.nil? ? "." : (slash.zero? ? "/" : word[0...slash])
        end.join(" ")
      end

      # $(@F): file (basename) part of each word.
      def file_parts(value)
        value.split(/\s+/).reject(&:empty?).map do |word|
          slash = word.rindex("/")
          slash.nil? ? word : word[(slash + 1)..]
        end.join(" ")
      end
    end
  end
end
