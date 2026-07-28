/* rubycc bundled <sched.h>: scheduling (POSIX.1), pared down to the surface
   etc and google-protobuf's corpus samples actually reach (sched_yield,
   sched_getcpu, and cpu_set_t's existence) rather than glibc's full affinity
   API, per Step 123's (M5 H2) explicit scope. Provenance: clean room against
   the glibc/Linux ABI. cpu_set_t is glibc-internal state (a bitmap of
   CPU_SETSIZE bits used only through the CPU_SET/CPU_ZERO/CPU_ISSET macro
   family, none of which any corpus sample census hit needs), so, like
   pthread.h's opaque objects and setjmp.h's jmp_buf, rubycc reproduces only
   its measured size and alignment as an opaque byte blob -- a union of a
   char __size[N] arm and the aligning scalar -- and does not name glibc's
   internal __bits array. That size/alignment (128, 8-byte aligned) was
   measured against the glibc oracle on both x86-64 and aarch64 (see
   test/test_header_abi.rb's SCHED case) and the two agreed exactly (both are
   LP64, so CPU_SETSIZE/8 bytes of bitmap has no arch-dependent width), so
   this header lives in the common layer. sched_yield/sched_getcpu are POSIX/
   glibc declarations whose bodies resolve from the host libc at link time.
   Not included: sched_setaffinity/sched_getaffinity/CPU_SET/CPU_ZERO/
   CPU_ISSET and the sched_setscheduler family (no corpus sample census hit
   needs them; adding the affinity macros would require reproducing
   glibc-internal bit-numbering, not just an opaque size). */

#ifndef _RUBYCC_SCHED_H
#define _RUBYCC_SCHED_H

#define CPU_SETSIZE 1024

/* Opaque CPU affinity bitmap. glibc stores CPU_SETSIZE bits inside as an
   array of unsigned long words; rubycc reproduces only the measured size and
   alignment as an opaque blob, not the internal word layout. */
typedef union { char __size[128]; long __align; } cpu_set_t;

int sched_yield(void);
int sched_getcpu(void);

#endif /* _RUBYCC_SCHED_H */
