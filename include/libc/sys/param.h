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
   other sys/param.h name either. Until 2026-09-18 this header shipped only the
   traditional four macros a "sys/param.h" compatibility shim is expected to
   carry.

   Coverage against glibc's <sys/param.h> under _GNU_SOURCE (audited
   2026-09-18, glibc 2.39, x86-64 and aarch64, with
   tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). All eighteen missing names
   were added, because they *are* what this header is for: a program that
   includes <sys/param.h> at all is asking for exactly the BSD-heritage
   spellings, and MAXPATHLEN in particular is what a C extension sizes a path
   buffer with. Every value was printed from the glibc oracle on both arches
   on 2026-09-18 and, with one exception, the two agreed: CANBSIZ 255,
   DEV_BSIZE 512, HZ 100, MAXHOSTNAMELEN 64, MAXPATHLEN 4096, MAXSYMLINKS 20,
   NBBY 8, NCARGS 131072, NGROUPS 65536, NODEV (dev_t)-1, NOFILE 256, NOGROUP
   -1. The exception is EXEC_PAGESIZE, which measured 4096 on x86-64 and
   65536 on aarch64 (glibc reports the largest page size the port supports,
   not the running kernel's), so it is the one name here written under an arch
   test, the way math.h and float.h already do. setbit/clrbit/isset/isclr and
   powerof2 are rubycc's own phrasing of behaviour measured against gcc on
   2026-09-18: the bitmap macros address byte n/8 with the mask 1 << (n%8)
   (probed by setting bits 3, 9 and 17 of a four-byte array and reading the
   bytes back as 8, 2, 2, 0), and powerof2 answers 1 for 8 and for 0, and 0
   for 9. Left out, and only these:
   omitted: <endian.h> <limits.h> <signal.h> <stddef.h> <sys/select.h>
   <sys/types.h> <sys/ucontext.h> <syslimits.h> <unistd.h> <sys/procfs.h>
   <sys/time.h> <sys/user.h> -- glibc's <sys/param.h> synthesizes its aliases
   out of <limits.h>, <endian.h>, <signal.h> and <sys/types.h>, and those four
   drag the rest in behind them; rubycc writes each alias with the value it
   measured instead, so the only type this file needs is dev_t, declared here
   under the shared _RUBYCC_DEV_T guard, and a program that wanted only
   MAXPATHLEN is not handed the whole signal surface with it. */

#ifndef _RUBYCC_SYS_PARAM_H
#define _RUBYCC_SYS_PARAM_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#ifndef _RUBYCC_DEV_T
#define _RUBYCC_DEV_T
typedef unsigned long dev_t;
#endif

/* BSD-heritage names for traditional Unix limits and parameters (measured on
   both arches, see the header note). */
#define CANBSIZ        255
#define DEV_BSIZE      512
#define HZ             100
#define MAXHOSTNAMELEN 64
#define MAXPATHLEN     4096
#define MAXSYMLINKS    20
#define NBBY           8
#define NCARGS         131072
#define NGROUPS        65536
#define NODEV          ((dev_t) -1)
#define NOFILE         256
#define NOGROUP        (-1)

/* The one value here the two arches disagree on: glibc reports the largest
   page size the port supports, which is 4096 on x86-64 and 65536 on aarch64
   (measured 2026-09-18). */
#if defined(__aarch64__)
#define EXEC_PAGESIZE 65536
#else
#define EXEC_PAGESIZE 4096
#endif

/* Bit operations on a byte-addressed bitmap: bit n lives in byte n/8 at mask
   1 << (n%8) (measured against gcc, see the header note). */
#ifndef setbit
#define setbit(a, i) (((unsigned char *) (a))[(i) / NBBY] |= 1 << ((i) % NBBY))
#endif
#ifndef clrbit
#define clrbit(a, i) (((unsigned char *) (a))[(i) / NBBY] &= ~(1 << ((i) % NBBY)))
#endif
#ifndef isset
#define isset(a, i) (((const unsigned char *) (a))[(i) / NBBY] & (1 << ((i) % NBBY)))
#endif
#ifndef isclr
#define isclr(a, i) ((((const unsigned char *) (a))[(i) / NBBY] & (1 << ((i) % NBBY))) == 0)
#endif

/* True when x has at most one bit set (zero included, as glibc answers). */
#ifndef powerof2
#define powerof2(x) ((((x) - 1) & (x)) == 0)
#endif

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
