/*
 * Step 52: run-time conversions between unsigned long and float/double —
 * the missing half of the recorded debt (constant casts folded in Step 51).
 * x86-64 has only signed cvt instructions, so a 64-bit unsigned conversion
 * is a branch: values with the top bit clear convert directly, values with
 * it set go through halve-convert-double (to double) or subtract-2^63 then
 * set the top bit (from double). json's jeaiii-ltoa multiplies a runtime
 * counter into a double threshold and casts back — the shape shown last.
 * Compiled by rubycc, linked with libc's printf.
 */

int printf(const char *, ...);

typedef unsigned long u32_t;   /* uint_fast32_t on LP64, as jeaiii spells it */

static u32_t scaled(u32_t n) {
  /* jeaiii's fixed-point scale: a double expression times a runtime value,
   * truncated back into an unsigned long. */
  return (u32_t)((10 * (1 << 24) / 1e3 + 1) * n);
}

int main(void) {
  /* unsigned long -> double, both sides of the sign-bit branch. */
  unsigned long small = 3;
  unsigned long huge = 0xFFFFFFFFFFFFFFFFul;      /* top bit set */
  unsigned long mid = (1ul << 63) + 4096;
  printf("small=%.1f huge=%.1f mid=%.1f\n",
         (double)small, (double)huge, (double)mid);

  /* double -> unsigned long, again both branches. */
  double d1 = 12345.9;
  double d2 = 9223372036854775808.0;               /* exactly 2^63 */
  double d3 = 1.5e19;                              /* above 2^63   */
  printf("d1=%lu d2=%lu d3=%lu\n",
         (unsigned long)d1, (unsigned long)d2, (unsigned long)d3);

  /* Round trips stay exact for values a double represents exactly. */
  unsigned long rt = (unsigned long)(double)(1ul << 62);
  printf("rt=%lu\n", rt);

  /* The jeaiii shape with runtime operands. */
  printf("scaled(1)=%lu scaled(77)=%lu\n", scaled(1), scaled(77));

  return (int)(scaled(2) % 251);
}
