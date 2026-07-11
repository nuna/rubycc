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
    # kin) select which lines reach that loop. Only object-like macros are handled
    # here; function-like macros arrive in a later step, and are diagnosed rather
    # than misinterpreted meanwhile.
    class Preprocessor
      # A guard against unbounded #include recursion (a header that includes
      # itself); 200 is comfortably deeper than any sane header nesting.
      INCLUDE_DEPTH_LIMIT = 200

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

      def initialize
        # name (String) => replacement list (Array<PPToken>), object macros only.
        @macros = {}
        @include_depth = 0
      end

      def run(source, filename:, include_paths: [])
        @include_paths = include_paths
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
      # at end of file is an unterminated conditional. Newlines are consumed here
      # so the output stream is already free of them.
      def process_lines(tokens, filename, output)
        stack = []
        index = 0
        at_line_start = true
        while index < tokens.length
          tok = tokens[index]
          break if tok.eof?

          if tok.newline?
            at_line_start = true
            index += 1
          elsif at_line_start && tok.punct?("#")
            index = process_directive(tokens, index, filename, output, stack)
            at_line_start = true
          else
            at_line_start = false
            expand_into(tok, output, []) if active?(stack)
            index += 1
          end
        end
        raise_at(stack.last.token, "unterminated conditional directive") unless stack.empty?
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
        when "include" then handle_include(hash, body, output, filename)
        when "define"  then handle_define(name, body)
        when "undef"   then handle_undef(name, body)
        when "error"   then handle_error(hash, body)
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
      # boolean. In order: fold each `defined` operator to 1/0 (its operand
      # unexpanded), macro-expand what remains, replace every surviving
      # identifier with 0, convert to ordinary tokens, and evaluate the parsed
      # expression with the shared constant evaluator. A non-zero result is true.
      def evaluate_if_expression(directive, body)
        raise_at(directive, "##{directive.text} with no expression") if body.empty?

        expanded = []
        replace_defined(body).each { |tok| expand_into(tok, expanded, []) }
        neutral = expanded.map { |tok| tok.type == :identifier ? number_zero(tok) : tok }
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

      # Rewrites each `defined NAME` / `defined ( NAME )` operator to the pp-number
      # 1 or 0 by consulting the macro table, leaving NAME unexpanded (6.10.1p1).
      # A form that is not `defined` followed by an identifier (optionally
      # parenthesized) is rejected.
      def replace_defined(body)
        result = []
        index = 0
        while index < body.length
          tok = body[index]
          if tok.type == :identifier && tok.text == "defined"
            name, index = read_defined_operand(tok, body, index + 1)
            result << number_flag(tok, @macros.key?(name))
          else
            result << tok
            index += 1
          end
        end
        result
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

      # --- #include --------------------------------------------------------------

      def handle_include(hash, body, output, includer)
        kind, name = parse_header_name(hash, body)
        path = resolve_include(kind, name, includer, hash)
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
      # angled include only along the search path (6.10.2p2-3).
      def resolve_include(kind, name, includer, hash)
        directories = []
        directories << File.dirname(includer) if kind == :quote
        directories.concat(@include_paths)
        directories.each do |dir|
          candidate = File.join(dir, name)
          return candidate if File.file?(candidate)
        end
        raise_at(hash, "#{name}: No such file or directory")
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

        replacement = body[1..]
        first = replacement[0]
        # A "(" abutting the name with no separating space opens a parameter list;
        # such macros are function-like and not supported until a later step.
        if first && first.punct?("(") && !first.space_before
          raise_at(first, "function-like macros are not supported yet")
        end

        existing = @macros[name.text]
        if existing.nil?
          @macros[name.text] = replacement
        elsif !identical_replacement?(existing, replacement)
          # A benign redefinition (an identical replacement list) is allowed; a
          # differing one is an error (6.10.3p2, simplified to token spellings).
          raise_at(name, "macro '#{name.text}' redefined")
        end
      end

      def handle_undef(directive, body)
        raise_at(directive, "no macro name given in #undef directive") if body.empty?

        name = body[0]
        raise_at(name, "macro names must be identifiers") unless name.type == :identifier
        raise_at(body[1], "extra tokens at end of #undef directive") if body.length > 1
        # Undefining a name that was never a macro is not an error (6.10.3.5p2).
        @macros.delete(name.text)
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

      # --- macro expansion -------------------------------------------------------

      # Expands `tok` into `output`. An identifier naming an object macro is
      # replaced by its replacement list, which is itself rescanned for further
      # macros (6.10.3.4). `active` lists the macros whose expansion is currently
      # in progress; a name on it is left as a plain identifier, which halts both
      # direct self-reference and indirect cycles without painting tokens.
      def expand_into(tok, output, active)
        if tok.type == :identifier && @macros.key?(tok.text) && !active.include?(tok.text)
          nested = active + [tok.text]
          @macros[tok.text].each do |rep|
            expand_into(relocate(rep, tok), output, nested)
          end
        else
          output << tok
        end
      end

      # A copy of a replacement token relocated to the invocation site, so tokens
      # produced by expansion are diagnosed at the point of use rather than at the
      # #define that spelled them.
      def relocate(rep, site)
        PPToken.new(
          type: rep.type, text: rep.text,
          filename: site.filename, line: site.line, column: site.column,
          source_line: site.source_line, space_before: rep.space_before
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
