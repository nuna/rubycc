/* Step sysv-over-aligned-aggregate-stack-1: structs aligned to 32 and 64
 * bytes passed by value after enough longs to spill onto the stack, as
 * fixed arguments, through va_arg and as return values. On x86-64 each one
 * starts on its own 32/64-byte boundary in the stack argument area; on
 * AArch64 they travel by reference. Either way the values arrive intact.
 */
struct wide32 { long a, b, c; } __attribute__((aligned(32)));
struct lead64 { _Alignas(64) long tag; double weight; };

#include <stdarg.h>
#include <stdio.h>

static struct wide32 make_wide(long s) {
  struct wide32 w = { s, s * 2, s * 3 };
  return w;
}

static long fixed(long p1, long p2, long p3, long p4, long p5, long p6, long p7,
                  struct wide32 w, struct lead64 l, long tail) {
  return p1 + p2 + p3 + p4 + p5 + p6 + p7 + w.a * 10 + w.b * 100 + w.c * 1000 +
         l.tag * 10000 + (long)l.weight + tail;
}

static void variadic(int count, ...) {
  va_list ap;
  va_start(ap, count);
  long sum = 0;
  for (int i = 0; i < count; i++) sum += va_arg(ap, long);
  struct wide32 w = va_arg(ap, struct wide32);
  double d = va_arg(ap, double);
  struct lead64 l = va_arg(ap, struct lead64);
  long tail = va_arg(ap, long);
  va_end(ap);
  printf("variadic %d: sum=%ld w={%ld,%ld,%ld} d=%.2f l={%ld,%.2f} tail=%ld\n",
         count, sum, w.a, w.b, w.c, d, l.tag, l.weight, tail);
}

static struct lead64 bump(struct lead64 l, long by) {
  l.tag += by;
  l.weight *= 2;
  return l;
}

int main(void) {
  struct lead64 l = { 7, 1.25 };
  for (int k = 1; k <= 3; k++) {
    struct wide32 w = make_wide(k);
    printf("fixed %d: %ld\n", k, fixed(1, 2, 3, 4, 5, 6, k, w, l, 9));
  }
  for (int count = 5; count <= 9; count += 2) {
    struct wide32 w = make_wide(count);
    variadic(count, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, w, 0.5 * count, l, 42L);
  }
  struct lead64 r = bump(l, 5);
  printf("returned: {%ld,%.2f}\n", r.tag, r.weight);
  return 0;
}
