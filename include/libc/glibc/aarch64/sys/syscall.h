/* rubycc bundled <sys/syscall.h> (aarch64): the system-call numbers, as the
   SYS_ names callers pass to syscall(2). Provenance: clean room against the
   Linux kernel's aarch64 (asm-generic) system-call table, not derived from
   musl or glibc source. Every number below was printed from the glibc oracle
   under the cross toolchain and qemu (an ABI fact, not copied text -- see
   docs/HEADER-LICENSING.md sec. 4).

   Arch layer, necessarily: aarch64 uses the modern asm-generic numbering
   while x86-64 keeps its own historical table, and measured side by side the
   two disagree on essentially every entry -- SYS_read is 63 here and 0
   there, SYS_write 64 vs 1, SYS_openat 56 vs 257, SYS_epoll_ctl 21 vs 233.
   The x86-64 sibling carries the same set of names with its own numbers; the
   only entries where the two agree are the io_uring trio (425/426/427),
   allocated from the shared modern range. See that file's header note for
   the __NR_/SYS_ two-level spelling and the scope rule (only names present
   on both targets, so the legacy x86-64-only entry points -- open, poll,
   select, pipe, dup2 and their kin, which the asm-generic table simply does
   not have -- are left out on both sides).

   Like glibc's, this header does not declare syscall() itself; the prototype
   belongs to <unistd.h>. */

#ifndef _RUBYCC_SYS_SYSCALL_H
#define _RUBYCC_SYS_SYSCALL_H

/* Basic file I/O. */
#define __NR_read     63
#define __NR_write    64
#define __NR_close    57
#define __NR_lseek    62
#define __NR_openat   56
#define __NR_readlinkat 78
#define __NR_faccessat  48
#define __NR_ioctl    29
#define __NR_fcntl    25
#define __NR_pipe2    59
#define __NR_dup3     24

/* Filesystem statistics (the calls behind <sys/statfs.h>). */
#define __NR_statfs   43
#define __NR_fstatfs  44

/* Memory. */
#define __NR_mmap     222
#define __NR_mprotect 226
#define __NR_munmap   215

/* Processes, threads and signals. */
#define __NR_clone          220
#define __NR_exit           93
#define __NR_exit_group     94
#define __NR_getpid         172
#define __NR_gettid         178
#define __NR_kill           129
#define __NR_tgkill         131
#define __NR_rt_sigaction   134
#define __NR_rt_sigprocmask 135
#define __NR_futex          98
#define __NR_sched_yield    124
#define __NR_getcpu         168
#define __NR_membarrier     283
#define __NR_getrandom      278

/* Time. */
#define __NR_nanosleep       101
#define __NR_clock_gettime   113
#define __NR_clock_nanosleep 115

/* Event notification: the file-descriptor-based interfaces libev drives
   through raw syscalls when the libc wrappers are not available. */
#define __NR_epoll_create1     20
#define __NR_epoll_ctl         21
#define __NR_epoll_pwait       22
#define __NR_ppoll             73
#define __NR_pselect6          72
#define __NR_eventfd2          19
#define __NR_signalfd4         74
#define __NR_inotify_init1     26
#define __NR_inotify_add_watch 27
#define __NR_inotify_rm_watch  28
#define __NR_timerfd_create    85
#define __NR_timerfd_settime   86
#define __NR_timerfd_gettime   87

/* Asynchronous I/O: the legacy linux-aio calls and io_uring. These have no
   libc wrappers at all, which is why libev issues them by number. The aio
   five sit at 0..4 here, the very start of the asm-generic table. */
#define __NR_io_setup          0
#define __NR_io_destroy        1
#define __NR_io_submit         2
#define __NR_io_cancel         3
#define __NR_io_getevents      4
#define __NR_io_uring_setup    425
#define __NR_io_uring_enter    426
#define __NR_io_uring_register 427

/* Sockets. */
#define __NR_socket     198
#define __NR_setsockopt 208

/* The SYS_ spellings: aliases of the __NR_ names above, which is the
   relationship measured against the real header. */
#define SYS_read     __NR_read
#define SYS_write    __NR_write
#define SYS_close    __NR_close
#define SYS_lseek    __NR_lseek
#define SYS_openat   __NR_openat
#define SYS_readlinkat __NR_readlinkat
#define SYS_faccessat  __NR_faccessat
#define SYS_ioctl    __NR_ioctl
#define SYS_fcntl    __NR_fcntl
#define SYS_pipe2    __NR_pipe2
#define SYS_dup3     __NR_dup3

#define SYS_statfs   __NR_statfs
#define SYS_fstatfs  __NR_fstatfs

#define SYS_mmap     __NR_mmap
#define SYS_mprotect __NR_mprotect
#define SYS_munmap   __NR_munmap

#define SYS_clone          __NR_clone
#define SYS_exit           __NR_exit
#define SYS_exit_group     __NR_exit_group
#define SYS_getpid         __NR_getpid
#define SYS_gettid         __NR_gettid
#define SYS_kill           __NR_kill
#define SYS_tgkill         __NR_tgkill
#define SYS_rt_sigaction   __NR_rt_sigaction
#define SYS_rt_sigprocmask __NR_rt_sigprocmask
#define SYS_futex          __NR_futex
#define SYS_sched_yield    __NR_sched_yield
#define SYS_getcpu         __NR_getcpu
#define SYS_membarrier     __NR_membarrier
#define SYS_getrandom      __NR_getrandom

#define SYS_nanosleep       __NR_nanosleep
#define SYS_clock_gettime   __NR_clock_gettime
#define SYS_clock_nanosleep __NR_clock_nanosleep

#define SYS_epoll_create1     __NR_epoll_create1
#define SYS_epoll_ctl         __NR_epoll_ctl
#define SYS_epoll_pwait       __NR_epoll_pwait
#define SYS_ppoll             __NR_ppoll
#define SYS_pselect6          __NR_pselect6
#define SYS_eventfd2          __NR_eventfd2
#define SYS_signalfd4         __NR_signalfd4
#define SYS_inotify_init1     __NR_inotify_init1
#define SYS_inotify_add_watch __NR_inotify_add_watch
#define SYS_inotify_rm_watch  __NR_inotify_rm_watch
#define SYS_timerfd_create    __NR_timerfd_create
#define SYS_timerfd_settime   __NR_timerfd_settime
#define SYS_timerfd_gettime   __NR_timerfd_gettime

#define SYS_io_setup          __NR_io_setup
#define SYS_io_destroy        __NR_io_destroy
#define SYS_io_getevents      __NR_io_getevents
#define SYS_io_submit         __NR_io_submit
#define SYS_io_cancel         __NR_io_cancel
#define SYS_io_uring_setup    __NR_io_uring_setup
#define SYS_io_uring_enter    __NR_io_uring_enter
#define SYS_io_uring_register __NR_io_uring_register

#define SYS_socket     __NR_socket
#define SYS_setsockopt __NR_setsockopt

#endif /* _RUBYCC_SYS_SYSCALL_H */
