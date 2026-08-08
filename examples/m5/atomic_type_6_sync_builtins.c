/*
 * Step atomic-type-6: gcc's legacy __sync_* atomic builtins.
 *
 * These predate the __atomic_* family and differ from it in the two ways this
 * sample keeps in view. First, each one is a *full barrier* by definition, so
 * none of them takes a memory-order argument -- the signatures are the operands
 * and nothing else. Second, the two compare-and-swap forms take the value they
 * expect directly, by value, where __atomic_compare_exchange_n takes a pointer
 * to it; the "bool_" spelling answers whether the swap happened and the "val_"
 * spelling answers with the value it actually read.
 *
 * rubycc lowers exactly the ten forms an existing IR operation already gives the
 * right meaning to. The bitwise members with no such operation
 * (__sync_fetch_and_or, __sync_fetch_and_and, __sync_fetch_and_xor, the nand
 * pair and __sync_and_and_fetch / __sync_xor_and_fetch) stay unrecognized
 * identifiers on purpose: a program that uses one is refused rather than
 * silently mislowered.
 *
 * Every value below is completely determined in a single-threaded program,
 * which is what lets test_examples.rb check the whole file against gcc's own
 * output. Each builtin therefore gets its own statement, with the object read
 * back in the printf that follows: reading both in one printf would compare the
 * two compilers' argument evaluation order, which C leaves unspecified.
 *
 * This is the shape raindrops reaches a compiler with -- its extconf.rb probes
 * for __sync_lock_test_and_set, __sync_bool_compare_and_swap,
 * __sync_add_and_fetch and __sync_sub_and_fetch and aborts the build outright
 * when they do not compile and link.
 */

#include <stdio.h>
#include <stddef.h>

/* The counter shape raindrops' ext uses: an unsigned int reached only through
 * the atomic builtins, so a reader never sees a half-updated value. */
static unsigned int events;

static unsigned int record(unsigned int by)
{
    return __sync_add_and_fetch(&events, by);
}

static unsigned int forget(unsigned int by)
{
    return __sync_sub_and_fetch(&events, by);
}

/* A spinlock built out of the pair gcc documents together: the acquire side is
 * an exchange that reports what the lock held before, the release side writes
 * zero back. Single-threaded, so the acquire always wins on the first try. */
static unsigned long lock;

static int try_acquire(void)
{
    return __sync_lock_test_and_set(&lock, 1UL) == 0UL;
}

static void release(void)
{
    __sync_lock_release(&lock);
}

int main(void)
{
    unsigned int u = 10;
    size_t s = 100;
    int i = -5;
    long l = -1;
    unsigned int r;
    size_t rs;
    int ok;
    unsigned int *p;
    unsigned int *previous;
    unsigned int cells[8];

    /* The five fetch/modify spellings at 4 bytes. The "fetch_and_" pair answers
     * with the value it read, the "_and_fetch" trio with the value it wrote. */
    r = __sync_fetch_and_add(&u, 5u);      printf("fetch_and_add %u %u\n", r, u);
    r = __sync_fetch_and_sub(&u, 3u);      printf("fetch_and_sub %u %u\n", r, u);
    r = __sync_add_and_fetch(&u, 7u);      printf("add_and_fetch %u %u\n", r, u);
    r = __sync_sub_and_fetch(&u, 2u);      printf("sub_and_fetch %u %u\n", r, u);
    r = __sync_or_and_fetch(&u, 0x100u);   printf("or_and_fetch %u %u\n", r, u);

    /* The exchange, and then both outcomes of each compare-and-swap form. */
    r = __sync_lock_test_and_set(&u, 33u); printf("test_and_set %u %u\n", r, u);
    ok = __sync_bool_compare_and_swap(&u, 33u, 44u);
    printf("bool_cas won %d %u\n", ok, u);
    ok = __sync_bool_compare_and_swap(&u, 33u, 55u);
    printf("bool_cas lost %d %u\n", ok, u);
    r = __sync_val_compare_and_swap(&u, 44u, 66u);
    printf("val_cas won %u %u\n", r, u);
    r = __sync_val_compare_and_swap(&u, 44u, 77u);
    printf("val_cas lost %u %u\n", r, u);
    __sync_lock_release(&u);               printf("release %u\n", u);

    /* The same run at 8 bytes: the width is the object's, not the operand's. */
    rs = __sync_fetch_and_add(&s, 5);      printf("fetch_and_add8 %zu %zu\n", rs, s);
    rs = __sync_add_and_fetch(&s, 9);      printf("add_and_fetch8 %zu %zu\n", rs, s);
    rs = __sync_sub_and_fetch(&s, 4);      printf("sub_and_fetch8 %zu %zu\n", rs, s);
    rs = __sync_or_and_fetch(&s, 0x10000); printf("or_and_fetch8 %zu %zu\n", rs, s);
    rs = __sync_lock_test_and_set(&s, 900); printf("test_and_set8 %zu %zu\n", rs, s);
    rs = __sync_val_compare_and_swap(&s, 900, 1100);
    printf("val_cas8 won %zu %zu\n", rs, s);
    rs = __sync_val_compare_and_swap(&s, 900, 1200);
    printf("val_cas8 lost %zu %zu\n", rs, s);

    /* Signed objects wrap and sign-extend like the ordinary arithmetic would. */
    ok = (int)__sync_add_and_fetch(&i, 3);  printf("signed %d %d\n", ok, i);
    ok = (int)__sync_fetch_and_sub(&i, 10); printf("signed %d %d\n", ok, i);
    printf("signed8 %ld\n", __sync_val_compare_and_swap(&l, -1L, 42L));
    printf("signed8 %ld\n", l);

    /* A pointer object. The operand is *unscaled*: these builtins add plain
     * bytes rather than applying C's pointer arithmetic, so "+ 4" on an
     * "unsigned int *" advances it by four bytes -- one element here, which is
     * a coincidence of sizeof(unsigned int) and not the scaling "p + 4" does. */
    p = cells;
    previous = __sync_fetch_and_add(&p, 4);
    printf("pointer %ld\n", (long)(previous - cells));
    printf("pointer bytes %ld\n", (long)((char *)p - (char *)cells));
    ok = __sync_bool_compare_and_swap(&p, cells + 1, cells + 5);
    printf("pointer cas %d\n", ok);
    printf("pointer bytes %ld\n", (long)((char *)p - (char *)cells));
    previous = __sync_lock_test_and_set(&p, cells);
    printf("pointer swapped %ld\n", (long)(previous - cells));
    __sync_lock_release(&p);
    printf("pointer null %d\n", p == NULL);

    /* The counter and the lock, driven through the functions above. */
    printf("record %u\n", record(3));
    printf("record %u\n", record(4));
    printf("forget %u\n", forget(2));
    printf("events %u\n", events);
    ok = try_acquire();
    printf("acquire %d held %lu\n", ok, lock);
    ok = try_acquire();
    printf("re-acquire %d\n", ok);
    release();
    printf("released %lu\n", lock);

    /* A standalone full barrier: no object, no operands, no value. */
    __sync_synchronize();

    /* The result types, as gcc's are: the object's own type for the fetch,
     * exchange and val_ forms, and a one-byte _Bool for the bool_ form. */
    printf("sizes %zu %zu %zu %zu\n",
           sizeof(__sync_fetch_and_add(&u, 0u)),
           sizeof(__sync_add_and_fetch(&s, 0)),
           sizeof(__sync_val_compare_and_swap(&s, 0, 0)),
           sizeof(__sync_bool_compare_and_swap(&u, 0u, 0u)));
    printf("untouched %u %zu\n", u, s);

    return 0;
}
