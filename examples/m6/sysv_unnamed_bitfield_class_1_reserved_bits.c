/*
 * Step sysv-unnamed-bitfield-class-1: aggregates with unnamed bit-fields —
 * reserved bits a program cannot name — passed by value.
 *
 * An unnamed bit-field declares no member, but it does occupy storage, and
 * both ABIs count it. On x86-64 `sample` therefore travels in an integer
 * register rather than an xmm one (System V merges the float's SSE eightbyte
 * with the bit-field's INTEGER), and `reserved`, which has no member at all,
 * still takes a register of its own. On aarch64 `slot` is not a homogeneous
 * floating aggregate, because the bit-field is integer storage, so it rides
 * x0 instead of d0. A *zero-width* bit-field (`gap`) occupies nothing and
 * changes neither answer: it only forces the next field to a fresh storage
 * unit. All of that is gcc 13.3 behaviour, measured 2026-09-16.
 *
 * The program passes each shape as a named and as a variadic argument, before
 * and past the register files, and returns one, so every path that reads the
 * classification runs.
 */

/*
 * The types come before the headers on purpose: the aarch64 example runner
 * reads glibc's own <stdio.h>, whose <sys/cdefs.h> defines __attribute__(x)
 * to nothing for a compiler without __GNUC__ (rubycc, by DESIGN R7), which
 * would silently drop the aligned(8) below.
 */
struct sample { float value; int : 8; };
struct frame { double when; int : 8; };
struct gap { float first; int : 0; float second; };
struct reserved { int : 8; } __attribute__((aligned(8)));
union slot { double weight; int : 8; };

#include <stdarg.h>
#include <stdio.h>

static double named(struct sample s, double scale, struct frame f, double bias) {
    return s.value * scale + f.when + bias;
}

/* Seven doubles leave xmm7 for `g`; `scale` and the rest then spill. */
static double crowded(double a, double b, double c, double d, double e, double f, double g,
                      struct gap p, double scale, struct sample s, double bias) {
    return a + b + c + d + e + f + g + (p.first + p.second) * scale + s.value * bias;
}

/* Six longs fill the integer registers, so the aggregates behind them spill. */
static double packed(long a, long b, long c, long d, long e, long f,
                     struct reserved r, struct sample s, double tail) {
    (void)r;
    return (double)(a + b + c + d + e + f) + s.value + tail;
}

/* `count` doubles, then a sample, a double, a slot, a long and a reserved. */
static void variadic(int count, ...) {
    va_list ap;
    va_start(ap, count);
    double sum = 0.0;
    for (int i = 0; i < count; i++) sum += va_arg(ap, double);
    struct sample s = va_arg(ap, struct sample);
    double mid = va_arg(ap, double);
    union slot u = va_arg(ap, union slot);
    long tag = va_arg(ap, long);
    struct reserved r = va_arg(ap, struct reserved);
    va_end(ap);
    (void)r;
    printf("variadic %d: %g | %g | %g | %ld\n", count, sum, s.value, u.weight, tag);
}

static struct sample scaled(double factor, struct sample s) {
    struct sample r;
    r.value = s.value * (float)factor;
    return r;
}

static union slot halved(union slot u, double bias) {
    union slot r;
    r.weight = u.weight / 2.0 + bias;
    return r;
}

int main(void) {
    struct sample s;
    struct frame f;
    struct gap p;
    struct reserved r;
    union slot u;
    s.value = 1.5f;
    f.when = 0.25;
    p.first = 2.5f;
    p.second = -0.5f;
    u.weight = 8.5;
    printf("sizeof %zu %zu %zu %zu %zu\n", sizeof(struct sample), sizeof(struct frame),
           sizeof(struct gap), sizeof(struct reserved), sizeof(union slot));
    printf("alignof %zu %zu %zu %zu %zu\n", _Alignof(struct sample), _Alignof(struct frame),
           _Alignof(struct gap), _Alignof(struct reserved), _Alignof(union slot));
    printf("named: %g\n", named(s, 2.0, f, 0.125));
    printf("crowded: %g\n", crowded(1, 2, 3, 4, 5, 6, 7, p, 3.0, s, 0.5));
    printf("packed: %g\n", packed(1, 2, 3, 4, 5, 6, r, s, 0.5));
    variadic(0, s, 10.5, u, 7L, r);
    variadic(3, 1.0, 2.0, 3.0, s, 10.5, u, 8L, r);
    variadic(8, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, s, 10.5, u, 9L, r);
    struct sample doubled = scaled(2.0, s);
    union slot small = halved(u, 0.25);
    printf("returned: %g %g\n", doubled.value, small.weight);
    return 0;
}
