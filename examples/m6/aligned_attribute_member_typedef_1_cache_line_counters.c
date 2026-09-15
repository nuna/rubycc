/*
 * Step aligned-attribute-member-typedef-1: __attribute__((aligned(N))) written
 * on a struct member's declarator, on a typedef name and on a variable.
 *
 * `counter_t` puts each counter on its own 64-byte cache line through the
 * typedef, `pair` is 16-byte aligned through its first member's attribute,
 * `narrow_long` shows a typedef lowering a long to a 4-byte boundary, and
 * `frame` combines a member aligned(4) with a packed struct. sizeof, _Alignof
 * and offsetof below all depend on those attributes (gcc 13.3 on x86-64 and
 * aarch64, 2026-09-15). `pair` is also passed by value after three longs:
 * its 16 comes from a member, so on aarch64 it starts on an even register
 * pair (x4/x5), as a named and as a variadic argument.
 */

/*
 * The types come before the headers on purpose: the aarch64 example runner
 * reads glibc's own <stdio.h>, whose <sys/cdefs.h> defines __attribute__(x)
 * to nothing for a compiler without __GNUC__ (rubycc, by DESIGN R7), which
 * would silently drop every attribute below.
 */
typedef unsigned long counter_t __attribute__((aligned(64)));
typedef long narrow_long __attribute__((aligned(4)));

struct counters { counter_t produced; counter_t consumed; };
struct pair { long lo __attribute__((aligned(16))); long hi; };
struct wire { char tag; narrow_long value; char end; };
struct __attribute__((packed)) frame { char tag; long len __attribute__((aligned(4))); char end; };

static struct counters stats;
static char scratch[3] __attribute__((aligned(32)));

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>

static long named(long a, long b, long c, struct pair p, long after) {
    return a + b * 10 + c * 100 + p.lo * 1000 + p.hi * 10000 + after * 100000;
}

/* `count` longs, then a pair and a closing long. */
static void variadic(int count, ...) {
    va_list ap;
    va_start(ap, count);
    long sum = 0;
    for (int i = 0; i < count; i++) sum += va_arg(ap, long);
    struct pair p = va_arg(ap, struct pair);
    long last = va_arg(ap, long);
    va_end(ap);
    printf("variadic %d: %ld | %ld %ld | %ld\n", count, sum, p.lo, p.hi, last);
}

static struct pair swapped(long pad, struct pair p) {
    struct pair r = { p.hi + pad, p.lo };
    return r;
}

static int on_boundary(const void *p, unsigned long boundary) {
    return ((unsigned long)p % boundary) == 0;
}

int main(void) {
    printf("counter_t: size %zu align %zu\n", sizeof(counter_t), _Alignof(counter_t));
    printf("counters: size %zu align %zu consumed at %zu\n", sizeof(struct counters),
           _Alignof(struct counters), offsetof(struct counters, consumed));
    printf("pair: size %zu align %zu\n", sizeof(struct pair), _Alignof(struct pair));
    printf("wire: size %zu align %zu value at %zu end at %zu\n", sizeof(struct wire),
           _Alignof(struct wire), offsetof(struct wire, value), offsetof(struct wire, end));
    printf("frame: size %zu align %zu len at %zu end at %zu\n", sizeof(struct frame),
           _Alignof(struct frame), offsetof(struct frame, len), offsetof(struct frame, end));
    printf("objects on their boundaries: %d %d\n", on_boundary(&stats, 64), on_boundary(scratch, 32));

    stats.produced = 7;
    stats.consumed = 5;
    printf("in flight: %lu\n", stats.produced - stats.consumed);

    struct pair p = { 4, 5 };
    printf("named: %ld\n", named(1, 2, 3, p, 6));
    variadic(3, 1L, 2L, 3L, p, 9L);
    variadic(9, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, p, 10L);
    struct pair r = swapped(100, p);
    printf("swapped: %ld %ld\n", r.lo, r.hi);
    return 0;
}
