/* rubycc bundled <netinet/tcp.h>: the TCP-level setsockopt/getsockopt option
   names (used with level IPPROTO_TCP). Provenance: clean room against the Linux
   kernel UAPI (linux/tcp.h), not derived from musl. The TCP_* values are that
   ABI reproduced as measured integer constants (an ABI fact, not copied text --
   see docs/HEADER-LICENSING.md), the same treatment as errno.h and fcntl.h.
   Common layer: every value is identical on x86-64 and aarch64.

   Coverage against glibc's <netinet/tcp.h> under _GNU_SOURCE (audited
   2026-09-18, glibc 2.39, x86-64 and aarch64, with
   tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Ninety names were missing on
   both arches; eighty-two were added and eight are deliberate. Added: every
   remaining TCP_* option name and argument value, SOL_TCP, the TCPI_OPT_*
   bits, the TCPOPT_* / TCPOLEN_* option kinds and lengths and the TH_* flag
   bits -- 81 values printed from the glibc oracle on both arches on
   2026-09-18, all agreeing -- and tcp_seq, confirmed to be uint32_t on both
   arches with __builtin_types_compatible_p. <sys/socket.h> and <stdint.h> are
   now included, as glibc's <netinet/tcp.h> includes them, so a program that
   includes only this header still has socklen_t, setsockopt and uint32_t.
   omitted: struct tcp_info enum tcp_ca_state -- the TCP_INFO reply block.
   glibc's struct tcp_info is a frozen snapshot of the kernel's (measured 104
   bytes on both arches on 2026-09-18) while the kernel keeps appending fields,
   and getsockopt already reports how much it filled; reproducing one
   snapshot would be a layout nobody here consumes. The TCPI_OPT_* bits and
   TCP_CA_* states it reports are defined above, and the states are written
   as plain macros, so no enum tag is needed to use them.
   omitted: struct tcphdr -- the on-the-wire TCP header, which glibc spells as
   an anonymous union of the BSD th_* members and the Linux bit-field members,
   with bit-field order depending on byte order; only a raw-socket packet
   builder needs it, and no corpus gem is one.
   omitted: struct tcp_md5sig struct tcp_repair_opt struct tcp_repair_window
   struct tcp_zerocopy_receive struct tcp_cookie_transactions -- the payloads
   of the specialist options (MD5 signatures, checkpoint/restore, zero-copy
   receive, the withdrawn cookie transactions); the option names and their
   constants are above, the payload layouts have no corpus user.
   omitted: <endian.h> <stddef.h> <sys/select.h> <sys/types.h> -- glibc
   reaches them through its <sys/socket.h> and <stdint.h> chain; the bundled
   <sys/socket.h> declares what this header's users need directly. */

#ifndef _RUBYCC_NETINET_TCP_H
#define _RUBYCC_NETINET_TCP_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

/* glibc's <netinet/tcp.h> includes both; programs rely on it. */
#include <stdint.h>
#include <sys/socket.h>

/* A TCP sequence number (confirmed uint32_t on both arches). */
typedef uint32_t tcp_seq;

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

/* The rest of the IPPROTO_TCP-level option names (measured, both arches
   agree), in kernel order. */
#define TCP_SYNCNT               7
#define TCP_LINGER2              8
#define TCP_DEFER_ACCEPT         9
#define TCP_WINDOW_CLAMP         10
#define TCP_CONGESTION           13
#define TCP_MD5SIG               14
#define TCP_COOKIE_TRANSACTIONS  15
#define TCP_THIN_LINEAR_TIMEOUTS 16
#define TCP_THIN_DUPACK          17
#define TCP_REPAIR               19
#define TCP_REPAIR_QUEUE         20
#define TCP_QUEUE_SEQ            21
#define TCP_REPAIR_OPTIONS       22
#define TCP_TIMESTAMP            24
#define TCP_NOTSENT_LOWAT        25
#define TCP_CC_INFO              26
#define TCP_SAVE_SYN             27
#define TCP_SAVED_SYN            28
#define TCP_REPAIR_WINDOW        29
#define TCP_FASTOPEN_CONNECT     30
#define TCP_ULP                  31
#define TCP_MD5SIG_EXT           32
#define TCP_FASTOPEN_KEY         33
#define TCP_FASTOPEN_NO_COOKIE   34
#define TCP_ZEROCOPY_RECEIVE     35
#define TCP_CM_INQ               36
#define TCP_INQ                  36
#define TCP_TX_DELAY             37

/* The level name glibc gives IPPROTO_TCP. */
#define SOL_TCP 6

/* Argument values and limits that go with the options above:
   congestion-avoidance states, TCP_REPAIR modes and queues, TCP_MD5SIG
   flags and key size, and the classic MSS / window constants. */
#define TCP_CA_CWR              2
#define TCP_CA_Disorder         1
#define TCP_CA_Loss             4
#define TCP_CA_Open             0
#define TCP_CA_Recovery         3
#define TCP_COOKIE_IN_ALWAYS    1
#define TCP_COOKIE_MAX          16
#define TCP_COOKIE_MIN          8
#define TCP_COOKIE_OUT_NEVER    2
#define TCP_COOKIE_PAIR_SIZE    32
#define TCP_MAXWIN              65535
#define TCP_MAX_WINSHIFT        14
#define TCP_MD5SIG_FLAG_IFINDEX 2
#define TCP_MD5SIG_FLAG_PREFIX  1
#define TCP_MD5SIG_MAXKEYLEN    80
#define TCP_MSS                 512
#define TCP_MSS_DEFAULT         536
#define TCP_MSS_DESIRED         1220
#define TCP_NO_QUEUE            0
#define TCP_QUEUES_NR           3
#define TCP_RECV_QUEUE          1
#define TCP_REPAIR_OFF          0
#define TCP_REPAIR_OFF_NO_WP    -1
#define TCP_REPAIR_ON           1
#define TCP_SEND_QUEUE          2
#define TCP_S_DATA_IN           4
#define TCP_S_DATA_OUT          8

/* tcpi_options bits of a TCP_INFO reply. */
#define TCPI_OPT_ECN        8
#define TCPI_OPT_ECN_SEEN   16
#define TCPI_OPT_SACK       2
#define TCPI_OPT_SYN_DATA   32
#define TCPI_OPT_TIMESTAMPS 1
#define TCPI_OPT_WSCALE     4

/* TCP header option kinds and lengths, and the header flag bits (RFC 793,
   1323, 2018), for code that parses segments itself. */
#define TCPOLEN_MAXSEG         4
#define TCPOLEN_SACK_PERMITTED 2
#define TCPOLEN_TIMESTAMP      10
#define TCPOLEN_TSTAMP_APPA    12
#define TCPOLEN_WINDOW         3
#define TCPOPT_EOL             0
#define TCPOPT_MAXSEG          2
#define TCPOPT_NOP             1
#define TCPOPT_SACK            5
#define TCPOPT_SACK_PERMITTED  4
#define TCPOPT_TIMESTAMP       8
#define TCPOPT_TSTAMP_HDR      16844810
#define TCPOPT_WINDOW          3
#define TH_FIN  0x01
#define TH_SYN  0x02
#define TH_RST  0x04
#define TH_PUSH 0x08
#define TH_ACK  0x10
#define TH_URG  0x20

#endif /* _RUBYCC_NETINET_TCP_H */
