/* rubycc bundled <pthread.h>: the POSIX threads types, the mutex/attribute
   enums and the core pthreads calls. Provenance: clean room against the glibc
   pthreads ABI (bits/pthreadtypes.h, bits/pthreadtypes-arch.h and pthread.h),
   not derived from musl or glibc source -- and a measured glibc ABI, not a
   kernel UAPI, since the pthreads objects are glibc internal state rather than a
   system-call interface. The opaque objects (pthread_mutex_t, pthread_cond_t,
   pthread_attr_t and kin) are glibc implementation detail, so rubycc reproduces
   only their measured size and alignment as an opaque byte blob -- a union of a
   char __size[N] arm and the aligning scalar -- and does not copy glibc's
   internal field layout (only what the ABI needs, exact; everything else opaque,
   the same principle sys/stat.h follows for its reserved slots). Only that
   size and alignment is an ABI fact reproduced by measurement, not copied text
   (see docs/HEADER-LICENSING.md). The pthread_* calls are POSIX declarations
   whose bodies resolve from the host libc at link time (glibc folds them into
   libc), the same way errno.h's __errno_location does.
   Placed in the glibc/aarch64 layer because the opaque sizes are arch dependent:
   pthread_mutex_t, pthread_attr_t, pthread_mutexattr_t and pthread_condattr_t
   are wider here than on x86-64, so this file differs from the companion
   glibc/x86-64/pthread.h only in those four __size[N] counts (and this
   provenance line).
   musl disagrees with glibc on five of these objects here, one more than the
   x86-64 companion's single case (pthread_rwlockattr_t's alignment): musl's
   pthread_mutex_t is 40 bytes against glibc's 48, its pthread_attr_t 56
   against glibc's 64, its pthread_mutexattr_t and pthread_condattr_t 4 bytes
   against glibc's 8 (all four with the same alignment on both libcs), and its
   pthread_rwlockattr_t is 4-byte aligned against glibc's 8 (same 8-byte size
   on both) -- the opaque pthreads objects are the single most arch-dependent
   thing in this layer, as the four differing __size[N] counts above already
   show, so this file's musl figures are its own measurement rather than the
   x86-64 companion's single-case one, taken on the CI aarch64 musl run
   (docs/STEPS.md Step 202). Every other pthreads object here (pthread_t,
   pthread_cond_t, pthread_rwlock_t and the small scalar handles) measured
   identical on the two libraries. */

#ifndef _RUBYCC_PTHREAD_H
#define _RUBYCC_PTHREAD_H

/* The thread handle and the small scalar handles (identical on both arches). */
typedef unsigned long pthread_t;
typedef int           pthread_once_t;
typedef unsigned int  pthread_key_t;
typedef int           pthread_spinlock_t;

/* The opaque pthreads objects. Each carries real internal fields in glibc;
   rubycc reproduces only the measured size and alignment as an opaque blob (the
   char __size[N] arm alongside the aligning scalar), so a variable of the type
   occupies the right space and alignment without copying glibc's field layout.
   pthread_attr_t, pthread_mutex_t, pthread_mutexattr_t and pthread_condattr_t
   have a wider __size[N] on aarch64 (the four counts that differ between the two
   arch layers); the others are identical on both arches.
   Five of these additionally differ by libc on this arch (see the provenance
   note above): pthread_mutex_t, pthread_attr_t, pthread_mutexattr_t and
   pthread_condattr_t are narrower on musl (same alignment as glibc), and
   pthread_rwlockattr_t keeps glibc's 8-byte size but musl's alignment is
   narrower. Both figures measured with the ABI harness, glibc's on this host
   and musl's on the CI aarch64 musl run (docs/STEPS.md Step 202). */
#if defined(__RUBYCC_LIBC_MUSL__)
typedef union { char __size[56]; long __align; } pthread_attr_t;
typedef union { char __size[40]; long __align; } pthread_mutex_t;
typedef union { char __size[4];  int  __align; } pthread_mutexattr_t;
typedef union { char __size[48]; long __align; } pthread_cond_t;
typedef union { char __size[4];  int  __align; } pthread_condattr_t;
typedef union { char __size[56]; long __align; } pthread_rwlock_t;
typedef union { char __size[8];  int  __align; } pthread_rwlockattr_t;
#else
typedef union { char __size[64]; long __align; } pthread_attr_t;
typedef union { char __size[48]; long __align; } pthread_mutex_t;
typedef union { char __size[8];  int  __align; } pthread_mutexattr_t;
typedef union { char __size[48]; long __align; } pthread_cond_t;
typedef union { char __size[8];  int  __align; } pthread_condattr_t;
typedef union { char __size[56]; long __align; } pthread_rwlock_t;
typedef union { char __size[8];  long __align; } pthread_rwlockattr_t;
#endif

/* Mutex kinds (pthread_mutexattr_settype / __kind). */
#define PTHREAD_MUTEX_NORMAL     0
#define PTHREAD_MUTEX_RECURSIVE  1
#define PTHREAD_MUTEX_ERRORCHECK 2
#define PTHREAD_MUTEX_DEFAULT    PTHREAD_MUTEX_NORMAL

/* Detach state (pthread_attr_setdetachstate). */
#define PTHREAD_CREATE_JOINABLE  0
#define PTHREAD_CREATE_DETACHED  1

/* Process-shared attribute values. */
#define PTHREAD_PROCESS_PRIVATE  0
#define PTHREAD_PROCESS_SHARED   1

/* Static initializers: zero the first arm of the opaque union. */
#define PTHREAD_MUTEX_INITIALIZER  { { 0 } }
#define PTHREAD_COND_INITIALIZER   { { 0 } }
#define PTHREAD_RWLOCK_INITIALIZER { { 0 } }
#define PTHREAD_ONCE_INIT 0

int  pthread_create(pthread_t *__thread, const pthread_attr_t *__attr, void *(*__start)(void *), void *__arg);
int  pthread_join(pthread_t __thread, void **__retval);
int  pthread_detach(pthread_t __thread);
pthread_t pthread_self(void);
int  pthread_equal(pthread_t __t1, pthread_t __t2);
int  pthread_kill(pthread_t __thread, int __sig);
void pthread_exit(void *__retval);
int  pthread_mutex_init(pthread_mutex_t *__mutex, const pthread_mutexattr_t *__attr);
int  pthread_mutex_destroy(pthread_mutex_t *__mutex);
int  pthread_mutex_lock(pthread_mutex_t *__mutex);
int  pthread_mutex_trylock(pthread_mutex_t *__mutex);
int  pthread_mutex_unlock(pthread_mutex_t *__mutex);
int  pthread_cond_init(pthread_cond_t *__cond, const pthread_condattr_t *__attr);
int  pthread_cond_destroy(pthread_cond_t *__cond);
int  pthread_cond_wait(pthread_cond_t *__cond, pthread_mutex_t *__mutex);
int  pthread_cond_signal(pthread_cond_t *__cond);
int  pthread_cond_broadcast(pthread_cond_t *__cond);
int  pthread_once(pthread_once_t *__once, void (*__init)(void));
int  pthread_key_create(pthread_key_t *__key, void (*__destr)(void *));
int  pthread_key_delete(pthread_key_t __key);
void *pthread_getspecific(pthread_key_t __key);
int  pthread_setspecific(pthread_key_t __key, const void *__value);
int  pthread_attr_init(pthread_attr_t *__attr);
int  pthread_attr_destroy(pthread_attr_t *__attr);
int  pthread_mutexattr_init(pthread_mutexattr_t *__attr);
int  pthread_mutexattr_destroy(pthread_mutexattr_t *__attr);
int  pthread_mutexattr_settype(pthread_mutexattr_t *__attr, int __type);

/* Process-fork hook registration (a process-wide call, unlike the
   thread-manipulation calls above). Declaring this turns stackprof's
   build failure from a compile-time "implicit declaration" error into a
   link-time one: glibc supplies pthread_atfork only from libc_nonshared.a,
   whose member references __dso_handle, which rubycc's linker cannot yet
   resolve (Step 146 gap 6, a separate, unfixed problem). */
int  pthread_atfork(void (*__prepare)(void), void (*__parent)(void), void (*__child)(void));

#endif /* _RUBYCC_PTHREAD_H */
