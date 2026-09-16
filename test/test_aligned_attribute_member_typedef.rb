# frozen_string_literal: true

require_relative "test_helper"

# aligned-attribute-member-typedef-1: __attribute__((aligned(N))) on a struct
# member's declarator, on a typedef name and on a variable's declarator, with
# and without `packed`. rubycc used to drop all three (2026-09-14: the issue's
# repro printed "8 16 8 8" where gcc prints "16 16 16 16").
#
# gcc 13.3 is the oracle on both targets, and it gave the same answers on
# x86-64 and aarch64 for every shape here (measured 2026-09-15):
#  * a member's aligned(N) raises its boundary to N and never lowers it; under
#    a member or struct `packed` it applies in full;
#  * a typedef's aligned(N) *replaces* the type's boundary, lower or higher,
#    without changing its size, and reaches the declared type and arrays of
#    it but not a pointer to it;
#  * a variable's aligned(N) raises its address boundary;
#  * specifier-position attributes apply to every declarator of the
#    declaration, except an anonymous member, where gcc ignores them.
# Object boundaries are read back as address remainders, since rubycc has no
# __alignof__ on an expression. The one place rubycc places an object more
# strictly than gcc (a request below the type's own boundary) is unobservable
# that way, and the diagnostics gcc gives for arrays of over-aligned elements
# are checked against rubycc's own at the end.
class TestAlignedAttributeMemberTypedef < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  REPRO_SOURCE = <<~C
    #include <stdio.h>
    struct m { long a __attribute__((aligned(16))); long b; };
    typedef long al16 __attribute__((aligned(16)));
    struct t { al16 a; long b; };
    int main(void) { printf("%zu %zu %zu %zu\\n", _Alignof(struct m), sizeof(struct m), _Alignof(struct t), _Alignof(al16)); return 0; }
  C

  # P prints one expression per line, so a mismatch names its own row.
  PRINT_MACRO = '#define P(x) printf("%-36s %zu\\n", #x, (size_t)(x))'

  MEMBER_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    #{PRINT_MACRO}

    struct m8 { char c; long a __attribute__((aligned(8))); };
    struct m16 { char c; long a __attribute__((aligned(16))); };
    struct m32 { char c; long a __attribute__((aligned(32))); };
    struct mbare { char c; long a __attribute__((aligned)); };
    struct mdec { char c; long a __attribute__((aligned(4))); };
    struct mpk { char c; long a __attribute__((packed)); };
    struct mpkal { char c; long a __attribute__((packed, aligned(4))); };
    struct mpkal2 { char c; long a __attribute__((packed)) __attribute__((__aligned__(2))); };
    struct __attribute__((packed)) spk_m16 { char c; long a __attribute__((aligned(16))); char d; };
    struct __attribute__((packed)) spk_m4 { char c; long a __attribute__((aligned(4))); char d; };
    struct m_arr { char c; int a[3] __attribute__((aligned(16))); };
    struct m_multi { char c; long a __attribute__((aligned(16))), b; char d; };
    union u16 { char c; long a __attribute__((aligned(16))); };
    struct m_ptr { char c; char *p __attribute__((aligned(32))); };
    struct m_spec { char c; __attribute__((aligned(16))) long a; };
    struct m_spec2 { char c; long __attribute__((aligned(16))) a, b; };
    struct m_spec_ptr { char c; long __attribute__((aligned(16))) *p; };
    struct pair { long a, b; };
    struct m_pk_struct { char c; struct pair s __attribute__((packed)); };
    struct m_anon { char c; __attribute__((aligned(16))) struct { int x; }; };
    struct m_alignas_attr { char c; _Alignas(8) char d __attribute__((aligned(32))); };

    int main(void) {
      P(sizeof(struct m8)); P(_Alignof(struct m8));
      P(sizeof(struct m16)); P(_Alignof(struct m16)); P(offsetof(struct m16, a));
      P(sizeof(struct m32)); P(_Alignof(struct m32));
      P(sizeof(struct mbare)); P(_Alignof(struct mbare));
      P(_Alignof(struct mdec)); P(offsetof(struct mdec, a));
      P(sizeof(struct mpk)); P(_Alignof(struct mpk)); P(offsetof(struct mpk, a));
      P(_Alignof(struct mpkal)); P(offsetof(struct mpkal, a));
      P(_Alignof(struct mpkal2)); P(offsetof(struct mpkal2, a));
      P(sizeof(struct spk_m16)); P(_Alignof(struct spk_m16)); P(offsetof(struct spk_m16, a));
      P(sizeof(struct spk_m4)); P(_Alignof(struct spk_m4)); P(offsetof(struct spk_m4, a));
      P(sizeof(struct m_arr)); P(_Alignof(struct m_arr)); P(offsetof(struct m_arr, a));
      P(sizeof(struct m_multi)); P(offsetof(struct m_multi, b)); P(offsetof(struct m_multi, d));
      P(sizeof(union u16)); P(_Alignof(union u16));
      P(sizeof(struct m_ptr)); P(_Alignof(struct m_ptr));
      P(_Alignof(struct m_spec));
      P(sizeof(struct m_spec2)); P(_Alignof(struct m_spec2)); P(offsetof(struct m_spec2, b));
      P(offsetof(struct m_spec_ptr, p));
      P(sizeof(struct m_pk_struct)); P(_Alignof(struct m_pk_struct)); P(offsetof(struct m_pk_struct, s));
      P(sizeof(struct m_anon)); P(_Alignof(struct m_anon)); P(offsetof(struct m_anon, x));
      P(sizeof(struct m_alignas_attr)); P(offsetof(struct m_alignas_attr, d));
      return 0;
    }
  C

  TYPEDEF_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    #{PRINT_MACRO}

    typedef long t16 __attribute__((aligned(16)));
    typedef long t8 __attribute__((aligned(8)));
    typedef long t4 __attribute__((aligned(4)));
    typedef long tbare __attribute__((aligned));
    typedef char t32c __attribute__((aligned(32)));
    typedef t16 t16b;
    typedef t4 t4b;
    typedef t16 t16_lowered __attribute__((aligned(4)));
    typedef long __attribute__((aligned(16))) tspec16;
    typedef int tarr[3] __attribute__((aligned(16)));
    typedef char *tptr __attribute__((aligned(16)));
    typedef t16 *pt16;
    struct pair { long a, b; };
    typedef struct pair tpair32 __attribute__((aligned(32)));
    typedef struct pair tpair4 __attribute__((aligned(4)));
    typedef long t4pk __attribute__((packed, aligned(4)));
    typedef struct { long a, b; } tanon16 __attribute__((aligned(16)));

    struct use16 { char c; t16 a; };
    struct use8 { char c; t8 a; };
    struct use4 { char c; t4 a; };
    struct use4b { char c; t4b a; };
    struct use_lowered { char c; t16_lowered a; };
    struct __attribute__((packed)) pk_use16 { char c; t16 a; };
    struct use_bare { char c; tbare a; };
    struct use_arr { char c; tarr a; };
    struct use_pair32 { char c; tpair32 a; };
    struct use_pair4 { char c; tpair4 a; };
    struct use4_m16 { char c; t4 a __attribute__((aligned(16))); };
    struct use16_m4 { char c; t16 a __attribute__((aligned(4))); };
    struct use16_pk { char c; t16 a __attribute__((packed)); };
    struct use4_a2 { char c; t4 a[2]; };
    struct use_spec { char c; tspec16 a; };
    struct use32c { char c; t32c a; char d; };
    struct use_pt16 { char c; pt16 p; };
    struct use_anon16 { char c; tanon16 a; };
    union u4 { char c[5]; t4 a; };
    struct alignas_t16 { char c; _Alignas(t16) char d; };

    int main(void) {
      P(sizeof(t16)); P(_Alignof(t16)); P(_Alignof(t8)); P(_Alignof(t4)); P(_Alignof(tbare));
      P(sizeof(t32c)); P(_Alignof(t32c));
      P(_Alignof(t16b)); P(_Alignof(t4b)); P(_Alignof(t16_lowered)); P(_Alignof(tspec16));
      P(sizeof(tarr)); P(_Alignof(tarr)); P(_Alignof(tptr)); P(_Alignof(pt16)); P(_Alignof(t16 *));
      P(sizeof(tpair32)); P(_Alignof(tpair32)); P(_Alignof(tpair4)); P(_Alignof(t4pk));
      P(sizeof(tanon16)); P(_Alignof(tanon16));
      P(sizeof(t4[2])); P(_Alignof(t4[2]));
      P(sizeof(struct use16)); P(_Alignof(struct use16)); P(offsetof(struct use16, a));
      P(offsetof(struct use8, a));
      P(sizeof(struct use4)); P(_Alignof(struct use4)); P(offsetof(struct use4, a));
      P(offsetof(struct use4b, a)); P(offsetof(struct use_lowered, a));
      P(sizeof(struct pk_use16)); P(_Alignof(struct pk_use16)); P(offsetof(struct pk_use16, a));
      P(_Alignof(struct use_bare));
      P(sizeof(struct use_arr)); P(_Alignof(struct use_arr)); P(offsetof(struct use_arr, a));
      P(sizeof(struct use_pair32)); P(_Alignof(struct use_pair32)); P(offsetof(struct use_pair32, a));
      P(sizeof(struct use_pair4)); P(_Alignof(struct use_pair4)); P(offsetof(struct use_pair4, a));
      P(_Alignof(struct use4_m16)); P(offsetof(struct use4_m16, a));
      P(_Alignof(struct use16_m4)); P(offsetof(struct use16_m4, a));
      P(_Alignof(struct use16_pk)); P(offsetof(struct use16_pk, a));
      P(sizeof(struct use4_a2)); P(_Alignof(struct use4_a2)); P(offsetof(struct use4_a2, a));
      P(_Alignof(struct use_spec));
      P(sizeof(struct use32c)); P(_Alignof(struct use32c)); P(offsetof(struct use32c, d));
      P(offsetof(struct use_pt16, p));
      P(sizeof(struct use_anon16)); P(_Alignof(struct use_anon16)); P(offsetof(struct use_anon16, a));
      P(sizeof(union u4)); P(_Alignof(union u4));
      P(offsetof(struct alignas_t16, d));
      return 0;
    }
  C

  # Every object that asks for a boundary through an attribute or an aligned
  # typedef, at file scope, as a static of either scope and as an automatic
  # object within what the frame gives (16 for a stack object, 8 for a
  # scalar). A second object follows several of them, so an attribute that
  # only happened to land on a boundary is unlikely to pass twice.
  OBJECT_SOURCE = <<~C
    #include <stdio.h>

    typedef long t16 __attribute__((aligned(16)));
    typedef long t4 __attribute__((aligned(4)));
    struct pair { long a, b; };
    typedef struct pair tpair32 __attribute__((aligned(32)));

    char g_pad1;
    long g16 __attribute__((aligned(16)));
    char g_pad2;
    long g32 __attribute__((aligned(32))) = 3;
    static long s32 __attribute__((aligned(32)));
    char g_bare __attribute__((aligned));
    t16 g_t16;
    tpair32 g_pair32;
    __attribute__((aligned(64))) char g_spec[3];
    _Alignas(t16) char g_alignas_t16;
    _Alignas(4) t4 g_alignas_t4;
    char g_first, g_second __attribute__((aligned(32)));
    long g_lowered __attribute__((aligned(4)));
    extern char g_extern[5] __attribute__((aligned(16)));
    char g_extern[5];

    static int on(const void *p, unsigned long boundary) {
      return ((unsigned long)p % boundary) == 0;
    }

    int main(void) {
      long l8 __attribute__((aligned(8))) = 5;
      struct pair l_pair __attribute__((aligned(16)));
      char l_buf[3] __attribute__((aligned(16)));
      t16 l_t16 = 7;
      tpair32 l_pair32 = { 1, 2 };
      static long sl32 __attribute__((aligned(32)));
      static t16 sl_t16;
      static char sl_a __attribute__((aligned(64))), sl_b;

      l_pair.a = l8;
      printf("%d %d %d %d %d\\n", on(&g16, 16), on(&g32, 32), on(&s32, 32), on(&g_bare, 16), on(&g_t16, 16));
      printf("%d %d %d %d\\n", on(&g_pair32, 32), on(g_spec, 64), on(&g_alignas_t16, 16), on(&g_alignas_t4, 4));
      printf("%d %d %d\\n", on(&g_second, 32), on(&g_lowered, 4), on(g_extern, 16));
      printf("%d %d %d %d\\n", on(&l8, 8), on(&l_pair, 16), on(l_buf, 16), on(&l_pair32, 16));
      printf("%d %d %d\\n", on(&sl32, 32), on(&sl_t16, 16), on(&sl_a, 64));
      printf("%ld %ld %ld %ld %d %d\\n", l_pair.a, g32, (long)l_t16, l_pair32.b, (int)sl_b, (int)g_pad1 + g_pad2 + g_first);
      return 0;
    }
  C

  # The three automatic declarations that used to be refused — an aligned
  # attribute on a scalar, on an aggregate and in specifier position on an array
  # — plus the two whose boundary comes from a typedef rather than from the
  # declaration itself (a scalar typedef aligned 16 and a struct typedef aligned
  # 32), which the parser used to hold back for automatic objects.
  AUTOMATIC_ATTRIBUTE_SOURCE = <<~C
    typedef long t16 __attribute__((aligned(16)));
    typedef struct { long a, b; } box32 __attribute__((aligned(32)));

    #include <stdio.h>

    static int aligned_to(const void *p, unsigned long boundary) {
      return ((unsigned long)p % boundary) == 0;
    }

    static long attributes(long n) {
      long x __attribute__((aligned(16))) = n;
      struct { long a; } box __attribute__((aligned(32)));
      __attribute__((aligned(64))) char buf[4];
      box.a = n + 1;
      buf[0] = (char)n;
      return x + box.a + buf[0] +
             1000L * aligned_to(&x, 16) +
             2000L * aligned_to(&box, 32) +
             4000L * aligned_to(buf, 64);
    }

    static long typedefs(long n) {
      t16 x = n;
      box32 box;
      box.a = n + 1;
      return x + box.a + 1000L * aligned_to(&x, 16) + 2000L * aligned_to(&box, 32);
    }

    int main(void) {
      printf("%ld %ld\\n", attributes(5), typedefs(7));
      return 0;
    }
  C

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  def test_issue_repro_matches_gcc
    assert_matches_gcc(REPRO_SOURCE, "aligned_repro")
  end

  def test_member_layouts_match_gcc
    assert_matches_gcc(MEMBER_SOURCE, "aligned_members")
  end

  def test_typedef_layouts_match_gcc
    assert_matches_gcc(TYPEDEF_SOURCE, "aligned_typedefs")
  end

  def test_object_alignments_match_gcc
    assert_matches_gcc(OBJECT_SOURCE, "aligned_objects")
  end

  def test_aarch64_issue_repro_matches_gcc
    assert_aarch64_matches_gcc(REPRO_SOURCE)
  end

  def test_aarch64_member_layouts_match_gcc
    assert_aarch64_matches_gcc(MEMBER_SOURCE)
  end

  def test_aarch64_typedef_layouts_match_gcc
    assert_aarch64_matches_gcc(TYPEDEF_SOURCE)
  end

  def test_aarch64_object_alignments_match_gcc
    assert_aarch64_matches_gcc(OBJECT_SOURCE)
  end

  def test_aarch64_automatic_attribute_requests_are_honoured
    assert_aarch64_matches_gcc(AUTOMATIC_ATTRIBUTE_SOURCE)
  end

  # An array whose element type is aligned more strictly than its size allows
  # could not keep its second element on that boundary. gcc 13.3 refuses each
  # of these in these two wordings (measured 2026-09-15), wherever the array
  # is written: an object, a member, a typedef or a type-name.
  def test_arrays_of_overaligned_elements_are_rejected
    prelude = <<~C
      typedef long t16 __attribute__((aligned(16)));
      struct pair { long a, b; };
      typedef struct pair tpair32 __attribute__((aligned(32)));
      typedef struct { long a, b, c; } t24 __attribute__((aligned(16)));
      typedef int tarr[3] __attribute__((aligned(16)));
    C
    {
      "t16 a[2];" => /alignment of array elements is greater than element size/,
      "tpair32 a[2];" => /alignment of array elements is greater than element size/,
      "tarr a[2];" => /alignment of array elements is greater than element size/,
      "struct s { t16 a[2]; };" => /alignment of array elements is greater than element size/,
      "typedef t16 t16x2[2];" => /alignment of array elements is greater than element size/,
      "unsigned long n = sizeof(t16[2]);" => /alignment of array elements is greater than element size/,
      "t24 a[2];" => /size of array element is not a multiple of its alignment/
    }.each do |declaration, pattern|
      error = compile_error("#{prelude}#{declaration}\nint main(void) { return 0; }\n", "array.c")
      assert_match(pattern, error.message, "expected '#{declaration}' to be refused")
    end
  end

  # An _Alignas is measured against the boundary an aligned typedef gave the
  # type, not the type's natural one: gcc 13.3 refuses "_Alignas(8) t16 x;"
  # and accepts "_Alignas(4) t4 x;" (measured 2026-09-15).
  def test_alignas_is_checked_against_the_typedef_boundary
    prelude = "typedef long t16 __attribute__((aligned(16)));\n" \
              "typedef long t4 __attribute__((aligned(4)));\n"
    error = compile_error("#{prelude}_Alignas(8) t16 x;\nint main(void) { return 0; }\n", "reduce.c")
    assert_match(/'_Alignas' specifiers cannot reduce alignment of 'x'/, error.message)

    Rubycc::Compiler.new.compile("#{prelude}_Alignas(4) t4 x;\nstruct s { _Alignas(4) t4 a; };\n" \
                                 "int main(void) { return 0; }\n", filename: "keep.c", target: host_target)
  end

  # An aligned attribute written on an automatic object, and the boundary an
  # aligned typedef hands a local, reach the frame like an _Alignas does: the
  # prologue realigns the stack pointer and the object lands where it asked
  # (step overaligned-automatic-object-1). Before that step the attribute forms
  # were refused and the typedef-derived boundary was dropped on the floor, so
  # the same declarations are read back here against gcc.
  def test_overaligned_automatic_attribute_requests_are_honoured
    assert_matches_gcc(AUTOMATIC_ATTRIBUTE_SOURCE, "automatic_attribute")
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
