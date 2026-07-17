# frozen_string_literal: true

require_relative "test_helper"

# Step 46: a flexible array member (ISO C 6.7.2.1p18) — the last member of a
# struct written as an unbounded "T name[]". It has no fixed size, so it
# contributes nothing to sizeof (its offset still aligns to the element type,
# and the element type still joins the struct's alignment), and an lvalue of
# that type decays to a pointer to its element, so "p->fam[i]" indexes storage
# past the declared struct. These tests cross-check the layout (sizeof,
# _Alignof, __builtin_offsetof) against gcc, exercise a written-then-read round
# trip over heap storage sized like the msgpack idiom, and confirm the
# constraint violations (a FAM not last, in a union, alone, subscripted by
# sizeof, an array of such a struct, and an initializer for the FAM itself).
class TestFlexibleArrayMember < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # sizeof/_Alignof/offsetof of several FAM layouts, each with a different tail
  # element type and leading padding, cross-checked against gcc.
  LAYOUT_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>
    struct wide { unsigned long n; int tail[]; };
    struct padded { char c; double d[]; };
    struct msg { unsigned long size; long *mapped[]; };
    struct trailing { int a; char b; short body[]; };
    int main(void) {
      printf("%zu %zu %zu\\n",
             sizeof(struct wide), _Alignof(struct wide),
             __builtin_offsetof(struct wide, tail));
      printf("%zu %zu %zu\\n",
             sizeof(struct padded), _Alignof(struct padded),
             __builtin_offsetof(struct padded, d));
      printf("%zu %zu %zu\\n",
             sizeof(struct msg), _Alignof(struct msg),
             __builtin_offsetof(struct msg, mapped));
      printf("%zu %zu %zu\\n",
             sizeof(struct trailing), _Alignof(struct trailing),
             __builtin_offsetof(struct trailing, body));
      return 0;
    }
  C

  # Heap storage sized "sizeof(struct) + sizeof(elem) * n" (the msgpack idiom),
  # written and read back through the FAM by subscript, and through a pointer
  # the FAM decays to.
  ACCESS_SOURCE = <<~C
    #include <stdio.h>
    #include <stdlib.h>
    struct vec { unsigned long size; long data[]; };
    int main(void) {
      unsigned long n = 6;
      struct vec *v = malloc(sizeof(struct vec) + sizeof(long) * n);
      v->size = n;
      for (unsigned long i = 0; i < v->size; i++) {
        v->data[i] = (long)(i * i) - 3;
      }
      long sum = 0;
      long *p = v->data;
      for (unsigned long i = 0; i < v->size; i++) {
        sum += p[i];
      }
      printf("%ld %ld %ld\\n", sum, v->data[0], v->data[n - 1]);
      free(v);
      return 0;
    }
  C

  # The msgpack held-buffer shape: a size_t count followed by a VALUE
  # (pointer-sized) flexible array, allocated by the same size arithmetic
  # buffer_class.c uses, and filled through the FAM.
  MSGPACK_SHAPE_SOURCE = <<~C
    #include <stdio.h>
    #include <stdlib.h>
    typedef unsigned long VALUE;
    struct held_buffer { size_t size; VALUE mapped_strings[]; };
    int main(void) {
      size_t n = 4;
      struct held_buffer *h =
        malloc(sizeof(size_t) + sizeof(VALUE) * n);
      h->size = n;
      for (size_t i = 0; i < h->size; i++) {
        h->mapped_strings[i] = (VALUE)(i * 100 + 7);
      }
      unsigned long total = 0;
      for (size_t i = 0; i < h->size; i++) {
        total += h->mapped_strings[i];
      }
      printf("%zu %lu\\n", h->size, total);
      free(h);
      return 0;
    }
  C

  def test_layout_matches_gcc
    assert_matches_gcc(LAYOUT_SOURCE, "fam_layout")
  end

  def test_access_round_trip_matches_gcc
    assert_matches_gcc(ACCESS_SOURCE, "fam_access")
  end

  def test_msgpack_held_buffer_shape_matches_gcc
    assert_matches_gcc(MSGPACK_SHAPE_SOURCE, "fam_msgpack")
  end

  # A FAM must be the struct's last member; a member declared after it (here in
  # a later declaration) is a constraint violation.
  def test_flexible_array_member_not_last_is_rejected
    source = <<~C
      struct bad { int f[]; int n; };
      int main(void) { return 0; }
    C
    assert_compile_error(source, /flexible array member .* last member/)
  end

  # A FAM must be last within a single declarator list too ("int f[], g;").
  def test_flexible_array_member_before_sibling_is_rejected
    source = <<~C
      struct bad { int a; int f[], g; };
      int main(void) { return 0; }
    C
    assert_compile_error(source, /flexible array member .* last member/)
  end

  # A struct whose only member is a FAM has no other member to anchor it.
  def test_flexible_array_member_alone_is_rejected
    source = <<~C
      struct bad { int f[]; };
      int main(void) { return 0; }
    C
    assert_compile_error(source, /flexible array member .* no other members/)
  end

  # A union member is overlaid at offset 0, so a FAM is meaningless there.
  def test_flexible_array_member_in_union_is_rejected
    source = <<~C
      union bad { int n; int f[]; };
      int main(void) { return 0; }
    C
    assert_compile_error(source, /flexible array member .* union/)
  end

  # sizeof of the FAM member itself has no size (the member is an incomplete
  # array type), so it is rejected rather than folded.
  def test_sizeof_flexible_array_member_is_rejected
    source = <<~C
      struct s { int n; int f[]; };
      int main(void) {
        struct s x;
        return (int)sizeof(x.f);
      }
    C
    assert_compile_error(source, /incomplete type/)
  end

  # A struct that ends in a FAM has no fixed stride, so it cannot be an array
  # element.
  def test_array_of_flexible_array_struct_is_rejected
    source = <<~C
      struct s { int n; int f[]; };
      struct s table[3];
      int main(void) { return 0; }
    C
    assert_compile_error(source, /flexible array member/)
  end

  # The FAM has no reserved storage, so an initializer directed at it would
  # write past the object and is rejected — while one that fills only the other
  # members is accepted.
  def test_initializing_flexible_array_member_is_rejected
    source = <<~C
      struct s { int n; int f[]; };
      struct s x = { 1, { 2, 3 } };
      int main(void) { return 0; }
    C
    assert_compile_error(source, /flexible array member/)
  end

  def test_initializing_only_other_members_is_accepted
    source = <<~C
      #include <stdio.h>
      struct s { int n; int f[]; };
      struct s x = { 42 };
      int main(void) {
        printf("%d\\n", x.n);
        return 0;
      }
    C
    assert_c_program(source, exit_status: 0, stdout: "42\n")
  end

  def assert_compile_error(source, pattern)
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "fam.c")
    end
    assert_match(pattern, error.message)
  end

  def assert_matches_gcc(source, name)
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      binary = Rubycc::Compiler.new.compile(source, filename: "#{name}.c")
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
