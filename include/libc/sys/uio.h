/* rubycc bundled <sys/uio.h>: scatter/gather I/O (POSIX.1). Provenance: clean
   room against the POSIX public interface and the Linux kernel UAPI
   (linux/uio.h); struct iovec's member names, types and order are that ABI's
   own public contract, not glibc implementation detail. Reuses the
   _RUBYCC_STRUCT_IOVEC guard sys/socket.h already defines the struct under, so
   the two headers agree rather than redefine when both are included; its
   16-byte size and both members' offsets were measured against the glibc
   oracle on both x86-64 and aarch64 (see sys/socket.h's SOCKET case and this
   header's UIO case in test/test_header_abi.rb) and the two agreed exactly (a
   pointer-and-size_t struct has no arch-dependent field widths on either LP64
   target), so this header lives in the common layer. readv/writev are POSIX
   declarations whose bodies resolve from the host libc at link time
   (Step 123, M5 H2).

   Coverage against glibc's <sys/uio.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, x86-64 and aarch64, with tools/audit_bundled_headers.rb; table
   in docs/development/BUNDLED-HEADERS-COVERAGE.md). Sixteen names were
   missing; three were added and thirteen are deliberate. Added: UIO_MAXIOV
   (measured 1024 on both arches -- the kernel's per-call iovec-count ceiling,
   which a gem batching writes has to clamp to), and preadv/pwritev, the
   positional forms every gem that does scatter/gather I/O at an explicit
   offset reaches for. Both prototypes were checked by declaring them
   immediately before `#include <sys/uio.h>` under gcc and
   aarch64-linux-gnu-gcc (a conflicting redeclaration is a hard error) on
   2026-09-18. Visibility rule as elsewhere: preadv/pwritev are what glibc
   shows in gcc's default mode, so they are declared unconditionally.
   omitted: preadv2 pwritev2 RWF_APPEND RWF_DSYNC RWF_HIPRI RWF_NOWAIT
   RWF_SYNC -- the flagged forms of the same two calls, glibc 2.26 and later
   only and with no corpus user; adding them would promise symbols an older
   host glibc does not export (the same reasoning unistd.h's close_range
   omission uses).
   omitted: process_vm_readv process_vm_writev -- cross-process memory
   transfer, a debugger/tracer interface no gem's C extension reaches.
   omitted: preadv64 preadv64v2 pwritev64 pwritev64v2 -- LFS64 aliases,
   identical to the unsuffixed calls on an LP64 target, no corpus user.
   omitted: <endian.h> <stddef.h> <sys/select.h> <sys/types.h> -- glibc gets
   ssize_t/size_t/off_t here by pulling in the whole <sys/types.h> chain,
   which drags <endian.h> and <sys/select.h> along with it; this header
   declares the three typedefs directly instead, under the shared _RUBYCC_*
   guards. */

#ifndef _RUBYCC_SYS_UIO_H
#define _RUBYCC_SYS_UIO_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

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

/* The largest iovec count one readv/writev call accepts (measured: 1024 on
   both arches). */
#define UIO_MAXIOV 1024

/* struct iovec: 16 bytes, 8-byte aligned (measured, both arches). Shared with
   sys/socket.h under the same guard. */
#ifndef _RUBYCC_STRUCT_IOVEC
#define _RUBYCC_STRUCT_IOVEC
struct iovec {
  void  *iov_base; /* offset 0 */
  size_t iov_len;  /* offset 8 */
};
#endif

ssize_t readv(int __fd, const struct iovec *__iov, int __iovcnt);
ssize_t writev(int __fd, const struct iovec *__iov, int __iovcnt);
ssize_t preadv(int __fd, const struct iovec *__iov, int __iovcnt, off_t __offset);
ssize_t pwritev(int __fd, const struct iovec *__iov, int __iovcnt, off_t __offset);

#endif /* _RUBYCC_SYS_UIO_H */
