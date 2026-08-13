/*
 * Memory-bandwidth kernel: strided array copy + reduction.
 *
 * Repeatedly runs a SAXPY-like pass (b[i] += scale * a[i]) over two int32
 * arrays sized to spill out of L2, then reduces the result. The arithmetic
 * per element is trivial, so throughput is gated by the load/store stream and
 * the loop's addressing. rubycc emits a scalar loop with memory-resident
 * induction variables.
 *
 * This comment used to say the gap measured "both no vectorization and no
 * register allocation". Measured on 2026-08-13, that was wrong about the first
 * half: gcc's own -O1 to -O2 step is worth only 1.14x here, while its -O0 to
 * -O1 step is worth 3.30x. Vectorization is not what this kernel is mostly
 * paying for -- keeping induction variables and addresses out of memory is
 * (issues/spill-traffic-cleanup.md).
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
