# frozen_string_literal: true

require_relative "test_helper"

# The C11 `_Alignas` alignment-specifier (6.7.5), in both spellings —
# `_Alignas(constant-expression)` and `_Alignas(type-name)`.
#
# google-protobuf's bundled upb is what this exists for: its UPB_ALIGN_AS(x)
# macro picks `__declspec(align(x))` for MSVC, `__attribute__((aligned(x)))`
# when __GNUC__ is defined and `_Alignas(x)` otherwise, and rubycc deliberately
# does not define __GNUC__ (R7), so it always lands on the C11 branch — on a
# struct member in six of upb's definitions and on a file-scope `static char`
# array in the seventh, where an 8-byte boundary a char array would never get
# on its own is exactly the point.
#
# gcc is the oracle for the layouts and for the addresses the objects land on.
# The constraint violations 6.7.5p2 and p4 list are checked against rubycc's own
# diagnostics, whose wording follows gcc's for each of them.
#
# An *automatic* object may ask for a boundary past the 16 bytes the frame
# stands on: both backends then realign the stack pointer in the prologue and
# place the frame on that boundary (step overaligned-automatic-object-1). One
# ceiling is rubycc's own rather than gcc's — the request may not exceed a page,
# since the realigning prologue reserves the boundary itself with no probe in
# between. See test_overaligned_automatic_objects_are_realigned.
class TestAlignas < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # An _Alignas on a struct member: it places that member at the boundary it
  # names and raises the whole aggregate's alignment, which sizeof and offsetof
  # both show. Covers the leading member (where the boundary only shows in the
  # aggregate's alignment and tail padding), an interior one (where it inserts
  # padding), a char member and a char array (whose natural boundary is 1), the
  # type-name spelling, a repeated specifier (the largest wins), a union member,
  # an anonymous member, and a member of a packed struct — where the _Alignas
  # overrides the packing for that one member.
  MEMBER_LAYOUT_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>

    struct leading { _Alignas(8) int a; char b; };
    struct interior { int a; _Alignas(16) char b; };
    struct chars { _Alignas(4) char a; char b; };
    struct arrays { char lead; _Alignas(8) char buf[3]; char tail; };
    struct by_type { _Alignas(double) int a; char b; };
    struct repeated { _Alignas(8) _Alignas(16) int a; char b; };
    struct reversed { _Alignas(16) _Alignas(8) int a; char b; };
    union overlaid { _Alignas(16) char c; int i; };
    struct anonymous { char c; _Alignas(16) struct { int x; }; char d; };
    struct __attribute__((packed)) packed { char c; _Alignas(8) int a; char b; };

    int main(void) {
      printf("%zu %zu %zu %zu\\n", sizeof(struct leading), _Alignof(struct leading),
             offsetof(struct leading, a), offsetof(struct leading, b));
      printf("%zu %zu %zu %zu\\n", sizeof(struct interior), _Alignof(struct interior),
             offsetof(struct interior, a), offsetof(struct interior, b));
      printf("%zu %zu %zu\\n", sizeof(struct chars), _Alignof(struct chars),
             offsetof(struct chars, b));
      printf("%zu %zu %zu %zu\\n", sizeof(struct arrays), _Alignof(struct arrays),
             offsetof(struct arrays, buf), offsetof(struct arrays, tail));
      printf("%zu %zu %zu\\n", sizeof(struct by_type), _Alignof(struct by_type),
             offsetof(struct by_type, b));
      printf("%zu %zu %zu\\n", sizeof(struct repeated), _Alignof(struct repeated),
             offsetof(struct repeated, b));
      printf("%zu %zu %zu\\n", sizeof(struct reversed), _Alignof(struct reversed),
             offsetof(struct reversed, b));
      printf("%zu %zu\\n", sizeof(union overlaid), _Alignof(union overlaid));
      printf("%zu %zu %zu %zu\\n", sizeof(struct anonymous), _Alignof(struct anonymous),
             offsetof(struct anonymous, x), offsetof(struct anonymous, d));
      printf("%zu %zu %zu %zu\\n", sizeof(struct packed), _Alignof(struct packed),
             offsetof(struct packed, a), offsetof(struct packed, b));
      return 0;
    }
  C

  # An _Alignas on an object rather than a member. Every object here is checked
  # by taking its address modulo the boundary it asked for, so a dropped
  # specifier shows up as a non-zero remainder. The specifier is written before
  # the type on some declarations and after it on others, both of which C11
  # admits.
  OBJECT_ALIGNMENT_SOURCE = <<~C
    #include <stdio.h>

    _Alignas(64) int wide;
    _Alignas(32) char text[3];
    int _Alignas(16) after_the_type;
    static _Alignas(128) int internal = 5;
    static _Alignas(8) const char blob[24] = { 0 };
    _Alignas(0) int no_effect = 7;
    _Alignas(double) char as_double[3];

    static int aligned_to(const void *p, unsigned long boundary) {
      return ((unsigned long)p % boundary) == 0;
    }

    int main(void) {
      _Alignas(16) struct { char c; } box;
      _Alignas(8) char local_buf[3];
      _Alignas(8) double value = 1.5;
      static _Alignas(256) int block;

      printf("%d %d %d %d\\n", aligned_to(&wide, 64), aligned_to(text, 32),
             aligned_to(&after_the_type, 16), aligned_to(&internal, 128));
      printf("%d %d %d\\n", aligned_to(blob, 8), aligned_to(as_double, 8),
             aligned_to(&block, 256));
      printf("%d %d %d\\n", aligned_to(&box, 16), aligned_to(local_buf, 8),
             aligned_to(&value, 8));
      printf("%d %d %.1f %zu\\n", internal, no_effect, value, sizeof(wide));
      return 0;
    }
  C

  # Automatic objects asking for 16, 32 and 64 bytes, in every shape the frame
  # places differently: a scalar (a virtual-register slot), an aggregate and an
  # array (stack objects), in a plain function, in one that also takes stack
  # arguments, in a variadic one, and in a nested block. Each address is read
  # back modulo its boundary, and each value too, so a realigned frame that
  # placed an object right but lost track of a stack argument or of va_arg still
  # shows up.
  OVERALIGNED_AUTOMATIC_SOURCE = <<~C
    #include <stdarg.h>
    #include <stdio.h>

    static int aligned_to(const void *p, unsigned long boundary) {
      return ((unsigned long)p % boundary) == 0;
    }

    static long plain(long n) {
      _Alignas(32) long scalar = n;
      _Alignas(64) struct { long a, b; } box;
      _Alignas(16) char text[20];
      box.a = n + 1;
      text[0] = (char)n;
      return scalar + box.a + text[0] +
             1000L * aligned_to(&scalar, 32) +
             2000L * aligned_to(&box, 64) +
             4000L * aligned_to(text, 16);
    }

    static long stacked(long a, long b, long c, long d, long e, long f, long g, long h) {
      _Alignas(64) long buf[4];
      buf[0] = a + h;
      buf[1] = g;
      return buf[0] + buf[1] + 1000L * aligned_to(buf, 64);
    }

    static long variable(int count, ...) {
      _Alignas(32) long seen[2];
      va_list ap;
      va_start(ap, count);
      seen[0] = va_arg(ap, long);
      seen[1] = (long)va_arg(ap, double);
      va_end(ap);
      return seen[0] + seen[1] + 1000L * aligned_to(seen, 32);
    }

    static long nested(int n) {
      long total = 0;
      {
        _Alignas(64) struct { long a, b; } inner;
        inner.a = n;
        total += inner.a + 1000L * aligned_to(&inner, 64);
      }
      {
        _Alignas(16) int small = 3;
        total += small + 2000L * aligned_to(&small, 16);
      }
      return total;
    }

    int main(void) {
      printf("%ld %ld %ld %ld\\n", plain(5), stacked(1, 2, 3, 4, 5, 6, 7, 8),
             variable(1, 2L, 3.0), nested(9));
      return 0;
    }
  C

  # The exact shape ruby-upb.c reaches rubycc with: UPB_ALIGN_AS resolved to its
  # `_Alignas` branch (rubycc defines no __GNUC__), used on the leading pointer
  # member of a definition struct and on a file-scope static char array that
  # backs a default-options blob. This is the case the feature exists for, so it
  # is written out rather than inferred from the cases above.
  UPB_SHAPED_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>

    #define UPB_ALIGN_AS(x) _Alignas(x)
    #define _UPB_MAXOPT_SIZE 16

    typedef struct { int unused; } upb_EnumOptions;
    typedef struct { int unused; } upb_FeatureSet;

    struct upb_EnumDef {
      UPB_ALIGN_AS(8) const upb_EnumOptions *opts;
      const upb_FeatureSet *resolved_features;
      const char *full_name;
      int value_count;
      char is_sorted;
    };

    static UPB_ALIGN_AS(8) const
        char opt_default_buf[_UPB_MAXOPT_SIZE + sizeof(void *)] = { 0 };
    const char *kUpbDefOptDefault = &opt_default_buf[sizeof(void *)];

    int main(void) {
      printf("%zu %zu %zu\\n", sizeof(struct upb_EnumDef), _Alignof(struct upb_EnumDef),
             offsetof(struct upb_EnumDef, opts));
      printf("%zu %d\\n", sizeof(opt_default_buf),
             ((unsigned long)opt_default_buf % 8) == 0);
      printf("%d\\n", (int)(kUpbDefOptDefault - opt_default_buf));
      return 0;
    }
  C

  def test_member_layouts_match_gcc
    assert_matches_gcc(MEMBER_LAYOUT_SOURCE, "alignas_members")
  end

  def test_object_alignments_match_gcc
    assert_matches_gcc(OBJECT_ALIGNMENT_SOURCE, "alignas_objects")
  end

  def test_upb_shaped_program_matches_gcc
    assert_matches_gcc(UPB_SHAPED_SOURCE, "alignas_upb_shaped")
  end

  def test_aarch64_member_layouts_match_gcc
    assert_aarch64_matches_gcc(MEMBER_LAYOUT_SOURCE)
  end

  def test_aarch64_object_alignments_match_gcc
    assert_aarch64_matches_gcc(OBJECT_ALIGNMENT_SOURCE)
  end

  def test_aarch64_overaligned_automatic_objects_are_realigned
    assert_aarch64_matches_gcc(OVERALIGNED_AUTOMATIC_SOURCE)
  end

  def test_aarch64_upb_shaped_program_matches_gcc
    assert_aarch64_matches_gcc(UPB_SHAPED_SOURCE)
  end

  # <stdalign.h>'s `alignas` macro is the same specifier under its friendlier
  # name, so the header now backs a real declaration rather than only naming a
  # keyword the compiler refused.
  def test_stdalign_macro_matches_gcc
    source = <<~C
      #include <stdalign.h>
      #include <stdio.h>
      #include <stddef.h>
      struct padded { alignas(16) char tag; int value; };
      alignas(32) static char buffer[8];
      int main(void) {
        printf("%zu %zu %zu\\n", sizeof(struct padded), alignof(struct padded),
               offsetof(struct padded, value));
        printf("%d %d %d\\n", ((unsigned long)buffer % 32) == 0,
               __alignas_is_defined, __alignof_is_defined);
        return 0;
      }
    C
    assert_matches_gcc(source, "alignas_stdalign")
  end

  # 6.7.5p4: an _Alignas may raise a declaration's boundary but never lower it.
  # gcc rejects each of these; so does rubycc, with gcc's wording.
  def test_weakening_requests_are_rejected
    {
      "struct s { _Alignas(1) int a; };" => /cannot reduce alignment of 'a'/,
      "_Alignas(1) int g;" => /cannot reduce alignment of 'g'/,
      "_Alignas(char) long g;" => /cannot reduce alignment of 'g'/,
      "struct s { _Alignas(1) struct { int x; }; char c; };" =>
        /cannot reduce alignment of unnamed field/
    }.each do |declaration, pattern|
      error = compile_error("#{declaration}\nint main(void) { return 0; }\n", "weaken.c")
      assert_match(pattern, error.message, "expected '#{declaration}' to be refused")
    end
  end

  # An alignment must be a positive power of two; zero alone "has no effect"
  # (6.7.5p3) and is accepted, which OBJECT_ALIGNMENT_SOURCE exercises.
  def test_non_power_of_two_requests_are_rejected
    ["_Alignas(3) int g;", "_Alignas(-8) int g;", "_Alignas(12) int g;"].each do |declaration|
      error = compile_error("#{declaration}\nint main(void) { return 0; }\n", "power.c")
      assert_match(/is not a positive power of 2/, error.message,
                   "expected '#{declaration}' to be refused")
    end
  end

  # 6.7.5p2: the five declarations that have no object to align. A type-name is
  # the sixth — it declares nothing at all — which gcc also refuses.
  def test_declarations_with_no_object_to_align_are_rejected
    {
      "typedef _Alignas(8) int T;" => /alignment specified for typedef 'T'/,
      "_Alignas(8) int f(void);" => /alignment specified for function 'f'/,
      "_Alignas(8) int f(void) { return 0; }" => /alignment specified for function 'f'/,
      "int f(_Alignas(8) int x);" => /alignment specified for parameter 'x'/,
      "struct s { _Alignas(8) int a : 3; };" => /alignment specified for bit-field 'a'/,
      "struct s { _Alignas(8) int : 3; };" => /alignment specified for bit-field/,
      "int probe(void) { return (int)sizeof(_Alignas(8) int); }" =>
        /alignment specified for type name/
    }.each do |declaration, pattern|
      error = compile_error("#{declaration}\nint main(void) { return 0; }\n", "no_object.c")
      assert_match(pattern, error.message, "expected '#{declaration}' to be refused")
    end
  end

  # An automatic object asking for a boundary past the 16 bytes the frame stands
  # on (an aggregate) or the 8 its virtual-register slot stands on (a scalar):
  # the prologue realigns the stack pointer and the object lands where it asked,
  # which is what the address remainders below read back. gcc is the oracle for
  # every line.
  def test_overaligned_automatic_objects_are_realigned
    assert_matches_gcc(OVERALIGNED_AUTOMATIC_SOURCE, "overaligned_automatic")
  end

  # The one ceiling rubycc keeps where gcc has none: a realigning prologue drops
  # the stack pointer by the frame plus the boundary itself in a single step, so
  # a request past a page could carry it over the guard page with no access in
  # between. A static-duration object in the same block is unaffected
  # (OBJECT_ALIGNMENT_SOURCE asks for 256, and the source below for 8192).
  def test_automatic_alignment_past_a_page_is_refused
    error = compile_error("int main(void) { _Alignas(8192) char buf[4]; return buf[0]; }\n",
                          "overaligned.c")
    assert_match(/requested alignment 8192 for 'buf' exceeds the 4096 bytes/, error.message)

    Rubycc::Compiler.new.compile("int main(void) { static _Alignas(8192) char buf[4]; return buf[0]; }\n",
                                 filename: "static_page.c", target: host_target)
  end

  private

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
