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

/* The TCP state machine's states, as reported by TCP_INFO's tcpi_state and by
   the kernel's inet_diag netlink replies. glibc spells them as an anonymous
   enum and then #defines each name to itself, so a program can test one with
   #ifdef; plain object macros are indistinguishable from that and are what the
   rest of this header already uses. Measured, and identical on x86-64 and
   aarch64. raindrops' linux_inet_diag.c compares idiag_state against
   TCP_ESTABLISHED and TCP_LISTEN to split active connections from the listen
   queue. */
#define TCP_ESTABLISHED 1
#define TCP_SYN_SENT    2
#define TCP_SYN_RECV    3
#define TCP_FIN_WAIT1   4
#define TCP_FIN_WAIT2   5
#define TCP_TIME_WAIT   6
#define TCP_CLOSE       7
#define TCP_CLOSE_WAIT  8
#define TCP_LAST_ACK    9
#define TCP_LISTEN      10
#define TCP_CLOSING     11

#endif /* _RUBYCC_NETINET_TCP_H */
