/*
 * Step 215: the C11 `_Atomic` type specifier and the <stdatomic.h> layer.
 *
 * C11 spells `_Atomic` two ways and this sample uses both: as a type qualifier
 * written among the other specifiers ("_Atomic int", "int _Atomic") and as the
 * parenthesized atomic-type-specifier ("_Atomic(size_t)"). rubycc compiles
 * `_Atomic T` as plain `T` -- same size, same alignment, same ABI, which is a
 * measurement against gcc rather than a convenience -- and admits it on integer,
 * floating and pointer types of 1, 2, 4 or 8 bytes only. An aggregate, a
 * 16-byte scalar, an array or a function under `_Atomic` is a compile error,
 * because for those the layouts genuinely differ or no single instruction can
 * touch the object, and a silently non-atomic object is worse than a refusal.
 *
 * The operations come from <stdatomic.h>, whose generic macros sit on the
 * __atomic_* builtins, so each one is a real locked machine sequence. Every
 * value below is completely determined in a single-threaded program, which is
 * what lets test_examples.rb check the whole file against gcc's own output.
 *
 * This is the shape google-protobuf's bundled upb reaches a compiler with: it
 * defines UPB_ATOMIC(T) as _Atomic(T) and drives every access through
 * atomic_load_explicit / atomic_store_explicit / atomic_compare_exchange_*.
 */

#include <stdio.h>
#include <stddef.h>
#include <stdatomic.h>

/* The upb spelling, verbatim. */
#define UPB_ATOMIC(T) _Atomic(T)

/* A file-scope atomic object with an ordinary initializer: `_Atomic T` is `T`,
 * so it is initialized exactly as the unqualified type would be. */
static UPB_ATOMIC(size_t) max_block_size = 4096;

/* Atomic members inside a struct, including a pointer one. */
struct arena {
    UPB_ATOMIC(size_t) space_allocated;
    UPB_ATOMIC(struct arena *) next;
    _Atomic int refs;   /* the qualifier spelling, for contrast */
    int plain;
};

static struct arena root;
static struct arena child;

/* A reference count released with a fetch-and-subtract, the shape a refcounted
 * arena uses: the caller that observes the old count reach 1 owns the teardown. */
static int release(struct arena *a)
{
    return (int)atomic_fetch_sub_explicit(&a->refs, 1, memory_order_acq_rel);
}

int main(void)
{
    _Atomic int counter = 0;
    int _Atomic trailing = 5;      /* "_Atomic" after the type: the same type */
    int *_Atomic slot = &root.plain;
    size_t previous;
    int expected;
    int ok;
    int last;

    /* `_Atomic T` has `T`'s layout, so the struct is laid out as if none of the
     * qualifiers were there at all. */
    printf("sizes %zu %zu %zu %zu\n",
           sizeof(_Atomic int), sizeof(_Atomic(size_t)),
           sizeof(struct arena), sizeof(int *_Atomic));
    printf("aligns %zu %zu %zu\n",
           _Alignof(_Atomic int), _Alignof(_Atomic(double)), _Alignof(_Atomic(void *)));
    printf("offsets %zu %zu %zu %zu\n",
           offsetof(struct arena, space_allocated), offsetof(struct arena, next),
           offsetof(struct arena, refs), offsetof(struct arena, plain));

    /* atomic_init is C11's run-time initialization: not itself an atomic
     * operation, just the store that establishes the object's first value. */
    atomic_init(&root.space_allocated, 0);
    atomic_init(&root.next, NULL);
    atomic_init(&root.refs, 1);
    root.plain = 7;

    /* Load and store, in both the plain and the _explicit spelling. Every
     * memory order is lowered at sequential consistency, which only ever adds
     * guarantees to the one requested. */
    atomic_store(&counter, 10);
    printf("load %d\n", atomic_load(&counter));
    atomic_store_explicit(&counter, 20, memory_order_release);
    printf("load_explicit %d\n", atomic_load_explicit(&counter, memory_order_acquire));

    /* Read-modify-write: exchange returns the value it replaced, fetch_add and
     * fetch_sub the value they read. */
    printf("exchange %d\n", atomic_exchange(&counter, 30));
    printf("fetch_add %d\n", atomic_fetch_add(&counter, 4));
    printf("fetch_sub %d\n", atomic_fetch_sub(&counter, 1));
    printf("counter %d\n", atomic_load(&counter));

    /* Compare-and-exchange, both outcomes. The failing path writes the value it
     * actually found back through `expected`, which is what lets a caller retry
     * without re-reading the object. */
    expected = atomic_load(&counter);
    ok = atomic_compare_exchange_strong(&counter, &expected, 100);
    printf("cas won %d expected=%d counter=%d\n", ok, expected, atomic_load(&counter));

    expected = 999;
    ok = atomic_compare_exchange_weak(&counter, &expected, 200);
    printf("cas lost %d expected=%d counter=%d\n", ok, expected, atomic_load(&counter));

    /* The pointer member: a pointer object is one of the admitted widths, so it
     * takes the same operations. */
    atomic_store_explicit(&root.next, &child, memory_order_release);
    printf("next %d\n", atomic_load_explicit(&root.next, memory_order_acquire) == &child);
    printf("swapped %d\n", atomic_exchange_explicit(&root.next, NULL,
                                                    memory_order_acq_rel) == &child);

    /* A size_t object, accumulated the way an arena tracks its own footprint. */
    previous = atomic_fetch_add_explicit(&root.space_allocated, 512, memory_order_relaxed);
    printf("allocated %zu %zu\n", previous,
           atomic_load_explicit(&root.space_allocated, memory_order_relaxed));
    printf("max_block %zu\n", atomic_load_explicit(&max_block_size, memory_order_relaxed));

    /* The refcount release: the last holder sees the old value 1. */
    last = release(&root);
    printf("release %d refs=%d\n", last,
           (int)atomic_load_explicit(&root.refs, memory_order_relaxed));

    /* A fence with no object of its own, and the trailing-qualifier and
     * qualified-pointer declarations read back. */
    atomic_thread_fence(memory_order_seq_cst);
    printf("trailing %d slot %d\n", trailing, *slot);

    return 0;
}
