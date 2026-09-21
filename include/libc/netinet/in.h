/* rubycc bundled <netinet/in.h>: the IPv4/IPv6 address types, the
   sockaddr_in / sockaddr_in6 structs, the IPPROTO_* protocol numbers and the
   INADDR_* well-known addresses. Provenance: clean room against the Linux
   kernel UAPI (linux/in.h, linux/in6.h) and the glibc socket ABI, not derived
   from musl -- the same treatment as sys/socket.h (see docs/HEADER-LICENSING.md).
   The struct layouts and the IPPROTO_/INADDR_ integer values below are that ABI
   reproduced as measured field offsets and measured integer constants, an ABI
   fact rather than copied text. Common layer: every struct layout (sockaddr_in,
   sockaddr_in6, in6_addr all included) and every macro value is identical on
   x86-64 and aarch64.

   Shares its address-type definitions with <arpa/inet.h> (in_addr_t, in_port_t,
   struct in_addr, socklen_t) and its address-family type with <sys/socket.h>
   (sa_family_t): each is guarded so whichever header is #included first wins
   and the other's guard short-circuits, so #including both in either order
   never redefines anything. htons/htonl/ntohs/ntohl are declared again here
   with the identical signature <arpa/inet.h> uses -- a repeated declaration of
   the same C function is legal and the two headers commonly get both
   #included by real code (this file needs them for the sockaddr_in field
   assignments a socket client/server writes).

   Coverage against glibc's <netinet/in.h> under _GNU_SOURCE (audited
   2026-09-18, glibc 2.39, x86-64 and aarch64, with
   tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Two hundred and sixty-seven
   names were missing on both arches; two hundred and eleven were added and
   fifty-six are deliberate. What was added, and how it was checked:

     - <sys/socket.h> is now included, as glibc's <netinet/in.h> includes it.
       Before, a program that included only this header and then wrote
       socket(AF_INET, ...) or took a socklen_t compiled under gcc and failed
       under rubycc. The two headers already shared sa_family_t and socklen_t
       through guards, so nothing is redefined.
     - The rest of the IPPROTO_* numbers, the SOL_IP / SOL_IPV6 / SOL_ICMPV6
       levels, every IP_* and IPV6_* socket option with its argument values
       (IP_PMTUDISC_*, IPV6_RTHDR_*), the MCAST_* protocol-independent
       multicast options, the remaining INADDR_* group addresses and the
       classful masks: 181 values, printed from the glibc oracle on both
       arches on 2026-09-18, all agreeing. These are the numbers a gem passes
       to setsockopt at the IP levels; the same "closed numbered space, one
       probe" argument as <sys/socket.h>'s SO_* set.
     - The multicast and packet-info request structs struct ip_mreq,
       ip_mreqn, ip_mreq_source, ipv6_mreq, in_pktinfo, in6_pktinfo,
       group_req and group_source_req. Their sizes and every member offset
       were measured on both arches and agreed (8, 12, 12, 20, 12, 20, 136
       and 264 bytes); every member's type was confirmed against glibc's with
       __builtin_types_compatible_p on both arches (23 of 23).
     - s6_addr16 / s6_addr32, the 16- and 32-bit views of struct in6_addr's
       union above (byte offsets 2 and 4 for element 1, measured).
     - The IPv4 classification macros (IN_CLASSA..D, IN_MULTICAST,
       IN_EXPERIMENTAL, IN_BADCLASS) and the IPv6 ones (IN6_IS_ADDR_* and
       IN6_ARE_ADDR_EQUAL). Their bodies are rubycc's own, written over the
       address bytes rather than copied (R11, docs/reference/
       HEADER-LICENSING.md sec. 6), and checked by differential on
       2026-09-18: the IPv4 macros against glibc's for every one of the 2^32
       addresses, the IPv6 ones over 400,000 structured and pseudo-random
       addresses, on x86-64 and on aarch64 (cross gcc + qemu) -- zero
       mismatches on either arch.
     - IPPORT_RESERVED 1024 and IPPORT_USERRESERVED 5000, the two port-table
       entries that are policy rather than a service directory.

   omitted: IPPORT_BIFFUDP IPPORT_CMDSERVER IPPORT_DAYTIME IPPORT_DISCARD
   IPPORT_ECHO IPPORT_EFSSERVER IPPORT_EXECSERVER IPPORT_FINGER IPPORT_FTP
   IPPORT_LOGINSERVER IPPORT_MTP IPPORT_NAMESERVER IPPORT_NETSTAT IPPORT_RJE
   IPPORT_ROUTESERVER IPPORT_SMTP IPPORT_SUPDUP IPPORT_SYSTAT IPPORT_TELNET
   IPPORT_TFTP IPPORT_TIMESERVER IPPORT_TTYLINK IPPORT_WHOIS IPPORT_WHOSERVER
   -- the 4.2BSD well-known-service port table, which <netdb.h>'s
   getservbyname superseded and no corpus gem reads.
   omitted: SCM_SRCRT -- glibc defines it as IPV6_RXSRCRT, a name glibc 2.39
   does not define on either arch, so using it is a compile error under gcc
   too (measured 2026-09-18); there is nothing usable to reproduce.
   omitted: bindresvport bindresvport6 -- the Sun RPC privileged-port binders,
   with no corpus user.
   omitted: inet6_opt_append inet6_opt_find inet6_opt_finish
   inet6_opt_get_val inet6_opt_init inet6_opt_next inet6_opt_set_val
   inet6_option_alloc inet6_option_append inet6_option_find
   inet6_option_init inet6_option_next inet6_option_space inet6_rth_add
   inet6_rth_getaddr inet6_rth_init inet6_rth_reverse inet6_rth_segments
   inet6_rth_space -- the RFC 3542 / RFC 2292 advanced IPv6 extension-header
   builders, with no corpus user.
   omitted: getsourcefilter setsourcefilter getipv4sourcefilter
   setipv4sourcefilter struct group_filter struct ip_msfilter
   GROUP_FILTER_SIZE IP_MSFILTER_SIZE -- the full-state source-filter API,
   whose structs end in a variable-length source array; the per-source
   MCAST_* and IP_*_SOURCE_MEMBERSHIP options above cover what a multicast
   receiver does, and no corpus user needs the rest.
   omitted: struct ip_opts struct ip6_mtuinfo -- the IP_OPTIONS buffer layout
   and the IPV6_PATHMTU ancillary payload, with no corpus user.
   omitted: <endian.h> <stddef.h> <sys/select.h> <sys/types.h> -- glibc
   reaches those through its <sys/socket.h> and <stdint.h> chain; the
   bundled <sys/socket.h> included above declares what this header uses
   directly. */

#ifndef _RUBYCC_NETINET_IN_H
#define _RUBYCC_NETINET_IN_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#include <stdint.h>
/* glibc's <netinet/in.h> includes <sys/socket.h>, and programs rely on it. */
#include <sys/socket.h>

#ifndef _RUBYCC_SOCKLEN_T
#define _RUBYCC_SOCKLEN_T
typedef unsigned int socklen_t;
#endif

#ifndef _RUBYCC_IN_ADDR_T
#define _RUBYCC_IN_ADDR_T
typedef uint32_t in_addr_t;
#endif

#ifndef _RUBYCC_IN_PORT_T
#define _RUBYCC_IN_PORT_T
typedef uint16_t in_port_t;
#endif

#ifndef _RUBYCC_STRUCT_IN_ADDR
#define _RUBYCC_STRUCT_IN_ADDR
struct in_addr { in_addr_t s_addr; };
#endif

#ifndef _RUBYCC_SA_FAMILY_T
#define _RUBYCC_SA_FAMILY_T
typedef unsigned short sa_family_t;
#endif

/* IPv6 address: 16 bytes, 4-byte aligned (measured, both arches). The union
   gives access at three widths (glibc's in6_u); s6_addr is the POSIX-visible
   byte-array name, macro'd onto the byte member of the union. */
struct in6_addr {
  union {
    uint8_t  __u6_addr8[16];
    uint16_t __u6_addr16[8];
    uint32_t __u6_addr32[4];
  } __in6_u;
};
#define s6_addr   __in6_u.__u6_addr8
#define s6_addr16 __in6_u.__u6_addr16
#define s6_addr32 __in6_u.__u6_addr32

/* struct sockaddr_in: 16 bytes, 4-byte aligned (measured, both arches), the
   IPv4-specific socket address. */
struct sockaddr_in {
  sa_family_t    sin_family; /* offset 0 */
  in_port_t      sin_port;   /* offset 2 */
  struct in_addr sin_addr;   /* offset 4 */
  unsigned char  sin_zero[8]; /* offset 8 */
};

/* struct sockaddr_in6: 28 bytes, 4-byte aligned (measured, both arches), the
   IPv6-specific socket address. */
struct sockaddr_in6 {
  sa_family_t     sin6_family;   /* offset 0  */
  in_port_t       sin6_port;     /* offset 2  */
  uint32_t        sin6_flowinfo; /* offset 4  */
  struct in6_addr sin6_addr;     /* offset 8  */
  uint32_t        sin6_scope_id; /* offset 24 */
};

/* IP protocol numbers (Linux kernel UAPI, linux/in.h). */
#define IPPROTO_IP   0
#define IPPROTO_ICMP 1
#define IPPROTO_TCP  6
#define IPPROTO_UDP  17
#define IPPROTO_IPV6 41
#define IPPROTO_RAW  255

/* Well-known IPv4 addresses (host byte order, glibc's in_addr_t-typed constants). */
#define INADDR_ANY       ((in_addr_t)0x00000000)
#define INADDR_LOOPBACK  ((in_addr_t)0x7f000001)
#define INADDR_BROADCAST ((in_addr_t)0xffffffff)
#define INADDR_NONE      ((in_addr_t)0xffffffff)

/* Buffer sizes for inet_ntop's textual forms, counting the terminating NUL:
   "255.255.255.255" and the longest IPv6 spelling (an IPv4-mapped address with
   a scope, "ffff:...:255.255.255.255%4294967295"). Measured, and identical on
   x86-64 and aarch64. */
#define INET_ADDRSTRLEN  16
#define INET6_ADDRSTRLEN 46

/* Well-known IPv6 addresses, as struct in6_addr initializers (glibc's
   IN6ADDR_*_INIT macros); the triple brace reaches through struct in6_addr's
   anonymous union member down to the byte array. */
#define IN6ADDR_ANY_INIT \
  { { { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } } }
#define IN6ADDR_LOOPBACK_INIT \
  { { { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } } }

/* The same two addresses as objects the host libc defines (measured: both are
   real exported symbols, `V in6addr_any` / `V in6addr_loopback`). A program
   that needs the *address* of one -- raindrops' linux_inet_diag.c memcmps
   against &in6addr_any -- cannot use the initializer macros, so the
   declarations have to be here for the definitions to resolve at link time. */
extern const struct in6_addr in6addr_any;
extern const struct in6_addr in6addr_loopback;

/* The rest of the IP protocol numbers (measured, both arches agree). */
#define IPPROTO_AH       51
#define IPPROTO_BEETPH   94
#define IPPROTO_COMP     108
#define IPPROTO_DCCP     33
#define IPPROTO_DSTOPTS  60
#define IPPROTO_EGP      8
#define IPPROTO_ENCAP    98
#define IPPROTO_ESP      50
#define IPPROTO_ETHERNET 143
#define IPPROTO_FRAGMENT 44
#define IPPROTO_GRE      47
#define IPPROTO_HOPOPTS  0
#define IPPROTO_ICMPV6   58
#define IPPROTO_IDP      22
#define IPPROTO_IGMP     2
#define IPPROTO_IPIP     4
#define IPPROTO_L2TP     115
#define IPPROTO_MAX      263
#define IPPROTO_MH       135
#define IPPROTO_MPLS     137
#define IPPROTO_MPTCP    262
#define IPPROTO_MTP      92
#define IPPROTO_NONE     59
#define IPPROTO_PIM      103
#define IPPROTO_PUP      12
#define IPPROTO_ROUTING  43
#define IPPROTO_RSVP     46
#define IPPROTO_SCTP     132
#define IPPROTO_TP       29
#define IPPROTO_UDPLITE  136

/* setsockopt/getsockopt levels for the IP layers. */
#define SOL_ICMPV6 58
#define SOL_IP     0
#define SOL_IPV6   41

/* IPPROTO_IP-level option names and their argument values. */
#define IP_ADD_MEMBERSHIP         35
#define IP_ADD_SOURCE_MEMBERSHIP  39
#define IP_BIND_ADDRESS_NO_PORT   24
#define IP_BLOCK_SOURCE           38
#define IP_CHECKSUM               23
#define IP_DEFAULT_MULTICAST_LOOP 1
#define IP_DEFAULT_MULTICAST_TTL  1
#define IP_DROP_MEMBERSHIP        36
#define IP_DROP_SOURCE_MEMBERSHIP 40
#define IP_FREEBIND               15
#define IP_HDRINCL                3
#define IP_IPSEC_POLICY           16
#define IP_LOCAL_PORT_RANGE       51
#define IP_MAX_MEMBERSHIPS        20
#define IP_MINTTL                 21
#define IP_MSFILTER               41
#define IP_MTU                    14
#define IP_MTU_DISCOVER           10
#define IP_MULTICAST_ALL          49
#define IP_MULTICAST_IF           32
#define IP_MULTICAST_LOOP         34
#define IP_MULTICAST_TTL          33
#define IP_NODEFRAG               22
#define IP_OPTIONS                4
#define IP_ORIGDSTADDR            20
#define IP_PASSSEC                18
#define IP_PKTINFO                8
#define IP_PKTOPTIONS             9
#define IP_PMTUDISC               10
#define IP_PMTUDISC_DO            2
#define IP_PMTUDISC_DONT          0
#define IP_PMTUDISC_INTERFACE     4
#define IP_PMTUDISC_OMIT          5
#define IP_PMTUDISC_PROBE         3
#define IP_PMTUDISC_WANT          1
#define IP_PROTOCOL               52
#define IP_RECVERR                11
#define IP_RECVERR_RFC4884        26
#define IP_RECVFRAGSIZE           25
#define IP_RECVOPTS               6
#define IP_RECVORIGDSTADDR        20
#define IP_RECVRETOPTS            7
#define IP_RECVTOS                13
#define IP_RECVTTL                12
#define IP_RETOPTS                7
#define IP_ROUTER_ALERT           5
#define IP_TOS                    1
#define IP_TRANSPARENT            19
#define IP_TTL                    2
#define IP_UNBLOCK_SOURCE         37
#define IP_UNICAST_IF             50
#define IP_XFRM_POLICY            17

/* IPPROTO_IPV6-level option names and their argument values. */
#define IPV6_2292DSTOPTS          4
#define IPV6_2292HOPLIMIT         8
#define IPV6_2292HOPOPTS          3
#define IPV6_2292PKTINFO          2
#define IPV6_2292PKTOPTIONS       6
#define IPV6_2292RTHDR            5
#define IPV6_ADDRFORM             1
#define IPV6_ADDR_PREFERENCES     72
#define IPV6_ADD_MEMBERSHIP       20
#define IPV6_AUTHHDR              10
#define IPV6_AUTOFLOWLABEL        70
#define IPV6_CHECKSUM             7
#define IPV6_DONTFRAG             62
#define IPV6_DROP_MEMBERSHIP      21
#define IPV6_DSTOPTS              59
#define IPV6_FREEBIND             78
#define IPV6_HDRINCL              36
#define IPV6_HOPLIMIT             52
#define IPV6_HOPOPTS              54
#define IPV6_IPSEC_POLICY         34
#define IPV6_JOIN_ANYCAST         27
#define IPV6_JOIN_GROUP           20
#define IPV6_LEAVE_ANYCAST        28
#define IPV6_LEAVE_GROUP          21
#define IPV6_MINHOPCOUNT          73
#define IPV6_MTU                  24
#define IPV6_MTU_DISCOVER         23
#define IPV6_MULTICAST_ALL        29
#define IPV6_MULTICAST_HOPS       18
#define IPV6_MULTICAST_IF         17
#define IPV6_MULTICAST_LOOP       19
#define IPV6_NEXTHOP              9
#define IPV6_ORIGDSTADDR          74
#define IPV6_PATHMTU              61
#define IPV6_PKTINFO              50
#define IPV6_PMTUDISC_DO          2
#define IPV6_PMTUDISC_DONT        0
#define IPV6_PMTUDISC_INTERFACE   4
#define IPV6_PMTUDISC_OMIT        5
#define IPV6_PMTUDISC_PROBE       3
#define IPV6_PMTUDISC_WANT        1
#define IPV6_RECVDSTOPTS          58
#define IPV6_RECVERR              25
#define IPV6_RECVERR_RFC4884      31
#define IPV6_RECVFRAGSIZE         77
#define IPV6_RECVHOPLIMIT         51
#define IPV6_RECVHOPOPTS          53
#define IPV6_RECVORIGDSTADDR      74
#define IPV6_RECVPATHMTU          60
#define IPV6_RECVPKTINFO          49
#define IPV6_RECVRTHDR            56
#define IPV6_RECVTCLASS           66
#define IPV6_ROUTER_ALERT         22
#define IPV6_ROUTER_ALERT_ISOLATE 30
#define IPV6_RTHDR                57
#define IPV6_RTHDRDSTOPTS         55
#define IPV6_RTHDR_LOOSE          0
#define IPV6_RTHDR_STRICT         1
#define IPV6_RTHDR_TYPE_0         0
#define IPV6_RXDSTOPTS            59
#define IPV6_RXHOPOPTS            54
#define IPV6_TCLASS               67
#define IPV6_TRANSPARENT          75
#define IPV6_UNICAST_HOPS         16
#define IPV6_UNICAST_IF           76
#define IPV6_V6ONLY               26
#define IPV6_XFRM_POLICY          35

/* Protocol-independent multicast (RFC 3678) option names and filter modes. */
#define MCAST_BLOCK_SOURCE       43
#define MCAST_EXCLUDE            0
#define MCAST_INCLUDE            1
#define MCAST_JOIN_GROUP         42
#define MCAST_JOIN_SOURCE_GROUP  46
#define MCAST_LEAVE_GROUP        45
#define MCAST_LEAVE_SOURCE_GROUP 47
#define MCAST_MSFILTER           48
#define MCAST_UNBLOCK_SOURCE     44

/* More well-known IPv4 addresses, host byte order. */
#define INADDR_ALLHOSTS_GROUP    ((in_addr_t)0xe0000001)
#define INADDR_ALLRTRS_GROUP     ((in_addr_t)0xe0000002)
#define INADDR_ALLSNOOPERS_GROUP ((in_addr_t)0xe000006a)
#define INADDR_DUMMY             ((in_addr_t)0xc0000008)
#define INADDR_MAX_LOCAL_GROUP   ((in_addr_t)0xe00000ff)
#define INADDR_UNSPEC_GROUP      ((in_addr_t)0xe0000000)

/* The classful-network masks and shifts (historical, still published). */
#define IN_CLASSA_HOST   0x00ffffff
#define IN_CLASSA_MAX    128
#define IN_CLASSA_NET    0xff000000
#define IN_CLASSA_NSHIFT 24
#define IN_CLASSB_HOST   0x0000ffff
#define IN_CLASSB_MAX    65536
#define IN_CLASSB_NET    0xffff0000
#define IN_CLASSB_NSHIFT 16
#define IN_CLASSC_HOST   0x000000ff
#define IN_CLASSC_NET    0xffffff00
#define IN_CLASSC_NSHIFT 8
#define IN_LOOPBACKNET 127

/* Ports below IPPORT_RESERVED are privileged; IPPORT_USERRESERVED is the
   traditional floor for ephemeral user ports. */
#define IPPORT_RESERVED     1024
#define IPPORT_USERRESERVED 5000

/* IPv4 address classification, on a host-order in_addr_t (rubycc's own
   bodies, checked against glibc's for all 2^32 addresses -- see the header
   note). */
#define IN_CLASSA(a)       ((((in_addr_t) (a)) & 0x80000000) == 0)
#define IN_CLASSB(a)       ((((in_addr_t) (a)) & 0xc0000000) == 0x80000000)
#define IN_CLASSC(a)       ((((in_addr_t) (a)) & 0xe0000000) == 0xc0000000)
#define IN_CLASSD(a)       ((((in_addr_t) (a)) & 0xf0000000) == 0xe0000000)
#define IN_MULTICAST(a)    IN_CLASSD (a)
#define IN_EXPERIMENTAL(a) ((((in_addr_t) (a)) & 0xe0000000) == 0xe0000000)
#define IN_BADCLASS(a)     ((((in_addr_t) (a)) & 0xf0000000) == 0xf0000000)

/* IPv6 address classification, on a pointer to struct in6_addr. Written over
   the address bytes (network order), so the answer does not depend on the
   host byte order; checked against glibc's by differential (header note). */
#define __RUBYCC_IN6_B(a) (((const struct in6_addr *) (a))->s6_addr)
#define __RUBYCC_IN6_ZERO10(a) \
  (__RUBYCC_IN6_B (a)[0] == 0 && __RUBYCC_IN6_B (a)[1] == 0 \
   && __RUBYCC_IN6_B (a)[2] == 0 && __RUBYCC_IN6_B (a)[3] == 0 \
   && __RUBYCC_IN6_B (a)[4] == 0 && __RUBYCC_IN6_B (a)[5] == 0 \
   && __RUBYCC_IN6_B (a)[6] == 0 && __RUBYCC_IN6_B (a)[7] == 0 \
   && __RUBYCC_IN6_B (a)[8] == 0 && __RUBYCC_IN6_B (a)[9] == 0)
#define __RUBYCC_IN6_ZERO12(a) \
  (__RUBYCC_IN6_ZERO10 (a) && __RUBYCC_IN6_B (a)[10] == 0 && __RUBYCC_IN6_B (a)[11] == 0)
#define IN6_IS_ADDR_UNSPECIFIED(a) \
  (__RUBYCC_IN6_ZERO12 (a) && __RUBYCC_IN6_B (a)[12] == 0 && __RUBYCC_IN6_B (a)[13] == 0 \
   && __RUBYCC_IN6_B (a)[14] == 0 && __RUBYCC_IN6_B (a)[15] == 0)
#define IN6_IS_ADDR_LOOPBACK(a) \
  (__RUBYCC_IN6_ZERO12 (a) && __RUBYCC_IN6_B (a)[12] == 0 && __RUBYCC_IN6_B (a)[13] == 0 \
   && __RUBYCC_IN6_B (a)[14] == 0 && __RUBYCC_IN6_B (a)[15] == 1)
#define IN6_IS_ADDR_MULTICAST(a) (__RUBYCC_IN6_B (a)[0] == 0xff)
#define IN6_IS_ADDR_LINKLOCAL(a) \
  (__RUBYCC_IN6_B (a)[0] == 0xfe && (__RUBYCC_IN6_B (a)[1] & 0xc0) == 0x80)
#define IN6_IS_ADDR_SITELOCAL(a) \
  (__RUBYCC_IN6_B (a)[0] == 0xfe && (__RUBYCC_IN6_B (a)[1] & 0xc0) == 0xc0)
#define IN6_IS_ADDR_V4MAPPED(a) \
  (__RUBYCC_IN6_ZERO10 (a) && __RUBYCC_IN6_B (a)[10] == 0xff && __RUBYCC_IN6_B (a)[11] == 0xff)
#define IN6_IS_ADDR_V4COMPAT(a) \
  (__RUBYCC_IN6_ZERO12 (a) \
   && (__RUBYCC_IN6_B (a)[12] != 0 || __RUBYCC_IN6_B (a)[13] != 0 \
       || __RUBYCC_IN6_B (a)[14] != 0 || __RUBYCC_IN6_B (a)[15] > 1))
#define __RUBYCC_IN6_MC_SCOPE(a, s) \
  (IN6_IS_ADDR_MULTICAST (a) && (__RUBYCC_IN6_B (a)[1] & 0xf) == (s))
#define IN6_IS_ADDR_MC_NODELOCAL(a) __RUBYCC_IN6_MC_SCOPE (a, 0x1)
#define IN6_IS_ADDR_MC_LINKLOCAL(a) __RUBYCC_IN6_MC_SCOPE (a, 0x2)
#define IN6_IS_ADDR_MC_SITELOCAL(a) __RUBYCC_IN6_MC_SCOPE (a, 0x5)
#define IN6_IS_ADDR_MC_ORGLOCAL(a)  __RUBYCC_IN6_MC_SCOPE (a, 0x8)
#define IN6_IS_ADDR_MC_GLOBAL(a)    __RUBYCC_IN6_MC_SCOPE (a, 0xe)
#define IN6_ARE_ADDR_EQUAL(a, b) \
  (((const struct in6_addr *) (a))->s6_addr32[0] == ((const struct in6_addr *) (b))->s6_addr32[0] \
   && ((const struct in6_addr *) (a))->s6_addr32[1] == ((const struct in6_addr *) (b))->s6_addr32[1] \
   && ((const struct in6_addr *) (a))->s6_addr32[2] == ((const struct in6_addr *) (b))->s6_addr32[2] \
   && ((const struct in6_addr *) (a))->s6_addr32[3] == ((const struct in6_addr *) (b))->s6_addr32[3])

/* Multicast membership and packet-info payloads (sizes and offsets measured,
   both arches agree -- see the header note). */
struct ip_mreq {                     /* 8 bytes: IP_ADD/DROP_MEMBERSHIP */
  struct in_addr imr_multiaddr;      /* offset 0 */
  struct in_addr imr_interface;      /* offset 4 */
};
struct ip_mreqn {                    /* 12 bytes: the same, by interface index */
  struct in_addr imr_multiaddr;      /* offset 0 */
  struct in_addr imr_address;        /* offset 4 */
  int            imr_ifindex;        /* offset 8 */
};
struct ip_mreq_source {              /* 12 bytes: IP_*_SOURCE_MEMBERSHIP */
  struct in_addr imr_multiaddr;      /* offset 0 */
  struct in_addr imr_interface;      /* offset 4 */
  struct in_addr imr_sourceaddr;     /* offset 8 */
};
struct ipv6_mreq {                   /* 20 bytes: IPV6_JOIN/LEAVE_GROUP */
  struct in6_addr ipv6mr_multiaddr;  /* offset 0  */
  unsigned int    ipv6mr_interface;  /* offset 16 */
};
struct in_pktinfo {                  /* 12 bytes: IP_PKTINFO */
  int            ipi_ifindex;        /* offset 0 */
  struct in_addr ipi_spec_dst;       /* offset 4 */
  struct in_addr ipi_addr;           /* offset 8 */
};
struct in6_pktinfo {                 /* 20 bytes: IPV6_PKTINFO */
  struct in6_addr ipi6_addr;         /* offset 0  */
  unsigned int    ipi6_ifindex;      /* offset 16 */
};
struct group_req {                   /* 136 bytes, 8-aligned: MCAST_JOIN/LEAVE_GROUP */
  uint32_t                gr_interface;  /* offset 0 */
  struct sockaddr_storage gr_group;      /* offset 8 */
};
struct group_source_req {            /* 264 bytes, 8-aligned: MCAST_*_SOURCE_* */
  uint32_t                gsr_interface; /* offset 0   */
  struct sockaddr_storage gsr_group;     /* offset 8   */
  struct sockaddr_storage gsr_source;    /* offset 136 */
};

/* Host<->network byte-order conversions (same declarations as <arpa/inet.h>). */
uint32_t htonl(uint32_t __hostlong);
uint16_t htons(uint16_t __hostshort);
uint32_t ntohl(uint32_t __netlong);
uint16_t ntohs(uint16_t __netshort);

#endif /* _RUBYCC_NETINET_IN_H */
