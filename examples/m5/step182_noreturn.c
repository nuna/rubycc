/*
 * Step 182: the _Noreturn function specifier (ISO C11 6.7.4).
 *
 * _Noreturn is only an optimization hint -- it tells a compiler a function
 * never returns to its caller, so the compiler need not generate the code a
 * return would need. rubycc accepts and drops it: dropping a hint changes no
 * observable behavior.
 *
 * musl's <stdlib.h> spells its noreturn library prototypes with the bare
 * keyword -- "_Noreturn void abort(void);" -- unlike glibc, which uses
 * "__attribute__((__noreturn__))" instead (a different, already-accepted
 * path). Any translation unit built against musl reaches that declaration
 * before anything else, so failing to parse it stopped every musl build cold.
 * This sample plays out the same shape: a bare prototype, the specifier mixed
 * with a storage class in both orders, and the specifier repeated (C11 allows
 * a function specifier to appear more than once in one declaration).
 */

#include <stdio.h>
#include <stdlib.h>

/* A bare prototype, musl's <stdlib.h> shape. */
_Noreturn void die(const char *reason, int code);

/* The specifier interleaves with a storage class in either order. */
static _Noreturn void bail(int code);
_Noreturn static void abandon(int code);

/* Repeating the specifier is explicitly permitted. */
_Noreturn _Noreturn void panic(const char *reason);

static int safe_divide(int value, int divisor)
{
    if (divisor == 0) {
        die("division by zero", 7);
    }
    return value / divisor;
}

int main(void)
{
    int values[] = { 100, 40, 8 };
    int divisors[] = { 5, 4, 0 };
    int total = 0;
    int i;

    /* The third division hits the zero divisor, so safe_divide's call to
     * die() is the one that actually runs: the loop never reaches its last
     * iteration's addition, and "total=" never prints. */
    for (i = 0; i < 3; i++) {
        printf("step %d\n", i);
        total += safe_divide(values[i], divisors[i]);
    }

    printf("total=%d\n", total);

    if (total < 0) {
        bail(2);
    }
    if (total > 10000) {
        abandon(3);
    }
    if (total == 0) {
        panic("unexpected zero total");
    }

    return 0;
}

_Noreturn void die(const char *reason, int code)
{
    fprintf(stderr, "die: %s\n", reason);
    exit(code);
}

static _Noreturn void bail(int code)
{
    fprintf(stderr, "bail: %d\n", code);
    exit(code);
}

_Noreturn static void abandon(int code)
{
    fprintf(stderr, "abandon: %d\n", code);
    exit(code);
}

void panic(const char *reason)
{
    fprintf(stderr, "panic: %s\n", reason);
    exit(9);
}
