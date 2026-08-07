# frozen_string_literal: true

require_relative "test_helper"

# Step 48: reading and writing bit-fields. The layout (unit sharing, straddle,
# ":0" realignment) was fixed in Step 28; this step adds the access lowering —
# a shift/mask extraction on read, and a load-clear-splice-store
# (read-modify-write) on write, leaving neighbouring fields in the shared unit
# untouched. A plain-int field is signed (gcc's rule) so its value
# sign-extends; a _Bool or unsigned field zero-extends. These tests cross-check
# every shape against gcc, including the msgpack idiom (five `_Bool f:1`), a
# mixed-width shared unit with a signed field, a ":0"-forced unit span, and the
# truncated value an assignment expression yields. "&s.field" stays a
# diagnostic (a bit-field has no whole-byte address).
class TestBitfield < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # The msgpack msgpack_unpacker_t idiom: five one-bit _Bool flags, written and
  # read both directly and through a pointer, across a function boundary.
  MSGPACK_FLAGS_SOURCE = <<~C
    #include <stdio.h>
    typedef struct {
      _Bool use_key_cache : 1;
      _Bool optimized_symbol_ex : 1;
      _Bool symbolize_keys : 1;
      _Bool freeze : 1;
      _Bool allow_unknown_ext : 1;
    } unpacker_t;

    void configure(unpacker_t *uk, int a, int b, int c, int d, int e) {
      uk->use_key_cache = a;
      uk->optimized_symbol_ex = b;
      uk->symbolize_keys = c;
      uk->freeze = d;
      uk->allow_unknown_ext = e;
    }

    int symbolize(unpacker_t *uk) {
      return uk->symbolize_keys ? 42 : 7;
    }

    int main(void) {
      unpacker_t uk;
      configure(&uk, 1, 0, 1, 0, 1);
      printf("%d %d %d %d %d\\n",
             uk.use_key_cache ? 1 : 0,
             uk.optimized_symbol_ex ? 1 : 0,
             uk.symbolize_keys ? 1 : 0,
             uk.freeze ? 1 : 0,
             uk.allow_unknown_ext ? 1 : 0);
      printf("%d\\n", symbolize(&uk));

      uk.symbolize_keys = 0;
      printf("%d %d\\n", uk.symbolize_keys ? 1 : 0, symbolize(&uk));

      /* A non-zero-but-not-one value must normalize to 1 in a _Bool field. */
      uk.freeze = 99;
      printf("%d\\n", uk.freeze ? 1 : 0);
      return 0;
    }
  C

  # A single storage unit shared by four differently-signed, differently-sized
  # fields: writing each must leave the others intact, and the signed field
  # sign-extends on read.
  MIXED_UNIT_SOURCE = <<~C
    #include <stdio.h>
    struct mix { unsigned a:3; unsigned b:5; int c:6; unsigned d:10; };

    int read_c(struct mix *m) { return m->c; }

    int main(void) {
      struct mix m;
      m.a = 5; m.b = 20; m.c = -9; m.d = 1000;
      printf("%u %u %d %u\\n", m.a, m.b, m.c, m.d);
      printf("%d\\n", read_c(&m));

      /* Overwrite each field; the neighbours must survive. */
      m.c = 40;
      printf("%u %u %d %u\\n", m.a, m.b, m.c, m.d);

      m.a = 7; m.b = 31; m.d = 1023;
      printf("%u %u %d %u\\n", m.a, m.b, m.c, m.d);

      /* Compound assignment and ++/-- on a shared field. */
      m.a += 2;
      m.c -= 5;
      m.b++;
      printf("%u %u %d %u\\n", m.a, m.b, m.c, m.d);
      return 0;
    }
  C

  # A ":0" unnamed field forces the next field onto a fresh storage unit, so the
  # struct spans more than one unit; each unit is read/written independently.
  SPAN_SOURCE = <<~C
    #include <stdio.h>
    struct span {
      unsigned a:20;
      int c:6;
      int :0;
      unsigned e:20;
      int f:6;
    };

    int main(void) {
      struct span s;
      s.a = 0xFFFFF; s.c = -3; s.e = 12345; s.f = 20;
      printf("%u %d %u %d\\n", s.a, s.c, s.e, s.f);

      s.c = 30;      /* 6-bit signed: 30 stays 30 */
      s.f = 40;      /* 6-bit signed: 40 wraps to -24 */
      printf("%u %d %u %d\\n", s.a, s.c, s.e, s.f);
      return 0;
    }
  C

  # The value of an assignment expression is the field read back after
  # truncation, which for a signed field is sign-extended: 40 into a 6-bit
  # signed field reads as -24.
  ASSIGN_VALUE_SOURCE = <<~C
    #include <stdio.h>
    struct s { int c:6; unsigned u:6; };
    int main(void) {
      struct s p;
      int x = (p.c = 40);
      unsigned y = (p.u = 40);
      printf("%d %d %u %u\\n", x, p.c, y, p.u);
      return 0;
    }
  C

  # A long-based bit-field wider than 32 bits exercises the 64-bit unit path.
  LONG_UNIT_SOURCE = <<~C
    #include <stdio.h>
    struct big { long a:40; unsigned long b:20; };
    int main(void) {
      struct big s;
      s.a = -1234567890123L;
      s.b = 1000000;
      printf("%ld %lu\\n", s.a, s.b);
      s.a = 999999999999L;
      printf("%ld %lu\\n", s.a, s.b);
      return 0;
    }
  C

  def test_msgpack_flags_match_gcc
    assert_matches_gcc(MSGPACK_FLAGS_SOURCE, "bf_flags")
  end

  def test_mixed_unit_matches_gcc
    assert_matches_gcc(MIXED_UNIT_SOURCE, "bf_mixed")
  end

  def test_unit_span_matches_gcc
    assert_matches_gcc(SPAN_SOURCE, "bf_span")
  end

  def test_assignment_value_matches_gcc
    assert_matches_gcc(ASSIGN_VALUE_SOURCE, "bf_assign")
  end

  def test_long_unit_matches_gcc
    assert_matches_gcc(LONG_UNIT_SOURCE, "bf_long")
  end

  # "&s.field" names no whole-byte object, so it stays a diagnostic.
  def test_address_of_bitfield_is_rejected
    source = <<~C
      struct s { int a:3; };
      int main(void) {
        struct s x;
        int *p = &x.a;
        return 0;
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "bf.c")
    end
    assert_match(/cannot take address of bit-field 'a'/, error.message)
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
