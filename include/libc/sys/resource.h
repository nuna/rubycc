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
   (Step 123, M5 H2).

   Coverage against glibc's <sys/resource.h> under _GNU_SOURCE (audited
   2026-09-18, glibc 2.39, x86-64 and aarch64, with
   tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Twenty names were missing;
   twelve were added and eight are deliberate. Added, all measured on both
   arches on 2026-09-18 and agreeing: the nice-value interface
   getpriority/setpriority with its PRIO_PROCESS 0 / PRIO_PGRP 1 / PRIO_USER 2
   targets and PRIO_MIN -20 / PRIO_MAX 20 range (a gem that wants to run its
   worker at a lower priority calls exactly this); id_t, which those two take
   and which the bundled <sys/wait.h> already declares under the same guard;
   RLIMIT_OFILE 7 and RLIM_NLIMITS 16, the older spellings of RLIMIT_NOFILE
   and RLIMIT_NLIMITS above; and RLIM_SAVED_CUR / RLIM_SAVED_MAX, which
   measured equal to RLIM_INFINITY on this Linux (they exist so a portable
   program can say "leave this limit as it was" on systems where a limit does
   not fit in rlim_t).

   One divergence is worth naming, because it is not a gap but a deliberate
   difference the audit cannot see. Under _GNU_SOURCE glibc types the resource
   and priority selectors as *enums* (__rlimit_resource_t becomes `enum
   __rlimit_resource', __priority_which_t becomes `enum __priority_which'),
   while this header has always spelled them `int', and measurement on
   2026-09-18 confirms gcc calls that a conflicting redeclaration if the two
   spellings ever meet. They never do: the bundled <sys/resource.h> replaces
   glibc's rather than joining it, no glibc header rubycc does not bundle
   declares these calls, and `int' is what glibc itself uses outside
   _GNU_SOURCE (checked by declaring all five prototypes immediately before
   `#include <sys/resource.h>` under gcc and aarch64-linux-gnu-gcc with
   _DEFAULT_SOURCE: clean on both arches). That measurement is also why
   prlimit is left out below -- it exists only under _GNU_SOURCE, so it has no
   `int' spelling to borrow.
   omitted: prlimit -- see the paragraph above: glibc declares it only under
   _GNU_SOURCE, where its resource argument is `enum __rlimit_resource', so
   rubycc would have to reproduce a glibc-internal enum to declare it
   compatibly, and no corpus user asks for it.
   omitted: RUSAGE_LWP -- a Solaris-compatibility alias glibc gives the same
   value as the RUSAGE_THREAD above.
   omitted: RLIM64_INFINITY rlim64_t struct rlimit64 getrlimit64 setrlimit64
   prlimit64 -- LFS64 aliases, identical to the unsuffixed names on an LP64
   target, no corpus user (the same reasoning stdlib.h and unistd.h use). */

#ifndef _RUBYCC_SYS_RESOURCE_H
#define _RUBYCC_SYS_RESOURCE_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

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

#ifndef _RUBYCC_ID_T
#define _RUBYCC_ID_T
typedef unsigned int id_t;
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
/* "Leave this limit alone". Measured equal to RLIM_INFINITY on both arches. */
#define RLIM_SAVED_CUR RLIM_INFINITY
#define RLIM_SAVED_MAX RLIM_INFINITY

/* Older spellings of two of the names above. */
#define RLIMIT_OFILE  RLIMIT_NOFILE
#define RLIM_NLIMITS  RLIMIT_NLIMITS

/* getpriority/setpriority targets and the nice-value range (measured, both
   arches agree). */
#define PRIO_PROCESS 0
#define PRIO_PGRP    1
#define PRIO_USER    2
#define PRIO_MIN     (-20)
#define PRIO_MAX     20

#define RUSAGE_SELF     0
#define RUSAGE_CHILDREN (-1)
#define RUSAGE_THREAD   1

int getrlimit(int __resource, struct rlimit *__rlimits);
int setrlimit(int __resource, const struct rlimit *__rlimits);
int getrusage(int __who, struct rusage *__usage);
int getpriority(int __which, id_t __who);
int setpriority(int __which, id_t __who, int __prio);

#endif /* _RUBYCC_SYS_RESOURCE_H */
