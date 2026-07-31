/* rubycc bundled <unistd.h>: the POSIX system-call declarations (POSIX.1).
   Derived from musl's <unistd.h> declaration set; the few ABI-typed names
   (ssize_t, off_t, pid_t, ...) reuse the shared _RUBYCC_* guards and carry the
   LP64 widths. The STDIN_FILENO / *_OK values are the standard ones. Common
   layer: the surface is declarations plus universal constants. */

#ifndef _RUBYCC_UNISTD_H
#define _RUBYCC_UNISTD_H

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

/* POSIX option macro: the monotonic clock option is supported, but its
   value (0, not a positive constant) means support must still be confirmed
   at runtime via sysconf(_SC_MONOTONIC_CLOCK), matching the host glibc
   (measured). Needed for stackprof: it branches on
   `#ifdef _POSIX_MONOTONIC_CLOCK`, and the #else arm it would otherwise take
   is upstream dead code containing a real syntax error, so a toolchain that
   never defines this macro cannot build stackprof at all. Scope: only this
   one _POSIX_* macro is added here, not the full POSIX options set (same
   scoping judgment as sys/syscall.h's non-exhaustive number list). */
#define _POSIX_MONOTONIC_CLOCK 0

#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
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
int     dup(int __fd);
int     dup2(int __fd, int __fd2);
int     unlink(const char *__name);
int     rmdir(const char *__path);
int     chdir(const char *__path);
char   *getcwd(char *__buf, size_t __size);
int     fsync(int __fd);
int     ftruncate(int __fd, off_t __length);
int     truncate(const char *__file, off_t __length);
int     isatty(int __fd);
char   *ttyname(int __fd);
int     link(const char *__from, const char *__to);
int     symlink(const char *__from, const char *__to);
ssize_t readlink(const char *__restrict __path, char *__restrict __buf, size_t __len);
int     chown(const char *__file, uid_t __owner, gid_t __group);
int     fchown(int __fd, uid_t __owner, gid_t __group);
int     gethostname(char *__name, size_t __len);
int     getpagesize(void);

pid_t   fork(void);
pid_t   getpid(void);
pid_t   getppid(void);
uid_t   getuid(void);
uid_t   geteuid(void);
gid_t   getgid(void);
gid_t   getegid(void);
int     setuid(uid_t __uid);
int     setgid(gid_t __gid);

unsigned int alarm(unsigned int __seconds);
unsigned int sleep(unsigned int __seconds);
int     usleep(useconds_t __useconds);
int     pause(void);

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

#endif /* _RUBYCC_UNISTD_H */
