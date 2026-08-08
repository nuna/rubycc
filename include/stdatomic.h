/* rubycc's freestanding <stdatomic.h> subset.
 *
 * rubycc compiles `_Atomic T` as plain `T` — same size, same alignment, same
 * ABI (measured against gcc type by type; see test/test_header_abi.rb's
 * STDATOMIC spec) — and only for the types that measurement covers: integer,
 * floating and pointer types of 1, 2, 4 or 8 bytes. `_Atomic` on an aggregate,
 * on a 16-byte scalar, on an array or on a function is a compile error rather
 * than a silently non-atomic object.
 *
 * What this header provides, all of it resting on the __atomic_* builtins the
 * compiler actually lowers to locked machine sequences:
 *
 *   atomic_load / atomic_store / atomic_exchange, their _explicit forms,
 *   atomic_compare_exchange_strong / _weak and their _explicit forms,
 *   atomic_fetch_add / atomic_fetch_sub and their _explicit forms,
 *   atomic_init, ATOMIC_VAR_INIT, kill_dependency,
 *   atomic_thread_fence / atomic_signal_fence, the memory_order constants,
 *   the atomic_* typedefs and the ATOMIC_*_LOCK_FREE macros.
 *
 * What it deliberately does NOT provide, because the builtins underneath
 * cannot implement it and a name that does not work is worse than a missing
 * one:
 *
 *   atomic_fetch_or / _and / _xor — rubycc has __atomic_or_fetch (which yields
 *     the *new* value) but no __atomic_fetch_or, and the old value cannot be
 *     recovered from the new one for a bitwise or; there is no and/xor form at
 *     all.
 *   atomic_flag, atomic_flag_test_and_set, atomic_flag_clear — these need
 *     __atomic_test_and_set / __atomic_clear on a 1-byte object, and rubycc
 *     lowers neither (its atomic objects are 4 or 8 bytes wide).
 *   atomic_is_lock_free — needs __atomic_is_lock_free.
 *
 * One further limit, stated rather than hidden: reading or writing an _Atomic
 * object with ordinary C operators (`x = 1;`, `if (x)`) compiles to an
 * ordinary access. At the admitted widths that access is a single naturally
 * aligned instruction, so it is still indivisible, but it does not carry the
 * sequential consistency C11 gives an atomic assignment. Use the macros below
 * where the ordering matters.
 */
#ifndef RUBYCC_STDATOMIC_H
#define RUBYCC_STDATOMIC_H

#include <stddef.h>

/* C11 makes memory_order an enumeration; the values are what matter and they
 * are the compiler's own __ATOMIC_* constants (whose values match gcc's, see
 * test/test_atomic_builtins.rb), so an int typedef carries the same width (4)
 * and the same values. */
typedef int memory_order;

#define memory_order_relaxed __ATOMIC_RELAXED
#define memory_order_consume __ATOMIC_CONSUME
#define memory_order_acquire __ATOMIC_ACQUIRE
#define memory_order_release __ATOMIC_RELEASE
#define memory_order_acq_rel __ATOMIC_ACQ_REL
#define memory_order_seq_cst __ATOMIC_SEQ_CST

/* The atomic-lock-free macros (7.17.1): 2 means "always lock-free", 0 means
 * "never". gcc answers 2 for every one of these on x86-64 (measured), because
 * it falls back to libatomic's locked path for the widths its ISA cannot do in
 * one instruction. rubycc has no such fallback — it refuses an operation it
 * cannot lower — so the honest answer is 2 only for the widths
 * Rubycc::IR::Generator::ATOMIC_WIDTHS covers, and 0 for the rest. A program
 * branching on these therefore takes its non-lock-free path for exactly the
 * types whose atomic operations rubycc would reject. */
#define ATOMIC_BOOL_LOCK_FREE 0
#define ATOMIC_CHAR_LOCK_FREE 0
#define ATOMIC_CHAR16_T_LOCK_FREE 0
#define ATOMIC_SHORT_LOCK_FREE 0
#define ATOMIC_CHAR32_T_LOCK_FREE 2
#define ATOMIC_WCHAR_T_LOCK_FREE 2
#define ATOMIC_INT_LOCK_FREE 2
#define ATOMIC_LONG_LOCK_FREE 2
#define ATOMIC_LLONG_LOCK_FREE 2
#define ATOMIC_POINTER_LOCK_FREE 2

/* The atomic typedefs (7.17.6). Each is written with the _Atomic qualifier so
 * the name documents itself, and each has its unqualified type's layout. The
 * narrow ones are declared even though no atomic operation lowers for them:
 * the type is usable, and an operation on it is refused at the call site with
 * the compiler's own "4 or 8 bytes only" diagnostic. */
typedef _Atomic _Bool atomic_bool;
typedef _Atomic char atomic_char;
typedef _Atomic signed char atomic_schar;
typedef _Atomic unsigned char atomic_uchar;
typedef _Atomic short atomic_short;
typedef _Atomic unsigned short atomic_ushort;
typedef _Atomic int atomic_int;
typedef _Atomic unsigned int atomic_uint;
typedef _Atomic long atomic_long;
typedef _Atomic unsigned long atomic_ulong;
typedef _Atomic long long atomic_llong;
typedef _Atomic unsigned long long atomic_ullong;
typedef _Atomic size_t atomic_size_t;
typedef _Atomic ptrdiff_t atomic_ptrdiff_t;

/* Initialization (7.17.2). ATOMIC_VAR_INIT is the initializer for a static or
 * automatic atomic object and atomic_init the run-time equivalent; neither is
 * an atomic operation, so a plain store is the whole of it. */
#define ATOMIC_VAR_INIT(value) (value)
#define atomic_init(object, value) ((void)(*(object) = (value)))

/* kill_dependency (7.17.3.1): rubycc tracks no consume-order dependency chain
 * (every operation is lowered at sequential consistency), so breaking one is
 * the identity. */
#define kill_dependency(y) (y)

/* Fences (7.17.4). atomic_signal_fence only has to order against a signal
 * handler on the same thread, which a full thread fence does as well, so both
 * spellings emit the target's fence instruction. */
#define atomic_thread_fence(order) __atomic_thread_fence(order)
#define atomic_signal_fence(order) __atomic_thread_fence(order)

/* The generic operations (7.17.7). Each is a macro over the corresponding
 * builtin, so it takes the object's type from its pointer argument the way
 * C11's type-generic functions do. The non-_explicit spellings are the
 * memory_order_seq_cst cases, which is what rubycc lowers every order to
 * anyway. */
#define atomic_store_explicit(object, desired, order) \
  __atomic_store_n((object), (desired), (order))
#define atomic_store(object, desired) \
  __atomic_store_n((object), (desired), __ATOMIC_SEQ_CST)

#define atomic_load_explicit(object, order) __atomic_load_n((object), (order))
#define atomic_load(object) __atomic_load_n((object), __ATOMIC_SEQ_CST)

#define atomic_exchange_explicit(object, desired, order) \
  __atomic_exchange_n((object), (desired), (order))
#define atomic_exchange(object, desired) \
  __atomic_exchange_n((object), (desired), __ATOMIC_SEQ_CST)

/* The `weak` flag is the only thing separating the strong and weak forms; a
 * strong compare-exchange never fails spuriously, so it satisfies the weak
 * contract too and rubycc lowers both alike. The flag is still passed as
 * written, so the two spellings stay distinguishable at the call site. */
#define atomic_compare_exchange_strong_explicit(object, expected, desired, success, failure) \
  __atomic_compare_exchange_n((object), (expected), (desired), 0, (success), (failure))
#define atomic_compare_exchange_strong(object, expected, desired) \
  __atomic_compare_exchange_n((object), (expected), (desired), 0, \
                              __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)

#define atomic_compare_exchange_weak_explicit(object, expected, desired, success, failure) \
  __atomic_compare_exchange_n((object), (expected), (desired), 1, (success), (failure))
#define atomic_compare_exchange_weak(object, expected, desired) \
  __atomic_compare_exchange_n((object), (expected), (desired), 1, \
                              __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)

#define atomic_fetch_add_explicit(object, operand, order) \
  __atomic_fetch_add((object), (operand), (order))
#define atomic_fetch_add(object, operand) \
  __atomic_fetch_add((object), (operand), __ATOMIC_SEQ_CST)

#define atomic_fetch_sub_explicit(object, operand, order) \
  __atomic_fetch_sub((object), (operand), (order))
#define atomic_fetch_sub(object, operand) \
  __atomic_fetch_sub((object), (operand), __ATOMIC_SEQ_CST)

#endif
