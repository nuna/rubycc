/* rubycc bundled <signal.h>: the signal numbers, sigset_t / siginfo_t /
   struct sigaction and the POSIX signalling calls. Provenance: clean room
   against the Linux kernel UAPI and the glibc signal ABI (bits/signum-generic.h,
   bits/signum-arch.h, bits/types/siginfo_t.h, bits/sigaction.h), not derived
   from musl or glibc source. The signal numbers, the SA_ flag values and the
   sigset_t / siginfo_t / struct sigaction layouts are that ABI reproduced as
   measured integer constants and measured field offsets (an ABI fact, not
   copied text -- see docs/HEADER-LICENSING.md), the same treatment as errno.h
   and fcntl.h. signal, raise, kill, sigaction, the sigset_t manipulators and
   kin are POSIX declarations whose bodies resolve from the host libc at link
   time (the same way errno.h's __errno_location does), including glibc's
   __libc_current_sigrtmin / __libc_current_sigrtmax behind SIGRTMIN / SIGRTMAX.
   Common layer: every signal number, SA_ flag and struct layout (sigset_t,
   siginfo_t and struct sigaction all included) is identical on x86-64 and
   aarch64 -- both use glibc's generic sigaction with the trailing sa_restorer
   and the 128-byte sigset_t / siginfo_t. */

#ifndef _RUBYCC_SIGNAL_H
#define _RUBYCC_SIGNAL_H

#ifndef _RUBYCC_SIG_ATOMIC_T
#define _RUBYCC_SIG_ATOMIC_T
typedef int sig_atomic_t;
#endif
#ifndef _RUBYCC_PID_T
#define _RUBYCC_PID_T
typedef int pid_t;
#endif
#ifndef _RUBYCC_UID_T
#define _RUBYCC_UID_T
typedef unsigned int uid_t;
#endif

/* The signal-handler function-pointer type. */
typedef void (*__sighandler_t)(int);

/* Handler sentinels: default action, ignore, and the error return of signal. */
#define SIG_DFL ((__sighandler_t) 0)
#define SIG_IGN ((__sighandler_t) 1)
#define SIG_ERR ((__sighandler_t) -1)

/* The signal set: 128 bytes, 8-byte aligned (measured, both arches). */
#ifndef _RUBYCC_SIGSET_T
#define _RUBYCC_SIGSET_T
typedef struct {
  unsigned long __val[16];
} sigset_t;
#endif

/* The value delivered with a queued signal (POSIX real-time signals). */
union sigval {
  int   sival_int;
  void *sival_ptr;
};

/* siginfo_t: 128 bytes, 8-byte aligned (measured). The common fields sit at
   fixed offsets ahead of the _sifields union; the union's largest member is the
   28-int pad that fixes the total size. The user-facing member names below are
   provided as macros onto the union arms, exactly as glibc's ABI exposes them,
   so si_pid / si_addr / si_band and kin resolve to the measured offsets. */
typedef struct {
  int si_signo;   /* offset 0 */
  int si_errno;   /* offset 4 */
  int si_code;    /* offset 8 */
  int __pad0;     /* offset 12 */
  union {
    int __pad[28];
    /* kill / SIGCHLD. */
    struct {
      pid_t si_pid;
      uid_t si_uid;
      int   si_status;
    } __sigchld;
    /* SIGSEGV / SIGBUS / SIGILL / SIGFPE. */
    struct {
      void *si_addr;
    } __sigfault;
    /* Real-time signal (sigqueue). */
    struct {
      pid_t si_pid;
      uid_t si_uid;
      union sigval si_value;
    } __rt;
    /* SIGPOLL / SIGIO. */
    struct {
      long si_band;
      int  si_fd;
    } __sigpoll;
  } _sifields;
} siginfo_t;

#define si_pid    _sifields.__sigchld.si_pid
#define si_uid    _sifields.__sigchld.si_uid
#define si_status _sifields.__sigchld.si_status
#define si_addr   _sifields.__sigfault.si_addr
#define si_value  _sifields.__rt.si_value
#define si_band   _sifields.__sigpoll.si_band
#define si_fd     _sifields.__sigpoll.si_fd

/* struct sigaction: 152 bytes, 8-byte aligned (measured, both arches). The
   handler union is first, then the 128-byte sa_mask, sa_flags at offset 136 and
   the trailing sa_restorer at offset 144. */
struct sigaction {
  union {
    __sighandler_t sa_handler;
    void (*sa_sigaction)(int, siginfo_t *, void *);
  } __sigaction_handler;
  sigset_t sa_mask;           /* offset 8 */
  int sa_flags;               /* offset 136 */
  void (*sa_restorer)(void);  /* offset 144 */
};

#define sa_handler   __sigaction_handler.sa_handler
#define sa_sigaction __sigaction_handler.sa_sigaction

/* Signal numbers (Linux kernel ABI). */
#define SIGHUP     1
#define SIGINT     2
#define SIGQUIT    3
#define SIGILL     4
#define SIGTRAP    5
#define SIGABRT    6
#define SIGBUS     7
#define SIGFPE     8
#define SIGKILL    9
#define SIGUSR1   10
#define SIGSEGV   11
#define SIGUSR2   12
#define SIGPIPE   13
#define SIGALRM   14
#define SIGTERM   15
#define SIGSTKFLT 16
#define SIGCHLD   17
#define SIGCONT   18
#define SIGSTOP   19
#define SIGTSTP   20
#define SIGTTIN   21
#define SIGTTOU   22
#define SIGURG    23
#define SIGXCPU   24
#define SIGXFSZ   25
#define SIGVTALRM 26
#define SIGPROF   27
#define SIGWINCH  28
#define SIGIO     29
#define SIGPWR    30
#define SIGSYS    31

/* Historical aliases. */
#define SIGIOT  SIGABRT
#define SIGCLD  SIGCHLD
#define SIGPOLL SIGIO

/* The signal-number ceiling and the real-time base. */
#define _NSIG 65
#define NSIG  _NSIG
#define __SIGRTMIN 32

/* The usable real-time signal range is a runtime property in glibc (the loader
   reserves the lowest few for its own use), so SIGRTMIN / SIGRTMAX are function
   calls, not constants; the bodies resolve from the host libc at link time. */
extern int __libc_current_sigrtmin(void);
extern int __libc_current_sigrtmax(void);
#define SIGRTMIN (__libc_current_sigrtmin())
#define SIGRTMAX (__libc_current_sigrtmax())

/* sigprocmask direction (POSIX). */
#define SIG_BLOCK   0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2

/* struct sigaction flags. */
#define SA_NOCLDSTOP 1
#define SA_NOCLDWAIT 2
#define SA_SIGINFO   4
#define SA_ONSTACK   0x08000000
#define SA_RESTART   0x10000000
#define SA_NODEFER   0x40000000
#define SA_RESETHAND 0x80000000

/* BSD aliases. */
#define SA_NOMASK  SA_NODEFER
#define SA_ONESHOT SA_RESETHAND

__sighandler_t signal(int __sig, __sighandler_t __handler);
int raise(int __sig);
int kill(pid_t __pid, int __sig);
int sigaction(int __sig, const struct sigaction *__act, struct sigaction *__oact);
int sigprocmask(int __how, const sigset_t *__set, sigset_t *__oset);
int sigemptyset(sigset_t *__set);
int sigfillset(sigset_t *__set);
int sigaddset(sigset_t *__set, int __signo);
int sigdelset(sigset_t *__set, int __signo);
int sigismember(const sigset_t *__set, int __signo);
int sigpending(sigset_t *__set);
int sigsuspend(const sigset_t *__set);

#endif /* _RUBYCC_SIGNAL_H */
