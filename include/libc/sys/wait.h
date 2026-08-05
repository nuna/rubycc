/* rubycc bundled <sys/wait.h>: waiting for process state changes (POSIX.1).
   Provenance: clean room against the POSIX public interface and the Linux
   kernel's wait-status encoding, not derived from musl or glibc source. Two
   kinds of ABI fact are reproduced here, both measured rather than copied
   (see docs/HEADER-LICENSING.md sec. 4):

   (a) The option flags (WNOHANG/WUNTRACED/WCONTINUED and the waitid
       WEXITED/WSTOPPED/WNOWAIT set, plus glibc's __WALL family) and the
       idtype_t enumerators, printed from the glibc oracle on x86-64 and on
       aarch64 (cross gcc + qemu); the two agreed on every value.

   (b) The wait-status *encoding* behind WIFEXITED and kin. Rather than copy
       glibc's macro bodies, rubycc re-derived the encoding from observed
       behaviour and then proved the re-derivation exact: a probe compared
       rubycc's formula against the host glibc macro for *every* one of the
       2^32 int status values, for all eight macros, on both x86-64 and
       aarch64, and found zero mismatches (including the exact non-boolean
       return of WCOREDUMP, which yields the 0x80 flag bit rather than 1).
       The formulas below are therefore rubycc's own spelling of a measured
       fact; they are also written to evaluate their argument exactly once,
       which glibc's differently-shaped bodies also do. That exhaustive
       comparison had a glibc oracle; on musl the harness measured a
       difference in WIFSTOPPED alone, so that macro (and only that one) has a
       musl branch below.

   Common layer: every value and every macro result above is identical on
   x86-64 and aarch64, so this header is arch-neutral (unlike sys/epoll.h,
   whose struct packing differs between the two).

   <signal.h> is included for siginfo_t, which waitid's third parameter needs:
   glibc reaches for its own bits/types/siginfo_t.h here under
   __USE_XOPEN_EXTENDED, and rubycc has no split types layer to reach for, so
   it includes the whole bundled <signal.h> (the same way the bundled
   <string.h> reaches for <strings.h> to reproduce glibc's __USE_MISC
   pull-in). pid_t arrives with it.

   Not included: wait3/wait4 (they take a `struct rusage *`, which would mean
   either cross-including <sys/resource.h> or duplicating struct rusage under
   a shared guard, and no corpus census hit needs them -- nio4r, the gem that
   put this header on the list, reaches only waitpid and the status macros),
   the obsolete `union wait` overloads, and WAIT_ANY/WAIT_MYPGRP. */

#ifndef _RUBYCC_SYS_WAIT_H
#define _RUBYCC_SYS_WAIT_H

#include <signal.h>

#ifndef _RUBYCC_ID_T
#define _RUBYCC_ID_T
typedef unsigned int id_t;
#endif

/* waitpid / waitid options (measured, both arches). */
#define WNOHANG    1
#define WUNTRACED  2
#define WSTOPPED   2
#define WEXITED    4
#define WCONTINUED 8
#define WNOWAIT    0x01000000

/* glibc's Linux-specific selectors for which children to wait on. */
#define __WNOTHREAD 0x20000000
#define __WALL      0x40000000
#define __WCLONE    0x80000000

/* The wait-status encoding (Linux kernel ABI), re-derived from measurement:
     bits 0..6   terminating signal; 0 means "exited normally" and the
                 reserved value 0x7f means "stopped"
     bit 7       core-dump flag
     bits 8..15  exit code, or the stopping signal when bits 0..7 are 0x7f
     0xffff      the whole word, meaning "continued"
   Each macro evaluates its argument once, WIFSTOPPED's musl branch excepted
   (see its own note). WIFSIGNALED's unsigned compare is
   the single-evaluation way to say "the signal field is neither 0 nor the
   0x7f stopped marker": subtracting one wraps the 0 case past the range. */
#define WTERMSIG(status)     ((status) & 0x7f)
#define WEXITSTATUS(status)  (((status) & 0xff00) >> 8)
#define WSTOPSIG(status)     (((status) & 0xff00) >> 8)
#define WIFEXITED(status)    (((status) & 0x7f) == 0)
#define WIFSIGNALED(status)  ((unsigned)(((status) & 0x7f) - 1) < 0x7eu)
/* WIFSTOPPED is the one status macro the two C libraries answer differently:
   musl also requires the stopping-signal byte to be non-zero, so the bare
   0x007f word is not "stopped" there. Measured on the four status words the
   ABI harness probes (docs/STEPS.md Step 193; glibc's side on this host):
     status   glibc  musl
     0x0000     0      0
     0x007f     1      0
     0x137f     1      1
     0xffff     0      0
   The musl form below is the narrowest formula that reproduces all four; no
   other status word was measured on musl, so nothing stronger is claimed.
   Unlike every other macro here it names its argument twice -- there is no
   single-evaluation spelling of "low byte is 0x7f and high byte is not zero"
   that does not go through a helper -- so an argument with a side effect is
   evaluated twice under musl. */
#if defined(__RUBYCC_LIBC_MUSL__)
#define WIFSTOPPED(status)   (((status) & 0xff) == 0x7f && ((status) & 0xff00) != 0)
#else
#define WIFSTOPPED(status)   (((status) & 0xff) == 0x7f)
#endif
#define WIFCONTINUED(status) ((status) == 0xffff)
#define WCOREDUMP(status)    ((status) & 0x80)

/* waitid's id interpretation. Measured: a 4-byte, 4-byte-aligned enum whose
   enumerators run 0, 1, 2 (and 3 for the recent P_PIDFD addition). */
typedef enum {
  P_ALL   = 0,
  P_PID   = 1,
  P_PGID  = 2,
  P_PIDFD = 3
} idtype_t;

/* siginfo_t::si_code values for SIGCHLD, which is how waitid reports what
   happened (measured, both arches). glibc keeps these in the same
   bits/siginfo-consts.h that both <signal.h> and <sys/wait.h> reach for; the
   bundled <signal.h> does not define them, so they live here, next to the one
   call that needs them. */
#define CLD_EXITED    1
#define CLD_KILLED    2
#define CLD_DUMPED    3
#define CLD_TRAPPED   4
#define CLD_STOPPED   5
#define CLD_CONTINUED 6

pid_t wait(int *__status);
pid_t waitpid(pid_t __pid, int *__status, int __options);
int   waitid(idtype_t __idtype, id_t __id, siginfo_t *__infop, int __options);

#endif /* _RUBYCC_SYS_WAIT_H */
