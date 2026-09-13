# frozen_string_literal: true

require_relative "test_helper"

# The issue "attribute-statement-after-label" (GAPS row BE): an
# attribute-only statement ("__attribute__((fallthrough));") placed directly
# after a label is read through #parse_nested_statement -> #parse_statement,
# a different path from the one #parse_block_item's "attribute-statement-1"
# fix covers (a statement that opens a block, or that immediately follows
# another statement inside one). Measured 2026-09-13 (gcc 13.3, this host)
# with "attribute-statement-1" already applied: the issue's minimal repro
# ("case 1: __attribute__ ((fallthrough)); case 2: ...") still failed in
# rubycc with "expected expression", while gcc accepted it. #parse_statement
# now shares #parse_attribute_only_statement with #parse_block_item so the
# same shape is accepted right after any label (a "case", a "default", or a
# plain identifier label).
class TestAttributeStatementAfterLabel < Minitest::Test
  include ExecutionHelper

  # The issue's minimal repro, verbatim.
  def test_attribute_statement_right_after_case_label_matches_gcc
    src = <<~C
      int f(int x) {
        switch (x) {
        case 1:
          __attribute__ ((fallthrough));
        case 2:
          return x + 10;
        }
        return 0;
      }
      int main(void) { return f(1); }
    C
    assert_matches_gcc(11, src)
  end

  # Same shape right after "default:" instead of "case N:".
  def test_attribute_statement_right_after_default_label_matches_gcc
    src = <<~C
      int f(int x) {
        switch (x) {
        default:
          __attribute__ ((fallthrough));
        case 2:
          return x + 10;
        }
        return 0;
      }
      int main(void) { return f(3); }
    C
    assert_matches_gcc(13, src)
  end

  # Same shape right after an ordinary (goto-target) label rather than a
  # switch label; this exercises #parse_labeled_statement's call into
  # #parse_nested_statement, the other caller that used to bypass the fix.
  def test_attribute_statement_right_after_plain_label_matches_gcc
    src = <<~C
      int f(int x) {
      L:
        __attribute__ ((fallthrough));
        if (x) goto L;
        return x + 1;
      }
      int main(void) { return f(0); }
    C
    assert_matches_gcc(1, src)
  end

  # An attribute sequence right after a label, followed by something other
  # than ";", must still be a syntax error, exactly as it already is right
  # after a block-opening statement (measured 2026-09-13, gcc 13.3: gcc
  # rejects "__attribute__ ((fallthrough)) return x;" here with "expected
  # identifier or '(' before 'return'").
  def test_attribute_not_followed_by_semicolon_after_label_still_errors
    src = <<~C
      int f(int x) {
        switch (x) {
        case 1:
          __attribute__ ((fallthrough)) return x;
        case 2:
          return x + 10;
        }
        return 0;
      }
      int main(void) { return f(1); }
    C
    assert_raises(Rubycc::CompileError) { compile(src) }
  end

  # A declaration right after a label (attributed or not) is a gap unrelated
  # to this fix: gcc accepts it via its own GNU extension (a label may
  # directly precede a declaration), measured 2026-09-13, but rubycc's
  # #parse_statement has no declaration branch at all — a *plain* "L: int y =
  # x;" already failed with "expected expression" before this fix. This just
  # confirms an attribute ahead of that declaration is refused the same way,
  # i.e. this fix did not accidentally start treating it as an
  # attribute-only statement (which would silently drop the declaration).
  def test_declaration_leading_attribute_after_label_is_unaffected
    src = <<~C
      int f(int x) {
      L:
        __attribute__((unused)) int y = x;
        return y;
      }
      int main(void) { return f(2); }
    C
    assert_raises(Rubycc::CompileError) { compile(src) }
  end

  private

  def compile(source, filename: "test.c")
    Rubycc::Compiler.new.compile(source, filename: filename, target: host_target)
  end

  # Compiles `src` with both rubycc and gcc, links and runs each, asserting
  # both exit with `expected`.
  def assert_matches_gcc(expected, src)
    assert_c_exit_status(expected, src, compiler: :rubycc)
    assert_c_exit_status(expected, src, compiler: :gcc)
  end
end
