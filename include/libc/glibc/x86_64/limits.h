/* rubycc bundled <limits.h>: the arithmetic-type ranges (ISO C 5.2.4.2.1).
   Derived from the ISO-mandated values with the `long`/`char` widths pinned to
   the glibc x86-64 LP64 ABI (`long` is 64-bit, plain `char` is signed). ABI
   switch layer: LONG_MAX and the signedness of char are arch specific. */

#ifndef _RUBYCC_LIMITS_H
#define _RUBYCC_LIMITS_H

#define CHAR_BIT    8
#define MB_LEN_MAX  16

#define SCHAR_MIN   (-128)
#define SCHAR_MAX   127
#define UCHAR_MAX   255

/* Plain char is signed on the x86-64 SysV ABI. */
#define CHAR_MIN    SCHAR_MIN
#define CHAR_MAX    SCHAR_MAX

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
