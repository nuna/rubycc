/* rubycc bundled <sys/mman.h>: the memory-mapping calls and the PROT_/MAP_/MS_/
   MADV_ flag macros (POSIX plus Linux extensions). Provenance: clean room
   against the Linux kernel UAPI (asm-generic/mman-common.h and mman.h), not
   derived from musl. The flag values and MAP_FAILED are that ABI reproduced as
   measured integer constants (an ABI fact, not copied text -- see
   docs/HEADER-LICENSING.md), the same treatment as errno.h and fcntl.h. mmap,
   munmap and kin are POSIX declarations. Common layer: every flag value is
   identical on x86-64 and aarch64 (both use the asm-generic assignments). */

#ifndef _RUBYCC_SYS_MMAN_H
#define _RUBYCC_SYS_MMAN_H

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_OFF_T
#define _RUBYCC_OFF_T
typedef long off_t;
#endif

/* Memory protection bits (for mmap/mprotect). */
#define PROT_NONE  0x0
#define PROT_READ  0x1
#define PROT_WRITE 0x2
#define PROT_EXEC  0x4

/* mmap flags. MAP_SHARED/MAP_PRIVATE are the required sharing mode; the rest
   are Linux extensions. */
#define MAP_SHARED    0x00001
#define MAP_PRIVATE   0x00002
#define MAP_FIXED     0x00010
#define MAP_ANONYMOUS 0x00020
#define MAP_ANON      MAP_ANONYMOUS
#define MAP_GROWSDOWN 0x00100
#define MAP_LOCKED    0x02000
#define MAP_NORESERVE 0x04000
#define MAP_POPULATE  0x08000
#define MAP_STACK     0x20000

/* mmap failure sentinel: the return value on error. */
#define MAP_FAILED ((void *) -1)

/* msync flags. */
#define MS_ASYNC      0x1
#define MS_INVALIDATE 0x2
#define MS_SYNC       0x4

/* madvise advice values. */
#define MADV_NORMAL     0
#define MADV_RANDOM     1
#define MADV_SEQUENTIAL 2
#define MADV_WILLNEED   3
#define MADV_DONTNEED   4
#define MADV_FREE       8

void *mmap(void *__addr, size_t __len, int __prot, int __flags, int __fd, off_t __offset);
int   munmap(void *__addr, size_t __len);
int   mprotect(void *__addr, size_t __len, int __prot);
int   msync(void *__addr, size_t __len, int __flags);
int   madvise(void *__addr, size_t __len, int __advice);
int   mlock(const void *__addr, size_t __len);
int   munlock(const void *__addr, size_t __len);

#endif /* _RUBYCC_SYS_MMAN_H */
