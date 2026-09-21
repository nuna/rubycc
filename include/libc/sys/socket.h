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
   aarch64.

   Coverage against glibc's <sys/socket.h> under _GNU_SOURCE (audited
   2026-09-18, glibc 2.39, x86-64 and aarch64, with
   tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Two hundred and thirty-nine
   names were missing on both arches; two hundred and thirty-four were added
   and five are deliberate. Every added macro value was printed from the glibc
   oracle on both arches on 2026-09-18 and all 226 of them agreed, so they all
   stay in the common layer; every added prototype and struct was checked by
   declaring it immediately before `#include <sys/socket.h>` under gcc and
   aarch64-linux-gnu-gcc (a conflicting redeclaration is a hard error), and
   struct ucred and struct mmsghdr's sizes and member offsets were measured on
   both arches and agreed (ucred 12 bytes, 4-byte aligned, pid/uid/gid at
   0/4/8; mmsghdr 64 bytes, 8-byte aligned, msg_hdr at 0 and msg_len at 56).

   What changed, and why. The AF_/PF_ note below used to say that the families
   are a numbered space nobody had measured, so only the ones a corpus gem
   asked for by name were here. That reasoning does not survive the audit: the
   space is closed, and one probe prints all of it for both arches at once, so
   all forty-four remaining families (and their PF_ aliases) are here now. The
   same argument carries the rest of the SOL_SOCKET option names, the protocol
   SOL_* levels, the remaining MSG_ flags and the socket ioctl requests --
   these are precisely the numbers a gem passes to setsockopt/getsockopt, and
   a missing one is not an error a gem's extconf notices, it is a gem built
   with less function than gcc would have given it (the reasoning
   bundled-headers-coverage-audit-2 used for <sys/ioctl.h>'s SIOC* set).

   The ancillary-data macros are the other substantive gap this closes. This
   header has carried struct msghdr and struct cmsghdr since Step 88, but
   without CMSG_FIRSTHDR/CMSG_NXTHDR/CMSG_DATA/CMSG_LEN/CMSG_SPACE/CMSG_ALIGN
   there is no portable way to *write* or walk a control buffer, which is what
   SCM_RIGHTS file-descriptor passing and SO_PEERCRED/SCM_CREDENTIALS need.
   Their bodies are rubycc's own spelling, checked against glibc's by
   differential rather than copied (R11, docs/reference/HEADER-LICENSING.md
   sec. 6): a probe compared the two on 2026-09-18 for every payload length
   0..1023 and, for CMSG_FIRSTHDR/CMSG_NXTHDR/CMSG_DATA, over a walk of a
   512-byte control buffer at every msg_controllen 0..511 holding three
   records, on x86-64 and on aarch64 (cross gcc + qemu). Zero mismatches on
   either arch. Two facts that walk depends on came out of the same
   measurement: CMSG_ALIGN rounds up to sizeof(size_t), and glibc's
   __cmsg_nxthdr stops when the *current* record plus a whole cmsghdr would
   not fit -- it does not look at the next record's cmsg_len. CMSG_NXTHDR
   below therefore names its arguments more than once, the way the kernel's
   own UAPI macro does; glibc hides that behind an inline function, which a
   macro cannot do.
   omitted: SOCK_PACKET -- the obsolete raw-packet socket type, replaced by
   AF_PACKET above and rejected by current kernels.
   omitted: struct osockaddr -- the pre-4.3BSD socket address, which nothing
   on Linux produces or consumes.
   omitted: isfdtype -- a BSD predicate for "is this descriptor of that type",
   answerable with fstat and S_ISSOCK, with no corpus user.
   omitted: SIOCGSTAMP_OLD SIOCGSTAMPNS_OLD -- the pre-y2038 spellings of the
   packet-timestamp ioctls, which glibc keeps only so that its own
   SIOCGSTAMP/SIOCGSTAMPNS can choose between the old and new request numbers
   at runtime; a program writes SIOCGSTAMP, which <sys/ioctl.h> carries.
   omitted: <endian.h> <stddef.h> <sys/select.h> <sys/types.h> -- glibc gets
   size_t and the id types here by pulling in the whole <sys/types.h> chain,
   which drags <endian.h> and <sys/select.h> along with it; this header
   declares the handful it needs directly, under the shared _RUBYCC_* and
   _STRUCT_TIMESPEC guards. */

#ifndef _RUBYCC_SYS_SOCKET_H
#define _RUBYCC_SYS_SOCKET_H

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
#ifndef _RUBYCC_SOCKLEN_T
#define _RUBYCC_SOCKLEN_T
typedef unsigned int socklen_t;
#endif
#ifndef _RUBYCC_SA_FAMILY_T
#define _RUBYCC_SA_FAMILY_T
typedef unsigned short sa_family_t;
#endif
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

/* struct ucred: 12 bytes, 4-byte aligned, members at 0/4/8 (measured, both
   arches). The credentials SO_PEERCRED reports and SCM_CREDENTIALS carries. */
struct ucred {
  pid_t pid; /* offset 0 */
  uid_t uid; /* offset 4 */
  gid_t gid; /* offset 8 */
};

/* struct mmsghdr: 64 bytes, 8-byte aligned (measured, both arches), one entry
   of the vector recvmmsg/sendmmsg take. The four bytes after msg_len are
   padding the ABI leaves in place. */
struct mmsghdr {
  struct msghdr msg_hdr; /* offset 0  */
  unsigned int  msg_len; /* offset 56 */
};

/* Address / protocol families (Linux kernel UAPI). */
#define AF_UNSPEC 0
#define AF_UNIX   1
#define AF_LOCAL  AF_UNIX
#define AF_INET   2
#define AF_INET6  10
/* AF_NETLINK is the kernel-configuration socket family, the first one added
   beyond the five above because a corpus gem asked for it by name (raindrops'
   linux_inet_diag.c opens one to read TCP listen queues). The rest of the
   numbered space followed in bundled-headers-io-batch-1, once one probe had
   measured all of it on both arches (see the header note). */
#define AF_NETLINK 16

#define PF_UNSPEC AF_UNSPEC
#define PF_UNIX   AF_UNIX
#define PF_LOCAL  AF_UNIX
#define PF_INET   AF_INET
#define PF_INET6  AF_INET6
#define PF_NETLINK AF_NETLINK

/* The rest of the address families the kernel numbers (measured, both
   arches agree). */
#define AF_ALG        38
#define AF_APPLETALK  5
#define AF_ASH        18
#define AF_ATMPVC     8
#define AF_ATMSVC     20
#define AF_AX25       3
#define AF_BLUETOOTH  31
#define AF_BRIDGE     7
#define AF_CAIF       37
#define AF_CAN        29
#define AF_DECnet     12
#define AF_ECONET     19
#define AF_FILE       AF_UNIX
#define AF_IB         27
#define AF_IEEE802154 36
#define AF_IPX        4
#define AF_IRDA       23
#define AF_ISDN       34
#define AF_IUCV       32
#define AF_KCM        41
#define AF_KEY        15
#define AF_LLC        26
#define AF_MAX        46
#define AF_MCTP       45
#define AF_MPLS       28
#define AF_NETBEUI    13
#define AF_NETROM     6
#define AF_NFC        39
#define AF_PACKET     17
#define AF_PHONET     35
#define AF_PPPOX      24
#define AF_QIPCRTR    42
#define AF_RDS        21
#define AF_ROSE       11
#define AF_ROUTE      16
#define AF_RXRPC      33
#define AF_SECURITY   14
#define AF_SMC        43
#define AF_SNA        22
#define AF_TIPC       30
#define AF_VSOCK      40
#define AF_WANPIPE    25
#define AF_X25        9
#define AF_XDP        44

/* Each protocol family is its address family's number. */
#define PF_ALG        AF_ALG
#define PF_APPLETALK  AF_APPLETALK
#define PF_ASH        AF_ASH
#define PF_ATMPVC     AF_ATMPVC
#define PF_ATMSVC     AF_ATMSVC
#define PF_AX25       AF_AX25
#define PF_BLUETOOTH  AF_BLUETOOTH
#define PF_BRIDGE     AF_BRIDGE
#define PF_CAIF       AF_CAIF
#define PF_CAN        AF_CAN
#define PF_DECnet     AF_DECnet
#define PF_ECONET     AF_ECONET
#define PF_FILE       AF_FILE
#define PF_IB         AF_IB
#define PF_IEEE802154 AF_IEEE802154
#define PF_IPX        AF_IPX
#define PF_IRDA       AF_IRDA
#define PF_ISDN       AF_ISDN
#define PF_IUCV       AF_IUCV
#define PF_KCM        AF_KCM
#define PF_KEY        AF_KEY
#define PF_LLC        AF_LLC
#define PF_MAX        AF_MAX
#define PF_MCTP       AF_MCTP
#define PF_MPLS       AF_MPLS
#define PF_NETBEUI    AF_NETBEUI
#define PF_NETROM     AF_NETROM
#define PF_NFC        AF_NFC
#define PF_PACKET     AF_PACKET
#define PF_PHONET     AF_PHONET
#define PF_PPPOX      AF_PPPOX
#define PF_QIPCRTR    AF_QIPCRTR
#define PF_RDS        AF_RDS
#define PF_ROSE       AF_ROSE
#define PF_ROUTE      AF_ROUTE
#define PF_RXRPC      AF_RXRPC
#define PF_SECURITY   AF_SECURITY
#define PF_SMC        AF_SMC
#define PF_SNA        AF_SNA
#define PF_TIPC       AF_TIPC
#define PF_VSOCK      AF_VSOCK
#define PF_WANPIPE    AF_WANPIPE
#define PF_X25        AF_X25
#define PF_XDP        AF_XDP

/* Two more socket types (SOCK_PACKET is left out, see the header note). */
#define SOCK_RDM  4
#define SOCK_DCCP 6

/* getsockopt/setsockopt levels for the protocols above SOL_SOCKET
   (measured, both arches agree). */
#define SOL_AAL       265
#define SOL_ALG       279
#define SOL_ATM       264
#define SOL_BLUETOOTH 274
#define SOL_CAIF      278
#define SOL_DCCP      269
#define SOL_DECNET    261
#define SOL_IRDA      266
#define SOL_IUCV      277
#define SOL_KCM       281
#define SOL_LLC       268
#define SOL_MCTP      285
#define SOL_MPTCP     284
#define SOL_NETBEUI   267
#define SOL_NETLINK   270
#define SOL_NFC       280
#define SOL_PACKET    263
#define SOL_PNPIPE    275
#define SOL_PPPOL2TP  273
#define SOL_RAW       255
#define SOL_RDS       276
#define SOL_RXRPC     272
#define SOL_SMC       286
#define SOL_TIPC      271
#define SOL_TLS       282
#define SOL_X25       262
#define SOL_XDP       283

/* The rest of the SOL_SOCKET option names (asm-generic/socket.h,
   measured on both arches). */
#define SO_ACCEPTCONN                    30
#define SO_ATTACH_BPF                    50
#define SO_ATTACH_FILTER                 26
#define SO_ATTACH_REUSEPORT_CBPF         51
#define SO_ATTACH_REUSEPORT_EBPF         52
#define SO_BINDTODEVICE                  25
#define SO_BINDTOIFINDEX                 62
#define SO_BPF_EXTENSIONS                48
#define SO_BSDCOMPAT                     14
#define SO_BUF_LOCK                      72
#define SO_BUSY_POLL                     46
#define SO_BUSY_POLL_BUDGET              70
#define SO_CNX_ADVICE                    53
#define SO_COOKIE                        57
#define SO_DEBUG                         1
#define SO_DETACH_BPF                    27
#define SO_DETACH_FILTER                 27
#define SO_DETACH_REUSEPORT_BPF          68
#define SO_DOMAIN                        39
#define SO_DONTROUTE                     5
#define SO_GET_FILTER                    26
#define SO_INCOMING_CPU                  49
#define SO_INCOMING_NAPI_ID              56
#define SO_LOCK_FILTER                   44
#define SO_MARK                          36
#define SO_MAX_PACING_RATE               47
#define SO_MEMINFO                       55
#define SO_NETNS_COOKIE                  71
#define SO_NOFCS                         43
#define SO_NO_CHECK                      11
#define SO_OOBINLINE                     10
#define SO_PASSCRED                      16
#define SO_PASSPIDFD                     76
#define SO_PASSSEC                       34
#define SO_PEEK_OFF                      42
#define SO_PEERCRED                      17
#define SO_PEERGROUPS                    59
#define SO_PEERNAME                      28
#define SO_PEERPIDFD                     77
#define SO_PEERSEC                       31
#define SO_PREFER_BUSY_POLL              69
#define SO_PRIORITY                      12
#define SO_PROTOCOL                      38
#define SO_RCVBUFFORCE                   33
#define SO_RCVLOWAT                      18
#define SO_RCVMARK                       75
#define SO_RCVTIMEO                      20
#define SO_RCVTIMEO_NEW                  66
#define SO_RCVTIMEO_OLD                  20
#define SO_RESERVE_MEM                   73
#define SO_RXQ_OVFL                      40
#define SO_SECURITY_AUTHENTICATION       22
#define SO_SECURITY_ENCRYPTION_NETWORK   24
#define SO_SECURITY_ENCRYPTION_TRANSPORT 23
#define SO_SELECT_ERR_QUEUE              45
#define SO_SNDBUFFORCE                   32
#define SO_SNDLOWAT                      19
#define SO_SNDTIMEO                      21
#define SO_SNDTIMEO_NEW                  67
#define SO_SNDTIMEO_OLD                  21
#define SO_TIMESTAMP                     29
#define SO_TIMESTAMPING                  37
#define SO_TIMESTAMPING_NEW              65
#define SO_TIMESTAMPING_OLD              37
#define SO_TIMESTAMPNS                   35
#define SO_TIMESTAMPNS_NEW               64
#define SO_TIMESTAMPNS_OLD               35
#define SO_TIMESTAMP_NEW                 63
#define SO_TIMESTAMP_OLD                 29
#define SO_TXREHASH                      74
#define SO_TXTIME                        61
#define SO_WIFI_STATUS                   41
#define SO_ZEROCOPY                      60

/* The rest of the send/recv message flags. */
#define MSG_BATCH        0x40000
#define MSG_CMSG_CLOEXEC 0x40000000
#define MSG_CONFIRM      0x800
#define MSG_CTRUNC       0x8
#define MSG_DONTROUTE    0x4
#define MSG_EOR          0x80
#define MSG_ERRQUEUE     0x2000
#define MSG_FASTOPEN     0x20000000
#define MSG_FIN          0x200
#define MSG_MORE         0x8000
#define MSG_PROXY        0x10
#define MSG_RST          0x1000
#define MSG_SYN          0x400
#define MSG_TRYHARD      0x4
#define MSG_WAITFORONE   0x10000
#define MSG_ZEROCOPY     0x4000000

/* Ancillary-data record types carried in a cmsghdr's cmsg_type. */
#define SCM_CREDENTIALS            2
#define SCM_PIDFD                  4
#define SCM_RIGHTS                 1
#define SCM_SECURITY               3
#define SCM_TIMESTAMP              29
#define SCM_TIMESTAMPING           37
#define SCM_TIMESTAMPING_OPT_STATS 54
#define SCM_TIMESTAMPING_PKTINFO   58
#define SCM_TIMESTAMPNS            35
#define SCM_TXTIME                 61
#define SCM_WIFI_STATUS            41

/* Socket ioctl requests and the BSD aliases glibc gives two of them
   (measured, both arches agree; the same numbers <sys/ioctl.h> carries). */
#define SIOCATMARK 0x8905
#define SIOCGPGRP  0x8904
#define SIOCSPGRP  0x8902
#define FIOGETOWN  0x8903
#define FIOSETOWN  0x8901

#define SOMAXCONN 4096


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
/* accept4 is the Linux extension that folds SOCK_CLOEXEC / SOCK_NONBLOCK into
   the accept itself, closing the race a separate fcntl leaves open. glibc gates
   it behind _GNU_SOURCE; this header exposes SOCK_CLOEXEC unconditionally
   already (see the socket types above), so the declaration follows the same
   rule rather than growing a feature-test macro of its own. kgio's accept.c
   calls it whenever its extconf found it. */
int     accept4(int __fd, struct sockaddr *__addr, socklen_t *__addr_len, int __flags);
int     shutdown(int __fd, int __how);
/* True when the read pointer of fd sits at an out-of-band mark. */
int     sockatmark(int __fd);
/* Send/receive several messages with one call (Linux extension). */
int     recvmmsg(int __fd, struct mmsghdr *__vmessages, unsigned int __vlen, int __flags,
                 struct timespec *__tmo);
int     sendmmsg(int __fd, struct mmsghdr *__vmessages, unsigned int __vlen, int __flags);

/* Ancillary data (control messages). Every body below is rubycc's own
   spelling of behaviour measured against glibc -- see the header note for the
   differential that compared them. CMSG_ALIGN rounds a length up to a
   size_t boundary; CMSG_LEN is what a record's cmsg_len should be set to for
   a payload of `len' bytes; CMSG_SPACE is how much buffer that record then
   occupies. */
#define CMSG_ALIGN(len) (((len) + (sizeof (size_t) - 1)) & ~(sizeof (size_t) - 1))
#define CMSG_LEN(len)   (CMSG_ALIGN (sizeof (struct cmsghdr)) + (len))
#define CMSG_SPACE(len) (CMSG_ALIGN (len) + CMSG_ALIGN (sizeof (struct cmsghdr)))
#define CMSG_DATA(cmsg) ((unsigned char *) ((struct cmsghdr *) (cmsg) + 1))
#define CMSG_FIRSTHDR(mhdr) \
  ((size_t) (mhdr)->msg_controllen >= sizeof (struct cmsghdr) \
   ? (struct cmsghdr *) (mhdr)->msg_control : (struct cmsghdr *) 0)
/* Bytes needed to round `len' up to a size_t boundary, written so that a
   cmsg_len close to SIZE_MAX cannot make the sum wrap. */
#define __RUBYCC_CMSG_PAD(len)  ((0 - (size_t) (len)) & (sizeof (size_t) - 1))
/* Bytes from `cmsg' to the end of the control buffer. */
#define __RUBYCC_CMSG_ROOM(mhdr, cmsg) \
  ((size_t) ((unsigned char *) (mhdr)->msg_control + (mhdr)->msg_controllen \
             - (unsigned char *) (cmsg)))
/* The next record, or a null pointer when the current one is malformed or
   when the buffer has no room for this record plus a whole header after it.
   Names both arguments more than once (see the header note). */
#define CMSG_NXTHDR(mhdr, cmsg) \
  (((size_t) (cmsg)->cmsg_len < sizeof (struct cmsghdr) \
    || __RUBYCC_CMSG_ROOM (mhdr, cmsg) \
       < sizeof (struct cmsghdr) + __RUBYCC_CMSG_PAD ((cmsg)->cmsg_len) \
    || (__RUBYCC_CMSG_ROOM (mhdr, cmsg) \
        - (sizeof (struct cmsghdr) + __RUBYCC_CMSG_PAD ((cmsg)->cmsg_len))) \
       < (size_t) (cmsg)->cmsg_len) \
   ? (struct cmsghdr *) 0 \
   : (struct cmsghdr *) ((unsigned char *) (cmsg) \
                         + CMSG_ALIGN ((cmsg)->cmsg_len)))

#endif /* _RUBYCC_SYS_SOCKET_H */
