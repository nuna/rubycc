/* rubycc bundled <arpa/inet.h>: the Internet address-manipulation declarations
   (POSIX) -- the host<->network byte-order conversions and the inet_* address
   conversions. Derived from musl's <arpa/inet.h> declaration set; the byte-order
   direction is taken from <endian.h> (arch specific) and the address types are
   fixed width, so this header itself carries nothing arch specific. Common layer.

   Measured need (Step 64): msgpack's sysdep_endian.h includes this header solely
   for __BYTE_ORDER / __LITTLE_ENDIAN and the ntohs/ntohl functions. glibc's real
   <arpa/inet.h> fans out into the whole socket + kernel-UAPI chain (netinet/in.h,
   sys/socket.h and the asm/asm-generic socket headers); the bundled header
   collapses that -- no target gem uses sockets, so the socket UAPI surface is
   deliberately not reproduced (measurement-driven, per the B7 plan). */

#ifndef _RUBYCC_ARPA_INET_H
#define _RUBYCC_ARPA_INET_H

#include <stdint.h>
#include <endian.h>

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

/* IPv4 address: a single network-order 32-bit word, the same one-field layout
   glibc/musl commit to (sizeof 4, s_addr at offset 0). */
#ifndef _RUBYCC_STRUCT_IN_ADDR
#define _RUBYCC_STRUCT_IN_ADDR
struct in_addr { in_addr_t s_addr; };
#endif

/* Host<->network byte-order conversions (network order is big-endian). Declared
   as plain out-of-line functions resolving from the host libc, matching glibc's
   real symbols; on a little-endian host each swaps its argument's bytes. */
uint32_t htonl(uint32_t __hostlong);
uint16_t htons(uint16_t __hostshort);
uint32_t ntohl(uint32_t __netlong);
uint16_t ntohs(uint16_t __netshort);

/* IPv4 / IPv6 address conversions. */
in_addr_t      inet_addr(const char *__cp);
in_addr_t      inet_network(const char *__cp);
struct in_addr inet_makeaddr(in_addr_t __net, in_addr_t __host);
in_addr_t      inet_lnaof(struct in_addr __in);
in_addr_t      inet_netof(struct in_addr __in);
int            inet_aton(const char *__cp, struct in_addr *__inp);
char          *inet_ntoa(struct in_addr __in);
int            inet_pton(int __af, const char *__cp, void *__buf);
const char    *inet_ntop(int __af, const void *__cp, char *__buf, socklen_t __len);

#endif /* _RUBYCC_ARPA_INET_H */
