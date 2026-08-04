/* rubycc freestanding <stdckdint.h>: checked integer arithmetic (ISO C23 7.20).
   Compiler-supplied rather than libc-supplied, like <stdarg.h> and <stdbool.h>:
   the ckd_* macros are type-generic over every integer type, which only the
   compiler can express, so C23 makes the header the implementation's job.

   rubycc ships it because an installed Ruby can force it on. Ruby's
   <ruby/internal/stdckdint.h> includes this header whenever its config.h says
   HAVE_STDCKDINT_H -- which is decided by whatever compiler built that Ruby, not
   by rubycc -- and <ruby/internal/memory.h> then calls ckd_mul(). Without this
   header such a Ruby's ruby.h does not preprocess at all under rubycc, which is
   how the gap was found (docs/STEPS.md Step 175, on musl + Ruby 4.0).

   The macros are one-liners over the overflow builtins added in Step 177: each
   computes its operands' product/sum/difference in infinite precision, stores
   the result converted to *r, and answers whether that conversion lost the
   value. Note the argument order differs from the builtins' -- C23 puts the
   result pointer first. */

#ifndef _RUBYCC_STDCKDINT_H
#define _RUBYCC_STDCKDINT_H

#define __STDC_VERSION_STDCKDINT_H__ 202311L

#define ckd_add(r, a, b) ((_Bool)__builtin_add_overflow((a), (b), (r)))
#define ckd_sub(r, a, b) ((_Bool)__builtin_sub_overflow((a), (b), (r)))
#define ckd_mul(r, a, b) ((_Bool)__builtin_mul_overflow((a), (b), (r)))

#endif
