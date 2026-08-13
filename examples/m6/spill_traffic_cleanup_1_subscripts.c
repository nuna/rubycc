/* spill-traffic-cleanup-1: the code shapes the local IR rewrites fire on.
 *
 * This sample adds no C feature -- every construct in it already worked. What
 * changed is how much code each one costs: a subscript's "index * element
 * size" and the add to the base fold into one address-forming instruction, an
 * expression assigned to a variable writes that variable's slot directly
 * instead of going through a temporary, and a result nobody reads (the value of
 * a discarded "i++", the element-size constant the fold left behind) is not
 * materialized at all.
 *
 * So its job is to be a differential guard over exactly those paths. Each
 * function below is a shape the rewrites fire on, arranged so that a mistake
 * shows up as a wrong number rather than as slower-but-correct code:
 *
 *   - subscripts at every element width the scale field can name (1, 2, 4, 8),
 *     including a negative index, which is why the index is sign-extended
 *     before it is scaled;
 *   - a stride that is *not* a power of two, which has to keep its multiply;
 *   - chains of assignments, each an expression forwarded into a variable's
 *     slot, including the "i = i + 1" shape whose producer reads its own
 *     destination;
 *   - statements whose value is discarded, which is what leaves a result unread.
 *
 * Output is fixed and printed as integers so the comparison against gcc is
 * exact.
 */
#include <stdio.h>

/* Subscripts at each element width, with a negative index thrown in so the
 * scaled address really does have to sign-extend before it scales. */
static long widths(void) {
  /* `signed char` rather than plain `char`, whose signedness is the target's
   * choice (signed under the x86-64 psABI, unsigned under AAPCS64) and would
   * make this function's number differ between the two for a reason that has
   * nothing to do with what is being demonstrated. */
  signed char b[8];
  short h[8];
  int w[8];
  long g[8];
  long total = 0;
  int i;

  for (i = 0; i < 8; i++) {
    b[i] = (signed char)(i * 3 - 10);
    h[i] = (short)(i * 1000 - 4000);
    w[i] = i * 100000 - 400000;
    g[i] = (long)i * 1000000000L - 4000000000L;
  }
  for (i = 0; i < 8; i++) {
    total += b[i] + h[i] + w[i] + g[i];
  }
  /* A pointer past the middle, indexed backwards. */
  {
    int *p = w + 6;
    total += p[-6] + p[-1] + p[0] + p[1];
  }
  return total;
}

/* A 12-byte element: the stride is not a power of two, so this subscript keeps
 * the multiply the fold cannot take. */
typedef struct {
  int a;
  int b;
  int c;
} Triple;

static long odd_stride(void) {
  Triple t[6];
  long total = 0;
  int i;

  for (i = 0; i < 6; i++) {
    t[i].a = i;
    t[i].b = i * 10;
    t[i].c = i * 100;
  }
  for (i = 0; i < 6; i++) {
    total += t[i].a + t[i].b + t[i].c;
  }
  return total + t[5].c - t[0].a;
}

/* Assignments, each an expression written straight into a variable's slot, and
 * one ("acc = acc + ...") whose producer reads the variable it writes. */
static long chains(long a, long b, long c) {
  long x = (a + b) * (a - b);
  long y = c - (a * b + 7);
  long z = (x + y) >> ((a & 3) + 1);
  long acc = 0;
  int i;

  for (i = 0; i < 4; i++) {
    acc = acc + x - y * i;
  }
  return x + y * 3 + z + acc;
}

/* Statements whose value is discarded: the post-increment's result and an
 * expression statement's, neither of which has to reach a slot. */
static long discarded(long n) {
  long i = 0;
  long total = 0;

  while (i < n) {
    i++;
    total += i;
    total + 1; /* value discarded on purpose */
  }
  return total;
}

/* The saxpy loop this whole change started from: an accumulating subscripted
 * store whose address is computed twice and read back once. */
static long saxpy(int scale) {
  int a[16];
  int b[16];
  long sum = 0;
  int i;

  for (i = 0; i < 16; i++) {
    a[i] = i * 3 + 1;
    b[i] = -i;
  }
  for (i = 0; i < 16; i++) {
    b[i] += scale * a[i];
  }
  for (i = 0; i < 16; i++) {
    sum += b[i];
  }
  return sum;
}

int main(void) {
  printf("widths=%ld\n", widths());
  printf("odd_stride=%ld\n", odd_stride());
  printf("chains=%ld %ld\n", chains(11, 4, 97), chains(-6, 5, -13));
  printf("discarded=%ld %ld\n", discarded(9), discarded(0));
  printf("saxpy=%ld %ld\n", saxpy(5), saxpy(-2));
  return 0;
}
