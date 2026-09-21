/* rubycc bundled <strings.h>: the BSD byte-string declarations (POSIX). Derived
   from musl's <strings.h> declaration set; pure prototypes, nothing arch
   specific. Common layer.

   Coverage against glibc's <strings.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, both arches, with tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Nothing was added; glibc's
   remaining three names are the locale-object half.
   omitted: locale_t strcasecmp_l strncasecmp_l -- the locale-object API, which
   the bundled <locale.h> deliberately leaves out (the same line <stdlib.h>
   draws); a consumer of it needs newlocale/uselocale too, so the family is
   added as a whole when one appears. omitted: <stddef.h> -- only size_t is
   needed, and it is declared here directly. */

#ifndef _RUBYCC_STRINGS_H
#define _RUBYCC_STRINGS_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif

int  bcmp(const void *__s1, const void *__s2, size_t __n);
void bcopy(const void *__src, void *__dest, size_t __n);
void bzero(void *__s, size_t __n);
void *memchr(const void *__s, int __c, size_t __n);
int  ffs(int __i);
int  ffsl(long __i);
int  ffsll(long long __i);
char *index(const char *__s, int __c);
char *rindex(const char *__s, int __c);
int  strcasecmp(const char *__s1, const char *__s2);
int  strncasecmp(const char *__s1, const char *__s2, size_t __n);

#endif /* _RUBYCC_STRINGS_H */
