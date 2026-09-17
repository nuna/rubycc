/*
 * Step glibc-alloca-without-gnuc-1: `alloca` called under its libc name, which
 * is a builtin by that name as well as by __builtin_alloca.
 *
 * Which <alloca.h> a translation unit reads decides what the name means. The
 * bundled header maps it onto __builtin_alloca unconditionally; glibc's own
 * header does so only under __GNUC__, which rubycc does not define (DESIGN R7),
 * and leaves a plain call of a function named `alloca` behind otherwise -- a
 * symbol no libc defines, so the program used to fail to link ("undefined
 * reference to `alloca'"). Both include orders are exercised by this one file:
 * the host runner reads the bundled header, the aarch64 runner reads glibc's
 * own from the cross sysroot.
 *
 * `total` allocates a block whose size is only known at run time, `pair` keeps
 * two live at once, `rows` allocates one per loop iteration (all of them freed
 * together when the function returns, not at the end of the iteration), and
 * `handed_out` passes one to another function. Every block's address is printed
 * modulo 16, the alignment the allocator promises, so a block placed weakly
 * shows a 0 (gcc 13.3 prints 1 everywhere, on x86-64 and aarch64, 2026-09-18).
 */

#include <alloca.h>
#include <stdio.h>

static int aligned16(const void *p) {
    return ((unsigned long)p % 16) == 0;
}

/* A block whose size is a run-time value, filled and read back. */
static long total(int n) {
    unsigned char *bytes = (unsigned char *)alloca((size_t)n);
    long sum = 0;
    int i;

    for (i = 0; i < n; i++) bytes[i] = (unsigned char)(i * 3 + 1);
    for (i = 0; i < n; i++) sum += bytes[i];
    printf("total %d %d\n", aligned16(bytes), n);
    return sum;
}

/* Two blocks live at the same time must not overlap. */
static long pair(int n) {
    long *first = (long *)alloca((size_t)n * sizeof(long));
    long *second = (long *)alloca((size_t)n * sizeof(long));
    long sum = 0;
    int i;

    for (i = 0; i < n; i++) {
        first[i] = i + 1;
        second[i] = -(i + 1);
    }
    for (i = 0; i < n; i++) sum += first[i] + second[i];
    printf("pair %d %d %d\n", aligned16(first), aligned16(second), first != second);
    return sum + first[n - 1] + second[n - 1];
}

/* One block per iteration: the storage lives until the function returns. */
static long rows(int count, int width) {
    char *kept[4];
    long sum = 0;
    int i, j;

    for (i = 0; i < count; i++) {
        char *row = (char *)alloca((size_t)width);

        for (j = 0; j < width; j++) row[j] = (char)(i * width + j);
        kept[i] = row;
    }
    for (i = 0; i < count; i++)
        for (j = 0; j < width; j++) sum += kept[i][j];
    printf("rows %d %d\n", aligned16(kept[0]), kept[0] != kept[count - 1]);
    return sum;
}

static long consume(const long *values, int n) {
    long sum = 0;
    int i;

    for (i = 0; i < n; i++) sum += values[i];
    return sum;
}

/* The block is an ordinary argument, passed to a function that reads it. */
static long handed_out(int n) {
    long *values = (long *)alloca((size_t)n * sizeof(long));
    int i;

    for (i = 0; i < n; i++) values[i] = (long)(i + 1) * 10;
    printf("handed %d\n", aligned16(values));
    return consume(values, n);
}

int main(void) {
    long sum = total(37) + pair(5) + rows(4, 6) + handed_out(8);

    printf("sum %ld\n", sum);
    return 0;
}
