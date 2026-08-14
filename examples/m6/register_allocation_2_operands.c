/* register-allocation-2: naming a promoted register as an instruction operand.
 *
 * This sample adds no C feature either. What changed is that a value living in
 * a callee-saved register is now *named where it is* -- as an instruction's
 * r/m operand, as a `lea`'s base or index, and as the register a result is
 * computed into -- instead of being moved into eax first and moved back after.
 *
 * Every mistake this can make is a different number rather than a diagnostic,
 * so a differential run against gcc is what guards it. The shapes below are
 * the ones the new encodings can get wrong:
 *
 *   - a subscript whose base *and* index are both promoted, which puts two
 *     callee-saved registers into one `lea`'s SIB byte. Three of those five
 *     registers are encoded specially there -- an r13 base collides with the
 *     "no base register" form, an r12 base with the "a SIB byte follows" form,
 *     and an r12 index with the "no index" form -- and which value lands in
 *     which register is decided by occurrence counts, so the sample sweeps
 *     several functions with different numbers of live values rather than
 *     trying to name a register from C;
 *   - an accumulator that is its own first operand ("sum += x", "i++"), now
 *     updated in place. A 32-bit update must still clear the register's upper
 *     half the way the old "compute in eax, move back" pair did, so both int
 *     and long accumulators are read back as long here;
 *   - a promoted value as the *second* operand of a non-commutative op
 *     (subtract, shift, divide, remainder, compare), where getting the operand
 *     order wrong is silent;
 *   - a promoted value as a divisor, which shares a register file with the
 *     div/idiv pair's fixed rax/rdx, and as a shift count, which has to reach
 *     cl whatever register it lives in;
 *   - a promoted value being widened (signed and unsigned, from 1, 2 and 4
 *     bytes), read through as a pointer at every width, and tested by a branch;
 *   - the same values crossing a call, since none of this may disturb the
 *     save/restore pair that makes a callee-saved register usable at all.
 *
 * Output is fixed and printed as integers so the comparison against gcc is
 * exact.
 */
#include <stdio.h>

/* Both operands of the subscript are promoted: `data` is a loop-invariant
 * parameter and `i` the induction variable, so the address is one `lea` over
 * two callee-saved registers. Two arrays and two strides keep more than one
 * base live at a time. */
static long two_bases(const int *xs, const long *ys, int n) {
  long sum = 0;
  int i;

  for (i = 0; i < n; i++) sum += (long)xs[i] * 3 + ys[i];
  return sum;
}

/* The two SIB corners, reached by keeping enough loop-invariant scalars live
 * that the base pointer falls to third in the ranking. `i` is a long, so it is
 * the index register itself rather than a widened copy of it, and the pair
 * comes out as "lea 0x0(%r13,%r12,4)": an r13 base needs the zero displacement
 * the encoding's shorter form has spent on "no base register", and an r12
 * index needs the REX.X that tells it apart from "no index". Getting either
 * wrong reads a wrong address, which is a wrong sum rather than a crash. */
static long sib_corners(const int *xs, long n, long m, long k) {
  long acc = 0;
  long i;

  for (i = 0; i < n; i++) {
    acc += m;
    acc += k;
    acc += xs[i];
  }
  return acc;
}

/* Two bases against one promoted index, so a base register is reloaded between
 * subscripts while the index stays put. */
static long two_indexed(const int *p, const int *q, long n) {
  long acc = 0;
  long i;

  for (i = 0; i < n; i++) {
    acc += q[i];
    acc += p[i];
    acc += q[i];
  }
  return acc;
}

/* Five live values, so every promotion register is taken and the subscript's
 * base and index land wherever the ranking puts them. */
static long five_live(const int *xs, const short *hs, const char *cs, int n) {
  long a = 0;
  long b = 1;
  int i;

  for (i = 0; i < n; i++) {
    a += xs[i] - hs[i];
    b = b * 3 + cs[i];
  }
  return a * 100 + b;
}

/* Accumulators that are their own first operand, at both widths. The int one
 * is returned as a long so a stale upper half would show. */
static long accumulate(int n) {
  int narrow = 0;
  long wide = 0;
  int i;

  for (i = 0; i < n; i++) {
    narrow += i * 7 - 3;
    wide += (long)i * 1000003L;
  }
  return (long)narrow + wide;
}

/* An accumulator that appears as the *second* operand of a commutative op, so
 * the operands have to be exchanged before it can be updated in place. */
static long commuted(int n) {
  long acc = 1;
  long mask = 0;
  int i;

  for (i = 0; i < n; i++) {
    acc = i + acc;
    mask = (i & 3) | mask;
  }
  return acc * 10 + mask;
}

/* Non-commutative ops with a promoted value on the right: subtracting from,
 * shifting by, dividing by and comparing against a value that lives in a
 * register. */
static long right_hand(long n, long d) {
  long acc = 0;
  long i;

  for (i = 1; i <= n; i++) {
    acc = acc - i;
    acc = acc + (i << (d & 3));
    acc = acc + (n / i) - (n % i);
    if (i < d) acc = acc * 2;
    if (d > i) acc = acc + 5;
  }
  return acc;
}

/* Unsigned division and remainder by a promoted divisor, and an unsigned
 * shift, none of which share the signed forms' opcodes. */
static unsigned long unsigned_right_hand(unsigned long n, unsigned long d) {
  unsigned long acc = 0;
  unsigned long i;

  for (i = 1; i <= n; i++) {
    acc += n / (i + d);
    acc += n % (i + d);
    acc += (n >> (i & 7));
    if (acc > n) acc -= n;
  }
  return acc;
}

/* Widening a promoted value: signed and unsigned, from each narrower width,
 * read back through pointers of every size. */
static long widths(const signed char *sc, const unsigned char *uc,
                   const short *ss, const unsigned short *us, int n) {
  long acc = 0;
  int i;

  for (i = 0; i < n; i++) {
    signed char a = sc[i];
    unsigned char b = uc[i];
    short c = ss[i];
    unsigned short d = us[i];
    unsigned int e = (unsigned int)(c + d);

    acc += (long)a + (long)b + (long)c + (long)d + (long)e;
  }
  return acc;
}

/* A promoted value used directly as a branch condition, including one that is
 * a pointer. */
static long conditions(const int *xs, int n) {
  const int *p = xs;
  long acc = 0;
  int i;

  for (i = 0; i < n; i++) {
    int v = xs[i];

    if (v) acc += 2;
    if (!v) acc += 3;
    if (p) acc += 1;
  }
  if (!p) acc = -1;
  return acc;
}

static long helper(long v) { return v * 3 + 1; }

/* The same shapes with a call in the middle: the in-place updates and the
 * subscripts must both survive the callee's own use of the same registers. */
static long across(const int *xs, int n) {
  long acc = 0;
  long step = 2;
  int i;

  for (i = 0; i < n; i++) {
    acc += helper(xs[i]) - step;
    step = step + 1;
  }
  return acc * 10 + step;
}

int main(void) {
  int xs[10];
  long ys[10];
  short hs[10];
  unsigned short us[10];
  signed char sc[10];
  unsigned char uc[10];
  int i;

  for (i = 0; i < 10; i++) {
    xs[i] = i * 7 - 13;
    ys[i] = (long)i * 1000 - 250;
    hs[i] = (short)(i * 31 - 100);
    us[i] = (unsigned short)(60000 + i);
    sc[i] = (signed char)(i * 9 - 60);
    uc[i] = (unsigned char)(200 + i);
  }

  printf("two_bases=%ld\n", two_bases(xs, ys, 10));
  printf("sib_corners=%ld\n", sib_corners(xs, 10, 5, -2));
  printf("two_indexed=%ld\n", two_indexed(xs, xs + 1, 9));
  printf("five_live=%ld\n", five_live(xs, hs, (const char *)sc, 10));
  printf("accumulate=%ld\n", accumulate(40));
  printf("commuted=%ld\n", commuted(30));
  printf("right_hand=%ld %ld\n", right_hand(20, 6), right_hand(3, 1));
  printf("unsigned_right_hand=%lu\n", unsigned_right_hand(50UL, 4UL));
  printf("widths=%ld\n", widths(sc, uc, hs, us, 10));
  printf("conditions=%ld\n", conditions(xs, 10));
  printf("across=%ld\n", across(xs, 10));
  return 0;
}
