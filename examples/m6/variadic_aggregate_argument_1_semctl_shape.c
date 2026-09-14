/*
 * Step variadic-aggregate-argument-1: structs and unions passed by value in
 * the variable part of a call, and read back with va_arg(ap, struct T).
 *
 * The call shape is semctl(2)'s, which semian 0.28.4 uses: a union passed
 * by value as the fourth, anonymous argument. The other readers cover the
 * shapes the two calling conventions treat differently: a small union, an
 * integer struct of 9-16 bytes, a struct of two doubles (two SSE eightbytes
 * on x86-64, an HFA on aarch64), a pair of floats, an int/double mix, and
 * a struct larger than 16 bytes (on the stack on x86-64, passed as a pointer
 * to a copy on aarch64). Long runs of int and double arguments before the
 * aggregate push it past the argument registers, so the stack path runs too.
 */
#include <stdarg.h>
#include <stdio.h>

union semun_like {
    int val;
    unsigned short *array;
    long raw;
};

struct pair { long a, b; };
struct vec2 { double x, y; };
struct rgb { float r, g; };
struct tagged { int tag; double value; };
struct big { long w[4]; };

/* semctl's shape: three named ints, then the union in the variable part. */
static long control(int id, int num, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    long result = id * 100 + num * 10 + cmd;
    if (cmd == 16) {
        union semun_like arg = va_arg(ap, union semun_like);
        result += arg.val;
    }
    va_end(ap);
    return result;
}

/* Reads `count` tagged items; each tag says which aggregate follows. */
static double gather(int count, ...) {
    va_list ap;
    va_start(ap, count);
    double total = 0.0;
    for (int i = 0; i < count; i++) {
        int kind = va_arg(ap, int);
        if (kind == 0) {
            struct pair p = va_arg(ap, struct pair);
            total += (double)(p.a - p.b);
        } else if (kind == 1) {
            struct vec2 v = va_arg(ap, struct vec2);
            total += v.x * v.y;
        } else if (kind == 2) {
            struct rgb c = va_arg(ap, struct rgb);
            total += c.r + c.g;
        } else if (kind == 3) {
            struct tagged t = va_arg(ap, struct tagged);
            total += t.tag + t.value;
        } else {
            struct big b = va_arg(ap, struct big);
            total += (double)(b.w[0] + b.w[1] + b.w[2] + b.w[3]);
        }
    }
    va_end(ap);
    return total;
}

/* A long prefix of ints and doubles, then aggregates past the registers. */
static void after_prefix(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long ints = 0;
    double dbls = 0.0;
    for (int i = 0; i < n; i++) ints += va_arg(ap, int);
    for (int i = 0; i < n; i++) dbls += va_arg(ap, double);
    struct vec2 v = va_arg(ap, struct vec2);
    struct pair p = va_arg(ap, struct pair);
    struct big b = va_arg(ap, struct big);
    int last = va_arg(ap, int);
    va_end(ap);
    printf("prefix %d: %ld %g | %g %g | %ld %ld | %ld %ld | %d\n",
           n, ints, dbls, v.x, v.y, p.a, p.b, b.w[0], b.w[3], last);
}

int main(void) {
    union semun_like arg;
    arg.raw = 0;
    arg.val = 5;
    printf("control: %ld\n", control(1, 2, 16, arg));

    struct pair p = { 40, 2 };
    struct vec2 v = { 1.5, 4.0 };
    struct rgb c = { 0.25f, 0.5f };
    struct tagged t = { 7, 0.125 };
    struct big b = { { 1, 2, 3, 4 } };
    printf("gather: %g\n", gather(5, 0, p, 1, v, 2, c, 3, t, 4, b));

    after_prefix(2, 10, 20, 0.5, 1.5, v, p, b, 99);
    after_prefix(8, 1, 2, 3, 4, 5, 6, 7, 8,
                 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, v, p, b, 42);
    return 0;
}
