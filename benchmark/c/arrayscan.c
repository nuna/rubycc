/*
 * Memory-bandwidth kernel: strided array copy + reduction.
 *
 * Repeatedly runs a SAXPY-like pass (b[i] += scale * a[i]) over two int32
 * arrays sized to spill out of L2, then reduces the result. The arithmetic
 * per element is trivial, so throughput is gated by the load/store stream and
 * the loop's addressing. gcc -O2 vectorizes this; rubycc emits a scalar loop
 * with memory-resident induction variables, so the gap here measures the cost
 * of both no vectorization and no register allocation.
 *
 * Fixed workload, deterministic output.
 */
#include <stdio.h>
#include <stdlib.h>

#define N (4 * 1000 * 1000)
#define REPS 120

int main(void) {
    int *a = malloc((size_t)N * sizeof(int));
    int *b = malloc((size_t)N * sizeof(int));
    if (!a || !b) return 1;
    for (int i = 0; i < N; i++) {
        a[i] = i * 3 + 1;
        b[i] = 0;
    }
    for (int r = 0; r < REPS; r++) {
        int scale = (r & 7) + 1;
        for (int i = 0; i < N; i++) {
            b[i] += scale * a[i];
        }
    }
    long sum = 0;
    for (int i = 0; i < N; i++) {
        sum += b[i];
    }
    free(a);
    free(b);
    printf("arrayscan sum=%ld\n", sum);
    return 0;
}
