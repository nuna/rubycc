/* rubycc bundled <limits.h>: the arithmetic-type ranges (ISO C 5.2.4.2.1).
   Derived from the ISO-mandated values with the `long`/`char` widths pinned to
   the glibc x86-64 LP64 ABI (`long` is 64-bit). ABI switch layer: LONG_MAX is
   arch specific, and so is the signedness of plain char -- that one is taken
   from the compiler's own __CHAR_UNSIGNED__ rather than from this directory. */

#ifndef _RUBYCC_LIMITS_H
#define _RUBYCC_LIMITS_H

#define CHAR_BIT    8
#define MB_LEN_MAX  16

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
