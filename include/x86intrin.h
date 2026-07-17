/* rubycc freestanding <x86intrin.h>: an intentionally empty stub.

   CRuby's config.h bakes in HAVE_X86INTRIN_H (it was probed with gcc), so
   headers such as json's vendored fast_float parser include <x86intrin.h>
   unconditionally on x86-64. rubycc, however, provides no SIMD intrinsics.

   This is safe because every actual use of an intrinsic behind such an include
   is itself guarded by a target-feature macro (__AVX2__, __LZCNT__, __SSE4_2__
   and the like), and rubycc defines none of those. With the feature macros
   undefined, the intrinsic bodies are never reached, so an empty header
   satisfies the include without pulling in declarations rubycc cannot honor. */

#ifndef _RUBYCC_X86INTRIN_H
#define _RUBYCC_X86INTRIN_H

#endif /* _RUBYCC_X86INTRIN_H */
