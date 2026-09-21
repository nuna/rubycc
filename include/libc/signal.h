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
   and the 128-byte sigset_t / siginfo_t. sigset_t's typedef guard and
   spelling (__sigset_t_defined / __sigset_t) are shared literally with
   <sys/select.h>, so a program that pulls in both headers -- directly or via
   ruby.h's <sys/select.h> include -- does not hit a conflicting redefinition,
   regardless of which header is included first.

   Coverage against glibc's <signal.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, x86-64 and aarch64, with tools/audit_bundled_headers.rb; table
   in docs/development/BUNDLED-HEADERS-COVERAGE.md).
   bundled-headers-coverage-audit-2 fixed this header's guards but classified
   none of its names; that is what the 2026-09-18 pass did. Added there: the
   si_code constants a handler installed with SA_SIGINFO switches on (SI_*,
   CLD_*, SEGV_*, BUS_*, ILL_*, FPE_*, TRAP_*, POLL_*), the siginfo_t members
   behind them, the alternate signal stack (stack_t, sigaltstack, SS_*), the
   waiting and queueing calls (sigwait, sigwaitinfo, sigtimedwait, sigqueue),
   killpg, siginterrupt, psignal/psiginfo, the two per-thread calls
   (pthread_kill, pthread_sigmask) with the pthread_t they take, and the sig_t
   / sighandler_t spellings of the handler type. Every value here was printed
   from the glibc oracle on x86-64 and, separately, on aarch64 under qemu
   (2026-09-18) and the two agreed on all of them, so the header stays in the
   common layer; every added prototype was written here and then placed next to
   glibc's own <signal.h> under gcc and aarch64-linux-gnu-gcc, where a
   conflicting redeclaration is an error (2026-09-18, both clean).
   Intentionally left out:
   omitted: struct sigevent sigevent_t SIGEV_NONE SIGEV_SIGNAL SIGEV_THREAD
   SIGEV_THREAD_ID sigev_notify_function sigev_notify_attributes -- the
   notification block of the POSIX per-process timers (the bundled <time.h>
   leaves those out for the same reason): it embeds a pthread_attr_t, and glibc
   shares its definition with <netdb.h> behind __sigevent_t_defined, so
   providing it means carrying both that layout and that guard.
   omitted: pthread_attr_t union pthread_attr_t pthread_barrier_t
   pthread_barrierattr_t pthread_cond_t pthread_condattr_t pthread_key_t
   pthread_mutex_t pthread_mutexattr_t pthread_once_t pthread_rwlock_t
   pthread_rwlockattr_t pthread_spinlock_t -- glibc shows the whole thread type
   set here only because struct sigevent above reaches for it; the bundled
   <pthread.h> is where they live (pthread_t is the exception, since
   pthread_kill and pthread_sigmask below are declared over it).
   omitted: SIGSTKSZ MINSIGSTKSZ -- not constants in glibc 2.34 and later
   (measured 2026-09-18: both expand to a sysconf call, because the signal
   frame's size depends on the CPU's register state), so a number written here
   could contradict the host; a caller of sigaltstack below picks its own size.
   omitted: sigblock sigsetmask siggetmask sigmask sigstack struct sigstack
   sigreturn gsignal ssignal sighold sigrelse sigignore sigpause sigset
   sysv_signal SIG_HOLD -- the BSD and System V signal interfaces, superseded
   by sigprocmask/sigaction and removed from POSIX; no corpus user.
   omitted: struct sigcontext sigcontext_struct struct _fpreg struct _fpstate
   struct _fpx_sw_bytes struct _fpxreg struct _xmmreg struct _xsave_hdr struct
   _xstate struct _ymmh_state FP_XSTATE_MAGIC1 FP_XSTATE_MAGIC2
   FP_XSTATE_MAGIC2_SIZE struct _aarch64_ctx struct esr_context struct
   extra_context struct fpsimd_context struct sve_context struct
   tpidr2_context struct za_context struct zt_context ESR_MAGIC EXTRA_MAGIC
   FPSIMD_MAGIC TPIDR2_MAGIC SVE_* ZA_* ZT_* sve_vl_from_vq sve_vl_valid
   sve_vq_from_vl -- the machine's saved register state inside a signal frame,
   which is where this header's two arches differ (the x86-64 FPU dump against
   the aarch64 SVE one). Reading it means walking a kernel UAPI layout rubycc
   does not model; a handler that wants the faulting address uses si_addr
   below. omitted: <sys/ucontext.h> <sys/procfs.h> <sys/user.h> -- the same
   saved state, reached as whole headers. omitted: pthread_sigqueue tgkill --
   GNU extensions for queueing to, and killing, one thread of a group; no
   corpus user. omitted: <unistd.h> <sys/types.h> <sys/select.h> <sys/time.h>
   <endian.h> <stddef.h> -- glibc pulls these in for pid_t, sigset_t's
   companions and size_t; each type this header needs is declared here
   directly, under the guard glibc shares for it. */

#ifndef _RUBYCC_SIGNAL_H
#define _RUBYCC_SIGNAL_H

/* As glibc's <signal.h> does: this brings <sys/cdefs.h>'s __THROW and kin.
   A glibc header that follows this one and relied on glibc's siginfo_t file
   to bring them (<sys/pidfd.h>) no longer gets that file once the siginfo_t
   guard below is set (measured 2026-09-14: "expected ';'" at the __THROW of
   sys/pidfd.h:31 without this include). */
#include <features.h>

#ifndef _RUBYCC_SIG_ATOMIC_T
#define _RUBYCC_SIG_ATOMIC_T
typedef int sig_atomic_t;
#endif
#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_PID_T
#define _RUBYCC_PID_T
typedef int pid_t;
#endif
#ifndef _RUBYCC_UID_T
#define _RUBYCC_UID_T
typedef unsigned int uid_t;
#endif

/* glibc's internal spellings of the member types of its own siginfo_t.
   Setting glibc's siginfo_t guard below makes a later glibc header skip
   glibc's siginfo_t file entirely -- including the internal types that file
   would have brought in -- and glibc's <sys/pidfd.h> declares pidfd_open over
   __pid_t on the strength of it (measured 2026-09-14: "expected ')'" at
   sys/pidfd.h:31 once the guard was set, before these typedefs were added).
   Each is the same scalar type glibc uses on both arches (measured, see
   <sys/types.h>), so glibc's own later definition is a compatible
   redefinition (C11 6.7p3). */
typedef int           __pid_t;
typedef unsigned int  __uid_t;
typedef long          __clock_t;

/* The signal-handler function-pointer type, under its three spellings:
   glibc's internal one, the BSD name (shown in gcc's default mode) and the
   GNU name. */
typedef void (*__sighandler_t)(int);
typedef __sighandler_t sig_t;
#ifdef __USE_GNU
typedef __sighandler_t sighandler_t;
#endif

/* Handler sentinels: default action, ignore, and the error return of signal. */
#define SIG_DFL ((__sighandler_t) 0)
#define SIG_IGN ((__sighandler_t) 1)
#define SIG_ERR ((__sighandler_t) -1)

/* The signal set: 128 bytes, 8-byte aligned (measured, both arches). The
   typedef guard and spelling (__sigset_t_defined / __sigset_t) are shared
   literally with <sys/select.h>, so the two headers do not redefine sigset_t
   regardless of which one is included first. */
#ifndef __sigset_t_defined
#define __sigset_t_defined 1
typedef struct { unsigned long __val[1024 / (8 * sizeof(unsigned long))]; } __sigset_t;
typedef __sigset_t sigset_t;
#endif

/* The value delivered with a queued signal (POSIX real-time signals):
   8 bytes, 8-byte aligned (measured, both arches). glibc defines this union
   in a second place too -- the file behind struct sigevent, which <netdb.h>
   reads under __USE_GNU -- and keeps the two to one definition with a shared
   guard that also covers its __sigval_t spelling (guard name and spelling
   read off `gcc -E -dD` on both arches, 2026-09-14). Setting that same
   guard here, and defining __sigval_t under it, is what lets <signal.h> and
   <netdb.h> share a _GNU_SOURCE unit in either order (GAPS BL; iodine's
   fio.c includes both). Before bundled-headers-coverage-audit-2 this union
   was unguarded, and rubycc rejected both orders with "redefinition of
   'union sigval'" where gcc accepts them. */
#ifndef ____sigval_t_defined
#define ____sigval_t_defined
union sigval {
  int   sival_int;
  void *sival_ptr;
};
typedef union sigval __sigval_t;
#endif

/* glibc's misc-level alias for the same union, behind the guard it keeps for
   that spelling alone. */
#ifndef __sigval_t_defined
#define __sigval_t_defined 1
typedef union sigval sigval_t;
#endif

/* siginfo_t: 128 bytes, 8-byte aligned (measured). The common fields sit at
   fixed offsets ahead of the _sifields union; the union's largest member is the
   28-int pad that fixes the total size. The user-facing member names below are
   provided as macros onto the union arms, exactly as glibc's ABI exposes them,
   so si_pid / si_addr / si_band and kin resolve to the measured offsets.
   glibc's own siginfo_t lives behind the guard set below, and other glibc
   headers than <signal.h> read that file too (<sys/pidfd.h> does). Without
   the shared guard each side's si_* member macros rewrote the other side's
   struct, and rubycc rejected <signal.h> next to <sys/pidfd.h> in both orders
   ("expected ';'", measured 2026-09-14 by tools/audit_bundled_headers.rb's
   guard probe; gcc accepts both). The macros sit inside the guard with the
   typedef: when glibc's definition arrives first, its own member macros are
   already in place and address the same measured offsets. */
#ifndef __siginfo_t_defined
#define __siginfo_t_defined 1
typedef struct {
  int si_signo;   /* offset 0 */
  int si_errno;   /* offset 4 */
  int si_code;    /* offset 8 */
  int __pad0;     /* offset 12 */
  union {
    int __pad[28];
    /* kill / SIGCHLD. The two CPU times are the child's, reported with
       SIGCHLD; their offsets (32 and 40) leave the padding glibc's own
       clock_t alignment leaves. */
    struct {
      pid_t si_pid;
      uid_t si_uid;
      int   si_status;
      __clock_t si_utime;
      __clock_t si_stime;
    } __sigchld;
    /* SIGSEGV / SIGBUS / SIGILL / SIGFPE. After the faulting address come the
       three mutually exclusive details the kernel may add: how much of the
       address is known to be right (SIGBUS hardware errors), the bounds that
       were violated, and the protection key that refused access. */
    struct {
      void *si_addr;
      short si_addr_lsb;
      union {
        struct {
          void *si_lower;
          void *si_upper;
        } __bounds;
        unsigned int si_pkey;
      } __first;
    } __sigfault;
    /* Real-time signal (sigqueue). The member is spelled as glibc spells it,
       si_sigval, so that the si_value / si_int / si_ptr macros below can name
       it without one macro rewriting another. */
    struct {
      pid_t si_pid;
      uid_t si_uid;
      union sigval si_sigval;
    } __rt;
    /* POSIX timer expiry. */
    struct {
      int si_timerid;
      int si_overrun;
      union sigval si_sigval;
    } __timer;
    /* SIGPOLL / SIGIO. */
    struct {
      long si_band;
      int  si_fd;
    } __sigpoll;
    /* SIGSYS: the system call a seccomp filter refused. */
    struct {
      void *si_call_addr;
      int   si_syscall;
      unsigned int si_arch;
    } __sigsys;
  } _sifields;
} siginfo_t;

#define si_pid       _sifields.__sigchld.si_pid
#define si_uid       _sifields.__sigchld.si_uid
#define si_status    _sifields.__sigchld.si_status
#define si_utime     _sifields.__sigchld.si_utime
#define si_stime     _sifields.__sigchld.si_stime
#define si_addr      _sifields.__sigfault.si_addr
#define si_addr_lsb  _sifields.__sigfault.si_addr_lsb
#define si_lower     _sifields.__sigfault.__first.__bounds.si_lower
#define si_upper     _sifields.__sigfault.__first.__bounds.si_upper
#define si_pkey      _sifields.__sigfault.__first.si_pkey
#define si_value     _sifields.__rt.si_sigval
#define si_int       _sifields.__rt.si_sigval.sival_int
#define si_ptr       _sifields.__rt.si_sigval.sival_ptr
#define si_timerid   _sifields.__timer.si_timerid
#define si_overrun   _sifields.__timer.si_overrun
#define si_band      _sifields.__sigpoll.si_band
#define si_fd        _sifields.__sigpoll.si_fd
#define si_call_addr _sifields.__sigsys.si_call_addr
#define si_syscall   _sifields.__sigsys.si_syscall
#define si_arch      _sifields.__sigsys.si_arch
#endif /* __siginfo_t_defined */

/* si_code: where the signal came from, and what kind of fault it reports.
   glibc gives these as enumerators; every value below was printed from the
   oracle on both arches (2026-09-18) and they agreed. The negative half is
   the "sent by" set (a queued signal, a timer, a message queue); SI_USER and
   SI_KERNEL are the two a handler checks most. */
#define SI_ASYNCNL   (-60)
#define SI_DETHREAD  (-7)
#define SI_TKILL     (-6)
#define SI_SIGIO     (-5)
#define SI_ASYNCIO   (-4)
#define SI_MESGQ     (-3)
#define SI_TIMER     (-2)
#define SI_QUEUE     (-1)
#define SI_USER      0
#define SI_KERNEL    0x80

/* SIGILL. */
#define ILL_ILLOPC   1
#define ILL_ILLOPN   2
#define ILL_ILLADR   3
#define ILL_ILLTRP   4
#define ILL_PRVOPC   5
#define ILL_PRVREG   6
#define ILL_COPROC   7
#define ILL_BADSTK   8
#define ILL_BADIADDR 9

/* SIGFPE. */
#define FPE_INTDIV   1
#define FPE_INTOVF   2
#define FPE_FLTDIV   3
#define FPE_FLTOVF   4
#define FPE_FLTUND   5
#define FPE_FLTRES   6
#define FPE_FLTINV   7
#define FPE_FLTSUB   8
#define FPE_FLTUNK   14
#define FPE_CONDTRAP 15

/* SIGSEGV. */
#define SEGV_MAPERR  1
#define SEGV_ACCERR  2
#define SEGV_BNDERR  3
#define SEGV_PKUERR  4
#define SEGV_ACCADI  5
#define SEGV_ADIDERR 6
#define SEGV_ADIPERR 7
#define SEGV_MTEAERR 8
#define SEGV_MTESERR 9
#define SEGV_CPERR   10

/* SIGBUS. */
#define BUS_ADRALN    1
#define BUS_ADRERR    2
#define BUS_OBJERR    3
#define BUS_MCEERR_AR 4
#define BUS_MCEERR_AO 5

/* SIGTRAP. */
#define TRAP_BRKPT  1
#define TRAP_TRACE  2
#define TRAP_BRANCH 3
#define TRAP_HWBKPT 4
#define TRAP_UNK    5

/* SIGCHLD: what became of the child. */
#define CLD_EXITED    1
#define CLD_KILLED    2
#define CLD_DUMPED    3
#define CLD_TRAPPED   4
#define CLD_STOPPED   5
#define CLD_CONTINUED 6

/* SIGPOLL / SIGIO. */
#define POLL_IN  1
#define POLL_OUT 2
#define POLL_MSG 3
#define POLL_ERR 4
#define POLL_PRI 5
#define POLL_HUP 6

/* The alternate stack a handler can be run on (sigaltstack). Measured 24
   bytes, 8-byte aligned, with ss_sp at 0, ss_flags at 8 and ss_size at 16 on
   both arches (2026-09-18). glibc's own guard, so a glibc header that defines
   stack_t for itself does not collide with this one. */
#ifndef __stack_t_defined
#define __stack_t_defined 1
typedef struct {
  void  *ss_sp;
  int    ss_flags;
  size_t ss_size;
} stack_t;
#endif

/* ss_flags: the stack is in use / is not to be used at all. */
#define SS_ONSTACK 1
#define SS_DISABLE 2

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

/* BSD aliases. SA_INTERRUPT is the historical opposite of SA_RESTART and has
   no effect on Linux; its value (0x20000000) was printed from the oracle on
   both arches. */
#define SA_NOMASK    SA_NODEFER
#define SA_ONESHOT   SA_RESETHAND
#define SA_STACK     SA_ONSTACK
#define SA_INTERRUPT 0x20000000

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

/* Waiting for a signal instead of being interrupted by one. sigtimedwait takes
   a deadline, so it needs <time.h>'s struct timespec, shared here under the
   guards both headers use. */
#ifndef _RUBYCC_TIME_T
#define _RUBYCC_TIME_T
typedef long time_t;
#endif
#ifndef _STRUCT_TIMESPEC
#define _STRUCT_TIMESPEC 1
struct timespec {
  time_t tv_sec;
  long   tv_nsec;
};
#endif

int sigwait(const sigset_t *__set, int *__sig);
int sigwaitinfo(const sigset_t *__set, siginfo_t *__info);
int sigtimedwait(const sigset_t *__set, siginfo_t *__info, const struct timespec *__timeout);
/* Queue a signal together with a value the handler reads out of si_value. */
int sigqueue(pid_t __pid, int __sig, const union sigval __value);

int killpg(pid_t __pgrp, int __sig);
int siginterrupt(int __sig, int __interrupt);
void psignal(int __sig, const char *__s);
void psiginfo(const siginfo_t *__info, const char *__s);
int sigaltstack(const stack_t *__ss, stack_t *__oss);

/* The per-thread half of the interface. pthread_t is the same scalar the
   bundled <pthread.h> defines, so the two declarations are a compatible
   repetition (C11 6.7p3); glibc declares these two calls here as well, and a
   source that includes only <signal.h> expects to see them. */
#ifndef _RUBYCC_PTHREAD_T
#define _RUBYCC_PTHREAD_T
typedef unsigned long pthread_t;
#endif
int pthread_kill(pthread_t __th, int __sig);
int pthread_sigmask(int __how, const sigset_t *__newmask, sigset_t *__oldmask);

#ifdef __USE_GNU
int sigisemptyset(const sigset_t *__set);
int sigandset(sigset_t *__set, const sigset_t *__left, const sigset_t *__right);
int sigorset(sigset_t *__set, const sigset_t *__left, const sigset_t *__right);
#endif

#endif /* _RUBYCC_SIGNAL_H */
