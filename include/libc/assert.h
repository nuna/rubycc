/* rubycc bundled <assert.h>: the assert macro and its __assert_fail hook (ISO C
   7.2). Written clean room against the standard idiom (musl's <assert.h> was the
   shape reference); the __assert_fail prototype matches glibc's so the macro
   links against the host libc when present. Common layer. Deliberately has no
   whole-file include guard: the standard requires assert to be redefined per the
   current NDEBUG on every inclusion.

   Coverage against glibc's <assert.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, both arches, with tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Nothing was added.
   Intentionally left out:
   omitted: assert_perror -- a GNU-only macro that asserts on an errno value
   and prints strerror() for it; it needs glibc's own __assert_perror_fail
   entry point, and no corpus user spells it (plain assert plus strerror says
   the same thing). */

#include <features.h>

#undef assert

#ifdef NDEBUG
# define assert(expr) ((void) 0)
#else

extern void __assert_fail(const char *__assertion, const char *__file,
                          unsigned int __line, const char *__function)
  __attribute__((__noreturn__));

/* The enclosing function's name. C99's __func__ is the portable spelling, but
   rubycc does not provide it, so under rubycc the (informational) function slot
   is passed as a null pointer instead. */
# if defined __RUBYCC__
#  define __ASSERT_FUNCTION ((const char *) 0)
# else
#  define __ASSERT_FUNCTION __func__
# endif

# define assert(expr) \
  ((void) ((expr) ? 0 : \
           (__assert_fail(#expr, __FILE__, __LINE__, __ASSERT_FUNCTION), 0)))

#endif /* NDEBUG */

#ifndef _RUBYCC_ASSERT_H
#define _RUBYCC_ASSERT_H

/* static_assert: the C11 keyword, exposed under its library spelling. */
#if !defined __cplusplus && (!defined __STDC_VERSION__ || __STDC_VERSION__ < 202311L)
# define static_assert _Static_assert
#endif

#endif /* _RUBYCC_ASSERT_H */
