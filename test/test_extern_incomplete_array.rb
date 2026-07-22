# frozen_string_literal: true

require_relative "test_helper"

# Step 93 (M5 H4): an `extern` declaration of an unbounded array
# ("extern T name[];") is a reference, not a definition, so its size may be
# omitted — the type is incomplete and the defining translation unit supplies
# the bound (C11 6.7.6.2p1, 6.9.2). rubycc formerly rejected it with "array
# size missing"; real gems (bigdecimal's ruby/util.h) rely on the form. Only
# the element type is needed to subscript or decay such a reference, so no
# storage is reserved for it here.
class TestExternIncompleteArray < Minitest::Test
  include ExecutionHelper

  # A definition supplying the bound (TU-A) and a use that only ever sees the
  # unbounded reference (TU-B). tbl[i] == i, so the summed exit code and the
  # printed line are fixed constants the oracle assertion pins down.
  TABLE_DEF = "const signed char tbl[64] = { #{(0...64).to_a.join(", ")} };\n"

  TABLE_USE = <<~C
    int printf(const char *, ...);
    extern const signed char tbl[];
    int lookup(int i) { return tbl[i]; }
    int main(void) {
      int sum = 0;
      for (int i = 0; i < 64; i++) sum += lookup(i);
      printf("%d %d\\n", lookup(10), sum);
      return sum % 256;
    }
  C

  # Building both units with rubycc must link and run identically to building
  # both with gcc — the differential oracle for the whole feature end to end.
  def test_extern_unbounded_array_matches_gcc_across_two_units
    oracle = link_units_and_run([[TABLE_DEF, :gcc], [TABLE_USE, :gcc]])
    actual = link_units_and_run([[TABLE_DEF, :rubycc], [TABLE_USE, :rubycc]])
    assert_equal oracle, actual
    assert_equal [224, "10 2016\n"], actual # the oracle itself is meaningful
  end

  # The reference (rubycc) and the definition (gcc) must agree on the symbol
  # and its layout even though only the definition knows the bound.
  def test_extern_unbounded_array_links_against_a_gcc_definition
    oracle = link_units_and_run([[TABLE_DEF, :gcc], [TABLE_USE, :gcc]])
    mixed = link_units_and_run([[TABLE_DEF, :gcc], [TABLE_USE, :rubycc]])
    assert_equal oracle, mixed
  end

  def compile(source, filename: "foo.c")
    Rubycc::Compiler.new.compile(source, filename: filename)
  end

  # A non-extern unbounded array at block scope has no initializer and no
  # tentative-definition rule to complete it, so it stays a diagnostic (gcc
  # rejects it likewise).
  def test_block_scope_non_extern_unbounded_array_is_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("int main(void) { int a[]; return 0; }")
    end
    assert_match(/array size missing in 'a'/, error.description)
  end

  # sizeof needs a size, which an incomplete array has not (6.5.3.4), so a
  # "sizeof(a)" on an extern unbounded array stays rejected even though the
  # reference itself is now admitted.
  def test_sizeof_of_extern_unbounded_array_is_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("extern int a[];\nint main(void) { return sizeof(a); }")
    end
    assert_match(/invalid use of incomplete type/, error.description)
  end
end
