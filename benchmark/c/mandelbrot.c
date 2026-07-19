/*
 * Floating-point tight-loop kernel: Mandelbrot escape-time.
 *
 * Sweeps a WIDTH x HEIGHT grid and, for each point, iterates the complex
 * quadratic map until escape (or MAX_ITER), summing the iteration counts.
 * The hot loop is a pair of dependent double-precision multiplies/adds with a
 * data-dependent branch; register pressure on the four live doubles is what
 * separates an allocating backend from rubycc's spill-everything codegen.
 *
 * No libm calls (only + - *), so it links against a bare libc. Fixed
 * workload, deterministic output.
 */
#include <stdio.h>

#define WIDTH 900
#define HEIGHT 900
#define MAX_ITER 1000

int main(void) {
    long total = 0;
    for (int py = 0; py < HEIGHT; py++) {
        double y0 = (double)py / HEIGHT * 2.0 - 1.0;
        for (int px = 0; px < WIDTH; px++) {
            double x0 = (double)px / WIDTH * 3.0 - 2.0;
            double x = 0.0, y = 0.0;
            int iter = 0;
            while (iter < MAX_ITER) {
                double x2 = x * x;
                double y2 = y * y;
                if (x2 + y2 > 4.0) break;
                y = 2.0 * x * y + y0;
                x = x2 - y2 + x0;
                iter++;
            }
            total += iter;
        }
    }
    printf("mandelbrot total=%ld\n", total);
    return 0;
}
