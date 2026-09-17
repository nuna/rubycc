/* Clean-room ABI subset: rubycc bundled <link.h> exposes the leading fields of
   glibc's link_map ABI used by
   dlinfo(RTLD_DI_LINKMAP). The dynamic-loader extension only exposes the
   object's load bias and name to this C subset; the remaining loader-private
   fields are deliberately not presented as a false public surface. */

#ifndef _RUBYCC_LINK_H
#define _RUBYCC_LINK_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

struct link_map {
    unsigned long l_addr;
    char *l_name;
    void *l_ld;
    struct link_map *l_next;
    struct link_map *l_prev;
};

#endif /* _RUBYCC_LINK_H */
