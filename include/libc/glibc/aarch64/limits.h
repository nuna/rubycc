/* rubycc bundled <limits.h>: the arithmetic-type ranges (ISO C 5.2.4.2.1).
   Derived from the ISO-mandated values with the `long`/`char` widths pinned to
   the glibc x86-64 LP64 ABI (`long` is 64-bit); the arithmetic ranges are the
   same under either C library, and only MB_LEN_MAX differs between them
   (carried below under __RUBYCC_LIBC_MUSL__, see the preprocessor's LIBCS).
   ABI switch layer: LONG_MAX is arch specific, and so is the signedness of
   plain char -- that one is taken from the compiler's own __CHAR_UNSIGNED__
   rather than from this directory. */

#ifndef _RUBYCC_LIMITS_H
#define _RUBYCC_LIMITS_H

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

#endif /* _RUBYCC_LIMITS_H */
