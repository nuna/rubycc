/* Step 28: GNU extensions. A __attribute__((packed)) struct (no inter-member
   padding) and a __attribute__((aligned(16))) struct (its size rounded up to a
   16-byte multiple) reported through sizeof; __builtin_expect used as a
   branch-prediction hint in an if condition; __builtin_alloca carving a scratch
   buffer on the stack that is written then read back (and survives a call);
   __extension__ silencing a would-be pedantic diagnostic; and the degenerate
   __asm__ volatile("" ::: "memory") compiler barrier. Uses only features
   available through Step 28. */
int printf(const char *format, ...);

struct __attribute__((packed)) Packed {
    char tag;
    int value;
};

struct __attribute__((aligned(16))) Aligned {
    char tag;
};

/* Fills n bytes of `buf` with a rising byte pattern; called on an alloca'd
   block to prove the block survives an intervening function call. */
static void fill(char *buf, int n) {
    for (int i = 0; i < n; i++) {
        buf[i] = (char)(i * 3 + 1);
    }
}

int main(void) {
    printf("Packed %d\n", (int)sizeof(struct Packed));
    printf("Aligned %d\n", (int)sizeof(struct Aligned));

    int level = 5;
    /* The hint carries no weight in rubycc; the branch is taken because the
       tested value is truthy, exactly as in gcc's unoptimized build. */
    int taken = 0;
    if (__builtin_expect(level == 5, 1)) {
        taken = 1;
    }
    printf("taken %d\n", taken);

    /* A 32-byte scratch buffer on the stack: write a pattern, cross a call,
       then read it back and total it. */
    int n = 32;
    char *scratch = (char *)__builtin_alloca((unsigned long)n);
    fill(scratch, n);
    int sum = 0;
    for (int i = 0; i < n; i++) {
        sum += (unsigned char)scratch[i];
    }
    printf("sum %d\n", sum);
    printf("aligned16 %d\n", (int)(((unsigned long)scratch & 15) == 0));

    /* __extension__ on a parenthesized expression: a no-op that only suppresses
       a pedantic warning, so the value is unchanged. */
    int bump = __extension__ (sum - sum + 7);

    /* A compiler barrier: emits no instructions, prints nothing, just anchors
       the surrounding stores. */
    __asm__ volatile("" ::: "memory");

    return bump;
}
