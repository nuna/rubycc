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
   Placed in the glibc/x86-64 layer because the opaque sizes are arch dependent:
   pthread_mutex_t, pthread_attr_t, pthread_mutexattr_t and pthread_condattr_t
   are wider on aarch64, so a companion glibc/aarch64/pthread.h differs from this
   file only in those four __size[N] counts (and this provenance line). */

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
   arch layers); the others are identical on both arches. */
typedef union { char __size[56]; long __align; } pthread_attr_t;
typedef union { char __size[40]; long __align; } pthread_mutex_t;
typedef union { char __size[4];  int  __align; } pthread_mutexattr_t;
typedef union { char __size[48]; long __align; } pthread_cond_t;
typedef union { char __size[4];  int  __align; } pthread_condattr_t;
typedef union { char __size[56]; long __align; } pthread_rwlock_t;
typedef union { char __size[8];  long __align; } pthread_rwlockattr_t;

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

#endif /* _RUBYCC_PTHREAD_H */
