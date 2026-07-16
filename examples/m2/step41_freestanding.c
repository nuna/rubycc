/*
 * Step 41: rubycc's bundled freestanding headers (<stdarg.h>, <stddef.h>,
 * <stdbool.h>, <stdalign.h>, <iso646.h>). No -I is passed: rubycc finds these
 * on its own default include path, exactly as gcc finds its own — so the
 * toolchain no longer borrows gcc's internal header directory. Compiled by
 * rubycc, linked with libc's printf.
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdalign.h>
#include <iso646.h>

int printf(const char *, ...);

/* <stdarg.h>: sum a variable number of ints, terminated by a sentinel. */
static long sum(int first, ...) {
  va_list ap;
  va_start(ap, first);
  long total = 0;
  for (int v = first; v != -1; v = va_arg(ap, int)) total += v;
  va_end(ap);
  return total;
}

struct box {
  char tag;      /* forces padding before the long */
  long value;
};

int main(void) {
  /* <stdarg.h> */
  long s = sum(10, 20, 12, -1);            /* 42 */

  /* <stddef.h>: offsetof and size_t/NULL */
  size_t off = offsetof(struct box, value);
  void *nothing = NULL;
  bool null_is_null = (nothing == NULL);   /* <stdbool.h> */

  /* <stdalign.h> */
  size_t a = alignof(struct box);

  /* <iso646.h>: spelled-out operators */
  bool both = (s == 42) and null_is_null;
  bool either = (off == 8) or (a == 1);

  printf("sum=%ld off=%zu align=%zu both=%d either=%d\n",
         s, off, a, (int)both, (int)either);

  return (int)s + (both and either ? 0 : 100);  /* 42 */
}
