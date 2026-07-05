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
    #   external-declaration      = "int" identifier "(" parameter-type-list? ")"
    #                               (";" | compound-statement)
    #   parameter-type-list       = "void"
    #                             | parameter-declaration
    #                               ("," parameter-declaration)*
    #   parameter-declaration     = "int" declarator?
    #   declarator                = "*"* direct-declarator
    #   direct-declarator         = identifier ("[" integer-constant "]")?
    #   compound-statement        = "{" block-item* "}"
    #   block-item                = declaration | statement
    #   declaration               = "int" init-declarator ("," init-declarator)* ";"
    #   init-declarator           = declarator ("=" assignment-expression)?
    #   statement                 = return-statement | expression-statement
    #                             | selection-statement | iteration-statement
    #                             | jump-statement | compound-statement
    #   return-statement          = "return" expression ";"
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
    #   assignment-expression     = equality-expression ("=" assignment-expression)?
    #   equality-expression       = relational-expression
    #                               (("==" | "!=") relational-expression)*
    #   relational-expression     = additive-expression
    #                               (("<" | ">" | "<=" | ">=") additive-expression)*
    #   additive-expression       = multiplicative-expression
    #                               (("+" | "-") multiplicative-expression)*
    #   multiplicative-expression = unary-expression
    #                               (("*" | "/" | "%") unary-expression)*
    #   unary-expression          = ("+" | "-" | "!" | "&" | "*")* postfix-expression
    #                             | "sizeof" unary-expression
    #                             | "sizeof" "(" type-name ")"
    #   type-name                 = "int" "*"*
    #   postfix-expression        = (primary-expression
    #                               | identifier "(" argument-expression-list? ")")
    #                               ("[" expression "]")*
    #   argument-expression-list  = assignment-expression
    #                               ("," assignment-expression)*
    #   primary-expression        = integer-constant | identifier | "(" expression ")"
    #
    # Binary precedence levels are parsed by a single table-driven
    # left-associative loop (see #parse_left_associative) rather than one
    # hand-written loop per level, so adding an operator or a precedence
    # tier only requires a new table entry. assignment-expression is
    # right-associative and is handled separately (see #parse_assignment_expression).
    class Parser
      # Punctuator → AST operator tables, one per precedence tier
      # (weakest binding first).
      EQUALITY_OPERATORS = { "==" => :eq, "!=" => :ne }.freeze
      RELATIONAL_OPERATORS = { "<" => :lt, ">" => :gt, "<=" => :le, ">=" => :ge }.freeze
      ADDITIVE_OPERATORS = { "+" => :add, "-" => :sub }.freeze
      MULTIPLICATIVE_OPERATORS = { "*" => :mul, "/" => :div, "%" => :mod }.freeze

      # System V AMD64 passes the first six integer arguments in registers;
      # this subset rejects any function with more parameters (or arguments).
      MAX_PARAMS = 6

      def initialize(tokens)
        @tokens = tokens
        @pos = 0
      end

      # Parses the whole translation unit into an AST::Program.
      def parse
        functions = []
        functions << parse_external_declaration until peek.eof?
        AST::Program.new(functions)
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

      # An external declaration is a prototype (ends in ";") or a definition
      # (ends in a compound-statement); the two share the same
      # "int" identifier "(" parameter-type-list? ")" prefix.
      def parse_external_declaration
        int_tok = expect_keyword("int")
        name_tok = expect_ident
        expect_punct("(")
        params = parse_parameter_type_list
        expect_punct(")")

        if peek.punct?(";")
          advance
          AST::FunctionDecl.new(name_tok.value, params, int_tok)
        else
          parse_function_definition(name_tok.value, params, int_tok)
        end
      end

      def parse_function_definition(name, params, int_tok)
        # A definition, unlike a prototype, must name each parameter so its
        # value can be bound in the body.
        params.each do |param|
          error_at(param.token, "parameter name omitted") if param.name.nil?
        end
        expect_punct("{")
        body = []
        body.concat(parse_block_item) until peek.punct?("}")
        expect_punct("}")
        AST::FunctionDef.new(name, params, body, int_tok)
      end

      # Returns an array of AST::Parameter; empty for "()" or "(void)".
      def parse_parameter_type_list
        return [] if peek.punct?(")")
        if peek.keyword?("void")
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

      # parameter-declaration = "int" declarator?. The declarator's name is
      # optional (nil) so prototypes may omit it, but any leading "*" run still
      # contributes to the parameter's pointer type; an unnamed parameter is
      # located by its "int" keyword for diagnostics.
      def parse_parameter_declaration
        int_tok = expect_keyword("int")
        type = parse_pointer_declarator(Type::Int)
        if peek.type == :ident
          name_tok = advance
          AST::Parameter.new(name_tok.value, type, name_tok)
        else
          AST::Parameter.new(nil, type, int_tok)
        end
      end

      # Returns an array of nodes: a declaration expands to one VariableDecl
      # per init-declarator, while a statement always yields exactly one node.
      def parse_block_item
        if peek.keyword?("int")
          parse_declaration
        else
          [parse_statement]
        end
      end

      def parse_declaration
        expect_keyword("int")
        decls = [parse_init_declarator]
        while peek.punct?(",")
          advance
          decls << parse_init_declarator
        end
        expect_punct(";")
        decls
      end

      def parse_init_declarator
        type = parse_pointer_declarator(Type::Int)
        name_tok = expect_ident
        type = parse_array_declarator(type)
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

      def parse_return
        ret_tok = advance # "return"
        expr = parse_expression
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
        init = parse_for_init
        condition = peek.punct?(";") ? nil : parse_expression
        expect_punct(";")
        step = peek.punct?(")") ? nil : parse_expression
        expect_punct(")")
        body = parse_statement
        AST::For.new(init, condition, step, body, for_tok)
      end

      # Parses the for-loop's first clause, consuming its trailing ";" (a
      # declaration already does so; the other two branches do it explicitly).
      def parse_for_init
        if peek.keyword?("int")
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
        items = []
        items.concat(parse_block_item) until peek.punct?("}")
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

      def parse_expression
        parse_assignment_expression
      end

      # Right-associative: "a = b = c" parses as "a = (b = c)".
      def parse_assignment_expression
        node = parse_equality_expression
        return node unless peek.punct?("=")

        eq_tok = advance
        error_at(eq_tok, "expression is not assignable") unless assignable?(node)
        value = parse_assignment_expression
        AST::Assignment.new(node, value, eq_tok)
      end

      # Syntactically, only a variable reference, a subscript "e[i]" or a
      # dereference "*expr" can appear on the left of "=". Whether the target's
      # type is actually assignable (e.g. not an array) is checked later by the
      # generator.
      def assignable?(node)
        node.is_a?(AST::VariableRef) ||
          node.is_a?(AST::Subscript) ||
          (node.is_a?(AST::Unary) && node.op == :deref)
      end

      def parse_equality_expression
        parse_left_associative(EQUALITY_OPERATORS) { parse_relational_expression }
      end

      def parse_relational_expression
        parse_left_associative(RELATIONAL_OPERATORS) { parse_additive_expression }
      end

      def parse_additive_expression
        parse_left_associative(ADDITIVE_OPERATORS) { parse_multiplicative_expression }
      end

      def parse_multiplicative_expression
        parse_left_associative(MULTIPLICATIVE_OPERATORS) { parse_unary_expression }
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
          parse_unary_expression
        elsif peek.punct?("-")
          op_tok = advance
          AST::Unary.new(:neg, parse_unary_expression, op_tok)
        elsif peek.punct?("!")
          op_tok = advance
          AST::Unary.new(:not, parse_unary_expression, op_tok)
        elsif peek.punct?("&")
          op_tok = advance
          AST::Unary.new(:addr, parse_unary_expression, op_tok)
        elsif peek.punct?("*")
          op_tok = advance
          AST::Unary.new(:deref, parse_unary_expression, op_tok)
        else
          parse_postfix_expression
        end
      end

      # "sizeof" measures either a parenthesized type-name ("sizeof(int *)") or
      # the result type of a unary-expression ("sizeof x", "sizeof(a)"). A "("
      # right after the keyword is only a type-name when "int" follows;
      # otherwise it is an ordinary parenthesized operand, so it is left for
      # unary-expression to consume.
      def parse_sizeof
        sizeof_tok = advance # "sizeof"
        if peek.punct?("(") && peek_ahead(1)&.keyword?("int")
          advance # "("
          expect_keyword("int")
          type = parse_pointer_declarator(Type::Int)
          expect_punct(")")
          AST::SizeofType.new(type, sizeof_tok)
        else
          AST::SizeofExpr.new(parse_unary_expression, sizeof_tok)
        end
      end

      # An identifier immediately followed by "(" is a function call; anything
      # else falls through to a primary-expression. Either may then be followed
      # by a chain of "[" expression "]" subscripts (a[i], a[i][j], p[k]).
      def parse_postfix_expression
        tok = peek
        node = if tok.type == :ident && peek_ahead(1)&.punct?("(")
                 parse_call
               else
                 parse_primary_expression
               end
        while peek.punct?("[")
          bracket_tok = advance # "["
          index = parse_expression
          expect_punct("]")
          node = AST::Subscript.new(node, index, bracket_tok)
        end
        node
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
