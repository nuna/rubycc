/* rubycc bundled <sys/syscall.h> (x86-64): the system-call numbers, as the
   SYS_ names callers pass to syscall(2). Provenance: clean room against the
   Linux kernel's x86-64 system-call table, not derived from musl or glibc
   source. Every number below was printed from the glibc oracle (an ABI fact,
   not copied text -- see docs/HEADER-LICENSING.md sec. 4).

   Arch layer, necessarily. glibc's <sys/syscall.h> is a thin shim that pulls
   in <asm/unistd.h> and then defines each SYS_ name as an alias of the
   corresponding __NR_ name, and __NR_ numbering is per-architecture: x86-64
   carries its own historical table while aarch64 uses the modern
   asm-generic one. Measured side by side, the two disagree on essentially
   every entry -- SYS_read is 0 here and 63 there, SYS_write 1 vs 64,
   SYS_openat 257 vs 56, SYS_epoll_ctl 233 vs 21 -- so there is no common
   layer to be had and this header has an aarch64 sibling. The only
   agreements found were the io_uring trio (425/426/427), which entered the
   kernel late enough to be allocated from the shared modern range. The
   __NR_/SYS_ two-level spelling is reproduced rather than collapsed because
   callers do write __NR_ names directly, and because it is what makes the
   `#if SYS_foo` feature tests third-party code performs behave as they do
   against the real header.

   Scope: this is deliberately NOT the whole table. glibc's copy is generated
   from the kernel headers and runs to several hundred entries; reproducing
   all of them by measurement would add a large surface with no consumer and
   would need re-measuring on every kernel release. The set below is (a)
   everything nio4r, the gem that put this header on the list, can reach --
   libev routes clock_gettime, the eventfd/signalfd/inotify/epoll creation
   calls, and its linuxaio and io_uring backends through raw syscall numbers
   -- and (b) a representative core of process, memory, file and socket
   calls, chosen so the numbering itself is verifiable across a wide span of
   the table rather than at one end of it.

   One consequence of the scope rule used here is worth stating: only names
   that exist on BOTH targets are defined, so the two arch copies differ in
   their numbers and in nothing else. That excludes the legacy x86-64-only
   entry points (open, poll, select, pipe, dup2, access, unlink, rename,
   creat, fork, and their kin), for which the asm-generic table aarch64 uses
   has no entry at all -- their callers are expected to use the *at / *2 /
   p* replacements that are listed below. No corpus census hit reaches any of
   them through syscall(2).

   Note that this header intentionally does not declare syscall() itself;
   measured, neither does glibc's -- the prototype lives in <unistd.h>. */

#ifndef _RUBYCC_SYS_SYSCALL_H
#define _RUBYCC_SYS_SYSCALL_H

/* Basic file I/O. */
#define __NR_read     0
#define __NR_write    1
#define __NR_close    3
#define __NR_lseek    8
#define __NR_openat   257
#define __NR_readlinkat 267
#define __NR_faccessat  269
#define __NR_ioctl    16
#define __NR_fcntl    72
#define __NR_pipe2    293
#define __NR_dup3     292

/* Filesystem statistics (the calls behind <sys/statfs.h>). */
#define __NR_statfs   137
#define __NR_fstatfs  138

/* Memory. */
#define __NR_mmap     9
#define __NR_mprotect 10
#define __NR_munmap   11

/* Processes, threads and signals. */
#define __NR_clone          56
#define __NR_exit           60
#define __NR_exit_group     231
#define __NR_getpid         39
#define __NR_gettid         186
#define __NR_kill           62
#define __NR_tgkill         234
#define __NR_rt_sigaction   13
#define __NR_rt_sigprocmask 14
#define __NR_futex          202
#define __NR_sched_yield    24
#define __NR_getcpu         309
#define __NR_membarrier     324
#define __NR_getrandom      318

/* Time. */
#define __NR_nanosleep       35
#define __NR_clock_gettime   228
#define __NR_clock_nanosleep 230

/* Event notification: the file-descriptor-based interfaces libev drives
   through raw syscalls when the libc wrappers are not available. */
#define __NR_epoll_create1     291
#define __NR_epoll_ctl         233
#define __NR_epoll_pwait       281
#define __NR_ppoll             271
#define __NR_pselect6          270
#define __NR_eventfd2          290
#define __NR_signalfd4         289
#define __NR_inotify_init1     294
#define __NR_inotify_add_watch 254
#define __NR_inotify_rm_watch  255
#define __NR_timerfd_create    283
#define __NR_timerfd_settime   286
#define __NR_timerfd_gettime   287

/* Asynchronous I/O: the legacy linux-aio calls and io_uring. These have no
   libc wrappers at all, which is why libev issues them by number. */
#define __NR_io_setup          206
#define __NR_io_destroy        207
#define __NR_io_getevents      208
#define __NR_io_submit         209
#define __NR_io_cancel         210
#define __NR_io_uring_setup    425
#define __NR_io_uring_enter    426
#define __NR_io_uring_register 427

/* Sockets. */
#define __NR_socket     41
#define __NR_setsockopt 54

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
