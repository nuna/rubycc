# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The gcc __atomic_* builtins <ruby/atomic.h> uses unconditionally (its
# HAVE_GCC_ATOMIC_BUILTINS branch, which CRuby's baked-in config.h always
# selects), so any gem whose sources reach ruby.h can be compiled: nine object
# forms, at the two object widths that header needs (4 for rb_atomic_t, 8 for
# size_t and VALUE), plus the C11 fence used by libev.
#
# The legacy __sync_* family is covered here too. raindrops' extconf.rb probes
# for it directly and aborts the build when the probe does not compile, so its
# absence stopped `gem install unicorn` at the dependency; the ten forms rubycc
# lowers are the ones an existing IR operation already means correctly.
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
        __has_builtin(__atomic_load) || __has_builtin(__sync_fetch_and_or) || \\
        __has_builtin(__sync_fetch_and_and) || __has_builtin(__sync_fetch_and_xor) || \\
        __has_builtin(__sync_fetch_and_nand) || __has_builtin(__sync_and_and_fetch) || \\
        __has_builtin(__sync_xor_and_fetch) || __has_builtin(__sync_nand_and_fetch)
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

  # --- the legacy __sync_* family -----------------------------------------

  # Every one of the ten __sync_* forms rubycc lowers, at both object widths.
  # Each builtin gets a statement of its own and the object is read back in the
  # printf that follows, for the same reason the __atomic_* sources are shaped
  # that way: a printf that both called the builtin and read the object would
  # compare the two compilers' argument evaluation order, which C leaves
  # unspecified (measured: gcc evaluates right to left here, rubycc left to
  # right, so such a line differs even when both lowerings are correct).
  SYNC_ALL_FORMS_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    int main(void) {
      unsigned int u = 10;
      size_t s = 100;
      unsigned int r;
      size_t rs;
      int ok;

      r = __sync_fetch_and_add(&u, 5u);      printf("%u %u\\n", r, u);
      r = __sync_fetch_and_sub(&u, 3u);      printf("%u %u\\n", r, u);
      r = __sync_add_and_fetch(&u, 7u);      printf("%u %u\\n", r, u);
      r = __sync_sub_and_fetch(&u, 2u);      printf("%u %u\\n", r, u);
      r = __sync_or_and_fetch(&u, 0x100u);   printf("%u %u\\n", r, u);
      r = __sync_lock_test_and_set(&u, 33u); printf("%u %u\\n", r, u);
      ok = __sync_bool_compare_and_swap(&u, 33u, 44u); printf("%d %u\\n", ok, u);
      r = __sync_val_compare_and_swap(&u, 44u, 66u);   printf("%u %u\\n", r, u);
      __sync_lock_release(&u);               printf("%u\\n", u);
      __sync_synchronize();

      rs = __sync_fetch_and_add(&s, 5);      printf("%zu %zu\\n", rs, s);
      rs = __sync_fetch_and_sub(&s, 3);      printf("%zu %zu\\n", rs, s);
      rs = __sync_add_and_fetch(&s, 7);      printf("%zu %zu\\n", rs, s);
      rs = __sync_sub_and_fetch(&s, 2);      printf("%zu %zu\\n", rs, s);
      rs = __sync_or_and_fetch(&s, 0x10000); printf("%zu %zu\\n", rs, s);
      rs = __sync_lock_test_and_set(&s, 900); printf("%zu %zu\\n", rs, s);
      ok = __sync_bool_compare_and_swap(&s, 900, 1100); printf("%d %zu\\n", ok, s);
      rs = __sync_val_compare_and_swap(&s, 1100, 1200); printf("%zu %zu\\n", rs, s);
      __sync_lock_release(&s);               printf("%zu\\n", s);
      __sync_synchronize();
      return 0;
    }
  C

  # Both compare-and-swap spellings, on both outcomes, at both widths. The value
  # form has to answer with the value it *actually read* — which is the one it
  # was given when the swap wins and the one that was really there when it loses
  # — so a lowering that reported the guess on the failing path (or the guess's
  # replacement on the winning one) is what these lines catch. The bool form's
  # result must be exactly 0 or 1, as a _Bool's is.
  SYNC_COMPARE_AND_SWAP_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    int main(void) {
      unsigned int u = 7;
      size_t s = 900;
      unsigned int r;
      size_t rs;
      int ok;

      ok = __sync_bool_compare_and_swap(&u, 7u, 11u);
      printf("bwin4 %d object=%u\\n", ok, u);
      ok = __sync_bool_compare_and_swap(&u, 1234u, 99u);
      printf("blose4 %d object=%u\\n", ok, u);

      r = __sync_val_compare_and_swap(&u, 11u, 22u);
      printf("vwin4 %u object=%u\\n", r, u);
      r = __sync_val_compare_and_swap(&u, 11u, 33u);
      printf("vlose4 %u object=%u\\n", r, u);

      ok = __sync_bool_compare_and_swap(&s, 900, 1100);
      printf("bwin8 %d object=%zu\\n", ok, s);
      ok = __sync_bool_compare_and_swap(&s, 5, 3);
      printf("blose8 %d object=%zu\\n", ok, s);

      rs = __sync_val_compare_and_swap(&s, 1100, 1300);
      printf("vwin8 %zu object=%zu\\n", rs, s);
      rs = __sync_val_compare_and_swap(&s, 1100, 1400);
      printf("vlose8 %zu object=%zu\\n", rs, s);

      /* A _Bool object of its own, so the result's 0/1 is read back through a
         one-byte slot rather than through an int conversion. */
      _Bool flag = __sync_bool_compare_and_swap(&s, 1300, 1500);
      printf("flag %d object=%zu\\n", (int)flag, s);
      flag = __sync_bool_compare_and_swap(&s, 1300, 1600);
      printf("flag %d object=%zu\\n", (int)flag, s);
      return 0;
    }
  C

  # Signed objects at both widths, including the wrap a negative operand causes
  # in an unsigned one. The __sync_* forms have no separate signed spelling — the
  # object's own type decides — so this pins that the result is extended the way
  # that type says.
  SYNC_SIGNEDNESS_SOURCE = <<~C
    #include <stdio.h>
    int main(void) {
      int i = -5;
      long l = -1;
      unsigned int u = 5;
      int r;
      long rl;

      r = __sync_add_and_fetch(&i, 3);       printf("%d %d\\n", r, i);
      r = __sync_fetch_and_sub(&i, 10);      printf("%d %d\\n", r, i);
      r = __sync_sub_and_fetch(&i, -100);    printf("%d %d\\n", r, i);
      r = __sync_or_and_fetch(&i, 0xF);      printf("%d %d\\n", r, i);
      rl = __sync_val_compare_and_swap(&l, -1L, 42L);  printf("%ld %ld\\n", rl, l);
      rl = __sync_add_and_fetch(&l, -100L);            printf("%ld %ld\\n", rl, l);
      /* A negative operand on an unsigned object wraps, as the conversion to the
         object's type says it must. */
      u = __sync_add_and_fetch(&u, -7);      printf("%u\\n", u);
      return 0;
    }
  C

  # A pointer-typed object. Whether the operand is scaled by the pointee's size
  # or added as plain bytes is measured for *this* family rather than assumed
  # from the __atomic_* one, since the two are separate builtins with separate
  # documented histories.
  SYNC_POINTER_OBJECT_SOURCE = <<~C
    #include <stdio.h>
    int cells[8];
    int *p;
    int main(void) {
      int *previous;
      int *now;

      p = cells;
      previous = __sync_fetch_and_add(&p, 1);
      printf("%ld %ld\\n", (long)(previous - cells), (long)((char *)p - (char *)cells));

      p = cells;
      now = __sync_add_and_fetch(&p, 4);
      printf("%ld %ld\\n", (long)((char *)now - (char *)cells),
                           (long)((char *)p - (char *)cells));

      p = cells + 2;
      now = __sync_sub_and_fetch(&p, 4);
      printf("%ld %ld\\n", (long)((char *)now - (char *)cells),
                           (long)((char *)p - (char *)cells));

      previous = __sync_lock_test_and_set(&p, cells + 3);
      printf("%ld %ld\\n", (long)(previous - cells), (long)(p - cells));

      int ok = __sync_bool_compare_and_swap(&p, cells + 3, cells + 7);
      printf("%d %ld\\n", ok, (long)(p - cells));

      previous = __sync_val_compare_and_swap(&p, cells + 7, cells + 1);
      printf("%ld %ld\\n", (long)(previous - cells), (long)(p - cells));

      previous = __sync_val_compare_and_swap(&p, cells + 7, cells + 5);
      printf("%ld %ld\\n", (long)(previous - cells), (long)(p - cells));

      __sync_lock_release(&p);
      printf("%d\\n", p == 0);
      return 0;
    }
  C

  # The volatile-qualified spelling a lock or a counter is normally declared
  # with, reached through functions so the object arrives as a parameter.
  SYNC_VOLATILE_OBJECT_SOURCE = <<~C
    #include <stdio.h>
    static volatile unsigned long lock;
    static volatile unsigned int events;
    static int acquire(volatile unsigned long *l) {
      return __sync_lock_test_and_set(l, 1UL) == 0UL;
    }
    static void release(volatile unsigned long *l) {
      __sync_lock_release(l);
    }
    static unsigned int record(volatile unsigned int *c, unsigned int by) {
      return __sync_add_and_fetch(c, by);
    }
    int main(void) {
      int first = acquire(&lock);
      printf("%d %lu\\n", first, lock);
      int second = acquire(&lock);
      printf("%d %lu\\n", second, lock);
      release(&lock);
      printf("%lu\\n", lock);
      printf("%u\\n", record(&events, 3));
      printf("%u\\n", record(&events, 4));
      printf("%u\\n", events);
      return 0;
    }
  C

  # __has_builtin answers for all ten forms, and the whole expression's type is
  # what gcc gives it: the object's own type for the fetch/exchange/val_ forms
  # and a one-byte _Bool for the bool_ one. sizeof does not evaluate its operand,
  # so the objects must come out untouched — which also exercises the type
  # inference path that never emits code.
  SYNC_HAS_BUILTIN_AND_TYPE_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    #if __has_builtin(__sync_fetch_and_add) && __has_builtin(__sync_fetch_and_sub) && \\
        __has_builtin(__sync_add_and_fetch) && __has_builtin(__sync_sub_and_fetch) && \\
        __has_builtin(__sync_or_and_fetch) && __has_builtin(__sync_lock_test_and_set) && \\
        __has_builtin(__sync_lock_release) && __has_builtin(__sync_synchronize) && \\
        __has_builtin(__sync_bool_compare_and_swap) && \\
        __has_builtin(__sync_val_compare_and_swap)
    #define ALL_KNOWN 1
    #else
    #define ALL_KNOWN 0
    #endif
    int main(void) {
      unsigned int u = 1;
      size_t s = 2;
      printf("%d %zu %zu %zu %zu %zu\\n", ALL_KNOWN,
             sizeof(__sync_fetch_and_add(&u, 1u)),
             sizeof(__sync_add_and_fetch(&s, 1)),
             sizeof(__sync_lock_test_and_set(&s, 1)),
             sizeof(__sync_val_compare_and_swap(&s, 1, 2)),
             sizeof(__sync_bool_compare_and_swap(&u, 1u, 2u)));
      printf("%u %zu\\n", u, s);
      return 0;
    }
  C

  # raindrops' extconf.rb probe, verbatim but for the ruby.h include (which the
  # probe only needs to prove the header and the builtins coexist) and a printf
  # so the run has something to compare. Its failure to compile is what aborted
  # `gem install unicorn` at the raindrops dependency.
  RAINDROPS_PROBE_SOURCE = <<~C
    #include <stdio.h>
    int main(int argc, char * const argv[]) {
      unsigned long i = 0;
      (void)argv;
      __sync_lock_test_and_set(&i, 0);
      __sync_lock_test_and_set(&i, 1);
      __sync_bool_compare_and_swap(&i, 0, 1);
      __sync_add_and_fetch(&i, argc);
      __sync_sub_and_fetch(&i, argc);
      printf("%lu\\n", i);
      return 0;
    }
  C

  # The __sync_* spellings rubycc deliberately does not lower, each in a call
  # that would compile under gcc. They must stay ordinary identifiers, so the
  # program is refused instead of silently mislowered.
  UNIMPLEMENTED_SYNC_FORMS = %w[
    __sync_fetch_and_or __sync_fetch_and_and __sync_fetch_and_xor
    __sync_fetch_and_nand __sync_and_and_fetch __sync_xor_and_fetch
    __sync_nand_and_fetch
  ].freeze

  # Each implemented form with an argument count one off its signature. gcc
  # accepts extra trailing arguments here (its documented, ignored list of
  # variables to protect — measured: "__sync_add_and_fetch(&i, 1, 2, 3)" builds
  # and behaves as the two-argument call); rubycc requires the exact arity so a
  # call that drifted from the intended shape is reported.
  SYNC_ARITIES = {
    "__sync_fetch_and_add" => 2,
    "__sync_fetch_and_sub" => 2,
    "__sync_add_and_fetch" => 2,
    "__sync_sub_and_fetch" => 2,
    "__sync_or_and_fetch" => 2,
    "__sync_lock_test_and_set" => 2,
    "__sync_lock_release" => 1,
    "__sync_synchronize" => 0,
    "__sync_bool_compare_and_swap" => 3,
    "__sync_val_compare_and_swap" => 3
  }.freeze

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
    skip_unless_x86_64_host

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
    skip_unless_x86_64_host

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
     "__atomic_load(&x, &x, 5)"].each do |call|
      error = assert_raises(Rubycc::CompileError, "expected '#{call}' to be refused") do
        compile("int main(void) { int x = 0; #{call}; return x; }")
      end
      assert_match(/undeclared|unknown function|implicit/i, error.message)
    end
  end

  # --- the legacy __sync_* family -----------------------------------------

  def test_sync_all_forms_match_gcc
    assert_matches_gcc(SYNC_ALL_FORMS_SOURCE, "sync_all_forms")
  end

  def test_sync_compare_and_swap_matches_gcc
    assert_matches_gcc(SYNC_COMPARE_AND_SWAP_SOURCE, "sync_cas")
  end

  # The value form's answer, asserted against literal expectations as well as
  # against gcc, so the property a caller depends on — that a losing swap reports
  # the value that was really there, not the one it guessed — is named in the
  # test rather than inferred from a diff.
  def test_sync_val_compare_and_swap_reports_the_value_it_actually_found
    _status, stdout = run_source(SYNC_COMPARE_AND_SWAP_SOURCE, :rubycc)
    lines = stdout.lines.map(&:chomp)
    assert_equal "bwin4 1 object=11", lines[0]
    assert_equal "blose4 0 object=11", lines[1]
    assert_equal "vwin4 11 object=22", lines[2]
    assert_equal "vlose4 22 object=22", lines[3]
    assert_equal "bwin8 1 object=1100", lines[4]
    assert_equal "blose8 0 object=1100", lines[5]
    assert_equal "vwin8 1100 object=1300", lines[6]
    assert_equal "vlose8 1300 object=1300", lines[7]
    assert_equal "flag 1 object=1500", lines[8]
    assert_equal "flag 0 object=1500", lines[9]
  end

  def test_sync_signedness_matches_gcc
    assert_matches_gcc(SYNC_SIGNEDNESS_SOURCE, "sync_signedness")
  end

  def test_sync_pointer_objects_match_gcc
    assert_matches_gcc(SYNC_POINTER_OBJECT_SOURCE, "sync_pointer")
  end

  # The unscaled-operand property, named outright rather than only diffed: on an
  # "int *" object, adding 1 advances the pointer by one *byte*. Measured for the
  # __sync_* family in its own right — the __atomic_* family behaving the same
  # way is not on its own evidence about this one.
  def test_sync_pointer_add_is_unscaled
    _status, stdout = run_source(SYNC_POINTER_OBJECT_SOURCE, :rubycc)
    lines = stdout.lines.map(&:chomp)
    assert_equal "0 1", lines[0], "__sync_fetch_and_add(&p, 1) must advance p by one byte"
    assert_equal "4 4", lines[1], "__sync_add_and_fetch(&p, 4) must advance p by four bytes"
    assert_equal "4 4", lines[2], "__sync_sub_and_fetch(&p, 4) must retreat p by four bytes"
  end

  def test_sync_volatile_qualified_objects_match_gcc
    assert_matches_gcc(SYNC_VOLATILE_OBJECT_SOURCE, "sync_volatile")
  end

  def test_sync_has_builtin_and_result_types_match_gcc
    assert_matches_gcc(SYNC_HAS_BUILTIN_AND_TYPE_SOURCE, "sync_has_builtin")
  end

  def test_raindrops_probe_matches_gcc
    assert_matches_gcc(RAINDROPS_PROBE_SOURCE, "raindrops_probe")
  end

  def test_aarch64_sync_all_forms_match_gcc
    assert_aarch64_matches_gcc(SYNC_ALL_FORMS_SOURCE)
  end

  def test_aarch64_sync_compare_and_swap_matches_gcc
    assert_aarch64_matches_gcc(SYNC_COMPARE_AND_SWAP_SOURCE)
  end

  def test_aarch64_sync_signedness_matches_gcc
    assert_aarch64_matches_gcc(SYNC_SIGNEDNESS_SOURCE)
  end

  def test_aarch64_sync_pointer_objects_match_gcc
    assert_aarch64_matches_gcc(SYNC_POINTER_OBJECT_SOURCE)
  end

  def test_aarch64_sync_volatile_qualified_objects_match_gcc
    assert_aarch64_matches_gcc(SYNC_VOLATILE_OBJECT_SOURCE)
  end

  def test_aarch64_raindrops_probe_matches_gcc
    assert_aarch64_matches_gcc(RAINDROPS_PROBE_SOURCE)
  end

  # Atomicity, asserted on the instruction stream as for the __atomic_* family:
  # the __sync_* forms share its IR ops, so on x86-64 every read-modify-write is
  # either `lock`-prefixed or an `xchg`, and __sync_synchronize is an mfence.
  def test_x86_64_sync_emits_locked_instructions
    skip_unless_x86_64_host

    skip "objdump unavailable" unless tool?("objdump")

    listing = in_tmpdir do |dir|
      object_path = File.join(dir, "sync.o")
      compile_with_rubycc(SYNC_ALL_FORMS_SOURCE, object_path)
      stdout, _stderr, status = Open3.capture3("objdump", "-d", object_path)
      raise "objdump failed" unless status.success?

      stdout
    end

    # fetch_and_add/fetch_and_sub/add_and_fetch/sub_and_fetch at both widths.
    assert_equal 4, listing.scan(/lock xadd\s+%ecx/).size, "expected four 32-bit lock xadd"
    assert_equal 4, listing.scan(/lock xadd\s+%rcx/).size, "expected four 64-bit lock xadd"
    # or_and_fetch's retry loop plus the two compare-and-swaps, at both widths.
    assert_equal 3, listing.scan(/lock cmpxchg\s+%edx/).size, "expected three 32-bit lock cmpxchg"
    assert_equal 3, listing.scan(/lock cmpxchg\s+%rdx/).size, "expected three 64-bit lock cmpxchg"
    # lock_test_and_set and lock_release at both widths: four exchanges.
    assert_equal 2, listing.scan(/xchg\s+%ecx,\(%rax\)/).size, "expected two 32-bit xchg"
    assert_equal 2, listing.scan(/xchg\s+%rcx,\(%rax\)/).size, "expected two 64-bit xchg"
    assert_equal 2, listing.scan(/mfence/).size, "expected one mfence per __sync_synchronize"
  end

  def test_aarch64_sync_emits_exclusive_loops
    skip_unless_aarch64_toolchain

    listing = in_tmpdir do |dir|
      object_path = File.join(dir, "sync.o")
      compile_with_rubycc_aarch64(SYNC_ALL_FORMS_SOURCE, object_path)
      disassemble_aarch64(object_path)
    end

    assert_operator listing.scan(/\bldaxr\b/).size, :>=, 16,
                    "expected an ldaxr per read-modify-write and compare-and-swap"
    assert_equal listing.scan(/\bldaxr\b/).size, listing.scan(/\bstlxr\b/).size,
                 "every ldaxr must be paired with a stlxr"
    assert_equal 2, listing.scan(/\bdmb\s+ish\b/).size,
                 "expected one dmb ish per __sync_synchronize"
    refute_match(/\b(casal|cas|ldadd|ldaddal|swp|swpal)\b/, listing,
                 "the LSE atomics need armv8.1-a and must not be emitted")
    refute_match(/__aarch64_(ldadd|swp|cas)/, listing,
                 "libgcc's outline atomics must not be called")
  end

  # The __sync_* spellings with no IR operation behind them (see
  # Front::Parser::SYNC_BUILTINS): they stay ordinary identifiers, so a program
  # calling one is refused rather than silently given the wrong operation.
  def test_unimplemented_sync_forms_are_not_recognized
    UNIMPLEMENTED_SYNC_FORMS.each do |spelling|
      error = assert_raises(Rubycc::CompileError, "expected '#{spelling}' to be refused") do
        compile("int main(void) { int x = 0; #{spelling}(&x, 1); return x; }")
      end
      assert_match(/undeclared|unknown function|implicit/i, error.message)
    end
  end

  # gcc lets a caller append the extra "protected variable" arguments its manual
  # documents and then ignores. rubycc holds every form to its exact arity in
  # both directions, so a miscount is a located diagnostic rather than a silent
  # acceptance.
  def test_sync_wrong_argument_count_is_diagnosed
    SYNC_ARITIES.each do |spelling, arity|
      [arity + 1, arity - 1].reject(&:negative?).each do |count|
        args = Array.new(count) { |index| index.zero? ? "&x" : "1" }.join(", ")
        error = assert_raises(Rubycc::CompileError,
                              "expected '#{spelling}' with #{count} arguments to be refused") do
          compile("int main(void) { unsigned int x = 0; #{spelling}(#{args}); return 0; }")
        end
        assert_match(/'#{spelling}' expects #{arity} arguments, have #{count}/, error.message)
      end
    end
  end

  def test_sync_narrow_and_wide_objects_are_diagnosed
    {
      "char" => 1,
      "short" => 2,
      "__int128" => 16
    }.each do |spelling, width|
      error = assert_raises(Rubycc::CompileError, "expected '#{spelling}' to be refused") do
        compile("int main(void) { #{spelling} c = 0; return (int)__sync_add_and_fetch(&c, 1); }")
      end
      assert_match(/'__sync_add_and_fetch' supports atomic objects of 4 or 8 bytes only/, error.message)
      assert_match(/has width #{width}/, error.message)
    end
  end

  def test_sync_non_integer_objects_are_diagnosed
    ["double d = 0;", "struct pair { int a, b; } d;"].each do |declaration|
      error = assert_raises(Rubycc::CompileError) do
        compile("int main(void) { #{declaration} __sync_lock_release(&d); return 0; }")
      end
      assert_match(/does not support atomic operations on/, error.message)
    end
  end

  def test_sync_non_pointer_first_argument_is_diagnosed
    error = assert_raises(Rubycc::CompileError) do
      compile("int main(void) { int x = 0; return (int)__sync_add_and_fetch(x, 1); }")
    end
    assert_match(/first argument to '__sync_add_and_fetch' is not a pointer/, error.message)
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
