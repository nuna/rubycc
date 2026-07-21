/* rubycc bundled <netinet/tcp.h>: the TCP-level setsockopt/getsockopt option
   names (used with level IPPROTO_TCP). Provenance: clean room against the Linux
   kernel UAPI (linux/tcp.h), not derived from musl. The TCP_* values are that
   ABI reproduced as measured integer constants (an ABI fact, not copied text --
   see docs/HEADER-LICENSING.md), the same treatment as errno.h and fcntl.h.
   Common layer: every value is identical on x86-64 and aarch64. The large
   struct tcp_info diagnostic block is deliberately omitted -- gems reach this
   header for the option names (TCP_NODELAY and kin), not that struct. */

#ifndef _RUBYCC_NETINET_TCP_H
#define _RUBYCC_NETINET_TCP_H

#define TCP_NODELAY      1
#define TCP_MAXSEG       2
#define TCP_CORK         3
#define TCP_KEEPIDLE     4
#define TCP_KEEPINTVL    5
#define TCP_KEEPCNT      6
#define TCP_INFO         11
#define TCP_QUICKACK     12
#define TCP_USER_TIMEOUT 18
#define TCP_FASTOPEN     23

#endif /* _RUBYCC_NETINET_TCP_H */
