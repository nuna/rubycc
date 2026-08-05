/* rubycc bundled <fcntl.h>: the open/fcntl flag macros, the fcntl commands,
   the *at family constants, and struct flock (POSIX). Provenance: clean room
   against the Linux kernel UAPI (asm-generic/fcntl.h plus the arch-specific
   uapi/asm/fcntl.h), not derived from musl. The O_*, F_* and AT_* values and
   the struct flock layout are ABI facts reproduced as measured integers, not
   copied text (see docs/HEADER-LICENSING.md) -- the same treatment as
   errno.h and sys/stat.h. open/openat/creat/fcntl are POSIX declarations.
   Placed in the glibc/aarch64 layer because O_DIRECT, O_DIRECTORY and
   O_NOFOLLOW swap bit assignments here versus x86-64's uapi/asm/fcntl.h.
   Two macros -- O_ACCMODE and O_LARGEFILE -- additionally differ between the
   two C libraries; both measured values are carried below, selected by
   __RUBYCC_LIBC_MUSL__ (see the preprocessor's LIBCS). This is also the layer
   that exists precisely because values move between machines -- the O_DIRECT
   group below is the standing proof, and O_LARGEFILE is a second one: musl's
   figure here (131072, i.e. 0400000) is not musl's x86-64 figure (32768,
   i.e. 0100000). Had this file copied the x86-64 companion's musl value
   instead of measuring its own, it would have been wrong. */

#ifndef _RUBYCC_FCNTL_H
#define _RUBYCC_FCNTL_H

#ifndef _RUBYCC_MODE_T
#define _RUBYCC_MODE_T
typedef unsigned int mode_t;
#endif
#ifndef _RUBYCC_OFF_T
#define _RUBYCC_OFF_T
typedef long off_t;
#endif
#ifndef _RUBYCC_PID_T
#define _RUBYCC_PID_T
typedef int pid_t;
#endif

/* Access modes (octal). */
#define O_RDONLY  0
#define O_WRONLY  01
#define O_RDWR    02
/* O_ACCMODE is one of the two flag macros the two libcs disagree on: musl's
   access-mode mask spans the O_PATH bit as well (measured 2097155, i.e.
   010000003), glibc's is the low two bits only (measured 3, i.e. 03) -- the
   same pair the x86-64 companion carries, and measured identically here
   (docs/STEPS.md Step 202), not merely assumed to match it (R8). Both
   figures are measurements of the ABI harness, glibc's on this host and
   musl's on the CI aarch64 musl run. */
#if defined(__RUBYCC_LIBC_MUSL__)
#define O_ACCMODE 010000003
#else
#define O_ACCMODE 03
#endif

/* Creation and status flags (octal, kernel ABI). */
#define O_CREAT     0100
#define O_EXCL      0200
#define O_NOCTTY    0400
#define O_TRUNC     01000
#define O_APPEND    02000
#define O_NONBLOCK  04000
#define O_NDELAY    O_NONBLOCK
#define O_DSYNC     010000
#define O_ASYNC     020000
#define O_SYNC      04010000
#define O_RSYNC     O_SYNC
#define O_CLOEXEC   02000000
/* O_LARGEFILE is the other flag macro the two libcs disagree on: musl hands
   out the kernel's own large-file bit (measured 131072, i.e. 0400000) while
   glibc, whose LP64 off_t is already 64-bit, leaves it empty (measured 0).
   Unlike O_ACCMODE above, this is NOT the x86-64 companion's musl figure
   (32768, i.e. 0100000): the large-file bit's position is arch specific, the
   same way O_DIRECT/O_DIRECTORY/O_NOFOLLOW are, so copying x86-64's value here
   would have been wrong rather than merely unmeasured (R8). Both measured
   with the ABI harness, glibc's here and musl's on the CI aarch64 musl run
   (docs/STEPS.md Step 202). */
#if defined(__RUBYCC_LIBC_MUSL__)
#define O_LARGEFILE 0400000
#else
#define O_LARGEFILE 0
#endif
#define O_NOATIME   01000000
#define O_PATH      010000000

/* Arch-specific bits (kernel uapi/asm/fcntl.h): O_DIRECT/O_DIRECTORY/
   O_NOFOLLOW swap values here versus x86-64. */
#define O_DIRECT    0200000
#define O_DIRECTORY 040000
#define O_NOFOLLOW  0100000

#define __O_TMPFILE 020000000
#define O_TMPFILE   (__O_TMPFILE | O_DIRECTORY)

/* fcntl commands. */
#define F_DUPFD  0
#define F_GETFD  1
#define F_SETFD  2
#define F_GETFL  3
#define F_SETFL  4
#define F_GETLK  5
#define F_SETLK  6
#define F_SETLKW 7
#define F_SETOWN 8
#define F_GETOWN 9
#define F_DUPFD_CLOEXEC 1030
/* Linux pipe-buffer sizing (Fcntl exposes both). Measured on this target
   rather than derived: 1024 + 7 and 1024 + 8 off the Linux-specific base,
   the same pair on x86-64 and aarch64. */
#define F_SETPIPE_SZ 1031
#define F_GETPIPE_SZ 1032

/* FD_CLOEXEC: the sole close-on-exec bit for F_GETFD/F_SETFD. */
#define FD_CLOEXEC 1

/* struct flock l_type / l_whence values. */
#define F_RDLCK 0
#define F_WRLCK 1
#define F_UNLCK 2

/* *at family flags. */
#define AT_FDCWD            (-100)
#define AT_SYMLINK_NOFOLLOW 0x100
#define AT_REMOVEDIR        0x200
#define AT_SYMLINK_FOLLOW   0x400
#define AT_EACCESS          0x200

#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

/* struct flock: 32 bytes, 8-byte aligned (LP64, measured). */
struct flock {
  short l_type;
  short l_whence;
  off_t l_start;
  off_t l_len;
  pid_t l_pid;
};

int open(const char *__file, int __oflag, ...);
int openat(int __fd, const char *__file, int __oflag, ...);
int creat(const char *__file, mode_t __mode);
int fcntl(int __fd, int __cmd, ...);

#endif /* _RUBYCC_FCNTL_H */
