/*
 * Step 177: the overflow-checked arithmetic builtins
 * (__builtin_add_overflow, __builtin_sub_overflow, __builtin_mul_overflow).
 *
 * Each computes "a op b" with infinite precision, stores that result converted
 * to the type the third argument points at -- wrapping or truncating exactly as
 * an assignment to that type would, whether it overflowed or not -- and answers
 * int 1 when the conversion lost the value, 0 when it did not.
 *
 * Two properties set them apart from a hand-rolled check and are what this
 * sample shows:
 *
 *   * The two operands keep their *own* types. No usual arithmetic conversion
 *     runs between them, so "int -1" plus "unsigned 1" is 0 -- the answer in
 *     the integers -- and not UINT_MAX.
 *
 *   * The result is stored even when it overflowed, so a caller that ignores
 *     the answer still sees the wrapped value it would have got anyway.
 *
 * This is the shape C23's <stdckdint.h> gives ckd_add/ckd_sub/ckd_mul, and the
 * shape ruby's allocation paths use to size a buffer ("does count * size fit in
 * a size_t?") before asking for it.
 */

#include <stdio.h>
#include <limits.h>
#include <stddef.h>

/* Sizes a buffer the way an allocator does: count * size must fit in a size_t,
 * and a header of `extra` bytes must still fit after it. Returns 0 when the
 * size is representable, leaving it in *out; 1 when it is not. */
static int array_bytes(size_t count, size_t size, size_t extra, size_t *out)
{
    size_t bytes;

    if (__builtin_mul_overflow(count, size, &bytes)) {
        return 1;
    }
    return __builtin_add_overflow(bytes, extra, out) ? 1 : 0;
}

int main(void)
{
    unsigned char small;
    int wrapped;
    int sum;
    int fits;
    int at_max;
    int high;
    unsigned under;
    int borrowed;
    int a;
    unsigned b;
    unsigned mixed;
    int mixed_over;
    size_t bytes;
    int ok;
    int huge;

    /* An unsigned char cannot hold 300, so the answer is 1 -- and 300 is still
     * stored, truncated to its low 8 bits (300 - 256 == 44). */
    wrapped = __builtin_add_overflow(200, 100, &small);
    printf("add wrapped=%d value=%u\n", wrapped, small);

    /* The same builtin on a computation that fits answers 0. */
    fits = __builtin_add_overflow(2000000, 40, &sum);
    printf("add fits=%d value=%d\n", fits, sum);

    /* Signed overflow, which plain "INT_MAX + 1" would leave undefined, is an
     * ordinary answer here: 1, with the wrapped value stored. */
    at_max = __builtin_add_overflow(INT_MAX, 1, &high);
    printf("add at_max=%d value=%d\n", at_max, high);

    /* Unsigned underflow: 0 - 1 is -1 in the integers, which no unsigned type
     * can represent, so the answer is 1 and UINT_MAX is stored. */
    borrowed = __builtin_sub_overflow(0u, 1u, &under);
    printf("sub borrowed=%d value=%u\n", borrowed, under);

    /* Operands of different types, each keeping its own: -1 + 1 is 0, which an
     * unsigned int holds, so the answer is 0. Converting the int operand to
     * unsigned first (what "a + b" would do) would instead give UINT_MAX and no
     * overflow report at all. */
    a = -1;
    b = 1;
    mixed_over = __builtin_add_overflow(a, b, &mixed);
    printf("mixed over=%d value=%u\n", mixed_over, mixed);

    /* The allocator-shaped use: a modest request is sized exactly, and one
     * whose product needs more than 64 bits is refused before any allocation
     * is attempted. */
    ok = array_bytes(1000, sizeof(long), 16, &bytes);
    printf("array ok=%d bytes=%zu\n", ok, bytes);
    huge = array_bytes((size_t)1 << 40, (size_t)1 << 40, 0, &bytes);
    printf("array huge=%d\n", huge);

    return 0;
}
