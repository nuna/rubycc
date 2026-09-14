/* rubycc bundled <sys/types.h>: the width-critical POSIX typedefs. Derived from
   musl's <sys/types.h> shape; every width and signedness is pinned to the glibc
   x86-64 LP64 ABI (measured): off_t/time_t/ssize_t are `long`, pid_t is `int`,
   dev_t/ino_t/nlink_t are `unsigned long`. Each typedef is guarded by a shared
   _RUBYCC_* tag so the other bundled headers that also spell these types agree
   rather than redefine. ABI switch layer: the widths are arch specific.

   glibc's own headers that include <sys/types.h> (and so reach this file on
   rubycc's search path) spell their members with glibc's internal type names
   -- <net/if.h> uses __caddr_t (GAPS AQ), <sys/procfs.h> __pid_t, <sys/mtio.h>
   __daddr_t, <sys/quota.h> __uint64_t, <sys/sendfile.h> __off64_t, and
   <utmp.h> the public int32_t (tools/audit_bundled_headers.rb's mixing survey,
   2026-09-14). bundled-headers-coverage-audit-2 therefore added the whole set
   of scalar __*_t names glibc's <sys/types.h> shows, plus int8_t..int64_t
   and quad_t/u_quad_t. Each width, alignment and signedness was measured on
   both arches on 2026-09-14 (test/test_header_abi.rb's SYS_TYPES case); only
   __nlink_t and __blksize_t differ from aarch64. Every one of them is a
   scalar or pointer typedef, so the second, identical definition a glibc
   header brings in through its own bits/types.h is a compatible
   redefinition (C11 6.7p3).

   bundled-sys-types-ushort-1 (GAPS BN): the BSD short-hand names below were
   also measured against glibc on both arches on 2026-09-14. `ushort` was
   wrong (`unsigned char`, 1 byte) against glibc's `unsigned short` (2 bytes);
   every other name in the section already matched.
   Coverage against glibc's <sys/types.h> under _GNU_SOURCE (audited
   2026-09-14). Intentionally left out:
   omitted: fsid_t -- glibc defines __fsid_t in bits/types.h as a struct
   with no guard, so a struct defined here is a different type and every
   glibc header that reads bits/types.h after this one fails to compile
   (measured 2026-09-14 when it was tried: <aio.h>, <mqueue.h>,
   <semaphore.h>, <sys/acct.h>, <sys/sem.h>, <net/if_ppp.h>); <sys/statfs.h>
   keeps its own copy.
   omitted: pthread_* union pthread_attr_t -- the pthreads objects, whose
   arch-specific opaque layouts live in the bundled <pthread.h>; no corpus
   user reaches them through <sys/types.h>. omitted: <endian.h>
   <sys/select.h> <stddef.h> -- glibc pulls these in; include them directly. */

#ifndef _RUBYCC_SYS_TYPES_H
#define _RUBYCC_SYS_TYPES_H

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
typedef long off64_t;
typedef long loff_t;
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
#ifndef _RUBYCC_MODE_T
#define _RUBYCC_MODE_T
typedef unsigned int mode_t;
#endif
#ifndef _RUBYCC_INO_T
#define _RUBYCC_INO_T
typedef unsigned long ino_t;
#endif
typedef unsigned long ino64_t;
#ifndef _RUBYCC_DEV_T
#define _RUBYCC_DEV_T
typedef unsigned long dev_t;
#endif
#ifndef _RUBYCC_NLINK_T
#define _RUBYCC_NLINK_T
typedef unsigned long nlink_t;
#endif
#ifndef _RUBYCC_BLKSIZE_T
#define _RUBYCC_BLKSIZE_T
typedef long blksize_t;
#endif
#ifndef _RUBYCC_BLKCNT_T
#define _RUBYCC_BLKCNT_T
typedef long blkcnt_t;
#endif
typedef long blkcnt64_t;
#ifndef _RUBYCC_FSBLKCNT_T
#define _RUBYCC_FSBLKCNT_T
typedef unsigned long fsblkcnt_t;
#endif
typedef unsigned long fsblkcnt64_t;
#ifndef _RUBYCC_FSFILCNT_T
#define _RUBYCC_FSFILCNT_T
typedef unsigned long fsfilcnt_t;
#endif
typedef unsigned long fsfilcnt64_t;
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
#ifndef _RUBYCC_SUSECONDS_T
#define _RUBYCC_SUSECONDS_T
typedef long suseconds_t;
#endif
#ifndef _RUBYCC_USECONDS_T
#define _RUBYCC_USECONDS_T
typedef unsigned int useconds_t;
#endif
#ifndef _RUBYCC_ID_T
#define _RUBYCC_ID_T
typedef unsigned int id_t;
#endif
#ifndef _RUBYCC_KEY_T
#define _RUBYCC_KEY_T
typedef int key_t;
#endif

typedef long register_t;
typedef int  daddr_t;
typedef char *caddr_t;
typedef long quad_t;
typedef unsigned long u_quad_t;

/* The exact-width signed integers, spelled as the bundled <stdint.h> spells
   them (an identical typedef is a permitted redefinition, C11 6.7p3). */
#ifndef _RUBYCC_SYS_TYPES_INTN_T
#define _RUBYCC_SYS_TYPES_INTN_T
typedef signed char int8_t;
typedef short       int16_t;
typedef int         int32_t;
typedef long        int64_t;
#endif

/* glibc's internal type names, which glibc's own headers use in place of the
   public ones (measured widths, alignments and signedness). */
typedef signed char        __int8_t;
typedef unsigned char      __uint8_t;
typedef short              __int16_t;
typedef unsigned short     __uint16_t;
typedef int                __int32_t;
typedef unsigned int       __uint32_t;
typedef long               __int64_t;
typedef unsigned long      __uint64_t;
typedef signed char        __int_least8_t;
typedef unsigned char      __uint_least8_t;
typedef short              __int_least16_t;
typedef unsigned short     __uint_least16_t;
typedef int                __int_least32_t;
typedef unsigned int       __uint_least32_t;
typedef long               __int_least64_t;
typedef unsigned long      __uint_least64_t;
typedef long               __quad_t;
typedef unsigned long      __u_quad_t;
typedef long               __intmax_t;
typedef unsigned long      __uintmax_t;
typedef unsigned char      __u_char;
typedef unsigned short     __u_short;
typedef unsigned int       __u_int;
typedef unsigned long      __u_long;
typedef unsigned long      __dev_t;
typedef unsigned int       __uid_t;
typedef unsigned int       __gid_t;
typedef unsigned long      __ino_t;
typedef unsigned long      __ino64_t;
typedef unsigned int       __mode_t;
typedef unsigned long      __nlink_t;
typedef long               __off_t;
typedef long               __off64_t;
typedef int                __pid_t;
typedef unsigned long      __rlim_t;
typedef unsigned long      __rlim64_t;
typedef unsigned int       __id_t;
typedef long               __time_t;
typedef unsigned int       __useconds_t;
typedef long               __suseconds_t;
typedef long               __suseconds64_t;
typedef int                __daddr_t;
typedef int                __key_t;
typedef int                __clockid_t;
typedef void              *__timer_t;
typedef long               __blksize_t;
typedef long               __blkcnt_t;
typedef long               __blkcnt64_t;
typedef unsigned long      __fsblkcnt_t;
typedef unsigned long      __fsblkcnt64_t;
typedef unsigned long      __fsfilcnt_t;
typedef unsigned long      __fsfilcnt64_t;
typedef long               __fsword_t;
typedef long               __ssize_t;
typedef long               __syscall_slong_t;
typedef unsigned long      __syscall_ulong_t;
typedef long               __loff_t;
typedef char              *__caddr_t;
typedef long               __intptr_t;
typedef unsigned int       __socklen_t;
typedef long               __clock_t;

/* BSD short-hand integer names (glibc exposes them under _DEFAULT_SOURCE). */
typedef unsigned char  u_char;
typedef unsigned short u_short;
typedef unsigned int   u_int;
typedef unsigned long  u_long;
typedef unsigned short ushort;
typedef unsigned int   uint;
typedef unsigned long  ulong;
typedef unsigned char  u_int8_t;
typedef unsigned short u_int16_t;
typedef unsigned int   u_int32_t;
typedef unsigned long  u_int64_t;

#endif /* _RUBYCC_SYS_TYPES_H */
