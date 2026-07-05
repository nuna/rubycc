# frozen_string_literal: true

require_relative "ast"
require_relative "../compile_error"

module Rubycc
  module Front
    # Recursive-descent parser for the C subset. Nonterminals follow the
    # grammar productions of ISO C (6.5.x / 6.7 / 6.8.x):
    #
    #   translation-unit          = function-definition*
    #   function-definition       = "int" identifier "(" "void"? ")" compound-statement
    #   compound-statement        = "{" block-item* "}"
    #   block-item                = declaration | statement
    #   declaration               = "int" init-declarator ("," init-declarator)* ";"
    #   init-declarator           = identifier ("=" assignment-expression)?
    #   statement                 = return-statement | expression-statement
    #   return-statement          = "return" expression ";"
    #   expression-statement      = expression? ";"
    #   expression                = assignment-expression
    #   assignment-expression     = additive-expression ("=" assignment-expression)?
    #   additive-expression       = multiplicative-expression
    #                               (("+" | "-") multiplicative-expression)*
    #   multiplicative-expression = unary-expression
    #                               (("*" | "/" | "%") unary-expression)*
    #   unary-expression          = ("+" | "-")* primary-expression
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
      ADDITIVE_OPERATORS = { "+" => :add, "-" => :sub }.freeze
      MULTIPLICATIVE_OPERATORS = { "*" => :mul, "/" => :div, "%" => :mod }.freeze
      def initialize(tokens)
        @tokens = tokens
        @pos = 0
      end

      # Parses the whole translation unit into an AST::Program.
      def parse
        functions = []
        functions << parse_function until peek.eof?
        AST::Program.new(functions)
      end

      private

      def peek
        @tokens[@pos]
      end

      def advance
        tok = @tokens[@pos]
        @pos += 1 unless tok.eof?
        tok
      end

      def parse_function
        int_tok = expect_keyword("int")
        name_tok = expect_ident
        expect_punct("(")
        # Accept both "(void)" and "()".
        consume_keyword("void")
        expect_punct(")")
        expect_punct("{")

        body = []
        body.concat(parse_block_item) until peek.punct?("}")
        expect_punct("}")

        AST::FunctionDef.new(name_tok.value, body, int_tok)
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
        name_tok = expect_ident
        initializer = nil
        if peek.punct?("=")
          advance
          initializer = parse_assignment_expression
        end
        AST::VariableDecl.new(name_tok.value, initializer, name_tok)
      end

      def parse_statement
        if peek.keyword?("return")
          parse_return
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
        node = parse_additive_expression
        return node unless peek.punct?("=")

        eq_tok = advance
        error_at(eq_tok, "expression is not assignable") unless node.is_a?(AST::VariableRef)
        value = parse_assignment_expression
        AST::Assignment.new(node, value, eq_tok)
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
        if peek.punct?("+")
          advance # unary + is a no-op; fold it away
          parse_unary_expression
        elsif peek.punct?("-")
          op_tok = advance
          AST::Unary.new(:neg, parse_unary_expression, op_tok)
        else
          parse_primary_expression
        end
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

      def consume_keyword(str)
        advance if peek.keyword?(str)
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
