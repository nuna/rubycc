/*
 * Integer tight-loop kernel: Sieve of Eratosthenes.
 *
 * Counts the primes below LIMIT, repeated REPS times, and prints the running
 * total (which also defeats dead-code elimination). The inner marking loop is
 * a dependency-light integer store loop -- exactly the shape an optimizing
 * backend turns into a handful of registers, so it is expected to be one of
 * rubycc's worst cases against gcc -O2.
 *
 * Fixed workload, deterministic output. Timing is the harness's job.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIMIT 1000000
#define REPS 300

static long count_primes(unsigned char *sieve) {
    memset(sieve, 1, LIMIT);
    sieve[0] = 0;
    sieve[1] = 0;
    long count = 0;
    for (int i = 2; i < LIMIT; i++) {
        if (sieve[i]) {
            count++;
            for (long j = (long)i * i; j < LIMIT; j += i) {
                sieve[j] = 0;
            }
        }
    }
    return count;
}

int main(void) {
    unsigned char *sieve = malloc(LIMIT);
    if (!sieve) return 1;
    long total = 0;
    for (int r = 0; r < REPS; r++) {
        total += count_primes(sieve);
    }
    free(sieve);
    printf("sieve total=%ld\n", total);
    return 0;
}
