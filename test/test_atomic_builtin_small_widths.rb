# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The atomic builtins on 1- and 2-byte objects (atomic-builtin-small-widths-1).
# Before this step rubycc refused them ("supports atomic objects of 4 or 8 bytes
# only"), which stopped iodine 0.7.59: facil.io's one-byte spinlock
# (`typedef uint8_t volatile fio_lock_i`) is taken with __atomic_exchange_n.
# The same step added the bitwise fetch forms (and/or/xor, either half) of both
# families, so they are exercised here at every width.
#
# The values are pinned by a gcc differential on both targets, signed and
# unsigned: a narrow result has to come back extended the way the object's type
# says (an unsigned char holding 0xF0 is 240, a signed one -16), and a narrow
# compare-exchange has to compare only the object's bits. Atomicity is checked
# twice over — by a multi-threaded run whose totals would come up short if any
# increment were torn or lost, and by reading the emitted instructions back.
class TestAtomicBuiltinSmallWidths < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # The issue's minimal reproduction, verbatim.
  ISSUE_REPRO_SOURCE = <<~C
    static unsigned char flag;
    unsigned char f(void) { return __atomic_exchange_n(&flag, 1, __ATOMIC_SEQ_CST); }
    unsigned short g(unsigned short *p) { return __atomic_exchange_n(p, 2, __ATOMIC_SEQ_CST); }
  C

  # Every object form of both families, instantiated per object type. Each
  # builtin gets a statement of its own and the object is printed by a separate
  # printf, so neither compiler's argument evaluation order enters the output.
  # The operands are chosen to wrap: 250 + 7 in an unsigned char, 120 + 9 in a
  # signed one, 0x180 or-ed into a byte, a 16-bit mask and-ed into it — the cases
  # where a result that kept the machine's upper bits, or was extended the wrong
  # way, would print differently from gcc's.
  ALL_FORMS_SOURCE = <<~'C'
    #include <stdio.h>

    #define ALL_FORMS(T, FMT, NAME, INIT, OPND, SWAP)                                 \
      static void NAME(void) {                                                        \
        T v = INIT;                                                                   \
        T r;                                                                          \
        T e;                                                                          \
        int ok;                                                                       \
        r = __atomic_load_n(&v, __ATOMIC_SEQ_CST);  printf(#NAME " load " FMT "\n", r); \
        __atomic_store_n(&v, (T)(INIT + 1), __ATOMIC_SEQ_CST);                        \
        printf(#NAME " store " FMT "\n", v);                                          \
        r = __atomic_exchange_n(&v, SWAP, __ATOMIC_SEQ_CST);                          \
        printf(#NAME " xchg " FMT, r); printf(" " FMT "\n", v);                       \
        r = __atomic_fetch_add(&v, OPND, __ATOMIC_SEQ_CST);                           \
        printf(#NAME " fadd " FMT, r); printf(" " FMT "\n", v);                       \
        r = __atomic_add_fetch(&v, OPND, __ATOMIC_SEQ_CST);                           \
        printf(#NAME " addf " FMT, r); printf(" " FMT "\n", v);                       \
        r = __atomic_fetch_sub(&v, OPND, __ATOMIC_SEQ_CST);                           \
        printf(#NAME " fsub " FMT, r); printf(" " FMT "\n", v);                       \
        r = __atomic_sub_fetch(&v, 3 * OPND, __ATOMIC_SEQ_CST);                       \
        printf(#NAME " subf " FMT, r); printf(" " FMT "\n", v);                       \
        r = __atomic_fetch_or(&v, 0x41, __ATOMIC_SEQ_CST);                            \
        printf(#NAME " for " FMT, r); printf(" " FMT "\n", v);                        \
        r = __atomic_or_fetch(&v, 0x180, __ATOMIC_SEQ_CST);                           \
        printf(#NAME " orf " FMT, r); printf(" " FMT "\n", v);                        \
        r = __atomic_fetch_and(&v, 0xF0F3, __ATOMIC_SEQ_CST);                         \
        printf(#NAME " fand " FMT, r); printf(" " FMT "\n", v);                       \
        r = __atomic_and_fetch(&v, 0x7F81, __ATOMIC_SEQ_CST);                         \
        printf(#NAME " andf " FMT, r); printf(" " FMT "\n", v);                       \
        r = __atomic_fetch_xor(&v, 0xFFFF, __ATOMIC_SEQ_CST);                         \
        printf(#NAME " fxor " FMT, r); printf(" " FMT "\n", v);                       \
        r = __atomic_xor_fetch(&v, 0x8001, __ATOMIC_SEQ_CST);                         \
        printf(#NAME " xorf " FMT, r); printf(" " FMT "\n", v);                       \
        e = v;                                                                        \
        ok = __atomic_compare_exchange_n(&v, &e, SWAP, 0,                             \
                                         __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);         \
        printf(#NAME " caswin %d " FMT, ok, e); printf(" " FMT "\n", v);              \
        e = (T)(SWAP + 5);                                                            \
        ok = __atomic_compare_exchange_n(&v, &e, INIT, 0,                             \
                                         __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);         \
        printf(#NAME " caslose %d " FMT, ok, e); printf(" " FMT "\n", v);             \
        r = __sync_fetch_and_add(&v, OPND);                                           \
        printf(#NAME " sfadd " FMT, r); printf(" " FMT "\n", v);                      \
        r = __sync_sub_and_fetch(&v, OPND);                                           \
        printf(#NAME " ssubf " FMT, r); printf(" " FMT "\n", v);                      \
        r = __sync_fetch_and_or(&v, 0x80);                                            \
        printf(#NAME " sfor " FMT, r); printf(" " FMT "\n", v);                       \
        r = __sync_or_and_fetch(&v, 0x3);                                             \
        printf(#NAME " sorf " FMT, r); printf(" " FMT "\n", v);                       \
        r = __sync_fetch_and_and(&v, 0xFF7F);                                         \
        printf(#NAME " sfand " FMT, r); printf(" " FMT "\n", v);                      \
        r = __sync_and_and_fetch(&v, 0xFFF0);                                         \
        printf(#NAME " sandf " FMT, r); printf(" " FMT "\n", v);                      \
        r = __sync_fetch_and_xor(&v, 0x55);                                           \
        printf(#NAME " sfxor " FMT, r); printf(" " FMT "\n", v);                      \
        r = __sync_xor_and_fetch(&v, 0xAA);                                           \
        printf(#NAME " sxorf " FMT, r); printf(" " FMT "\n", v);                      \
        r = __sync_lock_test_and_set(&v, SWAP);                                       \
        printf(#NAME " stas " FMT, r); printf(" " FMT "\n", v);                       \
        ok = __sync_bool_compare_and_swap(&v, SWAP, INIT);                            \
        printf(#NAME " sbcas %d " FMT "\n", ok, v);                                   \
        r = __sync_val_compare_and_swap(&v, INIT, SWAP);                              \
        printf(#NAME " svcas " FMT, r); printf(" " FMT "\n", v);                      \
        r = __sync_val_compare_and_swap(&v, INIT, SWAP);                              \
        printf(#NAME " svcas2 " FMT, r); printf(" " FMT "\n", v);                     \
        __sync_lock_release(&v);                                                      \
        printf(#NAME " rel " FMT "\n", v);                                            \
        printf(#NAME " int %d\n", (int)__atomic_load_n(&v, __ATOMIC_SEQ_CST) - 1);    \
      }

    ALL_FORMS(unsigned char, "%u", uc, 250, 7, 0xF0)
    ALL_FORMS(signed char, "%d", sc, 120, 9, -16)
    ALL_FORMS(char, "%d", pc, -3, 100, 'z')
    ALL_FORMS(unsigned short, "%u", us, 65530, 9, 0xFF00)
    ALL_FORMS(short, "%d", ss, 32760, 11, -32000)
    ALL_FORMS(unsigned int, "%u", ui, 4000000000u, 7, 0xF0F0F0F0u)
    ALL_FORMS(long, "%ld", sl, -5L, 70000L, -0x123456789L)

    int main(void) {
      uc(); sc(); pc(); us(); ss(); ui(); sl();
      return 0;
    }
  C

  # _Bool objects take the forms gcc allows on them — exchange, load, store and
  # both compare-and-swap spellings — and each result must be exactly 0 or 1.
  BOOL_SOURCE = <<~C
    #include <stdio.h>
    int main(void) {
      _Bool b = 0, e = 0;
      _Bool r = __atomic_exchange_n(&b, 1, __ATOMIC_SEQ_CST);
      printf("xchg %d %d\\n", r, b);
      int ok = __atomic_compare_exchange_n(&b, &e, 0, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      printf("cas %d %d %d\\n", ok, e, b);
      printf("load %d\\n", __atomic_load_n(&b, __ATOMIC_SEQ_CST));
      __atomic_store_n(&b, 0, __ATOMIC_SEQ_CST);
      printf("store %d\\n", b);
      r = __sync_lock_test_and_set(&b, 1);
      printf("tas %d %d\\n", r, b);
      r = __sync_val_compare_and_swap(&b, 1, 0);
      printf("vcas %d %d\\n", r, b);
      ok = __sync_bool_compare_and_swap(&b, 0, 1);
      printf("bcas %d %d\\n", ok, b);
      return 0;
    }
  C

  # A narrow access must touch its own byte/halfword and nothing else: the
  # neighbours packed around each object come out unchanged.
  NEIGHBOURS_SOURCE = <<~C
    #include <stdio.h>
    struct packed_bytes { unsigned char a, b, c, d; unsigned short h[3]; };
    int main(void) {
      struct packed_bytes s = { 1, 2, 3, 4, { 5, 6, 7 } };
      unsigned short he = 5;
      __atomic_exchange_n(&s.b, 0xAB, __ATOMIC_SEQ_CST);
      __atomic_fetch_add(&s.c, 0xFF, __ATOMIC_SEQ_CST);
      __atomic_store_n(&s.h[1], 0xBEEF, __ATOMIC_SEQ_CST);
      __atomic_or_fetch(&s.h[2], 0xF000, __ATOMIC_SEQ_CST);
      __atomic_compare_exchange_n(&s.h[0], &he, 0x1234, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      __sync_fetch_and_xor(&s.d, 0xFF);
      printf("%u %u %u %u %u %u %u\\n", s.a, s.b, s.c, s.d, s.h[0], s.h[1], s.h[2]);
      return 0;
    }
  C

  # Four threads hammer narrow objects at once. Every total is known in
  # advance, so a lost or torn update shows up as a wrong number:
  #   - a one-byte spinlock taken with __atomic_exchange_n (facil.io's shape)
  #     guards a plain long, which must reach THREADS * ROUNDS exactly;
  #   - 1- and 2-byte counters bumped by fetch_add / add_fetch / __sync
  #     fetch_and_sub end at the total modulo their width;
  #   - a 2-byte counter advanced by a weak compare-exchange loop likewise;
  #   - each thread or-s its own bit into a shared byte and and-s it back out,
  #     which leaves 0 only if no read-modify-write clobbered another's bit.
  THREADS_SOURCE = <<~C
    #include <pthread.h>
    #include <stdio.h>

    #define THREADS 4
    #define ROUNDS 20000

    static unsigned char lock;
    static long guarded;
    static unsigned char byte_counter;
    static unsigned short half_counter;
    static signed char byte_down;
    static unsigned short cas_counter;
    static unsigned char flags;

    static void spin_lock(void) {
      while (__atomic_exchange_n(&lock, 1, __ATOMIC_ACQUIRE))
        ;
    }

    static void spin_unlock(void) {
      __atomic_store_n(&lock, 0, __ATOMIC_RELEASE);
    }

    static void *work(void *arg) {
      unsigned char bit = (unsigned char)(1u << (long)arg);
      for (int i = 0; i < ROUNDS; i++) {
        spin_lock();
        guarded++;
        spin_unlock();
        __atomic_fetch_add(&byte_counter, 1, __ATOMIC_SEQ_CST);
        __atomic_add_fetch(&half_counter, 1, __ATOMIC_SEQ_CST);
        __sync_fetch_and_sub(&byte_down, 1);
        unsigned short seen = __atomic_load_n(&cas_counter, __ATOMIC_RELAXED);
        while (!__atomic_compare_exchange_n(&cas_counter, &seen, (unsigned short)(seen + 1), 1,
                                            __ATOMIC_SEQ_CST, __ATOMIC_RELAXED))
          ;
        __atomic_fetch_or(&flags, bit, __ATOMIC_SEQ_CST);
        __atomic_fetch_and(&flags, (unsigned char)~bit, __ATOMIC_SEQ_CST);
      }
      return 0;
    }

    int main(void) {
      pthread_t threads[THREADS];
      for (long t = 0; t < THREADS; t++)
        pthread_create(&threads[t], 0, work, (void *)t);
      for (int t = 0; t < THREADS; t++)
        pthread_join(threads[t], 0);
      printf("guarded %ld\\n", guarded);
      printf("byte %u\\n", byte_counter);
      printf("half %u\\n", half_counter);
      printf("down %d\\n", byte_down);
      printf("cas %u\\n", cas_counter);
      printf("flags %u lock %u\\n", flags, lock);
      return 0;
    }
  C

  # THREADS * ROUNDS = 80000: 80000 mod 256 = 128, 80000 mod 65536 = 14464,
  # and -80000 in a signed char is -128.
  THREADS_EXPECTED = <<~OUT
    guarded 80000
    byte 128
    half 14464
    down -128
    cas 14464
    flags 0 lock 0
  OUT

  HAS_BUILTIN_SOURCE = <<~C
    #include <stdio.h>
    #if __has_builtin(__atomic_fetch_and) && __has_builtin(__atomic_fetch_or) && \\
        __has_builtin(__atomic_fetch_xor) && __has_builtin(__atomic_and_fetch) && \\
        __has_builtin(__atomic_xor_fetch) && __has_builtin(__sync_fetch_and_and) && \\
        __has_builtin(__sync_fetch_and_or) && __has_builtin(__sync_fetch_and_xor) && \\
        __has_builtin(__sync_and_and_fetch) && __has_builtin(__sync_xor_and_fetch)
    #define ALL_KNOWN 1
    #else
    #define ALL_KNOWN 0
    #endif
    int main(void) {
      unsigned char c = 1;
      short s = 2;
      printf("%d %zu %zu %zu\\n", ALL_KNOWN,
             sizeof(__atomic_fetch_or(&c, 1, __ATOMIC_SEQ_CST)),
             sizeof(__sync_xor_and_fetch(&s, 1)),
             sizeof(__atomic_load_n(&c, __ATOMIC_SEQ_CST)));
      printf("%u %d\\n", c, s);
      return 0;
    }
  C

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  def test_issue_repro_compiles
    refute_empty compile(ISSUE_REPRO_SOURCE)
    refute_empty Rubycc::Compiler.new.compile(ISSUE_REPRO_SOURCE, filename: "repro.c", target: "aarch64")
  end

  def test_all_forms_match_gcc
    assert_matches_gcc(ALL_FORMS_SOURCE, "small_widths_all_forms")
  end

  def test_bool_objects_match_gcc
    assert_matches_gcc(BOOL_SOURCE, "small_widths_bool")
  end

  def test_neighbours_are_untouched
    assert_matches_gcc(NEIGHBOURS_SOURCE, "small_widths_neighbours")
    _status, stdout = run_source(NEIGHBOURS_SOURCE, :rubycc)
    assert_equal "1 171 2 251 4660 48879 61447\n", stdout
  end

  def test_has_builtin_and_result_types_match_gcc
    assert_matches_gcc(HAS_BUILTIN_SOURCE, "small_widths_has_builtin")
  end

  def test_threads_match_gcc_and_lose_no_update
    assert_matches_gcc(THREADS_SOURCE, "small_widths_threads")
    _status, stdout = run_source(THREADS_SOURCE, :rubycc)
    assert_equal THREADS_EXPECTED, stdout
  end

  def test_aarch64_all_forms_match_gcc
    assert_aarch64_matches_gcc(ALL_FORMS_SOURCE)
  end

  def test_aarch64_bool_objects_match_gcc
    assert_aarch64_matches_gcc(BOOL_SOURCE)
  end

  def test_aarch64_neighbours_are_untouched
    assert_aarch64_matches_gcc(NEIGHBOURS_SOURCE)
  end

  def test_aarch64_threads_match_gcc_and_lose_no_update
    assert_aarch64_matches_gcc(THREADS_SOURCE)
    _status, stdout = run_aarch64(THREADS_SOURCE, compiler: :rubycc)
    assert_equal THREADS_EXPECTED, stdout
  end

  # gcc refuses the arithmetic and bitwise read-modify-writes on a _Bool object
  # (measured 2026-09-14, gcc 13.3) while accepting exchange, load, store and
  # compare-exchange there; rubycc draws the same line.
  def test_bool_arithmetic_is_diagnosed
    ["__atomic_fetch_add(&b, 1, 5)", "__atomic_or_fetch(&b, 1, 5)",
     "__sync_fetch_and_xor(&b, 1)", "__sync_sub_and_fetch(&b, 1)"].each do |call|
      name = call[/\A\w+/]
      error = assert_raises(Rubycc::CompileError, "expected '#{call}' to be refused") do
        compile("int main(void) { _Bool b = 0; return (int)#{call}; }")
      end
      assert_match(/'#{name}' does not support arithmetic or bitwise operations on '_Bool'/, error.message)
    end
  end

  # Atomicity on the instruction stream: every narrow read-modify-write is a
  # byte/word `lock` form or an `xchg` (implicitly locked).
  def test_x86_64_emits_narrow_locked_instructions
    skip_unless_x86_64_host
    skip "objdump unavailable" unless tool?("objdump")

    listing = in_tmpdir do |dir|
      object_path = File.join(dir, "narrow.o")
      compile_with_rubycc(ALL_FORMS_SOURCE, object_path)
      stdout, _stderr, status = Open3.capture3("objdump", "-d", object_path)
      raise "objdump failed" unless status.success?

      stdout
    end

    # Per narrow type: fetch_add/add_fetch/fetch_sub/sub_fetch and the two
    # __sync add/sub forms are xadds (6); the twelve bitwise forms (six per
    # family) are cmpxchg loops, joined by the two __atomic compare-exchanges
    # and the three __sync compare-and-swap calls (17);
    # exchange/store/test_and_set/release are xchgs (4). Three types are
    # 1-byte (unsigned, signed, plain char), two 2-byte.
    assert_equal 3 * 6, listing.scan(/lock xadd\s+%cl,\(%rax\)/).size
    assert_equal 2 * 6, listing.scan(/lock xadd\s+%cx,\(%rax\)/).size
    assert_equal 3 * 17, listing.scan(/lock cmpxchg\s+%dl,\(%rdi\)/).size
    assert_equal 2 * 17, listing.scan(/lock cmpxchg\s+%dx,\(%rdi\)/).size
    assert_equal 3 * 4, listing.scan(/xchg\s+%cl,\(%rax\)/).size
    assert_equal 2 * 4, listing.scan(/xchg\s+%cx,\(%rax\)/).size
  end

  # The aarch64 counterpart: the b/h forms of the armv8-a baseline exclusive
  # pair, each store-exclusive closed by a retry branch, and no LSE atomics.
  def test_aarch64_emits_narrow_exclusive_loops
    skip_unless_aarch64_toolchain

    listing = in_tmpdir do |dir|
      object_path = File.join(dir, "narrow.o")
      compile_with_rubycc_aarch64(ALL_FORMS_SOURCE, object_path)
      disassemble_aarch64(object_path)
    end

    # Per narrow type: 20 read-modify-writes (exchange, the six add/sub forms,
    # the twelve bitwise ones, test_and_set) plus 5 compare-and-swaps.
    assert_equal 3 * 25, listing.scan(/\bldaxrb\b/).size
    assert_equal 2 * 25, listing.scan(/\bldaxrh\b/).size
    assert_equal listing.scan(/\bldaxrb\b/).size, listing.scan(/\bstlxrb\b/).size
    assert_equal listing.scan(/\bldaxrh\b/).size, listing.scan(/\bstlxrh\b/).size
    assert_equal listing.scan(/\bstlxr[bh]?\b/).size, listing.scan(/\bcbnz\b/).size
    # __atomic_load_n twice per type; __atomic_store_n and __sync_lock_release
    # once each per type.
    assert_equal 3 * 2, listing.scan(/\bldarb\b/).size
    assert_equal 2 * 2, listing.scan(/\bldarh\b/).size
    assert_equal 3 * 2, listing.scan(/\bstlrb\b/).size
    assert_equal 2 * 2, listing.scan(/\bstlrh\b/).size
    refute_match(/\b(casal|casb|cas|ldadd\w*|swp\w*)\b/, listing,
                 "the LSE atomics need armv8.1-a and must not be emitted")
  end

  private

  def compile(source)
    Rubycc::Compiler.new.compile(source, filename: "atomic.c", target: host_target)
  end

  def run_source(source, compiler)
    in_tmpdir do |dir|
      object_path = File.join(dir, "atomic.o")
      compile_source(source, object_path, compiler)
      link_and_run(object_path)
    end
  end

  def assert_matches_gcc(source, name)
    rubycc_status, rubycc_out = run_source(source, :rubycc)
    gcc_status, gcc_out = run_source(source, :gcc)

    assert_equal 0, rubycc_status, "rubycc-built #{name} exited #{rubycc_status}"
    assert_equal gcc_status, rubycc_status, "#{name}: exit status differs from gcc"
    assert_equal gcc_out, rubycc_out, "#{name}: output differs from gcc"
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
