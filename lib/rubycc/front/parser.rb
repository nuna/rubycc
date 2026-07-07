# frozen_string_literal: true

require_relative "ast"
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
    #                               ( "(" parameter-type-list? ")"
    #                                 (";" | compound-statement)   -- function
    #                               | global-declarator-suffix
    #                                 ("," declarator global-declarator-suffix)*
    #                                 ";" )                         -- variables
    #   global-declarator-suffix  = ("[" integer-constant "]")?
    #                               ("=" constant-initializer)?
    #   constant-initializer      = ("+" | "-")* integer-constant
    #   type-specifier            = "int" | "char" | "void"
    #                             | struct-or-union-specifier
    #   struct-or-union-specifier = "struct" identifier? "{" struct-declaration+ "}"
    #                             | "struct" identifier
    #   struct-declaration        = type-specifier declarator
    #                               ("," declarator)* ";"
    #   parameter-type-list       = "void"
    #                             | parameter-declaration
    #                               ("," parameter-declaration)*
    #   parameter-declaration     = type-specifier declarator?
    #   declarator                = "*"* direct-declarator
    #   direct-declarator         = identifier ("[" integer-constant "]")?
    #   compound-statement        = "{" block-item* "}"
    #   block-item                = declaration | statement
    #   declaration               = type-specifier ";"
    #                             | type-specifier init-declarator
    #                               ("," init-declarator)* ";"
    #   init-declarator           = declarator ("=" assignment-expression)?
    #   statement                 = return-statement | expression-statement
    #                             | selection-statement | iteration-statement
    #                             | jump-statement | compound-statement
    #   return-statement          = "return" expression? ";"
    #   expression-statement      = expression? ";"
    #   selection-statement       = "if" "(" expression ")" statement
    #                               ("else" statement)?
    #   iteration-statement       = "while" "(" expression ")" statement
    #                             | "do" statement "while" "(" expression ")" ";"
    #                             | "for" "(" for-init expression? ";"
    #                               expression? ")" statement
    #   for-init                  = declaration | expression? ";"
    #   jump-statement            = "break" ";" | "continue" ";"
    #   expression                = assignment-expression
    #                               ("," assignment-expression)*
    #   assignment-expression     = conditional-expression
    #                               (("=" | "+=" | "-=" | "*=" | "/=" | "%="
    #                                | "&=" | "|=" | "^=" | "<<=" | ">>=")
    #                                assignment-expression)?
    #   conditional-expression    = logical-OR-expression
    #                               ("?" expression ":" conditional-expression)?
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
    #   type-name                 = type-specifier "*"*
    #   postfix-expression        = (primary-expression
    #                               | identifier "(" argument-expression-list? ")")
    #                               ("[" expression "]" | "." identifier
    #                                | "->" identifier | "++" | "--")*
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

      # The keywords that open a declaration, each naming a base Rubycc::Type.
      # "void" is only ever valid as a function's return type or as the target
      # of a pointer; every other use is rejected by #reject_void_type.
      TYPE_SPECIFIERS = { "int" => Type::Int, "char" => Type::Char, "void" => Type::Void }.freeze

      # System V AMD64 passes the first six integer arguments in registers;
      # this subset rejects any function with more parameters (or arguments).
      MAX_PARAMS = 6

      def initialize(tokens)
        @tokens = tokens
        @pos = 0
        # Struct tags live in their own namespace, separate from variables and
        # functions, and follow the same block scoping. @tag_scopes is a stack
        # of "tag name -> Type::StructType" maps, innermost last, with the
        # file scope at the bottom; a compound-statement (and a for-loop's own
        # parentheses, and a function body) pushes a fresh map so a struct
        # defined inside a block shadows an outer one and vanishes at the block's
        # end. Tag resolution happens here, at parse time, because every other
        # type is built here too — the generator only ever consumes finished
        # Type objects.
        @tag_scopes = [{}]
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
      # function-call "identifier (" from a bare identifier reference.
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
      # declaration. Both begin with a type-specifier, its "*" run and a name; a
      # following "(" marks the function form, anything else the variable form.
      def parse_external_declaration
        type_tok = peek
        base_type = parse_type_specifier

        # "struct point { ... };" (or "struct node;") with no declarator only
        # declares or defines the tag, which parse_type_specifier already
        # registered; it contributes no object and no code, so it flattens away
        # to an empty run of declarations.
        if peek.punct?(";")
          advance
          return []
        end

        type = parse_pointer_declarator(base_type)
        name_tok = expect_ident

        if peek.punct?("(")
          parse_function(type, name_tok, type_tok)
        else
          parse_global_declaration(base_type, type, name_tok)
        end
      end

      # The function form of an external declaration, its name and return type
      # already read: int, char, void or a pointer to any of those (including
      # void, "void *") are all valid return types.
      def parse_function(return_type, name_tok, return_tok)
        expect_punct("(")
        params = parse_parameter_type_list
        expect_punct(")")

        if peek.punct?(";")
          advance
          AST::FunctionDecl.new(name_tok.value, return_type, params, return_tok)
        else
          parse_function_definition(name_tok.value, return_type, params, return_tok)
        end
      end

      # The file-scope variable form of an external declaration: a
      # comma-separated run of declarators sharing `base_type`, the first of
      # which (`first_type`/`first_name_tok`) has already been read. Each
      # declarator yields one GlobalDecl; the run ends at ";".
      def parse_global_declaration(base_type, first_type, first_name_tok)
        decls = [parse_global_declarator(first_type, first_name_tok)]
        while peek.punct?(",")
          advance
          type = parse_pointer_declarator(base_type)
          name_tok = expect_ident
          decls << parse_global_declarator(type, name_tok)
        end
        expect_punct(";")
        decls
      end

      # One global declarator: the array suffix and an optional "= constant"
      # initializer. A global may only be initialized by an integer/character
      # constant (with an optional sign); an array, a non-constant expression, a
      # string literal or an initializer list is rejected uniformly with
      # "unsupported initializer for global variable".
      def parse_global_declarator(type, name_tok)
        type = parse_array_declarator(type)
        reject_void_type(type, name_tok)
        initializer_value = nil
        if peek.punct?("=")
          eq_tok = advance
          if type.array? || type.struct?
            error_at(eq_tok, "unsupported initializer for global variable")
          end
          initializer_value = parse_constant_initializer(eq_tok)
        end
        AST::GlobalDecl.new(name_tok.value, type, initializer_value, name_tok)
      end

      # Folds a global's initializer to a Ruby Integer at parse time. Only an
      # integer or character constant, optionally preceded by unary "+"/"-"
      # signs, is a valid constant initializer; the folded value must be
      # immediately followed by "," or ";", so a non-constant expression like
      # "1 + 2" (or an identifier, a string or an initializer list) is rejected
      # with "unsupported initializer for global variable" located at "=".
      def parse_constant_initializer(eq_tok)
        negate = false
        loop do
          if peek.punct?("-")
            advance
            negate = !negate
          elsif peek.punct?("+")
            advance
          else
            break
          end
        end
        tok = peek
        follower = peek_ahead(1)
        unless tok.type == :num && follower && (follower.punct?(";") || follower.punct?(","))
          error_at(eq_tok, "unsupported initializer for global variable")
        end
        advance
        negate ? -tok.value : tok.value
      end

      # type-specifier = "int" | "char" | "void" | struct-or-union-specifier:
      # consumes the specifier and returns the base Rubycc::Type any leading
      # "*" run then builds a pointer from. A "struct" hands off to
      # #parse_struct_specifier, which resolves or defines the tag.
      def parse_type_specifier
        tok = peek
        return parse_struct_specifier if tok.keyword?("struct")

        base = type_specifier?(tok) && TYPE_SPECIFIERS[tok.value]
        error_at(tok, "expected type specifier") unless base

        advance
        base
      end

      # struct-or-union-specifier: a "struct" keyword, an optional tag, and an
      # optional "{ ... }" body. Three shapes result:
      #   * "struct tag { ... }" / "struct { ... }" — a definition; the tagged
      #     one is registered (or completed) in the current tag scope, an
      #     anonymous one is a fresh unnamed type. #parse_struct_body lays it out.
      #   * "struct tag" — a reference; resolved through the tag scopes, or, when
      #     the tag is unknown, forward-declared as an incomplete struct in the
      #     current scope (so "struct node;" and a pointer to a not-yet-defined
      #     tag both work).
      def parse_struct_specifier
        struct_tok = advance # "struct"
        tag_tok = peek.type == :ident ? advance : nil
        tag = tag_tok&.value

        if peek.punct?("{")
          struct_type = tag ? define_struct_tag(tag, struct_tok) : Type::StructType.new(nil)
          parse_struct_body(struct_type)
          struct_type
        elsif tag
          reference_struct_tag(tag)
        else
          error_at(struct_tok, "expected identifier or '{' after 'struct'")
        end
      end

      # Resolves the tag being *defined* to the StructType #parse_struct_body
      # will lay out. A tag already declared in the *current* scope is reused
      # (completing an earlier "struct tag;" forward declaration or the
      # in-progress self-reference), unless it is already complete, which makes
      # the second body a redefinition. An unknown tag is created incomplete and
      # registered up front — before its body is parsed — so a member that
      # points back at the same tag ("struct node *next;") resolves to this very
      # object.
      def define_struct_tag(tag, token)
        existing = @tag_scopes.last[tag]
        if existing
          error_at(token, "redefinition of 'struct #{tag}'") if existing.complete?
          return existing
        end
        struct_type = Type::StructType.new(tag)
        @tag_scopes.last[tag] = struct_type
        struct_type
      end

      # Resolves a bare "struct tag" reference. An in-scope tag (searched
      # innermost outward) is returned as is — complete or not. An unknown tag
      # is forward-declared: a fresh incomplete struct is registered in the
      # current scope, so "struct node;" introduces the tag and "struct node *p;"
      # names a pointer to an as-yet-undefined struct.
      def reference_struct_tag(tag)
        @tag_scopes.reverse_each do |scope|
          found = scope[tag]
          return found if found
        end
        struct_type = Type::StructType.new(tag)
        @tag_scopes.last[tag] = struct_type
        struct_type
      end

      # Parses a struct's "{ struct-declaration+ }" body and lays `struct_type`
      # out. Each struct-declaration is a type-specifier followed by one or more
      # comma-separated declarators (each contributing a "*" run and an optional
      # array suffix), just like a local declaration but with no initializer. A
      # member may not be void, an incomplete struct by value, or a duplicate
      # name; a pointer to an incomplete struct (the self-referential case) is
      # fine, since a pointer is always complete.
      def parse_struct_body(struct_type)
        expect_punct("{")
        raw_members = []
        names = {}
        until peek.punct?("}")
          member_base = parse_type_specifier
          loop do
            type = parse_pointer_declarator(member_base)
            name_tok = expect_ident
            type = parse_array_declarator(type)
            reject_void_type(type, name_tok)
            reject_incomplete_member(type, name_tok)
            error_at(name_tok, "duplicate member '#{name_tok.value}'") if names.key?(name_tok.value)
            names[name_tok.value] = true
            raw_members << [name_tok.value, type]
            break unless peek.punct?(",")

            advance
          end
          expect_punct(";")
        end
        expect_punct("}")
        struct_type.define(raw_members)
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

      # Whether `token` opens a declaration (an "int", "char", "void" or
      # "struct" keyword), letting block-item and for-init tell a declaration
      # from a statement.
      def type_specifier?(token)
        token.type == :keyword && (TYPE_SPECIFIERS.key?(token.value) || token.value == "struct")
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
        # The body is a block, so it owns a tag scope: a struct defined in one
        # function's body is invisible to the next.
        @tag_scopes.push({})
        body = []
        body.concat(parse_block_item) until peek.punct?("}")
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
        if params.size > MAX_PARAMS
          error_at(params[MAX_PARAMS].token, "too many parameters (rubycc supports up to 6)")
        end
        params
      end

      # parameter-declaration = type-specifier declarator?. The declarator's
      # name is optional (nil) so prototypes may omit it, but any leading "*"
      # run still contributes to the parameter's pointer type; an unnamed
      # parameter is located by its type-specifier keyword for diagnostics.
      def parse_parameter_declaration
        type_tok = peek
        type = parse_pointer_declarator(parse_type_specifier)
        reject_void_type(type, type_tok)
        if peek.type == :ident
          name_tok = advance
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
        base_type = parse_type_specifier

        # A bare "struct point { ... };" (or "struct node;") inside a block just
        # declares or defines the tag, adding no local; it yields no items.
        if peek.punct?(";")
          advance
          return []
        end

        decls = [parse_init_declarator(base_type)]
        while peek.punct?(",")
          advance
          decls << parse_init_declarator(base_type)
        end
        expect_punct(";")
        decls
      end

      def parse_init_declarator(base_type)
        type = parse_pointer_declarator(base_type)
        name_tok = expect_ident
        type = parse_array_declarator(type)
        reject_void_type(type, name_tok)
        initializer = nil
        if peek.punct?("=")
          eq_tok = advance
          if type.array?
            error_at(eq_tok, "array initializers are not supported yet")
          end
          initializer = parse_assignment_expression
        end
        AST::VariableDecl.new(name_tok.value, type, initializer, name_tok)
      end

      # direct-declarator's optional array suffix. A bracketed length turns the
      # declared object into an array of `element_type`; the length must be a
      # positive integer-constant literal. A second "[" would begin a
      # multidimensional array, which this subset does not model.
      def parse_array_declarator(element_type)
        return element_type unless peek.punct?("[")

        advance # "["
        length_tok = peek
        unless length_tok.type == :num
          error_at(length_tok, "array size must be an integer constant")
        end
        advance
        unless length_tok.value.positive?
          error_at(length_tok, "array size must be positive")
        end
        expect_punct("]")
        if peek.punct?("[")
          error_at(peek, "multidimensional arrays are not supported yet")
        end
        Type::Array.new(element_type, length_tok.value)
      end

      # Consumes the "*" run of a declarator, wrapping `base` in one pointer
      # level per star (so "int **" becomes a pointer to a pointer to int). The
      # parser only builds the type here; whether operations on it type-check is
      # the generator's job.
      def parse_pointer_declarator(base)
        type = base
        while peek.punct?("*")
          advance
          type = Type::Pointer.new(type)
        end
        type
      end

      def parse_statement
        if peek.keyword?("return")
          parse_return
        elsif peek.keyword?("if")
          parse_selection_statement
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
        elsif peek.punct?("{")
          parse_compound_statement
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
        # C99 gives the for-loop's own parentheses a scope, so a struct tag (or
        # a variable) declared in clause-1 is visible only through the loop.
        @tag_scopes.push({})
        init = parse_for_init
        condition = peek.punct?(";") ? nil : parse_expression
        expect_punct(";")
        step = peek.punct?(")") ? nil : parse_expression
        expect_punct(")")
        body = parse_statement
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

      def parse_compound_statement
        brace_tok = expect_punct("{")
        # A nested block introduces its own tag scope, mirroring its variable
        # scope: a struct defined here shadows an outer tag and is gone at "}".
        @tag_scopes.push({})
        items = []
        items.concat(parse_block_item) until peek.punct?("}")
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
      # finally primary-expression) to consume. With no typedef names yet, the
      # keyword after "(" settles the choice with a single token of lookahead,
      # so "(int)x" is a cast while "(x)(y)" — x not being a type — is a call.
      # (When typedef arrives, this test must also consult the typedef-name
      # namespace, since a "(" followed by a typedef name would open a cast.)
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
        AST::Binary.new(:xor, operand, AST::IntLit.new(-1, op_tok), op_tok)
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

      # type-name = type-specifier "*"*: a base type-specifier and its pointer
      # "*" run, with no declarator name. Shared by "sizeof ( type-name )" and
      # the cast "( type-name )"; abstract array and function declarators are
      # not modelled in this subset.
      def parse_type_name
        parse_pointer_declarator(parse_type_specifier)
      end

      # An identifier immediately followed by "(" is a function call; anything
      # else falls through to a primary-expression. Either may then be followed
      # by a chain of "[" expression "]" subscripts (a[i], a[i][j], p[k]) and
      # postfix "++"/"--" (a[i]++), in any order.
      def parse_postfix_expression
        tok = peek
        node = if tok.type == :ident && peek_ahead(1)&.punct?("(")
                 parse_call
               else
                 parse_primary_expression
               end
        loop do
          if peek.punct?("[")
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

      def parse_call
        name_tok = advance # identifier
        expect_punct("(")
        args = parse_argument_expression_list
        expect_punct(")")
        AST::Call.new(name_tok.value, args, name_tok)
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
          AST::IntLit.new(tok.value, tok)
        elsif tok.type == :string
          advance
          AST::StringLit.new(tok.value, tok)
        elsif tok.type == :ident
          advance
          AST::VariableRef.new(tok.value, tok)
        elsif tok.punct?("(")
          advance
          node = parse_expression
          expect_punct(")")
          node
        else
          error_at(tok, "expected expression")
        end
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
    end
  end
end
