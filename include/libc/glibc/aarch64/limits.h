/* rubycc bundled <limits.h>: the arithmetic-type ranges (ISO C 5.2.4.2.1).
   Derived from the ISO-mandated values with the `long`/`char` widths pinned to
   the glibc x86-64 LP64 ABI (`long` is 64-bit); the arithmetic ranges are the
   same under either C library, and only MB_LEN_MAX differs between them
   (carried below under __RUBYCC_LIBC_MUSL__, see the preprocessor's LIBCS).
   ABI switch layer: LONG_MAX is arch specific, and so is the signedness of
   plain char -- that one is taken from the compiler's own __CHAR_UNSIGNED__
   rather than from this directory.
   Coverage against glibc's <limits.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, both arches, with tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). The system limits below
   (PATH_MAX and kin) and the C23 width macros were added there; before that a
   plain "#include <limits.h>; char buf[PATH_MAX];" was rejected by rubycc and
   accepted by gcc (measured 2026-09-18). Intentionally left out:
   omitted: _POSIX_* _POSIX2_* _XOPEN_IOV_MAX -- the standard's compile-time
   *minimums*, which a program reads with #if only to size something when the
   real limit is unknown; the real limits are now here.
   omitted: BC_BASE_MAX BC_DIM_MAX BC_SCALE_MAX BC_STRING_MAX COLL_WEIGHTS_MAX
   EXPR_NEST_MAX CHARCLASS_NAME_MAX -- the POSIX.2 limits on shell utilities
   (bc, locale definitions), not on a C extension; no corpus user.
   omitted: NL_ARGMAX NL_LANGMAX NL_MSGMAX NL_NMAX NL_SETMAX NL_TEXTMAX -- the
   X/Open message-catalogue limits; rubycc bundles no <nl_types.h> to use them
   with. omitted: AIO_PRIO_DELTA_MAX DELAYTIMER_MAX MQ_PRIO_MAX RTSIG_MAX
   SEM_VALUE_MAX -- limits on the POSIX aio, timer, message-queue and semaphore
   interfaces, none of which rubycc bundles a header for.
   omitted: PTHREAD_KEYS_MAX PTHREAD_DESTRUCTOR_ITERATIONS PTHREAD_STACK_MIN --
   thread limits; PTHREAD_STACK_MIN is not even a constant in glibc 2.34 and
   later (measured 2026-09-18: it expands to a sysconf call), so a number
   written here could contradict the host.
   omitted: <syslimits.h> -- gcc's own plumbing header, reached from gcc's
   <limits.h> and empty of public names. */

#ifndef _RUBYCC_LIMITS_H
#define _RUBYCC_LIMITS_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#define CHAR_BIT    8
/* MB_LEN_MAX is the one value in this header the two C libraries disagree on:
   musl reports 4 (its widest multibyte character, UTF-8's four bytes) and
   glibc 16, the same pair the x86-64 companion carries -- but not copied from
   it (a value's identity across two machines is a coincidence, not a rule
   this layer may assume, R8): measured directly on the CI aarch64 musl run
   (docs/STEPS.md Step 202), with glibc's on this host. */
#if defined(__RUBYCC_LIBC_MUSL__)
#define MB_LEN_MAX  4
#else
#define MB_LEN_MAX  16
#endif

#define SCHAR_MIN   (-128)
#define SCHAR_MAX   127
#define UCHAR_MAX   255

/* Plain char's signedness is implementation-defined and pinned per ABI: signed
   on the x86-64 SysV ABI, unsigned on AAPCS64. rubycc predefines
   __CHAR_UNSIGNED__ on a target of the latter kind (as gcc does), so the range
   follows the compilation target rather than this header's directory. */
#ifdef __CHAR_UNSIGNED__
#define CHAR_MIN    0
#define CHAR_MAX    UCHAR_MAX
#else
#define CHAR_MIN    SCHAR_MIN
#define CHAR_MAX    SCHAR_MAX
#endif

#define SHRT_MIN    (-32768)
#define SHRT_MAX    32767
#define USHRT_MAX   65535

#define INT_MIN     (-INT_MAX-1)
#define INT_MAX     2147483647
#define UINT_MAX    4294967295U

#define LONG_MIN    (-LONG_MAX-1L)
#define LONG_MAX    9223372036854775807L
#define ULONG_MAX   18446744073709551615UL

#define LLONG_MIN   (-LLONG_MAX-1LL)
#define LLONG_MAX   9223372036854775807LL
#define ULLONG_MAX  18446744073709551615ULL

/* GNU spellings some code still uses. */
#define LONG_LONG_MIN   LLONG_MIN
#define LONG_LONG_MAX   LLONG_MAX
#define ULONG_LONG_MAX  ULLONG_MAX

/* The system limits a C extension reads out of <limits.h>: the kernel's own
   fixed bounds (PATH_MAX and kin) and the X/Open word-width pair. glibc keeps
   these in <linux/limits.h> and bits/posix1_lim.h rather than in <limits.h>
   itself, but a program only ever sees them through this header. Every value
   below was printed from the glibc oracle on x86-64 and, separately, on
   aarch64 under qemu (2026-09-18); the two agreed on all of them, but each was
   measured on its own machine rather than copied across (R8), which is why
   this file carries them in the arch layer. */
#define PATH_MAX       4096
#define NAME_MAX       255
#define PIPE_BUF       4096
#define IOV_MAX        1024
#define HOST_NAME_MAX  64
#define LOGIN_NAME_MAX 256
#define TTY_NAME_MAX   32
#define NGROUPS_MAX    65536
#define MAX_CANON      255
#define MAX_INPUT      255
#define LINE_MAX       2048
#define RE_DUP_MAX     32767
#define NZERO          20
#define SSIZE_MAX      LONG_MAX
#define LONG_BIT       64
#define WORD_BIT       32
#define XATTR_NAME_MAX 255
#define XATTR_SIZE_MAX 65536
#define XATTR_LIST_MAX 65536

/* The ISO C23 width macros (glibc shows them under _GNU_SOURCE on 2.39). They
   are this header's own arithmetic business -- the bit count that matches each
   range above -- and were printed from the glibc oracle on both arches. */
#define BOOL_WIDTH   1
#define BOOL_MAX     1
#define CHAR_WIDTH   8
#define SCHAR_WIDTH  8
#define UCHAR_WIDTH  8
#define SHRT_WIDTH   16
#define USHRT_WIDTH  16
#define INT_WIDTH    32
#define UINT_WIDTH   32
#define LONG_WIDTH   64
#define ULONG_WIDTH  64
#define LLONG_WIDTH  64
#define ULLONG_WIDTH 64

#endif /* _RUBYCC_LIMITS_H */
