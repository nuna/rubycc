/* rubycc bundled <alloca.h>: the alloca declaration, mapped onto the compiler
   builtin (glibc/BSD extension). Derived from musl's <alloca.h> shape. Common
   layer: the builtin mapping is the same on any target. */

#ifndef _RUBYCC_ALLOCA_H
#define _RUBYCC_ALLOCA_H

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif

extern void *alloca(size_t __size);

#undef alloca
#define alloca(size) __builtin_alloca(size)

#endif /* _RUBYCC_ALLOCA_H */
