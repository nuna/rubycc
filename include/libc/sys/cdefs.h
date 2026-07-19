/* rubycc bundled <sys/cdefs.h>: the glibc compiler-abstraction macros
   (__BEGIN_DECLS, __THROW, __attribute_* and kin) that glibc's own headers lean
   on. Written clean room against glibc's published macro contract rather than
   derived from musl (which has no equivalent) or copied from glibc: the bodies
   reproduce the observable behaviour (a name that expands to a usable attribute
   or to nothing), not glibc's source. Common layer: the definitions are the same
   for any x86-64 target. */

#ifndef _RUBYCC_SYS_CDEFS_H
#define _RUBYCC_SYS_CDEFS_H

/* glibc's own guard, so a later real <sys/cdefs.h> (reached via the host path in
   the non-distroless configuration) becomes a no-op and does not redefine. */
#ifndef _SYS_CDEFS_H
#define _SYS_CDEFS_H 1

#ifdef __cplusplus
# define __BEGIN_DECLS extern "C" {
# define __END_DECLS   }
#else
# define __BEGIN_DECLS
# define __END_DECLS
#endif

/* Token-pasting and stringizing helpers. */
#define __CONCAT(x, y) x ## y
#define __STRING(x)    #x

/* Pre-standard spellings still used by a few headers. */
#define __P(args)      args
#define __PMT(args)    args
#define __ptr_t        void *

/* GCC version predicate. rubycc identifies as a recent GCC-compatible compiler,
   so headers gate their newest spellings on this. */
#if defined __GNUC__ && defined __GNUC_MINOR__
# define __GNUC_PREREQ(maj, min) \
    ((__GNUC__ << 16) + __GNUC_MINOR__ >= ((maj) << 16) + (min))
#else
# define __GNUC_PREREQ(maj, min) 0
#endif

#ifndef __glibc_clang_prereq
# define __glibc_clang_prereq(maj, min) 0
#endif

/* Function-annotation macros. They carry no ABI meaning, so expanding them to
   nothing (or, for the wrappers, to their argument) is behaviourally faithful
   while keeping the token stream simple. */
#define __THROW
#define __THROWNL
#define __NTH(fct)   fct
#define __NTHNL(fct) fct

#define __attribute_malloc__
#define __attribute_pure__
#define __attribute_const__
#define __attribute_used__
#define __attribute_unused__
#define __attribute_noinline__
#define __attribute_deprecated__
#define __attribute_deprecated_msg__(msg)
#define __attribute_warn_unused_result__
#define __attribute_alloc_size__(params)
#define __attribute_alloc_align__(param)
#define __attribute_nonstring__
#define __attribute_maybe_unused__
#define __attribute_returns_twice__
#define __attribute_format_arg__(x)
#define __attribute_format_strfmon__(a, b)
#define __wur
#define __result_use_check
#define __COLD

#define __nonnull(params)
#define __always_inline    __inline
#define __extern_inline    extern __inline
#define __extern_always_inline extern __inline
#define __fortify_function __extern_always_inline __attribute_artificial__
#define __attribute_artificial__

/* restrict/inline keyword spellings for pre-C99 fallbacks. */
#ifndef __restrict
# define __restrict restrict
#endif
#define __restrict_arr

/* Branch-prediction hints: identities without the underlying builtin. */
#define __glibc_likely(cond)   (cond)
#define __glibc_unlikely(cond) (cond)
#define __glibc_unsigned_or_positive(v) 1

/* Flexible array members: C99 spelling is available. */
#define __flexarr [ ]
#define __glibc_c99_flexarr_available 1
#define __glibc_flexarr_length(arr)   1

/* Symbol-redirection and asm-name helpers: the plain (unredirected) form is what
   a bundled libc offers, so these degrade to a straight declaration. */
#define __ASMNAME(cname)  cname
#define __ASMNAME2(prefix, cname) cname
#define __REDIRECT(name, proto, alias)     name proto
#define __REDIRECT_NTH(name, proto, alias) name proto
#define __REDIRECT_NTHNL(name, proto, alias) name proto
#define __LDBL_REDIR(name, proto)     name proto
#define __LDBL_REDIR_NTH(name, proto) name proto
#define __LDBL_REDIR1(name, proto, alias) name proto
#define __LDBL_REDIR1_NTH(name, proto, alias) name proto
#define __LDBL_REDIR_DECL(name)

/* Variadic-macro argument pack forwarding (GCC builtins). */
#define __va_arg_pack()       __builtin_va_arg_pack()
#define __va_arg_pack_len()   __builtin_va_arg_pack_len()

/* Bounds/fortify plumbing: no fortification, no BOS instrumentation. */
#define __bos(ptr)  __builtin_object_size(ptr, __USE_FORTIFY_LEVEL > 1)
#define __bos0(ptr) __builtin_object_size(ptr, 0)
#define __glibc_objsize(obj)  __bos(obj)
#define __glibc_objsize0(obj) __bos0(obj)

/* Wide-character / locale plumbing spellings some headers reference. */
#define __LEAF
#define __LEAF_ATTR

#endif /* !_SYS_CDEFS_H */
#endif /* _RUBYCC_SYS_CDEFS_H */
