# frozen_string_literal: true

require_relative "ast"
require_relative "constant_evaluator"
require_relative "initializer_resolver"
require_relative "../type"
require_relative "../compile_error"

module Rubycc
  module Front
    # Recursive-descent parser for the C subset. Nonterminals follow the
    # grammar productions of ISO C (6.5.x / 6.7 / 6.8.x):
    #
    #   translation-unit          = external-declaration*
    #   external-declaration      = type-specifier ";"             -- tag only
    #                             | type-specifier declarator
    #                               ( (";" | compound-statement)   -- function
    #                                                                 (declarator
    #                                                                  is a
    #                                                                  function)
    #                               | ("=" initializer)?
    #                                 ("," declarator ("=" initializer)?)*
    #                                 ";" )                         -- variables
    #   declaration-specifiers    = (storage-class-specifier | type-specifier)+
    #   storage-class-specifier   = "typedef"
    #   type-specifier            = "void" | "char" | "short" | "int" | "long"
    #                             | "signed" | "unsigned" | "_Bool"
    #                             | struct-or-union-specifier | enum-specifier
    #                             | typedef-name
    #   typedef-name              = identifier
    #   struct-or-union-specifier = struct-or-union identifier?
    #                                 "{" struct-declaration+ "}"
    #                             | struct-or-union identifier
    #   struct-or-union           = "struct" | "union"
    #   enum-specifier            = "enum" identifier? "{" enumerator-list ","? "}"
    #                             | "enum" identifier
    #   enumerator-list           = enumerator ("," enumerator)*
    #   enumerator                = identifier ("=" constant-expression)?
    #   struct-declaration        = type-specifier declarator
    #                               ("," declarator)* ";"
    #                             | struct-or-union-specifier ";"  -- anonymous
    #   parameter-type-list       = "void"
    #                             | parameter-declaration
    #                               ("," parameter-declaration)*
    #   parameter-declaration     = type-specifier declarator
    #   declarator                = "*"* direct-declarator
    #   direct-declarator         = (identifier | "(" declarator ")")
    #                               direct-declarator-suffix*
    #   direct-declarator-suffix  = "[" constant-expression? "]"
    #                             | "(" parameter-type-list? ")"
    #   abstract-declarator       = "*"* direct-abstract-declarator?
    #   direct-abstract-declarator = ("(" abstract-declarator ")")?
    #                               direct-declarator-suffix*
    #   compound-statement        = "{" block-item* "}"
    #   block-item                = declaration | statement
    #   declaration               = type-specifier ";"
    #                             | type-specifier init-declarator
    #                               ("," init-declarator)* ";"
    #   init-declarator           = declarator ("=" initializer)?
    #   initializer               = assignment-expression
    #                             | "{" initializer-list ","? "}"
    #   initializer-list          = designation? initializer
    #                               ("," designation? initializer)*
    #   designation               = designator+ "="
    #   designator                = "[" constant-expression "]" | "." identifier
    #   statement                 = labeled-statement | return-statement
    #                             | expression-statement | selection-statement
    #                             | iteration-statement | jump-statement
    #                             | compound-statement
    #   labeled-statement         = identifier ":" statement
    #                             | "case" constant-expression ":" statement
    #                             | "default" ":" statement
    #   return-statement          = "return" expression? ";"
    #   expression-statement      = expression? ";"
    #   selection-statement       = "if" "(" expression ")" statement
    #                               ("else" statement)?
    #                             | "switch" "(" expression ")" statement
    #   iteration-statement       = "while" "(" expression ")" statement
    #                             | "do" statement "while" "(" expression ")" ";"
    #                             | "for" "(" for-init expression? ";"
    #                               expression? ")" statement
    #   for-init                  = declaration | expression? ";"
    #   jump-statement            = "break" ";" | "continue" ";"
    #                             | "goto" identifier ";"
    #   expression                = assignment-expression
    #                               ("," assignment-expression)*
    #   assignment-expression     = conditional-expression
    #                               (("=" | "+=" | "-=" | "*=" | "/=" | "%="
    #                                | "&=" | "|=" | "^=" | "<<=" | ">>=")
    #                                assignment-expression)?
    #   conditional-expression    = logical-OR-expression
    #                               ("?" expression ":" conditional-expression)?
    #   constant-expression       = conditional-expression
    #   logical-OR-expression     = logical-AND-expression
    #                               ("||" logical-AND-expression)*
    #   logical-AND-expression    = inclusive-OR-expression
    #                               ("&&" inclusive-OR-expression)*
    #   inclusive-OR-expression   = exclusive-OR-expression
    #                               ("|" exclusive-OR-expression)*
    #   exclusive-OR-expression   = AND-expression ("^" AND-expression)*
    #   AND-expression            = equality-expression ("&" equality-expression)*
    #   equality-expression       = relational-expression
    #                               (("==" | "!=") relational-expression)*
    #   relational-expression     = shift-expression
    #                               (("<" | ">" | "<=" | ">=") shift-expression)*
    #   shift-expression          = additive-expression
    #                               (("<<" | ">>") additive-expression)*
    #   additive-expression       = multiplicative-expression
    #                               (("+" | "-") multiplicative-expression)*
    #   multiplicative-expression = cast-expression
    #                               (("*" | "/" | "%") cast-expression)*
    #   cast-expression           = "(" type-name ")" cast-expression
    #                             | unary-expression
    #   unary-expression          = ("+" | "-" | "!" | "~" | "&" | "*")* cast-expression
    #                             | ("++" | "--") unary-expression
    #                             | "sizeof" unary-expression
    #                             | "sizeof" "(" type-name ")"
    #   type-name                 = type-specifier abstract-declarator?
    #   postfix-expression        = primary-expression
    #                               ("[" expression "]"
    #                                | "(" argument-expression-list? ")"
    #                                | "." identifier | "->" identifier
    #                                | "++" | "--")*
    #   argument-expression-list  = assignment-expression
    #                               ("," assignment-expression)*
    #   primary-expression        = integer-constant | string-literal
    #                             | identifier | "(" expression ")"
    #
    # Binary precedence levels are parsed by a single table-driven
    # left-associative loop (see #parse_left_associative) rather than one
    # hand-written loop per level, so adding an operator or a precedence
    # tier only requires a new table entry. assignment-expression is
    # right-associative and is handled separately (see #parse_assignment_expression),
    # as is conditional-expression (see #parse_conditional_expression), whose
    # third operand recurses back into itself rather than into the tier above.
    class Parser
      # Punctuator → AST operator tables, one per precedence tier
      # (weakest binding first).
      COMPOUND_ASSIGNMENT_OPERATORS = {
        "+=" => :add, "-=" => :sub, "*=" => :mul, "/=" => :div, "%=" => :mod,
        "&=" => :and, "|=" => :or, "^=" => :xor, "<<=" => :shl, ">>=" => :shr
      }.freeze
      INCLUSIVE_OR_OPERATORS = { "|" => :or }.freeze
      EXCLUSIVE_OR_OPERATORS = { "^" => :xor }.freeze
      AND_OPERATORS = { "&" => :and }.freeze
      EQUALITY_OPERATORS = { "==" => :eq, "!=" => :ne }.freeze
      RELATIONAL_OPERATORS = { "<" => :lt, ">" => :gt, "<=" => :le, ">=" => :ge }.freeze
      # ">>" desugars to an arithmetic shift (:shr here names the source
      # operator, which the generator lowers to a signed :sar); a future
      # unsigned type will lower the same :shr to a logical shift instead.
      SHIFT_OPERATORS = { "<<" => :shl, ">>" => :shr }.freeze
      ADDITIVE_OPERATORS = { "+" => :add, "-" => :sub }.freeze
      MULTIPLICATIVE_OPERATORS = { "*" => :mul, "/" => :div, "%" => :mod }.freeze

      # The keywords that make up an integer/void type-specifier list (a "struct"
      # specifier is handled on its own). A declaration begins with one or more
      # of these; #normalize_type_specifiers collapses the collected multiset
      # into a single Rubycc::Type. "void" is only ever valid as a function's
      # return type or as the target of a pointer; every other use is rejected
      # by #reject_void_type.
      DECL_SPECIFIER_KEYWORDS = %w[void char short int long signed unsigned _Bool].freeze

      # A tag scope entry for an enum tag. C keeps struct, union and enum tags in
      # one shared namespace, so enum tags live in @tag_scopes alongside the
      # StructType objects that stand for struct tags. An enum contributes no
      # distinct type — an enum object is just an int (6.7.2.2) — so this marker
      # only records that the tag names an enum, which lets a later "struct X"
      # (or "enum X" against a struct tag) be diagnosed as the wrong kind of tag.
      EnumTag = Data.define(:tag)

      # An entry in the ordinary-identifier scope (see @ordinary_scopes). `kind`
      # is :typedef for a typedef name (`value` its resolved Rubycc::Type), :enum
      # for an enumeration constant (`value` its Integer value), or :ordinary for
      # a variable, parameter or function name (`value` nil). The ordinary
      # entries carry no payload; they exist only so a declarator can shadow a
      # typedef name or an enum constant of the same name from an outer scope,
      # keeping "typedef int T; { int T; ... }" from misreading the inner T as a
      # type.
      OrdinaryName = Data.define(:kind, :value)

      def initialize(tokens)
        @tokens = tokens
        @pos = 0
        # Struct and enum tags live in their own namespace, separate from
        # variables and functions, and follow the same block scoping.
        # @tag_scopes is a stack of "tag name -> Type::StructType | EnumTag"
        # maps, innermost last, with the file scope at the bottom; a
        # compound-statement (and a for-loop's own parentheses, and a function
        # body) pushes a fresh map so a tag defined inside a block shadows an
        # outer one and vanishes at the block's end. Tag resolution happens here,
        # at parse time, because every other type is built here too — the
        # generator only ever consumes finished Type objects.
        @tag_scopes = [{}]
        # The ordinary-identifier namespace, scoped in lockstep with @tag_scopes:
        # a stack of "name -> OrdinaryName" maps. It records typedef names
        # (resolved to a Type), enum constants (resolved to an Integer) and the
        # plain declarator names that shadow them, so a name is looked up here to
        # decide whether an identifier opens a declaration (a typedef name), folds
        # to a constant (an enumerator) or is an ordinary reference.
        @ordinary_scopes = [{}]
      end

      # Parses the whole translation unit into an AST::Program. An external
      # declaration yields a single node (a function) or, for a comma-separated
      # run of global variables, an array of GlobalDecl; both are flattened into
      # one source-ordered list.
      def parse
        declarations = []
        until peek.eof?
          node = parse_external_declaration
          node.is_a?(Array) ? declarations.concat(node) : declarations << node
        end
        AST::Program.new(declarations)
      end

      private

      def peek
        @tokens[@pos]
      end

      # Looks ahead `offset` tokens without consuming; used to disambiguate a
      # parenthesized declarator from a parameter list, a cast/sizeof type-name
      # from a parenthesized expression, and a labeled statement from an
      # expression-statement.
      def peek_ahead(offset)
        @tokens[@pos + offset]
      end

      def advance
        tok = @tokens[@pos]
        @pos += 1 unless tok.eof?
        tok
      end

      # An external declaration is either a function (a prototype ending in ";"
      # or a definition ending in a compound-statement) or a file-scope variable
      # declaration. Both begin with a type-specifier and a declarator; the
      # declarator's built type settles the form — a function type is the
      # function form (its declarator having read the "(" parameter list), any
      # other type the variable form.
      def parse_external_declaration
        type_tok = peek
        base_type, is_typedef = parse_declaration_specifiers(allow_storage_class: true)

        # "struct point { ... };" (or "struct node;", or a tag-only "enum E { ...
        # };") with no declarator only declares or defines the tag, which the
        # specifier parse already registered; it contributes no object and no
        # code, so it flattens away to an empty run of declarations. A stray
        # "typedef int;" with no declarator flattens away the same way.
        if peek.punct?(";")
          advance
          return []
        end

        # A typedef declaration binds each declarator's name as a type; it
        # yields no object and no code (see #parse_typedef_declaration).
        return parse_typedef_declaration(base_type) if is_typedef

        name_tok, type, function_params = parse_declarator(base_type, allow_incomplete_array: true)

        if type.function?
          parse_function(name_tok, type, function_params, type_tok)
        else
          parse_global_declaration(base_type, name_tok, type)
        end
      end

      # The function form of an external declaration, its declarator already
      # read into `func_type` (a Type::FunctionType) and `params` (the Parameter
      # objects of its outermost function suffix). A ";" is a prototype, a
      # compound-statement a definition. The return type is func_type's — int,
      # char, void or a pointer to any of those (including "void *").
      def parse_function(name_tok, func_type, params, return_tok)
        # A function name is an ordinary identifier at file scope, recorded so an
        # inner block declaring the same name shadows it against a typedef check.
        declare_ordinary_name(name_tok.value)

        if peek.punct?(";")
          advance
          AST::FunctionDecl.new(name_tok.value, func_type.return_type, params, return_tok)
        else
          parse_function_definition(name_tok.value, func_type.return_type, params, return_tok)
        end
      end

      # The file-scope variable form of an external declaration: a
      # comma-separated run of declarators sharing `base_type`, the first of
      # which (`first_type`/`first_name_tok`) has already been read. Each
      # declarator yields one GlobalDecl; the run ends at ";".
      def parse_global_declaration(base_type, first_name_tok, first_type)
        decls = [parse_global_declarator(first_type, first_name_tok)]
        while peek.punct?(",")
          advance
          name_tok, type = parse_declarator(base_type, allow_incomplete_array: true)
          decls << parse_global_declarator(type, name_tok)
        end
        expect_punct(";")
        decls
      end

      # One global declarator's tail, its type (array suffix included) already
      # built: the void/incomplete checks and an optional "=" initializer.
      # A plain scalar-integer initializer is a constant-expression (6.6) folded
      # to a Ruby Integer on the spot (initializer_value). Every other admitted
      # form is deferred to the generator as a raw node (initializer_node): a
      # brace initializer-list for an aggregate or scalar, a string for a char
      # array, or an address constant for a pointer (a null pointer, a "&global",
      # a decayed global array name, or a string literal). A structural
      # initializer also completes an inferred "[]" bound here. A non-constant
      # scalar-integer initializer (a call, another variable, ...) is still
      # rejected with "unsupported initializer for global variable"; the deferred
      # forms the generator cannot fold reach the same diagnostic there.
      def parse_global_declarator(type, name_tok)
        reject_void_type(type, name_tok)
        initializer_value = nil
        initializer_node = nil
        if peek.punct?("=")
          advance # "="
          init = parse_initializer
          if InitializerResolver.structural?(type, init)
            type = InitializerResolver.resolve(type, init).type
            initializer_node = init
          elsif type.integer?
            initializer_value = evaluate_constant_expression(init, "unsupported initializer for global variable")
          else
            initializer_node = init
          end
        elsif type.array? && type.length.nil?
          error_at(name_tok, "array size missing in '#{name_tok.value}'")
        end
        declare_ordinary_name(name_tok.value)
        AST::GlobalDecl.new(name_tok.value, type, initializer_value, initializer_node, name_tok)
      end

      # A bare type-specifier list with no storage class, used everywhere a type
      # is written without a "typedef" in front of it: a struct member, a
      # parameter, and a type-name in a cast or sizeof. It resolves to a single
      # Rubycc::Type, discarding the (always-false) typedef flag.
      def parse_type_specifier
        type, = parse_declaration_specifiers(allow_storage_class: false)
        type
      end

      # declaration-specifiers = (storage-class-specifier | type-specifier)+.
      # Consumes the whole specifier run — an optional "typedef" storage class
      # (6.7.1), which may sit anywhere among the type-specifiers, together with
      # the type itself — and returns [base_type, is_typedef]. The base type any
      # leading "*" run then builds a pointer from is one of: a run of
      # integer/void keywords collected and normalized by
      # #normalize_type_specifiers; a "struct"/"enum" specifier, which resolves
      # or defines its tag; or a single typedef name, an identifier bound to a
      # type in the ordinary namespace. A typedef name is recognized only as the
      # first (and only) type-specifier — once any type keyword has been seen, a
      # following identifier is the declarator, so "int T" declares a variable T
      # even where T names a type (the standard rule that keeps typedef names
      # shadowable). Mixing categories ("unsigned struct", "enum T", ...) is a
      # diagnostic; `allow_storage_class` is false in the contexts a "typedef"
      # cannot appear (a member, a parameter, a type-name).
      def parse_declaration_specifiers(allow_storage_class:)
        start_tok = peek
        specs = []       # collected integer/void keyword strings
        composite = nil  # a struct/enum/typedef-name Type (excludes `specs`)
        is_typedef = false
        loop do
          tok = peek
          if tok.keyword?("typedef")
            error_at(tok, "'typedef' is not allowed here") unless allow_storage_class
            error_at(tok, "duplicate 'typedef'") if is_typedef
            is_typedef = true
            advance
          elsif tok.type == :keyword && DECL_SPECIFIER_KEYWORDS.include?(tok.value)
            error_at(tok, "two or more data types in declaration specifiers") if composite
            specs << advance.value
          elsif tok.keyword?("struct") || tok.keyword?("union")
            error_at(tok, "two or more data types in declaration specifiers") if composite || !specs.empty?
            composite = parse_struct_or_union_specifier
          elsif tok.keyword?("enum")
            error_at(tok, "two or more data types in declaration specifiers") if composite || !specs.empty?
            composite = parse_enum_specifier
          elsif composite.nil? && specs.empty? && tok.type == :ident && typedef_name?(tok.value)
            composite = lookup_ordinary(tok.value).value
            advance
          else
            break
          end
        end

        if composite
          [composite, is_typedef]
        else
          error_at(start_tok, "expected type specifier") if specs.empty?
          [normalize_type_specifiers(specs, start_tok), is_typedef]
        end
      end

      # Collapses a multiset of integer type-specifier keywords (in any order:
      # "unsigned long", "long unsigned int", "long long int", ...) into a
      # single Rubycc::Type per 6.7.2. `void` and `_Bool` stand alone;
      # signed/unsigned choose the signedness; short/long (up to two longs, LP64
      # folding "long long" onto "long") and int/char choose the width, with a
      # bare "signed"/"unsigned" meaning int. Every ill-formed combination
      # ("short char", "long short", "signed unsigned", ...) is a diagnostic.
      def normalize_type_specifiers(specs, tok)
        counts = Hash.new(0)
        specs.each { |s| counts[s] += 1 }

        return normalize_standalone(Type::Void, "void", specs, tok) if counts["void"].positive?
        return normalize_standalone(Type::Bool, "_Bool", specs, tok) if counts["_Bool"].positive?

        signed = counts["signed"].positive?
        unsigned = counts["unsigned"].positive?
        short = counts["short"].positive?
        long = counts["long"]
        %w[signed unsigned short int char].each do |kw|
          error_at(tok, "duplicate '#{kw}'") if counts[kw] > 1
        end
        error_at(tok, "both 'signed' and 'unsigned' in declaration specifiers") if signed && unsigned
        error_at(tok, "more than two 'long's in declaration specifiers") if long > 2

        if counts["char"].positive?
          if short || long.positive? || counts["int"].positive?
            error_at(tok, "both 'char' and a size specifier in declaration specifiers")
          end
          return unsigned ? Type::UChar : Type::Char
        end

        error_at(tok, "both 'short' and 'long' in declaration specifiers") if short && long.positive?

        if short
          unsigned ? Type::UShort : Type::Short
        elsif long.positive?
          unsigned ? Type::ULong : Type::Long
        else
          unsigned ? Type::UInt : Type::Int
        end
      end

      # `void` and `_Bool` cannot combine with any other type-specifier keyword;
      # each must be the whole list.
      def normalize_standalone(type, keyword, specs, tok)
        unless specs == [keyword]
          error_at(tok, "cannot combine '#{keyword}' with other type specifiers")
        end
        type
      end

      # struct-or-union-specifier: a "struct" or "union" keyword (the two differ
      # only in the aggregate's `kind` and thus its layout), an optional tag,
      # and an optional "{ ... }" body. Three shapes result:
      #   * "struct tag { ... }" / "struct { ... }" — a definition; the tagged
      #     one is registered (or completed) in the current tag scope, an
      #     anonymous one is a fresh unnamed type. #parse_struct_body lays it out.
      #   * "struct tag" — a reference; resolved through the tag scopes, or, when
      #     the tag is unknown, forward-declared as an incomplete aggregate in
      #     the current scope (so "struct node;" and a pointer to a
      #     not-yet-defined tag both work — the union spellings behave alike).
      def parse_struct_or_union_specifier
        keyword_tok = advance # "struct" or "union"
        kind = keyword_tok.value == "union" ? :union : :struct
        tag_tok = peek.type == :ident ? advance : nil
        tag = tag_tok&.value

        if peek.punct?("{")
          struct_type = tag ? define_struct_tag(tag, kind, keyword_tok) : Type::StructType.new(nil, kind: kind)
          parse_struct_body(struct_type)
          struct_type
        elsif tag
          reference_struct_tag(tag, kind, tag_tok)
        else
          error_at(keyword_tok, "expected identifier or '{' after '#{keyword_tok.value}'")
        end
      end

      # enum-specifier (6.7.2.2): "enum identifier? { enumerator-list ,? }"
      # defines the enumeration (registering the tag, if named, and every
      # enumerator as an int constant in the current ordinary scope), while
      # "enum identifier" references a previously defined enum tag. Either way an
      # enum object is an int, so the specifier resolves to Type::Int and no
      # dedicated enum type exists. Unlike a struct, an enum has no incomplete
      # form: a reference to a tag with no visible definition is an error on the
      # spot, since an int-sized object cannot be laid out from an unknown set of
      # constants.
      def parse_enum_specifier
        enum_tok = advance # "enum"
        tag_tok = peek.type == :ident ? advance : nil
        tag = tag_tok&.value

        if peek.punct?("{")
          register_enum_tag(tag, tag_tok) if tag
          parse_enum_body
          Type::Int
        elsif tag
          resolve_enum_tag(tag, tag_tok)
        else
          error_at(enum_tok, "expected identifier or '{' after 'enum'")
        end
      end

      # Registers an enum tag being defined in the current scope. A name already
      # taken there by another enum is a redefinition; one taken by a struct tag
      # is the wrong kind of tag (struct, union and enum share one namespace).
      def register_enum_tag(tag, token)
        existing = @tag_scopes.last[tag]
        if existing
          if existing.is_a?(EnumTag)
            error_at(token, "redefinition of 'enum #{tag}'")
          else
            error_at(token, "'#{tag}' defined as wrong kind of tag")
          end
        end
        @tag_scopes.last[tag] = EnumTag.new(tag)
      end

      # Resolves a bare "enum tag" reference (innermost scope outward) to
      # Type::Int. A tag bound to a struct is the wrong kind of tag; a tag with
      # no visible binding at all is undefined — an enum type cannot be used
      # incomplete, so this is an error rather than a forward declaration.
      def resolve_enum_tag(tag, token)
        @tag_scopes.reverse_each do |scope|
          found = scope[tag]
          next unless found

          error_at(token, "'#{tag}' defined as wrong kind of tag") unless found.is_a?(EnumTag)
          return Type::Int
        end
        error_at(token, "use of undefined enum '#{tag}'")
      end

      # Parses "{ enumerator-list ,? }" (the enumerator-list must be non-empty).
      # Each enumerator takes the previous value plus one, the first being 0,
      # unless it names an explicit "= constant"; the folded value is bound as an
      # int enum constant in the current ordinary scope. A trailing comma before
      # "}" is allowed (C99).
      def parse_enum_body
        expect_punct("{")
        next_value = 0
        loop do
          name_tok = expect_ident
          value = next_value
          if peek.punct?("=")
            advance # "="
            expr = parse_conditional_expression
            value = evaluate_constant_expression(expr, "enumerator value is not an integer constant")
          end
          declare_enum_constant(name_tok, value)
          next_value = value + 1
          break unless peek.punct?(",")

          advance # ","
          break if peek.punct?("}") # trailing comma ends the list
        end
        expect_punct("}")
      end

      # Binds an enumerator's name to its value as an int constant in the current
      # ordinary scope. A name already bound there — by another enumerator or by
      # a variable — is a redefinition.
      def declare_enum_constant(name_tok, value)
        if @ordinary_scopes.last.key?(name_tok.value)
          error_at(name_tok, "redefinition of '#{name_tok.value}'")
        end
        @ordinary_scopes.last[name_tok.value] = OrdinaryName.new(:enum, value)
      end

      # Resolves the tag being *defined* to the StructType #parse_struct_body
      # will lay out. A tag already declared in the *current* scope is reused
      # (completing an earlier "struct tag;" forward declaration or the
      # in-progress self-reference), unless it is already complete, which makes
      # the second body a redefinition. A tag already taken by a differing kind
      # (an enum, or the other of struct/union) is the wrong kind of tag. An
      # unknown tag is created incomplete and registered up front — before its
      # body is parsed — so a member that points back at the same tag ("struct
      # node *next;") resolves to this very object.
      def define_struct_tag(tag, kind, token)
        existing = @tag_scopes.last[tag]
        if existing
          reject_wrong_tag_kind(existing, kind, tag, token)
          error_at(token, "redefinition of '#{tag_keyword(kind)} #{tag}'") if existing.complete?
          return existing
        end
        struct_type = Type::StructType.new(tag, kind: kind)
        @tag_scopes.last[tag] = struct_type
        struct_type
      end

      # Resolves a bare "struct tag" reference. An in-scope tag (searched
      # innermost outward) is returned as is — complete or not — provided it is
      # the same kind of aggregate; a tag bound to an enum or the other of
      # struct/union is the wrong kind of tag. An unknown tag is forward-declared:
      # a fresh incomplete aggregate of this kind is registered in the current
      # scope, so "struct node;" introduces the tag and "struct node *p;" names a
      # pointer to an as-yet-undefined struct.
      def reference_struct_tag(tag, kind, token)
        @tag_scopes.reverse_each do |scope|
          found = scope[tag]
          next unless found

          reject_wrong_tag_kind(found, kind, tag, token)
          return found
        end
        struct_type = Type::StructType.new(tag, kind: kind)
        @tag_scopes.last[tag] = struct_type
        struct_type
      end

      # Rejects a tag whose existing binding disagrees with the kind now written
      # for it: struct, union and enum share one namespace (6.7.2.3), so "union
      # S" against a "struct S", or either against an "enum S", is the wrong kind
      # of tag. An enum binding is an EnumTag; a struct/union binding is a
      # StructType told apart by #union?.
      def reject_wrong_tag_kind(existing, kind, tag, token)
        wrong = existing.is_a?(EnumTag) || existing.union? != (kind == :union)
        error_at(token, "'#{tag}' defined as wrong kind of tag") if wrong
      end

      # The keyword spelling for an aggregate kind, for diagnostics.
      def tag_keyword(kind)
        kind == :union ? "union" : "struct"
      end

      # Parses a struct/union's "{ struct-declaration+ }" body and lays
      # `struct_type` out. A struct-declaration is either a type-specifier
      # followed by one or more comma-separated declarators (each contributing a
      # "*" run and an optional array suffix), just like a local declaration but
      # with no initializer, or — for an anonymous member (C11 6.7.2.1p13) — a
      # tagless struct/union specifier with no declarator at all. A named member
      # may not be void, an incomplete aggregate by value, or a duplicate name;
      # a pointer to an incomplete struct (the self-referential case) is fine,
      # since a pointer is always complete. `seen` tracks every member name
      # visible from this body, folding in the names an anonymous member exposes
      # transparently, so a collision through one is diagnosed like any other.
      def parse_struct_body(struct_type)
        expect_punct("{")
        raw_members = []
        seen = {}
        until peek.punct?("}")
          spec_tok = peek
          member_base = parse_type_specifier
          if peek.punct?(";")
            parse_anonymous_member(member_base, spec_tok, raw_members, seen)
          else
            parse_member_declarators(member_base, raw_members, seen)
          end
          expect_punct(";")
        end
        expect_punct("}")
        struct_type.define(raw_members)
      end

      # A struct-declaration with no declarator. It is well-formed only as an
      # anonymous member — a tagless struct/union specifier (its type is an
      # aggregate with no tag); a tagged specifier standing alone ("struct Inner
      # {...};" or "struct Inner;" inside a body) or any other bare type
      # declares nothing and is rejected. The member is recorded with a nil name
      # and its inner type; every name it exposes transparently is added to
      # `seen` so a later member cannot shadow one of them.
      def parse_anonymous_member(member_base, spec_tok, raw_members, seen)
        unless member_base.struct? && member_base.tag.nil?
          error_at(spec_tok, "declaration does not declare anything")
        end
        transparent_member_names(member_base).each do |name|
          error_at(spec_tok, "duplicate member '#{name}'") if seen.key?(name)
          seen[name] = true
        end
        raw_members << [nil, member_base]
      end

      # The comma-separated declarators sharing `member_base`, each a named
      # member with its own declarator (a "*" run, an array suffix, or a
      # function-pointer shape such as "int (*handler)(int)"). A member may not
      # be a bare function; a pointer to one is fine. Each name is checked for a
      # duplicate against `seen` (which already holds any transparently exposed
      # names) and then added to it.
      def parse_member_declarators(member_base, raw_members, seen)
        loop do
          name_tok, type = parse_declarator(member_base)
          error_at(name_tok, "field '#{name_tok.value}' declared as a function") if type.function?
          reject_void_type(type, name_tok)
          reject_incomplete_member(type, name_tok)
          error_at(name_tok, "duplicate member '#{name_tok.value}'") if seen.key?(name_tok.value)
          seen[name_tok.value] = true
          raw_members << [name_tok.value, type]
          break unless peek.punct?(",")

          advance
        end
      end

      # Every member name an anonymous member exposes to its enclosing
      # aggregate: its own named members, plus (recursively) the names its own
      # anonymous members expose. `struct_type` is already laid out here, so its
      # members are known.
      def transparent_member_names(struct_type)
        struct_type.members.flat_map do |m|
          if m.name.nil? && m.type.struct?
            transparent_member_names(m.type)
          else
            [m.name]
          end
        end
      end

      # Rejects a struct member declared with an incomplete struct type by
      # value (a whole "struct node" inside "struct node", or before the tag is
      # defined): its size is unknown, so the layout could not place the fields
      # after it. An array of such a type is rejected for the same reason; a
      # pointer to it is allowed.
      def reject_incomplete_member(type, token)
        incomplete = (type.struct? && !type.complete?) ||
                     (type.array? && type.element.struct? && !type.element.complete?)
        error_at(token, "field '#{token.value}' has incomplete type") if incomplete
      end

      # Whether `token` opens a declaration, letting block-item and for-init tell
      # a declaration from a statement, and the cast/sizeof parsers tell a
      # type-name from a parenthesized expression. A declaration begins with an
      # integer/void type-specifier keyword, "struct"/"enum", the "typedef"
      # storage class, or a typedef name — an identifier bound to a type in the
      # ordinary namespace whose innermost binding is not shadowed by a variable.
      def type_specifier?(token)
        if token.type == :keyword
          return DECL_SPECIFIER_KEYWORDS.include?(token.value) ||
                 token.value == "struct" || token.value == "union" ||
                 token.value == "enum" || token.value == "typedef"
        end
        token.type == :ident && typedef_name?(token.value)
      end

      # Rejects `type` when it denotes a bare void or an array of void: this
      # subset only allows "void" as a function's return type or as the target
      # of a pointer ("void *", "void **", ...), so a void variable, global,
      # array element or (non-pointer) parameter is an error.
      def reject_void_type(type, token)
        return unless type.void? || (type.array? && type.element.void?)

        error_at(token, "variable or field declared void")
      end

      def parse_function_definition(name, return_type, params, return_tok)
        # A definition, unlike a prototype, must name each parameter so its
        # value can be bound in the body.
        params.each do |param|
          error_at(param.token, "parameter name omitted") if param.name.nil?
        end
        expect_punct("{")
        # The body is a block, so it owns a tag scope and an ordinary scope: a
        # struct or typedef defined in one function's body is invisible to the
        # next. The parameters live in this body scope as ordinary names, so a
        # parameter shadows an outer typedef of the same name inside the body.
        @tag_scopes.push({})
        @ordinary_scopes.push({})
        params.each { |param| declare_ordinary_name(param.name) }
        body = []
        body.concat(parse_block_item) until peek.punct?("}")
        @ordinary_scopes.pop
        @tag_scopes.pop
        expect_punct("}")
        AST::FunctionDef.new(name, return_type, params, body, return_tok)
      end

      # Returns an array of AST::Parameter; empty for "()" or "(void)". A bare
      # "void" only means "no parameters" when it is the entire list (followed
      # immediately by ")"); "void *" or a later "void" parameter falls through
      # to parse_parameter_declaration, which rejects a non-pointer void.
      def parse_parameter_type_list
        return [] if peek.punct?(")")
        if peek.keyword?("void") && peek_ahead(1)&.punct?(")")
          advance
          return []
        end

        params = [parse_parameter_declaration]
        while peek.punct?(",")
          advance
          params << parse_parameter_declaration
        end
        params
      end

      # parameter-declaration = type-specifier declarator?, the declarator being
      # a full (possibly abstract) one whose name is optional (:optional mode)
      # so prototypes may omit it. The parsed type is then adjusted per 6.7.6.3
      # (an array becomes a pointer to its element, a function a pointer to
      # itself), so "int a[10]" is "int *a" and "int g(int)" is "int (*g)(int)".
      # An unnamed parameter is located by its type-specifier keyword for
      # diagnostics.
      def parse_parameter_declaration
        type_tok = peek
        name_tok, type = parse_declarator(parse_type_specifier, name_mode: :optional)
        type = adjust_parameter_type(type)
        reject_void_type(type, name_tok || type_tok)
        if name_tok
          AST::Parameter.new(name_tok.value, type, name_tok)
        else
          AST::Parameter.new(nil, type, type_tok)
        end
      end

      # Returns an array of nodes: a declaration expands to one VariableDecl
      # per init-declarator, while a statement always yields exactly one node.
      def parse_block_item
        if type_specifier?(peek)
          parse_declaration
        else
          [parse_statement]
        end
      end

      def parse_declaration
        base_type, is_typedef = parse_declaration_specifiers(allow_storage_class: true)

        # A bare "struct point { ... };" (or "struct node;", or a tag-only "enum
        # E { ... };") inside a block just declares or defines the tag, adding no
        # local; it yields no items.
        if peek.punct?(";")
          advance
          return []
        end

        # A local typedef binds names as types in this block's scope; like a
        # file-scope typedef it yields no items.
        return parse_typedef_declaration(base_type) if is_typedef

        decls = [parse_init_declarator(base_type)]
        while peek.punct?(",")
          advance
          decls << parse_init_declarator(base_type)
        end
        expect_punct(";")
        decls
      end

      # A typedef declaration: a run of comma-separated declarators sharing
      # `base_type`, each binding its name as a type (its "*" run and array
      # suffix applied) in the current ordinary scope. A typedef declarator may
      # not have an initializer (6.7.1); the declaration itself contributes no
      # AST node, so this returns an empty run.
      def parse_typedef_declaration(base_type)
        loop do
          name_tok, type = parse_declarator(base_type)
          if peek.punct?("=")
            error_at(peek, "typedef '#{name_tok.value}' must not be initialized")
          end
          declare_typedef_name(name_tok, type)
          break unless peek.punct?(",")

          advance # ","
        end
        expect_punct(";")
        []
      end

      def parse_init_declarator(base_type)
        name_tok, type = parse_declarator(base_type, allow_incomplete_array: true)
        reject_void_type(type, name_tok)
        initializer = nil
        if peek.punct?("=")
          advance # "="
          initializer = parse_initializer
          # A structural initializer (a brace list, or a string for a char array)
          # fixes the object's type — completing an inferred "[]" bound — and is
          # validated for shape here, so a later stage sees a finished type.
          if InitializerResolver.structural?(type, initializer)
            type = InitializerResolver.resolve(type, initializer).type
          end
        elsif type.array? && type.length.nil?
          error_at(name_tok, "array size missing in '#{name_tok.value}'")
        end
        declare_ordinary_name(name_tok.value)
        AST::VariableDecl.new(name_tok.value, type, initializer, name_tok)
      end

      # initializer = assignment-expression | "{" initializer-list ","? "}"
      # (6.7.9). A "{" opens a brace list; anything else is a single assignment
      # expression (a scalar's value, or a whole string literal for a char
      # array). The resolver later matches the shape against the object's type.
      def parse_initializer
        return parse_initializer_list if peek.punct?("{")

        parse_assignment_expression
      end

      # initializer-list = designation? initializer ("," designation? initializer)*
      # with an optional trailing comma before "}". Each element becomes an
      # InitItem pairing its (possibly empty) designator chain with its value,
      # which may itself be a nested brace list.
      def parse_initializer_list
        brace_tok = expect_punct("{")
        items = []
        until peek.punct?("}")
          designators = parse_designation
          value = parse_initializer
          items << AST::InitItem.new(designators, value)
          break unless peek.punct?(",")

          advance # ","
        end
        expect_punct("}")
        AST::InitializerList.new(items, brace_tok)
      end

      # designation = designator+ "=", where designator is "[" constant-expression
      # "]" or "." identifier (6.7.9). Returns the designator chain, or an empty
      # array when the next element is positional (no leading "[" or "."). An
      # array designator's index is folded to a Ruby Integer on the spot, like an
      # array bound.
      def parse_designation
        return [] unless peek.punct?("[") || peek.punct?(".")

        designators = []
        loop do
          if peek.punct?("[")
            bracket_tok = advance # "["
            expr = parse_conditional_expression
            index = evaluate_constant_expression(expr, "array designator is not an integer constant")
            expect_punct("]")
            designators << AST::ArrayDesignator.new(index, bracket_tok)
          elsif peek.punct?(".")
            dot_tok = advance # "."
            name_tok = expect_ident
            designators << AST::MemberDesignator.new(name_tok.value, dot_tok)
          else
            break
          end
        end
        expect_punct("=")
        designators
      end

      # Parses a full declarator (6.7.6) and applies it to `base`, returning
      # [name_token_or_nil, type, function_params]. The declarator is read
      # syntactically and turned into a proc that wraps `base` inside-out (see
      # #parse_declarator_builder); `type` is that proc applied to `base`, and
      # `function_params` is the parameter list of the function suffix attached
      # directly to the declared name when the result is a function type (a
      # function definition or prototype needs those Parameter objects), nil
      # otherwise.
      #
      # `name_mode` governs the identifier: :required in an ordinary declaration
      # (a missing name is an error), :optional in a parameter (the name may be
      # omitted), or :forbidden in a type-name (a cast or sizeof, which never
      # names anything). `allow_incomplete_array` admits a trailing "[]" whose
      # length an initializer will infer.
      def parse_declarator(base, name_mode: :required, allow_incomplete_array: false)
        name_tok, build, function_params =
          parse_declarator_builder(name_mode: name_mode, allow_incomplete_array: allow_incomplete_array)
        [name_tok, build.call(base), function_params]
      end

      # declarator = pointer? direct-declarator. Parses the leading "*" run and
      # the direct-declarator, returning [name_token, build, function_params]
      # where `build` maps a base type to the declared type. The pointer prefix
      # is the outermost derivation textually but binds looser than the postfix
      # "()"/"[]", so it wraps the *base* first (becoming the innermost target,
      # e.g. the return or element type) and the direct-declarator's suffixes
      # then wrap that — which is exactly why "int *f(int)" is a function
      # returning "int *" while "int (*f)(int)" is a pointer to a function.
      def parse_declarator_builder(name_mode:, allow_incomplete_array:)
        star_count = 0
        star_count += 1 while consume_punct("*")
        name_tok, direct_build, function_params =
          parse_direct_declarator(name_mode: name_mode, allow_incomplete_array: allow_incomplete_array)
        build = lambda do |base|
          type = base
          star_count.times { type = Type::Pointer.new(type) }
          direct_build.call(type)
        end
        [name_tok, build, function_params]
      end

      # direct-declarator = (identifier | "(" declarator ")") suffix*, where a
      # suffix is a "[" size? "]" array or a "(" parameter-type-list? ")"
      # function. Returns [name_token, build, function_params].
      #
      # The core is a parenthesized declarator when a "(" is followed by a token
      # that opens a declarator (see #paren_starts_declarator?), an identifier
      # when one is present and the mode admits a name, or empty (an abstract
      # declarator's or an unnamed parameter's missing name). The suffixes bind
      # tighter than the pointer prefix and than an enclosing paren's suffix, so
      # `build` applies them to the base before the core — and, since a later
      # suffix binds tighter than an earlier one ("a[2][3]"), in reverse textual
      # order.
      #
      # `function_params` reports the parameter list of the function suffix
      # attached directly to the name: it is this level's first suffix when the
      # core is the identifier (or is absent), but the *inner* declarator's when
      # the core is parenthesized, so a name buried inside parentheses still
      # surfaces the suffix that makes it a function ("int (*g(int a))(int b)"
      # reports "int a", g's own parameters, not "int b").
      def parse_direct_declarator(name_mode:, allow_incomplete_array:)
        name_tok, core_build, inner_params = parse_declarator_core(name_mode: name_mode)

        suffixes = []
        loop do
          if peek.punct?("[")
            suffixes << parse_array_suffix(allow_incomplete: allow_incomplete_array)
          elsif peek.punct?("(")
            suffixes << parse_function_suffix
          else
            break
          end
        end

        build = lambda do |base|
          type = base
          suffixes.reverse_each { |suffix| type = apply_declarator_suffix(suffix, type) }
          core_build.call(type)
        end

        # A parenthesized core forwards the buried name's own function suffix;
        # every other core takes this level's outermost (first textual) suffix.
        function_params =
          if inner_params != :none
            inner_params
          elsif suffixes.first&.first == :function
            suffixes.first[1]
          end
        [name_tok, build, function_params]
      end

      # The core of a direct-declarator, returning [name_token, build,
      # inner_params]. `inner_params` is the parenthesized inner declarator's
      # function_params when the core is "( declarator )", or the sentinel :none
      # when the core is an identifier or empty (so #parse_direct_declarator
      # knows whether to forward a buried name's suffix or read its own).
      def parse_declarator_core(name_mode:)
        if peek.punct?("(") && paren_starts_declarator?
          advance # "("
          name_tok, build, inner_params =
            parse_declarator_builder(name_mode: name_mode, allow_incomplete_array: false)
          expect_punct(")")
          [name_tok, build, inner_params]
        elsif peek.type == :ident && name_mode != :forbidden
          name_tok = advance
          [name_tok, ->(base) { base }, :none]
        elsif name_mode == :required
          error_at(peek, "expected identifier")
        else
          # An abstract declarator or an unnamed parameter: no core, so the type
          # is whatever the suffixes and pointer prefix make of the base.
          [nil, ->(base) { base }, :none]
        end
      end

      # Whether a "(" at the core position opens a parenthesized declarator
      # rather than a function suffix's parameter list. It does exactly when the
      # following token begins a declarator — a "*", a "[", a nested "(", or an
      # identifier that is not a typedef name (a declared or redundantly
      # parenthesized name) — which is what disambiguates "int (*f)(int)" (a
      # parenthesized "*f") from the abstract "int (int)" (a function taking an
      # int). A type-specifier, a typedef name or a ")" after the "(" instead
      # opens a parameter list.
      def paren_starts_declarator?
        nxt = peek_ahead(1)
        return false if nxt.nil?
        return true if nxt.punct?("*") || nxt.punct?("[") || nxt.punct?("(")

        nxt.type == :ident && !typedef_name?(nxt.value)
      end

      # A direct-declarator's array suffix "[" size? "]". A bracketed length is
      # a constant-expression (6.6) folded to a positive Ruby Integer. When
      # `allow_incomplete` is set (a variable or global with an initializer),
      # empty brackets "[]" leave the length nil for the initializer resolver to
      # infer (6.7.9p22); everywhere else "[]" is an error. Returns a suffix
      # descriptor [:array, length, bracket_token] applied later by
      # #apply_declarator_suffix.
      def parse_array_suffix(allow_incomplete:)
        bracket_tok = advance # "["
        if peek.punct?("]")
          error_at(bracket_tok, "array size must be an integer constant") unless allow_incomplete
          advance # "]"
          length = nil
        else
          expr = parse_conditional_expression
          length = evaluate_constant_expression(expr, "array size must be an integer constant")
          expect_punct("]")
          error_at(expr.token, "array size must be positive") unless length.positive?
        end
        [:array, length, bracket_tok]
      end

      # A direct-declarator's function suffix "(" parameter-type-list? ")". The
      # parameters are parsed (and array/function ones adjusted, see
      # #parse_parameter_declaration) here so the suffix can both build the
      # function type and, when it belongs to a real function, hand its
      # Parameter objects back for the body. Returns [:function, params,
      # paren_token].
      def parse_function_suffix
        paren_tok = advance # "("
        params = parse_parameter_type_list
        expect_punct(")")
        [:function, params, paren_tok]
      end

      # Wraps `inner` in one declarator suffix, enforcing the constraints a
      # function or array derivation cannot satisfy (6.7.6.3): a function's
      # return type may be neither a function nor an array, an array's element
      # may not be a function, and (this subset) an array's element may not be
      # another array. The suffix's own token (the "(" or "[") locates any
      # diagnostic.
      def apply_declarator_suffix(suffix, inner)
        kind, data, tok = suffix
        if kind == :function
          error_at(tok, "function returning a function is not allowed") if inner.function?
          error_at(tok, "function returning an array is not allowed") if inner.array?
          Type::FunctionType.new(inner, data.map(&:type))
        else
          error_at(tok, "array of functions is not allowed") if inner.function?
          error_at(tok, "multidimensional arrays are not supported yet") if inner.array?
          Type::Array.new(inner, data)
        end
      end

      # A parameter's declared type after the adjustments of 6.7.6.3: an array
      # parameter is adjusted to a pointer to its element ("int a[10]" is
      # "int *a") and a function parameter to a pointer to that function
      # ("int g(int)" is "int (*g)(int)"), so a call passes an address in either
      # case. Every other type is left as written.
      def adjust_parameter_type(type)
        if type.array?
          Type::Pointer.new(type.element)
        elsif type.function?
          Type::Pointer.new(type)
        else
          type
        end
      end

      # Consumes and reports a punctuator when it is next, leaving the stream
      # untouched otherwise; lets the "*" run read one star at a time.
      def consume_punct(str)
        return false unless peek.punct?(str)

        advance
        true
      end

      def parse_statement
        if peek.keyword?("return")
          parse_return
        elsif peek.keyword?("if")
          parse_selection_statement
        elsif peek.keyword?("switch")
          parse_switch_statement
        elsif peek.keyword?("case")
          parse_case_statement
        elsif peek.keyword?("default")
          parse_default_statement
        elsif peek.keyword?("while")
          parse_while_statement
        elsif peek.keyword?("do")
          parse_do_while_statement
        elsif peek.keyword?("for")
          parse_for_statement
        elsif peek.keyword?("break")
          parse_break_statement
        elsif peek.keyword?("continue")
          parse_continue_statement
        elsif peek.keyword?("goto")
          parse_goto_statement
        elsif peek.punct?("{")
          parse_compound_statement
        # A bare identifier immediately followed by ":" opens a labeled
        # statement (a goto target); this two-token lookahead is what tells it
        # apart from an expression-statement that merely begins with a name.
        elsif peek.type == :ident && peek_ahead(1)&.punct?(":")
          parse_labeled_statement
        else
          parse_expression_statement
        end
      end

      # "return;" (a void return, `expr` nil) or "return expression;"; whether
      # a void function may omit the value (and a non-void one may not) is the
      # generator's job.
      def parse_return
        ret_tok = advance # "return"
        expr = peek.punct?(";") ? nil : parse_expression
        expect_punct(";")
        AST::Return.new(expr, ret_tok)
      end

      # "else" binds to the nearest preceding "if": since the else clause is
      # consumed eagerly by the innermost recursive call, dangling-else
      # resolves the standard C way without extra bookkeeping.
      def parse_selection_statement
        if_tok = advance # "if"
        expect_punct("(")
        condition = parse_expression
        expect_punct(")")
        then_stmt = parse_statement
        else_stmt = nil
        if peek.keyword?("else")
          advance
          else_stmt = parse_statement
        end
        AST::If.new(condition, then_stmt, else_stmt, if_tok)
      end

      def parse_while_statement
        while_tok = advance # "while"
        expect_punct("(")
        condition = parse_expression
        expect_punct(")")
        body = parse_statement
        AST::While.new(condition, body, while_tok)
      end

      def parse_do_while_statement
        do_tok = advance # "do"
        body = parse_statement
        expect_keyword("while")
        expect_punct("(")
        condition = parse_expression
        expect_punct(")")
        expect_punct(";")
        AST::DoWhile.new(body, condition, do_tok)
      end

      def parse_for_statement
        for_tok = advance # "for"
        expect_punct("(")
        # C99 gives the for-loop's own parentheses a scope, so a tag, a typedef
        # or a variable declared in clause-1 is visible only through the loop.
        @tag_scopes.push({})
        @ordinary_scopes.push({})
        init = parse_for_init
        condition = peek.punct?(";") ? nil : parse_expression
        expect_punct(";")
        step = peek.punct?(")") ? nil : parse_expression
        expect_punct(")")
        body = parse_statement
        @ordinary_scopes.pop
        @tag_scopes.pop
        AST::For.new(init, condition, step, body, for_tok)
      end

      # Parses the for-loop's first clause, consuming its trailing ";" (a
      # declaration already does so; the other two branches do it explicitly).
      def parse_for_init
        if type_specifier?(peek)
          parse_declaration
        elsif peek.punct?(";")
          advance
          nil
        else
          expr = parse_expression
          expect_punct(";")
          expr
        end
      end

      def parse_break_statement
        break_tok = advance # "break"
        expect_punct(";")
        AST::Break.new(break_tok)
      end

      def parse_continue_statement
        continue_tok = advance # "continue"
        expect_punct(";")
        AST::Continue.new(continue_tok)
      end

      # "goto identifier;": an unconditional jump to a label defined elsewhere
      # in the same function. Only the target's name is captured here; whether
      # it names a defined label is the generator's check, since the label may
      # appear textually after the goto (a forward jump).
      def parse_goto_statement
        goto_tok = advance # "goto"
        name_tok = expect_ident
        expect_punct(";")
        AST::Goto.new(name_tok.value, goto_tok)
      end

      # "switch (expression) statement": the controlling expression and the body
      # in which case/default labels sit. The body is one statement (typically a
      # compound-statement); the parser does not check that any case is present
      # or well-placed — the generator collects the labels and diagnoses misuse.
      def parse_switch_statement
        switch_tok = advance # "switch"
        expect_punct("(")
        control = parse_expression
        expect_punct(")")
        body = parse_statement
        AST::Switch.new(control, body, switch_tok)
      end

      # "case constant-expression : statement". The case constant is parsed as
      # a conditional-expression — constant-expression's production (6.6) — and
      # folded to a Ruby Integer on the spot; the labeled statement follows the
      # colon. A conditional operand's own ":" (as in "case 1 ? 2 : 3:") is
      # consumed by conditional-expression itself, leaving exactly the label's
      # ":" for #expect_punct here. Whether this case sits inside a switch, and
      # whether its value is unique, is left to the generator.
      def parse_case_statement
        case_tok = advance # "case"
        expr = parse_conditional_expression
        value = evaluate_constant_expression(expr, "case label does not reduce to an integer constant")
        expect_punct(":")
        body = parse_statement
        AST::Case.new(value, body, case_tok)
      end

      # "default : statement": the fall-through label of a switch, carrying no
      # constant. At most one may appear per switch, which the generator checks.
      def parse_default_statement
        default_tok = advance # "default"
        expect_punct(":")
        body = parse_statement
        AST::Default.new(body, default_tok)
      end

      # "identifier : statement": a labeled statement, the target of a goto. The
      # identifier and its ":" have already been confirmed by the two-token
      # lookahead in #parse_statement; the prefixed statement follows.
      def parse_labeled_statement
        name_tok = advance # identifier
        advance # ":"
        body = parse_statement
        AST::Label.new(name_tok.value, body, name_tok)
      end

      def parse_compound_statement
        brace_tok = expect_punct("{")
        # A nested block introduces its own tag and ordinary scopes, mirroring
        # its variable scope: a struct, an enum constant or a typedef defined
        # here shadows an outer one and is gone at "}".
        @tag_scopes.push({})
        @ordinary_scopes.push({})
        items = []
        items.concat(parse_block_item) until peek.punct?("}")
        @ordinary_scopes.pop
        @tag_scopes.pop
        expect_punct("}")
        AST::Block.new(items, brace_tok)
      end

      def parse_expression_statement
        tok = peek
        if tok.punct?(";")
          advance
          AST::EmptyStmt.new(tok)
        else
          expr = parse_expression
          expect_punct(";")
          AST::ExpressionStmt.new(expr, tok)
        end
      end

      # expression = assignment-expression ("," assignment-expression)*: the
      # comma operator, left-associative. Each left operand is evaluated for its
      # side effects and discarded; the last operand's value and type are the
      # whole expression's. Every context where a comma is a *separator* rather
      # than the operator (a call's arguments, a run of declarators, a global
      # initializer) bypasses this and calls #parse_assignment_expression
      # directly, so those commas keep their meaning; only the contexts that
      # take a full expression (a parenthesized expression, a subscript, an
      # expression-statement, the for-clauses, a control condition, a return,
      # the middle of "?:") reach the comma operator here.
      def parse_expression
        node = parse_assignment_expression
        while peek.punct?(",")
          tok = advance
          node = AST::Comma.new(node, parse_assignment_expression, tok)
        end
        node
      end

      # Right-associative: "a = b = c" parses as "a = (b = c)"; likewise for
      # the compound-assignment operators.
      def parse_assignment_expression
        node = parse_conditional_expression
        tok = peek
        if tok.punct?("=")
          advance
          error_at(tok, "expression is not assignable") unless assignable?(node)
          return AST::Assignment.new(node, parse_assignment_expression, tok)
        end

        op = tok.type == :punct ? COMPOUND_ASSIGNMENT_OPERATORS[tok.value] : nil
        return node unless op

        advance
        error_at(tok, "expression is not assignable") unless assignable?(node)
        AST::CompoundAssignment.new(op, node, parse_assignment_expression, tok)
      end

      # Syntactically, only a variable reference, a subscript "e[i]", a struct
      # member access "e.m"/"e->m" or a dereference "*expr" can appear on the
      # left of "=" (or "++"/"--", or a compound-assignment operator). Whether
      # the target's type is actually assignable (e.g. not an array) is checked
      # later by the generator.
      def assignable?(node)
        node.is_a?(AST::VariableRef) ||
          node.is_a?(AST::Subscript) ||
          node.is_a?(AST::MemberAccess) ||
          (node.is_a?(AST::Unary) && node.op == :deref)
      end

      # "?:" is right-associative: "a ? b : c ? d : e" parses as
      # "a ? b : (c ? d : e)". The middle operand is a full expression (not a
      # conditional-expression), per ISO C, so a bare assignment may appear
      # there without parentheses.
      def parse_conditional_expression
        node = parse_logical_or_expression
        return node unless peek.punct?("?")

        question_tok = advance
        then_expr = parse_expression
        expect_punct(":")
        else_expr = parse_conditional_expression
        AST::Conditional.new(node, then_expr, else_expr, question_tok)
      end

      def parse_logical_or_expression
        node = parse_logical_and_expression
        while peek.punct?("||")
          tok = advance
          node = AST::LogicalOr.new(node, parse_logical_and_expression, tok)
        end
        node
      end

      def parse_logical_and_expression
        node = parse_inclusive_or_expression
        while peek.punct?("&&")
          tok = advance
          node = AST::LogicalAnd.new(node, parse_inclusive_or_expression, tok)
        end
        node
      end

      # The three bitwise tiers sit between logical-AND and equality, in ISO C
      # order (inclusive-OR loosest, then exclusive-OR, then AND). The binary
      # "&" is recognized only here, between two operands; a "&" that opens a
      # unary-expression is the address-of operator, parsed far deeper, so the
      # two never collide (and the lexer has already split off "&&" and "&=").
      def parse_inclusive_or_expression
        parse_left_associative(INCLUSIVE_OR_OPERATORS) { parse_exclusive_or_expression }
      end

      def parse_exclusive_or_expression
        parse_left_associative(EXCLUSIVE_OR_OPERATORS) { parse_and_expression }
      end

      def parse_and_expression
        parse_left_associative(AND_OPERATORS) { parse_equality_expression }
      end

      def parse_equality_expression
        parse_left_associative(EQUALITY_OPERATORS) { parse_relational_expression }
      end

      def parse_relational_expression
        parse_left_associative(RELATIONAL_OPERATORS) { parse_shift_expression }
      end

      # shift-expression sits between relational and additive, so "1 << 2 + 3"
      # shifts by 5 (additive binds tighter) while "1 + 2 << 3" adds first
      # (shift is looser than additive but tighter than relational).
      def parse_shift_expression
        parse_left_associative(SHIFT_OPERATORS) { parse_additive_expression }
      end

      def parse_additive_expression
        parse_left_associative(ADDITIVE_OPERATORS) { parse_multiplicative_expression }
      end

      def parse_multiplicative_expression
        parse_left_associative(MULTIPLICATIVE_OPERATORS) { parse_cast_expression }
      end

      # cast-expression = "(" type-name ")" cast-expression | unary-expression.
      # A "(" begins a cast only when a type-specifier follows it; otherwise it
      # is an ordinary parenthesized expression, left for unary-expression (and
      # finally primary-expression) to consume. #type_specifier? settles the
      # choice with a single token of lookahead — a type keyword or a typedef
      # name after "(" — so "(int)x" and "(T)x" are casts while "(x)(y)", x
      # being neither, is a call.
      def parse_cast_expression
        if peek.punct?("(") && peek_ahead(1) && type_specifier?(peek_ahead(1))
          paren_tok = advance # "("
          type = parse_type_name
          expect_punct(")")
          AST::Cast.new(type, parse_cast_expression, paren_tok)
        else
          parse_unary_expression
        end
      end

      # Generic left-associative binary parser: the block parses one operand
      # at the next-tighter precedence tier; `operator_table` maps the
      # punctuators of this tier to AST operators.
      def parse_left_associative(operator_table)
        node = yield
        loop do
          tok = peek
          ast_op = tok.type == :punct ? operator_table[tok.value] : nil
          return node unless ast_op

          advance
          node = AST::Binary.new(ast_op, node, yield, tok)
        end
      end

      def parse_unary_expression
        if peek.keyword?("sizeof")
          parse_sizeof
        elsif peek.punct?("+")
          advance # unary + is a no-op; fold it away
          parse_cast_expression
        elsif peek.punct?("-")
          op_tok = advance
          AST::Unary.new(:neg, parse_cast_expression, op_tok)
        elsif peek.punct?("!")
          op_tok = advance
          AST::Unary.new(:not, parse_cast_expression, op_tok)
        elsif peek.punct?("~")
          parse_bitwise_not
        elsif peek.punct?("&")
          op_tok = advance
          AST::Unary.new(:addr, parse_cast_expression, op_tok)
        elsif peek.punct?("*")
          op_tok = advance
          AST::Unary.new(:deref, parse_cast_expression, op_tok)
        elsif peek.punct?("++") || peek.punct?("--")
          parse_prefix_inc_dec
        else
          parse_postfix_expression
        end
      end

      # "~x" is the one's-complement of an arithmetic operand. Rather than carry
      # a dedicated bitwise-not through the IR, it is desugared here to the
      # exclusive-or "x ^ -1": flipping every bit is an xor with all-ones, and
      # -1 is all-ones in every integer width. The generator then type-checks
      # and lowers it as an ordinary ":xor", so a pointer or struct operand is
      # rejected as an invalid binary operand exactly like "x ^ 1" would be. The
      # "~" token locates both the literal and the node for diagnostics.
      def parse_bitwise_not
        op_tok = advance # "~"
        operand = parse_cast_expression
        AST::Binary.new(:xor, operand, AST::IntLit.new(-1, op_tok, Type::Int), op_tok)
      end

      def parse_prefix_inc_dec
        op_tok = advance
        op = op_tok.value == "++" ? :add : :sub
        operand = parse_unary_expression
        error_at(op_tok, "expression is not assignable") unless assignable?(operand)
        AST::IncDec.new(op, operand, true, op_tok)
      end

      # "sizeof" measures either a parenthesized type-name ("sizeof(char *)")
      # or the result type of a unary-expression ("sizeof x", "sizeof(a)"). A
      # "(" right after the keyword is only a type-name when a type-specifier
      # ("int" or "char") follows; otherwise it is an ordinary parenthesized
      # operand, so it is left for unary-expression to consume.
      def parse_sizeof
        sizeof_tok = advance # "sizeof"
        if peek.punct?("(") && peek_ahead(1) && type_specifier?(peek_ahead(1))
          advance # "("
          type = parse_type_name
          expect_punct(")")
          AST::SizeofType.new(type, sizeof_tok)
        else
          AST::SizeofExpr.new(parse_unary_expression, sizeof_tok)
        end
      end

      # type-name = type-specifier abstract-declarator?: a base type-specifier
      # and an abstract declarator (no name). Shared by "sizeof ( type-name )"
      # and the cast "( type-name )", so a function pointer, an array pointer or
      # a plain pointer type can be written there ("sizeof(int (*)(int))",
      # "(int (*)(int))p").
      def parse_type_name
        _name_tok, type = parse_declarator(parse_type_specifier, name_mode: :forbidden)
        type
      end

      # A postfix-expression is a primary-expression followed by any run of
      # postfix suffixes in source order: a call "( args )", a subscript
      # "[ i ]", a member access "." / "->" and a postfix "++"/"--". A call is
      # just another suffix, so its callee may be any postfix-expression —
      # "f(x)", "(*fp)(x)", "table[i](x)" and "s.fp(x)" all parse the same way,
      # with the AST::Call carrying the callee expression it followed.
      def parse_postfix_expression
        node = parse_primary_expression
        loop do
          if peek.punct?("(")
            paren_tok = advance # "("
            args = parse_argument_expression_list
            expect_punct(")")
            node = AST::Call.new(node, args, paren_tok)
          elsif peek.punct?("[")
            bracket_tok = advance # "["
            index = parse_expression
            expect_punct("]")
            node = AST::Subscript.new(node, index, bracket_tok)
          elsif peek.punct?(".") || peek.punct?("->")
            op_tok = advance
            member_tok = expect_ident
            node = AST::MemberAccess.new(node, member_tok.value, op_tok.value == "->", op_tok)
          elsif peek.punct?("++") || peek.punct?("--")
            op_tok = advance
            op = op_tok.value == "++" ? :add : :sub
            error_at(op_tok, "expression is not assignable") unless assignable?(node)
            node = AST::IncDec.new(op, node, false, op_tok)
          else
            return node
          end
        end
      end

      # Returns an array of expression nodes; empty for an argument-less "()".
      def parse_argument_expression_list
        return [] if peek.punct?(")")

        args = [parse_assignment_expression]
        while peek.punct?(",")
          advance
          args << parse_assignment_expression
        end
        args
      end

      def parse_primary_expression
        tok = peek
        if tok.type == :num
          advance
          AST::IntLit.new(tok.value, tok, integer_literal_type(tok.value, tok.base, tok.suffix, tok))
        elsif tok.type == :string
          advance
          AST::StringLit.new(tok.value, tok)
        elsif tok.type == :ident
          advance
          # An identifier bound to an enum constant folds to its int value on the
          # spot, so the rest of the pipeline never sees an enumerator; one bound
          # to (or shadowed by) an ordinary name stays a variable reference.
          entry = lookup_ordinary(tok.value)
          if entry&.kind == :enum
            AST::IntLit.new(entry.value, tok, Type::Int)
          else
            AST::VariableRef.new(tok.value, tok)
          end
        elsif tok.punct?("(")
          advance
          node = parse_expression
          expect_punct(")")
          node
        else
          error_at(tok, "expected expression")
        end
      end

      # The type of an integer constant (6.4.4.1): the first type in a
      # base/suffix-specific candidate list whose range holds the value. A `u`
      # suffix admits the unsigned types; a decimal constant is never unsigned
      # without one, while hex and octal constants may fall through to an
      # unsigned type. `l`/`ll` (folded to one "long" width under LP64) demote
      # the int candidates. A value beyond even unsigned long is rejected.
      def integer_literal_type(value, base, suffix, tok)
        has_u = suffix.include?("u")
        has_l = suffix.include?("l")
        decimal = base == 10
        candidates =
          if has_u && has_l then [Type::ULong]
          elsif has_u then [Type::UInt, Type::ULong]
          elsif has_l then decimal ? [Type::Long] : [Type::Long, Type::ULong]
          elsif decimal then [Type::Int, Type::Long]
          else [Type::Int, Type::UInt, Type::Long, Type::ULong]
          end

        candidates.find { |type| integer_fits?(value, type) } ||
          # gcc widens an out-of-range constant to unsigned long rather than
          # reject it outright; only a value past unsigned long is an error.
          (integer_fits?(value, Type::ULong) ? Type::ULong : error_at(tok, "integer constant is too large"))
      end

      # Whether the non-negative `value` fits in integer type `type`.
      def integer_fits?(value, type)
        limit = type.signed? ? (1 << (type.size * 8 - 1)) - 1 : (1 << (type.size * 8)) - 1
        value <= limit
      end

      # --- ordinary-identifier namespace ---------------------------------

      # Records a variable, parameter or function name in the current ordinary
      # scope. The entry carries no payload; it exists only to shadow a typedef
      # name or enum constant of the same name from an outer scope, so a
      # redeclaration of an ordinary name (a genuine error the generator reports)
      # is deliberately not diagnosed here.
      def declare_ordinary_name(name)
        @ordinary_scopes.last[name] = OrdinaryName.new(:ordinary, nil)
      end

      # Binds a typedef name to its resolved type in the current ordinary scope.
      # A name already bound there — by an earlier typedef (even to the same
      # type, which M1 rejects for simplicity), or by any other declaration — is
      # a redefinition.
      def declare_typedef_name(name_tok, type)
        if @ordinary_scopes.last.key?(name_tok.value)
          error_at(name_tok, "redefinition of typedef '#{name_tok.value}'")
        end
        @ordinary_scopes.last[name_tok.value] = OrdinaryName.new(:typedef, type)
      end

      # The innermost ordinary-scope entry for `name`, or nil when none binds it.
      def lookup_ordinary(name)
        @ordinary_scopes.reverse_each do |scope|
          entry = scope[name]
          return entry if entry
        end
        nil
      end

      # Whether `name`'s innermost ordinary binding is a typedef name — false
      # when it is unbound or shadowed by a nearer variable or enum constant.
      def typedef_name?(name)
        entry = lookup_ordinary(name)
        !entry.nil? && entry.kind == :typedef
      end

      # --- token consumption helpers -------------------------------------

      def expect_keyword(str)
        tok = peek
        error_at(tok, "expected '#{str}'") unless tok.keyword?(str)
        advance
      end

      def expect_ident
        tok = peek
        error_at(tok, "expected identifier") unless tok.type == :ident
        advance
      end

      def expect_punct(str)
        tok = peek
        error_at(tok, "expected '#{str}'") unless tok.punct?(str)
        advance
      end

      def error_at(token, description)
        raise CompileError.new(
          description,
          filename: token.filename,
          line: token.line,
          column: token.column,
          source_line: token.source_line
        )
      end

      # Folds `node` — a conditional-expression already parsed as a
      # constant-expression (6.6) — to a Ruby Integer via ConstantEvaluator.
      # A sub-expression that is not itself a constant expression is reported
      # with `message` at its own token; a division/remainder by zero that is
      # actually reached is reported at the operator's token, independent of
      # `message`, since it is a different failure than "not a constant".
      def evaluate_constant_expression(node, message)
        ConstantEvaluator.evaluate(node)
      rescue ConstantEvaluator::NotConstant => e
        error_at(e.token, message)
      rescue ConstantEvaluator::DivisionByZero => e
        error_at(e.token, "division by zero in constant expression")
      end
    end
  end
end
