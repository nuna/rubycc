# frozen_string_literal: true

module Rubycc
  module Front
    # Raised while decoding the interior of a single lexeme (a numeric constant,
    # a string/character literal). It is deliberately position-agnostic: it only
    # names the problem and the character offset (into the text handed to the
    # reader) where it occurred, leaving the caller to translate that offset into
    # a source line/column for a user-facing CompileError. This lets the same
    # decoder serve both the streaming Lexer (offsets into the whole source) and
    # the preprocessor's converter (offsets into an isolated lexeme).
    class LexError < StandardError
      attr_reader :offset

      def initialize(message, offset)
        @offset = offset
        super(message)
      end
    end

    # The shared spelling-to-value decoder for the C subset's lexemes. Both the
    # streaming Front::Lexer and the preprocessor's token converter delegate here
    # so the two paths fold numeric constants, resolve escapes and classify
    # identifiers with byte-for-byte identical rules. The reader walks a plain
    # string with its own cursor (no line/column bookkeeping); positions are the
    # caller's concern. Each `read_*` leaves `pos` just past the lexeme.
    class LexemeReader
      # A decoded lexeme. `type` is :num, :float, :string, :ident or :keyword.
      # `value` is the folded Integer/Float, the escape-resolved ASCII-8BIT bytes
      # of a string, or the identifier text. `base`/`suffix` accompany an integer
      # :num and `suffix` a :float, matching Front::Token's numeric fields.
      Result = Struct.new(:type, :value, :base, :suffix)

      KEYWORDS = %w[int char void short long signed unsigned _Bool float double struct union
                    enum typedef static extern const volatile inline register auto
                    return if else while do for break continue
                    switch case default goto sizeof
                    _Static_assert _Alignof __int128
                    __builtin_va_start __builtin_va_arg __builtin_va_end __builtin_va_copy
                    __builtin_expect __builtin_alloca __builtin_offsetof
                    __builtin_constant_p __builtin_choose_expr
                    __builtin_ctz __builtin_ctzll __builtin_clz __builtin_clzll
                    __builtin_unreachable __builtin_memcpy
                    __builtin_add_overflow __builtin_sub_overflow __builtin_mul_overflow
                    __atomic_load_n __atomic_store_n __atomic_exchange_n
                    __atomic_compare_exchange_n
                    __atomic_fetch_add __atomic_fetch_sub
                    __atomic_add_fetch __atomic_sub_fetch __atomic_or_fetch
                    __asm__
                    __attribute__ __extension__].freeze

      # Membership lookup for every identifier the lexer produces, so it must
      # be O(1); KEYWORDS.include? showed up as a linear scan in profiling.
      KEYWORD_SET = KEYWORDS.to_h { |word| [word, true] }.freeze

      # gcc's reserved "__x"/"__x__" alternate spellings for a handful of
      # keywords (6.10.8.4's rationale: a header built with strict-ISO options
      # such as -ansi still needs the keyword's meaning without colliding with
      # a user identifier of the plain name). glibc's uapi-derived headers lean
      # on these unconditionally, e.g. asm-generic/int-ll64.h's
      # "typedef __signed__ char __s8". Each maps straight to the plain
      # keyword's own spelling, so every downstream check keyed on that
      # spelling (DECL_SPECIFIER_KEYWORDS, "const"/"volatile"/"inline" in
      # Front::Parser, ...) sees an ordinary keyword token and needs no
      # separate case for the alias.
      KEYWORD_ALIASES = {
        "__signed" => "signed", "__signed__" => "signed",
        "__const" => "const", "__const__" => "const",
        "__volatile" => "volatile", "__volatile__" => "volatile",
        "__inline" => "inline", "__inline__" => "inline"
      }.freeze

      # Escape sequences shared by character constants and string literals,
      # mapping the letter after the backslash to the byte value it denotes.
      # "\x" (hexadecimal, any number of digits) and octal ("\ooo", 1-3 digits,
      # "0" included) are handled separately in #read_escaped_byte since their
      # value comes from digits rather than a fixed table lookup.
      ESCAPES = {
        "n" => 10, "t" => 9, "r" => 13, "\\" => 92,
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

      # Whether `name` (an identifier's spelling) is a reserved keyword.
      def self.keyword?(name)
        KEYWORD_SET.key?(name)
      end

      # The keyword token `name` denotes: itself when it already is one of
      # KEYWORDS, or the plain spelling it aliases (see KEYWORD_ALIASES) when it
      # is one of gcc's reserved "__x"/"__x__" spellings. nil when `name` names
      # neither, so the caller lexes it as an ordinary identifier.
      def self.keyword_spelling(name)
        return name if KEYWORD_SET.key?(name)

        KEYWORD_ALIASES[name]
      end

      attr_reader :pos

      def initialize(text, start = 0)
        @text = text
        @pos = start
      end

      # An identifier or keyword run "[A-Za-z_][A-Za-z0-9_]*". The caller must
      # position the cursor on the leading identifier character.
      def read_identifier
        name = +""
        name << advance while identifier_char?(current)
        spelling = LexemeReader.keyword_spelling(name)
        Result.new(spelling ? :keyword : :ident, spelling || name, nil, nil)
      end

      # A numeric constant. A "0x"/"0X" prefix is hexadecimal (an integer, or a
      # hexadecimal floating constant this subset does not lower yet); otherwise
      # a "." or an exponent anywhere in the run marks a decimal floating
      # constant, and its absence a decimal or octal integer. The floating check
      # precedes the octal one so "08.5" reads as the float 8.5 rather than
      # tripping the octal-digit rule on its '8'.
      def read_number
        if current == "0" && (peek == "x" || peek == "X")
          read_hexadecimal_constant
        elsif current == "0" && (peek == "b" || peek == "B")
          read_binary_constant
        elsif floating_constant_ahead?
          read_floating_constant
        else
          read_integer_constant
        end
      end

      # A string literal "abc" including its surrounding quotes: returns the
      # escape-resolved bytes (ASCII-8BIT), without the NUL terminator the
      # generator later appends. An unterminated literal (newline or end before
      # the closing quote) and an unknown escape are rejected.
      def read_string
        start = @pos
        advance # opening quote
        bytes = +"".b
        loop do
          if at_end? || current == "\n"
            raise LexError.new("unterminated string literal", start)
          end
          break if current == "\""

          bytes << read_escaped_byte(start, "string literal")
        end
        advance # closing quote
        Result.new(:string, bytes, nil, nil)
      end

      # A character constant 'c' or '\n' including its quotes: returns a :num
      # result whose value is the character's byte code, since an ISO C character
      # constant has type int (6.4.4.4). The constant must hold exactly one
      # character; an empty '', a multi-character 'ab', an unterminated ' and an
      # unknown escape are all rejected.
      def read_char
        start = @pos
        advance # opening quote
        if at_end? || current == "\n"
          raise LexError.new("unterminated character constant", start)
        elsif current == "'"
          raise LexError.new("empty character constant", start)
        end
        value = read_escaped_byte(start, "character constant")
        if at_end? || current == "\n"
          raise LexError.new("unterminated character constant", start)
        elsif current != "'"
          raise LexError.new("multi-character character constant", start)
        end
        advance # closing quote
        Result.new(:num, value, 10, "")
      end

      private

      def at_end?
        @pos >= @text.length
      end

      def current
        @text[@pos]
      end

      def peek(offset = 1)
        @text[@pos + offset]
      end

      def advance
        ch = @text[@pos]
        @pos += 1
        ch
      end

      def identifier_char?(ch)
        !ch.nil? && ch.match?(/[A-Za-z0-9_]/)
      end

      # Reads one logical character and returns its byte value, decoding a
      # backslash escape via ESCAPES, a hexadecimal escape ("\x" then one or
      # more hex digits) or an octal escape ("\ooo", 1-3 octal digits, 6.4.4.4).
      # Shared by character constants and string literals; `context` names the
      # construct for error messages and `start` locates the opening quote for
      # a positioned error.
      def read_escaped_byte(start, context)
        ch = current
        if ch.nil? || ch == "\n"
          raise LexError.new("unterminated #{context}", start)
        elsif ch == "\\"
          advance # backslash
          esc = current
          if esc.nil? || esc == "\n"
            raise LexError.new("unterminated #{context}", start)
          elsif esc == "x"
            advance
            read_hex_escape(start)
          elsif octal_digit?(esc)
            read_octal_escape(start)
          else
            code = ESCAPES[esc]
            raise LexError.new("unknown escape sequence in #{context}", start) unless code

            advance
            code
          end
        else
          advance
          ch.ord
        end
      end

      # A "\x" escape's value: one or more hex digits (unbounded in the grammar,
      # 6.4.4.4), rejected here when it exceeds a byte's range since a char or a
      # string element is one byte in this implementation. At least one digit is
      # required ("\x" alone is ill-formed).
      def read_hex_escape(start)
        digits = +""
        digits << advance while hex_digit?(current)
        raise LexError.new("\\x used with no following hex digits", start) if digits.empty?

        value = digits.to_i(16)
        raise LexError.new("hex escape sequence out of range", start) if value > 255

        value
      end

      # An octal escape's value: 1-3 octal digits (the leading one already
      # confirmed present by the caller), rejected when it exceeds a byte's
      # range ("\777" is 511, past 255).
      def read_octal_escape(start)
        digits = +""
        3.times do
          break unless octal_digit?(current)

          digits << advance
        end
        value = digits.to_i(8)
        raise LexError.new("octal escape sequence out of range", start) if value > 255

        value
      end

      # Whether the digit run at the cursor is a decimal floating constant: it is
      # exactly when a "." or an exponent marker ('e'/'E') follows the leading
      # digits. Only consulted for a decimal constant (hexadecimal is split off
      # first), so an 'e'/'E' here is always an exponent, never a hex digit.
      def floating_constant_ahead?
        i = @pos
        i += 1 while @text[i]&.match?(/[0-9]/)
        ch = @text[i]
        ch == "." || ch == "e" || ch == "E"
      end

      # A hexadecimal integer constant "0x...". A '.' or a binary-exponent marker
      # ('p'/'P') after the hex digits is a hexadecimal *floating* constant
      # (0x1.8p3), a distinct grammar this subset does not lower yet, so it is
      # diagnosed rather than silently misread as an integer.
      def read_hexadecimal_constant
        start = @pos
        advance # 0
        advance # x
        digits = +""
        digits << advance while hex_digit?(current)
        raise LexError.new("invalid hexadecimal constant", start) if digits.empty?
        if current == "." || current == "p" || current == "P"
          raise LexError.new("hexadecimal floating constants are not supported yet", start)
        end
        suffix = read_integer_suffix(start)
        if identifier_char?(current)
          raise LexError.new("invalid suffix on integer constant", @pos)
        end
        Result.new(:num, digits.to_i(16), 16, suffix)
      end

      # A binary integer constant "0b...."/"0B...." (a GNU extension, made
      # standard in C23): the "0b" prefix, one or more binary digits, and an
      # optional integer suffix. It shares the octal/hexadecimal type rules (a
      # non-decimal constant may take an unsigned type without a "u" suffix), so
      # the result carries base 2 for #integer_literal_type to treat it as such.
      # At least one digit is required; a trailing identifier character after the
      # suffix is rejected like any other invalid suffix.
      def read_binary_constant
        start = @pos
        advance # 0
        advance # b / B
        digits = +""
        digits << advance while current == "0" || current == "1"
        raise LexError.new("invalid binary constant", start) if digits.empty?

        suffix = read_integer_suffix(start)
        if identifier_char?(current)
          raise LexError.new("invalid suffix on integer constant", @pos)
        end
        Result.new(:num, digits.to_i(2), 2, suffix)
      end

      # A decimal or octal integer constant, with an optional u/U and l/L/ll/LL
      # suffix run. The result carries the folded value with its base and
      # normalized suffix. A trailing identifier character (e.g. 12abc, once the
      # real suffix letters are consumed) is rejected.
      def read_integer_constant
        start = @pos
        if current == "0" && digit?(peek)
          advance # leading 0
          digits = +"0"
          while digit?(current)
            unless octal_digit?(current)
              raise LexError.new("invalid digit in octal constant", @pos)
            end
            digits << advance
          end
          base = 8
        else
          digits = +""
          digits << advance while digit?(current)
          base = 10
        end

        suffix = read_integer_suffix(start)
        if identifier_char?(current)
          raise LexError.new("invalid suffix on integer constant", @pos)
        end
        Result.new(:num, digits.to_i(base), base, suffix)
      end

      # A decimal floating constant (6.4.4.2): an integer part, an optional
      # fraction after a ".", and an optional exponent ("e"/"E" with an optional
      # sign and required digits). A trailing f/F makes it `float`, l/L `long
      # double` (treated as `double`), and no suffix `double`. String#to_f parses
      # every admitted spelling (including "1." and ".5") over the characters
      # already validated here. An exponent with no digits, and a trailing
      # identifier or "." character, are rejected.
      def read_floating_constant
        start = @pos
        text = +""
        text << advance while digit?(current)
        saw_fraction_digit = true
        if current == "."
          text << advance
          saw_fraction_digit = digit?(current)
          text << advance while digit?(current)
        end
        if current == "e" || current == "E"
          text << advance
          text << advance if current == "+" || current == "-"
          unless digit?(current)
            raise LexError.new("exponent has no digits", start)
          end
          text << advance while digit?(current)
        end
        suffix = read_floating_suffix
        if !current.nil? && current.match?(/[A-Za-z0-9_.]/)
          raise LexError.new("invalid suffix on floating constant", @pos)
        end
        # C allows a floating constant with a "." followed by no fraction
        # digits before the exponent (6.4.4.2), e.g. "1.e5". Ruby's
        # String#to_f up to 3.3.x (fixed in 3.4) drops the exponent for
        # exactly this shape and silently returns the wrong value (e.g.
        # "1.e5".to_f == 1.0 instead of 100000.0). Since "N." and "N.0" are
        # the same number, pad the fraction with a "0" before conversion so
        # to_f sees the shape it parses correctly on every supported Ruby.
        # This only affects the string handed to to_f, not the token's
        # spelling (Result carries no spelling field; `text` here is purely
        # a conversion buffer).
        to_f_text = saw_fraction_digit ? text : text.sub(".", ".0")
        Result.new(:float, to_f_text.to_f, nil, suffix)
      end

      # Consumes a floating constant's f/F or l/L suffix, returning it normalized
      # ("f" for float, "l" for long double, "" for a plain double). At most one
      # letter is valid; a longer run is caught by the trailing-character check.
      def read_floating_suffix
        ch = current
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

      # Consumes an integer constant's u/U and l/L suffix run and returns it in a
      # normalized (lower-case) form ("", "u", "l", "ul", "ll", "ull", ...). A
      # valid suffix is at most one "u" together with at most one l-part
      # ("l"/"L" or "ll"/"LL", never mixed case), in either order; anything else
      # is rejected. `start` locates the constant for a positioned error.
      def read_integer_suffix(start)
        raw = +""
        raw << advance while current&.match?(/[uUlL]/)
        return "" if raw.empty?

        valid = raw.match?(/\A(?:[uU])?(?:ll|LL|[lL])?\z/) ||
                raw.match?(/\A(?:ll|LL|[lL])?(?:[uU])?\z/)
        raise LexError.new("invalid suffix #{raw.inspect} on integer constant", start) unless valid

        raw.downcase
      end

      def digit?(ch)
        !ch.nil? && ch.match?(/[0-9]/)
      end

      def octal_digit?(ch)
        !ch.nil? && ch.match?(/[0-7]/)
      end

      def hex_digit?(ch)
        !ch.nil? && ch.match?(/[0-9A-Fa-f]/)
      end
    end
  end
end
