/* rubycc bundled <sys/mman.h>: the memory-mapping calls and the PROT_/MAP_/MS_/
   MADV_ flag macros (POSIX plus Linux extensions). Provenance: clean room
   against the Linux kernel UAPI (asm-generic/mman-common.h and mman.h), not
   derived from musl. The flag values and MAP_FAILED are that ABI reproduced as
   measured integer constants (an ABI fact, not copied text -- see
   docs/HEADER-LICENSING.md), the same treatment as errno.h and fcntl.h. mmap,
   munmap and kin are POSIX declarations. Common layer: almost every flag value
   is identical on x86-64 and aarch64 (both use the asm-generic assignments);
   the four that are not are written under an arch test below.

   Coverage against glibc's <sys/mman.h> under _GNU_SOURCE (audited
   2026-09-18, glibc 2.39, x86-64 and aarch64, with
   tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Seventy-two names were
   missing on x86-64 and seventy-one on aarch64; fifty-eight were added and
   the rest are deliberate. Every added value was printed from the glibc
   oracle on both arches on 2026-09-18 and agreed except the four arch ones
   (MAP_32BIT 64 and MAP_ABOVE4G 128 exist only on x86-64, PROT_BTI 16 and
   PROT_MTE 32 only on aarch64), and every added prototype was checked by
   declaring it immediately before `#include <sys/mman.h>` under gcc and
   aarch64-linux-gnu-gcc (a conflicting redeclaration is a hard error): clean
   on both arches. What was added, and why: the remaining mmap flags (a gem
   that maps a file reaches for MAP_FILE, MAP_TYPE, MAP_FIXED_NOREPLACE or the
   huge-page pair), the two extra protection bits, the memory-locking set
   (MCL_* with mlockall and munlockall), mincore, the POSIX advice names and
   posix_madvise, every remaining MADV_* advice value, mremap with its
   MREMAP_* flags, remap_file_pages, memfd_create with its MFD_* flags, and
   the POSIX shared-memory pair shm_open/shm_unlink (which is what mode_t is
   declared here for). Visibility rule as elsewhere: this header has always
   exposed the Linux extensions unconditionally, and the additions follow
   that.
   omitted: mmap64 -- an LFS64 alias, identical to mmap on an LP64 target, no
   corpus user (the same reasoning stdlib.h and unistd.h use).
   omitted: mlock2 MLOCK_ONFAULT -- the on-fault variant of mlock, glibc 2.27
   and later only, and no corpus user; mlock above covers the locking a gem
   does.
   omitted: pkey_alloc pkey_free pkey_get pkey_set pkey_mprotect
   PKEY_DISABLE_ACCESS PKEY_DISABLE_WRITE -- memory protection keys, a
   hardware feature glibc wraps from 2.27 on, with no corpus user.
   omitted: process_madvise process_mrelease -- cross-process advice and
   release, glibc 2.35 and 2.36 respectively, so declaring them would promise
   symbols an older host glibc does not export (the same reasoning unistd.h's
   close_range omission uses).
   omitted: SHADOW_STACK_SET_TOKEN -- an x86-64 shadow-stack helper glibc
   added in 2.39, with no corpus user and no aarch64 counterpart.
   omitted: <stddef.h> -- only size_t is needed, and it is declared here
   directly. */

#ifndef _RUBYCC_SYS_MMAN_H
#define _RUBYCC_SYS_MMAN_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_OFF_T
#define _RUBYCC_OFF_T
typedef long off_t;
#endif
#ifndef _RUBYCC_MODE_T
#define _RUBYCC_MODE_T
typedef unsigned int mode_t;
#endif

/* Memory protection bits (for mmap/mprotect). */
#define PROT_NONE  0x0
#define PROT_READ  0x1
#define PROT_WRITE 0x2
#define PROT_EXEC  0x4
/* Extend the mapping downwards/upwards in address space. */
#define PROT_GROWSDOWN 0x01000000
#define PROT_GROWSUP   0x02000000
/* Arch-specific protection bits: aarch64's branch-target-identification and
   memory-tagging pages have no x86-64 counterpart (measured 16 and 32). */
#if defined(__aarch64__)
#define PROT_BTI 0x10
#define PROT_MTE 0x20
#endif

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
#define MAP_DENYWRITE 0x00800
#define MAP_EXECUTABLE 0x01000
#define MAP_NONBLOCK  0x10000
#define MAP_HUGETLB   0x40000
#define MAP_SYNC      0x80000
#define MAP_FIXED_NOREPLACE 0x100000
/* MAP_FILE is the (no-op) opposite of MAP_ANONYMOUS; MAP_TYPE masks off the
   sharing mode; MAP_SHARED_VALIDATE is MAP_SHARED with unknown flags
   rejected. */
#define MAP_FILE      0x00000
#define MAP_TYPE      0x0000f
#define MAP_SHARED_VALIDATE 0x00003
/* Page size for MAP_HUGETLB, encoded as log2 in bits 26..31. */
#define MAP_HUGE_SHIFT 26
#define MAP_HUGE_MASK  0x3f
/* An x86-64-only placement pair: no aarch64 counterpart (measured 64, 128). */
#if defined(__x86_64__)
#define MAP_32BIT   0x40
#define MAP_ABOVE4G 0x80
#endif

/* mremap flags. */
#define MREMAP_MAYMOVE   1
#define MREMAP_FIXED     2
#define MREMAP_DONTUNMAP 4

/* memfd_create flags. */
#define MFD_CLOEXEC       0x0001
#define MFD_ALLOW_SEALING 0x0002
#define MFD_HUGETLB       0x0004
#define MFD_NOEXEC_SEAL   0x0008
#define MFD_EXEC          0x0010

/* mlockall flags. */
#define MCL_CURRENT 1
#define MCL_FUTURE  2
#define MCL_ONFAULT 4

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
#define MADV_REMOVE     9
#define MADV_DONTFORK   10
#define MADV_DOFORK     11
#define MADV_MERGEABLE  12
#define MADV_UNMERGEABLE 13
#define MADV_HUGEPAGE   14
#define MADV_NOHUGEPAGE 15
#define MADV_DONTDUMP   16
#define MADV_DODUMP     17
#define MADV_WIPEONFORK 18
#define MADV_KEEPONFORK 19
#define MADV_COLD       20
#define MADV_PAGEOUT    21
#define MADV_POPULATE_READ  22
#define MADV_POPULATE_WRITE 23
#define MADV_DONTNEED_LOCKED 24
#define MADV_COLLAPSE   25
#define MADV_HWPOISON   100

/* posix_madvise advice values, which are numbered separately from the
   MADV_* set above (measured 0..4). */
#define POSIX_MADV_NORMAL     0
#define POSIX_MADV_RANDOM     1
#define POSIX_MADV_SEQUENTIAL 2
#define POSIX_MADV_WILLNEED   3
#define POSIX_MADV_DONTNEED   4

void *mmap(void *__addr, size_t __len, int __prot, int __flags, int __fd, off_t __offset);
int   munmap(void *__addr, size_t __len);
int   mprotect(void *__addr, size_t __len, int __prot);
int   msync(void *__addr, size_t __len, int __flags);
int   madvise(void *__addr, size_t __len, int __advice);
int   posix_madvise(void *__addr, size_t __len, int __advice);
int   mincore(void *__start, size_t __len, unsigned char *__vec);
void *mremap(void *__addr, size_t __old_len, size_t __new_len, int __flags, ...);
int   remap_file_pages(void *__start, size_t __size, int __prot, size_t __pgoff, int __flags);
int   mlock(const void *__addr, size_t __len);
int   munlock(const void *__addr, size_t __len);
int   mlockall(int __flags);
int   munlockall(void);
int   memfd_create(const char *__name, unsigned int __flags);
/* POSIX shared memory objects, opened by name and then mmap'd. */
int   shm_open(const char *__name, int __oflag, mode_t __mode);
int   shm_unlink(const char *__name);

#endif /* _RUBYCC_SYS_MMAN_H */
