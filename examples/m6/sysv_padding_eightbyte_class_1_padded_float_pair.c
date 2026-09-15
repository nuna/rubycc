/*
 * Step sysv-padding-eightbyte-class-1: aggregates whose upper eightbyte is
 * padding only, passed by value with floating arguments around them.
 *
 * `pair` is two floats in 16 bytes and `tag` one int in 16 bytes: in both,
 * the second eightbyte holds no member. System V classes such an eightbyte
 * NO_CLASS and gives it no register, so on x86-64 `pair` rides one xmm
 * register and `tag` one integer register, and the double after either one
 * takes the next xmm register (gcc 13.3, 2026-09-15). The program passes both
 * as named and as variadic arguments, before and past the eight xmm
 * registers, and returns them, so every path that reads the rule runs.
 * aarch64 passes both in integer registers and must print the same.
 */

/*
 * The types come before the headers on purpose: the aarch64 example runner
 * reads glibc's own <stdio.h>, whose <sys/cdefs.h> defines __attribute__(x)
 * to nothing for a compiler without __GNUC__ (rubycc, by DESIGN R7), which
 * would silently drop the aligned(16) below.
 */
struct pair { float x, y; } __attribute__((aligned(16)));
struct tag { int id; } __attribute__((aligned(16)));

#include <stdarg.h>
#include <stdio.h>

static double named(struct pair p, double scale, struct tag t, double bias) {
    return (p.x + p.y) * scale + t.id + bias;
}

/* Seven doubles leave xmm7 for `p`; `scale` and `bias` then spill. */
static double crowded(double a, double b, double c, double d, double e, double f, double g,
                      struct pair p, double scale, struct tag t, double bias) {
    return a + b + c + d + e + f + g + (p.x - p.y) * scale + t.id * bias;
}

/* `count` doubles, then a pair, a double, a tag, a double and a second pair. */
static void variadic(int count, ...) {
    va_list ap;
    va_start(ap, count);
    double sum = 0.0;
    for (int i = 0; i < count; i++) sum += va_arg(ap, double);
    struct pair p = va_arg(ap, struct pair);
    double mid = va_arg(ap, double);
    struct tag t = va_arg(ap, struct tag);
    double after = va_arg(ap, double);
    struct pair q = va_arg(ap, struct pair);
    va_end(ap);
    printf("variadic %d: %g | %g %g | %g | %d | %g | %g %g\n", count, sum, p.x, p.y, mid, t.id, after, q.x, q.y);
}

static struct pair mirror(double shift, struct pair p) {
    struct pair r = { p.y + (float)shift, p.x };
    return r;
}

static struct tag next_tag(struct tag t, double step) {
    struct tag r = { t.id + (int)step };
    return r;
}

int main(void) {
    struct pair p = { 1.5f, 2.25f };
    struct pair q = { -4.0f, 0.5f };
    struct tag t = { 42 };
    printf("sizeof %zu %zu, alignof %zu %zu\n",
           sizeof(struct pair), sizeof(struct tag), _Alignof(struct pair), _Alignof(struct tag));
    printf("named: %g\n", named(p, 2.0, t, 0.125));
    printf("crowded: %g\n", crowded(1, 2, 3, 4, 5, 6, 7, p, 3.0, t, 0.5));
    variadic(0, p, 10.5, t, 20.5, q);
    variadic(3, 1.0, 2.0, 3.0, p, 10.5, t, 20.5, q);
    variadic(6, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, p, 10.5, t, 20.5, q);
    variadic(8, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, p, 10.5, t, 20.5, q);
    struct pair m = mirror(0.5, p);
    struct tag n = next_tag(t, 8.0);
    printf("returned: %g %g %d\n", m.x, m.y, n.id);
    return 0;
}
