/* rubycc bundled <sys/socket.h>: the socket address family / type / option
   macros, the socket address structs (sockaddr, sockaddr_storage, msghdr,
   iovec, cmsghdr, linger) and the POSIX socket calls. Provenance: clean room
   against the Linux kernel UAPI (linux/socket.h, asm-generic/socket.h,
   linux/uio.h) and the glibc socket ABI, not derived from musl. The AF_/PF_/
   SOCK_/SOL_/SO_/MSG_/SHUT_ values and the struct layouts are that ABI
   reproduced as measured integer constants and measured field offsets (an ABI
   fact, not copied text -- see docs/HEADER-LICENSING.md), the same treatment
   as errno.h and fcntl.h. socket, bind, connect and kin are POSIX declarations
   whose bodies resolve from the host libc at link time. Common layer: every
   macro value and every struct layout below (struct sockaddr, sockaddr_storage,
   msghdr, iovec, cmsghdr and linger all included) is identical on x86-64 and
   aarch64. */

#ifndef _RUBYCC_SYS_SOCKET_H
#define _RUBYCC_SYS_SOCKET_H

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_SSIZE_T
#define _RUBYCC_SSIZE_T
typedef long ssize_t;
#endif
#ifndef _RUBYCC_SOCKLEN_T
#define _RUBYCC_SOCKLEN_T
typedef unsigned int socklen_t;
#endif
#ifndef _RUBYCC_SA_FAMILY_T
#define _RUBYCC_SA_FAMILY_T
typedef unsigned short sa_family_t;
#endif

/* struct iovec: 16 bytes, 8-byte aligned (measured, both arches). */
#ifndef _RUBYCC_STRUCT_IOVEC
#define _RUBYCC_STRUCT_IOVEC
struct iovec {
  void  *iov_base; /* offset 0 */
  size_t iov_len;  /* offset 8 */
};
#endif

/* struct sockaddr: 16 bytes, the generic socket address (POSIX/glibc). */
struct sockaddr {
  sa_family_t sa_family;   /* offset 0 */
  char        sa_data[14]; /* offset 2 */
};

/* struct sockaddr_storage: 128 bytes, 8-byte aligned (measured, both arches),
   large and aligned enough to hold any of the protocol-specific sockaddr_*
   structs. __ss_align forces the 8-byte alignment and pads the struct out to
   the full 128 bytes. */
struct sockaddr_storage {
  sa_family_t   ss_family;       /* offset 0   */
  char          __ss_padding[118]; /* offset 2 */
  unsigned long __ss_align;      /* offset 120 */
};

/* struct msghdr: 56 bytes (measured, both arches), the sendmsg/recvmsg
   scatter-gather message descriptor. */
struct msghdr {
  void         *msg_name;       /* offset 0  */
  socklen_t     msg_namelen;    /* offset 8  */
  struct iovec *msg_iov;        /* offset 16 */
  size_t        msg_iovlen;     /* offset 24 */
  void         *msg_control;    /* offset 32 */
  size_t        msg_controllen; /* offset 40 */
  int           msg_flags;      /* offset 48 */
};

/* struct cmsghdr: 16 bytes, one ancillary-data record header. */
struct cmsghdr {
  size_t cmsg_len;   /* offset 0  */
  int    cmsg_level; /* offset 8  */
  int    cmsg_type;  /* offset 12 */
};

/* struct linger: 8 bytes, the SO_LINGER option payload. */
struct linger {
  int l_onoff;
  int l_linger;
};

/* Address / protocol families (Linux kernel UAPI). */
#define AF_UNSPEC 0
#define AF_UNIX   1
#define AF_LOCAL  AF_UNIX
#define AF_INET   2
#define AF_INET6  10

#define PF_UNSPEC AF_UNSPEC
#define PF_UNIX   AF_UNIX
#define PF_LOCAL  AF_UNIX
#define PF_INET   AF_INET
#define PF_INET6  AF_INET6

/* Socket types. SOCK_CLOEXEC/SOCK_NONBLOCK are Linux extensions that may be
   OR'd into the type argument of socket()/socketpair(). */
#define SOCK_STREAM    1
#define SOCK_DGRAM     2
#define SOCK_RAW       3
#define SOCK_SEQPACKET 5
#define SOCK_NONBLOCK  0x800
#define SOCK_CLOEXEC   0x80000

/* getsockopt/setsockopt level and SO_* option names (asm-generic/socket.h). */
#define SOL_SOCKET 1

#define SO_REUSEADDR 2
#define SO_TYPE      3
#define SO_ERROR     4
#define SO_BROADCAST 6
#define SO_SNDBUF    7
#define SO_RCVBUF    8
#define SO_KEEPALIVE 9
#define SO_LINGER    13
#define SO_REUSEPORT 15

/* send/recv message flags. */
#define MSG_OOB      1
#define MSG_PEEK     2
#define MSG_TRUNC    0x20
#define MSG_DONTWAIT 0x40
#define MSG_WAITALL  0x100
#define MSG_NOSIGNAL 0x4000

/* shutdown() how. */
#define SHUT_RD   0
#define SHUT_WR   1
#define SHUT_RDWR 2

int     socket(int __domain, int __type, int __protocol);
int     socketpair(int __domain, int __type, int __protocol, int __fds[2]);
int     bind(int __fd, const struct sockaddr *__addr, socklen_t __len);
int     getsockname(int __fd, struct sockaddr *__addr, socklen_t *__len);
int     connect(int __fd, const struct sockaddr *__addr, socklen_t __len);
int     getpeername(int __fd, struct sockaddr *__addr, socklen_t *__len);
ssize_t send(int __fd, const void *__buf, size_t __n, int __flags);
ssize_t recv(int __fd, void *__buf, size_t __n, int __flags);
ssize_t sendto(int __fd, const void *__buf, size_t __n, int __flags,
               const struct sockaddr *__addr, socklen_t __addr_len);
ssize_t recvfrom(int __fd, void *__buf, size_t __n, int __flags,
                  struct sockaddr *__addr, socklen_t *__addr_len);
ssize_t sendmsg(int __fd, const struct msghdr *__message, int __flags);
ssize_t recvmsg(int __fd, struct msghdr *__message, int __flags);
int     getsockopt(int __fd, int __level, int __optname, void *__optval, socklen_t *__optlen);
int     setsockopt(int __fd, int __level, int __optname, const void *__optval, socklen_t __optlen);
int     listen(int __fd, int __n);
int     accept(int __fd, struct sockaddr *__addr, socklen_t *__addr_len);
int     shutdown(int __fd, int __how);

#endif /* _RUBYCC_SYS_SOCKET_H */
