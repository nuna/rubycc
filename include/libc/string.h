/* rubycc bundled <string.h>: the memory- and string-manipulation declarations
   (ISO C 7.24, POSIX). Derived from musl's <string.h> declaration set, kept as
   pure prototypes (size_t is the only ABI-typed name, shared via _RUBYCC_SIZE_T)
   so nothing here is arch specific. Common layer.

   Coverage against glibc's <string.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, both arches, with tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Added there: explicit_bzero
   (a wipe the compiler may not optimise away -- what a crypto extension
   reaches for), strverscmp and rawmemchr. The two GNU-only ones follow
   bundled-headers-coverage-audit-2's visibility rule (a name glibc shows only
   under _GNU_SOURCE is declared under __USE_GNU, so a program not built with
   _GNU_SOURCE that writes its own portability shim does not collide); the GNU
   names Step 124 already declared unconditionally are left where they are,
   since sources rely on seeing them. Each added prototype was written here and
   then placed ahead of glibc's own <string.h> under gcc and
   aarch64-linux-gnu-gcc, where a conflicting redeclaration is an error
   (2026-09-18, both clean). Intentionally left out:
   omitted: locale_t strcoll_l strerror_l strxfrm_l -- the locale-object API,
   which the bundled <locale.h> deliberately leaves out; the family is added as
   a whole when a consumer appears. omitted: strdupa strndupa -- glibc macros
   built on alloca inside a statement expression, so what they return dies with
   the calling function; strdup/strndup say the same thing safely.
   omitted: basename -- glibc's GNU basename is the one of two same-named
   functions that <libgen.h> replaces with a macro; bundling one spelling of a
   name whose meaning depends on which header came first would be worse than
   not having it. omitted: sigabbrev_np sigdescr_np strerrordesc_np
   strerrorname_np -- glibc 2.32 and later only, so declaring them would
   promise symbols an older host glibc does not have (the same line
   <stdlib.h> draws at arc4random). omitted: memfrob strfry -- the joke
   interfaces (an XOR "encryption" and a shuffle); no corpus user.
   omitted: <stddef.h> -- only size_t and NULL are needed, and both are
   declared here directly. */

#ifndef _RUBYCC_STRING_H
#define _RUBYCC_STRING_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#ifndef NULL
#define NULL ((void*)0)
#endif

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif

void *memcpy(void *__restrict __dest, const void *__restrict __src, size_t __n);
void *memmove(void *__dest, const void *__src, size_t __n);
void *memset(void *__s, int __c, size_t __n);
int   memcmp(const void *__s1, const void *__s2, size_t __n);
void *memchr(const void *__s, int __c, size_t __n);

char  *strcpy(char *__restrict __dest, const char *__restrict __src);
char  *strncpy(char *__restrict __dest, const char *__restrict __src, size_t __n);
char  *strcat(char *__restrict __dest, const char *__restrict __src);
char  *strncat(char *__restrict __dest, const char *__restrict __src, size_t __n);
int    strcmp(const char *__s1, const char *__s2);
int    strncmp(const char *__s1, const char *__s2, size_t __n);
int    strcoll(const char *__s1, const char *__s2);
size_t strxfrm(char *__restrict __dest, const char *__restrict __src, size_t __n);

char  *strchr(const char *__s, int __c);
char  *strrchr(const char *__s, int __c);
size_t strcspn(const char *__s, const char *__reject);
size_t strspn(const char *__s, const char *__accept);
char  *strpbrk(const char *__s, const char *__accept);
char  *strstr(const char *__haystack, const char *__needle);
char  *strtok(char *__restrict __s, const char *__restrict __delim);
char  *strtok_r(char *__restrict __s, const char *__restrict __delim, char **__restrict __save_ptr);

size_t strlen(const char *__s);
size_t strnlen(const char *__s, size_t __maxlen);

char  *strerror(int __errnum);
int    strerror_r(int __errnum, char *__buf, size_t __buflen);

char  *strdup(const char *__s);
char  *strndup(const char *__s, size_t __n);

/* POSIX/glibc extensions commonly relied on. */
void  *memccpy(void *__restrict __dest, const void *__restrict __src, int __c, size_t __n);
void  *mempcpy(void *__restrict __dest, const void *__restrict __src, size_t __n);
void  *memmem(const void *__haystack, size_t __haystacklen, const void *__needle, size_t __needlelen);
void  *memrchr(const void *__s, int __c, size_t __n);
char  *stpcpy(char *__restrict __dest, const char *__restrict __src);
char  *stpncpy(char *__restrict __dest, const char *__restrict __src, size_t __n);
/* BSD size-bounded copies, in glibc since 2.38; used by date's strftime. */
size_t strlcpy(char *__restrict __dest, const char *__restrict __src, size_t __size);
size_t strlcat(char *__restrict __dest, const char *__restrict __src, size_t __size);
char  *strsep(char **__restrict __stringp, const char *__restrict __delim);
char  *strchrnul(const char *__s, int __c);
char  *strcasestr(const char *__haystack, const char *__needle);
char  *strsignal(int __sig);
/* A wipe that survives dead-store elimination (glibc 2.25 and later); glibc
   shows it under _DEFAULT_SOURCE, so it is unconditional here. */
void   explicit_bzero(void *__s, size_t __n);

/* GNU-only names, gated as glibc gates them (see the visibility rule above). */
#ifdef __USE_GNU
int    strverscmp(const char *__s1, const char *__s2);
void  *rawmemchr(const void *__s, int __c);
#endif

/* glibc's <string.h> pulls in <strings.h> under __USE_MISC (the default GNU
   environment), so a translation unit that includes only <string.h> still sees
   strcasecmp/strncasecmp. Real-world sources (e.g. redcarpet's autolink.c) rely
   on that, so mirror it here. Our headers don't gate glibc extensions behind
   feature-test macros, so include it unconditionally. The lone overlapping
   prototype (memchr) is an identical, compatible redeclaration. */
#include <strings.h>

#endif /* _RUBYCC_STRING_H */
