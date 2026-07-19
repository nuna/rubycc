/* rubycc bundled <strings.h>: the BSD byte-string declarations (POSIX). Derived
   from musl's <strings.h> declaration set; pure prototypes, nothing arch
   specific. Common layer. */

#ifndef _RUBYCC_STRINGS_H
#define _RUBYCC_STRINGS_H

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
