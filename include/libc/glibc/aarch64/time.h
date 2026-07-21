/* rubycc bundled <time.h>: the calendar/clock types and declarations (ISO C
   7.27, POSIX). Derived from musl's <time.h> shape; time_t is pinned to `long`
   and `struct tm` carries glibc's tm_gmtoff/tm_zone extension so its 56-byte
   layout matches the reference ABI (measured). The struct guards reuse glibc's
   (__struct_tm_defined, _STRUCT_TIMESPEC) so a host header coexisting on the
   path does not redefine. ABI switch layer: time_t width and struct tm layout
   are arch specific. */

#ifndef _RUBYCC_TIME_H
#define _RUBYCC_TIME_H

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

struct itimerspec {
  struct timespec it_interval;
  struct timespec it_value;
};

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
