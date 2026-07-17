/*
 * Step 49: floating constants cast to integer types fold at compile time.
 * json's jeaiii-ltoa spells its decimal thresholds as "u32(1e2)" .. "u64(1e15)"
 * — double literals cast to unsigned integers — and uses them in comparisons
 * and even as division/modulo operands, so they must become integer constants.
 * Compiled by rubycc, linked with libc's printf.
 */

int printf(const char *, ...);

typedef unsigned long u32_t;   /* uint_fast32_t on LP64, as jeaiii uses */
typedef unsigned long u64_t;

#define u32(x) ((u32_t)(x))
#define u64(x) ((u64_t)(x))

/* The jeaiii shape: pick the decimal width of n by threshold comparisons. */
static int digits10(u64_t n) {
  if (n < u32(1e2)) return n < 10 ? 1 : 2;
  if (n < u32(1e6)) {
    if (n < u32(1e4)) return n < u32(1e3) ? 3 : 4;
    return n < u32(1e5) ? 5 : 6;
  }
  if (n < u64(1e8)) return n < u64(1e7) ? 7 : 8;
  return 9; /* enough for the demo */
}

int main(void) {
  /* Threshold constants also serve as division/modulo operands. */
  u64_t n = 987654321;
  u64_t hi = n / u64(1e8);
  u64_t lo = n % u64(1e8);

  printf("d(7)=%d d(4200)=%d d(999999)=%d d(10000000)=%d\n",
         digits10(7), digits10(4200), digits10(999999), digits10(10000000));
  printf("hi=%lu lo=%lu\n", hi, lo);

  /* Negative and fractional doubles truncate toward zero. */
  int t1 = (int)-2.9;
  long t2 = (long)3.999;
  printf("t1=%d t2=%ld\n", t1, t2);

  return digits10(4200) + (int)hi + t1 + (int)t2; /* 4 + 9 - 2 + 3 = 14 */
}
