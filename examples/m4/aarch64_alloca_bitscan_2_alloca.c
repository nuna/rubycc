/*
 * Step m4/aarch64-alloca-bitscan-2: __builtin_alloca on the AArch64 backend.
 *
 * Dynamic stack allocation has been available since Step 28, and on x86-64 it
 * is nearly free: every slot is addressed from rbp, so lowering rsp disturbs
 * nothing. AArch64 addresses everything from sp instead -- a deliberate choice,
 * because its load/store immediate reaches 32 KiB upward from a base register
 * but only 256 bytes downward -- and that is exactly the arrangement alloca
 * breaks. The backend therefore anchors the frame of an alloca-using function
 * in x29 and keeps sp free to move.
 *
 * What this sample is for is the consequences of that, which are the parts an
 * implementation gets wrong:
 *
 *   - The storage lasts until the *function* returns, not until the end of the
 *     block that allocated it. alloca in a loop accumulates: each round hands
 *     back a different pointer and every earlier block is still readable at the
 *     end. (This is also why alloca in a loop is a bad idea in real code, and
 *     why it belongs in a test.)
 *   - A call that passes arguments on the stack has to put them where the
 *     callee looks, which AAPCS64 defines as the sp the call was made with --
 *     below the allocated blocks, not in the fixed frame the caller reserved
 *     before any of this. Ten arguments is what it takes: the first eight
 *     travel in registers.
 *   - A variadic function's va_arg walks a register-save area at the top of the
 *     fixed frame, so the walk has to be anchored to the frame rather than to
 *     the sp it no longer tracks.
 *   - The block is 16-byte aligned whatever size is asked for, which is both
 *     what gcc promises the caller and what the ABI requires of sp itself.
 *
 * Every value printed below is fully determined, so test_examples.rb can check
 * the whole file against gcc on x86-64 and test_examples_aarch64.rb against the
 * cross gcc under qemu. Addresses themselves are never printed -- only
 * relations between them (distinct, ordered, aligned), since where a stack
 * lands is not something two compilers have to agree about.
 */

#include <stdio.h>
#include <stdarg.h>

/* Ten parameters: two of them arrive on the stack under AAPCS64's
 * eight-register rule, which is the case that has to reach the callee across a
 * moved sp. */
static long ten(long a, long b, long c, long d, long e,
                long f, long g, long h, long i, long j)
{
    return a + b * 2 + c * 3 + d * 4 + e * 5
         + f * 6 + g * 7 + h * 8 + i * 9 + j * 10;
}

/* Fill a scratch buffer, call across it, and read it back: the block must
 * survive a call that took the stack below it. */
static long scratch_across_call(int n)
{
    unsigned char *p = (unsigned char *)__builtin_alloca((size_t)n);
    long total = 0;
    int k;

    for (k = 0; k < n; k++) {
        p[k] = (unsigned char)(k * 3 + 1);
    }

    total = ten(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9]);

    for (k = 0; k < n; k++) {
        total += p[k];
    }
    return total;
}

/* alloca inside a loop. The blocks accumulate, so `kept` holds n distinct live
 * pointers at the end; the outgoing argument area of the call inside the loop
 * must not accumulate, or the stack walks down one area per round. */
static long blocks_in_a_loop(int rounds, int *all_distinct)
{
    long *kept[8];
    long total = 0;
    int k, j;

    *all_distinct = 1;
    for (k = 0; k < rounds; k++) {
        long *block = (long *)__builtin_alloca(6 * sizeof(long));
        block[0] = k;
        block[5] = (long)k * 100;
        kept[k] = block;
        total += ten(1, 1, 1, 1, 1, 1, 1, 1, 1, (long)k);
    }

    for (k = 0; k < rounds; k++) {
        total += kept[k][0] + kept[k][5];
        for (j = 0; j < k; j++) {
            if (kept[k] == kept[j]) {
                *all_distinct = 0;
            }
        }
    }
    return total;
}

/* alloca in a variadic function: the va_arg walk and the moved sp are live at
 * the same time, and the buffer the walk fills is itself alloca'd. Eleven
 * arguments makes the walk cross from the register-save area into the caller's
 * stack. */
static long weighted_sum(int count, ...)
{
    va_list ap;
    long *values = (long *)__builtin_alloca((size_t)count * sizeof(long));
    long total = 0;
    int k;

    va_start(ap, count);
    for (k = 0; k < count; k++) {
        values[k] = va_arg(ap, long);
    }
    va_end(ap);

    for (k = 0; k < count; k++) {
        total += values[k] * (k + 1);
    }
    return total;
}

/* A fixed frame past the reach of the scaled load/store immediate, so the
 * frame's own slots are addressed through a composed address -- which has to be
 * composed from the anchor, not from the sp alloca moved. */
static long large_frame_and_block(int n)
{
    long fixed[9000];
    char *p = (char *)__builtin_alloca((size_t)n);
    long total = 0;
    int k;

    for (k = 0; k < 9000; k++) {
        fixed[k] = k * 3;
    }
    for (k = 0; k < n; k++) {
        p[k] = (char)(k & 7);
    }
    for (k = 0; k < 9000; k += 901) {
        total += fixed[k];
    }
    for (k = 0; k < n; k++) {
        total += p[k];
    }
    return total + fixed[8999];
}

int main(void)
{
    int distinct = 0;
    long looped;

    printf("scratch:  %ld %ld\n", scratch_across_call(20), scratch_across_call(10));

    /* The call and the flag it sets go in separate statements: passing both to
     * one printf would leave the answer to the order the compiler happens to
     * evaluate arguments in, which C leaves unspecified (and which gcc and
     * rubycc genuinely differ about). */
    looped = blocks_in_a_loop(8, &distinct);
    printf("loop:     %ld distinct=%d\n", looped, distinct);

    printf("variadic: %ld %ld\n",
           weighted_sum(3, 10L, 20L, 30L),
           weighted_sum(11, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, 10L, 11L));

    printf("large:    %ld\n", large_frame_and_block(40));

    /* Alignment holds for a size already a multiple of 16 and for one that is
     * not; two blocks in the same function do not overlap. */
    {
        unsigned char *a = (unsigned char *)__builtin_alloca(3);
        unsigned char *b = (unsigned char *)__builtin_alloca(16);
        unsigned char *c = (unsigned char *)__builtin_alloca(17);
        a[0] = 1;
        b[15] = 2;
        c[16] = 3;
        printf("align:    %d %d %d overlap=%d\n",
               (int)(((unsigned long)a) & 15),
               (int)(((unsigned long)b) & 15),
               (int)(((unsigned long)c) & 15),
               (int)(a == b || b == c || a == c));
        printf("bytes:    %d %d %d\n", a[0], b[15], c[16]);
    }

    return 0;
}
