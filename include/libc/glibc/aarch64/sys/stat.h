/* rubycc bundled <sys/stat.h>: struct stat and the file-mode macros (POSIX).
   Provenance: clean room against the Linux aarch64 kernel ABI, not derived from
   musl. struct stat is pinned to that ABI, which differs from x86-64's: it is
   128 bytes (not 144), st_mode precedes st_nlink, nlink_t/blksize_t are 32-bit,
   and glibc reserves three slots to reach that size -- an 8-byte __pad1 after
   st_rdev (a second dev_t's worth of space), a 4-byte __pad2 after st_blksize,
   and a trailing int __glibc_reserved[2]. The measured field offsets are st_dev
   0, st_ino 8, st_mode 16, st_nlink 20, st_uid 24, st_gid 28, st_rdev 32,
   st_size 48, st_blksize 56, st_blocks 64, st_atim 72, st_mtim 88, st_ctim 104.
   Both the layout and the S_IF* octal values are ABI facts reproduced by
   measurement, not copied text (see docs/HEADER-LICENSING.md). The S_IF* values
   are the kernel ABI, identical to x86-64. Placed in the glibc/aarch64 layer
   because they are kernel-ABI specific. */

#ifndef _RUBYCC_SYS_STAT_H
#define _RUBYCC_SYS_STAT_H

#ifndef _RUBYCC_DEV_T
#define _RUBYCC_DEV_T
typedef unsigned long dev_t;
#endif
#ifndef _RUBYCC_INO_T
#define _RUBYCC_INO_T
typedef unsigned long ino_t;
#endif
#ifndef _RUBYCC_NLINK_T
#define _RUBYCC_NLINK_T
typedef unsigned int nlink_t;
#endif
#ifndef _RUBYCC_MODE_T
#define _RUBYCC_MODE_T
typedef unsigned int mode_t;
#endif
#ifndef _RUBYCC_UID_T
#define _RUBYCC_UID_T
typedef unsigned int uid_t;
#endif
#ifndef _RUBYCC_GID_T
#define _RUBYCC_GID_T
typedef unsigned int gid_t;
#endif
#ifndef _RUBYCC_OFF_T
#define _RUBYCC_OFF_T
typedef long off_t;
#endif
#ifndef _RUBYCC_TIME_T
#define _RUBYCC_TIME_T
typedef long time_t;
#endif
#ifndef _RUBYCC_BLKSIZE_T
#define _RUBYCC_BLKSIZE_T
typedef int blksize_t;
#endif
#ifndef _RUBYCC_BLKCNT_T
#define _RUBYCC_BLKCNT_T
typedef long blkcnt_t;
#endif
#ifndef _STRUCT_TIMESPEC
#define _STRUCT_TIMESPEC 1
struct timespec {
  time_t tv_sec;
  long   tv_nsec;
};
#endif

struct stat {
  dev_t   st_dev;          /*  0 */
  ino_t   st_ino;          /*  8 */
  mode_t  st_mode;         /* 16 (precedes st_nlink on aarch64) */
  nlink_t st_nlink;        /* 20 (32-bit) */
  uid_t   st_uid;          /* 24 */
  gid_t   st_gid;          /* 28 */
  dev_t   st_rdev;         /* 32 */
  dev_t   __pad1;          /* 40 (reserved dev_t slot) */
  off_t   st_size;         /* 48 */
  blksize_t st_blksize;    /* 56 (32-bit) */
  int     __pad2;          /* 60 */
  blkcnt_t  st_blocks;     /* 64 */
  struct timespec st_atim; /* 72 */
  struct timespec st_mtim; /* 88 */
  struct timespec st_ctim; /* 104 */
  int __glibc_reserved[2]; /* 120, filling out to 128 */
};

/* POSIX.1-2008 second-resolution aliases onto the timespec fields. */
#define st_atime st_atim.tv_sec
#define st_mtime st_mtim.tv_sec
#define st_ctime st_ctim.tv_sec

/* File type bits (octal, kernel ABI). */
#define S_IFMT   0170000
#define S_IFDIR  0040000
#define S_IFCHR  0020000
#define S_IFBLK  0060000
#define S_IFREG  0100000
#define S_IFIFO  0010000
#define S_IFLNK  0120000
#define S_IFSOCK 0140000

#define S_ISTYPE(mode, mask) (((mode) & S_IFMT) == (mask))
#define S_ISDIR(mode)  S_ISTYPE((mode), S_IFDIR)
#define S_ISCHR(mode)  S_ISTYPE((mode), S_IFCHR)
#define S_ISBLK(mode)  S_ISTYPE((mode), S_IFBLK)
#define S_ISREG(mode)  S_ISTYPE((mode), S_IFREG)
#define S_ISFIFO(mode) S_ISTYPE((mode), S_IFIFO)
#define S_ISLNK(mode)  S_ISTYPE((mode), S_IFLNK)
#define S_ISSOCK(mode) S_ISTYPE((mode), S_IFSOCK)

/* Permission bits. */
#define S_ISUID 04000
#define S_ISGID 02000
#define S_ISVTX 01000
#define S_IRUSR 0400
#define S_IWUSR 0200
#define S_IXUSR 0100
#define S_IRWXU (S_IRUSR | S_IWUSR | S_IXUSR)
#define S_IRGRP (S_IRUSR >> 3)
#define S_IWGRP (S_IWUSR >> 3)
#define S_IXGRP (S_IXUSR >> 3)
#define S_IRWXG (S_IRWXU >> 3)
#define S_IROTH (S_IRGRP >> 3)
#define S_IWOTH (S_IWGRP >> 3)
#define S_IXOTH (S_IXGRP >> 3)
#define S_IRWXO (S_IRWXG >> 3)

int stat(const char *__restrict __file, struct stat *__restrict __buf);
int fstat(int __fd, struct stat *__buf);
int lstat(const char *__restrict __file, struct stat *__restrict __buf);
int fstatat(int __fd, const char *__restrict __file, struct stat *__restrict __buf, int __flag);
int chmod(const char *__file, mode_t __mode);
int fchmod(int __fd, mode_t __mode);
int mkdir(const char *__path, mode_t __mode);
int mkfifo(const char *__path, mode_t __mode);
mode_t umask(mode_t __mask);

#endif /* _RUBYCC_SYS_STAT_H */
