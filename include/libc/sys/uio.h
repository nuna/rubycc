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
   (Step 123, M5 H2). */

#ifndef _RUBYCC_SYS_UIO_H
#define _RUBYCC_SYS_UIO_H

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_SSIZE_T
#define _RUBYCC_SSIZE_T
typedef long ssize_t;
#endif

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

#endif /* _RUBYCC_SYS_UIO_H */
