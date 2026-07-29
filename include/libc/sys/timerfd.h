/* rubycc bundled <sys/timerfd.h>: the Linux timerfd(2) family, which delivers
   POSIX timer expirations as readable events on a file descriptor.
   Provenance: clean room against the Linux kernel UAPI
   (linux/timerfd.h) and the glibc call surface, not derived from musl or
   glibc source. The four TFD_* values are that ABI reproduced as measured
   integer constants (an ABI fact, not copied text -- see
   docs/HEADER-LICENSING.md sec. 4), printed from the glibc oracle on x86-64
   and on aarch64 (cross gcc + qemu).

   Common layer. Both TFD_CLOEXEC and TFD_NONBLOCK share bits with the
   open(2) flags, which do differ between the two targets for some O_* names
   (that is why fcntl.h is an arch-layer header), so this was measured rather
   than assumed. It measured identical on both:

     TFD_CLOEXEC 0x80000, TFD_NONBLOCK 0x800,
     TFD_TIMER_ABSTIME 1, TFD_TIMER_CANCEL_ON_SET 2

   and so did everything the interface's types rest on -- struct itimerspec
   is 32 bytes with it_interval at 0 and it_value at 16, struct timespec is
   16 bytes, clockid_t is 4 -- so no arch split is needed here.

   struct itimerspec is NOT duplicated below: the bundled <time.h> already
   defines it (next to struct timespec, which it is built from), so this
   header includes <time.h> and lets the one definition serve, the same
   judgement <sys/wait.h> makes about siginfo_t. That include also supplies
   the CLOCK_* ids timerfd_create's first argument takes.

   Not included: timerfd_settime64/timerfd_gettime64 (the 32-bit-time_t
   compatibility entry points; on LP64 targets glibc resolves the plain names
   to the 64-bit implementation already). nio4r, the gem that put this header
   on the list, reaches timerfd_create and timerfd_settime through libev's
   periodic-timer backend. */

#ifndef _RUBYCC_SYS_TIMERFD_H
#define _RUBYCC_SYS_TIMERFD_H

#include <time.h>

/* timerfd_create flags (measured, both arches). */
#define TFD_CLOEXEC  0x80000
#define TFD_NONBLOCK 0x800

/* timerfd_settime flags (measured, both arches). ABSTIME reads the value as
   an absolute time on the chosen clock; CANCEL_ON_SET additionally makes a
   discontinuous change of CLOCK_REALTIME cancel the timer, which is how a
   reader learns the wall clock was stepped. */
#define TFD_TIMER_ABSTIME       1
#define TFD_TIMER_CANCEL_ON_SET 2

int timerfd_create(int __clock_id, int __flags);
int timerfd_settime(int __fd, int __flags, const struct itimerspec *__new_value,
                    struct itimerspec *__old_value);
int timerfd_gettime(int __fd, struct itimerspec *__curr_value);

#endif /* _RUBYCC_SYS_TIMERFD_H */
