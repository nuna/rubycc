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

  # An automatic object is sized by its type alone, so the extra elements have
  # nowhere to live; gcc rejects the initializer with the same wording (a static
  # one is the extension the next section covers).
  def test_initializing_flexible_array_member_of_an_automatic_object_is_rejected
    source = <<~C
      struct s { int n; int f[]; };
      int main(void) { struct s x = { 1, { 2, 3 } }; return x.n; }
    C
    assert_compile_error(source, /non-static initialization of a flexible array member/)
  end

  # A compound literal at block scope is an automatic object too.
  def test_initializing_flexible_array_member_of_a_compound_literal_is_rejected
    source = <<~C
      struct s { int n; int f[]; };
      int main(void) { struct s *p = &(struct s){ 1, { 2, 3 } }; return p->n; }
    C
    assert_compile_error(source, /non-static initialization of a flexible array member/)
  end

  # Only the object's own trailing FAM may be initialized: one reached through
  # a nested struct would have to widen a subobject, which has no room.
  def test_initializing_flexible_array_member_in_a_nested_context_is_rejected
    source = <<~C
      struct inner { int n; int f[]; };
      struct outer { int y; struct inner x; };
      struct outer v = { 1, { 2, { 3, 4 } } };
      int main(void) { return v.y; }
    C
    assert_compile_error(source, /flexible array member in a nested context/)
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

  # --- gcc's static-storage extension (Step 171) ---------------------------
  #
  # ISO C reserves no storage for a FAM, so it has no meaning for an
  # initializer directed at one; gcc extends the language to accept it for an
  # object with static storage duration and widens that *object* past its
  # type's size, which google-protobuf's generated upb tables rely on
  # ("{64, 11, {0x7, ...}}" at file scope). Measured against gcc: sizeof stays
  # the type's, the object occupies sizeof(struct) + n * sizeof(element) bytes
  # (readelf's symbol size), the count n is the highest element index reached
  # plus one whatever order the items arrive in, and every spelling below —
  # braced, string, brace-elided, designated, empty — round trips through the
  # elements. All of it is cross-checked against gcc rather than asserted here.

  # Every initializer spelling for a file-scope FAM, read back through the
  # member, plus the sizeof that must *not* have grown.
  STATIC_INIT_SOURCE = <<~C
    #include <stdio.h>
    struct chars { long n; char c[]; };
    struct doubles { char c; double d[]; };
    struct upb { long mask; int count; unsigned int data[]; };
    const struct chars braced = { 1, { 'a', 'b', 'c' } };
    const struct chars strung = { 2, "hey" };
    const struct doubles padded = { 3, { 1.5, 2.5 } };
    const struct upb table = { 4, 5, { 9, 8, 7 } };
    const struct upb designated = { 6, 7, { [3] = 42 } };
    const struct upb member_designated = { .mask = 8, .count = 9, .data[0] = 1, .data[4] = 2 };
    const struct upb elided = { 10, 11, 12, 13 };
    const struct upb empty = { 14, 15, {} };
    static const struct upb internal = { 16, 17, { 21, 22 } };
    int main(void) {
      static const struct chars block_static = { 18, { 'x', 'y' } };
      printf("%zu %zu %zu\\n",
             sizeof(struct chars), sizeof(struct doubles), sizeof(struct upb));
      printf("%ld %d %d %d\\n", braced.n, braced.c[0], braced.c[1], braced.c[2]);
      printf("%ld %s\\n", strung.n, strung.c);
      printf("%d %g %g\\n", padded.c, padded.d[0], padded.d[1]);
      printf("%ld %d %u %u %u\\n", table.mask, table.count,
             table.data[0], table.data[1], table.data[2]);
      printf("%ld %d %u %u\\n", designated.mask, designated.count,
             designated.data[0], designated.data[3]);
      printf("%ld %d %u %u %u\\n", member_designated.mask, member_designated.count,
             member_designated.data[0], member_designated.data[2],
             member_designated.data[4]);
      printf("%ld %d %u %u\\n", elided.mask, elided.count,
             elided.data[0], elided.data[1]);
      printf("%ld %d\\n", empty.mask, empty.count);
      printf("%ld %d %u %u\\n", internal.mask, internal.count,
             internal.data[0], internal.data[1]);
      printf("%ld %d %d\\n", block_static.n, block_static.c[0], block_static.c[1]);
      return 0;
    }
  C

  # A written-then-read pass over every element of the widened object, so the
  # storage past sizeof is proven to exist rather than merely to be readable
  # once: a const object's bytes could be folded, a mutable one's cannot.
  STATIC_WRITE_SOURCE = <<~C
    #include <stdio.h>
    struct vec { unsigned long size; long data[]; };
    struct vec v = { 5, { 10, 20, 30, 40, 50 } };
    int main(void) {
      long sum = 0;
      for (unsigned long i = 0; i < v.size; i++) {
        v.data[i] = v.data[i] * 2 + (long)i;
        sum += v.data[i];
      }
      printf("%lu %ld %ld %ld\\n", v.size, sum, v.data[0], v.data[v.size - 1]);
      return 0;
    }
  C

  def test_static_flexible_array_initializer_matches_gcc
    assert_matches_gcc(STATIC_INIT_SOURCE, "fam_static_init")
  end

  def test_static_flexible_array_storage_round_trips_like_gcc
    assert_matches_gcc(STATIC_WRITE_SOURCE, "fam_static_write")
  end

  # The object's own width is what the extension changes, so it is checked
  # directly against gcc's: readelf's symbol size for each definition (which is
  # also the size the emitted image occupies) must agree object for object.
  OBJECT_SIZE_SOURCE = <<~C
    struct upb { long mask; int count; unsigned int data[]; };
    struct chars { long n; char c[]; };
    struct shorts { char a; short s[]; };
    struct upb none = { 1, 2 };
    struct upb one = { 1, 2, { 9 } };
    struct upb four = { 1, 2, { 9, 9, 9, 9 } };
    struct chars strung = { 1, "hey" };
    struct shorts three = { 1, { 1, 2, 3 } };
    struct upb spread = { .mask = 1, .data[4] = 2 };
  C

  def test_object_sizes_match_gcc
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "fam_sizes_rubycc.o")
      File.binwrite(rubycc_obj, Rubycc::Compiler.new.compile(OBJECT_SIZE_SOURCE, filename: "fam_sizes.c"))
      gcc_obj = compile_with_gcc(OBJECT_SIZE_SOURCE, File.join(dir, "fam_sizes_gcc.o"))
      assert_equal object_symbol_sizes(gcc_obj), object_symbol_sizes(rubycc_obj),
                   "object sizes differ from gcc"
    end
  end

  # name => size for every STT_OBJECT symbol of `path`, read out of readelf's
  # symbol table (columns: num, value, size, type, bind, vis, ndx, name).
  def object_symbol_sizes(path)
    output = `readelf -sW #{path}`
    output.lines.filter_map do |line|
      fields = line.split
      next unless fields[3] == "OBJECT"

      [fields[7], fields[2].to_i]
    end.to_h
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
      compile_with_rubycc(source, rubycc_obj)
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
