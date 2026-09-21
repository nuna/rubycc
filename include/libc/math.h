/* rubycc bundled <math.h>: the floating-point declarations and classification
   macros (ISO C 7.12). Derived from musl's <math.h> declaration set; the special
   values and classifiers are expressed through the compiler builtins so they
   fold to the same bit patterns gcc uses, and the FP_* / math_errhandling values
   are measured (math_errhandling is the one the two C libraries differ on, so
   both values are carried under __RUBYCC_LIBC_MUSL__; see the preprocessor's
   LIBCS). Common layer: nothing here is arch specific beyond the (universal on
   the hosted targets' IEEE 754 model; the two target libc ABIs select their
   distinct FP_ILOGB* values below.

   Coverage against glibc's <math.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, x86-64 and aarch64, with tools/audit_bundled_headers.rb; table
   in docs/development/BUNDLED-HEADERS-COVERAGE.md). glibc's <math.h> shows
   close to a thousand names, almost all of them the same function spelled once
   per floating type; the audit's difference was classified in full and the
   families left out are listed below. Added there: the ISO C99 companions this
   header had only the `double` half of (lrintf and kin -- rubycc rejected
   lrintf before, measured 2026-09-18), the XSI Bessel functions with signgam
   and MAXFLOAT, lgamma_r (the thread-safe lgamma a statistics extension wants)
   and, under __USE_GNU, exp10 and sincos. Every added prototype was written
   here and then placed next to glibc's own <math.h> under gcc and
   aarch64-linux-gnu-gcc, where a conflicting redeclaration is an error
   (2026-09-18, both clean); MAXFLOAT was printed from the oracle on both
   arches and is the largest finite float, 3.40282347e+38F.
   Intentionally left out:
   omitted: *f32 *f32x *f64 *f64x *f128 SNAN* HUGE_VAL_* lgammaf32_r
   lgammaf32x_r lgammaf64_r lgammaf64x_r lgammaf128_r -- ISO/IEC TS 18661
   interfaces over the _FloatN types rubycc does not model (the line
   <stdlib.h> draws at strtof128). omitted: M_*f M_*l -- the float and
   long-double spellings of the constants above; on this target long double is
   the same 64-bit double, and a float constant is the double one converted.
   omitted: fmaximum* fminimum* fmaxmag* fminmag* roundeven* nextup* nextdown*
   llogb* fromfp* ufromfp* totalorder* totalordermag* getpayload* setpayload*
   setpayloadsig* canonicalize* iscanonical issignaling issubnormal iszero
   iseqsig FP_INT_* FP_LLOGB* -- the IEEE 754-2019 / C23 additions, most of
   them glibc 2.25 or later and none with a corpus user; declaring them would
   promise symbols an older host glibc does not have.
   omitted: fadd faddl fdiv fdivl ffma ffmal fmul fmull fsqrt fsqrtl fsub
   fsubl daddl ddivl dfmal dmull dsqrtl dsubl -- C23's narrowing arithmetic
   (add two long doubles, round once to float); glibc 2.28 and later.
   omitted: drem* finite* gamma* scalb scalbf scalbl significand* isinff
   isinfl isnanf isnanl -- the SVID/BSD legacy, superseded by remainder,
   isfinite, tgamma/lgamma, scalbn and the type-generic classification macros
   above, which already answer for float and long double.
   omitted: FP_FAST_FMA FP_FAST_FMAF -- glibc defines these from the
   *compiler's* view of whether the target has a fused multiply-add
   instruction, which is why they appear on aarch64 and, on x86-64, only under
   -mfma (measured 2026-09-18, the only arch difference in this header's
   audit); a bundled header cannot answer that for the compiler, and a program
   reads them only to choose between fma() and a plain a*b+c. */

#ifndef _RUBYCC_MATH_H
#define _RUBYCC_MATH_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

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

/* glibc's AArch64 math ABI uses -2147483647 for FP_ILOGB0 and INT_MAX for
   FP_ILOGBNAN; glibc's x86-64 uses INT_MIN for both. These are header ABI
   values, not compiler implementation details, so select them from the target
   macro just as float.h and the arch libc headers do.

   musl uses INT_MIN for both on *every* machine, so the C library has to be
   part of the selection and not only the architecture. Branching on the machine
   alone was wrong exactly where the two disagree -- AArch64 musl, where this
   header claimed glibc's pair (measured against Alpine's own gcc on an arm64
   container, 2026-08-12, the first time the suite ran there). x86-64 musl agreed
   with glibc by coincidence, which is why the x86-64 musl runs never caught
   it. */
#if defined(__RUBYCC_LIBC_MUSL__)
#define FP_ILOGB0   (-2147483647-1)
#define FP_ILOGBNAN (-2147483647-1)
#elif defined(__aarch64__)
#define FP_ILOGB0   (-2147483647)
#define FP_ILOGBNAN (2147483647)
#else
#define FP_ILOGB0   (-2147483647-1)
#define FP_ILOGBNAN (-2147483647-1)
#endif

#define MATH_ERRNO     1
#define MATH_ERREXCEPT 2
/* math_errhandling is the one value in this header the two C libraries
   disagree on: musl reports 2 (it raises the floating-point exceptions but
   does not promise errno) where glibc reports 3 (both). Measured with the ABI
   harness, glibc's on this host and musl's on the CI musl run (docs/STEPS.md
   Step 193); MATH_ERRNO, MATH_ERREXCEPT, the FP_* codes and FP_ILOGB* are
   probed too; the FP_ILOGB* values are target-specific as documented above. */
#if defined(__RUBYCC_LIBC_MUSL__)
#define math_errhandling (MATH_ERREXCEPT)
#else
#define math_errhandling (MATH_ERRNO | MATH_ERREXCEPT)
#endif

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
int    ilogbf(float);
int    ilogbl(long double);
long   lround(double);
long long llround(double);
long   lrint(double);
long long llrint(double);
long   lroundf(float);
long   lroundl(long double);
long long llroundf(float);
long long llroundl(long double);
long   lrintf(float);
long   lrintl(long double);
long long llrintf(float);
long long llrintl(long double);
float  scalblnf(float, long);
long double scalblnl(long double, long);
double nexttoward(double, long double);
float  nexttowardf(float, long double);
long double nexttowardl(long double, long double);
double remquo(double, double, int *);
float  remquof(float, float, int *);
long double remquol(long double, long double, int *);

/* lgamma writes the sign of the result's gamma into signgam, which makes it
   unusable from two threads at once; lgamma_r returns that sign through the
   caller's own int instead. glibc shows the _r form in gcc's default mode. */
double lgamma_r(double, int *);
float  lgammaf_r(float, int *);
long double lgammal_r(long double, int *);
extern int signgam;

/* The largest finite float, X/Open's older spelling of FLT_MAX. Printed from
   the glibc oracle on both arches (2026-09-18) and equal to <float.h>'s
   FLT_MAX there. */
#define MAXFLOAT 3.40282347e+38F

/* The Bessel functions of the first (j) and second (y) kind: orders 0, 1 and
   n. POSIX/XSI has the double forms; the float and long-double ones are
   glibc's, shown in gcc's default mode. */
double j0(double);
double j1(double);
double jn(int, double);
double y0(double);
double y1(double);
double yn(int, double);
float  j0f(float);
float  j1f(float);
float  jnf(int, float);
float  y0f(float);
float  y1f(float);
float  ynf(int, float);
long double j0l(long double);
long double j1l(long double);
long double jnl(int, long double);
long double y0l(long double);
long double y1l(long double);
long double ynl(int, long double);

/* GNU-only names, gated as glibc gates them: base-10 exponentiation, and the
   pair that computes a sine and a cosine in one call. */
#ifdef __USE_GNU
double exp10(double);
float  exp10f(float);
long double exp10l(long double);
void   sincos(double, double *, double *);
void   sincosf(float, float *, float *);
void   sincosl(long double, long double *, long double *);
#endif

#endif /* _RUBYCC_MATH_H */
