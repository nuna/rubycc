# frozen_string_literal: true

require_relative "token"
require_relative "../compile_error"

module Rubycc
  module Front
    # Hand-written lexer for the C subset. Tracks 1-based line/column positions
    # and keeps each source line around so tokens (and errors) can be reported
    # with source excerpts. Handles // and /* */ comments and whitespace.
    class Lexer
      KEYWORDS = %w[int char void short long signed unsigned _Bool float double struct union
                    enum typedef static extern const volatile inline register auto
                    return if else while do for break continue
                    switch case default goto sizeof
                    _Static_assert _Alignof
                    __builtin_va_start __builtin_va_arg __builtin_va_end].freeze

      # Escape sequences shared by character constants and string literals,
      # mapping the letter after the backslash to the byte value it denotes.
      ESCAPES = {
        "n" => 10, "t" => 9, "r" => 13, "0" => 0, "\\" => 92,
        "'" => 39, "\"" => 34, "a" => 7, "b" => 8, "f" => 12, "v" => 11
      }.freeze

      # Three-character punctuators, matched before the shorter lists so the
      # longest one always wins: "<<=" must beat "<<" (and "<="/"<"), ">>=" must
      # beat ">>" (and ">="/">"), and "..." (the variadic-parameter ellipsis)
      # must beat a lone "." (which is not a two-character punctuator, so ".."
      # never forms; three consecutive dots are the only way "..." arises).
      PUNCTUATORS_3 = %w[<<= >>= ...].freeze

      # Two-character punctuators, matched before the single-character list so
      # the lexer always prefers the longest punctuator ("==" over two "=",
      # "&&" over two "&", "++" or "+=" over a lone "+", "->" over a lone "-",
      # "<<" over two "<", "&=" over "&"/"&&").
      PUNCTUATORS_2 = %w[== != <= >= && || += -= *= /= %= ++ -- -> << >> &= |= ^=].freeze

      # Single-character punctuators used by this slice. "&" is both the
      # address-of operator and the bitwise-and operator, "*" doubles as
      # dereference and pointer-declarator marker, "|" "^" "~" are the remaining
      # bitwise operators, "[" "]" bracket array declarators and subscripts,
      # "?" ":" form the conditional operator, and "." selects a struct member.
      PUNCTUATORS_1 = %w[+ - * / % ( ) { } ; = , < > ! & | ^ ~ [ ] ? : .].freeze

      def initialize(source, filename:)
        @src = source
        @filename = filename
        @pos = 0
        @line = 1
        @column = 1
        # -1 keeps a trailing empty field, so line numbers map 1:1 to entries.
        @lines = source.split("\n", -1)
      end

      def tokenize
        tokens = []
        loop do
          skip_whitespace_and_comments
          break if at_end?

          tokens << next_token
        end
        tokens << make_token(:eof, nil, @line, @column)
        tokens
      end

      private

      def at_end?
        @pos >= @src.length
      end

      def current_char
        @src[@pos]
      end

      def peek(offset = 0)
        @src[@pos + offset]
      end

      # Consumes one character, maintaining line/column bookkeeping.
      def advance
        ch = @src[@pos]
        @pos += 1
        if ch == "\n"
          @line += 1
          @column = 1
        else
          @column += 1
        end
        ch
      end

      def skip_whitespace_and_comments
        loop do
          ch = current_char
          if ch.nil?
            return
          elsif ch =~ /\s/
            advance
          elsif ch == "/" && peek(1) == "/"
            advance until at_end? || current_char == "\n"
          elsif ch == "/" && peek(1) == "*"
            skip_block_comment
          else
            return
          end
        end
      end

      def skip_block_comment
        start_line = @line
        start_col = @column
        advance # /
        advance # *
        loop do
          if at_end?
            raise_error("unterminated block comment", start_line, start_col)
          elsif current_char == "*" && peek(1) == "/"
            advance # *
            advance # /
            return
          else
            advance
          end
        end
      end

      def next_token
        line = @line
        column = @column
        ch = current_char

        if ch =~ /[0-9]/
          lex_number(line, column)
        elsif ch == "." && peek(1) =~ /[0-9]/
          # A leading-dot floating constant (".5"): a "." immediately followed
          # by a digit is the fractional-only form, which #lex_number routes to
          # the floating path. A "." in any other position is the member-access
          # punctuator (or part of "..."), handled by #lex_punctuator.
          lex_number(line, column)
        elsif ch =~ /[A-Za-z_]/
          lex_identifier(line, column)
        elsif ch == "'"
          lex_character_constant(line, column)
        elsif ch == "\""
          lex_string_literal(line, column)
        else
          lex_punctuator(line, column)
        end
      end

      # A character constant 'c' or '\n': lexed as a :num token whose value is
      # the character's byte code, since an ISO C character constant has type
      # int. The constant must hold exactly one character; an empty '', a
      # multi-character 'ab', an unterminated ' and an unknown escape are all
      # rejected with a positioned error.
      def lex_character_constant(line, column)
        advance # opening quote
        if at_end? || current_char == "\n"
          raise_error("unterminated character constant", line, column)
        elsif current_char == "'"
          raise_error("empty character constant", line, column)
        end
        value = read_escaped_byte(line, column, "character constant")
        if at_end? || current_char == "\n"
          raise_error("unterminated character constant", line, column)
        elsif current_char != "'"
          raise_error("multi-character character constant", line, column)
        end
        advance # closing quote
        # A character constant has type int (6.4.4.4), so it presents as a plain
        # decimal, suffix-free integer constant to the parser.
        make_num_token(value, 10, "", line, column)
      end

      # A string literal "abc": lexed as a :string token whose value is the
      # escape-resolved bytes (ASCII-8BIT), without the NUL terminator the
      # generator later appends. An unterminated literal (newline or EOF before
      # the closing quote) and an unknown escape are rejected.
      def lex_string_literal(line, column)
        advance # opening quote
        bytes = +"".b
        loop do
          if at_end? || current_char == "\n"
            raise_error("unterminated string literal", line, column)
          end
          break if current_char == "\""

          bytes << read_escaped_byte(line, column, "string literal")
        end
        advance # closing quote
        make_token(:string, bytes, line, column)
      end

      # Reads one logical character at the cursor and returns its byte value,
      # decoding a backslash escape via ESCAPES. Shared by character constants
      # and string literals; `context` names the construct for error messages.
      def read_escaped_byte(start_line, start_col, context)
        ch = current_char
        if ch.nil? || ch == "\n"
          raise_error("unterminated #{context}", start_line, start_col)
        elsif ch == "\\"
          advance # backslash
          esc = current_char
          if esc.nil? || esc == "\n"
            raise_error("unterminated #{context}", start_line, start_col)
          end
          code = ESCAPES[esc]
          raise_error("unknown escape sequence in #{context}", start_line, start_col) unless code

          advance
          code
        else
          advance
          ch.ord
        end
      end

      # Longest-match punctuator scan: try the three-character punctuators
      # first, then the two-character ones, then fall back to the
      # single-character ones. peek(1)/peek(2) yield nil past the end, which
      # interpolate to "", so the assembled candidates simply fail to match near
      # EOF and the scan falls through to a shorter length.
      def lex_punctuator(line, column)
        three = "#{current_char}#{peek(1)}#{peek(2)}"
        two = "#{current_char}#{peek(1)}"
        if PUNCTUATORS_3.include?(three)
          advance
          advance
          advance
          make_token(:punct, three, line, column)
        elsif PUNCTUATORS_2.include?(two)
          advance
          advance
          make_token(:punct, two, line, column)
        elsif PUNCTUATORS_1.include?(current_char)
          ch = advance
          make_token(:punct, ch, line, column)
        else
          raise_error("unexpected character #{current_char.inspect}", line, column)
        end
      end

      # A numeric constant. A "0x"/"0X" prefix is hexadecimal (an integer, or a
      # hexadecimal floating constant this subset does not lower yet); otherwise
      # a "." or an exponent anywhere in the run marks a decimal floating
      # constant (#lex_floating_constant), and its absence a decimal or octal
      # integer (#lex_integer_constant). The floating check precedes the octal
      # one so "08.5" reads as the float 8.5 rather than tripping the octal-digit
      # rule on its '8'.
      def lex_number(line, column)
        if current_char == "0" && (peek(1) == "x" || peek(1) == "X")
          lex_hexadecimal_constant(line, column)
        elsif floating_constant_ahead?
          lex_floating_constant(line, column)
        else
          lex_integer_constant(line, column)
        end
      end

      # Whether the digit run at the cursor is a decimal floating constant: it is
      # exactly when a "." or an exponent marker ('e'/'E') follows the leading
      # digits. Only ever consulted for a decimal constant (hexadecimal is split
      # off first), so an 'e'/'E' here is always an exponent, never a hex digit.
      def floating_constant_ahead?
        i = @pos
        i += 1 while @src[i] =~ /[0-9]/
        ch = @src[i]
        ch == "." || ch == "e" || ch == "E"
      end

      # A hexadecimal integer constant "0x...". A '.' or a binary-exponent marker
      # ('p'/'P') after the hex digits is a hexadecimal *floating* constant
      # (0x1.8p3), a distinct grammar this subset does not lower yet, so it is
      # diagnosed rather than silently misread as an integer.
      def lex_hexadecimal_constant(line, column)
        advance # 0
        advance # x
        digits = +""
        digits << advance while !at_end? && current_char =~ /[0-9A-Fa-f]/
        raise_error("invalid hexadecimal constant", line, column) if digits.empty?
        if current_char == "." || current_char == "p" || current_char == "P"
          raise_error("hexadecimal floating constants are not supported yet", line, column)
        end
        suffix = lex_integer_suffix(line, column)
        if !at_end? && current_char =~ /[A-Za-z0-9_]/
          raise_error("invalid suffix on integer constant", @line, @column)
        end
        make_num_token(digits.to_i(16), 16, suffix, line, column)
      end

      # A decimal or octal integer constant, with an optional u/U and l/L/ll/LL
      # suffix run. The token carries the folded value together with its base and
      # normalized suffix, from which the parser fixes the constant's type
      # (6.4.4.1). A trailing identifier character (e.g. 12abc, once the real
      # suffix letters are consumed) is rejected.
      def lex_integer_constant(line, column)
        if current_char == "0" && peek(1) =~ /[0-9]/
          advance # leading 0
          digits = +"0"
          while !at_end? && current_char =~ /[0-9]/
            unless current_char =~ /[0-7]/
              raise_error("invalid digit in octal constant", @line, @column)
            end
            digits << advance
          end
          base = 8
        else
          digits = +""
          digits << advance while !at_end? && current_char =~ /[0-9]/
          base = 10
        end

        suffix = lex_integer_suffix(line, column)
        if !at_end? && current_char =~ /[A-Za-z0-9_]/
          raise_error("invalid suffix on integer constant", @line, @column)
        end
        make_num_token(digits.to_i(base), base, suffix, line, column)
      end

      # A decimal floating constant (6.4.4.2): an integer part, an optional
      # fraction after a ".", and an optional exponent ("e"/"E" with an optional
      # sign and required digits), any of the three shapes "1.5", "1.", ".5",
      # "1e3", "1.5e-2". A trailing f/F makes it `float`, l/L `long double`
      # (treated as `double`), and no suffix `double`; the parser fixes the type
      # from that suffix. String#to_f parses every admitted spelling (including
      # the "1." and ".5" forms Kernel#Float rejects) over the characters already
      # validated here. An exponent with no digits, and a trailing identifier or
      # "." character, are rejected.
      def lex_floating_constant(line, column)
        text = +""
        text << advance while !at_end? && current_char =~ /[0-9]/
        if current_char == "."
          text << advance
          text << advance while !at_end? && current_char =~ /[0-9]/
        end
        if current_char == "e" || current_char == "E"
          text << advance
          text << advance if current_char == "+" || current_char == "-"
          unless !at_end? && current_char =~ /[0-9]/
            raise_error("exponent has no digits", line, column)
          end
          text << advance while !at_end? && current_char =~ /[0-9]/
        end
        suffix = lex_floating_suffix
        if !at_end? && current_char =~ /[A-Za-z0-9_.]/
          raise_error("invalid suffix on floating constant", @line, @column)
        end
        make_float_token(text.to_f, suffix, line, column)
      end

      # Consumes a floating constant's f/F or l/L suffix, returning it normalized
      # ("f" for float, "l" for long double, "" for a plain double). At most one
      # letter is valid; a longer run is caught by #lex_floating_constant's
      # trailing-character check.
      def lex_floating_suffix
        ch = current_char
        if ch == "f" || ch == "F"
          advance
          "f"
        elsif ch == "l" || ch == "L"
          advance
          "l"
        else
          ""
        end
      end

      # Consumes an integer constant's u/U and l/L suffix run and returns it in
      # a normalized (lower-case) form ("", "u", "l", "ul", "ll", "ull", ...).
      # A valid suffix is at most one "u" together with at most one l-part
      # ("l"/"L" or "ll"/"LL", never mixed case), in either order; anything else
      # is rejected.
      def lex_integer_suffix(line, column)
        raw = +""
        raw << advance while !at_end? && current_char =~ /[uUlL]/
        return "" if raw.empty?

        valid = raw.match?(/\A(?:[uU])?(?:ll|LL|[lL])?\z/) ||
                raw.match?(/\A(?:ll|LL|[lL])?(?:[uU])?\z/)
        raise_error("invalid suffix #{raw.inspect} on integer constant", line, column) unless valid

        raw.downcase
      end

      def lex_identifier(line, column)
        name = +""
        name << advance while !at_end? && current_char =~ /[A-Za-z0-9_]/
        type = KEYWORDS.include?(name) ? :keyword : :ident
        make_token(type, name, line, column)
      end

      def make_token(type, value, line, column)
        Token.new(
          type: type,
          value: value,
          filename: @filename,
          line: line,
          column: column,
          source_line: source_line_for(line)
        )
      end

      # A :num token carrying the extra base/suffix an integer constant needs
      # for the parser to fix its type.
      def make_num_token(value, base, suffix, line, column)
        Token.new(
          type: :num,
          value: value,
          filename: @filename,
          line: line,
          column: column,
          source_line: source_line_for(line),
          base: base,
          suffix: suffix
        )
      end

      # A :float token carrying the folded Ruby Float value and the normalized
      # floating suffix the parser fixes the constant's type from.
      def make_float_token(value, suffix, line, column)
        Token.new(
          type: :float,
          value: value,
          filename: @filename,
          line: line,
          column: column,
          source_line: source_line_for(line),
          suffix: suffix
        )
      end

      def source_line_for(line)
        @lines[line - 1] || ""
      end

      def raise_error(description, line, column)
        raise CompileError.new(
          description,
          filename: @filename,
          line: line,
          column: column,
          source_line: source_line_for(line)
        )
      end
    end
  end
end
