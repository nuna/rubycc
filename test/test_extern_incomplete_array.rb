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
    Rubycc::Compiler.new.compile(source, filename: filename, target: host_target)
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

  # Step 150: two declarations of one object, one an unbounded "extern T a[];"
  # and the other bounded, are *compatible*; the object's type is their composite
  # type, which is the one with the known bound (6.2.7p3). Both orders appear
  # here, and each is measured with sizeof — the reverse order (definition first)
  # would still measure 12 if the later unbounded reference wrongly overwrote the
  # binding's completed type, so the subscript of the last element pins the
  # element type and bound down as well.
  COMPOSITE_ORDER_PROGRAM = <<~C
    int printf(const char *, ...);
    extern int reference_first[];
    int reference_first[3] = {1, 2, 3};
    int definition_first[4] = {10, 20, 30, 40};
    extern int definition_first[];
    int main(void) {
      printf("%d %d %d %d\\n", (int)sizeof(reference_first), reference_first[2],
             (int)sizeof(definition_first), definition_first[3]);
      return 0;
    }
  C

  def test_composite_array_type_matches_gcc_in_both_declaration_orders
    oracle = link_units_and_run([[COMPOSITE_ORDER_PROGRAM, :gcc]])
    actual = link_units_and_run([[COMPOSITE_ORDER_PROGRAM, :rubycc]])
    assert_equal oracle, actual
    assert_equal [0, "12 3 16 40\n"], actual # the oracle itself is meaningful
  end

  # A multidimensional array composes the same way: only the outermost bound may
  # be unspecified ("extern int m[][4];"), so the composite type takes that bound
  # from the definition while the inner dimension — which both declarations state
  # — has to agree.
  COMPOSITE_MULTIDIM_PROGRAM = <<~C
    int printf(const char *, ...);
    extern int m[][4];
    int m[2][4] = {{1, 2, 3, 4}, {5, 6, 7, 8}};
    int main(void) {
      printf("%d %d %d\\n", (int)sizeof(m), (int)sizeof(m[0]), m[1][3]);
      return 0;
    }
  C

  def test_composite_array_type_completes_an_outer_bound_of_a_multidimensional_array
    oracle = link_units_and_run([[COMPOSITE_MULTIDIM_PROGRAM, :gcc]])
    actual = link_units_and_run([[COMPOSITE_MULTIDIM_PROGRAM, :rubycc]])
    assert_equal oracle, actual
    assert_equal [0, "32 16 8\n"], actual
  end

  # nkf's shape, the one this rule was needed for: utf8tbl.h declares
  # "extern const unsigned short euc_to_utf8_1byte[];" and utf8tbl.c defines the
  # table with its bound left to the initializer, so the translation unit that
  # includes the header sees the unbounded declaration first and the bounded
  # definition second. The element count is recovered from sizeof, which only
  # works if the definition's bound survived the merge.
  NKF_TABLE_PROGRAM = <<~C
    int printf(const char *, ...);
    extern const unsigned short euc_to_utf8_1byte[];
    const unsigned short euc_to_utf8_1byte[] = {
      #{(0...94).map { |i| format("0x%04X", 0xFF61 + i) }.join(", ")}
    };
    int main(void) {
      int count = sizeof(euc_to_utf8_1byte) / sizeof(euc_to_utf8_1byte[0]);
      printf("%d %d %d\\n", count, euc_to_utf8_1byte[0], euc_to_utf8_1byte[count - 1]);
      return 0;
    }
  C

  def test_composite_array_type_admits_the_nkf_forward_declared_table
    oracle = link_units_and_run([[NKF_TABLE_PROGRAM, :gcc]])
    actual = link_units_and_run([[NKF_TABLE_PROGRAM, :rubycc]])
    assert_equal oracle, actual
    assert_equal [0, "94 65377 65470\n"], actual
  end

  # Compatibility still requires compatible element types: only the bound may be
  # left unspecified by one of the two declarations.
  def test_conflicting_element_type_is_still_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("extern int tbl[];\nlong tbl[3];\n")
    end
    assert_match(/conflicting types for 'tbl'/, error.description)
  end

  # Two *known* bounds must be the same one; neither declaration is unspecified,
  # so there is no composite type to form.
  def test_conflicting_array_bounds_are_still_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("extern int tbl[2];\nint tbl[3];\n")
    end
    assert_match(/conflicting types for 'tbl'/, error.description)
  end

  # The inner dimension of a multidimensional array is stated by both
  # declarations, so a disagreement there is a conflict even though the outer
  # bound composes.
  def test_conflicting_inner_dimension_is_still_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("extern int m[][4];\nint m[2][8];\n")
    end
    assert_match(/conflicting types for 'm'/, error.description)
  end

  # A block-scope "extern T a[];" names the same object a file-scope declaration
  # does, so it merges by the same rule: it neither conflicts with the bound
  # already in place nor unbounds it.
  BLOCK_SCOPE_REFERENCE_PROGRAM = <<~C
    int printf(const char *, ...);
    int tbl[3] = {1, 2, 3};
    int main(void) {
      extern int tbl[];
      printf("%d %d\\n", (int)sizeof(tbl), tbl[2]);
      return 0;
    }
  C

  def test_block_scope_unbounded_reference_keeps_the_known_bound
    oracle = link_units_and_run([[BLOCK_SCOPE_REFERENCE_PROGRAM, :gcc]])
    actual = link_units_and_run([[BLOCK_SCOPE_REFERENCE_PROGRAM, :rubycc]])
    assert_equal oracle, actual
    assert_equal [0, "12 3\n"], actual
  end
end
