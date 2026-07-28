/* rubycc bundled <setjmp.h>: the ISO C non-local jump facility (C11 7.13) plus
   the POSIX sigsetjmp/siglongjmp pair. Provenance: clean room against the
   glibc setjmp ABI (bits/setjmp.h, struct __jmp_buf_tag in bits/setjmpP.h),
   not derived from musl or glibc source -- and a measured glibc ABI, not a
   kernel UAPI, since jmp_buf is glibc internal state (a saved register set)
   rather than a system-call interface. jmp_buf/sigjmp_buf are glibc
   implementation detail (the callee-saved registers, stack pointer, program
   counter, and -- for sigjmp_buf -- the saved signal mask), so rubycc
   reproduces only their measured size and alignment as an opaque byte blob --
   a union of a char __size[N] arm and the aligning scalar -- and does not copy
   glibc's internal field layout (__jmpbuf / __mask_was_saved / __saved_mask),
   the same principle pthread.h follows for its opaque objects. Only that size
   and alignment is an ABI fact reproduced by measurement, not copied text (see
   docs/HEADER-LICENSING.md). setjmp/longjmp/_setjmp/_longjmp/siglongjmp are
   POSIX/ISO C declarations whose bodies resolve from the host libc at link
   time (glibc folds them into libc), the same way errno.h's __errno_location
   does. sigsetjmp is the one exception: glibc exports no plain `sigsetjmp'
   symbol, only `__sigsetjmp' (measured: a plain `int sigsetjmp(...)'
   declaration fails to link against glibc), so this header follows glibc's own
   public macro contract and expands `sigsetjmp' onto `__sigsetjmp' -- a
   documented interoperability fact, not copied glibc source.
   Placed in the glibc/aarch64 layer because the opaque size is arch dependent:
   jmp_buf holds one register set per architecture, so it is wider here than on
   x86-64 (aarch64 saves more callee-saved integer and FP/SIMD registers) -- this
   file differs from the companion glibc/x86-64/setjmp.h only in the __size[N]
   count (and this provenance line).
   Measured: sizeof(jmp_buf) == sizeof(sigjmp_buf) == 312, _Alignof == 8, on
   aarch64 glibc (a small probe printing sizeof/_Alignof, cross-compiled with
   aarch64-linux-gnu-gcc -static and run under qemu-aarch64; see
   test/test_header_abi.rb's SETJMP case run against the cross-gcc oracle for
   the same values).
   Caution for rubycc users: 7.13.2.1p3 of the C standard leaves the values of
   non-volatile automatic variables modified between setjmp and longjmp
   unspecified if they were changed after the setjmp call. rubycc performs no
   register allocation across calls -- every local is spilled to its stack slot
   on every store -- so in practice such values come back unchanged after a
   longjmp, which is the conservative (safe) side of that rule: rubycc never
   restores a stale value the way an optimizing compiler that shuffled variables
   into registers might. Do not rely on this coincidence; write code that treats
   such variables as unspecified, as the standard requires, and mark anything
   that must survive the jump `volatile`. */

#ifndef _RUBYCC_SETJMP_H
#define _RUBYCC_SETJMP_H

/* The opaque saved-context blocks. glibc stores the callee-saved registers,
   stack pointer and program counter (and, for sigjmp_buf, the saved signal
   mask) inside; rubycc reproduces only the measured size and alignment as an
   opaque blob (the char __size[N] arm alongside the aligning scalar), so a
   variable of the type occupies the right space and alignment without copying
   glibc's field layout. Wider than on x86-64 (a different register file),
   which is why this header lives in the arch layer. */
typedef union { char __size[312]; long __align; } jmp_buf[1];
typedef union { char __size[312]; long __align; } sigjmp_buf[1];

int  setjmp(jmp_buf __env);
void longjmp(jmp_buf __env, int __val) __attribute__((__noreturn__));

/* BSD/POSIX non-restoring variants (do not save/restore the signal mask). */
int  _setjmp(jmp_buf __env);
void _longjmp(jmp_buf __env, int __val) __attribute__((__noreturn__));

/* POSIX sigsetjmp. glibc exports no plain `sigsetjmp' symbol -- only
   `__sigsetjmp' -- because sigsetjmp must capture its caller's own stack
   frame, so glibc's own <setjmp.h> makes `sigsetjmp' a macro onto
   `__sigsetjmp' rather than a plain function (a documented public-interface
   fact, not glibc source text: measured here by observing that a plain
   `int sigsetjmp(...)' declaration fails to link against glibc, while
   `__sigsetjmp' does). rubycc's header follows that same public contract so
   generated calls resolve against the host libc. */
int  __sigsetjmp(sigjmp_buf __env, int __savemask);
#define sigsetjmp(__env, __savemask) __sigsetjmp(__env, __savemask)
void siglongjmp(sigjmp_buf __env, int __val) __attribute__((__noreturn__));

#endif /* _RUBYCC_SETJMP_H */
