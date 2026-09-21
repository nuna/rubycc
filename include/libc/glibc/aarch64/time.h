/* rubycc bundled <time.h>: the calendar/clock types and declarations (ISO C
   7.27, POSIX). Derived from musl's <time.h> shape; time_t is pinned to `long`
   and `struct tm` carries glibc's tm_gmtoff/tm_zone extension so its 56-byte
   layout matches the reference ABI (measured). The struct guards reuse glibc's
   (__struct_tm_defined, _STRUCT_TIMESPEC) so a host header coexisting on the
   path does not redefine. ABI switch layer: time_t width and struct tm layout
   are arch specific.

   Coverage against glibc's <time.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, both arches, with tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Added there: timespec_get
   (ISO C11's own way to read a clock, which rubycc rejected before -- measured
   2026-09-18), clock_nanosleep, clock_getcpuclockid, and the three clock ids
   this header was missing (each printed from the glibc oracle on x86-64 and,
   separately, on aarch64 under qemu on 2026-09-18; the two agreed). struct
   itimerspec also moved behind glibc's own __itimerspec_defined guard, the
   treatment struct tm already had. Every added prototype was written here and
   then placed ahead of glibc's <time.h> under gcc and aarch64-linux-gnu-gcc,
   where a conflicting redeclaration is an error (2026-09-18, both clean).
   Intentionally left out:
   omitted: timer_create timer_delete timer_settime timer_gettime
   timer_getoverrun struct sigevent sigevent_t SIGEV_NONE SIGEV_SIGNAL
   SIGEV_THREAD SIGEV_THREAD_ID -- the POSIX per-process timers. Their
   notification block embeds a pthread_attr_t and glibc shares its definition
   with <netdb.h> behind __sigevent_t_defined, so providing it means carrying
   that layout and that guard; no corpus user asks for them yet.
   omitted: struct timex clock_adjtime ADJ_* MOD_* STA_* -- the kernel clock
   discipline (adjtimex), whose struct is a kernel UAPI layout of its own and
   which only an NTP daemon calls. omitted: getdate getdate_r getdate_err --
   the DATEMSK-file date parser; strptime above is what sources use.
   omitted: dysize -- a days-in-year helper glibc inherited from SunOS.
   omitted: timespec_getres -- glibc 2.34 and later only, so declaring it would
   promise a symbol an older host glibc does not have (the line <stdlib.h>
   draws at arc4random). omitted: locale_t strftime_l strptime_l -- the
   locale-object API the bundled <locale.h> leaves out.
   omitted: struct timeval -- glibc shows it here only because struct timex
   embeds one; the bundled <sys/time.h> defines it, under the guard glibc
   shares (__timeval_defined). omitted: <stddef.h> -- only size_t and NULL are
   needed, and both are declared here directly. */

#ifndef _RUBYCC_TIME_H
#define _RUBYCC_TIME_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#ifndef NULL
#define NULL ((void*)0)
#endif

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_TIME_T
#define _RUBYCC_TIME_T
typedef long time_t;
#endif
#ifndef _RUBYCC_CLOCK_T
#define _RUBYCC_CLOCK_T
typedef long clock_t;
#endif
#ifndef _RUBYCC_CLOCKID_T
#define _RUBYCC_CLOCKID_T
typedef int clockid_t;
#endif
#ifndef _RUBYCC_TIMER_T
#define _RUBYCC_TIMER_T
typedef void *timer_t;
#endif
#ifndef _RUBYCC_PID_T
#define _RUBYCC_PID_T
typedef int pid_t;
#endif

#define CLOCKS_PER_SEC ((clock_t) 1000000)
#define TIME_UTC 1

/* POSIX clock ids. */
#define CLOCK_REALTIME           0
#define CLOCK_MONOTONIC          1
#define CLOCK_PROCESS_CPUTIME_ID 2
#define CLOCK_THREAD_CPUTIME_ID  3
#define CLOCK_MONOTONIC_RAW      4
#define CLOCK_REALTIME_COARSE    5
#define CLOCK_MONOTONIC_COARSE   6
#define CLOCK_BOOTTIME           7
#define CLOCK_REALTIME_ALARM     8
#define CLOCK_BOOTTIME_ALARM     9
#define CLOCK_TAI                11
#define TIMER_ABSTIME            1

#ifndef _STRUCT_TIMESPEC
#define _STRUCT_TIMESPEC 1
struct timespec {
  time_t tv_sec;
  long   tv_nsec;
};
#endif

#ifndef __struct_tm_defined
#define __struct_tm_defined 1
struct tm {
  int tm_sec;
  int tm_min;
  int tm_hour;
  int tm_mday;
  int tm_mon;
  int tm_year;
  int tm_wday;
  int tm_yday;
  int tm_isdst;
  long tm_gmtoff;
  const char *tm_zone;
};
#endif

/* glibc keeps struct itimerspec in a file of its own and guards it with
   __itimerspec_defined, so setting the same guard keeps a glibc header that
   reads that file (timerfd, mqueue) from defining it a second time. */
#ifndef __itimerspec_defined
#define __itimerspec_defined 1
struct itimerspec {
  struct timespec it_interval;
  struct timespec it_value;
};
#endif

clock_t clock(void);
time_t time(time_t *__timer);
double difftime(time_t __time1, time_t __time0);
time_t mktime(struct tm *__tp);
size_t strftime(char *__restrict __s, size_t __maxsize,
                const char *__restrict __format, const struct tm *__restrict __tp);
struct tm *gmtime(const time_t *__timer);
struct tm *localtime(const time_t *__timer);
struct tm *gmtime_r(const time_t *__restrict __timer, struct tm *__restrict __tp);
struct tm *localtime_r(const time_t *__restrict __timer, struct tm *__restrict __tp);
char *asctime(const struct tm *__tp);
char *ctime(const time_t *__timer);
char *asctime_r(const struct tm *__restrict __tp, char *__restrict __buf);
char *ctime_r(const time_t *__restrict __timer, char *__restrict __buf);
char *strptime(const char *__restrict __s, const char *__restrict __fmt, struct tm *__tp);

int nanosleep(const struct timespec *__requested_time, struct timespec *__remaining);
/* ISO C11's clock read: __base is TIME_UTC, and the return value is __base on
   success rather than 0. */
int timespec_get(struct timespec *__ts, int __base);
int clock_nanosleep(clockid_t __clock_id, int __flags,
                    const struct timespec *__requested_time, struct timespec *__remaining);
int clock_getcpuclockid(pid_t __pid, clockid_t *__clock_id);
int clock_gettime(clockid_t __clock_id, struct timespec *__tp);
int clock_settime(clockid_t __clock_id, const struct timespec *__tp);
int clock_getres(clockid_t __clock_id, struct timespec *__res);
time_t timegm(struct tm *__tp);
time_t timelocal(struct tm *__tp);

extern char *tzname[2];
extern long timezone;
extern int daylight;
void tzset(void);

#endif /* _RUBYCC_TIME_H */
