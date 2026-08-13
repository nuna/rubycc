/* spill-traffic-cleanup-2: the code shapes the backends' residency rules fire on.
 *
 * This sample adds no C feature -- every construct in it already worked. What
 * changed is how much code each one costs: the backends now keep a value in the
 * register the previous instruction left it in, read a second operand straight
 * out of its slot, and skip the store of a temporary whose only reader is the
 * instruction right behind it.
 *
 * So its job is to be a differential guard over exactly those paths, whose
 * mistakes are the kind an optimization makes rather than the kind a parser
 * does: a value fetched from a register that no longer holds it is a wrong
 * number, not a diagnostic. Each function below is arranged so such a mistake
 * shows up in the printed output:
 *
 *   - a temporary consumed as the *second* operand of a non-commutative op
 *     (subtraction, shift, division, pointer store), which has to be rescued
 *     into the other scratch register rather than named as a memory operand;
 *   - the same in the vector register file, where a double's producer and its
 *     reader must agree on the register file *and* the width;
 *   - values that must survive across a call, which stages its arguments
 *     through the registers a waiting temporary would be sitting in;
 *   - values that must survive a control-flow join, where the registers hold
 *     whatever the branch that got there left in them;
 *   - a whole-object copy through a union, which reads two addresses at once.
 *
 * Output is fixed and printed as integers (and as fractions scaled to integers)
 * so the comparison against gcc is exact.
 */
#include <stdio.h>
#include <string.h>

/* A chain of temporaries, each read exactly once by the instruction behind it,
 * with the last few consumed as second operands where the order matters. */
static long second_operands(long a, long b, long c) {
  long x = (a + b) * (a - b);
  long y = c - (a * b + 7);
  long z = (x + y) >> ((a & 3) + 1);
  long q = (x | y) / (c - 40);
  long r = (x ^ y) % (c - 39);
  return x + y * 3 + z - q + r;
}

/* The same idea over doubles: every intermediate is a single-use vector value,
 * and the comparison at the end reads two of them. */
static long floats(double a, double b) {
  double x = a * a;
  double y = b * b;
  double s = x + y;
  double d = x - y;
  double q = s / (d + 0.5);
  float f = (float)(q * 2.0f);
  long flags = 0;

  if (s > 4.0) flags += 1;
  if (d < 0.0) flags += 2;
  if (q >= 1.0) flags += 4;
  if ((double)f == q * 2.0) flags += 8;
  return flags * 1000 + (long)(q * 100.0);
}

static long scale_of(long n) { return n * 3 + 1; }

/* A value produced just before a call has to reach past it: staging the
 * arguments overwrites the registers a temporary would have been waiting in. */
static long across_calls(long n) {
  long a = n * 2 + 1;
  long b = scale_of(a) + scale_of(n);
  return a + b * 2 + scale_of(b - a);
}

/* A control-flow join: whatever a register held before the branch says nothing
 * about what it holds where the two paths meet. */
static long across_joins(long n, long m) {
  long t = n * m;
  long u;

  if (t > 0) {
    u = t - m;
  } else {
    u = t + m;
  }
  while (u > 100) {
    u = u / 2 - 1;
  }
  return u * 10 + t % 7;
}

/* A whole-object copy: both addresses are loaded at once, and the destination
 * must not displace the source. */
typedef union {
  long words[2];
  char bytes[16];
} Cell;

static long copies(long lo, long hi) {
  Cell src;
  Cell dst;
  Cell again;

  src.words[0] = lo;
  src.words[1] = hi;
  dst = src;
  again = dst;
  memset(src.bytes, 0, sizeof src.bytes);
  return again.words[0] * 2 + again.words[1] + dst.words[0] - src.words[1];
}

int main(void) {
  printf("second_operands=%ld %ld\n", second_operands(11, 4, 97), second_operands(-6, 5, -13));
  printf("floats=%ld %ld\n", floats(1.5, 2.25), floats(0.5, 0.125));
  printf("calls=%ld %ld\n", across_calls(7), across_calls(-3));
  printf("joins=%ld %ld\n", across_joins(9, 30), across_joins(-4, 7));
  printf("copies=%ld\n", copies(1234567890123L, -98765432109L));
  return 0;
}
