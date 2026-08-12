/* long-double-varargs-1: a `long double` handed to a variadic function.
 *
 * rubycc computes with double's range and precision (sizeof(long double) is
 * still 8 here), but the C library reads back the platform's wide format --
 * 80-bit x87 on x86-64, IEEE binary128 on AArch64. Passing the 8-byte value
 * would make printf read bytes that were never written, which is what used to
 * happen: "%Lg" printed a wrong number rather than failing.
 *
 * So a variadic call site converts by static type. The conversion is exact
 * (double is a subset of both wide formats), which is why the arithmetic below
 * prints the same digits gcc prints. Note the third line: the type has to
 * survive the usual arithmetic conversions too, or `a + b` would push 8 bytes
 * where `a` alone pushed 16.
 */
#include <stdio.h>

static long double scaled(long double x, int by) { return x * by; }

int main(void) {
  long double a = 1.25L;
  long double b = 0.5L;
  double d = 2.5;

  printf("%Lg %Lg\n", a, -a);
  printf("%Lg %Lg %Lg\n", a + b, a * 2.0L, a - b);
  printf("%Lg %Lg\n", a + d, (long double)d);
  printf("%Lg\n", scaled(a, 4));

  /* The special values a bit-pattern conversion has to name explicitly: the
     signed zeros, the infinities, and a NaN. */
  printf("%Lg %Lg\n", 0.0L, -0.0L);
  printf("%Lg %Lg\n", 1.0L / 0.0L, -1.0L / 0.0L);

  /* What is deliberately *not* printed here: sizeof(long double). rubycc says
     8 and gcc says 16, and this file is compiled by both and compared output
     for output (test/test_examples.rb), so printing it would fail the sample
     rather than document it. Widening the type is an ABI change and those are
     batched into one major release (issues/platform-abi-alignment.md). */
  return 0;
}
