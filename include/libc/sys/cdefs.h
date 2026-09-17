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

/* Static-analysis annotations: __attr_access describes which parameter is a
   buffer and how it is used, __attr_access_none says a parameter is not
   accessed at all, and __attr_dealloc (plus the fclose/free object-like
   spellings some headers apply directly) pairs an allocating function with
   the one that must free its result. rubycc performs no such analysis, so
   each expands to nothing, the same as the __attribute_* group above. */
#define __attr_access(params)
#define __attr_access_none(argno)
#define __attr_dealloc(dealloc, argno)
#define __attr_dealloc_fclose
#define __attr_dealloc_free

#define __nonnull(params)
#define __attribute_nonnull__(params)
#define __returns_nonnull
#define __attribute_copy__(arg)

/* Diagnostic-only spellings. glibc attaches a compile-time message to a name
   with these; rubycc emits no such diagnostic, so each expands to nothing --
   except __errordecl, which glibc also uses as the declaration itself, so it
   has to leave one behind. Names measured against glibc's <sys/cdefs.h> on
   2026-09-18 with `gcc -E -dM` (glibc-public-headers-mixed-1). */
#define __warnattr(msg)
#define __errordecl(name, msg) extern void name (void)
#define __glibc_macro_warning1(msg)
#define __glibc_macro_warning(msg)

/* Feature predicates glibc's headers ask before reaching for a compiler
   extension. rubycc answers the builtin and attribute ones honestly through
   its own #if operators; __has_extension is a clang spelling rubycc does not
   have, and 0 is the answer glibc itself gives without it. */
#define __glibc_has_builtin(name) __has_builtin (name)
#define __glibc_has_attribute(attr) __has_attribute (attr)
#define __glibc_has_extension(ext) 0

/* Fortification plumbing: __fortified_attr_access is the buffer-access
   annotation glibc puts on the unfortified declaration of a function that has
   a _FORTIFY_SOURCE variant (<sys/poll.h> puts it on poll, and without the
   spelling the declaration does not parse, measured 2026-09-18), and the
   __REDIRECT_FORTIFY pair is __REDIRECT under a different name. */
#define __fortified_attr_access(access, index, size)
#define __REDIRECT_FORTIFY(name, proto, alias)     name proto
#define __REDIRECT_FORTIFY_NTH(name, proto, alias) name proto

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
#define __LDBL_REDIR2_DECL(name)
#define __REDIRECT_LDBL(name, proto, alias)     name proto
#define __REDIRECT_NTH_LDBL(name, proto, alias) name proto

/* Variadic-macro argument pack forwarding (__builtin_va_arg_pack and kin).
   Deliberately *not* defined: rubycc has no such builtin, and every glibc
   header that reaches for the forwarding uses `defined __va_arg_pack' (or the
   _len spelling) as the feature test, so leaving the names absent selects the
   plain out-of-line declaration instead. Defining them made <error.h> read
   <bits/error.h>, whose __extern_always_inline body calls __va_arg_pack (),
   and the compile failed on the builtin (measured 2026-09-18,
   glibc-public-headers-mixed-1). The gated users are <error.h>, <fcntl.h>,
   <mqueue.h> and the bits/*2.h fortify files. */

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
