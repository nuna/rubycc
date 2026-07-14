# frozen_string_literal: true

require_relative "scanner"
require_relative "token_converter"
require_relative "constant_expression"
require_relative "../front/constant_evaluator"
require_relative "../compile_error"

module Rubycc
  module Preprocess
    # Entry point for translation phases 1-4: source text in, a Front::Token
    # stream out. It scans preprocessing tokens (line splicing and comment
    # removal), executes directives, expands macros, and converts what remains
    # into ordinary tokens.
    #
    # The macro table and the #include search path are instance state so an
    # includee shares them with its includer: a translation unit is preprocessed
    # as a single accumulating pass, with #include recursion feeding an includee's
    # tokens through the same line-oriented loop. Conditional groups (#if and its
    # kin) select which lines reach that loop. Both object-like and function-like
    # macros are expanded (6.10.3), the latter gathering their arguments across
    # line boundaries; the "#" (stringize) and "##" (paste) operators, the
    # compiler-supplied macros (__FILE__ and kin), the __has_* queries and
    # "#pragma once" complete the model.
    class Preprocessor
      # A guard against unbounded #include recursion (a header that includes
      # itself); 200 is comfortably deeper than any sane header nesting.
      INCLUDE_DEPTH_LIMIT = 200

      # The cumulative ceiling on how many tokens macro expansion may process
      # across a whole translation unit. Blue-painting (see #expand_tokens) stops
      # self-reference and mutual recursion, but nothing otherwise bounds an
      # exponentially expanding macro — the classic "#define B1 B0 B0 ... #define
      # B40 B39 B39" doubles its output each level, so "B40" would materialize
      # 2^40 tokens and exhaust CPU and memory long before finishing. Charging one
      # unit per token pulled from the work queue and tripping this ceiling turns
      # that runaway into a located CompileError. The bound is a whole-run
      # cumulative budget (expand_tokens runs once per gathered line and once per
      # #if condition, and recurses for each argument), so an expansion that
      # explodes across many small calls is still caught. The real #include
      # <ruby.h> header graph — the whole CRuby + libc header set, a worst-case
      # legitimate input — consumes about 137k, so one million leaves a 7x margin
      # while it never fires on real code. It is deliberately not larger: because
      # a doubling macro is rejected only after the full budget is processed, the
      # ceiling also caps the worst-case work a hostile input can force (about
      # three seconds here), so raising it would trade rejection latency for
      # headroom no real translation unit needs.
      EXPANSION_TOKEN_LIMIT = 1_000_000

      # The ceiling on conditional-directive nesting within a single file. A
      # deeply nested tower of "#if"s is not a stack risk (the frames are held in
      # a heap array, not on the Ruby stack), but capping it keeps a hostile
      # source from building an arbitrarily large conditional stack; 256 is far
      # beyond any real header's conditional nesting.
      CONDITIONAL_NESTING_LIMIT = 256

      # The ceiling on parenthesis nesting inside a function-like macro's argument
      # list. #collect_arguments balances parentheses with a plain integer depth
      # counter (no recursion, so this is not a stack guard), but bounding it
      # rejects a pathological "M(((((...)))))" up front rather than scanning an
      # unbounded run. It is generous — a macro argument is a full expression, and
      # the parser re-checks nesting downstream — so this only trips on clearly
      # abusive input.
      MACRO_ARGUMENT_NESTING_LIMIT = 2000

      # The directives that steer a conditional group (6.10.1). They are acted on
      # whether or not the enclosing group is active, so nesting stays balanced
      # inside a skipped region; every other directive is inert while skipping.
      CONDITIONAL_DIRECTIVES = %w[if ifdef ifndef elif else endif].freeze

      # One nesting level of a conditional. `active` is whether this frame's
      # current group is being emitted (its condition held and the frame itself
      # is reachable); `taken` records whether any group of this #if has been
      # selected yet, so a later #elif/#else knows to stay inert; `seen_else`
      # guards against an #elif/#else after the #else; `parent_active` is whether
      # the enclosing context was active when the #if opened, which freezes the
      # whole conditional off when it was not. `token` is the opening directive,
      # for an "unterminated conditional" diagnosed at end of file.
      Frame = Struct.new(:active, :taken, :seen_else, :parent_active, :token)

      # One entry of the macro table. `kind` is :object or :function; `params`
      # is the ordered parameter-name list (empty for an object macro, and for a
      # function macro it excludes the trailing "..."); `variadic` records that
      # trailing "..." so __VA_ARGS__ is meaningful; `replacement` is the raw
      # replacement-list tokens as written.
      Macro = Struct.new(:kind, :params, :variadic, :replacement)

      # One function-like invocation's arguments. `raw` is each argument's
      # unexpanded tokens (what "#" and "##" operate on), `commas` the top-level
      # comma tokens between them (kept verbatim so #__VA_ARGS__ can reproduce the
      # exact spacing), and `expanded` a per-argument memo of the fully expanded
      # form, filled lazily so an argument used only by "#"/"##" is never expanded.
      Invocation = Struct.new(:raw, :commas, :expanded)

      # The macros the preprocessor supplies itself (6.10.8): each is expanded
      # from the use site, so its value cannot be a fixed replacement list stored
      # at definition time. __GNUC__ is deliberately absent (DESIGN R7), so a
      # header cannot select a gcc-specific path. None may be redefined or undefined.
      BUILTIN_MACROS = %w[__FILE__ __LINE__ __STDC__ __STDC_VERSION__ __RUBYCC__].freeze

      # The identifiers __has_builtin (6.10.1) answers true for: the varargs
      # intrinsics, the branch-prediction hint (__builtin_expect) and the stack
      # allocator (__builtin_alloca) this compiler recognizes. Every other
      # builtin query is false.
      KNOWN_BUILTINS = %w[__builtin_va_start __builtin_va_arg __builtin_va_end
                          __builtin_expect __builtin_alloca].freeze

      # The target-identifying macros gcc keeps predefined even under strict ISO
      # C (-std=c11): only the reserved forms (a leading underscore followed by
      # another underscore or an uppercase letter, 7.1.3), so headers relying on
      # "linux", "unix" or "i386" (the non-reserved spellings, gcc drops these
      # under -std=c11) still see them undefined here. __GNUC__ is deliberately
      # excluded (DESIGN R7): rubycc is x86-64 Linux/ELF only, so this fixed set
      # is enough for glibc's own architecture dispatch (e.g. gnu/stubs.h) to
      # settle on the right branch, without claiming gcc compatibility beyond
      # that. Unlike BUILTIN_MACROS these are ordinary #define'd entries in
      # @macros, so a translation unit may #undef or redefine them (gcc allows
      # this too).
      PREDEFINED_TARGET_MACROS = %w[__x86_64__ __amd64__ __linux__ __gnu_linux__
                                    __unix__ __ELF__ __LP64__ _LP64 __STDC_HOSTED__].freeze

      # The numeric limit/size macros gcc predefines describing the target's
      # fundamental types. glibc's headers reach for these directly when __GNUC__
      # is absent (e.g. limits.h's __LONG_MAX__ via ruby's special_consts.h), so
      # they must carry gcc's exact spellings — value base (hex vs decimal) and
      # integer suffix — for a gcc-differential #if to agree. The right-hand sides
      # are the verbatim replacement texts of `gcc -dM -E </dev/null` on this
      # x86-64 LP64 target; they become ordinary object macros (a translation unit
      # may #undef or redefine them). __WCHAR_MIN__'s value is a parenthesized
      # expression referring to another of these, which expands recursively at the
      # use site like any macro. Only the reserved "__X__" forms are provided;
      # __GNUC__ and version macros stay absent (DESIGN R7). The replacement text
      # is re-scanned into pp-tokens rather than hand-built, so multi-token values
      # need no special casing.
      PREDEFINED_NUMERIC_MACROS = {
        "__CHAR_BIT__" => "8",
        "__SCHAR_MAX__" => "0x7f",
        "__SHRT_MAX__" => "0x7fff",
        "__INT_MAX__" => "0x7fffffff",
        "__LONG_MAX__" => "0x7fffffffffffffffL",
        "__LONG_LONG_MAX__" => "0x7fffffffffffffffLL",
        "__WCHAR_MAX__" => "0x7fffffff",
        "__WCHAR_MIN__" => "(-__WCHAR_MAX__ - 1)",
        "__WINT_MAX__" => "0xffffffffU",
        "__WINT_MIN__" => "0U",
        "__PTRDIFF_MAX__" => "0x7fffffffffffffffL",
        "__SIZE_MAX__" => "0xffffffffffffffffUL",
        "__INTMAX_MAX__" => "0x7fffffffffffffffL",
        "__UINTMAX_MAX__" => "0xffffffffffffffffUL",
        "__INTPTR_MAX__" => "0x7fffffffffffffffL",
        "__UINTPTR_MAX__" => "0xffffffffffffffffUL",
        "__SIZEOF_INT__" => "4",
        "__SIZEOF_LONG__" => "8",
        "__SIZEOF_LONG_LONG__" => "8",
        "__SIZEOF_SHORT__" => "2",
        "__SIZEOF_POINTER__" => "8",
        "__SIZEOF_SIZE_T__" => "8",
        "__SIZEOF_PTRDIFF_T__" => "8",
        "__SIZEOF_FLOAT__" => "4",
        "__SIZEOF_DOUBLE__" => "8",
        "__SIZEOF_WCHAR_T__" => "4",
        "__SIZEOF_WINT_T__" => "4"
      }.freeze

      def initialize
        # name (String) => Macro.
        @macros = {}
        PREDEFINED_TARGET_MACROS.each { |name| @macros[name] = predefined_target_macro }
        PREDEFINED_NUMERIC_MACROS.each { |name, text| @macros[name] = predefined_numeric_macro(text) }
        @include_depth = 0
        # Absolute paths of files that asked (via "#pragma once") to be read at
        # most once; a later #include resolving to one of them is skipped.
        @pragma_once = {}
        # Absolute path => index into @include_paths of the -I directory a file
        # was found in. Only files resolved along the search path get an entry
        # (the main source file and a quote-relative resolution beside its
        # includer never do), which is exactly what #include_next needs to tell
        # "resume the search past here" from "there is no here" (GNU extension).
        @include_origin = {}
      end

      def run(source, filename:, include_paths: [])
        @include_paths = include_paths
        # The whole-run macro-expansion budget (see EXPANSION_TOKEN_LIMIT), reset
        # here so every translation unit starts with a full allowance.
        @expansion_tokens = 0
        pp_tokens = Scanner.new(source, filename: filename).scan
        output = []
        process_lines(pp_tokens, filename, output)
        # process_lines stops at the unit's end-of-file marker without emitting
        # it; carry it through so the converter can terminate its stream.
        output << pp_tokens.last
        TokenConverter.new.convert(output)
      end

      private

      # Walks one file's preprocessing tokens a logical line at a time. A line
      # whose first token is "#" is a directive (6.10); every other line has its
      # tokens macro-expanded into `output`, but only while every enclosing
      # conditional is active. `stack` is this file's conditional nesting; a
      # frame it opens must be closed in the same file (a #include appears only on
      # an active line and runs with its own fresh stack), so any frame still open
      # at end of file is an unterminated conditional.
      #
      # A function-like macro invocation may span several physical lines, so the
      # tokens of a run of consecutive active non-directive lines (newlines and
      # all) are gathered and expanded together. A directive line, an inactive
      # region, or end of file ends the run: activeness only ever changes at a
      # directive, so a run is uniformly active, and a call left open where a run
      # ends is diagnosed there (a directive splitting an argument list is 6.10.3
      # undefined behavior). Newlines are dropped by the expander, so the output
      # stream stays free of them.
      def process_lines(tokens, filename, output)
        stack = []
        index = 0
        at_line_start = true
        run = []
        while index < tokens.length
          tok = tokens[index]
          break if tok.eof?

          if tok.newline?
            run << tok if active?(stack)
            at_line_start = true
            index += 1
          elsif at_line_start && tok.punct?("#")
            expand_run(run, output)
            run = []
            index = process_directive(tokens, index, filename, output, stack)
            at_line_start = true
          else
            at_line_start = false
            run << tok if active?(stack)
            index += 1
          end
        end
        expand_run(run, output)
        raise_at(stack.last.token, "unterminated conditional directive") unless stack.empty?
      end

      def expand_run(run, output)
        expand_tokens(run, output) unless run.empty?
      end

      # Whether output is currently being emitted: true unless some enclosing
      # conditional selected against it. A frame's `active` already folds in its
      # parents' state, so only the innermost need be consulted.
      def active?(stack)
        stack.empty? || stack.last.active
      end

      # Dispatches the directive that "#" at `hash_index` introduces and returns
      # the index of the first token past its terminating newline. A conditional
      # directive is always acted on (it may re-activate a skipped region or nest
      # inside it); every other directive, and even a malformed one, is silently
      # dropped while skipping, matching how gcc discards an excluded group whole.
      # An empty directive line (just "#") is the null directive (6.10p2).
      def process_directive(tokens, hash_index, filename, output, stack)
        hash = tokens[hash_index]
        args, next_index = collect_line(tokens, hash_index + 1)
        return next_index if args.empty?

        name = args[0]
        body = args[1..]
        if name.type == :identifier && CONDITIONAL_DIRECTIVES.include?(name.text)
          dispatch_conditional(name, body, stack)
          return next_index
        end
        return next_index unless active?(stack)

        unless name.type == :identifier
          raise_at(name, "invalid preprocessing directive '##{name.text}'")
        end

        case name.text
        when "include"      then handle_include(hash, body, output, filename)
        when "include_next" then handle_include_next(hash, body, output, filename)
        when "define"       then handle_define(name, body)
        when "undef"        then handle_undef(name, body)
        when "error"        then handle_error(hash, body)
        when "pragma"       then handle_pragma(body, filename)
        else
          raise_at(name, "invalid preprocessing directive '##{name.text}'")
        end
        next_index
      end

      # --- conditional inclusion (6.10.1) ----------------------------------------

      def dispatch_conditional(name, body, stack)
        case name.text
        when "if"     then handle_if(name, body, stack, :if)
        when "ifdef"  then handle_if(name, body, stack, :ifdef)
        when "ifndef" then handle_if(name, body, stack, :ifndef)
        when "elif"   then handle_elif(name, body, stack)
        when "else"   then handle_else(name, stack)
        when "endif"  then handle_endif(name, stack)
        end
      end

      # Opens a new conditional frame. Its first group's condition is only
      # evaluated when the enclosing context is active; inside a skipped region
      # the frame is pushed inert (never taken, so no #elif/#else can revive it)
      # and the condition is left unread, so an undefined name or bad expression
      # there is not diagnosed (6.10.1p6, and matching gcc).
      def handle_if(name, body, stack, kind)
        if stack.length >= CONDITIONAL_NESTING_LIMIT
          raise_at(name, "#{name.text} directives nested too deeply")
        end

        if active?(stack)
          condition = evaluate_group(name, body, kind)
          stack.push(Frame.new(condition, condition, false, true, name))
        else
          stack.push(Frame.new(false, true, false, false, name))
        end
      end

      def evaluate_group(name, body, kind)
        case kind
        when :if     then evaluate_if_expression(name, body)
        when :ifdef  then defined_condition(name, body, true)
        when :ifndef then defined_condition(name, body, false)
        end
      end

      def handle_elif(name, body, stack)
        raise_at(name, "#elif without #if") if stack.empty?

        frame = stack.last
        raise_at(name, "#elif after #else") if frame.seen_else
        # Only evaluate when the enclosing context is active and no earlier group
        # of this #if was taken; otherwise this branch cannot win, so its
        # expression is left unevaluated (and undiagnosed).
        if frame.parent_active && !frame.taken
          condition = evaluate_if_expression(name, body)
          frame.active = condition
          frame.taken = true if condition
        else
          frame.active = false
        end
      end

      def handle_else(name, stack)
        raise_at(name, "#else without #if") if stack.empty?

        frame = stack.last
        raise_at(name, "#else after #else") if frame.seen_else
        frame.seen_else = true
        # The else group is taken exactly when the context is active and nothing
        # earlier was; either way no further group of this #if can be selected.
        frame.active = frame.parent_active && !frame.taken
        frame.taken = true
      end

      def handle_endif(name, stack)
        raise_at(name, "#endif without #if") if stack.empty?

        stack.pop
      end

      # #ifdef/#ifndef NAME: NAME must be a lone identifier, and the frame is
      # active when the macro's presence in the table matches the sense wanted.
      def defined_condition(name, body, want_defined)
        raise_at(name, "no macro name given in ##{name.text} directive") if body.empty?

        macro = body[0]
        raise_at(macro, "macro names must be identifiers") unless macro.type == :identifier
        raise_at(body[1], "extra tokens at end of ##{name.text} directive") if body.length > 1
        @macros.key?(macro.text) == want_defined
      end

      # Evaluates a #if/#elif controlling constant-expression (6.10.1) to a
      # boolean. In order: fold each preprocessor operator (`defined` and the
      # `__has_*` queries) to 1/0 with its operand unexpanded, macro-expand what
      # remains, fold operators a second time (a header may hide a __has_* query
      # behind a macro, e.g. RBIMPL_HAS_BUILTIN(x) -> __has_builtin(x), so the
      # operator only surfaces after expansion; gcc likewise re-honors a
      # macro-produced `defined`), then replace every surviving identifier with 0,
      # convert to ordinary tokens, and evaluate the parsed expression with the
      # shared constant evaluator. A non-zero result is true. One post-expansion
      # pass suffices: fold_operators never expands its own operands, so a query
      # it uncovers cannot itself reveal another.
      def evaluate_if_expression(directive, body)
        raise_at(directive, "##{directive.text} with no expression") if body.empty?

        expanded = []
        expand_tokens(fold_operators(body), expanded)
        refolded = fold_operators(expanded)
        neutral = refolded.map { |tok| tok.type == :identifier ? number_zero(tok) : tok }
        tokens = to_front_tokens(neutral, directive)
        node = ConstantExpressionParser.new(tokens, directive.text).parse
        evaluate_constant(node)
      end

      # Converts the neutralized expression tokens to the Front::Token stream the
      # expression parser consumes, terminating it with an :eof. A floating
      # constant is not an integer constant-expression, so it is rejected here
      # (6.10.1p1) before it can reach the evaluator.
      def to_front_tokens(pp_tokens, directive)
        tokens = TokenConverter.new.convert(pp_tokens)
        floating = tokens.find { |tok| tok.type == :float }
        raise_at_front(floating, "floating constant in preprocessor expression") if floating
        tokens << Front::Token.new(type: :eof, value: nil, filename: directive.filename,
                                   line: directive.line, column: directive.column,
                                   source_line: directive.source_line)
        tokens
      end

      def evaluate_constant(node)
        Front::ConstantEvaluator.evaluate(node) != 0
      rescue Front::ConstantEvaluator::DivisionByZero => e
        raise_at_front(e.token, "division by zero in preprocessor expression")
      rescue Front::ConstantEvaluator::NotConstant => e
        raise_at_front(e.token, "token is not valid in preprocessor expressions")
      end

      # Rewrites each preprocessor operator in a #if expression to the pp-number 1
      # or 0, its operand left unexpanded (6.10.1p1, p4): `defined` against the
      # macro table, `__has_include` against the include search, `__has_attribute`
      # true only for the layout attributes rubycc honors (aligned/packed), and
      # `__has_builtin`
      # true only for the varargs intrinsics. Any other token passes through to be
      # macro-expanded (an unrecognized identifier later neutralizes to 0).
      def fold_operators(body)
        result = []
        index = 0
        while index < body.length
          tok = body[index]
          if tok.type == :identifier && (handler = PP_OPERATORS[tok.text])
            value, index = send(handler, tok, body, index + 1)
            result << number_flag(tok, value)
          else
            result << tok
            index += 1
          end
        end
        result
      end

      # Each #if operator's fold method, keyed by its spelling.
      PP_OPERATORS = {
        "defined" => :fold_defined, "__has_include" => :fold_has_include,
        "__has_attribute" => :fold_has_attribute, "__has_builtin" => :fold_has_builtin
      }.freeze

      def fold_defined(operator, body, index)
        name, index = read_defined_operand(operator, body, index)
        [@macros.key?(name) || query_operator_name?(name), index]
      end

      # gcc treats the __has_* query operators as satisfying `defined`, so
      # `#if defined(__has_builtin)` is 1 there; a header uses that to prefer
      # the operator over a config.h fallback (ruby/internal/has/builtin.h).
      # The `defined` operator itself is not answered here (only the __has_*
      # queries), so this excludes it from PP_OPERATORS.
      def query_operator_name?(name)
        PP_OPERATORS.key?(name) && name != "defined"
      end

      # __has_include ( "f" | <f> ): true when the header resolves like the same
      # #include would (quote relative to this file, then the search path).
      def fold_has_include(operator, body, index)
        raise_at(operator, "missing '(' after '__has_include'") unless body[index]&.punct?("(")

        close = closing_paren(operator, body, index)
        kind, name = parse_header_name(operator, body[(index + 1)...close])
        [include_exists?(kind, name, operator.filename), close + 1]
      end

      # The GNU attributes rubycc gives real semantics (Step 28): the layout
      # attributes the parser honors on a struct/union. Every other attribute is
      # accepted and discarded, so __has_attribute answers true only for these.
      KNOWN_ATTRIBUTES = %w[aligned packed].freeze

      # __has_attribute ( X ): true for the attributes rubycc actually acts on
      # (aligned and packed, in either the plain or the "__name__" spelling),
      # false for every other name. The name is normalized the same way the
      # parser normalizes an attribute token.
      def fold_has_attribute(operator, body, index)
        name, index = read_paren_identifier(operator, body, index, "__has_attribute")
        [KNOWN_ATTRIBUTES.include?(normalize_attribute_name(name)), index]
      end

      # Collapses a "__name__" attribute spelling to "name" (a single leading and
      # trailing "__" pair stripped when both are present), matching the parser's
      # #normalize_attribute_name so "__aligned__" and "aligned" agree here too.
      def normalize_attribute_name(name)
        if name.start_with?("__") && name.end_with?("__") && name.length > 4
          name[2..-3]
        else
          name
        end
      end

      def fold_has_builtin(operator, body, index)
        name, index = read_paren_identifier(operator, body, index, "__has_builtin")
        [KNOWN_BUILTINS.include?(name), index]
      end

      # The index of the ")" that closes the "(" at `index`; the operand between
      # them is a header name, which has no nested parentheses.
      def closing_paren(operator, body, index)
        close = index + 1
        close += 1 until body[close].nil? || body[close].punct?(")")
        raise_at(operator, "missing ')' after '#{operator.text}'") if body[close].nil?
        close
      end

      # Reads a "( identifier )" operand for the __has_* attribute/builtin queries,
      # returning [identifier-text, index-past-")"].
      def read_paren_identifier(operator, body, index, what)
        name = body[index + 1]
        unless body[index]&.punct?("(") && name&.type == :identifier && body[index + 2]&.punct?(")")
          raise_at(operator, "operator '#{what}' requires a parenthesized identifier")
        end
        [name.text, index + 3]
      end

      # Whether a header name resolves without reading it: quote form beside the
      # querying file then along the search path, angled form only the latter.
      def include_exists?(kind, name, includer)
        directories = []
        directories << File.dirname(includer) if kind == :quote
        directories.concat(@include_paths)
        directories.any? { |dir| File.file?(File.join(dir, name)) }
      end

      # Reads the operand of a `defined` operator starting at `index`, returning
      # [macro-name, index-past-operand]. Accepts NAME or ( NAME ).
      def read_defined_operand(directive, body, index)
        if body[index]&.punct?("(")
          name = body[index + 1]
          unless name && name.type == :identifier && body[index + 2]&.punct?(")")
            raise_at(directive, "operator 'defined' requires an identifier")
          end
          [name.text, index + 3]
        else
          name = body[index]
          raise_at(directive, "operator 'defined' requires an identifier") unless name&.type == :identifier

          [name.text, index + 1]
        end
      end

      def number_flag(site, present)
        number_token(site, present ? "1" : "0")
      end

      def number_zero(site)
        number_token(site, "0")
      end

      def number_token(site, text)
        PPToken.new(
          type: :pp_number, text: text,
          filename: site.filename, line: site.line, column: site.column,
          source_line: site.source_line, space_before: site.space_before
        )
      end

      # A PREDEFINED_TARGET_MACROS entry: an ordinary object macro whose sole
      # replacement token is the pp-number "1". Its position ("<built-in>", line
      # 0) is a placeholder that no diagnostic ever surfaces: #substitute always
      # relocates a replacement token to the invocation site via #relocate
      # before it can reach the token stream, so this position only ever exists
      # transiently inside the macro table.
      def predefined_target_macro
        token = PPToken.new(
          type: :pp_number, text: "1",
          filename: "<built-in>", line: 0, column: 0, source_line: ""
        )
        Macro.new(:object, [], false, [token])
      end

      # A PREDEFINED_NUMERIC_MACROS entry: an ordinary object macro whose
      # replacement is `text` re-scanned into pp-tokens, so a multi-token value
      # (like __WCHAR_MIN__'s parenthesized expression) becomes a proper token
      # list without hand-building each token. The scanner appends an :eof (and
      # never a newline for a single line), dropped here. As with the target
      # macros the tokens carry a placeholder "<built-in>" location that #relocate
      # replaces with the use site before any diagnostic could reference it.
      def predefined_numeric_macro(text)
        tokens = Scanner.new(text, filename: "<built-in>").scan.reject(&:eof?)
        Macro.new(:object, [], false, tokens)
      end

      # The tokens of the logical line starting at `start` (up to but excluding
      # the newline), paired with the index just past that newline. A line ended
      # by end-of-file yields the eof index so the caller's loop can stop there.
      def collect_line(tokens, start)
        stop = start
        stop += 1 until tokens[stop].newline? || tokens[stop].eof?
        rest = tokens[start...stop]
        next_index = tokens[stop].newline? ? stop + 1 : stop
        [rest, next_index]
      end

      # --- #include ----------------------------------------------------------

      def handle_include(hash, body, output, includer)
        kind, name = parse_header_name(hash, body)
        path = resolve_include(kind, name, includer, hash)
        process_include(hash, name, path, output)
      end

      # #include_next NAME (GNU extension): like #include, but the search for
      # NAME resumes just past the -I directory `includer` itself was found in,
      # rather than starting over from the front of the list. It exists so a
      # header can shadow a same-named one further down the search path while
      # still #including that later copy (gcc's fixinclude wrappers use it on
      # limits.h and syslimits.h). Both "NAME" and <NAME> are accepted, but
      # unlike a plain #include the quote form does not additionally search
      # `includer`'s own directory (gcc's behavior).
      def handle_include_next(hash, body, output, includer)
        kind, name = parse_header_name(hash, body)
        path = resolve_include_next(kind, name, includer, hash)
        process_include(hash, name, path, output)
      end

      # Reads and processes the header resolved to `path`, shared by #include
      # and #include_next once each has found its file.
      def process_include(hash, name, path, output)
        # A header that asked for "#pragma once" is read at most once per unit; a
        # later #include resolving to the same file is silently skipped (6.10.6).
        return if @pragma_once.key?(File.expand_path(path))

        raise_at(hash, "#include nested too deeply") if @include_depth >= INCLUDE_DEPTH_LIMIT

        @include_depth += 1
        begin
          source = read_source(path, name, hash)
          # The includee's tokens carry its own filename and line numbers (N3), so
          # a diagnostic raised inside it points at the header, not the includer.
          tokens = Scanner.new(source, filename: path).scan
          process_lines(tokens, path, output)
        ensure
          @include_depth -= 1
        end
      end

      # Reconstructs the header name from the raw tokens of an #include line. The
      # scanner does not treat header-names specially, so a quoted form arrives as
      # one :string token and an angled form as "<" ... ">"; the characters are
      # taken verbatim (6.10.2), never macro-expanded.
      def parse_header_name(hash, body)
        raise_at(hash, "#include expects \"FILENAME\" or <FILENAME>") if body.empty?

        first = body[0]
        if first.type == :string
          raise_at(body[1], "extra tokens at end of #include directive") if body.length > 1
          [:quote, first.text[1..-2]]
        elsif first.punct?("<")
          close = body.index { |t| t.punct?(">") }
          raise_at(first, "missing terminating > character") if close.nil?
          if close < body.length - 1
            raise_at(body[close + 1], "extra tokens at end of #include directive")
          end
          name = body[1...close].map(&:text).join
          raise_at(first, "empty filename in #include directive") if name.empty?
          [:angle, name]
        else
          raise_at(first, "#include expects \"FILENAME\" or <FILENAME>")
        end
      end

      # Resolves a header name to a filesystem path. A quoted include is looked
      # for first beside the file that names it, then along the search path; an
      # angled include only along the search path (6.10.2p2-3). A match found
      # along the search path records which directory it came from, so a later
      # #include_next from this same file knows where to resume.
      def resolve_include(kind, name, includer, hash)
        if kind == :quote
          beside = File.join(File.dirname(includer), name)
          return beside if File.file?(beside)
        end

        index, path = search_include_paths(name, 0)
        raise_at(hash, "#{name}: No such file or directory") unless path

        record_include_origin(path, index)
        path
      end

      # Resolves a header name for #include_next: search resumes one directory
      # past wherever `includer` itself was found along the search path. A file
      # with no recorded origin (the main source file, or a quote-relative
      # resolution beside its includer) has no "here" to resume past, so gcc
      # falls back to plain #include semantics for it, which this does too.
      def resolve_include_next(kind, name, includer, hash)
        origin = @include_origin[File.expand_path(includer)]
        return resolve_include(kind, name, includer, hash) unless origin

        index, path = search_include_paths(name, origin + 1)
        raise_at(hash, "#{name}: No such file or directory") unless path

        record_include_origin(path, index)
        path
      end

      # The first directory in @include_paths, starting the scan at `start`,
      # holding `name`; returns [its index, the joined path] or [nil, nil].
      def search_include_paths(name, start)
        @include_paths.each_with_index do |dir, index|
          next if index < start

          candidate = File.join(dir, name)
          return [index, candidate] if File.file?(candidate)
        end
        [nil, nil]
      end

      def record_include_origin(path, index)
        @include_origin[File.expand_path(path)] = index
      end

      def read_source(path, name, hash)
        File.read(path)
      rescue SystemCallError
        raise_at(hash, "#{name}: No such file or directory")
      end

      # --- #define / #undef ------------------------------------------------------

      def handle_define(directive, body)
        raise_at(directive, "no macro name given in #define directive") if body.empty?

        name = body[0]
        raise_at(name, "macro names must be identifiers") unless name.type == :identifier
        reject_reserved_name(name, "define")

        rest = body[1..]
        first = rest[0]
        # A "(" abutting the name with no separating space opens a parameter list
        # (function-like); a space before it, or its absence, makes an object
        # macro whose replacement merely begins with that token.
        macro =
          if first && first.punct?("(") && !first.space_before
            parse_function_macro(name, rest)
          else
            Macro.new(:object, [], false, rest)
          end
        validate_replacement(macro)

        existing = @macros[name.text]
        if existing.nil?
          @macros[name.text] = macro
        elsif !identical_macro?(existing, macro)
          # A benign redefinition (an identical definition) is allowed; a
          # differing one is an error (6.10.3p2, simplified to token spellings).
          raise_at(name, "macro '#{name.text}' redefined")
        end
      end

      # Parses a function-like macro's parameter list, `rest` being the tokens
      # after the macro name with rest[0] the opening "(". Returns the Macro,
      # its `replacement` the tokens past the closing ")". The list is a comma-
      # separated run of identifiers, optionally empty, optionally ending in a
      # "..." that marks the macro variadic (and "(...)" alone is allowed).
      def parse_function_macro(name, rest)
        params = []
        variadic = false
        index = 1
        unless rest[index]&.punct?(")")
          loop do
            token = rest[index]
            if token&.punct?("...")
              variadic = true
              index += 1
              break
            elsif token&.type == :identifier
              raise_at(token, "duplicate macro parameter \"#{token.text}\"") if params.include?(token.text)

              params << token.text
              index += 1
            else
              raise_at(token || name, "expected parameter name in macro parameter list")
            end

            separator = rest[index]
            if separator&.punct?(",")
              index += 1
            elsif separator&.punct?(")")
              break
            else
              raise_at(separator || name, "expected ',' or ')' in macro parameter list")
            end
          end
          raise_at(rest[index] || name, "missing ')' in macro parameter list") unless rest[index]&.punct?(")")
        end
        Macro.new(:function, params, variadic, rest[(index + 1)..] || [])
      end

      # Checks a replacement list for well-formed "#" and "##" placement at
      # definition time (6.10.3.2p1, 6.10.3.3p1). "##" may not sit at either end
      # of any replacement list; in a function-like macro "#" must be followed by
      # a parameter (or __VA_ARGS__), the only operands it can stringize. In an
      # object-like macro "#" is an ordinary token, so it is left unexamined.
      def validate_replacement(macro)
        rep = macro.replacement
        edge = rep.first if rep.first&.punct?("##")
        edge ||= rep.last if rep.last&.punct?("##")
        raise_at(edge, "'##' cannot appear at either end of a macro expansion") if edge

        return unless macro.kind == :function

        rep.each_with_index do |tok, index|
          next unless tok.punct?("#")

          operand = rep[index + 1]
          raise_at(tok, "'#' is not followed by a macro parameter") unless parameter_ref?(macro, operand)
        end
      end

      # Whether `tok` names one of `macro`'s parameters, counting __VA_ARGS__ as a
      # parameter for a variadic macro; the two spellings "#" and "##" may take.
      def parameter_ref?(macro, tok)
        return false unless tok&.type == :identifier

        macro.params.include?(tok.text) || (macro.variadic && tok.text == "__VA_ARGS__")
      end

      # A macro name may not shadow a builtin (6.10.8.4) nor be the "defined"
      # operator (6.10.1p4); both diagnose rather than silently redefine.
      def reject_reserved_name(name, verb)
        if name.text == "defined"
          raise_at(name, "\"defined\" cannot be used as a macro name")
        elsif BUILTIN_MACROS.include?(name.text)
          verb = verb == "define" ? "define" : "undefine"
          raise_at(name, "cannot #{verb} builtin macro \"#{name.text}\"")
        end
      end

      def handle_undef(directive, body)
        raise_at(directive, "no macro name given in #undef directive") if body.empty?

        name = body[0]
        raise_at(name, "macro names must be identifiers") unless name.type == :identifier
        reject_reserved_name(name, "undef")
        raise_at(body[1], "extra tokens at end of #undef directive") if body.length > 1
        # Undefining a name that was never a macro is not an error (6.10.3.5p2).
        @macros.delete(name.text)
      end

      # Two definitions are the same when their kind, parameter names, variadic
      # flag and replacement-list spellings all agree (6.10.3p1-2).
      def identical_macro?(one, other)
        one.kind == other.kind && one.variadic == other.variadic &&
          one.params == other.params && identical_replacement?(one.replacement, other.replacement)
      end

      def identical_replacement?(one, other)
        return false unless one.length == other.length

        one.zip(other).all? { |a, b| a.type == b.type && a.text == b.text }
      end

      # --- #error ----------------------------------------------------------------

      def handle_error(hash, body)
        # The message is the directive's tokens spelled out and single-spaced; it
        # is never macro-expanded (matching gcc).
        message = body.map(&:text).join(" ")
        raise_at(hash, message.empty? ? "#error" : message)
      end

      # --- #pragma ---------------------------------------------------------------

      # Acts on a "#pragma" (6.10.6). "#pragma once" records the current file so a
      # future #include of it is skipped; every other pragma (including a bare
      # one) is accepted and discarded. The "_Pragma" operator form (6.10.9) is
      # handled during rescanning; see #consume_pragma_operator.
      def handle_pragma(body, filename)
        first = body[0]
        return unless first&.type == :identifier && first.text == "once"

        @pragma_once[File.expand_path(filename)] = true
      end

      # --- macro expansion -------------------------------------------------------

      # Expands `tokens` into `output` by rescanning (6.10.3.4). The tokens are
      # driven through a work queue: the head is examined and, when it names a
      # macro it is not painted against, replaced in place by its (rescannable)
      # substitution, which is pushed back on the front so the next turn sees it.
      # Anything that is not an active macro name is emitted; newlines are the
      # inter-line glue of a gathered run and never reach the output.
      #
      # Painting is per token: an object macro, and every literal token of a
      # function macro's replacement, is painted with the macro's own name added
      # to the token it came from, so that name cannot expand again through it
      # (this alone halts self-reference and mutual recursion). Argument tokens
      # keep their own painting untouched, which is what lets a macro name that
      # arrives from an argument still expand in its new surroundings.
      def expand_tokens(tokens, output)
        queue = tokens.dup
        until queue.empty?
          tok = queue.shift
          # Charge one unit of the whole-run expansion budget per token examined.
          # A macro's substitution is pushed back onto the queue and re-examined,
          # so an exponentially expanding macro is charged for every token it
          # generates and trips this ceiling instead of running away.
          @expansion_tokens += 1
          if @expansion_tokens > EXPANSION_TOKEN_LIMIT
            raise_at(tok, "macro expansion is too large (possible runaway or exponentially expanding macro)")
          end
          if pragma_operator?(tok)
            consume_pragma_operator(tok, queue)
          elsif expandable_builtin?(tok)
            queue.unshift(*expand_builtin(tok))
          elsif expandable_macro?(tok)
            macro = @macros[tok.text]
            if macro.kind == :object
              queue.unshift(*substitute(tok, macro, nil))
            else
              expand_function_macro(tok, macro, queue, output)
            end
          elsif !tok.newline?
            output << tok
          end
        end
      end

      # Whether `tok` should expand now: an identifier naming a macro that its own
      # painting does not forbid (6.10.3.4).
      def expandable_macro?(tok)
        tok.type == :identifier && @macros.key?(tok.text) && !tok.suppress.include?(tok.text)
      end

      # Whether `tok` names a compiler-supplied macro (6.10.8). These cannot be
      # redefined (rejected at #define), so the user table never hides one; and
      # each expands to a non-identifier, so it can neither recurse nor need paint.
      def expandable_builtin?(tok)
        tok.type == :identifier && BUILTIN_MACROS.include?(tok.text)
      end

      # Whether `tok` is the "_Pragma" operator (6.10.9). It is handled during
      # rescanning, not as a directive, so it works whether written literally or
      # produced by macro expansion (Ruby's config.h defines its symbol-export
      # markers as "_Pragma(...)"), which is exactly the case that must be
      # accepted for <ruby.h> to preprocess.
      def pragma_operator?(tok)
        tok.type == :identifier && tok.text == "_Pragma"
      end

      # Consumes a "_Pragma ( string-literal )" operator and drops all four
      # tokens. The operand would destringize into a #pragma line, but the only
      # pragma this compiler acts on is "once", which is meaningless mid-file via
      # _Pragma, so every operand is accepted and ignored (ROADMAP's "accept
      # only"). Newlines between the tokens are inter-token whitespace. A "_Pragma"
      # not followed by a parenthesized string literal is a hard error.
      def consume_pragma_operator(operator, queue)
        skip_queued_newlines(queue)
        malformed_pragma(operator) unless queue.first&.punct?("(")
        queue.shift # "("
        skip_queued_newlines(queue)
        malformed_pragma(operator) unless queue.first&.type == :string
        queue.shift # the string literal (ignored)
        skip_queued_newlines(queue)
        malformed_pragma(operator) unless queue.first&.punct?(")")
        queue.shift # ")"
      end

      def skip_queued_newlines(queue)
        queue.shift while queue.first&.newline?
      end

      def malformed_pragma(operator)
        raise_at(operator, "_Pragma takes a parenthesized string literal")
      end

      # The single token a builtin macro stands for at its use site: the current
      # file and line (6.10.8.1), or a fixed conformance constant. __FILE__ is the
      # source name as a string literal with " and \ escaped; __LINE__ the line as
      # a preprocessing number.
      def expand_builtin(tok)
        token =
          case tok.text
          when "__FILE__"         then string_token(tok, tok.filename)
          when "__LINE__"         then number_token(tok, tok.line.to_s)
          when "__STDC__"         then number_token(tok, "1")
          when "__STDC_VERSION__" then number_token(tok, "201112L")
          when "__RUBYCC__"       then number_token(tok, "1")
          end
        [token]
      end

      # A string-literal preprocessing token whose spelling encodes `value`, its
      # embedded " and \ escaped so the converter reads back the original text.
      def string_token(site, value)
        PPToken.new(
          type: :string, text: quote(value),
          filename: site.filename, line: site.line, column: site.column,
          source_line: site.source_line, space_before: site.space_before
        )
      end

      def quote(value)
        "\"#{value.gsub(/["\\]/) { |ch| "\\#{ch}" }}\""
      end

      # Handles a function-like macro name pulled from the queue. A name not
      # followed (across any newlines) by "(" is a plain identifier, not a call
      # (6.10.3p10), so it is emitted as is. Otherwise the arguments up to the
      # matching ")" are consumed and checked, then the painted substitution is
      # pushed back on the queue for rescanning. Arguments are carried both raw
      # (for "#"/"##") and, lazily, pre-expanded, so each is expanded at most once.
      def expand_function_macro(tok, macro, queue, output)
        unless call_follows?(queue)
          output << tok
          return
        end

        raw, commas = collect_arguments(tok, queue)
        raw = match_arity(tok, macro, raw)
        invocation = Invocation.new(raw, commas, Array.new(raw.length))
        queue.unshift(*substitute(tok, macro, invocation))
      end

      # Whether the next non-newline token waiting in `queue` opens an argument
      # list; a call may sit on a later line than its macro name.
      def call_follows?(queue)
        index = 0
        index += 1 while queue[index]&.newline?
        queue[index] ? queue[index].punct?("(") : false
      end

      # Consumes the argument list of a call: the leading newlines and "(" already
      # confirmed by #call_follows?, then tokens up to the matching ")", split on
      # top-level commas. Nested parentheses are balanced so a comma or ")" inside
      # them belongs to an argument, and a newline is inter-token space that is
      # dropped. Returns [arguments, commas]: the argument token lists and the
      # separating comma tokens themselves (kept so #__VA_ARGS__ can reproduce the
      # exact spelling). Running out of tokens is an unterminated invocation.
      def collect_arguments(tok, queue)
        queue.shift while queue.first&.newline?
        queue.shift # the "("
        arguments = []
        commas = []
        current = []
        depth = 0
        loop do
          raise_at(tok, "unterminated function-like macro invocation") if queue.empty?

          token = queue.shift
          if token.newline?
            next
          elsif depth.zero? && token.punct?(")")
            arguments << current
            return [arguments, commas]
          elsif depth.zero? && token.punct?(",")
            arguments << current
            commas << token
            current = []
          else
            if token.punct?("(")
              depth += 1
              if depth > MACRO_ARGUMENT_NESTING_LIMIT
                raise_at(token, "macro argument parentheses nested too deeply")
              end
            end
            depth -= 1 if token.punct?(")")
            current << token
          end
        end
      end

      # Checks a call's argument count against the macro and returns the argument
      # list to substitute. A parameterless macro admits only "F()", which the
      # collector reports as one empty argument and which is normalized to none. A
      # variadic macro needs at least its named parameters, its variable part
      # possibly empty; a plain one needs exactly its parameters.
      def match_arity(tok, macro, arguments)
        named = macro.params.length
        if named.zero? && !macro.variadic
          return [] if arguments.length == 1 && arguments[0].empty?

          raise_at(tok, "macro \"#{tok.text}\" passed #{arguments.length} arguments, but takes just 0")
        elsif macro.variadic
          raise_at(tok, arity_message(tok, arguments.length, named, "at least")) if arguments.length < named
        elsif arguments.length != named
          raise_at(tok, arity_message(tok, arguments.length, named, "exactly"))
        end
        arguments
      end

      def arity_message(tok, given, wanted, qualifier)
        "macro \"#{tok.text}\" requires #{qualifier} #{wanted} arguments, but #{given} given"
      end

      # Fully expands one argument's tokens in isolation (6.10.3.1) before it is
      # substituted, reusing the same queue algorithm; the tokens keep their own
      # painting, since the macro being called is not yet in play for them.
      def expand_argument(argument)
        expanded = []
        expand_tokens(argument, expanded)
        expanded
      end

      # Builds a macro's substitution by walking its replacement list once
      # (6.10.3). `invocation` carries a function-like call's arguments, or is nil
      # for an object-like macro. "#" stringizes the following parameter's raw
      # argument; "##" pastes the token to its left onto the operand to its right;
      # a plain parameter becomes its pre-expanded argument, unless it abuts a
      # "##", where the raw argument is used instead (6.10.3.1p1); every other
      # token is a literal relocated to the use site and painted with the macro's
      # name. `span` tracks how many tokens the token just placed contributed, so
      # a following "##" knows its left operand (0 marks a placemarker).
      def substitute(tok, macro, invocation)
        painted = paint(tok)
        rep = macro.replacement
        result = []
        span = 0
        index = 0
        while index < rep.length
          cur = rep[index]
          following_paste = rep[index + 1]&.punct?("##")
          if macro.kind == :function && cur.punct?("#")
            result << stringize(cur, painted, raw_operand(macro, invocation, rep[index + 1]))
            span = 1
            index += 2
          elsif cur.punct?("##")
            right = paste_operand(macro, invocation, rep[index + 1], tok, painted)
            span = paste(result, span, right, tok, painted)
            index += 2
          else
            placed = replacement_tokens(macro, invocation, cur, tok, painted, raw: following_paste)
            result.concat(placed)
            span = placed.length
            index += 1
          end
        end
        result
      end

      # The tokens a plain (non-operator) replacement element expands to: a
      # parameter's argument (raw when it abuts "##", else pre-expanded and
      # memoized), the variable arguments for __VA_ARGS__, or the element itself
      # relocated and painted.
      def replacement_tokens(macro, invocation, rep, site, painted, raw:)
        param = parameter_index(macro, rep)
        if param
          raw ? invocation.raw[param] : expanded_argument(invocation, param)
        elsif variadic_ref?(macro, rep)
          raw ? raw_variadic(macro, invocation) : variable_arguments(site, macro, invocation, painted)
        else
          [relocate(rep, site, painted)]
        end
      end

      # The raw (unexpanded) tokens the "#"/"##" operand `operand` denotes: a
      # parameter's argument or the reconstructed variable-argument sequence. The
      # operand was checked at #define time to be a parameter or __VA_ARGS__.
      def raw_operand(macro, invocation, operand)
        param = parameter_index(macro, operand)
        param ? invocation.raw[param] : raw_variadic(macro, invocation)
      end

      # The tokens forming the right side of a "##": a parameter's raw argument
      # (possibly empty, i.e. a placemarker), or a single relocated literal.
      def paste_operand(macro, invocation, operand, site, painted)
        if invocation && parameter_ref?(macro, operand)
          raw_operand(macro, invocation, operand)
        else
          [relocate(operand, site, painted)]
        end
      end

      def parameter_index(macro, rep)
        rep.type == :identifier ? macro.params.index(rep.text) : nil
      end

      def variadic_ref?(macro, rep)
        macro.variadic && rep.type == :identifier && rep.text == "__VA_ARGS__"
      end

      # One argument's fully expanded tokens, computed on first use and cached in
      # the invocation so a parameter named several times expands only once.
      def expanded_argument(invocation, index)
        invocation.expanded[index] ||= expand_argument(invocation.raw[index])
      end

      # The tokens __VA_ARGS__ stands for in a plain position: the pre-expanded
      # variable arguments (those past the named parameters) laid end to end,
      # separated by comma tokens spelled at the call site and painted as literals.
      def variable_arguments(site, macro, invocation, painted)
        result = []
        (macro.params.length...invocation.raw.length).each_with_index do |arg, position|
          result << comma_token(site, painted) if position.positive?
          result.concat(expanded_argument(invocation, arg))
        end
        result
      end

      # The raw variable-argument tokens for a "#"/"##" operand: the unexpanded
      # arguments past the named parameters, rejoined by the very comma tokens the
      # call used, so #__VA_ARGS__ reproduces the source spacing exactly.
      def raw_variadic(macro, invocation)
        named = macro.params.length
        result = []
        (named...invocation.raw.length).each do |arg|
          result << invocation.commas[arg - 1] if arg > named
          result.concat(invocation.raw[arg])
        end
        result
      end

      # Stringizes an operand's raw tokens into a string-literal token (6.10.3.2):
      # the token spellings joined with a single space wherever the source had
      # whitespace and none at the ends, with " and \ escaped inside string and
      # character tokens. The result sits at the use site under the literal paint.
      def stringize(hash, painted, tokens)
        inner = +""
        tokens.each_with_index do |t, index|
          inner << " " if index.positive? && t.space_before
          inner << stringized_spelling(t)
        end
        PPToken.new(
          type: :string, text: "\"#{inner}\"",
          filename: hash.filename, line: hash.line, column: hash.column,
          source_line: hash.source_line, space_before: hash.space_before, suppress: painted
        )
      end

      # A token's contribution to a stringized argument: verbatim, except inside a
      # string literal or character constant, where each " and \ gains a backslash.
      def stringized_spelling(token)
        if token.type == :string || token.type == :char
          token.text.gsub(/["\\]/) { |ch| "\\#{ch}" }
        else
          token.text
        end
      end

      # Concatenates a "##"'s two operands (6.10.3.3). `left_span` is how many
      # tokens the left operand placed; 0 means it was a placemarker, so the paste
      # is just the right operand, and an empty right operand likewise leaves the
      # left alone. Otherwise the left operand's last token and the right's first
      # are spelled together and re-lexed into one token. Returns the new span so
      # a chained "##" pastes onto this result. Left to right by construction.
      def paste(result, left_span, right, site, painted)
        return concat_span(result, right) if left_span.zero?
        return left_span if right.empty?

        left = result.pop
        result << fuse(left, right.first, site, painted)
        result.concat(right[1..])
        right.length
      end

      def concat_span(result, tokens)
        result.concat(tokens)
        tokens.length
      end

      # Fuses two tokens into one by re-lexing their joined spelling through the
      # scanner (6.10.3.3p3): the result must be exactly one preprocessing token,
      # or the paste is ill-formed. It takes the left token's leading space and
      # the literal paint, and is located at the use site for rescanning.
      def fuse(left, right, site, painted)
        spelled = Scanner.new(left.text + right.text, filename: site.filename).scan.reject(&:eof?)
        unless spelled.length == 1
          raise_at(site, "pasting \"#{left.text}\" and \"#{right.text}\" does not give a valid preprocessing token")
        end

        fused = spelled.first
        PPToken.new(
          type: fused.type, text: fused.text,
          filename: site.filename, line: site.line, column: site.column,
          source_line: site.source_line, space_before: left.space_before, suppress: painted
        )
      end

      # The painting a token produced by expanding `tok` carries: `tok`'s own
      # suppression set plus the macro name now being expanded, frozen so the
      # shared list is never mutated by a later token's painting.
      def paint(tok)
        (tok.suppress + [tok.text]).freeze
      end

      def comma_token(site, suppress)
        PPToken.new(
          type: :punct, text: ",",
          filename: site.filename, line: site.line, column: site.column,
          source_line: site.source_line, suppress: suppress
        )
      end

      # A copy of a replacement token relocated to the invocation site (so tokens
      # produced by expansion are diagnosed at the point of use, not at the
      # #define that spelled them) and carrying its computed painting.
      def relocate(rep, site, suppress)
        PPToken.new(
          type: rep.type, text: rep.text,
          filename: site.filename, line: site.line, column: site.column,
          source_line: site.source_line, space_before: rep.space_before, suppress: suppress
        )
      end

      def raise_at(pp, description)
        raise CompileError.new(
          description,
          filename: pp.filename, line: pp.line, column: pp.column,
          source_line: pp.source_line
        )
      end

      # As #raise_at, but for a Front::Token (produced during #if evaluation)
      # rather than a preprocessing token; both expose the same location fields.
      def raise_at_front(token, description)
        raise CompileError.new(
          description,
          filename: token.filename, line: token.line, column: token.column,
          source_line: token.source_line
        )
      end
    end
  end
end
