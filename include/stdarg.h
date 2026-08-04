/* rubycc freestanding <stdarg.h>: variable arguments (ISO C 7.16).
   Maps onto rubycc's __builtin_va_* intrinsics and __builtin_va_list. */

/* __gnuc_va_list is provided for the glibc partial-include protocol
   (stdio.h/wchar.h "#define __need___va_list" then include this). */
#if !defined _RUBYCC_GNUC_VA_LIST
#define _RUBYCC_GNUC_VA_LIST
typedef __builtin_va_list __gnuc_va_list;
#endif
#undef __need___va_list

/* __isoc_va_list is musl's name for the same type, where glibc writes
   __gnuc_va_list. Both are provided unconditionally rather than per libc: they
   are aliases of one type, so offering both costs nothing and lets a source
   written against either libc's internal spelling compile. Repeating a typedef
   with the same type is legal (C11 6.7p3), so a host header that defines its
   own afterwards is not a conflict. Measured on musl in CI, where a probe
   spelling it __isoc_va_list did not compile (docs/STEPS.md Step 190). */
#if !defined _RUBYCC_ISOC_VA_LIST
#define _RUBYCC_ISOC_VA_LIST
typedef __builtin_va_list __isoc_va_list;
#endif

#ifndef _RUBYCC_STDARG_H
#define _RUBYCC_STDARG_H
typedef __builtin_va_list va_list;
#define va_start(ap, last) __builtin_va_start(ap, last)
#define va_arg(ap, type) __builtin_va_arg(ap, type)
#define va_end(ap) __builtin_va_end(ap)
#define va_copy(d, s) __builtin_va_copy(d, s)
#endif
