/* rubycc bundled <unistd.h>: the POSIX system-call declarations (POSIX.1).
   Derived from musl's <unistd.h> declaration set; the few ABI-typed names
   (ssize_t, off_t, pid_t, ...) reuse the shared _RUBYCC_* guards and carry the
   LP64 widths. The STDIN_FILENO / *_OK values are the standard ones. Common
   layer: the surface is declarations plus universal constants.

   Coverage against glibc's <unistd.h> under _GNU_SOURCE (audited 2026-09-15,
   glibc 2.39, x86-64 and aarch64, with tools/audit_bundled_headers.rb; table
   in docs/development/BUNDLED-HEADERS-COVERAGE.md). Visibility rule, the
   same one bundled-headers-coverage-audit-2 set for stdlib.h/sched.h: a name
   glibc shows in gcc's default mode (_DEFAULT_SOURCE and below) is declared
   unconditionally, as this header always has; a name glibc shows only under
   _GNU_SOURCE is declared under __USE_GNU too (hence the <features.h>
   include added here). bundled-unistd-process-group-1 (GAPS BU) added the
   process-group and session functions ruby-termios 1.1.0's tcgetpgrp needs
   (getpgrp/setpgid/getpgid/setsid/getsid/tcgetpgrp/tcsetpgrp/setpgrp),
   together with the rest of the plain POSIX/GNU declarations judged
   plausible for a gem's C extension to call directly (getgroups,
   getlogin/getlogin_r, fchdir, chroot, daemon, nice, sync, syncfs, lockf and
   its F_LOCK/F_TEST/F_TLOCK/F_ULOCK commands, getentropy, dup3, pipe2,
   environ, gettid) and the SEEK_DATA/SEEK_HOLE lseek() origins and the
   TEMP_FAILURE_RETRY retry-on-EINTR macro. Every added prototype was
   verified against glibc's own <unistd.h> by redeclaring it immediately
   before `#include <unistd.h>` under gcc (a conflicting redeclaration is a
   hard error) on both x86-64 and aarch64, and F_LOCK/F_ULOCK/F_TLOCK/F_TEST/
   SEEK_DATA/SEEK_HOLE's values were measured with `gcc -E -dM` on both and
   agree (0/1/2/3, 3/4). Intentionally left out:
   omitted: execle fexecve execveat execvpe -- the exec family's variant
   members, already covered by execv/execvp/execve/execl/execlp above, no
   corpus user for the rest.
   omitted: faccessat fchownat lchown linkat readlinkat symlinkat unlinkat --
   the openat-relative filesystem calls, no corpus user.
   omitted: setegid seteuid setregid setreuid setresgid setresuid getresgid
   getresuid -- privilege-management calls: the corpus's privilege-drop code
   goes through Ruby's Process::Sys, which the interpreter implements as a
   direct syscall, not through a gem's C extension calling this header.
   omitted: gethostid socklen_t swab -- rarely used, and socklen_t is already
   declared by the bundled <sys/socket.h>.
   omitted: L_INCR L_SET L_XTND -- superseded lseek() whence aliases,
   SEEK_SET/SEEK_CUR/SEEK_END above are the ones every caller uses.
   omitted: acct closefrom crypt endusershell getdomainname getdtablesize
   getpass getusershell getwd profil revoke setdomainname sethostid
   sethostname setlogin setusershell ttyslot ualarm vfork vhangup -- obsolete
   or rarely used, no corpus user.
   omitted: CLOSE_RANGE_CLOEXEC CLOSE_RANGE_UNSHARE close_range -- glibc 2.34
   and later only, declaring them would promise a symbol an older host glibc
   does not have (the same reasoning stdlib.h's arc4random* omission uses).
   omitted: copy_file_range eaccess euidaccess get_current_dir_name
   group_member -- no corpus user.
   omitted: ftruncate64 lockf64 lseek64 off64_t pread64 pwrite64 truncate64
   -- LFS64 aliases, identical to the unsuffixed calls on an LP64 target, no
   corpus user.
   omitted: <stddef.h> -- only size_t is needed, and it is declared here
   directly.

   audit-reserved-public-macros-1 (GAPS BX) made the audit count the reserved
   spellings the standards hand to programs, which is most of what this header
   publishes: the query arguments of sysconf/confstr/pathconf and the POSIX /
   X-Open option and version macros. _POSIX_VDISABLE was added below for
   ruby-termios 1.1.0; the families it did not bring in are listed next, and
   all of them rest on the same judgment the _SC_/_CS_/_PC_ comments in the
   body state -- each of these names is a *host-numbered* or *host-valued*
   constant that has to be re-measured on both arches at every glibc release,
   so they are added one consumer at a time rather than en bloc, and an
   unconsumed one is pure surface.
   omitted: _SC_* -- sysconf() arguments; the twelve the corpus asks for are
   defined in the body with their measured numbers, and the rest of glibc's
   <bits/confname.h> enumeration has no corpus caller.
   omitted: _CS_* _PC_* -- confstr()/pathconf() arguments; _CS_PATH and
   _PC_PIPE_BUF are defined in the body (etc's own test suite exercises
   exactly those two), the rest has no corpus caller.
   omitted: _POSIX_* _POSIX2_* _XOPEN_* _XBS5_* _LFS_* _LFS64_* -- the POSIX
   and X/Open option, version and programming-environment macros a program
   tests with #if. The three the corpus needs are in the body
   (_POSIX_MONOTONIC_CLOCK for stackprof, _POSIX_TIMERS, _POSIX_VDISABLE for
   ruby-termios). The rest state what the *host's* libc supports, so rubycc
   answering them from a bundled header would be asserting something about a
   libc it does not ship; where a gem's #if arm matters, adding the single
   macro with its measured value (as those three were) is the fix.
   omitted: _Fork -- POSIX.1-2024's async-signal-safe fork(), which the host
   libc exports as _Fork@@GLIBC_2.34 on both arches (measured with `nm -D
   --with-symbol-versions` on 2026-09-16), so declaring it would promise a
   symbol an older host glibc does not have (the same reasoning close_range
   uses above); no corpus user either. */

#ifndef _RUBYCC_UNISTD_H
#define _RUBYCC_UNISTD_H

#include <features.h>

#ifndef NULL
#define NULL ((void*)0)
#endif

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_SSIZE_T
#define _RUBYCC_SSIZE_T
typedef long ssize_t;
#endif
#ifndef _RUBYCC_OFF_T
#define _RUBYCC_OFF_T
typedef long off_t;
#endif
#ifndef _RUBYCC_PID_T
#define _RUBYCC_PID_T
typedef int pid_t;
#endif
#ifndef _RUBYCC_UID_T
#define _RUBYCC_UID_T
typedef unsigned int uid_t;
#endif
#ifndef _RUBYCC_GID_T
#define _RUBYCC_GID_T
typedef unsigned int gid_t;
#endif
#ifndef _RUBYCC_USECONDS_T
#define _RUBYCC_USECONDS_T
typedef unsigned int useconds_t;
#endif
#ifndef _RUBYCC_INTPTR_T
#define _RUBYCC_INTPTR_T
typedef long intptr_t;
#endif

#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

#define F_OK 0
#define X_OK 1
#define W_OK 2
#define R_OK 4

/* lockf() commands (GAPS BU), measured with `gcc -E -dM <unistd.h>` under
   _GNU_SOURCE on both x86-64 and aarch64 (0/1/2/3, agreeing). */
#define F_ULOCK 0
#define F_LOCK  1
#define F_TLOCK 2
#define F_TEST  3

/* POSIX option macro: the monotonic clock option is supported, and the two C
   libraries say so with different strengths. glibc's value is 0, meaning
   support must still be confirmed at runtime via
   sysconf(_SC_MONOTONIC_CLOCK); musl's is 200809, the standard revision it
   supports unconditionally. Both measured with the ABI harness, glibc's on
   this host and musl's on the CI musl run (docs/STEPS.md Step 193). Needed for
   stackprof: it branches on `#ifdef _POSIX_MONOTONIC_CLOCK`, and the #else arm
   it would otherwise take is upstream dead code containing a real syntax
   error, so a toolchain that never defines this macro cannot build stackprof
   at all -- and both values above define it. Scope: only this one _POSIX_*
   macro is added here, not the full POSIX options set (same scoping judgment
   as sys/syscall.h's non-exhaustive number list). */
#if defined(__RUBYCC_LIBC_MUSL__)
#define _POSIX_MONOTONIC_CLOCK 200809
#else
#define _POSIX_MONOTONIC_CLOCK 0
#endif
#define _POSIX_TIMERS 200809L

/* _POSIX_VDISABLE: the c_cc[] entry value that disables a terminal special
   character, i.e. what a caller stores into termios.c_cc[VINTR] to turn that
   character off. It is POSIX's, not glibc's, and a program writes it directly:
   ruby-termios 1.1.0 publishes it as Termios::POSIX_VDISABLE
   (ext/termios.c:759), which is where that gem stopped once
   bundled-unistd-process-group-1 had cleared tcgetpgrp (measured 2026-09-16).
   Value measured with `gcc -E -dM -D_GNU_SOURCE <unistd.h>` on x86-64 and
   aarch64 on 2026-09-16: glibc writes it as a character constant worth 0 on
   both, so the constant is arch-independent and lives in this common layer.
   No musl toolchain was available on that host to measure musl's value; the
   ABI harness checks this macro against whichever libc it runs on
   (test/test_header_abi.rb's UNISTD case), so a disagreement surfaces there
   rather than as a wrong constant in a built gem. */
#define _POSIX_VDISABLE 0

#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif
#ifdef __USE_GNU
/* Sparse-file lseek() origins (GAPS BU): seek to the next byte containing
   data, or the next hole, at or after the given offset. Values measured with
   `gcc -E -dM <unistd.h>` under _GNU_SOURCE on both x86-64 and aarch64
   (3/4, agreeing). */
#define SEEK_DATA 3
#define SEEK_HOLE 4
#endif

int     access(const char *__name, int __type);
int     close(int __fd);
ssize_t read(int __fd, void *__buf, size_t __nbytes);
ssize_t write(int __fd, const void *__buf, size_t __n);
/* Positioned I/O at __offset, without moving the file's own offset. */
ssize_t pread(int __fd, void *__buf, size_t __nbytes, off_t __offset);
ssize_t pwrite(int __fd, const void *__buf, size_t __n, off_t __offset);
off_t   lseek(int __fd, off_t __offset, int __whence);
int     pipe(int __pipedes[2]);
#ifdef __USE_GNU
/* pipe() with O_CLOEXEC/O_NONBLOCK set atomically (GAPS BU); event-loop
   gems use it to avoid a fork() racing a plain fcntl(F_SETFD, FD_CLOEXEC). */
int     pipe2(int __pipedes[2], int __flags);
#endif
int     dup(int __fd);
int     dup2(int __fd, int __fd2);
#ifdef __USE_GNU
/* dup2() with O_CLOEXEC set atomically on the new descriptor (GAPS BU). */
int     dup3(int __fd, int __fd2, int __flags);
#endif
int     unlink(const char *__name);
int     rmdir(const char *__path);
int     chdir(const char *__path);
/* fchdir()/chroot() (GAPS BU): the fd-relative and root-relative companions
   of chdir(), for callers that already hold an open directory descriptor or
   that sandbox themselves into a subtree. */
int     fchdir(int __fd);
int     chroot(const char *__path);
char   *getcwd(char *__buf, size_t __size);
int     fsync(int __fd);
/* Linux exposes fdatasync() from <unistd.h>; bootsnap probes it and then calls
   it when flushing its cache. Keep the declaration in the bundled surface so
   the probe and the extension compile against the same measured ABI. */
int     fdatasync(int __fd);
void    sync(void);
#ifdef __USE_GNU
/* sync(), narrowed to the filesystem __fd lives on (GAPS BU). */
int     syncfs(int __fd);
#endif
int     ftruncate(int __fd, off_t __length);
int     truncate(const char *__file, off_t __length);
/* Advisory record locking over a byte range of __fd (GAPS BU), the POSIX
   companion of the F_LOCK/F_TLOCK/F_ULOCK/F_TEST commands above. */
int     lockf(int __fd, int __cmd, off_t __len);
int     isatty(int __fd);
char   *ttyname(int __fd);
/* ttyname's POSIX reentrant pair: the caller supplies the buffer instead of
   getting back a pointer into static storage. */
int     ttyname_r(int __fd, char *__buf, size_t __buflen);
int     link(const char *__from, const char *__to);
int     symlink(const char *__from, const char *__to);
ssize_t readlink(const char *__restrict __path, char *__restrict __buf, size_t __len);
int     chown(const char *__file, uid_t __owner, gid_t __group);
int     fchown(int __fd, uid_t __owner, gid_t __group);
int     gethostname(char *__name, size_t __len);
int     getpagesize(void);
/* Fills __buffer with __length bytes straight from the kernel's entropy pool
   (GAPS BU); the sysrandom gem wraps this call directly. */
int     getentropy(void *__buffer, size_t __length);

pid_t   fork(void);
pid_t   getpid(void);
pid_t   getppid(void);
#ifdef __USE_GNU
/* The calling thread's kernel id, distinct from getpid()'s process id
   (GAPS BU); logging libraries tag messages with it. */
pid_t   gettid(void);
#endif
/* Process-group and session functions (GAPS BU): tcgetpgrp/tcsetpgrp query
   and set a terminal's foreground process group, and the rest manage a
   process's own group and session membership. ruby-termios 1.1.0's
   termios.c calls tcgetpgrp() right after the tcflow() bundled-headers-
   coverage-audit-2 (GAPS BA) added. */
pid_t   getpgrp(void);
int     setpgid(pid_t __pid, pid_t __pgid);
pid_t   getpgid(pid_t __pid);
pid_t   setsid(void);
pid_t   getsid(pid_t __pid);
/* The obsolete X/Open zero-argument spelling of setpgid(getpid(), 0), kept
   for callers that still use it. */
int     setpgrp(void);
pid_t   tcgetpgrp(int __fd);
int     tcsetpgrp(int __fd, pid_t __pgrp);
/* GNU's raw system-call escape hatch; libev's io_uring backend uses it when
   the libc wrapper is not available. */
long    syscall(long __number, ...);
uid_t   getuid(void);
uid_t   geteuid(void);
gid_t   getgid(void);
gid_t   getegid(void);
int     setuid(uid_t __uid);
int     setgid(gid_t __gid);
/* Fills __list with up to __size of the calling process's supplementary
   group ids (GAPS BU). */
int     getgroups(int __size, gid_t __list[]);
/* The login name associated with the calling process's controlling terminal
   (GAPS BU), and its POSIX reentrant pair. */
char   *getlogin(void);
int     getlogin_r(char *__name, size_t __size);

unsigned int alarm(unsigned int __seconds);
unsigned int sleep(unsigned int __seconds);
int     usleep(useconds_t __useconds);
int     pause(void);
/* Adjusts the calling process's nice value by __inc (GAPS BU). */
int     nice(int __inc);
/* Forks into a detached background process (GAPS BU); server gems call it
   to daemonize instead of hand-rolling the fork/setsid/chdir dance. */
int     daemon(int __nochdir, int __noclose);

int     execv(const char *__path, char *const __argv[]);
int     execvp(const char *__file, char *const __argv[]);
int     execve(const char *__path, char *const __argv[], char *const __envp[]);
int     execl(const char *__path, const char *__arg, ...);
int     execlp(const char *__file, const char *__arg, ...);
/* sysconf() is answered by the host's runtime libc, so its __name argument
   must match the host's own numbering (glibc's <bits/confname.h> enum), not
   a value rubycc invents. _SC_PAGE_SIZE is just an alias of _SC_PAGESIZE. */
#define _SC_ARG_MAX          0
#define _SC_CHILD_MAX        1
#define _SC_CLK_TCK          2
#define _SC_NGROUPS_MAX      3
#define _SC_OPEN_MAX         4
#define _SC_PAGESIZE         30
#define _SC_PAGE_SIZE        _SC_PAGESIZE
/* _SC_IOV_MAX answers how many struct iovec a single writev may carry; kgio's
   writev.c asks for it once and caches the answer to size its own batches. */
#define _SC_IOV_MAX          60
#define _SC_NPROCESSORS_CONF 83
#define _SC_NPROCESSORS_ONLN 84
#define _SC_PHYS_PAGES       85
#define _SC_AVPHYS_PAGES     86
long    sysconf(int __name);

/* confstr()/fpathconf()/pathconf() are likewise answered by the host's
   runtime libc, so their __name arguments must match the host's own
   <bits/confname.h> numbering, the same reasoning _SC_ rests on above
   (measured with gcc on the reference platform; x86-64 and aarch64 agree to
   the value, checked with a cross gcc + qemu run). Step 157 gap D: etc's
   ext/etc/mkconstants.rb conditionally exposes about 50 _CS_ and _PC_ names
   in total, and all of them exist on the host glibc, but the corpus has
   exactly one consumer (etc) and its own test suite exercises only
   Etc::CS_PATH and Etc::PC_PIPE_BUF (guarded by "if defined?", so the rest
   silently vanishing costs coverage, not a failure). Following the same
   non-exhaustive judgment as sys/syscall.h's number list and
   _POSIX_MONOTONIC_CLOCK above, only those two are added -- the POSIX_V6/V7
   build-environment names (CFLAGS/LDFLAGS/LIBS variants),
   CS_GNU_LIBC_VERSION, CS_GNU_LIBPTHREAD_VERSION, and the rest of the SUSv4
   _PC_ set have no consumer in the corpus and would just be an unconsumed
   measurement surface to re-check every release. */
#define _CS_PATH     0
#define _PC_PIPE_BUF 5
size_t  confstr(int __name, char *__buf, size_t __len);
long    fpathconf(int __fd, int __name);
/* pathconf() has no direct corpus consumer either (etc's io_pathconf() only
   ever calls fpathconf()), but it is fpathconf()'s standard POSIX pair over
   the same _PC_* names, its prototype carries no per-name numeric surface of
   its own to re-measure, and this header's declaration layer is the general
   POSIX surface (like execl/alarm/pause above) rather than a per-consumer
   scoped one -- so it is kept alongside fpathconf() rather than left out. */
long    pathconf(const char *__path, int __name);
void    _exit(int __status) __attribute__((__noreturn__));
void   *sbrk(intptr_t __delta);
int     brk(void *__addr);

/* getopt and its globals. */
extern char *optarg;
extern int optind, opterr, optopt;
int getopt(int __argc, char *const __argv[], const char *__optstring);

#ifdef __USE_GNU
/* The process's environment, as a NULL-terminated array of "NAME=value"
   strings (GAPS BU); code that walks or replaces the environment wholesale
   reads this instead of going through getenv()/setenv() one name at a time. */
extern char **environ;

/* Retries __expression while it evaluates to -1 with errno set to EINTR
   (GAPS BU), the standard guard around a blocking syscall that a signal can
   interrupt. Clean-room rewrite of the well-known GNU macro's behavior --
   it does not copy glibc's text, only its documented effect -- as a
   statement expression so it can be used as an ordinary function-call
   operand. Requires <errno.h> to be included at the call site, exactly as
   glibc's own version does. */
#define TEMP_FAILURE_RETRY(expression) \
  (__extension__ \
    ({ long int __rubycc_tfr_result; \
       do { \
         __rubycc_tfr_result = (long int) (expression); \
       } while (__rubycc_tfr_result == -1L && errno == EINTR); \
       __rubycc_tfr_result; }))
#endif

#endif /* _RUBYCC_UNISTD_H */
