/* rubycc bundled <stdio.h>: the standard I/O declarations and macros (ISO C
   7.21, POSIX). Derived from musl's <stdio.h> declaration set. FILE is kept
   opaque (an incomplete `struct _IO_FILE`, glibc's tag, reached only through
   FILE*), which is all ruby.h and the surveyed gems need. The macro values
   (BUFSIZ, TMP_MAX, ...) are the glibc ones (measured). Common layer: only FILE*
   crosses the ABI and it is a pointer, so nothing here is width sensitive. */

#ifndef _RUBYCC_STDIO_H
#define _RUBYCC_STDIO_H

#ifndef NULL
#define NULL ((void*)0)
#endif

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_SSIZE_T
#define _RUBYCC_SSIZE_T
typedef long ssize_t;
#endif
#ifndef _RUBYCC_OFF_T
#define _RUBYCC_OFF_T
typedef long off_t;
#endif
#ifndef _RUBYCC_GNUC_VA_LIST
#define _RUBYCC_GNUC_VA_LIST
typedef __builtin_va_list __gnuc_va_list;
#endif
/* musl's spelling of the same type; see the note in <stdarg.h>. */
#ifndef _RUBYCC_ISOC_VA_LIST
#define _RUBYCC_ISOC_VA_LIST
typedef __builtin_va_list __isoc_va_list;
#endif

/* FILE: opaque. glibc's tag and guard, so a host <stdio.h> reached later is a
   no-op and code that spells `struct _IO_FILE` stays compatible. */
#ifndef __FILE_defined
#define __FILE_defined 1
struct _IO_FILE;
typedef struct _IO_FILE FILE;
#endif

/* fpos_t: opaque but sized to match glibc's 16-byte layout, in case a caller
   stores one by value. */
#ifndef _RUBYCC_FPOS_T
#define _RUBYCC_FPOS_T
typedef struct { long __pos; struct { int __count; int __value; } __state; } fpos_t;
#endif

#define EOF (-1)

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2

#define BUFSIZ       8192
#define FOPEN_MAX    16
#define FILENAME_MAX 4096
#define L_tmpnam     20
#define TMP_MAX      238328
#define L_ctermid    9
#define P_tmpdir     "/tmp"

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;
#define stdin  stdin
#define stdout stdout
#define stderr stderr

int    remove(const char *__filename);
int    rename(const char *__old, const char *__new);
FILE  *tmpfile(void);
char  *tmpnam(char *__s);

int    fclose(FILE *__stream);
int    fflush(FILE *__stream);
FILE  *fopen(const char *__restrict __filename, const char *__restrict __modes);
FILE  *freopen(const char *__restrict __filename, const char *__restrict __modes, FILE *__restrict __stream);
FILE  *fdopen(int __fd, const char *__modes);
void   setbuf(FILE *__restrict __stream, char *__restrict __buf);
int    setvbuf(FILE *__restrict __stream, char *__restrict __buf, int __modes, size_t __n);

int    fprintf(FILE *__restrict __stream, const char *__restrict __format, ...);
int    printf(const char *__restrict __format, ...);
int    sprintf(char *__restrict __s, const char *__restrict __format, ...);
int    snprintf(char *__restrict __s, size_t __maxlen, const char *__restrict __format, ...);
int    vfprintf(FILE *__restrict __stream, const char *__restrict __format, __gnuc_va_list __arg);
int    vprintf(const char *__restrict __format, __gnuc_va_list __arg);
int    vsprintf(char *__restrict __s, const char *__restrict __format, __gnuc_va_list __arg);
int    vsnprintf(char *__restrict __s, size_t __maxlen, const char *__restrict __format, __gnuc_va_list __arg);
int    dprintf(int __fd, const char *__restrict __format, ...);
int    asprintf(char **__restrict __ptr, const char *__restrict __format, ...);
int    vasprintf(char **__restrict __ptr, const char *__restrict __format, __gnuc_va_list __arg);

int    fscanf(FILE *__restrict __stream, const char *__restrict __format, ...);
int    scanf(const char *__restrict __format, ...);
int    sscanf(const char *__restrict __s, const char *__restrict __format, ...);
int    vfscanf(FILE *__restrict __stream, const char *__restrict __format, __gnuc_va_list __arg);
int    vscanf(const char *__restrict __format, __gnuc_va_list __arg);
int    vsscanf(const char *__restrict __s, const char *__restrict __format, __gnuc_va_list __arg);

int    fgetc(FILE *__stream);
int    getc(FILE *__stream);
int    getchar(void);
int    fputc(int __c, FILE *__stream);
int    putc(int __c, FILE *__stream);
int    putchar(int __c);
int    ungetc(int __c, FILE *__stream);

char  *fgets(char *__restrict __s, int __n, FILE *__restrict __stream);
int    fputs(const char *__restrict __s, FILE *__restrict __stream);
int    puts(const char *__s);
ssize_t getline(char **__restrict __lineptr, size_t *__restrict __n, FILE *__restrict __stream);
ssize_t getdelim(char **__restrict __lineptr, size_t *__restrict __n, int __delimiter, FILE *__restrict __stream);

size_t fread(void *__restrict __ptr, size_t __size, size_t __n, FILE *__restrict __stream);
size_t fwrite(const void *__restrict __ptr, size_t __size, size_t __n, FILE *__restrict __stream);

int    fseek(FILE *__stream, long __off, int __whence);
long   ftell(FILE *__stream);
void   rewind(FILE *__stream);
int    fseeko(FILE *__stream, off_t __off, int __whence);
off_t  ftello(FILE *__stream);
int    fgetpos(FILE *__restrict __stream, fpos_t *__restrict __pos);
int    fsetpos(FILE *__stream, const fpos_t *__pos);

void   clearerr(FILE *__stream);
int    feof(FILE *__stream);
int    ferror(FILE *__stream);
int    fileno(FILE *__stream);
void   perror(const char *__s);

FILE  *popen(const char *__command, const char *__modes);
int    pclose(FILE *__stream);

#endif /* _RUBYCC_STDIO_H */
