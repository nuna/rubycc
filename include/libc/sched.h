/* rubycc bundled <sched.h>: scheduling (POSIX.1). Provenance: clean room
   against the glibc/Linux ABI. Step 123 (M5 H2) pared it to the surface etc
   and google-protobuf's corpus samples reach (sched_yield, sched_getcpu,
   cpu_set_t's existence). cpu_set_t is glibc-internal state (a bitmap of
   CPU_SETSIZE bits used only through the CPU_SET/CPU_ZERO/CPU_ISSET macro
   family), so, like pthread.h's opaque objects and setjmp.h's jmp_buf,
   rubycc reproduces only its measured size and alignment as an opaque byte
   blob -- a union of a char __size[N] arm and the aligning scalar -- and does
   not name glibc's internal __bits array. That size/alignment (128, 8-byte
   aligned) was measured against the glibc oracle on both x86-64 and aarch64
   (see test/test_header_abi.rb's SCHED case) and the two agreed exactly, so
   this header lives in the common layer. The functions are POSIX/glibc
   declarations whose bodies resolve from the host libc at link time.

   bundled-headers-coverage-audit-2 added the POSIX scheduling-policy half
   (GAPS AM): struct sched_param (glibc's <spawn.h> embeds one in
   posix_spawnattr_t, so without it that glibc header cannot be read next to
   this one), the SCHED_* policy numbers, and sched_setparam/getparam/
   setscheduler/getscheduler/get_priority_max/get_priority_min/
   rr_get_interval, together with the pid_t/time_t/struct timespec they are
   declared over (shared guards with <sys/types.h> and <time.h>). struct
   sched_param's size and member offset, and every SCHED_* value, were
   measured on both arches on 2026-09-14 and agree (SCHED case). The
   Linux-only policies (SCHED_BATCH and later) and the affinity calls are
   GNU names in glibc and are declared under __USE_GNU here (hence the
   <features.h> include); cpu_set_t/CPU_SETSIZE/sched_getcpu predate that
   rule and stay unconditional as Step 123 made them.
   Coverage against glibc's <sched.h> under _GNU_SOURCE (audited 2026-09-14,
   tools/audit_bundled_headers.rb). Intentionally left out:
   omitted: CPU_* -- the affinity macros would require reproducing glibc's
   internal bit numbering, not just an opaque size; no corpus user.
   omitted: clone unshare setns getcpu CLONE_* CSIGNAL -- the Linux
   process-creation and namespace API; no corpus user.
   omitted: sched_priority -- glibc's self-referential compatibility macro
   for the member name; the member itself is provided.
   omitted: <stddef.h> -- only size_t is needed, and it is declared here. */

#ifndef _RUBYCC_SCHED_H
#define _RUBYCC_SCHED_H

#include <features.h>

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_PID_T
#define _RUBYCC_PID_T
typedef int pid_t;
#endif
#ifndef _RUBYCC_TIME_T
#define _RUBYCC_TIME_T
typedef long time_t;
#endif
#ifndef _STRUCT_TIMESPEC
#define _STRUCT_TIMESPEC 1
struct timespec {
  time_t tv_sec;
  long   tv_nsec;
};
#endif

/* A thread's scheduling parameters: 4 bytes, the priority at offset 0
   (measured, both arches). */
struct sched_param {
  int sched_priority;
};

/* Scheduling policies (measured, both arches). */
#define SCHED_OTHER 0
#define SCHED_FIFO  1
#define SCHED_RR    2
#ifdef __USE_GNU
# define SCHED_BATCH         3
# define SCHED_ISO           4
# define SCHED_IDLE          5
# define SCHED_DEADLINE      6
# define SCHED_RESET_ON_FORK 0x40000000
#endif

#define CPU_SETSIZE 1024

/* Opaque CPU affinity bitmap. glibc stores CPU_SETSIZE bits inside as an
   array of unsigned long words; rubycc reproduces only the measured size and
   alignment as an opaque blob, not the internal word layout. */
typedef union { char __size[128]; long __align; } cpu_set_t;

int sched_setparam(pid_t __pid, const struct sched_param *__param);
int sched_getparam(pid_t __pid, struct sched_param *__param);
int sched_setscheduler(pid_t __pid, int __policy, const struct sched_param *__param);
int sched_getscheduler(pid_t __pid);
int sched_yield(void);
int sched_get_priority_max(int __algorithm);
int sched_get_priority_min(int __algorithm);
int sched_rr_get_interval(pid_t __pid, struct timespec *__t);
int sched_getcpu(void);

#ifdef __USE_GNU
int sched_setaffinity(pid_t __pid, size_t __cpusetsize, const cpu_set_t *__cpuset);
int sched_getaffinity(pid_t __pid, size_t __cpusetsize, cpu_set_t *__cpuset);
#endif

#endif /* _RUBYCC_SCHED_H */
