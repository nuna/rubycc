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
   (Step 123, M5 H2). */

#ifndef _RUBYCC_DIRENT_H
#define _RUBYCC_DIRENT_H

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

DIR *opendir(const char *__name);
DIR *fdopendir(int __fd);
struct dirent *readdir(DIR *__dirp);
int readdir_r(DIR *__restrict __dirp, struct dirent *__restrict __entry,
              struct dirent **__restrict __result);
int closedir(DIR *__dirp);
void rewinddir(DIR *__dirp);
int dirfd(DIR *__dirp);

#endif /* _RUBYCC_DIRENT_H */
