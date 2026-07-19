/* rubycc bundled <math.h>: the floating-point declarations and classification
   macros (ISO C 7.12). Derived from musl's <math.h> declaration set; the special
   values and classifiers are expressed through the compiler builtins so they
   fold to the same bit patterns gcc uses, and the FP_* / math_errhandling values
   match the glibc ABI (measured). Common layer: nothing here is arch specific
   beyond the (universal on this target) IEEE 754 model. */

#ifndef _RUBYCC_MATH_H
#define _RUBYCC_MATH_H

/* Special magnitudes. rubycc does not implement gcc's __builtin_huge_val/inf/nan
   family, so these use the classic overflow-literal and 0/0 spellings, which
   both toolchains fold to the same IEEE 754 infinity / quiet-NaN bit patterns
   (verified against gcc). */
#define HUGE_VAL   (1e10000)
#define HUGE_VALF  (1e10000f)
#define HUGE_VALL  (1e10000L)
#define INFINITY   (1e10000f)
#define NAN        (0.0f / 0.0f)

/* Classification result codes (glibc values). */
#define FP_NAN       0
#define FP_INFINITE  1
#define FP_ZERO      2
#define FP_SUBNORMAL 3
#define FP_NORMAL    4

#define FP_ILOGB0   (-2147483647-1)
#define FP_ILOGBNAN (-2147483647-1)

#define MATH_ERRNO     1
#define MATH_ERREXCEPT 2
#define math_errhandling (MATH_ERRNO | MATH_ERREXCEPT)

/* Classifiers, implemented in C (rubycc has no __builtin_isnan/signbit/...).
   The bit-inspecting helpers cover the double-or-narrower case; long double is
   an 8-byte double on this target, so the double helper handles it too. */
static inline int __rubycc_signbit(double __x) {
  union { double __d; unsigned long __u; } __v; __v.__d = __x;
  return (int) (__v.__u >> 63);
}
static inline int __rubycc_fpclassify(double __x) {
  union { double __d; unsigned long __u; } __v; __v.__d = __x;
  unsigned long __exp  = (__v.__u >> 52) & 0x7ffUL;
  unsigned long __mant = __v.__u & 0xfffffffffffffUL;
  if (__exp == 0)      return __mant == 0 ? FP_ZERO : FP_SUBNORMAL;
  if (__exp == 0x7ffUL) return __mant == 0 ? FP_INFINITE : FP_NAN;
  return FP_NORMAL;
}

#define fpclassify(x) __rubycc_fpclassify((double)(x))
#define isnan(x)      ((x) != (x))
#define isinf(x)      (!isnan((double)(x)) && ((x) == HUGE_VAL || (x) == -HUGE_VAL))
#define isfinite(x)   (((x) - (x)) == 0)
#define isnormal(x)   (fpclassify(x) == FP_NORMAL)
#define signbit(x)    __rubycc_signbit((double)(x))
#define isgreater(x, y)      ((x) > (y))
#define isgreaterequal(x, y) ((x) >= (y))
#define isless(x, y)         ((x) < (y))
#define islessequal(x, y)    ((x) <= (y))
#define islessgreater(x, y)  ((x) < (y) || (x) > (y))
#define isunordered(x, y)    (isnan(x) || isnan(y))

/* Common mathematical constants (glibc, under _DEFAULT_SOURCE). */
#define M_E        2.7182818284590452354
#define M_LOG2E    1.4426950408889634074
#define M_LOG10E   0.43429448190325182765
#define M_LN2      0.69314718055994530942
#define M_LN10     2.30258509299404568402
#define M_PI       3.14159265358979323846
#define M_PI_2     1.57079632679489661923
#define M_PI_4     0.78539816339744830962
#define M_1_PI     0.31830988618379067154
#define M_2_PI     0.63661977236758134308
#define M_2_SQRTPI 1.12837916709551257390
#define M_SQRT2    1.41421356237309504880
#define M_SQRT1_2  0.70710678118654752440

typedef float  float_t;
typedef double double_t;

/* Double, float and long-double declarations for the standard functions. */
#define __RUBYCC_MATHDECL(name) \
  double name(double); float name##f(float); long double name##l(long double);
#define __RUBYCC_MATHDECL2(name) \
  double name(double, double); float name##f(float, float); \
  long double name##l(long double, long double);

__RUBYCC_MATHDECL(acos)
__RUBYCC_MATHDECL(asin)
__RUBYCC_MATHDECL(atan)
__RUBYCC_MATHDECL2(atan2)
__RUBYCC_MATHDECL(cos)
__RUBYCC_MATHDECL(sin)
__RUBYCC_MATHDECL(tan)
__RUBYCC_MATHDECL(cosh)
__RUBYCC_MATHDECL(sinh)
__RUBYCC_MATHDECL(tanh)
__RUBYCC_MATHDECL(acosh)
__RUBYCC_MATHDECL(asinh)
__RUBYCC_MATHDECL(atanh)
__RUBYCC_MATHDECL(exp)
__RUBYCC_MATHDECL(exp2)
__RUBYCC_MATHDECL(expm1)
__RUBYCC_MATHDECL(log)
__RUBYCC_MATHDECL(log10)
__RUBYCC_MATHDECL(log1p)
__RUBYCC_MATHDECL(log2)
__RUBYCC_MATHDECL(logb)
__RUBYCC_MATHDECL(cbrt)
__RUBYCC_MATHDECL(sqrt)
__RUBYCC_MATHDECL2(pow)
__RUBYCC_MATHDECL2(hypot)
__RUBYCC_MATHDECL(ceil)
__RUBYCC_MATHDECL(fabs)
__RUBYCC_MATHDECL(floor)
__RUBYCC_MATHDECL2(fmod)
__RUBYCC_MATHDECL(round)
__RUBYCC_MATHDECL(trunc)
__RUBYCC_MATHDECL(rint)
__RUBYCC_MATHDECL(nearbyint)
__RUBYCC_MATHDECL2(remainder)
__RUBYCC_MATHDECL2(copysign)
__RUBYCC_MATHDECL2(nextafter)
__RUBYCC_MATHDECL2(fdim)
__RUBYCC_MATHDECL2(fmax)
__RUBYCC_MATHDECL2(fmin)
__RUBYCC_MATHDECL(tgamma)
__RUBYCC_MATHDECL(lgamma)
__RUBYCC_MATHDECL(erf)
__RUBYCC_MATHDECL(erfc)

double frexp(double, int *);
float  frexpf(float, int *);
long double frexpl(long double, int *);
double ldexp(double, int);
float  ldexpf(float, int);
long double ldexpl(long double, int);
double modf(double, double *);
float  modff(float, float *);
long double modfl(long double, long double *);
double scalbn(double, int);
float  scalbnf(float, int);
long double scalbnl(long double, int);
double scalbln(double, long);
double fma(double, double, double);
float  fmaf(float, float, float);
long double fmal(long double, long double, long double);
double nan(const char *);
float  nanf(const char *);
long double nanl(const char *);
int    ilogb(double);
long   lround(double);
long long llround(double);
long   lrint(double);
long long llrint(double);

#endif /* _RUBYCC_MATH_H */
