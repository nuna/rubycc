/* rubycc bundled <sys/un.h>: struct sockaddr_un, the AF_UNIX (local) socket
   address. Provenance: clean room against the Linux kernel UAPI (linux/un.h)
   and the glibc socket ABI, not derived from musl. The 110-byte layout
   (sun_family then a 108-byte sun_path) is that ABI reproduced as a measured
   field layout (an ABI fact, not copied text -- see docs/HEADER-LICENSING.md),
   the same treatment as sys/socket.h. Common layer: the layout is identical on
   x86-64 and aarch64. sa_family_t is shared with <sys/socket.h> and
   <netinet/in.h> through the same guard, so including any combination never
   redefines it.

   Coverage against glibc's <sys/un.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, x86-64 and aarch64, with tools/audit_bundled_headers.rb; table
   in docs/development/BUNDLED-HEADERS-COVERAGE.md). The one name that was
   missing, SUN_LEN, is below: it is how a caller hands bind()/connect() the
   exact address length for a pathname socket instead of sizeof(struct
   sockaddr_un), and every gem that opens a Unix socket by path wants it.
   rubycc writes its own body from the measured behaviour rather than copying
   glibc's (R11, docs/reference/HEADER-LICENSING.md sec. 6): sun_path sits at
   offset 2 on both arches, and SUN_LEN of a struct holding "/tmp/x" measured
   8 = 2 + 6 under gcc on 2026-09-18, i.e. the offset of sun_path plus the
   path's strlen. That is what <stddef.h> (offsetof) and <string.h> (strlen)
   are included for -- the same two headers glibc's own <sys/un.h> reaches for
   here.
   omitted: <strings.h> -- glibc pulls it in only as the __USE_MISC companion
   of <string.h>, and SUN_LEN needs nothing from it. */

#ifndef _RUBYCC_SYS_UN_H
#define _RUBYCC_SYS_UN_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#include <stddef.h>
#include <string.h>

#ifndef _RUBYCC_SA_FAMILY_T
#define _RUBYCC_SA_FAMILY_T
typedef unsigned short sa_family_t;
#endif

/* struct sockaddr_un: 110 bytes, 2-byte aligned (measured, both arches). */
struct sockaddr_un {
  sa_family_t sun_family;    /* offset 0 */
  char        sun_path[108]; /* offset 2 */
};

/* The address length a pathname socket should be bound/connected with: the
   bytes ahead of sun_path plus the path itself, without the trailing NUL. */
#define SUN_LEN(ptr) (offsetof(struct sockaddr_un, sun_path) + strlen((ptr)->sun_path))

#endif /* _RUBYCC_SYS_UN_H */
