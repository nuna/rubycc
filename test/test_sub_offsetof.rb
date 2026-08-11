# frozen_string_literal: true

require_relative "test_helper"

# Step 187: the subtraction form of offsetof — "((size_t)((char *)&((T *)0)->m
# - (char *)0))" — folds to a compile-time constant, the way Step 184 already
# folds the cast form "((size_t)&((T *)0)->m)". Both spell the same distance,
# but the subtraction form reaches it through a pointer difference (6.5.6p9)
# rather than a bare cast-to-integer, so ConstantEvaluator#pointer_difference
# is what these tests exercise, not #absolute_pointer_value on its own.
#
# The fold divides the byte difference by the pointed-to type's size — "char
# *" for the traditional macro, but any pointed-to type that both sides
# share — so these tests also cover a non-"char *" stride, and pin the cases
# that must stay unfolded: mismatched pointee sizes and "void *".
class TestSubOffsetof < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # The minimal repro this step was filed against.
  MINIMAL_SOURCE = <<~C
    #include <stdio.h>
    struct A { int x; void *data; };
    #define OFF_SUB(t, m) ((size_t)((char *)&((t *)0)->m - (char *)0))
    _Static_assert(OFF_SUB(struct A, data) == 8, "subtraction form");
    int main(void) {
      printf("%zu\\n", OFF_SUB(struct A, data));
      return 0;
    }
  C

  # Two subtraction-form offsets compared with "==" inside one
  # _Static_assert, the CRuby <ruby/internal/core/rtypeddata.h> shape (see
  # test_cast_offsetof.rb's RTYPEDDATA_SOURCE for the cast-form twin of this
  # test). Both sides must fold before the comparison can.
  RTYPEDDATA_SOURCE = <<~C
    #include <stdio.h>
    #define OFF(t, m) ((size_t)((char *)&((t *)0)->m - (char *)0))
    struct plain_data { unsigned long flags; const char *klass; void *data; };
    struct typed_data { unsigned long flags; const char *klass; void *data; long extra; };
    struct shifted_data { unsigned long flags; const char *klass; long extra; void *data; };
    _Static_assert(OFF(struct plain_data, data) == OFF(struct typed_data, data),
                   "data_in_typed_data");
    _Static_assert(OFF(struct plain_data, data) != OFF(struct shifted_data, data),
                   "shifted layout differs");
    _Static_assert(OFF(struct shifted_data, data) - OFF(struct plain_data, data) == 8,
                   "the difference is one slot");
    int main(void) {
      printf("%zu %zu %zu\\n",
             OFF(struct plain_data, data), OFF(struct typed_data, data),
             OFF(struct shifted_data, data));
      return 0;
    }
  C

  # A stride other than one byte: two "int *" values divide by sizeof(int),
  # not by one.
  INT_STRIDE_SOURCE = <<~C
    #include <stdio.h>
    struct arr { int values[8]; };
    #define STRIDE(t, m, i, j) \\
      ((int *)&((t *)0)->m[i] - (int *)&((t *)0)->m[j])
    _Static_assert(STRIDE(struct arr, values, 4, 2) == 2, "int stride divides by sizeof(int)");
    int main(void) {
      printf("%d\\n", (int)STRIDE(struct arr, values, 4, 2));
      return 0;
    }
  C

  # "&member + 1", a pointer advanced by an integer constant, is itself a
  # foldable address, so the subtraction form applies to it too.
  POINTER_PLUS_INT_SOURCE = <<~C
    #include <stdio.h>
    struct pair { int a; int b; };
    #define OFF_NEXT(t, m) ((size_t)((char *)(&((t *)0)->m + 1) - (char *)0))
    _Static_assert(OFF_NEXT(struct pair, a) == 4, "pointer-plus-int folds too");
    int main(void) {
      printf("%zu\\n", OFF_NEXT(struct pair, a));
      return 0;
    }
  C

  def test_minimal_repro_matches_gcc
    assert_matches_gcc(MINIMAL_SOURCE, "sub_offsetof_minimal")
  end

  def test_rtypeddata_shape_matches_gcc
    assert_matches_gcc(RTYPEDDATA_SOURCE, "sub_offsetof_rtypeddata")
  end

  def test_int_pointer_stride_matches_gcc
    assert_matches_gcc(INT_STRIDE_SOURCE, "sub_offsetof_int_stride")
  end

  def test_pointer_plus_integer_matches_gcc
    assert_matches_gcc(POINTER_PLUS_INT_SOURCE, "sub_offsetof_pointer_plus_int")
  end

  # Two different-sized pointees are a constraint violation (6.5.6p3) the
  # subtraction is never entitled to fold, no matter how it is reached; the
  # expression stays non-constant exactly as it did before this fold existed.
  def test_mismatched_pointee_sizes_are_not_folded
    source = <<~C
      typedef unsigned long size_t;
      struct pair { char a; long b; };
      _Static_assert(((size_t)((char *)&((struct pair *)0)->b - (long *)&((struct pair *)0)->a)) == 0,
                     "not a constant");
      int main(void) { return 0; }
    C
    error = compile_error(source, "mismatched_pointee_sizes.c")
    assert_match(/static assertion expression is not an integer constant/, error.message)
  end

  # "void *" has no size to divide by, so the difference stays unfolded even
  # though both addresses are themselves constant.
  def test_void_pointer_difference_is_not_folded
    source = <<~C
      typedef unsigned long size_t;
      struct pair { int first; int second; };
      _Static_assert(((size_t)((void *)&((struct pair *)0)->second - (void *)&((struct pair *)0)->first)) == 4,
                     "not a constant");
      int main(void) { return 0; }
    C
    error = compile_error(source, "void_pointer_difference.c")
    assert_match(/static assertion expression is not an integer constant/, error.message)
  end

  # A byte difference that does not divide evenly by the shared pointee size
  # cannot happen for two addresses this evaluator derives from the same
  # struct layout, but nothing stops two unrelated absolute addresses (the
  # same idiom Step 184's NON_ZERO_BASE_SOURCE exercises) from landing on
  # one; the fold must not silently truncate that case away.
  def test_indivisible_difference_is_not_silently_truncated
    source = <<~C
      typedef unsigned long size_t;
      _Static_assert(((size_t)((int *)5 - (float *)0)) == 1, "not a constant");
      int main(void) { return 0; }
    C
    error = compile_error(source, "indivisible_difference.c")
    assert_match(/static assertion expression is not an integer constant/, error.message)
  end

  # A base that is not constant leaves the whole difference unfolded, exactly
  # as an ordinary (non-pointer) constant expression would.
  def test_non_constant_base_is_still_rejected
    source = <<~C
      typedef unsigned long size_t;
      struct pair { int first; int second; };
      int origin;
      _Static_assert(((size_t)((char *)&((struct pair *)origin)->second - (char *)0)) == 4, "not a constant");
      int main(void) { return 0; }
    C
    error = compile_error(source, "sub_offsetof_non_constant_base.c")
    assert_match(/static assertion expression is not an integer constant/, error.message)
  end

  # Ordinary integer subtraction — no pointer in sight — keeps working
  # exactly as it did before this fold existed.
  def test_plain_integer_subtraction_still_folds
    source = <<~C
      #include <stdio.h>
      enum { DIFF = 10 - 3 };
      _Static_assert(DIFF == 7, "plain integer subtraction");
      int main(void) {
        printf("%d\\n", DIFF);
        return 0;
      }
    C
    assert_matches_gcc(source, "sub_offsetof_plain_integer")
  end

  def assert_matches_gcc(source, name)
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      binary = Rubycc::Compiler.new.compile(source, filename: "#{name}.c", target: host_target)
      File.binwrite(rubycc_obj, binary)
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = compile_with_gcc(source, File.join(dir, "#{name}_gcc.o"))
      gcc_status, gcc_out = link_and_run(gcc_obj)

      assert_equal 0, rubycc_status, "rubycc-built #{name} exited #{rubycc_status}"
      assert_equal gcc_status, rubycc_status, "#{name}: exit status differs from gcc"
      assert_equal gcc_out, rubycc_out, "#{name}: output differs from gcc"
    end
  end

  def compile_error(source, filename)
    assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: filename, target: host_target)
    end
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
