/* rubycc freestanding <float.h>: floating-type characteristics (ISO C 7.7).
   float is IEEE 754 binary32 and double is binary64 on every target rubycc
   supports, so those are unconditional. `long double` is not: x86-64 gives it
   the x87 80-bit extended format, aarch64 the IEEE 754 binary128 quad. This
   file is the freestanding layer -- one file for every machine, unlike
   include/libc/glibc/<arch>/ -- so the machine split is carried inline, on the
   arch macro the preprocessor predefines per target.

   That split was missing until Step 200: this header handed x87's numbers to
   aarch64 too. It went unnoticed because the aarch64 ABI harness covered only
   the arch-layer headers, on the assumption that a freestanding header has
   nothing arch-specific in it -- an assumption this file disproves. All the
   values below were measured with each target's own gcc (the x86-64 column
   reproduces this file's previous contents exactly, which is what validates
   the method). */

#ifndef _RUBYCC_FLOAT_H
#define _RUBYCC_FLOAT_H

/* Common to every floating type. */
#define FLT_RADIX       2
#define FLT_ROUNDS      1
#define FLT_EVAL_METHOD 0
#if defined(__aarch64__)
#define DECIMAL_DIG     36
#else
#define DECIMAL_DIG     21
#endif

/* float (IEEE 754 binary32). */
#define FLT_MANT_DIG    24
#define FLT_DIG         6
#define FLT_DECIMAL_DIG 9
#define FLT_MIN_EXP     (-125)
#define FLT_MIN_10_EXP  (-37)
#define FLT_MAX_EXP     128
#define FLT_MAX_10_EXP  38
#define FLT_MAX         3.40282347e+38F
#define FLT_MIN         1.17549435e-38F
#define FLT_EPSILON     1.19209290e-7F
#define FLT_TRUE_MIN    1.40129846e-45F
#define FLT_HAS_SUBNORM 1

/* double (IEEE 754 binary64). */
#define DBL_MANT_DIG    53
#define DBL_DIG         15
#define DBL_DECIMAL_DIG 17
#define DBL_MIN_EXP     (-1021)
#define DBL_MIN_10_EXP  (-307)
#define DBL_MAX_EXP     1024
#define DBL_MAX_10_EXP  308
#define DBL_MAX         1.7976931348623157e+308
#define DBL_MIN         2.2250738585072014e-308
#define DBL_EPSILON     2.2204460492503131e-16
#define DBL_TRUE_MIN    4.9406564584124654e-324
#define DBL_HAS_SUBNORM 1

/* long double. The exponent range is the same either way -- both formats carry
   15 exponent bits -- so only the precision-derived macros and the magnitudes
   that depend on the mantissa width differ. */
#define LDBL_MIN_EXP     (-16381)
#define LDBL_MIN_10_EXP  (-4931)
#define LDBL_MAX_EXP     16384
#define LDBL_MAX_10_EXP  4932
#define LDBL_HAS_SUBNORM 1

#if defined(__aarch64__)
/* IEEE 754 binary128 ("quad"): a 113-bit significand. */
#define LDBL_MANT_DIG    113
#define LDBL_DIG         33
#define LDBL_DECIMAL_DIG 36
#define LDBL_MAX         1.18973149535723176508575932662800702e+4932L
#define LDBL_MIN         3.36210314311209350626267781732175260e-4932L
#define LDBL_EPSILON     1.92592994438723585305597794258492732e-34L
#define LDBL_TRUE_MIN    6.47517511943802511092443895822764655e-4966L
#else
/* x87 80-bit extended: a 64-bit significand. */
#define LDBL_MANT_DIG    64
#define LDBL_DIG         18
#define LDBL_DECIMAL_DIG 21
#define LDBL_MAX         1.18973149535723176502e+4932L
#define LDBL_MIN         3.36210314311209350626e-4932L
#define LDBL_EPSILON     1.08420217248550443401e-19L
#define LDBL_TRUE_MIN    3.64519953188247460253e-4951L
#endif

#endif
