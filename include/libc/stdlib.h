/* rubycc bundled <stdlib.h>: general utilities (ISO C 7.22, POSIX). Derived from
   musl's <stdlib.h> declaration set; div_t/ldiv_t/lldiv_t carry the LP64 layout
   (measured: ldiv_t is two `long`s), and RAND_MAX/EXIT_* are the glibc values.
   Common layer: the div_t family layout is the same on any LP64 target. */

#ifndef _RUBYCC_STDLIB_H
#define _RUBYCC_STDLIB_H

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
long   random(void);
void   srandom(unsigned int __seed);

void  *malloc(size_t __size);
void  *calloc(size_t __nmemb, size_t __size);
void  *realloc(void *__ptr, size_t __size);
void   free(void *__ptr);
void  *aligned_alloc(size_t __alignment, size_t __size);
void  *reallocarray(void *__ptr, size_t __nmemb, size_t __size);
int    posix_memalign(void **__memptr, size_t __alignment, size_t __size);

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

#endif /* _RUBYCC_STDLIB_H */
