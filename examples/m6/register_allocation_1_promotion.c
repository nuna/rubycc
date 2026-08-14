/* register-allocation-1: the value shapes whole-function promotion binds to a
 * callee-saved register.
 *
 * This sample adds no C feature -- every construct in it already worked. What
 * changed is where the values live: the x86-64 backend now picks up to five
 * virtual registers per function and keeps each one in rbx/r12..r15 for the
 * function's whole length instead of in its stack slot, so the reads and writes
 * that used to be memory traffic are register moves.
 *
 * Its job is to be a differential guard over the ways that can go wrong, none
 * of which is a diagnostic -- each one is simply a different number:
 *
 *   - a value that crosses a loop back edge (the induction variable and the
 *     loop-invariant parameters), which is the whole point of binding one for
 *     the function's length rather than a block's;
 *   - a value that must survive a call, which is why the registers chosen are
 *     the callee-saved ones -- and, on the other side of the same rule, why
 *     every ret has to give them back to *our* caller, main being a function
 *     that holds a promoted accumulator across each call it makes;
 *   - a variable whose address is taken, which has to stay in memory: a store
 *     through the pointer must be visible to the next read of the variable, and
 *     a promoted copy would not see it;
 *   - deeply nested loops, where an occurrence's weight decides which values
 *     get the five registers;
 *   - more live values than there are registers, so some keep their slots and
 *     the answer must not depend on which;
 *   - a function with two returns, where both paths have to restore.
 *
 * Output is fixed and printed as integers so the comparison against gcc is
 * exact.
 */
#include <stdio.h>

/* An induction variable and four loop-invariant parameters, all crossing the
 * back edge every iteration. */
static long dot(const int *a, const int *b, int n, int bias) {
  long sum = 0;
  int i;

  for (i = 0; i < n; i++) sum += (long)a[i] * b[i] + bias;
  return sum;
}

static long twice(long v) { return v * 2 + 1; }

/* Values live across a call. The callee is free to use the same registers, so
 * it is the callee-saved property -- and the save/restore pair that backs it --
 * that keeps acc, scale and i intact here. */
static long across_calls(long n) {
  long acc = 0;
  long scale = n + 3;
  long i;

  for (i = 0; i < n; i++) acc += twice(i) * scale;
  return acc + scale * twice(n);
}

/* A variable whose address is taken. Every write through the pointer must be
 * visible to the reads of the variable that follow it, so this one has to keep
 * its slot while acc and i around it do not. */
static long addressed(long n) {
  long acc = 0;
  long window = 1;
  long *slot = &window;
  long i;

  for (i = 0; i < n; i++) {
    *slot = window * 2 + i;
    acc += window;
    if (window > 500) *slot = 1;
  }
  return acc * 10 + window;
}

/* Three nested loops: an occurrence in the innermost one is worth a hundred of
 * one outside every loop, which is what decides who gets a register. */
static long nested(int n) {
  long total = 0;
  int i, j, k;

  for (i = 0; i < n; i++)
    for (j = 0; j < n; j++)
      for (k = 0; k < n; k++) total += (long)(i + 1) * (j + 2) - k;
  return total;
}

/* Seven values wanted at once, five registers to hand: the two that miss out
 * keep their slots, and every one of them still has to be read back correctly.
 */
static long many(long a, long b, long c, long d, long e, long f) {
  long s0 = a, s1 = b, s2 = c, s3 = d, s4 = e, s5 = f, s6 = a + f;
  long i;

  for (i = 0; i < 20; i++) {
    s0 += s1 % 7;
    s1 += s2 % 11;
    s2 += s3 % 13;
    s3 += s4 % 17;
    s4 += s5 % 19;
    s5 += s6 % 23;
    s6 += s0 % 29;
  }
  return s0 + s1 * 2 + s2 * 3 + s3 * 4 + s4 * 5 + s5 * 6 + s6 * 7;
}

/* Two returns, one of them from inside the loop where the promoted values are
 * live: both paths have to restore what the prologue saved. */
static long early(long n, long m) {
  long acc = 0;
  long i;

  for (i = 0; i < n; i++) {
    acc += i * m;
    if (acc > 10000) return acc - i;
  }
  return acc + m;
}

int main(void) {
  int xs[8];
  int ys[8];
  long total = 0;
  int i;

  for (i = 0; i < 8; i++) {
    xs[i] = i * 3 - 5;
    ys[i] = 11 - i * i;
  }

  /* `total` is live across every call below, so main is itself a caller whose
   * promoted register each callee must give back. */
  total += dot(xs, ys, 8, 2);
  printf("dot=%ld\n", dot(xs, ys, 8, 2));
  total += across_calls(25);
  printf("across_calls=%ld %ld\n", across_calls(25), across_calls(0));
  total += addressed(12);
  printf("addressed=%ld %ld\n", addressed(12), addressed(1));
  total += nested(9);
  printf("nested=%ld\n", nested(9));
  total += many(3, 5, 7, 11, 13, 17);
  printf("many=%ld\n", many(3, 5, 7, 11, 13, 17));
  total += early(200, 3);
  printf("early=%ld %ld\n", early(200, 3), early(4, 3));
  printf("total=%ld\n", total);
  return 0;
}
