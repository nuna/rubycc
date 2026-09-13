/*
 * Step builtin-strlen-1: __builtin_strlen. gcc folds a string-literal
 * argument to a compile-time constant, so the expression is usable wherever
 * a constant-expression is (a static initializer, an array bound, a case
 * label, a _Static_assert — measured against gcc 13.3, 2026-09-13), while a
 * non-literal argument (a char * variable) is an ordinary run-time call that
 * returns the same value as libc's strlen. herb 0.10.4's
 * src/include/lib/hb_string.h:27 wraps the builtin in a macro exactly like
 * HB_STRLEN below.
 */

int printf(const char *, ...);

/* A literal argument inside a macro, herb's own shape. */
#define HB_STRLEN(s) ((unsigned) __builtin_strlen(s))

/* Array bound: a genuine constant-expression, not just "looks constant". */
static char abc_copy[__builtin_strlen("abc") + 1];

/* Static initializer. */
static unsigned long abcd_len = __builtin_strlen("abcd");

/* _Static_assert operand. */
_Static_assert(__builtin_strlen("abc") == 3, "builtin_strlen constant fold");

/* Case label. */
static int classify(int n) {
  switch (n) {
    case __builtin_strlen("ab"):
      return 100;
    case __builtin_strlen("abc"):
      return 300;
    default:
      return -1;
  }
}

int main(void) {
  /* Literal argument: folds to a constant, no code beyond the constant. */
  unsigned long lit_len = __builtin_strlen("rubycc");

  /* Variable argument: an ordinary run-time strlen call. */
  char buf[8] = "abcdef";
  char *p = buf;
  unsigned long var_len = __builtin_strlen(p);

  /* Embedded NUL: strlen stops at the first NUL byte, not the full literal
   * width (the literal's own type is char[6], one past the "\0"). */
  unsigned long embedded_len = __builtin_strlen("ab\0cd");

  printf("lit_len=%lu var_len=%lu embedded_len=%lu\n", lit_len, var_len, embedded_len);
  printf("abc_copy_size=%lu abcd_len=%lu\n", sizeof(abc_copy), abcd_len);
  printf("classify(2)=%d classify(3)=%d classify(9)=%d\n",
         classify(2), classify(3), classify(9));
  printf("hb_strlen=%u\n", HB_STRLEN("herb"));

  return (int) (lit_len + var_len + embedded_len) - 14; /* 6+6+2 - 14 = 0 */
}
