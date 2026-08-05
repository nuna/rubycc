/* rubycc bundled <sys/resource.h>: resource limits and usage (POSIX.1).
   Provenance: clean room against the POSIX public interface and the Linux
   kernel UAPI (asm-generic/resource.h); struct rlimit's and struct rusage's
   member names, types and order are that ABI's own public contract, not
   glibc implementation detail. Every member is used directly by callers, so
   neither struct can be an opaque byte blob; both structs' sizes and every
   member's offset were measured against the glibc oracle on both x86-64 and
   aarch64 (see test/test_header_abi.rb's RESOURCE case) and the two agreed
   exactly (rlim_t is `unsigned long` and struct timeval's members are both
   `long` on either LP64 target, so neither struct has an arch-dependent
   field width), so this header lives in the common layer. The C libraries do
   differ, though: struct rusage is larger on musl, which is carried below
   under __RUBYCC_LIBC_MUSL__ (see the preprocessor's LIBCS). struct timeval
   reuses the __timeval_defined guard sys/time.h also defines it under, so the
   two headers agree rather than redefine when both are included.
   The RLIMIT_* enumerators and RUSAGE_* constants are the standard Linux/
   glibc values (measured, both arches agree). getrlimit/setrlimit/getrusage
   are POSIX declarations whose bodies resolve from the host libc at link time
   (Step 123, M5 H2). */

#ifndef _RUBYCC_SYS_RESOURCE_H
#define _RUBYCC_SYS_RESOURCE_H

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

typedef unsigned long rlim_t;

/* struct rlimit: 16 bytes, 8-byte aligned (measured, both arches). */
struct rlimit {
  rlim_t rlim_cur; /* Soft limit. offset 0 */
  rlim_t rlim_max; /* Hard limit. offset 8 */
};

/* struct rusage: 144 bytes, 8-byte aligned on glibc and 272 bytes, 8-byte
   aligned on musl (both sizeof/_Alignof pairs measured with the ABI harness,
   glibc's on this host and musl's on the CI musl run, docs/STEPS.md Step 193).
   Every member offset below was probed on both and agreed, so the two libraries
   differ only in what follows the last member: musl reserves a further 128
   bytes there. Those bytes are reproduced as one opaque trailing array rather
   than as named fields, because only their extent was measured -- the same
   treatment sys/stat.h gives struct stat's reserved slots. The
   ru_ixrss/ru_idrss/ru_isrss/ru_nswap fields are unused by Linux but kept for
   the standard layout. */
struct rusage {
  struct timeval ru_utime;    /* offset 0:   user CPU time used */
  struct timeval ru_stime;    /* offset 16:  system CPU time used */
  long ru_maxrss;             /* offset 32:  maximum resident set size */
  long ru_ixrss;              /* offset 40:  integral shared memory size */
  long ru_idrss;              /* offset 48:  integral unshared data size */
  long ru_isrss;              /* offset 56:  integral unshared stack size */
  long ru_minflt;             /* offset 64:  page reclaims */
  long ru_majflt;             /* offset 72:  page faults */
  long ru_nswap;              /* offset 80:  swaps */
  long ru_inblock;            /* offset 88:  block input operations */
  long ru_oublock;            /* offset 96:  block output operations */
  long ru_msgsnd;             /* offset 104: messages sent */
  long ru_msgrcv;             /* offset 112: messages received */
  long ru_nsignals;           /* offset 120: signals received */
  long ru_nvcsw;              /* offset 128: voluntary context switches */
  long ru_nivcsw;             /* offset 136: involuntary context switches */
#if defined(__RUBYCC_LIBC_MUSL__)
  long __reserved[16];        /* offset 144: musl's trailing 128 bytes (measured) */
#endif
};

#define RLIMIT_CPU        0
#define RLIMIT_FSIZE      1
#define RLIMIT_DATA       2
#define RLIMIT_STACK      3
#define RLIMIT_CORE       4
#define RLIMIT_RSS        5
#define RLIMIT_NPROC      6
#define RLIMIT_NOFILE     7
#define RLIMIT_MEMLOCK    8
#define RLIMIT_AS         9
#define RLIMIT_LOCKS      10
#define RLIMIT_SIGPENDING 11
#define RLIMIT_MSGQUEUE   12
#define RLIMIT_NICE       13
#define RLIMIT_RTPRIO     14
#define RLIMIT_RTTIME     15
#define RLIMIT_NLIMITS    16

#define RLIM_INFINITY ((rlim_t)-1)

#define RUSAGE_SELF     0
#define RUSAGE_CHILDREN (-1)
#define RUSAGE_THREAD   1

int getrlimit(int __resource, struct rlimit *__rlimits);
int setrlimit(int __resource, const struct rlimit *__rlimits);
int getrusage(int __who, struct rusage *__usage);

#endif /* _RUBYCC_SYS_RESOURCE_H */
