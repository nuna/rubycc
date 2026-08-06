/* rubycc's freestanding <stdatomic.h> subset.
 *
 * This header intentionally exposes only the fence primitive needed by the
 * C11 library users currently in the corpus. `_Atomic` objects and the rest of
 * the atomic API remain outside the compiler's supported subset; keeping those
 * names absent is preferable to advertising a non-atomic implementation.
 */
#ifndef RUBYCC_STDATOMIC_H
#define RUBYCC_STDATOMIC_H

typedef int memory_order;

#define memory_order_relaxed __ATOMIC_RELAXED
#define memory_order_consume __ATOMIC_CONSUME
#define memory_order_acquire __ATOMIC_ACQUIRE
#define memory_order_release __ATOMIC_RELEASE
#define memory_order_acq_rel __ATOMIC_ACQ_REL
#define memory_order_seq_cst __ATOMIC_SEQ_CST

#define atomic_thread_fence(order) __atomic_thread_fence(order)

#endif
