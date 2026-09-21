/* rubycc bundled <dirent.h>: directory stream access (POSIX.1). Provenance:
   clean room against the POSIX public interface and the glibc/Linux ABI.
   DIR is glibc's own public spelling `typedef struct __dirstream DIR;' with
   struct __dirstream left incomplete -- glibc itself never defines it in a
   public header (its fields are libio-internal), and every caller only ever
   holds a `DIR *' returned by opendir/fdopendir, never a `DIR' by value, so
   there is nothing to size or reproduce; following the same public spelling
   is a POSIX/glibc interoperability fact, not glibc source copied.
   struct dirent, unlike DIR, is a struct callers read members out of
   directly, so it cannot be an opaque byte blob. Its member order
   (d_ino, d_off, d_reclen, d_type, d_name) and the d_reclen/d_type slots
   ahead of d_name are glibc/Linux ABI, not POSIX (POSIX only guarantees
   d_name), the same way sys/stat.h's field order is a kernel ABI fact rather
   than a POSIX one; the struct's size (280, with d_name[256]) and every
   member's offset were measured against the glibc oracle on both x86-64 and
   aarch64 (see test/test_header_abi.rb's DIRENT case) and the two agreed
   exactly (ino_t/off_t are both 8-byte and d_reclen/d_type/d_name have no
   arch-dependent width on either LP64 target), so this header lives in the
   common layer. ino_t/off_t reuse the shared _RUBYCC_* guards sys/stat.h and
   sys/types.h also carry. The DT_* file-type constants are the standard
   Linux/glibc values (measured, both arches agree).
   opendir/readdir/closedir/rewinddir/readdir_r/fdopendir/dirfd are POSIX
   declarations whose bodies resolve from the host libc at link time
   (Step 123, M5 H2).

   Coverage against glibc's <dirent.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, x86-64 and aarch64, with tools/audit_bundled_headers.rb; table
   in docs/development/BUNDLED-HEADERS-COVERAGE.md). Seventy-nine names were
   missing. Ten were added -- everything the difference holds that is actually
   about reading a directory:

     - seekdir/telldir, the position pair a caller uses to resume a scan;
     - scandir/scandirat with the two comparators glibc ships for them,
       alphasort and versionsort (scandir is how most C code lists a directory
       in one call, and it is useless without a comparator);
     - d_fileno, the BSD spelling of d_ino, defined here as a member macro
       onto the field above the same way sys/stat.h aliases st_atime;
     - MAXNAMLEN, measured 255 on both arches -- the d_name[256] above is
       exactly that plus the terminating NUL;
     - DTTOIF/IFTODT, which convert between the DT_* values above and the
       S_IF* file-type bits of <sys/stat.h>. Their bodies are rubycc's own
       spelling of measured behaviour, not glibc's text: DTTOIF printed 16384
       for DT_DIR, 32768 for DT_REG, 40960 for DT_LNK, 49152 for DT_SOCK and 0
       for DT_UNKNOWN, and IFTODT printed 8 for 0100644, 4 for 0040755, 10 for
       0120777 and 0 for 0 -- i.e. a shift by 12 in either direction, with
       IFTODT masking the mode down to its type bits first.

   Every added prototype was checked by declaring it immediately before
   `#include <dirent.h>` under gcc and aarch64-linux-gnu-gcc on 2026-09-18 (a
   conflicting redeclaration is a hard error): clean on both arches. The other
   sixty-nine are deliberate:
   omitted: AIO_PRIO_DELTA_MAX DELAYTIMER_MAX HOST_NAME_MAX LOGIN_NAME_MAX
   MAX_CANON MAX_INPUT MQ_PRIO_MAX NAME_MAX NGROUPS_MAX PATH_MAX PIPE_BUF
   PTHREAD_DESTRUCTOR_ITERATIONS PTHREAD_KEYS_MAX PTHREAD_STACK_MIN RTSIG_MAX
   SEM_VALUE_MAX SSIZE_MAX TTY_NAME_MAX XATTR_LIST_MAX XATTR_NAME_MAX
   XATTR_SIZE_MAX _POSIX_* -- the POSIX limit and option macros, which are not
   this header's surface at all: glibc shows them here only because its
   <dirent.h> reaches for <bits/posix1_lim.h> on the way to a NAME_MAX it
   wants itself, and the header a program asks them from is <limits.h>, where
   rubycc's own answer for them belongs.
   omitted: getdirentries -- the BSD raw directory-block read, superseded by
   readdir above and with no corpus user.
   omitted: getdents64 -- the raw 64-bit directory-block read, glibc 2.30 and
   later only, so declaring it would promise a symbol an older host glibc does
   not export (the same reasoning unistd.h's close_range omission uses).
   omitted: struct dirent64 ino64_t readdir64 readdir64_r scandir64
   scandirat64 alphasort64 versionsort64 getdirentries64 -- LFS64 aliases; on
   an LP64 target struct dirent64 is byte-for-byte struct dirent above, so the
   unsuffixed names already are the 64-bit interface (the same reasoning
   sys/statfs.h and unistd.h use).
   omitted: <stddef.h> -- only size_t is needed, and this header's calls take
   it nowhere; ino_t/off_t are declared here directly. */

#ifndef _RUBYCC_DIRENT_H
#define _RUBYCC_DIRENT_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#ifndef _RUBYCC_INO_T
#define _RUBYCC_INO_T
typedef unsigned long ino_t;
#endif
#ifndef _RUBYCC_OFF_T
#define _RUBYCC_OFF_T
typedef long off_t;
#endif

/* Opaque directory-stream handle. Only ever used through a `DIR *'; struct
   __dirstream is intentionally left incomplete, the same way glibc's own
   public header leaves it. */
typedef struct __dirstream DIR;

/* struct dirent: 280 bytes, 8-byte aligned (measured, both arches). */
struct dirent {
  ino_t d_ino;            /* offset 0:  inode number */
  off_t d_off;             /* offset 8:  offset to the next dirent */
  unsigned short d_reclen; /* offset 16: length of this record */
  unsigned char d_type;    /* offset 18: file type (DT_*) */
  char d_name[256];        /* offset 19: null-terminated filename */
};

/* The BSD spelling of d_ino, and the longest name that fits in d_name
   (measured 255, both arches). */
#define d_fileno d_ino
#define MAXNAMLEN 255

/* File-type values for d_type (measured, both arches agree). */
#define DT_UNKNOWN 0
#define DT_FIFO    1
#define DT_CHR     2
#define DT_DIR     4
#define DT_BLK     6
#define DT_REG     8
#define DT_LNK     10
#define DT_SOCK    12
#define DT_WHT     14

/* Between a d_type value above and the S_IF* file-type bits of <sys/stat.h>:
   a shift by 12, with IFTODT masking the mode to its type bits first
   (measured, see the header note). */
#define DTTOIF(dirtype) ((dirtype) << 12)
#define IFTODT(mode)    (((mode) & 0170000) >> 12)

DIR *opendir(const char *__name);
DIR *fdopendir(int __fd);
struct dirent *readdir(DIR *__dirp);
int readdir_r(DIR *__restrict __dirp, struct dirent *__restrict __entry,
              struct dirent **__restrict __result);
int closedir(DIR *__dirp);
void rewinddir(DIR *__dirp);
int dirfd(DIR *__dirp);
long telldir(DIR *__dirp);
void seekdir(DIR *__dirp, long __pos);

/* One-call directory listing, and the two orderings glibc ships for it. */
int scandir(const char *__restrict __dir, struct dirent ***__restrict __namelist,
            int (*__selector)(const struct dirent *),
            int (*__cmp)(const struct dirent **, const struct dirent **));
int scandirat(int __dfd, const char *__restrict __dir,
              struct dirent ***__restrict __namelist,
              int (*__selector)(const struct dirent *),
              int (*__cmp)(const struct dirent **, const struct dirent **));
int alphasort(const struct dirent **__e1, const struct dirent **__e2);
int versionsort(const struct dirent **__e1, const struct dirent **__e2);

#endif /* _RUBYCC_DIRENT_H */
