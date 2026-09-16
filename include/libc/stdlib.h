/* rubycc bundled <stdlib.h>: general utilities (ISO C 7.22, POSIX). Derived from
   musl's <stdlib.h> declaration set; div_t/ldiv_t/lldiv_t carry the LP64 layout
   (measured: ldiv_t is two `long`s), and RAND_MAX/EXIT_* are the glibc values.
   Common layer: the div_t family layout is the same on any LP64 target.

   Coverage against glibc's <stdlib.h> under _GNU_SOURCE (audited 2026-09-14,
   glibc 2.39, x86-64 and aarch64, with tools/audit_bundled_headers.rb; table
   in docs/development/BUNDLED-HEADERS-COVERAGE.md). Visibility rule: a name
   glibc shows in gcc's default mode (_DEFAULT_SOURCE, i.e. __USE_MISC and
   below) is declared unconditionally, as this header always has; a name
   glibc shows only under _GNU_SOURCE is declared under __USE_GNU too, so a
   program that is not built with _GNU_SOURCE and defines its own qsort_r (a
   common portability shim, sometimes with the BSD argument order) does not
   collide with it -- that is also why this header now includes <features.h>.
   Added by bundled-headers-coverage-audit-2: getloadavg (GAPS AF), qsort_r
   (AR), <alloca.h> (BG, glibc includes it under __USE_MISC), and alongside
   them the rest of the POSIX/XSI temp-file, pseudo-terminal and 48-bit
   random-number calls and the GNU mkostemp/secure_getenv/ptsname_r family.
   Intentionally left out:
   omitted: WCONTINUED WEXITED WEXITSTATUS WIFCONTINUED WIFEXITED WIFSIGNALED
   WIFSTOPPED WNOHANG WNOWAIT WSTOPPED WSTOPSIG WTERMSIG WUNTRACED -- the wait
   status macros, which the bundled <sys/wait.h> provides with the same values.
   omitted: <sys/types.h> <endian.h> <sys/select.h> -- glibc pulls these in
   under __USE_MISC; not reproduced here so that every translation unit that
   includes <stdlib.h> does not also receive the BSD u_char/ushort family,
   include <sys/types.h> directly. omitted: <stddef.h> -- only size_t, wchar_t
   and NULL are needed, and they are declared here directly.
   omitted: getsubopt a64l l64a rpmatch clearenv on_exit mktemp valloc getpt
   strtoq strtouq comparison_fn_t -- obsolete or rarely used, no corpus user.
   omitted: ecvt fcvt gcvt q*cvt *cvt_r -- legacy floating-point formatting,
   removed from POSIX in 2008. omitted: *48_r random_r srandom_r initstate_r
   setstate_r struct drand48_data struct random_data -- the reentrant
   generators need glibc's private state-struct layouts. omitted: arc4random
   arc4random_buf arc4random_uniform -- glibc 2.36 and later only; declaring
   them would promise symbols an older host glibc does not have.
   omitted: locale_t *_l -- the locale-object API; the bundled <locale.h> has
   no locale_t. omitted: strfrom* strtof128* strtof32* strtof64* -- ISO/IEC TS
   18661 interfaces over _FloatN types rubycc does not model.
   omitted: mkstemp64 mkstemps64 mkostemp64 mkostemps64 -- LFS64 aliases,
   identical to the unsuffixed calls on an LP64 target; no corpus user.
   Re-audited 2026-09-16 under audit-reserved-public-macros-1 (GAPS BX),
   which widened the diff to the reserved spellings a program writes
   (_POSIX_*, _SC_*, ioctl's _IO*, and the standard functions spelled with a
   leading underscore): the only one glibc's <stdlib.h> owns is _Exit, which
   this header already declares, so nothing was added or left out here. */

#ifndef _RUBYCC_STDLIB_H
#define _RUBYCC_STDLIB_H

#include <features.h>

#ifndef NULL
#define NULL ((void*)0)
#endif

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_WCHAR_T
#define _RUBYCC_WCHAR_T
typedef int wchar_t;
#endif

typedef struct { int quot; int rem; } div_t;
typedef struct { long quot; long rem; } ldiv_t;
typedef struct { long long quot; long long rem; } lldiv_t;

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX     2147483647

extern size_t __ctype_get_mb_cur_max(void);
#define MB_CUR_MAX (__ctype_get_mb_cur_max())

double  atof(const char *__nptr);
int     atoi(const char *__nptr);
long    atol(const char *__nptr);
long long atoll(const char *__nptr);

double      strtod(const char *__restrict __nptr, char **__restrict __endptr);
float       strtof(const char *__restrict __nptr, char **__restrict __endptr);
long double strtold(const char *__restrict __nptr, char **__restrict __endptr);
long        strtol(const char *__restrict __nptr, char **__restrict __endptr, int __base);
unsigned long strtoul(const char *__restrict __nptr, char **__restrict __endptr, int __base);
long long   strtoll(const char *__restrict __nptr, char **__restrict __endptr, int __base);
unsigned long long strtoull(const char *__restrict __nptr, char **__restrict __endptr, int __base);

int    rand(void);
void   srand(unsigned int __seed);
int    rand_r(unsigned int *__seed);
long   random(void);
void   srandom(unsigned int __seed);
char  *initstate(unsigned int __seed, char *__statebuf, size_t __statelen);
char  *setstate(char *__statebuf);

/* The XSI 48-bit linear congruential generators. The unsigned short[3]
   arrays are the caller-held 48-bit state; lcong48 also takes the multiplier
   and addend, 7 elements in all. */
double drand48(void);
double erand48(unsigned short __xsubi[3]);
long   lrand48(void);
long   nrand48(unsigned short __xsubi[3]);
long   mrand48(void);
long   jrand48(unsigned short __xsubi[3]);
void   srand48(long __seedval);
unsigned short *seed48(unsigned short __seed16v[3]);
void   lcong48(unsigned short __param[7]);

void  *malloc(size_t __size);
void  *calloc(size_t __nmemb, size_t __size);
void  *realloc(void *__ptr, size_t __size);
void   free(void *__ptr);
void  *aligned_alloc(size_t __alignment, size_t __size);
void  *reallocarray(void *__ptr, size_t __nmemb, size_t __size);
int    posix_memalign(void **__memptr, size_t __alignment, size_t __size);

/* glibc declares alloca through <alloca.h> whenever __USE_MISC is on, which
   gcc's default mode always has (GAPS BG). */
#include <alloca.h>

void   abort(void) __attribute__((__noreturn__));
int    atexit(void (*__func)(void));
int    at_quick_exit(void (*__func)(void));
void   exit(int __status) __attribute__((__noreturn__));
void   quick_exit(int __status) __attribute__((__noreturn__));
void   _Exit(int __status) __attribute__((__noreturn__));

char  *getenv(const char *__name);
int    setenv(const char *__name, const char *__value, int __replace);
int    unsetenv(const char *__name);
int    putenv(char *__string);
int    system(const char *__command);
char  *realpath(const char *__restrict __name, char *__restrict __resolved);
int    mkstemp(char *__template);
int    mkstemps(char *__template, int __suffixlen);
char  *mkdtemp(char *__template);

/* The system load averages over the last 1, 5 and 15 minutes, into up to
   __nelem elements (a BSD call glibc shows under __USE_MISC; GAPS AF). */
int    getloadavg(double __loadavg[], int __nelem);

/* Pseudo-terminal master side (POSIX XSI). */
int    posix_openpt(int __oflag);
int    grantpt(int __fd);
int    unlockpt(int __fd);
char  *ptsname(int __fd);

void  *bsearch(const void *__key, const void *__base, size_t __nmemb, size_t __size,
               int (*__compar)(const void *, const void *));
void   qsort(void *__base, size_t __nmemb, size_t __size,
             int (*__compar)(const void *, const void *));

int    abs(int __x);
long   labs(long __x);
long long llabs(long long __x);
div_t  div(int __numer, int __denom);
ldiv_t ldiv(long __numer, long __denom);
lldiv_t lldiv(long long __numer, long long __denom);

int    mblen(const char *__s, size_t __n);
int    mbtowc(wchar_t *__restrict __pwc, const char *__restrict __s, size_t __n);
int    wctomb(char *__s, wchar_t __wchar);
size_t mbstowcs(wchar_t *__restrict __pwcs, const char *__restrict __s, size_t __n);
size_t wcstombs(char *__restrict __s, const wchar_t *__restrict __pwcs, size_t __n);

#ifdef __USE_GNU
/* qsort with a caller context pointer handed to every comparison as its third
   argument (the GNU argument order; GAPS AR). */
void   qsort_r(void *__base, size_t __nmemb, size_t __size,
               int (*__compar)(const void *, const void *, void *), void *__arg);
int    mkostemp(char *__template, int __flags);
int    mkostemps(char *__template, int __suffixlen, int __flags);
char  *secure_getenv(const char *__name);
char  *canonicalize_file_name(const char *__name);
int    ptsname_r(int __fd, char *__buf, size_t __buflen);
#endif

#endif /* _RUBYCC_STDLIB_H */
