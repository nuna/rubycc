/* rubycc bundled <poll.h>: the poll(2) event macros and struct pollfd (POSIX).
   Provenance: clean room against the Linux kernel UAPI (asm-generic/poll.h),
   not derived from musl. The POLL* values are the kernel ABI, reproduced here
   as measured integer constants (an ABI fact, not copied text -- see
   docs/HEADER-LICENSING.md), the same treatment as errno.h and fcntl.h. struct
   pollfd is a POSIX declaration. Common layer: struct pollfd's layout and every
   POLLIN/POLLOUT/... value are identical on x86-64 and aarch64, unlike
   fcntl.h's O_DIRECT family.

   Coverage against glibc's <poll.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, x86-64 and aarch64, with tools/audit_bundled_headers.rb; table
   in docs/development/BUNDLED-HEADERS-COVERAGE.md). No name is missing. The
   one difference is structural:
   omitted: <sys/poll.h> -- glibc's <poll.h> owns no name of its own, it is a
   one-line wrapper that includes <sys/poll.h> and lets that file carry
   everything; rubycc puts the same surface directly in this file, so there is
   nothing for a bundled <sys/poll.h> to hold (a program that includes
   <sys/poll.h> by that spelling reaches the host glibc's copy, which the
   coverage test compiles on top of the bundled headers). */

#ifndef _RUBYCC_POLL_H
#define _RUBYCC_POLL_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#ifndef _RUBYCC_NFDS_T
#define _RUBYCC_NFDS_T
typedef unsigned long nfds_t;
#endif

/* struct pollfd: 8 bytes, 4-byte aligned (measured, both arches). */
struct pollfd {
  int fd;
  short events;
  short revents;
};

/* Event bits (Linux kernel UAPI, asm-generic/poll.h). POSIX. */
#define POLLIN     0x001
#define POLLPRI    0x002
#define POLLOUT    0x004
#define POLLERR    0x008
#define POLLHUP    0x010
#define POLLNVAL   0x020

/* XOPEN extensions. */
#define POLLRDNORM 0x040
#define POLLRDBAND 0x080
#define POLLWRNORM 0x100
#define POLLWRBAND 0x200
#define POLLMSG    0x400

/* Linux extensions. */
#define POLLREMOVE 0x1000
#define POLLRDHUP  0x2000

int poll(struct pollfd *__fds, nfds_t __nfds, int __timeout);

#endif /* _RUBYCC_POLL_H */
