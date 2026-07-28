/* rubycc bundled <sys/ioctl.h>: the ioctl(2) declaration and terminal window
   size query (POSIX does not standardize ioctl at all; this is a Linux/glibc
   ABI surface). Provenance: clean room against the glibc/Linux ABI (glibc's
   bits/ioctl-types.h plus the kernel UAPI's asm-generic/ioctls.h request
   numbers), not derived from musl. Narrowed to the surface io-console's
   corpus sample actually reaches (Step 124, M5 H2): on the HAVE_TERMIOS_H
   path (see termios.h's provenance note) the only ioctl requests it issues
   are TIOCGWINSZ/TIOCSWINSZ against a `struct winsize`; the TCGETA/TCSETAF/
   TIOCGETP/TIOCSETP requests belong to the termio.h/sgtty.h fallback paths
   that HAVE_TERMIOS_H skips on Linux, so they are not reproduced here (the
   same "corpus-reached surface only" scoping sched.h and poll.h used).
   struct winsize is a struct callers read/write members of directly, so it
   cannot be an opaque byte blob; its size (8) and every member's offset, and
   the TIOCGWINSZ/TIOCSWINSZ request numbers, were measured against the glibc
   oracle on both x86-64 and aarch64 (see test/test_header_abi.rb's IOCTL
   case) and the two agreed exactly, so this header lives in the common
   layer. */

#ifndef _RUBYCC_SYS_IOCTL_H
#define _RUBYCC_SYS_IOCTL_H

/* struct winsize: 8 bytes, 2-byte aligned (measured, both arches). */
struct winsize {
  unsigned short ws_row;    /* offset 0: rows, in characters */
  unsigned short ws_col;    /* offset 2: columns, in characters */
  unsigned short ws_xpixel; /* offset 4: horizontal size, pixels */
  unsigned short ws_ypixel; /* offset 6: vertical size, pixels */
};

/* Terminal window size ioctl requests (measured, both arches agree). */
#define TIOCGWINSZ 0x5413
#define TIOCSWINSZ 0x5414

int ioctl(int __fd, unsigned long __request, ...);

#endif /* _RUBYCC_SYS_IOCTL_H */
