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
      DECL_SPECIFIER_KEYWORDS = %w[void char short int long signed unsigned _Bool float double __int128].freeze

      # The x86_64 "biggest alignment" gcc gives a bare
      # `__attribute__((aligned))` with no argument (BIGGEST_ALIGNMENT, 16
      # bytes): the most useful boundary, enough for any scalar or vector type.
      BIGGEST_ALIGNMENT = 16

      # The GNU attribute names Step 28 gives real layout meaning; every other
      # attribute is accepted and silently discarded. Kept in sync with the
      # preprocessor's __has_attribute answer (see Preprocessor#fold_has_attribute).
      LAYOUT_ATTRIBUTES = %w[aligned packed].freeze

      # The spellings of the "restrict" type qualifier this subset recognizes.
      # ISO "restrict" is not a keyword here (it never gains semantics — a
      # restricted pointer is treated like any other), and glibc prototypes use
      # the reserved GNU spellings "__restrict"/"__restrict__" unconditionally, so
      # all three arrive as ordinary identifiers and are accepted and discarded
      # wherever a pointer or array-parameter qualifier may appear.
      RESTRICT_SPELLINGS = %w[restrict __restrict __restrict__].freeze

      # The hard ceiling on how deeply the recursive descent will nest before it
      # rejects an input rather than recurse further. A hostile source (tens of
      # thousands of nested parentheses, unary operators, braces, ...) would
      # otherwise drive the descent until the Ruby machine stack overflows,
      # raising a bare SystemStackError that escapes as an unhandled crash
      # instead of a diagnostic. Capping the depth turns that into an ordinary
      # located CompileError.
      #
      # The value is deliberately well below the depth at which the stack
      # actually gives out. On this toolchain the full pipeline (parser plus IR
      # generation plus the backend, all of which recurse over the same AST)
      # overflows at roughly 330 nested parentheses — the parenthesized-
      # expression path is the most expensive, spending the entire binary-
      # precedence chain per level. A single counter is shared across every
      # recursive path — parenthesized/unary/cast/ternary/assignment expressions,
      # compound statements, initializer lists, nested declarators and
      # struct/union bodies — because these forms interleave (an expression
      # inside a statement inside an initializer ...), so it is their *combined*
      # live depth that threatens the stack, and bounding it here also bounds the
      # AST depth every later pass recurses over.
      #
      # Because the expression grammar's right-recursive tiers each carry their
      # own guard (assignment, conditional, unary, cast), one parenthesized level
      # descends through several of them, so the counter climbs about 4 per
      # nested parenthesis — the worst multiplier of any construct. 500 therefore
      # admits roughly 122 nested parentheses: comfortably above C11 §5.2.4.1's
      # 63-level implementation minimum, and about 12x the deepest nesting real
      # inputs reach (measured: 41 in the c-testsuite, 32 for the ruby.h smoke
      # header graph, 22 in the examples). At that ceiling the parser rejects
      # after ~4900 live frames, well under the ~13000 at which Ruby's stack
      # gives out, leaving headroom for a caller that starts from a deeper stack.
      MAX_NESTING_DEPTH = 500

      # The storage-class specifiers (6.7.1): at most one may appear in a
      # declaration. "typedef", "static" and "extern" are recorded in
      # DeclSpecInfo#storage and consumed downstream, while "register" and "auto"
      # are accepted for compatibility but carry no effect in this subset, so
      # they are consumed without being recorded; all five still participate in
      # the "at most one storage class" duplicate check.
      STORAGE_CLASS_KEYWORDS = %w[typedef static extern register auto].freeze

      # The non-type parts of a declaration's specifier run, collected by
      # #parse_declaration_specifiers alongside the base type. `storage` is the
      # recorded storage class (nil, :typedef, :static or :extern); `const` is
      # whether the declaration is const-qualified (const seen among the
      # specifiers, or folded in from a const typedef name); `inline_p` is
      # whether "inline" appeared (a function specifier, accepted on functions
      # and rejected on objects). volatile and register/auto leave no trace here.
      DeclSpecInfo = Data.define(:storage, :const, :inline_p)

      # A tag scope entry for an enum tag. C keeps struct, union and enum tags in
      # one shared namespace, so enum tags live in @tag_scopes alongside the
      # StructType objects that stand for struct tags. An enum contributes no
      # distinct type — an enum object is just an int (6.7.2.2) — so this marker
      # only records that the tag names an enum, which lets a later "struct X"
      # (or "enum X" against a struct tag) be diagnosed as the wrong kind of tag.
      EnumTag = Data.define(:tag)

      # An entry in the ordinary-identifier scope (see @ordinary_scopes). `kind`
      # is :typedef for a typedef name (`value` a [resolved Rubycc::Type, const?]
      # pair, the flag carrying a "typedef const int" so a use folds it back into
      # the object's const-ness), :enum
      # for an enumeration constant (`value` its Integer value), or :ordinary for
      # a variable, parameter or function name (`value` nil). The ordinary
      # entries carry no payload; they exist only so a declarator can shadow a
      # typedef name or an enum constant of the same name from an outer scope,
      # keeping "typedef int T; { int T; ... }" from misreading the inner T as a
      # type.
      OrdinaryName = Data.define(:kind, :value)

      # `plain_char` is the Rubycc::Type a bare `char` type-specifier resolves
      # to. Its signedness is implementation-defined and pinned per ABI, so the
      # caller that knows the target hands it in (see Compiler#compile);
      # defaulting to the signed instance keeps a target-less caller on the
      # x86-64 System V choice. `signed char` and `unsigned char` are unaffected —
      # both are separate types with a fixed signedness.
      #
      # `unnamed_bitfields_align` is the second such per-ABI trait: whether an
      # unnamed bit-field's type raises its aggregate's alignment (it does under
      # AAPCS64, not under the x86-64 System V psABI). It is passed straight to
      # StructType#define, which documents the rule.
      #
      # `builtin_va_list` is the third: the type `__builtin_va_list` names, whose
      # tag layout differs between the ABIs (four fields on System V, five on
      # AAPCS64). The caller hands in the target's from its CallConvention so the
      # typedef the parser seeds below reserves the right-sized object and, being
      # the same tag instance the generator type-checks against, is recognized by
      # identity there.
      def initialize(tokens, plain_char: Type::Char, unnamed_bitfields_align: false,
                     builtin_va_list: Type::BuiltinVaList)
        @tokens = tokens
        @plain_char = plain_char
        @unnamed_bitfields_align = unnamed_bitfields_align
        @builtin_va_list = builtin_va_list
        @pos = 0
        # The number of recursive-descent nesting levels currently live, capped
        # at MAX_NESTING_DEPTH by #with_nesting_guard. One counter is shared by
        # every recursive construct so their interleaved depth is what is bounded.
        @nesting_depth = 0
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
        # to a constant (an enumerator) or is an ordinary reference. The outermost
        # scope is pre-seeded with `__builtin_va_list` as a typedef for the
        # target's va_list type (a one-element __va_list_tag array), exactly as
        # gcc predeclares it, so "__builtin_va_list ap;" is parsed as a
        # declaration with no dedicated keyword and a program may still shadow the
        # name.
        @ordinary_scopes = [{ "__builtin_va_list" => OrdinaryName.new(:typedef, [@builtin_va_list, false]) }]
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

      # Runs `block` one recursive-descent level deeper, first rejecting the
      # input with a located CompileError once MAX_NESTING_DEPTH levels are
      # already live — so a pathologically nested source is diagnosed rather than
      # left to overflow the Ruby stack with a bare SystemStackError. The counter
      # is decremented in an ensure, so a parse error thrown from within the
      # block still unwinds the depth correctly. `token` locates the diagnostic
      # and `what` names the construct (e.g. "expression", "block").
      def with_nesting_guard(token, what)
        error_at(token, "#{what} nested too deeply") if @nesting_depth >= MAX_NESTING_DEPTH

        @nesting_depth += 1
        begin
          yield
        ensure
          @nesting_depth -= 1
        end
      end

      # An external declaration is either a function (a prototype ending in ";"
      # or a definition ending in a compound-statement) or a file-scope variable
      # declaration. Both begin with a type-specifier and a declarator; the
      # declarator's built type settles the form — a function type is the
      # function form (its declarator having read the "(" parameter list), any
      # other type the variable form.
      def parse_external_declaration
        # A leading "__extension__" (a GNU marker that silences pedantic
        # warnings) prefixes a declaration with no semantic effect; every
        # external declaration is a declaration, so any run of them is discarded.
        skip_extension_markers

        # A file-scope "_Static_assert(expr, "msg");" is a declaration that binds
        # nothing; it is checked and flattened away here (see #parse_static_assert).
        return parse_static_assert if peek.keyword?("_Static_assert")

        type_tok = peek
        base_type, spec_info = parse_declaration_specifiers(allow_storage_class: true)

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
        return parse_typedef_declaration(base_type, spec_info) if spec_info.storage == :typedef

        name_tok, type, function_params, pointer_quals =
          parse_declarator(base_type, allow_incomplete_array: true)
        # A GNU attribute may trail the declarator (position d):
        # "int f(void) __attribute__((noreturn));". Accepted and discarded, on a
        # function prototype/definition or a variable alike.
        parse_attribute_specifiers

        # A function definition is the one external declaration whose declarator
        # is followed by a compound statement (6.9.1); the declarator must be a
        # function type and it stands alone. Every other shape — a function
        # prototype, an object, or a comma-separated run mixing the two
        # ("int f(int a), g(int a), a;") — is a declaration list, so a
        # function-typed *first* declarator does not by itself commit the line to
        # a definition: only a following "{" does.
        if type.function? && peek.punct?("{")
          # A function's parameters must be declared by the definition's own
          # declarator (6.9.1p2): a function type reached through a typedef
          # ("typedef int F(int); F f { ... }") supplies no parameter list of
          # its own — `function_params` is nil — so it may declare a prototype
          # but not a definition.
          if function_params.nil?
            error_at(name_tok, "function definition through a typedef is not allowed")
          end
          declare_ordinary_name(name_tok.value, type)
          return parse_function_definition(name_tok.value, type.return_type, function_params,
                                           type_tok, spec_info.storage, type.variadic)
        end

        parse_external_declaration_list(base_type, name_tok, type, function_params,
                                        pointer_quals, spec_info, type_tok)
      end

      # The declaration-list form of an external declaration: a comma-separated
      # run of init-declarators sharing `base_type`, the first already read into
      # `first_*`. Each declarator independently becomes a FunctionDecl (a
      # function prototype) or a GlobalDecl (a file-scope object), so one
      # declaration may mix the two ("int f(int a), g(int a), a;"). The run ends
      # at ";".
      def parse_external_declaration_list(base_type, first_name_tok, first_type, first_params,
                                          first_pointer_quals, spec_info, return_tok)
        decls = [parse_external_declarator(first_name_tok, first_type, first_params,
                                           first_pointer_quals, spec_info, return_tok)]
        while peek.punct?(",")
          advance
          name_tok, type, params, pointer_quals = parse_declarator(base_type, allow_incomplete_array: true)
          parse_attribute_specifiers # position d: a trailing attribute on this declarator
          decls << parse_external_declarator(name_tok, type, params, pointer_quals, spec_info, return_tok)
        end
        expect_punct(";")
        decls
      end

      # One init-declarator of an external declaration list. A function-typed
      # declarator is a prototype — a FunctionDecl whose name is recorded as an
      # ordinary identifier (so an inner block shadowing it is told from a typedef
      # use); every other declarator is a file-scope object (see
      # #parse_global_declarator, which reads any "=" initializer). `spec_info`
      # carries the shared storage class and an "inline" flag, legal only on the
      # function declarators (an object declarator rejects it downstream).
      def parse_external_declarator(name_tok, type, params, pointer_quals, spec_info, return_tok)
        if type.function?
          declare_ordinary_name(name_tok.value, type)
          AST::FunctionDecl.new(name_tok.value, type.return_type,
                                declarator_prototype_params(type, params, return_tok), return_tok,
                                spec_info.storage, type.variadic)
        else
          parse_global_declarator(type, name_tok, pointer_quals, spec_info)
        end
      end

      # The Parameter list a function-typed declarator contributes to its
      # prototype. When the declarator carries its own "( parameter-list )"
      # suffix, `params` is that list (each with the declared name). When the
      # function type instead arrives through a typedef — "typedef VALUE
      # getter_t(ID, VALUE *); getter_t g;" — the declarator has no parameter
      # suffix of its own, so `params` is nil; the prototype's parameters are
      # then synthesized from the typedef's parameter types as unnamed
      # parameters (6.7.6.3), exactly as an explicit "int f(int, int);"
      # prototype models its own. Such a declaration is always a prototype: a
      # function may not be *defined* through a typedef (6.9.1p2), which the
      # definition path rejects separately.
      def declarator_prototype_params(type, params, token)
        return params if params

        type.param_types.map { |param_type| AST::Parameter.new(nil, param_type, token, false) }
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
      def parse_global_declarator(type, name_tok, pointer_quals, spec_info)
        reject_void_type(type, name_tok)
        reject_object_specifiers(name_tok, spec_info)
        const = declarator_object_const(type, spec_info.const, pointer_quals)
        initializer_value = nil
        initializer_node = nil
        if peek.punct?("=")
          # An "extern" object with an initializer is a definition, not a mere
          # reference; the two together are contradictory, so reject them.
          if spec_info.storage == :extern
            error_at(name_tok, "'#{name_tok.value}' has both 'extern' and initializer")
          end
          advance # "="
          init = parse_initializer
          if InitializerResolver.structural?(type, init)
            type = InitializerResolver.resolve(type, init).type
            initializer_node = init
          elsif type.integer? && !references_sizeof_expr?(init) && !references_address_of?(init)
            # An integer scalar initializer is folded to a value here, where the
            # constant evaluator carries no type table. A `sizeof <expression>`
            # operand needs the operand's type, and an address-of (the
            # "(size_t)&((T*)0)->m" offsetof idiom) needs the generator's
            # address-constant machinery, so an initializer that uses either is
            # deferred as a raw node for the generator to fold instead (it reaches
            # the same "unsupported initializer" diagnostic there when genuinely
            # not a constant).
            initializer_value = evaluate_constant_expression(init, "unsupported initializer for global variable")
          else
            initializer_node = init
          end
        elsif type.array? && type.length.nil? && spec_info.storage != :extern
          # An `extern T a[];` is a reference to an array defined elsewhere, an
          # incomplete type the defining unit completes (6.7.6.2p1, 6.9.2); it is
          # kept as-is. A non-extern `T a[];` is a tentative definition whose
          # bound the standard completes to [1] — a completion M1 does not
          # perform — so it stays a diagnostic here.
          error_at(name_tok, "array size missing in '#{name_tok.value}'")
        end
        declare_ordinary_name(name_tok.value, type)
        AST::GlobalDecl.new(name_tok.value, type, initializer_value, initializer_node, name_tok, const, spec_info.storage)
      end

      # A bare type-specifier list with no storage class, used everywhere a type
      # is written without a "typedef" in front of it: a struct member, a
      # parameter, and a type-name in a cast or sizeof. It resolves to a single
      # Rubycc::Type, discarding the (always-false) typedef flag.
      def parse_type_specifier
        type, = parse_declaration_specifiers(allow_storage_class: false)
        type
      end

      # declaration-specifiers = (storage-class-specifier | type-qualifier |
      # function-specifier | type-specifier)+. Consumes the whole specifier run —
      # at most one storage class (6.7.1), any const/volatile/inline, and the
      # type itself, all in any order. The base type any
      # leading "*" run then builds a pointer from is one of: a run of
      # integer/void keywords collected and normalized by
      # #normalize_type_specifiers; a "struct"/"enum" specifier, which resolves
      # or defines its tag; or a single typedef name, an identifier bound to a
      # type in the ordinary namespace. A typedef name is recognized only as the
      # first (and only) type-specifier — once any type keyword has been seen, a
      # following identifier is the declarator, so "int T" declares a variable T
      # even where T names a type (the standard rule that keeps typedef names
      # shadowable). Mixing categories ("unsigned struct", "enum T", ...) is a
      # diagnostic; `allow_storage_class` is false in the contexts a storage
      # class or "inline" cannot appear (a member, a parameter, a type-name),
      # where const/volatile are still admitted ("int f(const int x)",
      # "sizeof(const int)"). Returns [base_type, DeclSpecInfo].
      def parse_declaration_specifiers(allow_storage_class:, allow_register: false)
        start_tok = peek
        specs = []       # collected integer/void keyword strings
        composite = nil  # a struct/enum/typedef-name Type (excludes `specs`)
        storage = nil    # recorded storage class: :typedef / :static / :extern
        storage_seen = false # any storage-class specifier (for the 6.7.1 check)
        const_p = false
        inline_p = false
        typedef_const = false # const folded in from a const typedef name
        loop do
          tok = peek
          if tok.type == :keyword && STORAGE_CLASS_KEYWORDS.include?(tok.value)
            # A parameter declaration admits exactly one storage class, `register`
            # (6.7.6.3p2), and no other — so `allow_register` opens that one
            # keyword without letting typedef/static/extern/auto through.
            unless allow_storage_class || (allow_register && tok.value == "register")
              error_at(tok, "'#{tok.value}' is not allowed here")
            end
            error_at(tok, "multiple storage classes in declaration specifiers") if storage_seen
            storage_seen = true
            # register/auto have no effect in this subset: they are consumed but
            # left unrecorded, only typedef/static/extern reaching later stages.
            storage = tok.value.to_sym if %w[typedef static extern].include?(tok.value)
            advance
          elsif tok.keyword?("const")
            const_p = true
            advance
          elsif tok.keyword?("volatile")
            advance # accepted and ignored: M1 carries no qualified types
          elsif tok.keyword?("inline")
            error_at(tok, "'inline' is not allowed here") unless allow_storage_class
            inline_p = true
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
          elsif tok.keyword?("__attribute__")
            # A GNU attribute may open the specifier run or sit between
            # specifiers (position a): "__attribute__((const)) int f(...)",
            # "int __attribute__((unused)) x;". None affects an object's type, so
            # the collected attributes are discarded.
            parse_attribute_specifiers
          elsif composite.nil? && specs.empty? && tok.type == :ident && typedef_name?(tok.value)
            composite, typedef_const = lookup_ordinary(tok.value).value
            advance
          else
            break
          end
        end

        # A "const" typedef name ("typedef const int ci; ci x;") contributes its
        # const to the declaration, OR-ed with any const written here directly.
        spec_info = DeclSpecInfo.new(storage: storage, const: const_p || typedef_const, inline_p: inline_p)
        if composite
          [composite, spec_info]
        else
          error_at(start_tok, "expected type specifier") if specs.empty?
          [normalize_type_specifiers(specs, start_tok), spec_info]
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
        return normalize_standalone(Type::Float, "float", specs, tok) if counts["float"].positive?
        # `double` stands alone or pairs with a single `long` ("long double",
        # treated as `double` here); any other keyword, a second `double` or a
        # second `long` is an ill-formed combination.
        if counts["double"].positive?
          non_long = specs.reject { |s| s == "long" }
          unless non_long == ["double"] && counts["long"] <= 1
            error_at(tok, "cannot combine 'double' with other type specifiers")
          end
          return Type::Double
        end

        # `__int128` (a GNU keyword) stands alone or pairs with a single
        # `signed`/`unsigned`, in any order ("unsigned __int128", "__int128
        # unsigned", "signed __int128"); no width keyword may join it. Its
        # signedness follows the same rule the standard integers use — a bare
        # `__int128` is signed, `unsigned` makes it unsigned.
        if counts["__int128"].positive?
          error_at(tok, "duplicate '__int128'") if counts["__int128"] > 1
          non_sign = specs.reject { |s| s == "signed" || s == "unsigned" }
          unless non_sign == ["__int128"]
            error_at(tok, "cannot combine '__int128' with other type specifiers")
          end
          if counts["signed"].positive? && counts["unsigned"].positive?
            error_at(tok, "both 'signed' and 'unsigned' in declaration specifiers")
          end
          return counts["unsigned"].positive? ? Type::UInt128 : Type::Int128
        end

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
          # The three character types are distinct: "unsigned char" and "signed
          # char" name their own fixed-signedness types, while a bare "char"
          # takes the target's plain-char instance (see #initialize).
          return Type::UChar if unsigned
          return Type::SChar if signed

          return @plain_char
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
        # A struct/union body may hold members whose own type is a further
        # struct/union definition ("struct { struct { ... } a; } b;"), which
        # recurses back here through #parse_struct_body; guarding at the keyword
        # bounds that nesting on the shared counter.
        with_nesting_guard(keyword_tok, "type definition") do
          # A GNU attribute may sit right after the keyword, before the tag or "{"
          # (position b): "struct __attribute__((aligned(8))) S { ... }". Only its
          # aligned/packed carry layout meaning, and only on a definition.
          leading_attrs = parse_attribute_specifiers
          tag_tok = peek.type == :ident ? advance : nil
          tag = tag_tok&.value

          if peek.punct?("{")
            struct_type = tag ? define_struct_tag(tag, kind, keyword_tok) : Type::StructType.new(nil, kind: kind)
            raw_members = parse_struct_body(kind, keyword_tok)
            # A second attribute run may follow the closing "}" (position c),
            # before the declarator list or ";"; the two runs combine on the layout.
            trailing_attrs = parse_attribute_specifiers
            aligned, packed = resolve_layout_attributes(leading_attrs + trailing_attrs)
            # A packed aggregate that also carries a bit-field would need bit-level
            # packing across storage units this subset does not model, so the
            # combination is rejected rather than laid out wrongly (Step 28 C2).
            if packed && raw_members.any? { |triple| triple[2] }
              error_at(keyword_tok, "packed bit-fields are not supported")
            end
            struct_type.define(raw_members, packed: packed, aligned: aligned,
                                            unnamed_bitfields_align: @unnamed_bitfields_align)
            struct_type
          elsif tag
            reference_struct_tag(tag, kind, tag_tok)
          else
            error_at(keyword_tok, "expected identifier or '{' after '#{keyword_tok.value}'")
          end
        end
      end

      # Consumes a run of GNU __attribute__ specifiers (each
      # "__attribute__ ( ( attribute-list ) )", ISO C23's attribute-specifier
      # sequence spelled the GNU way), returning the collected [name, argument]
      # pairs for the caller to interpret. A caller that gives attributes no
      # meaning (every position but a struct/union specifier) simply discards
      # the result. `__attribute__` is a keyword here, so it never collides with
      # an ordinary identifier. Nothing is consumed when no attribute is present.
      def parse_attribute_specifiers
        attributes = []
        while peek.keyword?("__attribute__")
          advance # "__attribute__"
          expect_punct("(")
          expect_punct("(")
          parse_attribute_list(attributes)
          expect_punct(")")
          expect_punct(")")
        end
        attributes
      end

      # attribute-list: a comma-separated sequence of attributes, possibly empty
      # ("__attribute__(())") and admitting empty elements ("__attribute__((,))",
      # which gcc allows), each appended to `attributes` as a [name, argument]
      # pair (argument is the folded aligned value, or nil).
      def parse_attribute_list(attributes)
        loop do
          parse_attribute(attributes) unless peek.punct?(",") || peek.punct?(")")
          break unless peek.punct?(",")

          advance # ","
        end
      end

      # One attribute: an attribute-token (an identifier, or a keyword — gcc
      # spells several attributes with keywords, e.g. "__attribute__((const))")
      # optionally followed by a parenthesized argument clause. Its name is
      # normalized (see #normalize_attribute_name) and paired with the folded
      # argument value #parse_attribute_arguments returns (meaningful only for
      # "aligned"; nil otherwise).
      def parse_attribute(attributes)
        name_tok = peek
        unless name_tok.type == :ident || name_tok.type == :keyword
          error_at(name_tok, "expected attribute name")
        end
        advance
        name = normalize_attribute_name(name_tok.value)
        argument = peek.punct?("(") ? parse_attribute_arguments(name) : nil
        attributes << [name, argument]
      end

      # An attribute's parenthesized argument clause. "aligned(N)" carries a
      # single integer constant-expression that must be folded and range-checked
      # here, so it is parsed for real; every other attribute's arguments (bare
      # identifiers, string literals, comma-separated integers such as
      # "format(printf, 1, 2)") are accepted and discarded, so its balanced
      # parentheses are skipped verbatim. Returns the folded aligned value, or
      # nil for any other attribute.
      def parse_attribute_arguments(name)
        return skip_balanced_parentheses && nil unless name == "aligned"

        advance # "("
        expr = parse_conditional_expression
        expect_punct(")")
        value = evaluate_constant_expression(expr, "'aligned' attribute argument is not an integer constant")
        unless value.positive? && (value & (value - 1)).zero?
          error_at(expr.token, "requested alignment '#{value}' is not a positive power of 2")
        end
        value
      end

      # Skips a balanced-parenthesis token run (an attribute argument clause we
      # give no meaning), from the opening "(" through its matching ")". Returns
      # true so #parse_attribute_arguments can chain it with "&& nil".
      def skip_balanced_parentheses
        expect_punct("(")
        depth = 1
        until depth.zero?
          tok = peek
          error_at(tok, "unterminated attribute argument list") if tok.eof?
          depth += 1 if tok.punct?("(")
          depth -= 1 if tok.punct?(")")
          advance
        end
        true
      end

      # Normalizes a GNU attribute name: a "__name__" spelling collapses to
      # "name" — exactly one leading and one trailing "__" stripped when both are
      # present — so "__aligned__" and "aligned" name the same attribute. A name
      # underscored on only one side, or too short to carry both pairs, is left
      # as written.
      def normalize_attribute_name(name)
        if name.start_with?("__") && name.end_with?("__") && name.length > 4
          name[2..-3]
        else
          name
        end
      end

      # Reduces a struct/union specifier's collected attributes to the layout
      # override StructType#define takes: [aligned, packed]. `aligned` is the
      # largest power-of-two boundary any "aligned" attribute asked for (a bare
      # "aligned" with no argument meaning BIGGEST_ALIGNMENT), or nil when none
      # appeared; `packed` is whether any "packed" attribute was present. Every
      # unrecognized attribute has already been discarded, so only these two
      # remain to interpret.
      def resolve_layout_attributes(attributes)
        aligned = nil
        packed = false
        attributes.each do |name, argument|
          case name
          when "aligned"
            value = argument || BIGGEST_ALIGNMENT
            aligned = value if aligned.nil? || value > aligned
          when "packed"
            packed = true
          end
        end
        [aligned, packed]
      end

      # Consumes any run of leading "__extension__" markers (a GNU keyword that
      # only silences pedantic diagnostics). Used wherever a declaration may be
      # prefixed by one; the unary-expression prefix form is handled separately
      # in #parse_cast_expression.
      def skip_extension_markers
        advance while peek.keyword?("__extension__")
      end

      # Whether the token `offset` tokens ahead of a run of "__extension__"
      # markers opens a declaration, so block-item and for-init can tell a
      # "__extension__ int x;" declaration from a "__extension__ expr;"
      # expression statement without committing to either first.
      def extension_prefixes_declaration?
        return false unless peek.keyword?("__extension__")

        offset = 1
        offset += 1 while peek_ahead(offset)&.keyword?("__extension__")
        following = peek_ahead(offset)
        !following.nil? && (type_specifier?(following) || following.keyword?("_Static_assert"))
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
      # taken there by a *complete* enum is a redefinition; one taken by a struct
      # tag is the wrong kind of tag (struct, union and enum share one namespace).
      # A tag already forward-declared incomplete in this scope (an EnumType, from
      # "enum E *p;") is completed here: the marker becomes an EnumTag, so later
      # "enum E" references resolve to int. Earlier pointer references keep the
      # incomplete EnumType they captured, which stays valid as a pointer target.
      def register_enum_tag(tag, token)
        existing = @tag_scopes.last[tag]
        if existing
          if existing.is_a?(EnumTag)
            error_at(token, "redefinition of 'enum #{tag}'")
          elsif !existing.is_a?(Type::EnumType)
            error_at(token, "'#{tag}' defined as wrong kind of tag")
          else
            # An earlier forward reference ("enum efoo;", or a prototype's
            # "enum efoo" return type) captured this incomplete EnumType. Complete
            # it in place so that captured object now answers as the int an enum
            # object is — the reference and this definition then agree on the type.
            existing.complete!
          end
        end
        @tag_scopes.last[tag] = EnumTag.new(tag)
      end

      # Resolves a bare "enum tag" reference (innermost scope outward). A defined
      # tag (an EnumTag) resolves to Type::Int, since an enum object is an int; a
      # tag bound to a struct is the wrong kind of tag. A tag with no visible
      # binding is forward-declared incomplete — mirroring an incomplete struct —
      # so "enum E *p;" names a pointer to an as-yet-undefined enum; a later
      # in-scope forward reference reuses that same incomplete EnumType. The
      # generator rejects an incomplete enum wherever a size or arithmetic is
      # actually required.
      def resolve_enum_tag(tag, token)
        @tag_scopes.reverse_each do |scope|
          found = scope[tag]
          next unless found

          return Type::Int if found.is_a?(EnumTag)
          return found if found.is_a?(Type::EnumType)

          error_at(token, "'#{tag}' defined as wrong kind of tag")
        end
        incomplete = Type::EnumType.new(tag)
        @tag_scopes.last[tag] = incomplete
        incomplete
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
      # of tag. An enum binding is an EnumTag (a defined enum) or a Type::EnumType
      # (an incomplete, forward-declared one); a struct/union binding is a
      # StructType told apart by #union?.
      def reject_wrong_tag_kind(existing, kind, tag, token)
        wrong = existing.is_a?(EnumTag) || existing.is_a?(Type::EnumType) ||
                existing.union? != (kind == :union)
        error_at(token, "'#{tag}' defined as wrong kind of tag") if wrong
      end

      # The keyword spelling for an aggregate kind, for diagnostics.
      def tag_keyword(kind)
        kind == :union ? "union" : "struct"
      end

      # Parses a struct/union's "{ struct-declaration+ }" body, returning the
      # raw [name, Type] member pairs the caller hands to StructType#define
      # (deferred so an attribute after "}" can still steer the layout). A
      # struct-declaration is either a type-specifier
      # followed by one or more comma-separated declarators (each contributing a
      # "*" run and an optional array suffix), just like a local declaration but
      # with no initializer, or — for an anonymous member (C11 6.7.2.1p13) — a
      # tagless struct/union specifier with no declarator at all. A named member
      # may not be void, an incomplete aggregate by value, or a duplicate name;
      # a pointer to an incomplete struct (the self-referential case) is fine,
      # since a pointer is always complete. `seen` tracks every member name
      # visible from this body, folding in the names an anonymous member exposes
      # transparently, so a collision through one is diagnosed like any other.
      def parse_struct_body(kind, keyword_tok)
        expect_punct("{")
        raw_members = []
        seen = {}
        # Tracks a flexible array member as the body is read (ISO C 6.7.2.1p18):
        # `token` is the FAM's name once seen, so any further member declared
        # after it is diagnosed (a FAM must be the struct's last member), and
        # `others` counts the ordinary members, so a struct whose *only* member
        # is a FAM is rejected. `kind` lets a FAM in a union be rejected.
        flex = { kind: kind, token: nil, others: 0 }
        until peek.punct?("}")
          spec_tok = peek
          member_base = parse_type_specifier
          if peek.punct?(";")
            parse_anonymous_member(member_base, spec_tok, raw_members, seen, flex)
          else
            parse_member_declarators(member_base, spec_tok, raw_members, seen, flex)
          end
          expect_punct(";")
        end
        expect_punct("}")
        if flex[:token] && flex[:others].zero?
          error_at(flex[:token], "flexible array member '#{flex[:token].value}' in a struct with no other members")
        end
        raw_members
      end

      # A struct-declaration with no declarator. It is well-formed only as an
      # anonymous member — a tagless struct/union specifier (its type is an
      # aggregate with no tag); a tagged specifier standing alone ("struct Inner
      # {...};" or "struct Inner;" inside a body) or any other bare type
      # declares nothing and is rejected. The member is recorded with a nil name
      # and its inner type; every name it exposes transparently is added to
      # `seen` so a later member cannot shadow one of them.
      def parse_anonymous_member(member_base, spec_tok, raw_members, seen, flex)
        reject_member_after_flexible_array(flex, spec_tok)
        unless member_base.struct? && member_base.tag.nil?
          error_at(spec_tok, "declaration does not declare anything")
        end
        transparent_member_names(member_base).each do |name|
          error_at(spec_tok, "duplicate member '#{name}'") if seen.key?(name)
          seen[name] = true
        end
        flex[:others] += 1
        raw_members << [nil, member_base, nil]
      end

      # The comma-separated struct-declarators sharing `member_base`. Each is
      # either a declarator naming a member (a "*" run, an array suffix, or a
      # function-pointer shape such as "int (*handler)(int)"), optionally followed
      # by ": constant-expression" to make it a bit-field, or a bare
      # ": constant-expression" with no declarator — an unnamed bit-field that
      # shapes the layout but declares nothing (6.7.2.1). A member may not be a
      # bare function; a pointer to one is fine. Each named member is checked for
      # a duplicate against `seen` (which already holds any transparently exposed
      # names) and then added to it. Every recorded triple is
      # [name, Type, bit_width], bit_width nil for a plain member.
      def parse_member_declarators(member_base, spec_tok, raw_members, seen, flex)
        loop do
          reject_member_after_flexible_array(flex, spec_tok)
          if peek.punct?(":")
            advance # ":"
            # An unnamed bit-field declares no member, so it does not satisfy the
            # "a FAM needs another named member" rule (flex[:others] untouched).
            raw_members << [nil, member_base, parse_bitfield_width(member_base, spec_tok)]
          else
            parse_named_member(member_base, raw_members, seen, flex)
          end
          break unless peek.punct?(",")

          advance
        end
      end

      # One named struct-declarator: a declarator, then either a ": width"
      # bit-field tail or a plain member. A named bit-field of zero width is a
      # constraint violation (6.7.2.1p3, "only an unnamed member may be
      # zero-width"). A plain member may not be a function, void, or an
      # incomplete aggregate by value.
      def parse_named_member(member_base, raw_members, seen, flex)
        # A trailing "[]" (an incomplete array) is admitted here so the last
        # member may be a flexible array member; #reject_flexible_array_member
        # then enforces the 6.7.2.1p18 constraints (struct only, and never
        # followed by another member — see #reject_member_after_flexible_array).
        name_tok, type = parse_declarator(member_base, allow_incomplete_array: true)
        if peek.punct?(":")
          advance # ":"
          width = parse_bitfield_width(type, name_tok)
          error_at(name_tok, "named bit-field '#{name_tok.value}' has zero width") if width.zero?
          register_member_name(name_tok, seen)
          flex[:others] += 1
          raw_members << [name_tok.value, type, width]
        else
          # A GNU attribute may trail a member declarator (position f):
          # "int m __attribute__((packed));". Accepted and discarded — a
          # member-level packed/aligned has no effect on this subset's layout
          # (only a whole-struct attribute steers #layout_struct).
          parse_attribute_specifiers
          error_at(name_tok, "field '#{name_tok.value}' declared as a function") if type.function?
          reject_void_type(type, name_tok)
          reject_incomplete_member(type, name_tok)
          register_member_name(name_tok, seen)
          if type.array? && type.incomplete?
            reject_flexible_array_member(type, name_tok, flex)
            flex[:token] = name_tok
          else
            flex[:others] += 1
          end
          raw_members << [name_tok.value, type, nil]
        end
      end

      # Rejects a member declared after a flexible array member: a FAM must be
      # the struct's last member (6.7.2.1p18), so anything that follows it — a
      # further declarator in the same list ("int f[], g;"), a later declaration,
      # or an anonymous member — is a constraint violation reported at the FAM's
      # own name. Does nothing until a FAM has actually been seen.
      def reject_member_after_flexible_array(flex, _anchor)
        return unless flex[:token]

        error_at(flex[:token],
                 "flexible array member '#{flex[:token].value}' must be the last member of the struct")
      end

      # Enforces the two constraints a flexible array member must satisfy at the
      # point it is declared (6.7.2.1p18): it is legal only in a struct, never a
      # union, and only when the element type is complete — an "[]" of an
      # incomplete struct has no element size to index. The "must be last" and
      # "needs another member" rules are enforced by the surrounding body parse,
      # which alone sees the whole member sequence.
      def reject_flexible_array_member(type, name_tok, flex)
        if flex[:kind] == :union
          error_at(name_tok, "flexible array member '#{name_tok.value}' not allowed in union")
        end
        if type.element.struct? && !type.element.complete?
          error_at(name_tok, "flexible array member '#{name_tok.value}' has incomplete element type")
        end
      end

      # Records a member name in `seen`, diagnosing a collision with a name
      # already visible in this body (a directly declared member or one an
      # anonymous member exposes transparently).
      def register_member_name(name_tok, seen)
        error_at(name_tok, "duplicate member '#{name_tok.value}'") if seen.key?(name_tok.value)
        seen[name_tok.value] = true
      end

      # Parses and validates a bit-field's ": constant-expression" width, the ":"
      # already consumed. `type` is the field's declared type and `anchor` the
      # token a diagnostic points at. The type must be an integer type, and the
      # width a non-negative integer constant no wider than that type (6.7.2.1p4).
      def parse_bitfield_width(type, anchor)
        unless type.integer?
          error_at(anchor, "bit-field has non-integral type '#{type}'")
        end
        expr = parse_conditional_expression
        width = evaluate_constant_expression(expr, "bit-field width is not an integer constant")
        error_at(expr.token, "negative width in bit-field") if width.negative?
        error_at(expr.token, "width of bit-field exceeds its type") if width > type.size * 8
        width
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
      # integer/void type-specifier keyword, "struct"/"union"/"enum", a storage
      # class ("typedef"/"static"/"extern"/"register"/"auto"), a type qualifier
      # ("const"/"volatile"), the "inline" function specifier, or a typedef name —
      # an identifier bound to a type in the ordinary namespace whose innermost
      # binding is not shadowed by a variable. The storage-class and inline
      # keywords never open an expression, so admitting them here only ever
      # forwards a genuine declaration (a bare "static x;" then fails in the
      # specifier parse, where it belongs).
      def type_specifier?(token)
        if token.type == :keyword
          return DECL_SPECIFIER_KEYWORDS.include?(token.value) ||
                 STORAGE_CLASS_KEYWORDS.include?(token.value) ||
                 token.value == "struct" || token.value == "union" ||
                 token.value == "enum" ||
                 token.value == "const" || token.value == "volatile" ||
                 token.value == "inline" ||
                 # A leading GNU attribute opens a declaration too
                 # ("__attribute__((unused)) int x;"), so block-item and
                 # for-init recognize it as one rather than a statement.
                 token.value == "__attribute__"
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

      def parse_function_definition(name, return_type, params, return_tok, storage, variadic)
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
        params.each { |param| declare_ordinary_name(param.name, param.type) }
        body = []
        body.concat(parse_block_item) until peek.punct?("}")
        @ordinary_scopes.pop
        @tag_scopes.pop
        expect_punct("}")
        AST::FunctionDef.new(name, return_type, params, body, return_tok, storage, variadic)
      end

      # Returns [params, variadic]: an array of AST::Parameter (empty for "()" or
      # "(void)") and whether the list ends in a "..." variable-argument marker
      # (6.7.6.3). A bare "void" only means "no parameters" when it is the entire
      # list (followed immediately by ")"); "void *" or a later "void" parameter
      # falls through to parse_parameter_declaration, which rejects a non-pointer
      # void. A "..." is admitted only after at least one named parameter and a
      # comma ("int a, ..."): a lone "(...)" has no fixed parameter to anchor a
      # va_start on, and nothing may follow the "...".
      def parse_parameter_type_list
        return [[], false] if peek.punct?(")")
        if peek.keyword?("void") && peek_ahead(1)&.punct?(")")
          advance
          return [[], false]
        end
        if peek.punct?("...")
          error_at(peek, "ISO C requires a named parameter before '...'")
        end

        params = [parse_parameter_declaration]
        variadic = false
        while peek.punct?(",")
          advance
          if peek.punct?("...")
            advance
            variadic = true
            # "..." terminates the list; a parameter or stray token after it
            # ("int a, ..., int b") is rejected here rather than left for the
            # caller's ")" expectation to surface as a vaguer error.
            error_at(peek, "'...' must be the last parameter") unless peek.punct?(")")
            break
          end
          params << parse_parameter_declaration
        end
        [params, variadic]
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
        # A parameter's specifiers admit const/volatile but not a storage class
        # or inline (allow_storage_class: false) — except `register`, the one
        # storage class 6.7.6.3p2 permits on a parameter, which is consumed and
        # ignored. Only its const survives.
        base_type, spec_info = parse_declaration_specifiers(allow_storage_class: false, allow_register: true)
        # A parameter's array declarator adjusts to a pointer (6.7.6.3p7), so an
        # empty "[]" is admitted here just as it is for an external declaration's
        # incomplete array; #adjust_parameter_type resolves it below.
        name_tok, type, _params, pointer_quals =
          parse_declarator(base_type, name_mode: :optional, allow_incomplete_array: true)
        # A GNU attribute may trail a parameter declarator (position e):
        # "int f(int x __attribute__((unused)))". Accepted and discarded; the
        # specifier-position form is already handled in the specifier parse.
        parse_attribute_specifiers
        type = adjust_parameter_type(type)
        # The const-ness is settled on the adjusted type, so "const int a[10]"
        # (a pointer to const int after adjustment) yields a non-const parameter,
        # while "int * const a" stays a const pointer parameter.
        const = declarator_object_const(type, spec_info.const, pointer_quals)
        reject_void_type(type, name_tok || type_tok)
        if name_tok
          AST::Parameter.new(name_tok.value, type, name_tok, const)
        else
          AST::Parameter.new(nil, type, type_tok, const)
        end
      end

      # Returns an array of nodes: a declaration expands to one VariableDecl
      # per init-declarator, while a statement always yields exactly one node.
      def parse_block_item
        # A block-scope "_Static_assert(expr, "msg");" is a declaration that
        # binds nothing; it is checked and flattened away like a bare tag decl.
        return parse_static_assert if peek.keyword?("_Static_assert")

        # A "__extension__" prefixing a declaration ("__extension__ int x;") is
        # discarded here; a "__extension__" prefixing an expression statement is
        # left for #parse_cast_expression, which binds it like a cast prefix.
        if extension_prefixes_declaration?
          skip_extension_markers
          return parse_static_assert if peek.keyword?("_Static_assert")

          return parse_declaration
        end

        if type_specifier?(peek)
          parse_declaration
        else
          [parse_statement]
        end
      end

      def parse_declaration
        base_type, spec_info = parse_declaration_specifiers(allow_storage_class: true)

        # A bare "struct point { ... };" (or "struct node;", or a tag-only "enum
        # E { ... };") inside a block just declares or defines the tag, adding no
        # local; it yields no items.
        if peek.punct?(";")
          advance
          return []
        end

        # A local typedef binds names as types in this block's scope; like a
        # file-scope typedef it yields no items.
        return parse_typedef_declaration(base_type, spec_info) if spec_info.storage == :typedef

        decls = [parse_init_declarator(base_type, spec_info)]
        while peek.punct?(",")
          advance
          decls << parse_init_declarator(base_type, spec_info)
        end
        expect_punct(";")
        decls
      end

      # A typedef declaration: a run of comma-separated declarators sharing
      # `base_type`, each binding its name as a type (its "*" run and array
      # suffix applied) in the current ordinary scope. A typedef declarator may
      # not have an initializer (6.7.1); the declaration itself contributes no
      # AST node, so this returns an empty run.
      def parse_typedef_declaration(base_type, spec_info)
        loop do
          name_tok, type, _params, pointer_quals = parse_declarator(base_type)
          parse_attribute_specifiers # position d: a trailing attribute on the typedef name
          if peek.punct?("=")
            error_at(peek, "typedef '#{name_tok.value}' must not be initialized")
          end
          # A typedef of a const-qualified object type remembers that const so a
          # later use ("typedef const int ci; ci x;") makes x const; the same
          # top-level rule applies, so "typedef const int *cp;" (a pointer to
          # const) is not itself const.
          const = declarator_object_const(type, spec_info.const, pointer_quals)
          declare_typedef_name(name_tok, type, const)
          break unless peek.punct?(",")

          advance # ","
        end
        expect_punct(";")
        []
      end

      def parse_init_declarator(base_type, spec_info)
        name_tok, type, _params, pointer_quals = parse_declarator(base_type, allow_incomplete_array: true)
        parse_attribute_specifiers # position d: a trailing attribute on this local declarator
        reject_void_type(type, name_tok)
        reject_object_specifiers(name_tok, spec_info)
        const = declarator_object_const(type, spec_info.const, pointer_quals)
        initializer = nil
        if peek.punct?("=")
          if spec_info.storage == :extern
            error_at(name_tok, "'#{name_tok.value}' has both 'extern' and initializer")
          end
          advance # "="
          initializer = parse_initializer
          # A structural initializer (a brace list, or a string for a char array)
          # fixes the object's type — completing an inferred "[]" bound — and is
          # validated for shape here, so a later stage sees a finished type.
          if InitializerResolver.structural?(type, initializer)
            type = InitializerResolver.resolve(type, initializer).type
          end
        elsif type.array? && type.length.nil? && spec_info.storage != :extern
          # A block-scope `extern T a[];` references a file-scope array defined
          # elsewhere, an incomplete type that unit completes (6.7.6.2p1, 6.9.2),
          # so it is kept as-is. A non-extern `int a[];` in a block has no
          # initializer to complete it and no tentative-definition rule at block
          # scope, so it stays a diagnostic (gcc rejects it likewise).
          error_at(name_tok, "array size missing in '#{name_tok.value}'")
        end
        declare_ordinary_name(name_tok.value, type)
        AST::VariableDecl.new(name_tok.value, type, initializer, name_tok, const, spec_info.storage)
      end

      # Rejects the declaration specifiers that may sit on a function but not on
      # an object: "inline" on a variable or global is ill-formed ("inline" is a
      # function specifier, 6.7.4). Storage classes are already admitted here
      # (recorded for Phase B), so only "inline" is caught. Shared by the local
      # and file-scope object declarators.
      def reject_object_specifiers(name_tok, spec_info)
        return unless spec_info.inline_p

        error_at(name_tok, "variable '#{name_tok.value}' declared 'inline'")
      end

      # Whether the object a declarator declares is top-level const-qualified,
      # the only qualification M1 tracks. With no pointer/array/function
      # derivation the specifier's const applies directly ("const int x"); an
      # array likewise takes the specifier const (M1 treats the whole array
      # variable as const rather than only its elements, a deliberate
      # simplification); a pointer is const only when its outermost level bears
      # the qualifier ("int * const p" is const, "const int *p" is not); a
      # function type is never a const object. `pointer_quals` is the declarator's
      # leading "*" run, one const flag per level, so its last entry is the
      # outermost pointer — empty (a pointer built inside parentheses) reads as
      # not const, a tolerated M1 gap for "int (* const p)[3]".
      def declarator_object_const(type, specifier_const, pointer_quals)
        return pointer_quals.last || false if type.pointer?
        return false if type.function?

        specifier_const
      end

      # A file- or block-scope "_Static_assert ( constant-expression ,
      # string-literal ) ;" (6.7.10). The expression is folded like any other
      # constant-expression, with the same parse-time "sizeof <expression>"
      # resolution an array bound gets (#fold_time_sizeof) — asserting a size
      # relation over an expression is the idiom's main use (ruby.h's
      # RBIMPL_STATIC_ASSERT(…, sizeof *ptr == sizeof(size_t))). A zero value
      # fails the assertion, quoting the message the way gcc does. It declares
      # nothing, so — like a bare tag declaration or a typedef — it returns an
      # empty run of declarations.
      def parse_static_assert
        keyword_tok = advance # "_Static_assert"
        expect_punct("(")
        expr = parse_conditional_expression
        value = evaluate_constant_expression(expr, "static assertion expression is not an integer constant",
                                                   sizeof_expr: method(:fold_time_sizeof))
        expect_punct(",")
        message_tok = peek
        error_at(message_tok, "expected string literal in '_Static_assert'") unless message_tok.type == :string
        advance
        expect_punct(")")
        expect_punct(";")
        error_at(keyword_tok, "static assertion failed: \"#{message_tok.value}\"") if value.zero?
        []
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
        with_nesting_guard(brace_tok, "initializer") do
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
      # Returns [name_token_or_nil, type, function_params, pointer_quals], the
      # last being the declarator's leading "*" run as a list of per-level const
      # flags (see #parse_pointer_qualifiers) so an object declarator can settle
      # its top-level const-ness (see #declarator_object_const). Callers that do
      # not need the qualifiers simply ignore the trailing value.
      def parse_declarator(base, name_mode: :required, allow_incomplete_array: false)
        name_tok, build, function_params, pointer_quals =
          parse_declarator_builder(name_mode: name_mode, allow_incomplete_array: allow_incomplete_array)
        [name_tok, build.call(base), function_params, pointer_quals]
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
        # A parenthesized declarator recurses back here through
        # #parse_declarator_core, so guarding this entry bounds "int
        # ((((x))))"-style nesting (and the matching build-lambda recursion,
        # which can only run as deep as the syntactic nesting that survived).
        with_nesting_guard(peek, "declarator") do
          # A GNU attribute may open a declarator ("int (__attribute__((packed))
          # *p)"), including the nested declarator inside a "(...)"; it qualifies
          # nothing this subset models, so it is accepted and discarded here just
          # as at every other declarator position.
          parse_attribute_specifiers
          pointer_quals = parse_pointer_qualifiers
          name_tok, direct_build, function_params =
            parse_direct_declarator(name_mode: name_mode, allow_incomplete_array: allow_incomplete_array)
          build = lambda do |base|
            type = base
            pointer_quals.each { type = Type::Pointer.new(type) }
            direct_build.call(type)
          end
          [name_tok, build, function_params, pointer_quals]
        end
      end

      # A declarator's "*" run, each star optionally followed by a type-qualifier
      # list ("int * const p", "char * const * volatile q"). Returns one boolean
      # per star, true when that pointer level is const-qualified; "volatile" is
      # accepted and ignored, since M1 carries no qualified types. The list is in
      # textual order, so the first star wraps the base first (the innermost
      # pointer) and the last is the outermost — the level that qualifies the
      # declared object.
      def parse_pointer_qualifiers
        quals = []
        while consume_punct("*")
          const_here = false
          loop do
            if peek.keyword?("const")
              const_here = true
              advance
            elsif peek.keyword?("volatile")
              advance
            elsif peek.keyword?("__attribute__")
              # A GNU attribute may follow a pointer's "*" ("int * __attribute__
              # ((x)) p", "int (ATTR *)(void)"); it qualifies nothing modeled
              # here, so it is accepted and discarded like the other qualifiers.
              parse_attribute_specifiers
            elsif restrict_qualifier?(peek)
              # A "restrict" (or "__restrict"/"__restrict__") qualifier on this
              # pointer level: carries no semantics in this subset, so consumed
              # and dropped, exactly as "volatile" is.
              advance
            else
              break
            end
          end
          quals << const_here
        end
        quals
      end

      # Whether `tok` is one of the recognized "restrict" spellings — an ordinary
      # identifier, since none is a keyword here (see RESTRICT_SPELLINGS).
      def restrict_qualifier?(tok)
        tok.type == :ident && RESTRICT_SPELLINGS.include?(tok.value)
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
        name_tok, core_build, inner_params =
          parse_declarator_core(name_mode: name_mode, allow_incomplete_array: allow_incomplete_array)

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
      #
      # `allow_incomplete_array` is forwarded into a parenthesized inner
      # declarator: the parentheses are only grouping, so the array buried in
      # "int (*fp[])(void) = { ... }" is the object's own array and its "[]" is
      # deducible from the initializer exactly as a bare "int fp[] = { ... }"
      # would be. Dropping the flag here rejected such declarators (6.7.6.3).
      def parse_declarator_core(name_mode:, allow_incomplete_array:)
        if peek.punct?("(") && paren_starts_declarator?
          advance # "("
          name_tok, build, inner_params =
            parse_declarator_builder(name_mode: name_mode, allow_incomplete_array: allow_incomplete_array)
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
        # A GNU attribute may sit right after the "(" and before the inner
        # declarator ("int (__attribute__((packed)) *p)(void)"); look past it so
        # the token that actually decides — a "*", "[", "(" or a plain
        # identifier — is the one classified. A parameter list whose first
        # parameter opens with an attribute ("(__attribute__((x)) int a)") still
        # resolves correctly: past the attribute sits a type-specifier, which is
        # none of those, so it stays a parameter list.
        nxt = @tokens[index_after_attributes(@pos + 1)]
        return false if nxt.nil?
        return true if nxt.punct?("*") || nxt.punct?("[") || nxt.punct?("(")

        nxt.type == :ident && !typedef_name?(nxt.value)
      end

      # The token index just past any run of "__attribute__ (( ... ))" specifiers
      # starting at `index`, matching parentheses so an argument list of any
      # shape is skipped whole. Used only for lookahead (nothing is consumed):
      # #paren_starts_declarator? peers past an attribute to the token that
      # classifies a "(". Returns `index` unchanged when no attribute is present.
      def index_after_attributes(index)
        while @tokens[index]&.keyword?("__attribute__")
          index += 1
          depth = 0
          loop do
            tok = @tokens[index]
            break if tok.nil? || tok.eof?

            index += 1
            if tok.punct?("(")
              depth += 1
            elsif tok.punct?(")")
              depth -= 1
              break if depth.zero?
            end
          end
        end
        index
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
        # A parameter's array declarator may carry type qualifiers and/or
        # "static" inside the brackets (6.7.6.3p7): they qualify the pointer the
        # parameter adjusts to, and "static" is an optimization hint. This subset
        # adjusts a parameter array to an *unqualified* pointer, so these are
        # parsed and discarded. They are accepted in any array declarator here,
        # not only a parameter's — a mild over-acceptance of a strict-conformance
        # error this subset does not otherwise diagnose.
        skip_array_qualifiers
        if peek.punct?("]")
          error_at(bracket_tok, "array size must be an integer constant") unless allow_incomplete
          advance # "]"
          length = nil
        elsif peek.punct?("*") && peek_ahead(1)&.punct?("]")
          # "[*]" is an unspecified-size (VLA) array bound in a function
          # prototype (6.7.6.2p4); treated like "[]", an incomplete array the
          # parameter adjustment turns into a pointer.
          error_at(bracket_tok, "'[*]' not allowed in this context") unless allow_incomplete
          advance # "*"
          advance # "]"
          length = nil
        else
          expr = parse_conditional_expression
          length = evaluate_constant_expression(expr, "array size must be an integer constant",
                                                sizeof_expr: method(:fold_time_sizeof))
          expect_punct("]")
          error_at(expr.token, "array size must be positive") unless length.positive?
        end
        [:array, length, bracket_tok]
      end

      # Consumes the qualifier/"static" run allowed at the start of a parameter's
      # array declarator brackets (6.7.6.3p7), in any order ("static const 5",
      # "const static 5"). All are discarded: this subset neither qualifies the
      # adjusted pointer nor acts on the "static" size hint. "restrict" appears
      # here in its identifier spellings (see #restrict_qualifier?).
      def skip_array_qualifiers
        loop do
          if peek.keyword?("const") || peek.keyword?("volatile") || peek.keyword?("static")
            advance
          elsif restrict_qualifier?(peek)
            advance
          else
            break
          end
        end
      end

      # A direct-declarator's function suffix "(" parameter-type-list? ")". The
      # parameters are parsed (and array/function ones adjusted, see
      # #parse_parameter_declaration) here so the suffix can both build the
      # function type and, when it belongs to a real function, hand its
      # Parameter objects back for the body. Returns [:function, params,
      # paren_token, variadic], the variadic flag carrying the trailing "..."
      # forward to #apply_declarator_suffix so it lands on the FunctionType.
      def parse_function_suffix
        paren_tok = advance # "("
        params, variadic = parse_parameter_type_list
        expect_punct(")")
        [:function, params, paren_tok, variadic]
      end

      # Wraps `inner` in one declarator suffix, enforcing the constraints a
      # function or array derivation cannot satisfy (6.7.6.3): a function's
      # return type may be neither a function nor an array, and an array's
      # element may not be a function. A multidimensional array is an array whose
      # element is itself an array ("int a[2][13]" is a 2-element array of
      # "int[13]"); the suffixes are applied innermost-first (see
      # #parse_direct_declarator's reverse_each), so the inner dimension is a
      # complete array by the time the outer wraps it. Only that inner element
      # array may not be incomplete -- "int a[2][]" has element type "int[]" of
      # unknown stride (6.7.6.2p1) -- while the outermost dimension may still be
      # "[]" (deduced from an initializer or adjusted away on a parameter). The
      # suffix's own token (the "(" or "[") locates any diagnostic.
      def apply_declarator_suffix(suffix, inner)
        kind, data, tok, variadic = suffix
        if kind == :function
          error_at(tok, "function returning a function is not allowed") if inner.function?
          error_at(tok, "function returning an array is not allowed") if inner.array?
          Type::FunctionType.new(inner, data.map(&:type), variadic)
        else
          error_at(tok, "array of functions is not allowed") if inner.function?
          error_at(tok, "array has incomplete element type") if inner.array? && inner.incomplete?
          # A struct ending in a flexible array member has no fixed size, so it
          # cannot be an array element (6.7.2.1p18; its stride is unknown).
          if inner.struct? && inner.flexible_array_member?
            error_at(tok, "array type has a struct with a flexible array member as its element")
          end
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
        elsif peek.keyword?("__asm__")
          parse_asm_statement
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

      # A control-flow statement's body, parsed one nesting level deeper. The
      # body of an unbraced `if`/`while`/`do`/`for`/label recurses straight
      # back into #parse_statement, which would otherwise let a chain like
      # "if(1)if(1)..." recurse without ever passing through the block guard
      # and exhaust the Ruby stack (a SystemStackError the driver cannot
      # report as a diagnostic).
      def parse_nested_statement(token)
        with_nesting_guard(token, "statement") { parse_statement }
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
        then_stmt = parse_nested_statement(if_tok)
        else_stmt = nil
        if peek.keyword?("else")
          else_tok = advance
          else_stmt = parse_nested_statement(else_tok)
        end
        AST::If.new(condition, then_stmt, else_stmt, if_tok)
      end

      def parse_while_statement
        while_tok = advance # "while"
        expect_punct("(")
        condition = parse_expression
        expect_punct(")")
        body = parse_nested_statement(while_tok)
        AST::While.new(condition, body, while_tok)
      end

      def parse_do_while_statement
        do_tok = advance # "do"
        body = parse_nested_statement(do_tok)
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
        body = parse_nested_statement(for_tok)
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

      # A GNU inline-assembly statement (DESIGN R7): only the degenerate barrier
      # form is supported, spelled `__asm__` (never `asm`/`__asm`). The grammar
      # is `__asm__ volatile* "(" template (":" section)* ")" ";"`, "volatile"
      # admitting its GNU "__volatile"/"__volatile__" spellings too (both lex to
      # the same keyword token, see LexemeReader::KEYWORD_ALIASES). The template
      # must be an (adjacent run of) empty string literal(s); a non-empty one, or
      # any real operand in the output/input sections, is diagnosed. The clobber
      # section's strings ("memory", "cc", ...) are accepted and discarded.
      # Nothing is lowered — see AST::InlineAsm.
      def parse_asm_statement
        asm_tok = advance # "__asm__"
        # Any number of volatile qualifiers.
        advance while peek.keyword?("volatile")
        expect_punct("(")
        parse_asm_template(asm_tok)
        parse_asm_operand_sections(asm_tok) if peek.punct?(":")
        expect_punct(")")
        expect_punct(";")
        AST::InlineAsm.new(asm_tok)
      end

      # The assembly template: one or more adjacent string literals, whose
      # concatenation must be empty. A non-empty template names real instructions
      # this backend cannot emit, so it is rejected at the keyword.
      def parse_asm_template(asm_tok)
        tok = peek
        error_at(tok, "expected string literal in inline assembly") unless tok.type == :string
        empty = true
        while peek.type == :string
          empty &&= peek.value.empty?
          advance
        end
        error_at(asm_tok, "non-empty inline assembly is not supported") unless empty
      end

      # The ":"-separated sections after the template. By position the first is
      # the output operands and the second the input operands, both of which must
      # be empty (a real operand is unsupported); the third and any later section
      # is a clobber list of string literals, accepted and discarded.
      def parse_asm_operand_sections(asm_tok)
        section = 0
        while peek.punct?(":")
          advance # ":"
          if section < 2
            parse_asm_empty_operand_section(asm_tok)
          else
            parse_asm_clobbers(asm_tok)
          end
          section += 1
        end
      end

      # An output/input operand section, which must be empty: the next token ends
      # the section (":" for the next one, ")" for the whole construct). Anything
      # else is an operand expression this subset does not support.
      def parse_asm_empty_operand_section(asm_tok)
        return if peek.punct?(":") || peek.punct?(")")

        error_at(peek, "inline assembly operands are not supported")
      end

      # A clobber section: a comma-separated list of string literals (or empty).
      # The names are discarded — this backend never reorders, so a clobber
      # constrains nothing.
      def parse_asm_clobbers(_asm_tok)
        return if peek.punct?(":") || peek.punct?(")")

        loop do
          tok = peek
          unless tok.type == :string
            error_at(tok, "expected string literal in inline assembly clobber list")
          end
          advance
          break unless peek.punct?(",")

          advance # ","
        end
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
        body = parse_nested_statement(switch_tok)
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
        body = parse_nested_statement(case_tok)
        AST::Case.new(value, body, case_tok)
      end

      # "default : statement": the fall-through label of a switch, carrying no
      # constant. At most one may appear per switch, which the generator checks.
      def parse_default_statement
        default_tok = advance # "default"
        expect_punct(":")
        body = parse_nested_statement(default_tok)
        AST::Default.new(body, default_tok)
      end

      # "identifier : statement": a labeled statement, the target of a goto. The
      # identifier and its ":" have already been confirmed by the two-token
      # lookahead in #parse_statement; the prefixed statement follows.
      def parse_labeled_statement
        name_tok = advance # identifier
        advance # ":"
        body = parse_nested_statement(name_tok)
        AST::Label.new(name_tok.value, body, name_tok)
      end

      def parse_compound_statement
        brace_tok = expect_punct("{")
        with_nesting_guard(brace_tok, "block") do
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
      # the compound-assignment operators. The right operand recurses back here,
      # so a long "a = b = c = ..." chain deepens through this method rather than
      # through #parse_cast_expression (which has already returned by the time the
      # "=" is seen); it therefore carries its own nesting guard.
      def parse_assignment_expression
        with_nesting_guard(peek, "expression") do
          node = parse_conditional_expression
          tok = peek
          if tok.punct?("=")
            advance
            error_at(tok, "expression is not assignable") unless assignable?(node)
            AST::Assignment.new(node, parse_assignment_expression, tok)
          elsif (op = tok.type == :punct ? COMPOUND_ASSIGNMENT_OPERATORS[tok.value] : nil)
            advance
            error_at(tok, "expression is not assignable") unless assignable?(node)
            AST::CompoundAssignment.new(op, node, parse_assignment_expression, tok)
          else
            node
          end
        end
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
      # Both arms recurse — the "then" through #parse_expression and the "else"
      # directly — so a "a ? b : c ? d : ..." chain deepens through this method,
      # above where #parse_cast_expression's guard would catch it; it is guarded
      # here on the shared counter.
      def parse_conditional_expression
        with_nesting_guard(peek, "expression") do
          node = parse_logical_or_expression
          if peek.punct?("?")
            question_tok = advance
            then_expr = parse_expression
            expect_punct(":")
            else_expr = parse_conditional_expression
            AST::Conditional.new(node, then_expr, else_expr, question_tok)
          else
            node
          end
        end
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
      # This is the single choke point every deepening expression form re-enters
      # exactly once per nesting level — a parenthesized "( expression )" (via
      # primary-expression), a "!"/"-"/"*"/... unary chain, a "( type-name )"
      # cast chain, a "?:" arm, a subscript or a call argument all descend back
      # through here — so guarding it alone bounds the depth of the whole
      # expression grammar with no double counting.
      def parse_cast_expression
        with_nesting_guard(peek, "expression") do
          # A "__extension__" prefix (a GNU marker with no semantic effect) binds
          # like a cast operator: it is consumed here and the cast-expression it
          # governs is parsed in its place ("__extension__ x", "y = __extension__ z").
          if peek.keyword?("__extension__")
            advance
            parse_cast_expression
          elsif peek.punct?("(") && peek_ahead(1) && type_specifier?(peek_ahead(1))
            paren_tok = advance # "("
            # An unsized "[]" is admitted here so a compound literal can infer its
            # bound ("(int[]){1,2,3}"); a plain cast to that incomplete type is
            # rejected below, once the following "{" (or its absence) settles the
            # two forms apart.
            type = parse_type_name(allow_incomplete_array: true)
            expect_punct(")")
            # A "{" after "( type-name )" opens a compound literal (6.5.2.5),
            # not a cast: "( type-name ) { initializer-list }" builds an unnamed
            # object of that type. It is a postfix-expression, so any trailing
            # postfix suffix ("(json_frame){...}.type") binds to it. Every other
            # token keeps the ordinary cast reading "( type-name ) cast-expr".
            if peek.punct?("{")
              parse_postfix_suffixes(parse_compound_literal(type, paren_tok))
            else
              if type.array? && type.length.nil?
                error_at(paren_tok, "array size missing in cast to array type")
              end
              AST::Cast.new(type, parse_cast_expression, paren_tok)
            end
          else
            parse_unary_expression
          end
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

      # The unary tier recurses through several forms that never pass through
      # #parse_cast_expression — "sizeof sizeof ... x" recurses back here, and a
      # prefix "++"/"--" likewise — so a chain of them would escape a guard placed
      # only on the cast tier. Guarding the unary entry catches those, and the
      # "!"/"-"/... operators (which do recurse through the cast tier) as well.
      def parse_unary_expression
        with_nesting_guard(peek, "expression") do
          if peek.keyword?("sizeof")
            parse_sizeof
          elsif peek.keyword?("_Alignof")
            parse_alignof
          elsif peek.keyword?("__builtin_va_start")
            parse_va_start
          elsif peek.keyword?("__builtin_va_arg")
            parse_va_arg
          elsif peek.keyword?("__builtin_va_end")
            parse_va_end
          elsif peek.keyword?("__builtin_va_copy")
            parse_va_copy
          elsif peek.keyword?("__builtin_expect")
            parse_builtin_expect
          elsif peek.keyword?("__builtin_alloca")
            parse_builtin_alloca
          elsif peek.keyword?("__builtin_offsetof")
            parse_builtin_offsetof
          elsif peek.keyword?("__builtin_constant_p")
            parse_builtin_constant_p
          elsif peek.keyword?("__builtin_choose_expr")
            parse_builtin_choose_expr
          elsif peek.keyword?("__builtin_ctz")
            parse_builtin_bit_scan(:forward, 4)
          elsif peek.keyword?("__builtin_ctzll")
            parse_builtin_bit_scan(:forward, 8)
          elsif peek.keyword?("__builtin_clz")
            parse_builtin_bit_scan(:reverse, 4)
          elsif peek.keyword?("__builtin_clzll")
            parse_builtin_bit_scan(:reverse, 8)
          elsif peek.keyword?("__builtin_unreachable")
            parse_builtin_unreachable
          elsif peek.keyword?("__builtin_memcpy")
            parse_builtin_memcpy
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

      # "_Alignof ( type-name )" (6.5.3.4): the alignment of a written type. Only
      # the parenthesized type-name form exists — there is no operand form as
      # sizeof has — so the "(" and type-name are read unconditionally. The
      # generator folds it to a size_t constant, like sizeof of a type.
      def parse_alignof
        alignof_tok = advance # "_Alignof"
        expect_punct("(")
        type = parse_type_name
        expect_punct(")")
        AST::AlignofType.new(type, alignof_tok)
      end

      # "__builtin_va_start ( assignment-expression , identifier )": the va_list
      # to initialize and the name of the last fixed parameter (a bare
      # identifier, not an expression, since the ABI locates the variable part
      # relative to that parameter). The generator checks the name against the
      # enclosing function's last named parameter.
      def parse_va_start
        keyword_tok = advance # "__builtin_va_start"
        expect_punct("(")
        ap = parse_assignment_expression
        expect_punct(",")
        name_tok = expect_ident
        expect_punct(")")
        AST::VaStart.new(ap, name_tok.value, keyword_tok)
      end

      # "__builtin_va_arg ( assignment-expression , type-name )": the va_list and
      # the type-name the next argument is fetched as. The type-name uses the
      # same abstract-declarator grammar as sizeof/casts.
      def parse_va_arg
        keyword_tok = advance # "__builtin_va_arg"
        expect_punct("(")
        ap = parse_assignment_expression
        expect_punct(",")
        type = parse_type_name
        expect_punct(")")
        AST::VaArg.new(ap, type, keyword_tok)
      end

      # "__builtin_va_end ( assignment-expression )": the va_list whose traversal
      # ends. A no-op on System V beyond the operand's type check.
      def parse_va_end
        keyword_tok = advance # "__builtin_va_end"
        expect_punct("(")
        ap = parse_assignment_expression
        expect_punct(")")
        AST::VaEnd.new(ap, keyword_tok)
      end

      # "__builtin_va_copy ( assignment-expression , assignment-expression )":
      # the destination and source va_lists, whose state the generator copies as
      # a whole tag from the second to the first.
      def parse_va_copy
        keyword_tok = advance # "__builtin_va_copy"
        expect_punct("(")
        dest = parse_assignment_expression
        expect_punct(",")
        src = parse_assignment_expression
        expect_punct(")")
        AST::VaCopy.new(dest, src, keyword_tok)
      end

      # "__builtin_expect ( exp , c )": exactly two arguments, parsed as an
      # ordinary argument list so a wrong count is reported as an arity error
      # rather than a bare punctuator-mismatch. The generator settles their
      # conversion to `long`.
      def parse_builtin_expect
        keyword_tok = advance # "__builtin_expect"
        expect_punct("(")
        args = parse_argument_expression_list
        expect_punct(")")
        unless args.size == 2
          error_at(keyword_tok, "'__builtin_expect' expects 2 arguments, have #{args.size}")
        end
        AST::BuiltinExpect.new(args[0], args[1], keyword_tok)
      end

      # "__builtin_alloca ( n )": exactly one argument, the byte count. Like
      # __builtin_expect it is parsed as an argument list so a wrong count is an
      # arity diagnostic.
      def parse_builtin_alloca
        keyword_tok = advance # "__builtin_alloca"
        expect_punct("(")
        args = parse_argument_expression_list
        expect_punct(")")
        unless args.size == 1
          error_at(keyword_tok, "'__builtin_alloca' expects 1 argument, have #{args.size}")
        end
        AST::BuiltinAlloca.new(args[0], keyword_tok)
      end

      # "__builtin_offsetof ( type-name , member-designator )": the aggregate
      # type and the member whose offset is wanted. The member-designator is a
      # leading member name followed by any run of ".name" and "[ expression ]"
      # steps (the gcc extension over a bare identifier, so "s.a.b[2].c" is
      # writable). The steps are collected into a designator array the constant
      # evaluator later walks to fold the offset; the array is never empty, since
      # a designator always begins with a member name.
      def parse_builtin_offsetof
        keyword_tok = advance # "__builtin_offsetof"
        expect_punct("(")
        type = parse_type_name
        expect_punct(",")
        designator = parse_member_designator
        expect_punct(")")
        AST::BuiltinOffsetof.new(type, designator, keyword_tok)
      end

      # "__builtin_constant_p ( assignment-expression )": one operand, which is
      # never evaluated — the fold to 1/0 happens later (the constant evaluator
      # and the generator), so any expression at all is accepted here, including
      # one that references a variable or calls a function. The value is int.
      def parse_builtin_constant_p
        keyword_tok = advance # "__builtin_constant_p"
        expect_punct("(")
        expr = parse_assignment_expression
        expect_punct(")")
        AST::BuiltinConstantP.new(expr, keyword_tok)
      end

      # "__builtin_choose_expr ( const-expr , expr-true , expr-false )": the
      # first operand is an integer constant-expression evaluated now; the whole
      # form is replaced at parse time by whichever of the two remaining operands
      # it selects (non-zero picks expr-true, zero picks expr-false), so no AST
      # node of its own is needed and the chosen operand's type flows through
      # unchanged. All three are still parsed, so a syntax error in the branch
      # that loses is still caught; only the winner reaches code generation. A
      # non-constant first operand is diagnosed.
      def parse_builtin_choose_expr
        keyword_tok = advance # "__builtin_choose_expr"
        expect_punct("(")
        condition = parse_assignment_expression
        expect_punct(",")
        when_true = parse_assignment_expression
        expect_punct(",")
        when_false = parse_assignment_expression
        expect_punct(")")
        selector = evaluate_constant_expression(
          condition, "first argument to '__builtin_choose_expr' is not a constant expression"
        )
        selector.zero? ? when_false : when_true
      end

      # "__builtin_ctz/ctzll/clz/clzll ( assignment-expression )": one integer
      # operand whose trailing (`:forward`) or leading (`:reverse`) zero bits are
      # counted over `width` bytes. The generator settles the operand's integer
      # type check and lowers the bit scan; the result is int.
      def parse_builtin_bit_scan(direction, width)
        keyword_tok = advance # the "__builtin_ctz"/... keyword
        expect_punct("(")
        operand = parse_assignment_expression
        expect_punct(")")
        AST::BuiltinBitScan.new(operand, direction, width, keyword_tok)
      end

      # "__builtin_unreachable ()": no operands. Lowers to no code (rubycc does
      # not optimize); its value is void.
      def parse_builtin_unreachable
        keyword_tok = advance # "__builtin_unreachable"
        expect_punct("(")
        expect_punct(")")
        AST::BuiltinUnreachable.new(keyword_tok)
      end

      # "__builtin_memcpy ( dst , src , n )": rewritten to an ordinary call of
      # the libc function "memcpy", so it links against the C library's memcpy
      # like the plain call would. The generator seeds a builtin prototype for
      # "memcpy" (void *(void *, const void *, unsigned long)), so this compiles
      # even when <string.h> is not included, matching gcc's builtin.
      def parse_builtin_memcpy
        keyword_tok = advance # "__builtin_memcpy"
        expect_punct("(")
        args = parse_argument_expression_list
        expect_punct(")")
        unless args.size == 3
          error_at(keyword_tok, "'__builtin_memcpy' expects 3 arguments, have #{args.size}")
        end
        AST::Call.new(AST::VariableRef.new("memcpy", keyword_tok), args, keyword_tok)
      end

      # member-designator = identifier ( "." identifier | "[" expression "]" )*:
      # the leading member name has no ".", every following member step does, and
      # a subscript step takes a constant-expression closed by "]". Any other
      # token where a "." or "[" is expected ends the designator, leaving the ")"
      # for the caller.
      def parse_member_designator
        first_tok = expect_ident
        designator = [AST::OffsetofMember.new(first_tok.value, first_tok)]
        loop do
          if peek.punct?(".")
            advance # "."
            member_tok = expect_ident
            designator << AST::OffsetofMember.new(member_tok.value, member_tok)
          elsif peek.punct?("[")
            bracket_tok = advance # "["
            index = parse_conditional_expression
            expect_punct("]")
            designator << AST::OffsetofIndex.new(index, bracket_tok)
          else
            return designator
          end
        end
      end

      # type-name = type-specifier abstract-declarator?: a base type-specifier
      # and an abstract declarator (no name). Shared by "sizeof ( type-name )"
      # and the cast "( type-name )", so a function pointer, an array pointer or
      # a plain pointer type can be written there ("sizeof(int (*)(int))",
      # "(int (*)(int))p").
      def parse_type_name(allow_incomplete_array: false)
        _name_tok, type = parse_declarator(parse_type_specifier, name_mode: :forbidden,
                                                                 allow_incomplete_array: allow_incomplete_array)
        type
      end

      # A compound literal "( type-name ) { initializer-list }" (6.5.2.5), the
      # "(" and type-name already consumed by the cast tier. The brace list is
      # parsed with the ordinary initializer machinery; when it structurally
      # fits `type` (a brace list always does, a string an aggregate char array)
      # the type is resolved once here so an inferred "(int[]){...}" bound is
      # filled in — the same completion #parse_init_declarator performs — and the
      # finished type rides on the node. The generator lays out the object and
      # re-resolves the placements.
      def parse_compound_literal(type, paren_tok)
        initializer = parse_initializer_list
        if InitializerResolver.structural?(type, initializer)
          type = InitializerResolver.resolve(type, initializer).type
        end
        AST::CompoundLiteral.new(type, initializer, paren_tok)
      end

      # A postfix-expression is a primary-expression followed by any run of
      # postfix suffixes in source order: a call "( args )", a subscript
      # "[ i ]", a member access "." / "->" and a postfix "++"/"--". A call is
      # just another suffix, so its callee may be any postfix-expression —
      # "f(x)", "(*fp)(x)", "table[i](x)" and "s.fp(x)" all parse the same way,
      # with the AST::Call carrying the callee expression it followed.
      def parse_postfix_expression
        parse_postfix_suffixes(parse_primary_expression)
      end

      # Applies any run of postfix suffixes (call, subscript, member access,
      # postfix "++"/"--") to an already-parsed postfix-expression head. Split
      # out from #parse_postfix_expression so a compound literal — which the cast
      # tier builds after "( type-name )" and which is itself a
      # postfix-expression (6.5.2p1) — can carry the same suffixes, letting
      # "(json_frame){...}.type" and "(int[]){1,2,3}[i]" parse.
      def parse_postfix_suffixes(node)
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
        elsif tok.type == :float
          advance
          # The suffix (from the lexer) fixes the constant's type: "f"/"F" is
          # float, everything else (plain, or "l"/"L" long double) is double.
          type = tok.suffix == "f" ? Type::Float : Type::Double
          AST::FloatLit.new(tok.value, type, tok)
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
          # A "(" immediately followed by "{" opens a GNU statement expression
          # "( { block-item* } )" (a GCC extension): the braces enclose a
          # compound-statement, and its last expression-statement (if any) gives
          # the whole construct its value and type. Every other "(" is an
          # ordinary parenthesized expression. #parse_compound_statement carries
          # its own nesting guard and pushes the block's tag/ordinary scopes.
          if peek_ahead(1)&.punct?("{")
            advance # "("
            body = parse_compound_statement
            expect_punct(")")
            AST::StatementExpr.new(body, tok)
          else
            advance
            node = parse_expression
            expect_punct(")")
            node
          end
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
      # scope. Its main job is to shadow a typedef name or enum constant of the
      # same name from an outer scope, so a redeclaration of an ordinary name (a
      # genuine error the generator reports) is deliberately not diagnosed here.
      # The declared `type` is kept as the entry's payload so a constant
      # expression folded during parsing can resolve "sizeof <variable>" (see
      # #fold_time_sizeof), which the type-table-free ConstantEvaluator otherwise
      # cannot; it is nil only for the synthetic entries that predate a type.
      def declare_ordinary_name(name, type = nil)
        @ordinary_scopes.last[name] = OrdinaryName.new(:ordinary, type)
      end

      # Binds a typedef name to its resolved type (and whether it names a
      # const-qualified object type) in the current ordinary scope. A name
      # already bound there — by an earlier typedef (even to the same type, which
      # M1 rejects for simplicity), or by any other declaration — is a
      # redefinition.
      def declare_typedef_name(name_tok, type, const)
        if @ordinary_scopes.last.key?(name_tok.value)
          error_at(name_tok, "redefinition of typedef '#{name_tok.value}'")
        end
        @ordinary_scopes.last[name_tok.value] = OrdinaryName.new(:typedef, [type, const])
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
      def evaluate_constant_expression(node, message, sizeof_expr: nil)
        ConstantEvaluator.evaluate(node, sizeof_expr: sizeof_expr)
      rescue ConstantEvaluator::NotConstant => e
        error_at(e.token, message)
      rescue ConstantEvaluator::DivisionByZero => e
        error_at(e.token, "division by zero in constant expression")
      end

      # Resolves a "sizeof <expression>" operand to its byte size at parse time,
      # for the ConstantEvaluator folding an array bound (see #parse_array_suffix)
      # -- the one constant context reduced while parsing, where "sizeof x" would
      # otherwise be a non-constant for want of a type table. The operand's type
      # is inferred by #sizeof_operand_type over the forms a real array bound
      # reaches (a named object, a string literal, a subscript, a dereference, a
      # cast -- notably ruby.h's rb_strlen_lit, "(sizeof(s "") / sizeof(s ""[0]))
      # - 1", which sizes both a string literal and its element). sizeof measures
      # its immediate operand undecayed (6.5.3.4), so "sizeof arr" is the whole
      # array. An operand whose type cannot be inferred, or one of
      # incomplete/void/function type with no size, stays a NotConstant so the
      # bound reports "not an integer constant" rather than a wrong value.
      def fold_time_sizeof(node)
        type = sizeof_operand_type(node.operand)
        if type.nil? || type.void? || type.function? || (type.array? && type.incomplete?)
          raise ConstantEvaluator::NotConstant, node.token
        end

        type.size
      end

      # The type a "sizeof" operand expression has, inferred without the
      # generator's symbol table, or nil when a form outside this small set is
      # met. A subscript and a dereference each decay their base (an array to a
      # pointer to its element) and yield the pointed-to type; a cast is its named
      # type; a named object's type is the one the ordinary scope recorded; a
      # member access ("." or "->") resolves against its base's struct/union type
      # -- sqlite3's "char dbFileVers[sizeof(pPager->dbFileVers)]" is exactly this
      # shape, an array bound sized from a pointer parameter's member. Only what
      # an array-bound constant expression realistically uses is covered.
      def sizeof_operand_type(node)
        case node
        when AST::StringLit
          Type::Array.new(Type::Char, node.value.bytesize + 1)
        when AST::VariableRef
          entry = lookup_ordinary(node.name)
          entry && entry.kind == :ordinary ? entry.value : nil
        when AST::Subscript
          element_of(sizeof_operand_type(node.target))
        when AST::Unary
          node.op == :deref ? element_of(sizeof_operand_type(node.operand)) : nil
        when AST::Cast
          node.type
        when AST::MemberAccess
          base = sizeof_operand_type(node.base)
          base = element_of(base) if node.arrow
          member_sizeof_type(base, node.member)
        end
      end

      # The element type reached by subscripting or dereferencing a base of type
      # `type`: an array decays to a pointer first, so both an array and a pointer
      # yield their element/pointee. Anything else (or an unknown base) has none.
      def element_of(type)
        return nil if type.nil?
        return type.element if type.array?

        type.target if type.pointer?
      end

      # The type of member `name` in a struct/union `type`, for #sizeof_operand_type
      # resolving "sizeof base.member"/"sizeof base->member" -- nil when `type`
      # is not a completed struct/union, the member does not exist, or it is a
      # bit-field, since a bit-field has no size to take (6.5.3.4p1) and so must
      # stay a NotConstant rather than fold to a wrong value. #struct? alone
      # tells a struct/union base apart from every other type (it answers true
      # for both, see Type::StructType), so a plain `sizeof x.m` with `x` of a
      # non-aggregate type -- syntactically parseable, only later rejected by
      # the generator -- stops here rather than reaching #union?, which only
      # Type::StructType implements.
      def member_sizeof_type(type, name)
        return nil if type.nil? || !type.struct?

        member = type.member(name)
        member && member.bit_width.nil? ? member.type : nil
      end

      # Whether the initializer subtree uses `sizeof <expression>` (as opposed to
      # `sizeof(type-name)`) anywhere. Such an operand's type can only be
      # inferred with the symbol table the generator holds, so its presence tells
      # #parse_global_declarator to defer folding to the generator rather than
      # evaluate the initializer here. The walk descends only through AST nodes
      # (each a `Data` under this AST module), so it never recurses into the
      # Type or Token objects a node's fields also carry.
      def references_sizeof_expr?(node)
        return true if node.is_a?(AST::SizeofExpr)
        return false unless ast_node?(node)

        node.deconstruct_keys(nil).each_value do |field|
          values = field.is_a?(Array) ? field : [field]
          return true if values.any? { |value| references_sizeof_expr?(value) }
        end
        false
      end

      # Whether the initializer subtree takes an address ("&x") anywhere. Such an
      # expression reduces only through the generator's address-constant
      # machinery (the "(size_t)&((T*)0)->m" offsetof idiom folds to a member's
      # byte offset), not the parser's type-table-free evaluator, so its presence
      # defers folding of an integer initializer to the generator — mirroring
      # #references_sizeof_expr?. The walk descends only through AST nodes.
      def references_address_of?(node)
        return true if node.is_a?(AST::Unary) && node.op == :addr
        return false unless ast_node?(node)

        node.deconstruct_keys(nil).each_value do |field|
          values = field.is_a?(Array) ? field : [field]
          return true if values.any? { |value| references_address_of?(value) }
        end
        false
      end

      # Whether `value` is one of this module's AST nodes — a `Data` instance
      # whose class lives under `Rubycc::Front::AST` — so the initializer walk
      # descends into it but not into the tokens, types or literals a field may
      # hold.
      def ast_node?(value)
        value.is_a?(Data) && AST.constants.any? { |c| AST.const_get(c).equal?(value.class) }
      end
    end
  end
end
