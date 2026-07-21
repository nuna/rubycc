/* rubycc bundled <poll.h>: the poll(2) event macros and struct pollfd (POSIX).
   Provenance: clean room against the Linux kernel UAPI (asm-generic/poll.h),
   not derived from musl. The POLL* values are the kernel ABI, reproduced here
   as measured integer constants (an ABI fact, not copied text -- see
   docs/HEADER-LICENSING.md), the same treatment as errno.h and fcntl.h. struct
   pollfd is a POSIX declaration. Common layer: struct pollfd's layout and every
   POLLIN/POLLOUT/... value are identical on x86-64 and aarch64, unlike
   fcntl.h's O_DIRECT family. */

#ifndef _RUBYCC_POLL_H
#define _RUBYCC_POLL_H

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
