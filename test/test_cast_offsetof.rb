# frozen_string_literal: true

require_relative "test_helper"

# Step 184: the cast form of offsetof — "((size_t)&((T *)0)->m)" — folds to a
# compile-time constant. The address is a member offset from a constant base, so
# nothing but the struct's layout is needed to settle it; the constant evaluator
# therefore places it itself (ConstantEvaluator#absolute_pointer_value) rather
# than through the IR generator's address-constant resolver, which is what makes
# it a constant in the parser's contexts (a _Static_assert above all) as well as
# in a global's initializer, the one context that already folded it.
#
# The form reaches rubycc through a libc whose <stddef.h> defines offsetof this
# way: CRuby's <ruby/internal/core/rtypeddata.h> asserts that struct RData and
# struct RTypedData agree on their "data" offset, and that one assertion stopped
# <ruby.h> from being preprocessed at all (docs/GAPS.md gap K).
#
# These tests cross-check the folded values against gcc and pin the cases that
# must *not* fold — a base that is not a constant, a bit-field, an unknown
# member — so they keep reporting rather than folding to a wrong value.
class TestCastOffsetof < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # Every designator shape the fold covers, in a constant context (a
  # _Static_assert and a global's initializer) and printed at run time so the
  # values themselves are cross-checked against gcc.
  FORMS_SOURCE = <<~C
    #include <stdio.h>
    #define OFF(t, m) ((size_t)&((t *)0)->m)
    struct point { short x; int y; };
    struct frame {
      char tag;
      struct point origin;
      int samples[8];
      struct point corners[4];
    };
    _Static_assert(OFF(struct frame, tag) == 0, "leading member");
    _Static_assert(OFF(struct frame, origin) == 4, "aggregate member");
    _Static_assert(OFF(struct frame, origin.y) == 8, "nested member");
    _Static_assert(OFF(struct frame, samples[2]) == 20, "array member element");
    _Static_assert(OFF(struct frame, corners[3].y) == 72, "element's member");
    _Static_assert((size_t)&((struct point *)0)[3] == 24, "subscript of the cast");
    _Static_assert((size_t)&(*(struct frame *)0) == 0, "dereference of the cast");
    static size_t corner_y = OFF(struct frame, corners[3].y);
    int main(void) {
      printf("%zu %zu %zu %zu %zu %zu %zu %zu\\n",
             OFF(struct frame, tag), OFF(struct frame, origin),
             OFF(struct frame, origin.y), OFF(struct frame, samples[2]),
             OFF(struct frame, corners[3].y), corner_y,
             (size_t)&((struct point *)0)[3],
             (size_t)&(*(struct frame *)0));
      return 0;
    }
  C

  # A base that is not the null pointer: the offset is added to whatever
  # constant the cast names, for every designator shape.
  NON_ZERO_BASE_SOURCE = <<~C
    #include <stdio.h>
    struct point { short x; int y; };
    struct frame { char tag; struct point origin; int samples[8]; };
    _Static_assert((size_t)&((struct frame *)16)->origin.y == 16 + 8, "member from 16");
    _Static_assert((size_t)&((struct frame *)16)->samples[1] == 16 + 16, "element from 16");
    _Static_assert((size_t)&((struct point *)64)[3] == 64 + 24, "subscript from 64");
    _Static_assert((size_t)&(*(struct frame *)128) == 128, "dereference of 128");
    _Static_assert((size_t)&((struct frame *)(2 * 8 + 1 - 1))->tag == 16, "computed base");
    int main(void) {
      printf("%zu %zu %zu %zu\\n",
             (size_t)&((struct frame *)16)->origin.y,
             (size_t)&((struct frame *)16)->samples[1],
             (size_t)&((struct point *)64)[3],
             (size_t)&(*(struct frame *)128));
      return 0;
    }
  C

  # The shape CRuby's <ruby/internal/core/rtypeddata.h> writes: two cast-form
  # offsets compared with "==" inside one _Static_assert. Both sides must fold
  # before the comparison can.
  RTYPEDDATA_SOURCE = <<~C
    #include <stdio.h>
    #define OFF(t, m) ((size_t)&((t *)0)->m)
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

  # Designators that reach through more than one level: a struct inside a struct
  # inside an array member, and a member found through an anonymous struct.
  NESTED_SOURCE = <<~C
    #include <stdio.h>
    #define OFF(t, m) ((size_t)&((t *)0)->m)
    struct leaf { char pad; long value; };
    struct branch { int label; struct leaf leaves[3]; };
    struct tree { short root; struct branch branches[2]; };
    struct packet { long header; struct { int channel; int sequence; }; };
    _Static_assert(OFF(struct tree, branches[1].leaves[2].value) == 112, "three levels");
    _Static_assert(OFF(struct packet, sequence) == 12, "anonymous member");
    int main(void) {
      printf("%zu %zu %zu %zu\\n",
             OFF(struct tree, branches[0].leaves[0].pad),
             OFF(struct tree, branches[1].leaves[2].value),
             OFF(struct packet, channel), OFF(struct packet, sequence));
      return 0;
    }
  C

  def test_designator_forms_match_gcc
    assert_matches_gcc(FORMS_SOURCE, "cast_offsetof_forms")
  end

  def test_non_zero_base_matches_gcc
    assert_matches_gcc(NON_ZERO_BASE_SOURCE, "cast_offsetof_base")
  end

  def test_rtypeddata_shape_matches_gcc
    assert_matches_gcc(RTYPEDDATA_SOURCE, "cast_offsetof_rtypeddata")
  end

  def test_nested_designators_match_gcc
    assert_matches_gcc(NESTED_SOURCE, "cast_offsetof_nested")
  end

  # A failing assertion is still reported: the fold makes the expression a
  # constant, so its value is actually checked rather than the whole
  # _Static_assert being rejected as non-constant.
  def test_wrong_offset_fails_the_static_assertion
    source = <<~C
      typedef unsigned long size_t;
      struct pair { int first; int second; };
      _Static_assert(((size_t)&((struct pair *)0)->second) == 0, "second is not first");
      int main(void) { return 0; }
    C
    error = compile_error(source, "wrong_offset.c")
    assert_match(/static assertion failed: "second is not first"/, error.message)
  end

  # A base that is not a constant leaves the address unfolded, exactly as before
  # this fold existed: nothing but the struct layout may be assumed, and a
  # variable's value is not part of it.
  def test_non_constant_base_is_still_rejected
    source = <<~C
      typedef unsigned long size_t;
      struct pair { int first; int second; };
      int origin;
      _Static_assert(((size_t)&((struct pair *)origin)->second) == 4, "not a constant");
      int main(void) { return 0; }
    C
    error = compile_error(source, "non_constant_base.c")
    assert_match(/static assertion expression is not an integer constant/, error.message)
  end

  # Likewise a non-constant subscript: the stride is known but the index is not.
  def test_non_constant_index_is_still_rejected
    source = <<~C
      typedef unsigned long size_t;
      struct row { int cells[4]; };
      int which;
      _Static_assert(((size_t)&((struct row *)0)->cells[which]) == 4, "not a constant");
      int main(void) { return 0; }
    C
    error = compile_error(source, "non_constant_index.c")
    assert_match(/static assertion expression is not an integer constant/, error.message)
  end

  # The address of an object is a link-time value, not a compile-time one, so
  # taking a member's address through a real object stays non-constant.
  def test_address_of_object_is_still_rejected
    source = <<~C
      typedef unsigned long size_t;
      struct pair { int first; int second; };
      struct pair global_pair;
      _Static_assert(((size_t)&global_pair.second) == 4, "not a constant");
      int main(void) { return 0; }
    C
    error = compile_error(source, "address_of_object.c")
    assert_match(/static assertion expression is not an integer constant/, error.message)
  end

  # A bit-field has no addressable byte offset, so the fold declines it and the
  # expression stays non-constant rather than folding to the containing byte.
  def test_bitfield_member_is_not_folded
    source = <<~C
      typedef unsigned long size_t;
      struct flags { unsigned a : 3; unsigned b : 5; };
      _Static_assert(((size_t)&((struct flags *)0)->b) == 0, "not a constant");
      int main(void) { return 0; }
    C
    error = compile_error(source, "bitfield_cast_offsetof.c")
    assert_match(/static assertion expression is not an integer constant/, error.message)
  end

  # A designator naming no member of the aggregate folds to nothing at all.
  def test_unknown_member_is_not_folded
    source = <<~C
      typedef unsigned long size_t;
      struct pair { int first; int second; };
      _Static_assert(((size_t)&((struct pair *)0)->third) == 4, "not a constant");
      int main(void) { return 0; }
    C
    error = compile_error(source, "unknown_member_cast_offsetof.c")
    assert_match(/static assertion expression is not an integer constant/, error.message)
  end

  # An incomplete struct has no layout to measure.
  def test_incomplete_type_is_not_folded
    source = <<~C
      typedef unsigned long size_t;
      struct opaque;
      _Static_assert(((size_t)&((struct opaque *)0)->field) == 0, "not a constant");
      int main(void) { return 0; }
    C
    error = compile_error(source, "incomplete_cast_offsetof.c")
    assert_match(/static assertion expression is not an integer constant/, error.message)
  end

  # The same fold serves the other parse-time constant contexts: an enumerator
  # and a bit-field width, neither of which carries a symbol table.
  def test_other_parse_time_constant_contexts_fold
    source = <<~C
      #include <stdio.h>
      #define OFF(t, m) ((size_t)&((t *)0)->m)
      struct record { int id; char name[16]; long stamp; };
      enum { NAME_AT = OFF(struct record, name), STAMP_AT = OFF(struct record, stamp) };
      struct widths { unsigned bits : OFF(struct record, name); };
      int main(void) {
        printf("%d %d %d\\n", (int)NAME_AT, (int)STAMP_AT, (int)sizeof(struct widths));
        return 0;
      }
    C
    assert_matches_gcc(source, "cast_offsetof_contexts")
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
