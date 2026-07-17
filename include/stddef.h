/* rubycc freestanding <stddef.h>: common definitions (ISO C 7.19).
   Types are fixed for the x86-64 System V LP64 target. The __need_* guards
   honor the glibc partial-include protocol (a header pulling in only NULL or
   size_t rather than the whole file). */

#if defined __need_NULL || defined __need_size_t || defined __need_wchar_t || defined __need_ptrdiff_t
#if defined __need_NULL
#ifndef NULL
#define NULL ((void*)0)
#endif
#undef __need_NULL
#endif
#if defined __need_size_t
#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#undef __need_size_t
#endif
#if defined __need_wchar_t
#ifndef _RUBYCC_WCHAR_T
#define _RUBYCC_WCHAR_T
typedef int wchar_t;
#endif
#undef __need_wchar_t
#endif
#if defined __need_ptrdiff_t
#ifndef _RUBYCC_PTRDIFF_T
#define _RUBYCC_PTRDIFF_T
typedef long ptrdiff_t;
#endif
#undef __need_ptrdiff_t
#endif
#else
#ifndef _RUBYCC_STDDEF_H
#define _RUBYCC_STDDEF_H
#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_PTRDIFF_T
#define _RUBYCC_PTRDIFF_T
typedef long ptrdiff_t;
#endif
#ifndef _RUBYCC_WCHAR_T
#define _RUBYCC_WCHAR_T
typedef int wchar_t;
#endif
#ifndef NULL
#define NULL ((void*)0)
#endif
/* Folds to a size_t constant via __builtin_offsetof, so it holds in a
   constant-expression context (a static initializer, an array bound, a case
   label) as well as at run time — unlike the traditional address-of-member
   form "((size_t)&(((t*)0)->m))", which rubycc's constant evaluator cannot
   fold. */
#define offsetof(t, m) __builtin_offsetof(t, m)
typedef struct { long long __ll; long double __ld; } max_align_t;
#endif
#endif
