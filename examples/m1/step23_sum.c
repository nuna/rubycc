// Step 23: variadic functions. Defines variadic functions with
// __builtin_va_list and the __builtin_va_start / __builtin_va_arg /
// __builtin_va_end trio: an integer sum reading its count of ints (crossing
// from the argument registers into the stack overflow area), a va_list
// forwarded to a helper that takes a __builtin_va_list parameter, and a
// printf-style logger that forwards its list to the libc vprintf.

int printf(const char *, ...);
int vprintf(const char *, __builtin_va_list);

// Sum `n` int arguments read from the variable part.
int sum(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  int total = 0;
  int i;
  for (i = 0; i < n; i = i + 1) {
    total = total + __builtin_va_arg(ap, int);
  }
  __builtin_va_end(ap);
  return total;
}

// A helper that consumes an already-started va_list handed over by value.
int vsum(int n, __builtin_va_list ap) {
  int total = 0;
  int i;
  for (i = 0; i < n; i = i + 1) {
    total = total + __builtin_va_arg(ap, int);
  }
  return total;
}

// Forward the variable part to vsum without re-reading it here.
int forward_sum(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  int result = vsum(n, ap);
  __builtin_va_end(ap);
  return result;
}

// A printf-style logger that forwards its list to vprintf.
void logline(const char *fmt, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, fmt);
  vprintf(fmt, ap);
  __builtin_va_end(ap);
}

int main(void) {
  // Three fit in registers; eight cross into the stack overflow area.
  printf("sum3 = %d\n", sum(3, 10, 20, 30));
  printf("sum8 = %d\n", sum(8, 1, 2, 3, 4, 5, 6, 7, 8));
  printf("forward = %d\n", forward_sum(4, 100, 200, 300, 400));
  logline("logged %d and %s\n", 42, "done");
  return 0;
}
