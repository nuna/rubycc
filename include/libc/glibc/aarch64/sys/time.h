/* rubycc bundled <sys/time.h>: struct timeval and the BSD time calls (POSIX).
   Derived from musl's <sys/time.h> shape; struct timeval's members are pinned to
   the glibc x86-64 ABI (time_t and suseconds_t are both `long`, giving a 16-byte
   layout, measured). The struct guard reuses glibc's __timeval_defined. ABI
   switch layer: the member widths are arch specific. */

#ifndef _RUBYCC_SYS_TIME_H
#define _RUBYCC_SYS_TIME_H

#ifndef _RUBYCC_TIME_T
#define _RUBYCC_TIME_T
typedef long time_t;
#endif
#ifndef _RUBYCC_SUSECONDS_T
#define _RUBYCC_SUSECONDS_T
typedef long suseconds_t;
#endif

#ifndef __timeval_defined
#define __timeval_defined 1
struct timeval {
  time_t      tv_sec;
  suseconds_t tv_usec;
};
#endif

struct timezone {
  int tz_minuteswest;
  int tz_dsttime;
};

struct itimerval {
  struct timeval it_interval;
  struct timeval it_value;
};

#define ITIMER_REAL    0
#define ITIMER_VIRTUAL 1
#define ITIMER_PROF    2

int gettimeofday(struct timeval *__restrict __tv, void *__restrict __tz);
int settimeofday(const struct timeval *__tv, const struct timezone *__tz);
int getitimer(int __which, struct itimerval *__value);
int setitimer(int __which, const struct itimerval *__restrict __new,
              struct itimerval *__restrict __old);
int utimes(const char *__file, const struct timeval __tvp[2]);

/* Convenience timeval arithmetic macros (glibc/BSD, under _DEFAULT_SOURCE). */
#define timerisset(tvp)   ((tvp)->tv_sec || (tvp)->tv_usec)
#define timerclear(tvp)   ((tvp)->tv_sec = (tvp)->tv_usec = 0)
#define timercmp(a, b, CMP) \
  (((a)->tv_sec == (b)->tv_sec) ? \
   ((a)->tv_usec CMP (b)->tv_usec) : \
   ((a)->tv_sec CMP (b)->tv_sec))
#define timeradd(a, b, result)                        \
  do {                                                \
    (result)->tv_sec = (a)->tv_sec + (b)->tv_sec;     \
    (result)->tv_usec = (a)->tv_usec + (b)->tv_usec;  \
    if ((result)->tv_usec >= 1000000) {               \
      ++(result)->tv_sec;                             \
      (result)->tv_usec -= 1000000;                   \
    }                                                 \
  } while (0)
#define timersub(a, b, result)                        \
  do {                                                \
    (result)->tv_sec = (a)->tv_sec - (b)->tv_sec;     \
    (result)->tv_usec = (a)->tv_usec - (b)->tv_usec;  \
    if ((result)->tv_usec < 0) {                      \
      --(result)->tv_sec;                             \
      (result)->tv_usec += 1000000;                   \
    }                                                 \
  } while (0)

#endif /* _RUBYCC_SYS_TIME_H */
