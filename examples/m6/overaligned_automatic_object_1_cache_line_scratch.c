/*
 * Step overaligned-automatic-object-1: automatic objects aligned more strictly
 * than the frame provides, which both backends now place by realigning the
 * stack pointer in the prologue.
 *
 * `mix` keeps a 64-byte cache-line scratch buffer, a 32-byte accumulator pair
 * and a 16-byte counter on the stack of one function; `tail` does the same in a
 * function that also takes two of its arguments on the stack; `log_line` in a
 * variadic one, where the realigned frame still has to find the variable
 * arguments; and `block` in a function that also carves an alloca block out of
 * the moving stack pointer. Each object's address is printed modulo the
 * boundary it asked for, so a frame that placed it weakly shows a 0 (gcc 13.3
 * prints 1 everywhere, on x86-64 and aarch64, 2026-09-16).
 */

/*
 * The types come before the headers on purpose: the aarch64 example runner
 * reads glibc's own <stdio.h>, whose <sys/cdefs.h> defines __attribute__(x)
 * to nothing for a compiler without __GNUC__ (rubycc, by DESIGN R7), which
 * would silently drop every attribute below.
 */
typedef long line_t __attribute__((aligned(64)));

struct pair { long lo, hi; } __attribute__((aligned(32)));

#include <stdarg.h>
#include <stdio.h>

static int on_boundary(const void *p, unsigned long boundary) {
    return ((unsigned long)p % boundary) == 0;
}

/* A scalar, an aggregate and an array, each past the frame's own boundary. */
static long mix(long seed) {
    line_t line = seed;
    struct pair acc;
    _Alignas(16) int counter = 3;
    _Alignas(32) char scratch[40];

    acc.lo = seed + 1;
    acc.hi = seed + 2;
    scratch[0] = (char)seed;
    printf("mix %d %d %d %d\n", on_boundary(&line, 64), on_boundary(&acc, 32),
           on_boundary(&counter, 16), on_boundary(scratch, 32));
    return line + acc.lo + acc.hi + counter + scratch[0];
}

/* Two arguments arrive on the stack, above the realigned frame. */
static long tail(long a, long b, long c, long d, long e, long f, long g, long h) {
    _Alignas(64) long window[4];

    window[0] = a + h;
    window[1] = b + g;
    window[2] = c + f;
    window[3] = d + e;
    printf("tail %d\n", on_boundary(window, 64));
    return window[0] + window[1] + window[2] + window[3];
}

/* The variable arguments are found from the entry stack pointer, not from sp. */
static long log_line(int count, ...) {
    _Alignas(32) long seen[4];
    va_list ap;
    int i;

    va_start(ap, count);
    for (i = 0; i < count; i++) seen[i] = va_arg(ap, long);
    va_end(ap);
    printf("log %d\n", on_boundary(seen, 32));
    return seen[0] + seen[1] + seen[2];
}

/* An alloca block moves the stack pointer under an already realigned frame. */
static long block(int bytes) {
    _Alignas(32) long fixed[2];
    char *dynamic = (char *)__builtin_alloca(bytes);
    int i;

    for (i = 0; i < bytes; i++) dynamic[i] = (char)i;
    fixed[0] = dynamic[bytes - 1];
    fixed[1] = bytes;
    printf("block %d %d\n", on_boundary(fixed, 32), on_boundary(dynamic, 16));
    return fixed[0] + fixed[1];
}

int main(void) {
    long total = mix(10) + tail(1, 2, 3, 4, 5, 6, 7, 8) + log_line(3, 100L, 200L, 300L) + block(48);

    printf("total %ld\n", total);
    return 0;
}
