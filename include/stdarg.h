/* rubycc freestanding <stdarg.h>: variable arguments (ISO C 7.16).
   Maps onto rubycc's __builtin_va_* intrinsics and __builtin_va_list. */

/* __gnuc_va_list is provided for the glibc partial-include protocol
   (stdio.h/wchar.h "#define __need___va_list" then include this). */
#if !defined _RUBYCC_GNUC_VA_LIST
#define _RUBYCC_GNUC_VA_LIST
typedef __builtin_va_list __gnuc_va_list;
#endif
#undef __need___va_list

#ifndef _RUBYCC_STDARG_H
#define _RUBYCC_STDARG_H
typedef __builtin_va_list va_list;
#define va_start(ap, last) __builtin_va_start(ap, last)
#define va_arg(ap, type) __builtin_va_arg(ap, type)
#define va_end(ap) __builtin_va_end(ap)
#define va_copy(d, s) __builtin_va_copy(d, s)
#endif
