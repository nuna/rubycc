/* rubycc bundled <stdint.h>: exact/least/fast-width integer typedefs and their
   limit and constant-suffix macros (ISO C 7.20). Derived from musl's <stdint.h>
   as the declaration shape, with the widths pinned to the aarch64 LP64 ABI
   (measured): intmax_t/intptr_t are `long`, and the fast types are 64-bit on
   glibc but 32-bit on musl -- see below. The one ABI difference from the
   x86-64 layer besides the fast types is WCHAR_MIN/WCHAR_MAX: aarch64 makes
   wchar_t unsigned, so the macros are 0 and UINT32_MAX rather than the signed
   INT32_MIN/INT32_MAX. The wchar_t typedef itself is left `typedef int wchar_t`
   (signed): it is shared with the freestanding <stddef.h> through the
   _RUBYCC_WCHAR_T guard, so changing its signedness only here would make the two
   disagree depending on include order. wchar_t's signedness is therefore a known
   limitation (like long double's width); the ABI surface the harness checks --
   the WCHAR_MIN/WCHAR_MAX macro values -- is what is pinned to aarch64 here.
   The fast types are the other place the two C libraries part company, and here
   it is a machine-dependent fact rather than a portable one: on this arch
   [u]int_fast16_t/[u]int_fast32_t are 4 bytes, 4-byte aligned on musl against
   8 bytes, 8-byte aligned on glibc (both sizeof/_Alignof pairs measured with
   the ABI harness, glibc's on this host and musl's on the CI aarch64 musl run,
   docs/STEPS.md Step 202) -- the same split the x86-64 companion carries, but
   measured here rather than copied from there, since a fast type's width is
   exactly the kind of thing this arch layer exists to keep per-machine (R8).
   The limit macros further down follow these widths rather than restating
   them. ABI switch layer: these widths are arch specific. */

#ifndef _RUBYCC_STDINT_H
#define _RUBYCC_STDINT_H

#ifndef _RUBYCC_WCHAR_T
#define _RUBYCC_WCHAR_T
typedef int wchar_t;
#endif

typedef signed char        int8_t;
typedef short              int16_t;
typedef int                int32_t;
typedef long               int64_t;
typedef unsigned char      uint8_t;
typedef unsigned short     uint16_t;
typedef unsigned int       uint32_t;
typedef unsigned long      uint64_t;

typedef signed char        int_least8_t;
typedef short              int_least16_t;
typedef int                int_least32_t;
typedef long               int_least64_t;
typedef unsigned char      uint_least8_t;
typedef unsigned short     uint_least16_t;
typedef unsigned int       uint_least32_t;
typedef unsigned long      uint_least64_t;

typedef signed char        int_fast8_t;
#if defined(__RUBYCC_LIBC_MUSL__)
typedef int                int_fast16_t;
typedef int                int_fast32_t;
#else
typedef long               int_fast16_t;
typedef long               int_fast32_t;
#endif
typedef long               int_fast64_t;
typedef unsigned char      uint_fast8_t;
#if defined(__RUBYCC_LIBC_MUSL__)
typedef unsigned int       uint_fast16_t;
typedef unsigned int       uint_fast32_t;
#else
typedef unsigned long      uint_fast16_t;
typedef unsigned long      uint_fast32_t;
#endif
typedef unsigned long      uint_fast64_t;

#ifndef _RUBYCC_INTPTR_T
#define _RUBYCC_INTPTR_T
typedef long               intptr_t;
#endif
#ifndef _RUBYCC_UINTPTR_T
#define _RUBYCC_UINTPTR_T
typedef unsigned long      uintptr_t;
#endif
typedef long               intmax_t;
typedef unsigned long      uintmax_t;

/* Exact-width limits. */
#define INT8_MIN    (-128)
#define INT16_MIN   (-32768)
#define INT32_MIN   (-2147483647-1)
#define INT64_MIN   (-9223372036854775807L-1)
#define INT8_MAX    (127)
#define INT16_MAX   (32767)
#define INT32_MAX   (2147483647)
#define INT64_MAX   (9223372036854775807L)
#define UINT8_MAX   (255)
#define UINT16_MAX  (65535)
#define UINT32_MAX  (4294967295U)
#define UINT64_MAX  (18446744073709551615UL)

/* Least-width limits (same representation as the exact widths here). */
#define INT_LEAST8_MIN    INT8_MIN
#define INT_LEAST16_MIN   INT16_MIN
#define INT_LEAST32_MIN   INT32_MIN
#define INT_LEAST64_MIN   INT64_MIN
#define INT_LEAST8_MAX    INT8_MAX
#define INT_LEAST16_MAX   INT16_MAX
#define INT_LEAST32_MAX   INT32_MAX
#define INT_LEAST64_MAX   INT64_MAX
#define UINT_LEAST8_MAX   UINT8_MAX
#define UINT_LEAST16_MAX  UINT16_MAX
#define UINT_LEAST32_MAX  UINT32_MAX
#define UINT_LEAST64_MAX  UINT64_MAX

/* Fast-width limits (fast8 is 8-bit; fast64 is 64-bit on both libcs). The
   fast16/fast32 group is the range of the type selected above: 32-bit on
   musl, so INT_FAST16_MAX/INT_FAST32_MAX are 2147483647 there against
   glibc's 9223372036854775807 (both measured with the ABI harness, glibc's
   on this host and musl's on the CI aarch64 musl run, docs/STEPS.md
   Step 202). The MIN and unsigned MAX macros are spelled through the same
   exact-width names, so they follow the width rather than being asserted
   separately. */
#define INT_FAST8_MIN     INT8_MIN
#if defined(__RUBYCC_LIBC_MUSL__)
#define INT_FAST16_MIN    INT32_MIN
#define INT_FAST32_MIN    INT32_MIN
#else
#define INT_FAST16_MIN    INT64_MIN
#define INT_FAST32_MIN    INT64_MIN
#endif
#define INT_FAST64_MIN    INT64_MIN
#define INT_FAST8_MAX     INT8_MAX
#if defined(__RUBYCC_LIBC_MUSL__)
#define INT_FAST16_MAX    INT32_MAX
#define INT_FAST32_MAX    INT32_MAX
#else
#define INT_FAST16_MAX    INT64_MAX
#define INT_FAST32_MAX    INT64_MAX
#endif
#define INT_FAST64_MAX    INT64_MAX
#define UINT_FAST8_MAX    UINT8_MAX
#if defined(__RUBYCC_LIBC_MUSL__)
#define UINT_FAST16_MAX   UINT32_MAX
#define UINT_FAST32_MAX   UINT32_MAX
#else
#define UINT_FAST16_MAX   UINT64_MAX
#define UINT_FAST32_MAX   UINT64_MAX
#endif
#define UINT_FAST64_MAX   UINT64_MAX

/* Pointer-holding, greatest-width, and the stddef/wchar companions. */
#define INTPTR_MIN        INT64_MIN
#define INTPTR_MAX        INT64_MAX
#define UINTPTR_MAX       UINT64_MAX
#define INTMAX_MIN        INT64_MIN
#define INTMAX_MAX        INT64_MAX
#define UINTMAX_MAX       UINT64_MAX
#define PTRDIFF_MIN       INT64_MIN
#define PTRDIFF_MAX       INT64_MAX
#define SIZE_MAX          UINT64_MAX
#define SIG_ATOMIC_MIN    INT32_MIN
#define SIG_ATOMIC_MAX    INT32_MAX
#define WCHAR_MIN         0
#define WCHAR_MAX         UINT32_MAX
#define WINT_MIN          (0U)
#define WINT_MAX          (4294967295U)

/* Constant-expression suffix macros. */
#define INT8_C(c)     c
#define INT16_C(c)    c
#define INT32_C(c)    c
#define INT64_C(c)    c ## L
#define UINT8_C(c)    c
#define UINT16_C(c)   c
#define UINT32_C(c)   c ## U
#define UINT64_C(c)   c ## UL
#define INTMAX_C(c)   c ## L
#define UINTMAX_C(c)  c ## UL

#endif /* _RUBYCC_STDINT_H */
