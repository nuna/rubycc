# frozen_string_literal: true

require_relative "test_helper"

# Regression coverage for the gap fixed by expansion-budget-source-tokens-1:
# EXPANSION_TOKEN_LIMIT (preprocess/preprocessor.rb) used to charge one unit
# per token *examined* while draining #expand_tokens' work queue, which
# includes every ordinary source token that simply passes through untouched.
# A large macro-free table (no macro use at all) could therefore exhaust the
# whole-run budget and be rejected as a "runaway or exponentially expanding
# macro", even though nothing was expanding. The fix charges the budget only
# for tokens a macro substitution actually produces.
#
# The two tests below are deliberately split, not merged into one
# end-to-end differential:
#
# - #test_a_table_that_would_have_exhausted_the_old_source_token_budget_now_preprocesses
#   reproduces the exact failure shape from issues/expansion-budget-source-tokens.md
#   (a struct table with no macros) at a row count picked so the resulting
#   token count alone -- without counting the newlines and other
#   non-emitted tokens the old scheme *also* charged -- already exceeds the
#   old 1,000,000 ceiling. Since the old scheme charged at least as many
#   units as the final token count (every emitted token was dequeued once,
#   plus more besides), this is a safe way to establish "the old code would
#   have rejected this" without resurrecting the removed counting logic. It
#   only preprocesses (no parse/codegen/link), because reaching the roughly
#   1,000,000 tokens needed to demonstrate that is inherently the dominant
#   cost here (about 7 seconds on the machine this was written on, 2026-09-13)
#   and full compilation is considerably slower per token than preprocessing
#   alone -- see the STEPS entry for the measurements behind this split.
# - #test_a_large_macro_free_table_compiles_and_matches_gcc exercises the
#   same shape end to end (compiled, linked, run, and compared against gcc)
#   at a size small enough to stay fast, since its job is to confirm the
#   *value* is right, not to stress the budget.
#
# The runaway-macro rejection itself is NOT re-pinned here: it already has a
# dedicated test (test_dos_resilience.rb's
# test_exponentially_expanding_macro_is_rejected), which this change must
# leave passing, for the same reason and in comparable time.
class TestExpansionBudgetSourceTokens < Minitest::Test
  include ExecutionHelper

  Preprocessor = Rubycc::Preprocess::Preprocessor

  # The exact generator shape from the issue: a struct table with six
  # int fields, `rows` copies of one literal row, and an `n()` accessor
  # returning the element count. `with_main` additionally prints `n()` so an
  # end-to-end (compiled and run) comparison against gcc has something to
  # compare beyond a bare exit status.
  def large_table_source(rows, with_main: false)
    row = "  { 1, 2, 3, 4, 5, 6 },\n"
    table = row * rows
    source = +"struct e { int a, b, c, d, e, f; };\n"
    source << "static const struct e tbl[] = {\n#{table}};\n"
    source << "int n(void) { return (int)(sizeof tbl / sizeof tbl[0]); }\n"
    if with_main
      source << "#include <stdio.h>\n"
      source << "int main(void) { printf(\"%d\\n\", n()); return 0; }\n"
    end
    source
  end

  # Each table row preprocesses to exactly 14 tokens ("{ 1 , 2 , 3 , 4 , 5 ,
  # 6 } ,"), and the struct/array/function declarations around it (without
  # `with_main`) contribute a fixed 52 more -- both measured directly against
  # the preprocessor's own output for this exact generator, 2026-09-13.
  TOKENS_PER_ROW = 14
  FIXED_OVERHEAD_TOKENS = 52

  # A row count whose resulting token count alone already exceeds the old
  # 1,000,000-token ceiling (see the class comment for why the old scheme's
  # actual count -- which also charged newlines and other non-emitted
  # tokens -- would only have been larger, not smaller). 72,000 rows clears
  # the ceiling (14 * 72,000 = 1,008,000, before the fixed declaration
  # overhead) with a comfortable margin while staying as small as the
  # 1,000,000-token floor allows.
  OLD_BUDGET_EXCEEDING_ROWS = 72_000

  def test_a_table_that_would_have_exhausted_the_old_source_token_budget_now_preprocesses
    source = large_table_source(OLD_BUDGET_EXCEEDING_ROWS)

    tokens = Preprocessor.new.run(source, filename: "big_table.c")

    expected_token_count = (TOKENS_PER_ROW * OLD_BUDGET_EXCEEDING_ROWS) + FIXED_OVERHEAD_TOKENS
    assert_equal expected_token_count, tokens.length
    assert_operator tokens.length, :>, Preprocessor::EXPANSION_TOKEN_LIMIT,
                     "the generated table's own token count should already clear the old budget"
  end

  def test_a_large_macro_free_table_compiles_and_matches_gcc
    rows = 3_000
    source = large_table_source(rows, with_main: true)

    in_tmpdir do |dir|
      rubycc_object = File.join(dir, "rubycc.o")
      gcc_object = File.join(dir, "gcc.o")
      compile_source(source, rubycc_object, :rubycc)
      compile_source(source, gcc_object, :gcc)

      rubycc_status, rubycc_stdout = link_and_run(rubycc_object)
      gcc_status, gcc_stdout = link_and_run(gcc_object)

      assert_equal 0, gcc_status, "gcc oracle program did not exit cleanly"
      assert_equal gcc_status, rubycc_status
      assert_equal "#{rows}\n", gcc_stdout, "gcc oracle printed an unexpected value"
      assert_equal gcc_stdout, rubycc_stdout
    end
  end
end
