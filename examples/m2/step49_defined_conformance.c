/*
 * Step 49: the `defined` operator and #ifdef see the compiler's builtin macros
 * (__STDC__, __FILE__, __LINE__, __STDC_VERSION__), matching gcc. glibc's
 * sys/cdefs.h probes exactly this ("#if defined __GNUC__ && !defined __STDC__"
 * rejects pre-ISO compilers), and version-selection ladders like the one below
 * are everyday header practice. Compiled by rubycc, linked with libc's printf.
 */

int printf(const char *, ...);
int defined_probe(void);

#if !defined(__STDC__)
#error "a conforming compiler must define __STDC__ and admit it to `defined`"
#endif

#ifdef __FILE__
#define WHERE __FILE__
#else
#define WHERE "unknown"
#endif

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
static const char *dialect = "c99-or-later";
#else
static const char *dialect = "c90";
#endif

#ifndef __LINE__
#error "__LINE__ must be visible to #ifndef/#ifdef as well"
#endif

int main(void) {
  int stdc = defined_probe();
  printf("dialect=%s stdc=%d\n", dialect, stdc);
  printf("file_macro_seen=%d\n", WHERE[0] != 'u');
  return stdc + 40; /* 2 + 40 = 42 */
}

/* A second probe spelled as an ordinary function so the value flows through
 * the program, not just the preprocessor. */
int defined_probe(void) {
#if defined(__STDC__) && defined(__FILE__)
  return 2;
#else
  return 1;
#endif
}
