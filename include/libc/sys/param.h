/* rubycc bundled <sys/param.h>: BSD-heritage traditional Unix parameter
   macros. Provenance: clean room. glibc's own <sys/param.h> is itself only a
   compatibility shim (its own comment header calls it "Compatibility header
   for old-style Unix parameters and limits") that pulls in sys/types.h,
   limits.h, endian.h and signal.h to synthesize BSD-named aliases
   (MAXPATHLEN, NOFILE, ...) and a handful of bit-twiddling macros
   (setbit/isset/howmany/roundup/MIN/MAX); it was inspected on the host
   (x86-64 and aarch64 glibc, both agree) to confirm what it actually emits,
   but no macro *body* is copied from it -- MIN/MAX/howmany/roundup below are
   rubycc's own phrasing of the same well-known formulas (an ABI/behavioral
   fact -- the value MIN(a,b)/roundup(x,y) etc. must produce -- not a
   creative expression; see docs/HEADER-LICENSING.md Sec 4). Narrowed to the
   surface digest's corpus sample actually reaches (Step 124, M5 H2): sha1.c's
   `#include <sys/param.h>` is itself gated behind `defined(_KERNEL) ||
   defined(_STANDALONE)`, neither of which a userspace Ruby extension build
   ever defines, so the include is unreachable dead code for this gem in
   practice -- and no digest source references MIN/MAX/howmany/roundup or any
   other sys/param.h name either. This header ships only the traditional
   four macros a "sys/param.h" compatibility shim is expected to carry
   (matching the header's own docs above); the BSD name aliases (MAXPATHLEN,
   NOFILE, ...), the setbit/isset bitmap macros and the endian.h/signal.h
   pull-ins are not reproduced (no corpus sample needs them, and re-adding
   them would just re-derive limits.h/endian.h under new names). */

#ifndef _RUBYCC_SYS_PARAM_H
#define _RUBYCC_SYS_PARAM_H

#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif
#ifndef howmany
#define howmany(x, y) (((x) + ((y) - 1)) / (y))
#endif
#ifndef roundup
#define roundup(x, y) ((((x) + ((y) - 1)) / (y)) * (y))
#endif

#endif /* _RUBYCC_SYS_PARAM_H */
