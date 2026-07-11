// Step 24: float and double across the call boundary (the System V xmm ABI).
// Phase A lowered floating computation inside a function; Phase B carries
// float/double through parameters, return values and the variadic convention,
// so the helpers now take and return floating types directly and main prints
// them with printf's %f/%g. Together they exercise xmm argument passing, a
// float/double return, the al xmm-count of a variadic call, __builtin_va_arg
// on a double, and .data/.bss floating globals.

int printf(const char *, ...);

// A file-scope double (.data) and float, plus an uninitialized double (.bss),
// fold their initializers to IEEE754 images at load time.
double base = 1.5;
float step = 0.25f;
double accumulated;

// double parameters and a double return: the midpoint, passed straight back as
// a floating value rather than truncated to int as Phase A had to.
double midpoint(double a, double b) {
  return (a + b) / 2.0;
}

// A float parameter and return with an int argument converted at the call.
float scale(float x, int n) {
  return x * (float)n;
}

// A mix of int and double parameters (nine of them) so each register class
// walks its own sequence past the other's arguments: the doubles are summed
// and the ints folded in.
double blend9(int a, double b, int c, double d, int e, double f, int g, double h, int i) {
  return b + d + f + h + (double)(a + c + e + g + i);
}

// A variadic average reading its variable part as doubles through va_arg: the
// SSE side of the register-save area (fp_offset) is walked independently of the
// integer count.
double average(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  double total = 0.0;
  for (int i = 0; i < n; i = i + 1) {
    total = total + __builtin_va_arg(ap, double);
  }
  __builtin_va_end(ap);
  return total / (double)n;
}

int main(void) {
  // A double returned and reused in an expression, then printed with %f.
  printf("midpoint(3,4) = %f\n", midpoint(3.0, 4.0));         // 3.500000

  // A float return, promoted to double for %g.
  printf("scale(1.25, 4) = %g\n", scale(1.25f, 4));           // 5

  // Nine mixed arguments, each class drawn from its own register sequence.
  printf("blend9 = %g\n", blend9(1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5));  // 27

  // A variadic call whose variable part is all doubles (al counts the xmm
  // registers), averaged through va_arg(double).
  printf("average = %g\n", average(4, 2.0, 4.0, 6.0, 8.0));   // 5

  // A floating global driving a running double sum, then printed.
  accumulated = base;
  for (int i = 0; i < 4; i = i + 1) {
    accumulated = accumulated + (double)step;
  }
  printf("accumulated = %g\n", accumulated);                  // 2.5

  // A double and a float argument together in one printf (al = 2).
  printf("%.3f %.3f\n", midpoint(1.0, 2.0), scale(0.5f, 3));  // 1.500 1.500
  return 0;
}
