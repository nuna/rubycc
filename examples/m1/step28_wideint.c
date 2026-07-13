/* Step 28 (Phase C4): a minimal __int128 / unsigned __int128 subset, the last
   blocker for parsing <ruby.h>'s config.h. Exercises the reachable surface:
   conversion into and out of a 128-bit integer (with sign/zero fill),
   assignment, 128-bit multiply (the rb_mul_size_overflow shape from memory.h),
   addition/subtraction across the low-word carry/borrow, mixed-type comparison
   (a narrower operand converting up to the 128-bit type), sizeof/_Alignof, and a
   16-byte struct member laid out at offset 16. Uses only features available
   through this step; output is deterministic. */
int printf(const char *format, ...);

/* The exact shape of <ruby.h>'s rb_mul_size_overflow: widen both size_t
   operands to unsigned __int128, multiply, and test the 128-bit product against
   the limit so a product that overflows 64 bits is still caught. */
int mul_ov(unsigned long a, unsigned long b, unsigned long max, unsigned long *c)
{
  unsigned __int128 da, db, c2;
  da = a;
  db = b;
  c2 = da * db;
  if (c2 > max) return 1;
  *c = (unsigned long)c2;
  return 0;
}

void report(unsigned long a, unsigned long b, unsigned long max)
{
  unsigned long c = 0;
  int r = mul_ov(a, b, max, &c);
  printf("ov(%lu,%lu,max=%lu) = %d, low=%lu\n", a, b, max, r, r ? 0 : c);
}

/* A 16-byte struct holding one __int128 (offset 16 after the char, size 32). */
struct boxed {
  char tag;
  __int128 value;
};

int main(void)
{
  /* sizeof / _Alignof of both 128-bit types. */
  printf("sizeof=%lu align=%lu usizeof=%lu\n",
         (unsigned long)sizeof(__int128),
         (unsigned long)_Alignof(unsigned __int128),
         (unsigned long)sizeof(signed __int128));

  /* The multiply-overflow check across representative triples. */
  report(3, 4, 100);                                    /* no overflow  */
  report(3, 4, 10);                                     /* > max        */
  report(0xFFFFFFFFUL, 0xFFFFFFFFUL, 0xFFFFFFFFFFFFFFFFUL); /* high word */
  report(0x100000000UL, 0x100000000UL, 0xFFFFFFFFFFFFFFFFUL); /* > 64 bit */

  /* Addition across the low-word carry, subtraction with a borrow. */
  unsigned __int128 big = (unsigned __int128)0xFFFFFFFFFFFFFFFFUL;
  unsigned __int128 rolled = big + (unsigned __int128)1; /* carries into hi */
  unsigned __int128 back = rolled - (unsigned __int128)1;
  printf("carry_low=%lu back=%lu\n", (unsigned long)rolled, (unsigned long)back);

  /* Signed conversion from a negative long sign-fills the high half. */
  long neg = -7;
  __int128 s = neg;
  printf("signed: <0=%d ==neg=%d back=%ld\n", s < 0, s == (__int128)neg, (long)s);

  /* Mixed comparison: the unsigned long converts up to unsigned __int128. */
  unsigned __int128 prod = (unsigned __int128)0xFFFFFFFFUL * (unsigned __int128)5;
  printf("mixed: gt=%d le=%d\n", prod > (unsigned long)7, prod <= (unsigned long)0xFFFFFFFFFFFFFFFFUL);

  /* The struct member's layout and a round-trip through it. */
  struct boxed b;
  b.tag = 1;
  b.value = 300;
  printf("struct: size=%lu off=%lu value=%d\n",
         (unsigned long)sizeof(struct boxed),
         (unsigned long)((char *)&b.value - (char *)&b),
         (int)b.value);
  return 0;
}
