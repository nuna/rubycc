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
long    sysconf(int __name);
void    _exit(int __status) __attribute__((__noreturn__));
void   *sbrk(intptr_t __delta);
int     brk(void *__addr);

/* getopt and its globals. */
extern char *optarg;
extern int optind, opterr, optopt;
int getopt(int __argc, char *const __argv[], const char *__optstring);

#endif /* _RUBYCC_UNISTD_H */
