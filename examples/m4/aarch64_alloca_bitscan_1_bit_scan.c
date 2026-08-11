/*
 * Step m4/aarch64-alloca-bitscan-1: the bit-scan builtins on the AArch64
 * backend.
 *
 * __builtin_ctz / __builtin_clz and their "ll" forms count the zero bits below
 * the lowest set bit and above the highest one. The language-level feature has
 * been there since Step 44; what this sample is here for is the second backend,
 * which reaches the same answers from a different instruction set. x86-64 has a
 * bit-*scan* pair (bsf/bsr) that reports an index and turns the leading form
 * into a count by subtracting from the width; AArch64 has a count-leading-zeros
 * instruction that already is the answer, and reaches the trailing form by
 * reversing the bit order first (rbit) so the lowest set bit becomes the
 * highest.
 *
 * Almost every case below is chosen for the *width* of the count rather than
 * for the count itself, because that is the property the two machines are most
 * easily made to disagree about. 0x80000000 has 0 leading zeros as an unsigned
 * int and 32 as an unsigned long; 1 has 31 against 63. A lowering that scanned
 * the wrong register view would compute a self-consistent, plausible and wrong
 * answer for each of those, which is exactly what a gcc differential run
 * catches and an eyeballed expectation does not.
 *
 * The operands travel through an array and a function parameter so each count
 * runs on a value in a register at run time, not on a literal a constant folder
 * could answer for. A zero operand is left out on purpose: it is undefined
 * behaviour for these builtins (gcc documents it so), and the two machines
 * genuinely differ there -- AArch64's clz would answer the register width while
 * x86's bsf leaves its destination untouched.
 */

#include <stdio.h>

static int trailing32(unsigned int x) { return __builtin_ctz(x); }
static int leading32(unsigned int x) { return __builtin_clz(x); }
static int trailing64(unsigned long long x) { return __builtin_ctzll(x); }
static int leading64(unsigned long long x) { return __builtin_clzll(x); }

/* The idiom the builtins exist for: rounding a size up to a power of two, and
 * the base-2 logarithm of one. Both are written the way a real allocator writes
 * them, off the leading-zero count of a run-time value. */
static unsigned long round_up_pow2(unsigned long n)
{
    if (n <= 1) return 1;
    return 1UL << (64 - leading64(n - 1));
}

static int log2_floor(unsigned long n)
{
    return 63 - leading64(n);
}

int main(void)
{
    static const unsigned int narrow[] = {
        1u, 2u, 3u, 0x8000u, 0x80000000u, 0xFFFFFFFFu, 0x00F0F000u
    };
    static const unsigned long long wide[] = {
        1ULL, 0xFF00ULL, 1ULL << 40, 1ULL << 63,
        0xFFFFFFFFFFFFFFFFULL, 0x100000000ULL, 0x00000000FFFFFFFFULL
    };
    unsigned long sizes[] = { 1, 2, 3, 17, 1024, 1025, 1UL << 40 };
    size_t i;

    for (i = 0; i < sizeof(narrow) / sizeof(narrow[0]); i++) {
        printf("u32 %08x ctz=%2d clz=%2d\n",
               narrow[i], trailing32(narrow[i]), leading32(narrow[i]));
    }

    for (i = 0; i < sizeof(wide) / sizeof(wide[0]); i++) {
        printf("u64 %016llx ctz=%2d clz=%2d\n",
               wide[i], trailing64(wide[i]), leading64(wide[i]));
    }

    /* The same value scanned at both widths: the counts differ by exactly 32
     * whenever it fits in an unsigned int, which is the invariant a
     * width-confused lowering breaks. */
    for (i = 0; i < sizeof(narrow) / sizeof(narrow[0]); i++) {
        unsigned int v = narrow[i];
        printf("both %08x %d %d %d\n", v, leading32(v), leading64(v),
               leading64(v) - leading32(v));
    }

    for (i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        printf("size %lu -> pow2 %lu log2 %d\n",
               sizes[i], round_up_pow2(sizes[i]), log2_floor(sizes[i]));
    }

    return leading32(1u) - trailing32(0x8000u);
}
