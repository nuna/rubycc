/* rubycc bundled <string.h>: the memory- and string-manipulation declarations
   (ISO C 7.24, POSIX). Derived from musl's <string.h> declaration set, kept as
   pure prototypes (size_t is the only ABI-typed name, shared via _RUBYCC_SIZE_T)
   so nothing here is arch specific. Common layer. */

#ifndef _RUBYCC_STRING_H
#define _RUBYCC_STRING_H

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

/* glibc's <string.h> pulls in <strings.h> under __USE_MISC (the default GNU
   environment), so a translation unit that includes only <string.h> still sees
   strcasecmp/strncasecmp. Real-world sources (e.g. redcarpet's autolink.c) rely
   on that, so mirror it here. Our headers don't gate glibc extensions behind
   feature-test macros, so include it unconditionally. The lone overlapping
   prototype (memchr) is an identical, compatible redeclaration. */
#include <strings.h>

#endif /* _RUBYCC_STRING_H */
