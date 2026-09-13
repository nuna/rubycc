# frozen_string_literal: true

require_relative "test_helper"

# A GNU attribute-specifier sequence written as its own statement
# ("__attribute__((fallthrough));"), gcc's spelling of a fallthrough marker
# right before a switch's next "case"/"default" (and the GNU counterpart of
# C23's "[[fallthrough]];"). #parse_block_item used to read a statement-leading
# "__attribute__" the same way it reads a declaration-leading one (position a,
# "__attribute__((unused)) int x;") and went looking for a type specifier next,
# failing with "expected type specifier" once it hit the following ";" or
# "case" (issue "attribute-statement", liquid-c 4.2.0's
# ext/liquid_c/parser.c:242).
#
# Per DESIGN R7, only 'aligned' and 'packed' carry any semantics anywhere this
# parser reads a GNU attribute; every other attribute is accepted and
# discarded. That holds for a statement attribute too, so 'fallthrough' itself
# is given no fallthrough-placement semantics (rubycc has no
# -Wimplicit-fallthrough-style lint to feed) — it is syntactically accepted and
# ignored exactly like any other unrecognized attribute.
#
# gcc only accepts a GNU-spelled attribute statement directly in front of the
# terminating ";" — measured 2026-09-13 (gcc 13.3, this host): gcc rejects
# "__attribute__((unused)) return x;" and "__attribute__((fallthrough)) case
# 2:" (both "expected identifier or '(' before ..."), and reports "empty
# declaration" for an unrecognized attribute statement rather than an error.
# rubycc mirrors that shape: an attribute sequence not followed by a type
# specifier must be followed by ";", parsed as an AST::EmptyStmt.
class TestAttributeStatement < Minitest::Test
  include ExecutionHelper

  def parse(source, filename: "test.c")
    tokens = Rubycc::Front::Lexer.new(source, filename: filename).tokenize
    Rubycc::Front::Parser.new(tokens).parse
  end

  # The issue's minimal repro: an attribute statement between a case's
  # statements and the next case label, falling through as it would without
  # the attribute. f(1) falls through to the "case 2:" return; f(2) returns
  # directly.
  def test_fallthrough_attribute_statement_matches_gcc
    src = <<~C
      int f(int x) {
        switch (x) {
        case 1:
          x += 1;
          __attribute__ ((fallthrough));
        case 2:
          return x;
        }
        return 0;
      }
      int main(void) { return f(1) + f(2) * 10; }
    C
    assert_matches_gcc(22, src) # f(1) == 2, f(2) == 2 -> 2 + 20
  end

  # An attribute statement need not be the GNU "fallthrough" name; every
  # attribute is discarded regardless of whether rubycc recognizes it (R7).
  def test_unrecognized_attribute_statement_is_accepted_and_ignored
    src = <<~C
      int f(int x) {
        __attribute__((totally_made_up));
        return x + 1;
      }
      int main(void) { return f(4); }
    C
    assert_matches_gcc(5, src)
  end

  # A bare, argument-less attribute statement.
  def test_empty_attribute_list_statement_is_accepted
    src = <<~C
      int f(int x) {
        __attribute__(());
        return x;
      }
      int main(void) { return f(3); }
    C
    assert_matches_gcc(3, src)
  end

  # A run of multiple "__attribute__((...))" groups before the ";". Neither
  # names "fallthrough": gcc only accepts that name immediately before a
  # "case"/"default", so pairing it with a second attribute here would fail on
  # the gcc side of the differential for reasons unrelated to this fix
  # (measured 2026-09-13: "invalid use of attribute 'fallthrough'").
  def test_multiple_attribute_specifiers_in_one_statement_are_accepted
    src = <<~C
      int f(int x) {
        __attribute__((unused)) __attribute__((cold));
        return x;
      }
      int main(void) { return f(9); }
    C
    assert_matches_gcc(9, src)
  end

  # An attribute statement as a compound statement's only item. Not
  # "fallthrough" here: outside a switch it is not immediately before a
  # "case"/"default", which gcc itself diagnoses as a placement error rather
  # than a syntax error (measured 2026-09-13); "unused" carries no such
  # placement constraint.
  def test_attribute_statement_as_sole_block_item_is_accepted
    src = <<~C
      int main(void) {
        __attribute__((unused));
        return 0;
      }
    C
    assert_matches_gcc(0, src)
  end

  # Declaration-leading attributes must keep parsing exactly as before: this
  # is not a statement attribute because a type specifier follows the
  # attribute sequence, so it stays with #parse_declaration.
  def test_declaration_leading_attribute_still_declares_a_local
    program = parse("int main(void) { __attribute__((unused)) int x = 7; return x; }")
    decl = program.functions.first.body.first
    assert_equal "x", decl.name
    assert_equal Rubycc::Type::Int, decl.type
  end

  def test_declaration_leading_attribute_matches_gcc
    src = <<~C
      int main(void) {
        __attribute__((unused)) int x = 7;
        return x;
      }
    C
    assert_matches_gcc(7, src)
  end

  private

  # Compiles `src` with both rubycc and gcc, links and runs each, asserting
  # both exit with `expected`.
  def assert_matches_gcc(expected, src)
    assert_c_exit_status(expected, src, compiler: :rubycc)
    assert_c_exit_status(expected, src, compiler: :gcc)
  end
end
