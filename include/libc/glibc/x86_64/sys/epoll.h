/* rubycc bundled <sys/epoll.h> (x86-64): the Linux epoll(7) event-notification
   interface. Provenance: clean room against the Linux kernel UAPI
   (linux/eventpoll.h) and the glibc call surface, not derived from musl or
   glibc source. The EPOLL_CTL_ / EPOLL / EPOLL_CLOEXEC values and struct
   epoll_event's layout are that ABI reproduced as measured integer constants
   and measured field offsets (an ABI fact, not copied text -- see
   docs/HEADER-LICENSING.md sec. 4), the same treatment as poll.h and
   sys/socket.h.

   Arch layer, unlike poll.h: struct epoll_event's layout is the one place in
   this header that differs between the two targets, and it differs by design.
   The kernel fixed the x86-64 epoll_event at 12 bytes so that a 32-bit and a
   64-bit process see the same array stride, which means the 8-byte-aligned
   epoll_data_t union has to sit at offset 4 -- i.e. the struct is packed.
   Measured with the glibc oracle:

     x86-64 : sizeof 12, _Alignof 1, events @ 0, data @ 4   (packed)
     aarch64: sizeof 16, _Alignof 8, events @ 0, data @ 8   (not packed)

   so this header is in the arch layer (like fcntl.h, pthread.h, setjmp.h and
   sys/stat.h) with an aarch64 sibling, rather than in the common layer with a
   preprocessor branch. Every macro value, by contrast, measured identical on
   both targets and is repeated verbatim in the aarch64 copy.

   epoll_create/epoll_create1/epoll_ctl/epoll_wait are Linux/glibc
   declarations whose bodies resolve from the host libc at link time.

   Not included: epoll_pwait/epoll_pwait2 (their sigset_t / struct timespec
   parameters would mean cross-including <signal.h> and <time.h>, and no
   corpus census hit needs them -- nio4r and unicorn, the two gems that put
   this header on the list, reach epoll_create/epoll_ctl/epoll_wait only). */

#ifndef _RUBYCC_SYS_EPOLL_H
#define _RUBYCC_SYS_EPOLL_H

#include <stdint.h>

/* epoll_ctl operations (measured, both arches). */
#define EPOLL_CTL_ADD 1
#define EPOLL_CTL_DEL 2
#define EPOLL_CTL_MOD 3

/* epoll_create1 flag; shares O_CLOEXEC's bit (measured, both arches). */
#define EPOLL_CLOEXEC 0x80000

/* Event bits. The first six are the poll(2) values epoll reuses; the top four
   are epoll's own behaviour switches (measured, both arches). EPOLLET does not
   fit a signed int, so it is spelled as the unsigned hex value the oracle
   printed. */
#define EPOLLIN         0x001
#define EPOLLPRI        0x002
#define EPOLLOUT        0x004
#define EPOLLERR        0x008
#define EPOLLHUP        0x010
#define EPOLLRDNORM     0x040
#define EPOLLRDBAND     0x080
#define EPOLLWRNORM     0x100
#define EPOLLWRBAND     0x200
#define EPOLLMSG        0x400
#define EPOLLRDHUP      0x2000
#define EPOLLEXCLUSIVE  0x10000000
#define EPOLLWAKEUP     0x20000000
#define EPOLLONESHOT    0x40000000
#define EPOLLET         0x80000000

/* The caller-owned cookie epoll hands back with each ready event: 8 bytes,
   8-byte aligned (measured, both arches), all four arms at offset 0. */
union epoll_data {
  void    *ptr;
  int      fd;
  uint32_t u32;
  uint64_t u64;
};

typedef union epoll_data epoll_data_t;

/* struct epoll_event: 12 bytes, 1-byte aligned on x86-64 (measured) -- the
   packed attribute is what pulls `data` back to offset 4 and drops the
   trailing padding, reproducing the kernel's deliberate 12-byte stride. */
struct epoll_event {
  uint32_t     events; /* offset 0: an EPOLL* bit set */
  epoll_data_t data;   /* offset 4 (packed) */
} __attribute__((packed));

int epoll_create(int __size);
int epoll_create1(int __flags);
int epoll_ctl(int __epfd, int __op, int __fd, struct epoll_event *__event);
int epoll_wait(int __epfd, struct epoll_event *__events, int __maxevents,
               int __timeout);

#endif /* _RUBYCC_SYS_EPOLL_H */
