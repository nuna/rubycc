/* rubycc bundled <sys/un.h>: struct sockaddr_un, the AF_UNIX (local) socket
   address. Provenance: clean room against the Linux kernel UAPI (linux/un.h)
   and the glibc socket ABI, not derived from musl. The 110-byte layout
   (sun_family then a 108-byte sun_path) is that ABI reproduced as a measured
   field layout (an ABI fact, not copied text -- see docs/HEADER-LICENSING.md),
   the same treatment as sys/socket.h. Common layer: the layout is identical on
   x86-64 and aarch64. sa_family_t is shared with <sys/socket.h> and
   <netinet/in.h> through the same guard, so including any combination never
   redefines it. */

#ifndef _RUBYCC_SYS_UN_H
#define _RUBYCC_SYS_UN_H

#ifndef _RUBYCC_SA_FAMILY_T
#define _RUBYCC_SA_FAMILY_T
typedef unsigned short sa_family_t;
#endif

/* struct sockaddr_un: 110 bytes, 2-byte aligned (measured, both arches). */
struct sockaddr_un {
  sa_family_t sun_family;    /* offset 0 */
  char        sun_path[108]; /* offset 2 */
};

#endif /* _RUBYCC_SYS_UN_H */
