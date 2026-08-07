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
   assignments a socket client/server writes). */

#ifndef _RUBYCC_NETINET_IN_H
#define _RUBYCC_NETINET_IN_H

#include <stdint.h>

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
#define s6_addr __in6_u.__u6_addr8

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

/* Host<->network byte-order conversions (same declarations as <arpa/inet.h>). */
uint32_t htonl(uint32_t __hostlong);
uint16_t htons(uint16_t __hostshort);
uint32_t ntohl(uint32_t __netlong);
uint16_t ntohs(uint16_t __netshort);

#endif /* _RUBYCC_NETINET_IN_H */
