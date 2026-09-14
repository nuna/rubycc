/*
 * Step aapcs64-aligned-attribute-aggregate-1: two structs that are both
 * 16-byte aligned, passed by value after an odd number of integer arguments.
 *
 * `boxed` gets its 16 from an attribute on the struct itself and `wide` from
 * an _Alignas member. AAPCS64 decides the even-register pair and the 16-byte
 * stack slot by a composite's natural alignment, which only the member raises:
 * on aarch64 `boxed` follows three longs in x3/x4 and `wide` in x4/x5
 * (gcc 13.3, 2026-09-14). The program passes both as named and as variadic
 * arguments, before and past the eight argument registers, and returns them,
 * so every path that reads the rule runs.
 */

/*
 * The structs come before the headers on purpose: the aarch64 example runner
 * reads glibc's own <stdio.h>, whose <sys/cdefs.h> defines __attribute__(x)
 * to nothing for a compiler without __GNUC__ (rubycc, by DESIGN R7), which
 * would silently drop the aligned(16) below.
 */
struct boxed { long lo, hi; } __attribute__((aligned(16)));
struct wide { _Alignas(16) long lo; long hi; };

#include <stdarg.h>
#include <stdio.h>

static long named_boxed(long a, long b, long c, struct boxed v, long after) {
    return a + b * 10 + c * 100 + v.lo * 1000 + v.hi * 10000 + after * 100000;
}

static long named_wide(long a, long b, long c, struct wide v, long after) {
    return a + b * 10 + c * 100 + v.lo * 1000 + v.hi * 10000 + after * 100000;
}

/* Nine longs spend x0..x7 and leave the struct at an odd stack offset. */
static long spilled_boxed(long a, long b, long c, long d, long e, long f, long g, long h,
                          long i, struct boxed v, long after) {
    return a + b + c + d + e + f + g + h + i + v.lo * 100 + v.hi * 1000 + after * 10000;
}

static long spilled_wide(long a, long b, long c, long d, long e, long f, long g, long h,
                         long i, struct wide v, long after) {
    return a + b + c + d + e + f + g + h + i + v.lo * 100 + v.hi * 1000 + after * 10000;
}

/* `count` longs, then a boxed, a wide and a closing long. */
static void variadic(int count, ...) {
    va_list ap;
    va_start(ap, count);
    long sum = 0;
    for (int i = 0; i < count; i++) sum += va_arg(ap, long);
    struct boxed b = va_arg(ap, struct boxed);
    struct wide w = va_arg(ap, struct wide);
    long last = va_arg(ap, long);
    va_end(ap);
    printf("variadic %d: %ld | %ld %ld | %ld %ld | %ld\n", count, sum, b.lo, b.hi, w.lo, w.hi, last);
}

static struct boxed swap_boxed(long pad, struct boxed v) {
    struct boxed r = { v.hi + pad, v.lo };
    return r;
}

int main(void) {
    struct boxed b = { 4, 5 };
    struct wide w = { 6, 7 };
    printf("sizeof %zu %zu, alignof %zu %zu\n",
           sizeof(struct boxed), sizeof(struct wide), _Alignof(struct boxed), _Alignof(struct wide));
    printf("named: %ld %ld\n", named_boxed(1, 2, 3, b, 8), named_wide(1, 2, 3, w, 8));
    printf("spilled: %ld %ld\n", spilled_boxed(1, 2, 3, 4, 5, 6, 7, 8, 9, b, 3),
           spilled_wide(1, 2, 3, 4, 5, 6, 7, 8, 9, w, 3));
    variadic(0, b, w, 10L);
    variadic(1, 11L, b, w, 12L);
    variadic(2, 13L, 14L, b, w, 15L);
    variadic(7, 1L, 2L, 3L, 4L, 5L, 6L, 7L, b, w, 16L);
    variadic(8, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, b, w, 17L);
    struct boxed s = swap_boxed(100, b);
    printf("returned: %ld %ld\n", s.lo, s.hi);
    return 0;
}
