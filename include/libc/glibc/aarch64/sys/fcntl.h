/* rubycc bundled <sys/fcntl.h>: the traditional compatibility alias for
   <fcntl.h>. Provenance: clean room -- glibc's own <sys/fcntl.h> is a one-line
   shim (`#include <fcntl.h>`, confirmed by inspecting the host's copy at
   /usr/aarch64-linux-gnu/include/sys/fcntl.h and its x86-64 counterpart,
   which agree byte for byte); nothing else is emitted so there is no ABI
   surface to measure beyond fcntl.h's own (already covered by that header's
   Spec). Placed alongside fcntl.h in the glibc/aarch64 layer (the same
   directory choice fcntl.h itself made, because O_DIRECT/O_DIRECTORY/
   O_NOFOLLOW here swap bit assignments against x86-64) purely for
   directory-structure symmetry with sys/select.h, sys/stat.h, sys/time.h and
   sys/types.h, which already live one per arch even where -- like this file
   -- their content does not differ (Step 124, M5 H2). */

#ifndef _RUBYCC_SYS_FCNTL_H
#define _RUBYCC_SYS_FCNTL_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#include <fcntl.h>

#endif /* _RUBYCC_SYS_FCNTL_H */
