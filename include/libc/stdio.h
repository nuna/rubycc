/* rubycc bundled <stdio.h>: the standard I/O declarations and macros (ISO C
   7.21, POSIX). Derived from musl's <stdio.h> declaration set. FILE is kept
   opaque (an incomplete `struct _IO_FILE`, glibc's tag, reached only through
   FILE*), which is all ruby.h and the surveyed gems need. The macro values
   (BUFSIZ, TMP_MAX, ...) are measured, and the three of them the two C
   libraries disagree on are carried under __RUBYCC_LIBC_MUSL__ (see the
   preprocessor's LIBCS). Common layer: only FILE* crosses the ABI and it is a
   pointer, so nothing here is width sensitive.

   Coverage against glibc's <stdio.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, both arches, with tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Added there: va_list (POSIX
   has <stdio.h> define it, and glibc does so behind _VA_LIST_DEFINED, which is
   set here too), the explicit locking calls and the whole _unlocked family
   (what a C extension reaches for when it has already taken the lock itself --
   getc_unlocked was rejected by rubycc before, measured 2026-09-18), fmemopen
   and open_memstream, vdprintf, renameat, setbuffer/setlinebuf and ctermid.
   Visibility follows bundled-headers-coverage-audit-2's rule: what glibc shows
   in gcc's default mode is unconditional, what it shows only under _GNU_SOURCE
   sits under __USE_GNU. Every added prototype was written here and then put
   next to glibc's own <stdio.h> under gcc and aarch64-linux-gnu-gcc, where a
   conflicting redeclaration is an error (2026-09-18, both clean); SEEK_DATA
   and SEEK_HOLE were printed from the oracle on both arches (3 and 4, equal).
   Intentionally left out:
   omitted: fopencookie cookie_io_functions_t cookie_read_function_t
   cookie_write_function_t cookie_seek_function_t cookie_close_function_t --
   glibc's hook for a caller-defined stream; its seek hook is typed over
   glibc's internal __off64_t, so providing it means carrying that plumbing as
   well, and no corpus user opens one. omitted: fopen64 freopen64 tmpfile64
   fseeko64 ftello64 fgetpos64 fsetpos64 fpos64_t off64_t -- LFS64 aliases,
   identical to the unsuffixed calls on an LP64 target (the line <stdlib.h>
   draws at mkstemp64). omitted: renameat2 RENAME_EXCHANGE RENAME_NOREPLACE
   RENAME_WHITEOUT -- the Linux-only rename with flags; renameat above covers
   what sources call. omitted: obstack_printf obstack_vprintf -- they print
   into a GNU obstack, and rubycc bundles no <obstack.h>.
   omitted: tempnam tmpnam_r cuserid L_cuserid fcloseall getw putw -- the
   legacy half (tempnam and cuserid are unsafe by construction and tmpnam_r is
   glibc's own patch over tmpnam; fcloseall, getw and putw have no corpus
   user). omitted: <stdarg.h> <stddef.h> -- glibc reaches __gnuc_va_list,
   size_t and NULL through them; all three are declared here directly. */

#ifndef _RUBYCC_STDIO_H
#define _RUBYCC_STDIO_H

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
/* POSIX has <stdio.h> define va_list as well, for the v*printf family below.
   glibc sets _VA_LIST_DEFINED when it does; repeating the typedef with the
   same type is legal either way (C11 6.7p3), so <stdarg.h> included before or
   after this header is not a conflict. */
#ifndef _VA_LIST_DEFINED
#define _VA_LIST_DEFINED 1
typedef __builtin_va_list va_list;
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
/* The sparse-file whences (Linux). Printed from the glibc oracle as 3 and 4 on
   both arches (2026-09-18); the bundled <unistd.h> carries the same pair. */
#ifdef __USE_GNU
#define SEEK_DATA 3
#define SEEK_HOLE 4
#endif

#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2

/* BUFSIZ, FOPEN_MAX and TMP_MAX are the three values in this header the two C
   libraries disagree on: musl reports 1024, 1000 and 10000 where glibc reports
   8192, 16 and 238328. All six measured with the ABI harness, glibc's on this
   host and musl's on the CI musl run (docs/STEPS.md Step 193). EOF, the SEEK_*
   and _IO*BF sets, FILENAME_MAX and L_tmpnam are probed too and measured
   identical on both; L_ctermid and P_tmpdir are not probed on either. */
#if defined(__RUBYCC_LIBC_MUSL__)
#define BUFSIZ       1024
#define FOPEN_MAX    1000
#define TMP_MAX      10000
#else
#define BUFSIZ       8192
#define FOPEN_MAX    16
#define TMP_MAX      238328
#endif
#define FILENAME_MAX 4096
#define L_tmpnam     20
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

/* The controlling terminal's name; L_ctermid above is the buffer size. */
char  *ctermid(char *__s);

/* Streams that write into memory rather than a file descriptor. */
FILE  *fmemopen(void *__s, size_t __len, const char *__modes);
FILE  *open_memstream(char **__bufloc, size_t *__sizeloc);
int    vdprintf(int __fd, const char *__restrict __format, __gnuc_va_list __arg);
int    renameat(int __oldfd, const char *__old, int __newfd, const char *__new);
void   setbuffer(FILE *__restrict __stream, char *__restrict __buf, size_t __size);
void   setlinebuf(FILE *__stream);

/* Explicit stream locking, and the _unlocked accessors that assume the caller
   holds the lock (or knows the stream is private). POSIX has the first seven;
   the rest are glibc's, shown in gcc's default mode. */
void   flockfile(FILE *__stream);
int    ftrylockfile(FILE *__stream);
void   funlockfile(FILE *__stream);
int    getc_unlocked(FILE *__stream);
int    getchar_unlocked(void);
int    putc_unlocked(int __c, FILE *__stream);
int    putchar_unlocked(int __c);
void   clearerr_unlocked(FILE *__stream);
int    feof_unlocked(FILE *__stream);
int    ferror_unlocked(FILE *__stream);
int    fileno_unlocked(FILE *__stream);
int    fflush_unlocked(FILE *__stream);
int    fgetc_unlocked(FILE *__stream);
int    fputc_unlocked(int __c, FILE *__stream);
size_t fread_unlocked(void *__restrict __ptr, size_t __size, size_t __n, FILE *__restrict __stream);
size_t fwrite_unlocked(const void *__restrict __ptr, size_t __size, size_t __n, FILE *__restrict __stream);
#ifdef __USE_GNU
char  *fgets_unlocked(char *__restrict __s, int __n, FILE *__restrict __stream);
int    fputs_unlocked(const char *__restrict __s, FILE *__restrict __stream);
#endif

#endif /* _RUBYCC_STDIO_H */
