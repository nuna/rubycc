/* rubycc bundled <sys/types.h>: the width-critical POSIX typedefs. Derived from
   musl's <sys/types.h> shape; every width and signedness is pinned to the glibc
   x86-64 LP64 ABI (measured): off_t/time_t/ssize_t are `long`, pid_t is `int`,
   dev_t/ino_t/nlink_t are `unsigned long`. Each typedef is guarded by a shared
   _RUBYCC_* tag so the other bundled headers that also spell these types agree
   rather than redefine. ABI switch layer: the widths are arch specific. */

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

/* BSD short-hand integer names (glibc exposes them under _DEFAULT_SOURCE). */
typedef unsigned char  u_char;
typedef unsigned short u_short;
typedef unsigned int   u_int;
typedef unsigned long  u_long;
typedef unsigned char  ushort;
typedef unsigned int   uint;
typedef unsigned long  ulong;
typedef unsigned char  u_int8_t;
typedef unsigned short u_int16_t;
typedef unsigned int   u_int32_t;
typedef unsigned long  u_int64_t;

#endif /* _RUBYCC_SYS_TYPES_H */
