# frozen_string_literal: true

require_relative "test_helper"

# Step 42: __builtin_offsetof(type-name, member-designator) folds the byte
# offset of a struct/union member to a size_t constant. Unlike the traditional
# "((size_t)&(((t*)0)->m))" macro, it is a genuine constant-expression, so it
# holds in a static initializer, an array bound and a case label as well as at
# run time — which is why <stddef.h>'s offsetof now expands to it. These tests
# cross-check the folded value against gcc across padded layouts, nested member
# designators, array subscripts and anonymous members, in both constant and
# run-time contexts, and confirm the constant-context uses gcc rejects with the
# traditional macro now compile.
class TestOffsetof < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # A run-time context: __builtin_offsetof written directly, and reached through
  # the <stddef.h> offsetof macro, across a padded layout.
  RUNTIME_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>
    struct layout { char tag; int value; double weight; char trailer; };
    int main(void) {
      size_t a = __builtin_offsetof(struct layout, tag);
      size_t b = __builtin_offsetof(struct layout, value);
      size_t c = offsetof(struct layout, weight);
      size_t d = offsetof(struct layout, trailer);
      printf("%zu %zu %zu %zu\\n", a, b, c, d);
      return 0;
    }
  C

  # A constant-expression context: static initializers, an array bound and a
  # case label — none of which the address-of-member macro can fold.
  CONSTANT_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>
    struct rec { int id; char name[16]; long stamp; };
    static size_t off_name = offsetof(struct rec, name);
    static size_t off_stamp = offsetof(struct rec, stamp);
    static char probe[offsetof(struct rec, stamp)];
    int classify(size_t k) {
      switch (k) {
        case offsetof(struct rec, id): return 1;
        case offsetof(struct rec, name): return 2;
        case offsetof(struct rec, stamp): return 3;
        default: return 0;
      }
    }
    int main(void) {
      printf("%zu %zu %zu %d %d %d\\n",
             off_name, off_stamp, sizeof(probe),
             classify(0), classify(off_name), classify(off_stamp));
      return 0;
    }
  C

  # Nested member designators and array subscripts: ".a.b", "arr[i]" and a
  # subscript through a nested aggregate "a.b[1].c".
  NESTED_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>
    struct inner { char pad; int field; };
    struct cell { short lead; int slot; };
    struct outer {
      char gate;
      struct inner inner;
      int arr[8];
      struct cell cells[4];
    };
    int main(void) {
      printf("%zu %zu %zu %zu\\n",
             offsetof(struct outer, inner.field),
             offsetof(struct outer, arr[2]),
             offsetof(struct outer, cells[3].slot),
             offsetof(struct outer, cells[1]));
      return 0;
    }
  C

  # An offset reached through an anonymous struct/union member (C11 6.7.2.1p13):
  # the member is named as if it were a direct field of the enclosing struct.
  ANONYMOUS_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>
    struct frame {
      long header;
      struct { int x; int y; };
      union { long as_long; char as_bytes[8]; };
    };
    static size_t off_x = offsetof(struct frame, x);
    int main(void) {
      printf("%zu %zu %zu %zu\\n",
             off_x,
             offsetof(struct frame, y),
             offsetof(struct frame, as_long),
             offsetof(struct frame, as_bytes));
      return 0;
    }
  C

  # A designator subscript whose index is *not* a constant expression. ISO
  # offsetof needs a constant, but gcc's __builtin_offsetof computes the offset
  # at run time instead of rejecting it, which is what google-protobuf's
  # bundled upb leans on: its UPB_SIZEOF_FLEX(type, member, count) macro is
  # "UPB_MAX(sizeof(type), offsetof(type, member[count]))" with `count` a
  # parameter, so the flexible array member's allocation size folds the trailing
  # padding in. The shapes here are that macro (over a flexible array member),
  # a variable index into a fixed array, two variable indices through nested
  # aggregates, and an index expression with side effects, which pins that the
  # index is evaluated exactly once and nothing else is.
  RUNTIME_INDEX_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>

    #define UPB_MAX(a, b) ((a) > (b) ? (a) : (b))
    #define UPB_SIZEOF_FLEX(type, member, count) \\
      UPB_MAX(sizeof(type), offsetof(type, member[count]))

    struct flex { int count; char tag; double items[]; };
    struct cell { short lead; int slot; };
    struct grid { char gate; struct cell cells[4]; int plain[8]; };

    static size_t flex_size(size_t count) {
      return UPB_SIZEOF_FLEX(struct flex, items, count);
    }

    int main(void) {
      int i = 2;
      int j = 3;
      int ticks = 0;

      printf("%zu %zu %zu %zu\\n", flex_size(0), flex_size(1), flex_size(2), flex_size(5));
      printf("%zu %zu\\n", offsetof(struct grid, plain[i]), offsetof(struct grid, cells[i].slot));
      printf("%zu %zu\\n", offsetof(struct grid, cells[j]), offsetof(struct grid, plain[i + j]));
      printf("%zu %d\\n", offsetof(struct grid, plain[ticks++]), ticks);
      printf("%zu %zu\\n", offsetof(struct grid, plain[-1]), offsetof(struct grid, plain[i - 4]));
      return 0;
    }
  C

  def test_runtime_offsetof_matches_gcc
    assert_matches_gcc(RUNTIME_SOURCE, "offsetof_runtime")
  end

  def test_runtime_index_offsetof_matches_gcc
    assert_matches_gcc(RUNTIME_INDEX_SOURCE, "offsetof_runtime_index")
  end

  # A constant context has no place to evaluate a run-time index, so the same
  # designator that compiles above is rejected as a non-constant there — the
  # diagnostic gcc also gives, rather than the unhandled evaluator failure a
  # deferred term would otherwise become.
  def test_runtime_index_is_rejected_in_a_constant_context
    source = <<~C
      struct grid { char gate; int plain[8]; };
      int n;
      static char probe[__builtin_offsetof(struct grid, plain[n])];
      int main(void) { return (int)sizeof(probe); }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "runtime_index_constant.c", target: host_target)
    end
    assert_match(/array size must be an integer constant/, error.message)
  end

  def test_constant_context_offsetof_matches_gcc
    assert_matches_gcc(CONSTANT_SOURCE, "offsetof_constant")
  end

  def test_nested_designator_offsetof_matches_gcc
    assert_matches_gcc(NESTED_SOURCE, "offsetof_nested")
  end

  def test_anonymous_member_offsetof_matches_gcc
    assert_matches_gcc(ANONYMOUS_SOURCE, "offsetof_anonymous")
  end

  # A bit-field has no addressable byte offset, so offsetof of one is rejected
  # rather than folded.
  def test_bitfield_member_is_rejected
    source = <<~C
      struct flags { unsigned a : 3; unsigned b : 5; };
      int main(void) {
        return (int)__builtin_offsetof(struct flags, a);
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "bitfield.c", target: host_target)
    end
    assert_match(/bit-field/, error.message)
  end

  # A designator that names no member of the aggregate is rejected.
  def test_unknown_member_is_rejected
    source = <<~C
      struct point { int x; int y; };
      int main(void) {
        return (int)__builtin_offsetof(struct point, z);
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "unknown.c", target: host_target)
    end
    assert_match(/no member named 'z'/, error.message)
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

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
