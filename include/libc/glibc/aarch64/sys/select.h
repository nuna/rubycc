/* rubycc bundled <sys/select.h>: fd_set and select()/pselect() (POSIX). Derived
   from musl's <sys/select.h> shape; fd_set is pinned to the glibc x86-64 ABI --
   __FD_SETSIZE is 1024 and __fd_mask is `long`, giving a 128-byte set (measured).
   The typedef guards reuse glibc's (__sigset_t_defined) so a host <signal.h> on
   the path does not redefine sigset_t. ABI switch layer: FD_SETSIZE and the mask
   width are arch specific. */

#ifndef _RUBYCC_SYS_SELECT_H
#define _RUBYCC_SYS_SELECT_H

#ifndef _RUBYCC_TIME_T
#define _RUBYCC_TIME_T
typedef long time_t;
#endif
#ifndef _RUBYCC_SUSECONDS_T
#define _RUBYCC_SUSECONDS_T
typedef long suseconds_t;
#endif

#ifndef __timeval_defined
#define __timeval_defined 1
struct timeval {
  time_t      tv_sec;
  suseconds_t tv_usec;
};
#endif
#ifndef _STRUCT_TIMESPEC
#define _STRUCT_TIMESPEC 1
struct timespec {
  time_t tv_sec;
  long   tv_nsec;
};
#endif

#ifndef __sigset_t_defined
#define __sigset_t_defined 1
typedef struct { unsigned long __val[1024 / (8 * sizeof(unsigned long))]; } __sigset_t;
typedef __sigset_t sigset_t;
#endif

#define __FD_SETSIZE 1024
typedef long __fd_mask;
#define __NFDBITS (8 * (int) sizeof(__fd_mask))

typedef struct {
  __fd_mask __fds_bits[__FD_SETSIZE / __NFDBITS];
} fd_set;

typedef __fd_mask fd_mask;

#define FD_SETSIZE __FD_SETSIZE

#define __FD_ELT(d)  ((d) / __NFDBITS)
#define __FD_MASK(d) ((__fd_mask) (1UL << ((d) % __NFDBITS)))

#define FD_ZERO(set) \
  do { \
    unsigned long __i; \
    fd_set *__s = (set); \
    for (__i = 0; __i < sizeof(fd_set) / sizeof(__fd_mask); ++__i) \
      __s->__fds_bits[__i] = 0; \
  } while (0)
#define FD_SET(d, set)   ((set)->__fds_bits[__FD_ELT(d)] |= __FD_MASK(d))
#define FD_CLR(d, set)   ((set)->__fds_bits[__FD_ELT(d)] &= ~__FD_MASK(d))
#define FD_ISSET(d, set) (((set)->__fds_bits[__FD_ELT(d)] & __FD_MASK(d)) != 0)

int select(int __nfds, fd_set *__restrict __readfds,
           fd_set *__restrict __writefds, fd_set *__restrict __exceptfds,
           struct timeval *__restrict __timeout);
int pselect(int __nfds, fd_set *__restrict __readfds,
            fd_set *__restrict __writefds, fd_set *__restrict __exceptfds,
            const struct timespec *__restrict __timeout,
            const sigset_t *__restrict __sigmask);

#endif /* _RUBYCC_SYS_SELECT_H */
