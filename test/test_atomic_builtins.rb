# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The gcc __atomic_* builtins <ruby/atomic.h> uses unconditionally (its
# HAVE_GCC_ATOMIC_BUILTINS branch, which CRuby's baked-in config.h always
# selects), so any gem whose sources reach ruby.h can be compiled: nine object
# forms, at the two object widths that header needs (4 for rb_atomic_t, 8 for
# size_t and VALUE), plus the C11 fence used by libev.
#
# The semantics are pinned by an execution oracle rather than by hand-computed
# expectations: a single-threaded program's atomic operations have completely
# determined results and side effects, so running the same source under gcc and
# under rubycc and demanding identical output fixes both the value each builtin
# yields and the state it leaves the object in.
#
# Atomicity itself is not observable that way, so it is checked separately by
# reading the emitted instructions back: an x86-64 read-modify-write must carry
# a `lock` prefix (or be an `xchg`, whose lock is implicit) and an aarch64 one
# must be an LDAXR/STLXR retry loop.
class TestAtomicBuiltins < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # Every one of the nine forms at both widths, each in its own statement so the
  # returned value and the object's new state are read at separate sequence
  # points (a printf that did both would compare rubycc's left-to-right argument
  # evaluation against gcc's right-to-left, which C leaves unspecified).
  ALL_FORMS_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    int main(void) {
      unsigned int u = 10;
      size_t s = 100;
      unsigned int r;
      size_t rs;
      int ok;

      printf("%u\\n", __atomic_load_n(&u, __ATOMIC_SEQ_CST));
      __atomic_store_n(&u, 20u, __ATOMIC_SEQ_CST);
      printf("%u\\n", u);
      r = __atomic_exchange_n(&u, 33u, __ATOMIC_SEQ_CST);    printf("%u %u\\n", r, u);
      r = __atomic_fetch_add(&u, 5u, __ATOMIC_SEQ_CST);      printf("%u %u\\n", r, u);
      r = __atomic_fetch_sub(&u, 3u, __ATOMIC_SEQ_CST);      printf("%u %u\\n", r, u);
      r = __atomic_add_fetch(&u, 7u, __ATOMIC_SEQ_CST);      printf("%u %u\\n", r, u);
      r = __atomic_sub_fetch(&u, 2u, __ATOMIC_SEQ_CST);      printf("%u %u\\n", r, u);
      r = __atomic_or_fetch(&u, 0x100u, __ATOMIC_SEQ_CST);   printf("%u %u\\n", r, u);

      unsigned int expected = u;
      ok = __atomic_compare_exchange_n(&u, &expected, 999u, 0,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      printf("%d %u %u\\n", ok, expected, u);

      printf("%zu\\n", __atomic_load_n(&s, __ATOMIC_SEQ_CST));
      __atomic_store_n(&s, 200, __ATOMIC_SEQ_CST);
      printf("%zu\\n", s);
      rs = __atomic_exchange_n(&s, 77, __ATOMIC_SEQ_CST);    printf("%zu %zu\\n", rs, s);
      rs = __atomic_fetch_add(&s, 5, __ATOMIC_SEQ_CST);      printf("%zu %zu\\n", rs, s);
      rs = __atomic_fetch_sub(&s, 2, __ATOMIC_SEQ_CST);      printf("%zu %zu\\n", rs, s);
      rs = __atomic_add_fetch(&s, 9, __ATOMIC_SEQ_CST);      printf("%zu %zu\\n", rs, s);
      rs = __atomic_sub_fetch(&s, 4, __ATOMIC_SEQ_CST);      printf("%zu %zu\\n", rs, s);
      rs = __atomic_or_fetch(&s, 0x10000, __ATOMIC_SEQ_CST); printf("%zu %zu\\n", rs, s);

      size_t sexpected = s;
      ok = __atomic_compare_exchange_n(&s, &sexpected, 42, 0,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      printf("%d %zu %zu\\n", ok, sexpected, s);
      return 0;
    }
  C

  # __atomic_compare_exchange_n's failing path writes the value it actually
  # found back through `expected`. <ruby/atomic.h>'s RUBY_ATOMIC_CAS discards the
  # boolean result and returns *expected, so an implementation that skipped the
  # write-back would report every failed CAS as a success. Both paths are
  # exercised at both widths, and the last case aliases `expected` with the
  # atomic object itself — the shape that shows whether the write-back is guarded
  # by the branch or done unconditionally.
  COMPARE_EXCHANGE_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    int main(void) {
      unsigned int u = 7;
      unsigned int expected = 7;
      int ok = __atomic_compare_exchange_n(&u, &expected, 11u, 0,
                                           __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      printf("win4 %d expected=%u object=%u\\n", ok, expected, u);

      expected = 1234u;
      ok = __atomic_compare_exchange_n(&u, &expected, 99u, 0,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      printf("lose4 %d expected=%u object=%u\\n", ok, expected, u);

      expected = u;
      ok = __atomic_compare_exchange_n(&u, &expected, 55u, 0,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      printf("retry4 %d expected=%u object=%u\\n", ok, expected, u);

      size_t s = 900;
      size_t sexpected = 900;
      ok = __atomic_compare_exchange_n(&s, &sexpected, 1100, 0,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      printf("win8 %d expected=%zu object=%zu\\n", ok, sexpected, s);

      sexpected = 5;
      ok = __atomic_compare_exchange_n(&s, &sexpected, 3, 0,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      printf("lose8 %d expected=%zu object=%zu\\n", ok, sexpected, s);

      /* expected aliases the atomic object: the winning path must not scribble
         the old value back over the one just exchanged in. */
      size_t alias = 1100;
      ok = __atomic_compare_exchange_n(&alias, &alias, 4242, 0,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      printf("alias %d object=%zu\\n", ok, alias);
      return 0;
    }
  C

  # The memory orders are accepted but never inspected: every operation is
  # lowered at seq_cst, which is a sound strengthening of each of them, so a
  # program passing __ATOMIC_RELAXED must behave exactly as the gcc build does.
  # The `weak` flag is ignored for the same reason (strong satisfies weak). The
  # six order macros must also carry gcc's own values, since a caller may
  # compute with them.
  MEMORY_ORDER_SOURCE = <<~C
    #include <stdio.h>
    int main(void) {
      unsigned int u = 4;
      unsigned int r;
      printf("%d %d %d %d %d %d\\n",
             __ATOMIC_RELAXED, __ATOMIC_CONSUME, __ATOMIC_ACQUIRE,
             __ATOMIC_RELEASE, __ATOMIC_ACQ_REL, __ATOMIC_SEQ_CST);
      r = __atomic_load_n(&u, __ATOMIC_RELAXED);            printf("%u\\n", r);
      __atomic_store_n(&u, 6u, __ATOMIC_RELEASE);           printf("%u\\n", u);
      r = __atomic_fetch_add(&u, 1u, __ATOMIC_ACQ_REL);     printf("%u %u\\n", r, u);
      r = __atomic_or_fetch(&u, 8u, __ATOMIC_ACQUIRE);      printf("%u %u\\n", r, u);
      unsigned int expected = u;
      int ok = __atomic_compare_exchange_n(&u, &expected, 21u, 1,
                                           __ATOMIC_ACQ_REL, __ATOMIC_RELAXED);
      printf("%d %u %u\\n", ok, expected, u);
      return 0;
    }
  C

  FENCE_SOURCE = <<~C
    #include <stdio.h>
    #include <stdatomic.h>
    int main(void) {
      int value = 7;
      atomic_thread_fence(memory_order_seq_cst);
      value += 5;
      printf("%d\\n", value);
      return 0;
    }
  C

  # The builtins reach pointer-typed objects too (VALUE * and void * in
  # <ruby/atomic.h>'s exchange/CAS helpers). gcc's atomic add on a pointer object
  # is *unscaled* — it adds plain bytes rather than applying C's pointer
  # arithmetic — so the differential run pins that as well.
  POINTER_OBJECT_SOURCE = <<~C
    #include <stdio.h>
    int cells[8];
    int *p;
    int main(void) {
      p = cells;
      int *previous = __atomic_exchange_n(&p, cells + 3, __ATOMIC_SEQ_CST);
      printf("%ld %ld\\n", (long)(previous - cells), (long)(p - cells));

      int *loaded = __atomic_load_n(&p, __ATOMIC_SEQ_CST);
      printf("%ld\\n", (long)(loaded - cells));

      __atomic_store_n(&p, cells + 1, __ATOMIC_SEQ_CST);
      printf("%ld\\n", (long)(p - cells));

      previous = __atomic_fetch_add(&p, 4, __ATOMIC_SEQ_CST);
      printf("%ld %ld\\n", (long)(previous - cells), (long)((char *)p - (char *)cells));

      int *expected = p;
      int ok = __atomic_compare_exchange_n(&p, &expected, cells + 7, 0,
                                           __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      printf("%d %ld\\n", ok, (long)(p - cells));
      return 0;
    }
  C

  # __has_builtin answers for all nine forms, and the whole expression's type is
  # what gcc gives it: the object's type for a load/exchange/fetch, void for a
  # store (checked by using it as an expression-statement) and _Bool for a
  # compare-exchange.
  HAS_BUILTIN_AND_TYPE_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    #if __has_builtin(__atomic_load_n) && __has_builtin(__atomic_store_n) && \\
        __has_builtin(__atomic_exchange_n) && __has_builtin(__atomic_compare_exchange_n) && \\
        __has_builtin(__atomic_fetch_add) && __has_builtin(__atomic_fetch_sub) && \\
        __has_builtin(__atomic_add_fetch) && __has_builtin(__atomic_sub_fetch) && \\
        __has_builtin(__atomic_or_fetch)
    #define ALL_KNOWN 1
    #else
    #define ALL_KNOWN 0
    #endif
    int main(void) {
      unsigned int u = 1;
      size_t s = 2;
      unsigned int expected = 1;
      printf("%d %zu %zu %zu %zu\\n", ALL_KNOWN,
             sizeof(__atomic_load_n(&u, __ATOMIC_SEQ_CST)),
             sizeof(__atomic_load_n(&s, __ATOMIC_SEQ_CST)),
             sizeof(__atomic_fetch_add(&s, 0, __ATOMIC_SEQ_CST)),
             sizeof(__atomic_compare_exchange_n(&u, &expected, 1u, 0,
                                                __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)));
      printf("%u %zu\\n", u, s);
      return 0;
    }
  C

  # __has_builtin stays honest about the forms rubycc does *not* lower, so a
  # header guarding a fallback behind it takes the fallback instead of calling
  # one that would not compile. This cannot be a gcc-differential check — gcc's
  # answer for these is 1 — so the program reports rubycc's own answer and the
  # test names the expected value.
  UNIMPLEMENTED_HAS_BUILTIN_SOURCE = <<~C
    #include <stdio.h>
    #if __has_builtin(__atomic_test_and_set) || \\
        __has_builtin(__atomic_load) || __has_builtin(__sync_fetch_and_add)
    #define ANY_CLAIMED 1
    #else
    #define ANY_CLAIMED 0
    #endif
    int main(void) {
      printf("%d\\n", ANY_CLAIMED);
      return 0;
    }
  C

  # A volatile-qualified object is what <ruby/atomic.h> actually passes
  # ("volatile rb_atomic_t *ptr"), so the qualifier must not stand in the way of
  # the pointee-type resolution.
  VOLATILE_OBJECT_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    static unsigned int counter;
    static unsigned int bump(volatile unsigned int *ptr, unsigned int by) {
      return __atomic_add_fetch(ptr, by, __ATOMIC_SEQ_CST);
    }
    static size_t swap(volatile size_t *ptr, size_t with) {
      return __atomic_exchange_n(ptr, with, __ATOMIC_SEQ_CST);
    }
    int main(void) {
      volatile size_t slot = 5;
      unsigned int first = bump(&counter, 3);
      unsigned int second = bump(&counter, 4);
      size_t previous = swap(&slot, 9);
      printf("%u %u %u\\n", first, second, counter);
      printf("%zu %zu\\n", previous, (size_t)slot);
      return 0;
    }
  C

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  def test_all_nine_forms_match_gcc
    assert_matches_gcc(ALL_FORMS_SOURCE, "atomic_all_forms")
  end

  def test_compare_exchange_write_back_matches_gcc
    assert_matches_gcc(COMPARE_EXCHANGE_SOURCE, "atomic_cas")
  end

  # The failing path's write-back, asserted against a literal expectation rather
  # than only against gcc, so the one property <ruby/atomic.h> depends on is
  # named in the test rather than inferred from a diff.
  def test_compare_exchange_reports_the_value_it_actually_found
    _status, stdout = run_source(COMPARE_EXCHANGE_SOURCE, :rubycc)
    lines = stdout.lines.map(&:chomp)
    assert_equal "win4 1 expected=7 object=11", lines[0]
    assert_equal "lose4 0 expected=11 object=11", lines[1]
    assert_equal "retry4 1 expected=11 object=55", lines[2]
    assert_equal "win8 1 expected=900 object=1100", lines[3]
    assert_equal "lose8 0 expected=1100 object=1100", lines[4]
    assert_equal "alias 1 object=4242", lines[5]
  end

  def test_memory_orders_are_accepted_and_match_gcc
    assert_matches_gcc(MEMORY_ORDER_SOURCE, "atomic_orders")
  end

  def test_thread_fence_matches_gcc
    assert_matches_gcc(FENCE_SOURCE, "atomic_thread_fence")
  end

  def test_x86_64_emits_mfence
    skip "objdump unavailable" unless tool?("objdump")

    listing = in_tmpdir do |dir|
      object_path = File.join(dir, "fence.o")
      compile_with_rubycc(FENCE_SOURCE, object_path)
      stdout, _stderr, status = Open3.capture3("objdump", "-d", object_path)
      raise "objdump failed" unless status.success?

      stdout
    end

    assert_match(/mfence/, listing)
  end

  def test_pointer_objects_match_gcc
    assert_matches_gcc(POINTER_OBJECT_SOURCE, "atomic_pointer")
  end

  def test_has_builtin_and_result_types_match_gcc
    assert_matches_gcc(HAS_BUILTIN_AND_TYPE_SOURCE, "atomic_has_builtin")
  end

  def test_has_builtin_is_false_for_the_forms_rubycc_does_not_lower
    status, stdout = run_source(UNIMPLEMENTED_HAS_BUILTIN_SOURCE, :rubycc)
    assert_equal 0, status
    assert_equal "0\n", stdout,
                 "__has_builtin must not claim an atomic form rubycc cannot lower"
  end

  def test_volatile_qualified_objects_match_gcc
    assert_matches_gcc(VOLATILE_OBJECT_SOURCE, "atomic_volatile")
  end

  # Atomicity is not visible to a single-threaded oracle, so it is asserted on
  # the instruction stream: on x86-64 every read-modify-write must be either
  # `lock`-prefixed or an `xchg` (whose lock is architecturally implicit), and a
  # seq_cst store must be an exchange rather than a plain mov.
  def test_x86_64_emits_locked_instructions
    skip "objdump unavailable" unless tool?("objdump")

    listing = in_tmpdir do |dir|
      object_path = File.join(dir, "atomics.o")
      compile_with_rubycc(ALL_FORMS_SOURCE, object_path)
      stdout, _stderr, status = Open3.capture3("objdump", "-d", object_path)
      raise "objdump failed" unless status.success?

      stdout
    end

    # fetch_add/fetch_sub/add_fetch/sub_fetch at both widths: eight xadds.
    assert_equal 4, listing.scan(/lock xadd\s+%ecx/).size, "expected four 32-bit lock xadd"
    assert_equal 4, listing.scan(/lock xadd\s+%rcx/).size, "expected four 64-bit lock xadd"
    # or_fetch's retry loop and compare_exchange, at both widths.
    assert_equal 2, listing.scan(/lock cmpxchg\s+%edx/).size, "expected two 32-bit lock cmpxchg"
    assert_equal 2, listing.scan(/lock cmpxchg\s+%rdx/).size, "expected two 64-bit lock cmpxchg"
    # exchange_n and store_n at both widths: four exchanges, none of them a mov.
    assert_equal 2, listing.scan(/xchg\s+%ecx,\(%rax\)/).size, "expected two 32-bit xchg"
    assert_equal 2, listing.scan(/xchg\s+%rcx,\(%rax\)/).size, "expected two 64-bit xchg"
    # The or_fetch loop closes with a backward branch to its own cmpxchg.
    assert_match(/lock cmpxchg\s+%edx,\(%rdi\)\n\s+\h+:\s+75 /, listing,
                 "expected the 32-bit or_fetch cmpxchg to be followed by a jne")
  end

  # The aarch64 counterpart: no LSE single-instruction atomic (which would need
  # armv8.1-a) and no outline-atomics call into libgcc, but the armv8-a baseline
  # LDAXR/STLXR retry loop, plus LDAR/STLR for the plain load and store.
  def test_aarch64_emits_exclusive_loops
    skip_unless_aarch64_toolchain

    listing = in_tmpdir do |dir|
      object_path = File.join(dir, "atomics.o")
      compile_with_rubycc_aarch64(ALL_FORMS_SOURCE, object_path)
      disassemble_aarch64(object_path)
    end

    assert_operator listing.scan(/\bldaxr\b/).size, :>=, 14,
                    "expected an ldaxr per read-modify-write and compare-exchange"
    assert_equal listing.scan(/\bldaxr\b/).size, listing.scan(/\bstlxr\b/).size,
                 "every ldaxr must be paired with a stlxr"
    assert_equal listing.scan(/\bstlxr\b/).size, listing.scan(/\bcbnz\b/).size,
                 "every stlxr must be followed by a retry branch"
    assert_equal 2, listing.scan(/\bldar\b/).size, "expected one ldar per __atomic_load_n"
    assert_equal 2, listing.scan(/\bstlr\b/).size, "expected one stlr per __atomic_store_n"
    refute_match(/\b(casal|cas|ldadd|ldaddal|swp|swpal)\b/, listing,
                 "the LSE atomics need armv8.1-a and must not be emitted")
    refute_match(/__aarch64_(ldadd|swp|cas)/, listing,
                 "libgcc's outline atomics must not be called")
  end

  def test_aarch64_all_nine_forms_match_gcc
    assert_aarch64_matches_gcc(ALL_FORMS_SOURCE)
  end

  def test_aarch64_compare_exchange_write_back_matches_gcc
    assert_aarch64_matches_gcc(COMPARE_EXCHANGE_SOURCE)
  end

  def test_aarch64_memory_orders_match_gcc
    assert_aarch64_matches_gcc(MEMORY_ORDER_SOURCE)
  end

  def test_aarch64_pointer_objects_match_gcc
    assert_aarch64_matches_gcc(POINTER_OBJECT_SOURCE)
  end

  def test_aarch64_volatile_qualified_objects_match_gcc
    assert_aarch64_matches_gcc(VOLATILE_OBJECT_SOURCE)
  end

  # Only 4- and 8-byte objects have a lowering here. A narrower or wider one is
  # refused rather than compiled to a plainly non-atomic sequence, since the
  # caller has no way to notice that its atomicity was silently dropped.
  def test_narrow_and_wide_objects_are_diagnosed
    {
      "char" => 1,
      "short" => 2,
      "__int128" => 16
    }.each do |spelling, width|
      error = assert_raises(Rubycc::CompileError, "expected '#{spelling}' to be refused") do
        compile("int main(void) { #{spelling} c = 0; return (int)__atomic_load_n(&c, 5); }")
      end
      assert_match(/'__atomic_load_n' supports atomic objects of 4 or 8 bytes only/, error.message)
      assert_match(/has width #{width}/, error.message)
    end
  end

  # A floating or aggregate object has no atomic form here at all, whatever its
  # width, so it is refused before the width check.
  def test_non_integer_objects_are_diagnosed
    ["double d = 0;", "struct pair { int a, b; } d;"].each do |declaration|
      error = assert_raises(Rubycc::CompileError) do
        compile("int main(void) { #{declaration} __atomic_load_n(&d, 5); return 0; }")
      end
      assert_match(/does not support atomic operations on/, error.message)
    end
  end

  def test_non_pointer_first_argument_is_diagnosed
    error = assert_raises(Rubycc::CompileError) do
      compile("int main(void) { int x = 0; return __atomic_load_n(x, 5); }")
    end
    assert_match(/first argument to '__atomic_load_n' is not a pointer/, error.message)
  end

  def test_wrong_argument_count_is_diagnosed
    error = assert_raises(Rubycc::CompileError) do
      compile("int main(void) { int x = 0; return __atomic_load_n(&x); }")
    end
    assert_match(/'__atomic_load_n' expects 2 arguments, have 1/, error.message)
  end

  # The 'expected' pointer must address an object of the atomic object's width:
  # the failing path writes back through it with a raw `size`-byte store, so a
  # mismatched width would truncate the value or overrun the object.
  def test_compare_exchange_expected_width_mismatch_is_diagnosed
    error = assert_raises(Rubycc::CompileError) do
      compile(<<~C)
        int main(void) {
          unsigned int object = 1;
          unsigned long expected = 1;
          return __atomic_compare_exchange_n(&object, &expected, 2u, 0, 5, 5);
        }
      C
    end
    assert_match(/the 'expected' argument to '__atomic_compare_exchange_n' must be a pointer to a 4-byte object/,
                 error.message)
  end

  # The forms deliberately left out (see Front::Parser::ATOMIC_BUILTINS): with no
  # consumer for them, they stay ordinary identifiers, so a program calling one
  # is refused rather than silently mislowered.
  def test_unimplemented_atomic_forms_are_not_recognized
    ["__atomic_test_and_set(&x, 5)",
     "__sync_fetch_and_add(&x, 1)"].each do |call|
      error = assert_raises(Rubycc::CompileError, "expected '#{call}' to be refused") do
        compile("int main(void) { int x = 0; #{call}; return x; }")
      end
      assert_match(/undeclared|unknown function|implicit/i, error.message)
    end
  end

  private

  def compile(source)
    Rubycc::Compiler.new.compile(source, filename: "atomic.c")
  end

  def run_source(source, compiler)
    in_tmpdir do |dir|
      object_path = File.join(dir, "atomic.o")
      compile_source(source, object_path, compiler)
      link_and_run(object_path)
    end
  end

  # Builds `source` with both compilers, runs both and demands identical exit
  # status and output — the same differential shape TestGccBuiltins uses.
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
