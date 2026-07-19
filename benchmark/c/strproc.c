/*
 * Branch-heavy kernel: byte-string scanning and hashing.
 *
 * Generates text into a buffer from an LCG, then repeatedly scans it counting
 * word boundaries and folding every byte into an FNV-1a hash. The work is a
 * per-byte branch on character class plus a multiply -- control-flow bound
 * with a short dependency chain, the kind of code where gcc's optimizer has
 * less room to pull ahead, so the rubycc/gcc gap is expected to be moderate.
 *
 * Fixed workload, deterministic output.
 */
#include <stdio.h>
#include <stdlib.h>

#define BUFSIZE (2 * 1000 * 1000)
#define REPS 120

static int is_word_byte(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9');
}

int main(void) {
    unsigned char *buf = malloc(BUFSIZE);
    if (!buf) return 1;
    unsigned long seed = 12345;
    for (int i = 0; i < BUFSIZE; i++) {
        seed = seed * 1103515245UL + 12345UL;
        unsigned int v = (seed >> 16) & 0x7f;
        buf[i] = (v < 32) ? ' ' : (unsigned char)v;
    }

    unsigned long words = 0;
    unsigned long hash = 0;
    for (int r = 0; r < REPS; r++) {
        int in_word = 0;
        unsigned long h = 1469598103934665603UL;
        for (int i = 0; i < BUFSIZE; i++) {
            unsigned char c = buf[i];
            if (is_word_byte(c)) {
                if (!in_word) {
                    words++;
                    in_word = 1;
                }
            } else {
                in_word = 0;
            }
            h ^= c;
            h *= 1099511628211UL;
        }
        hash += h;
    }
    free(buf);
    printf("strproc words=%lu hash=%lu\n", words, hash);
    return 0;
}
