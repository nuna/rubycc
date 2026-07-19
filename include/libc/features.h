/* rubycc bundled <features.h>: the feature-test-macro reduction glibc's headers
   consume. Clean room against the published POSIX/glibc feature-test protocol
   (musl's own <features.h> was the shape reference; the __USE_* result set and
   the glibc version macros are the glibc ABI, measured on the reference
   platform). It maps the caller's request macros (_GNU_SOURCE, _POSIX_C_SOURCE,
   _DEFAULT_SOURCE, __STRICT_ANSI__, ...) onto the __USE_* macros glibc headers
   branch on. Common layer: the mapping is libc-defined, not arch-specific. */

#ifndef _RUBYCC_FEATURES_H
#define _RUBYCC_FEATURES_H

/* glibc's guard, so a host <features.h> reached later is a no-op. */
#ifndef _FEATURES_H
#define _FEATURES_H 1

/* _GNU_SOURCE turns on every feature set. */
#if defined _GNU_SOURCE
# undef  _ISOC95_SOURCE
# define _ISOC95_SOURCE 1
# undef  _ISOC99_SOURCE
# define _ISOC99_SOURCE 1
# undef  _ISOC11_SOURCE
# define _ISOC11_SOURCE 1
# undef  _POSIX_SOURCE
# define _POSIX_SOURCE 1
# undef  _POSIX_C_SOURCE
# define _POSIX_C_SOURCE 200809L
# undef  _XOPEN_SOURCE
# define _XOPEN_SOURCE 700
# undef  _XOPEN_SOURCE_EXTENDED
# define _XOPEN_SOURCE_EXTENDED 1
# undef  _LARGEFILE64_SOURCE
# define _LARGEFILE64_SOURCE 1
# undef  _DEFAULT_SOURCE
# define _DEFAULT_SOURCE 1
# undef  _ATFILE_SOURCE
# define _ATFILE_SOURCE 1
#endif

/* With nothing requested and not in strict-ANSI mode, glibc turns on its default
   (BSD/SVID/POSIX) surface. */
#if (!defined __STRICT_ANSI__ \
     && !defined _ISOC99_SOURCE && !defined _ISOC11_SOURCE \
     && !defined _POSIX_SOURCE && !defined _POSIX_C_SOURCE \
     && !defined _XOPEN_SOURCE && !defined _DEFAULT_SOURCE)
# define _DEFAULT_SOURCE 1
#endif

/* _DEFAULT_SOURCE implies POSIX.1-2008 plus the misc/BSD extensions. POSIX is
   only turned on *implicitly* here when the caller did not request it; that
   distinction is exactly what __USE_POSIX_IMPLICITLY records (so _GNU_SOURCE,
   which sets POSIX explicitly above, does not get it). */
#ifdef _DEFAULT_SOURCE
# if !defined _POSIX_SOURCE && !defined _POSIX_C_SOURCE
#  define __USE_POSIX_IMPLICITLY 1
#  define _POSIX_SOURCE 1
#  define _POSIX_C_SOURCE 200809L
# endif
# ifndef _ATFILE_SOURCE
#  define _ATFILE_SOURCE 1
# endif
#endif

/* ISO C selections. */
#if defined _ISOC11_SOURCE || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 201112L)
# define __USE_ISOC11 1
#endif
#if defined _ISOC99_SOURCE || defined _ISOC11_SOURCE \
    || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 199901L)
# define __USE_ISOC99 1
#endif
#if defined _ISOC95_SOURCE || defined _ISOC99_SOURCE || defined _ISOC11_SOURCE \
    || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 199409L)
# define __USE_ISOC95 1
#endif

/* POSIX selections, keyed off _POSIX_C_SOURCE's level. */
#ifdef _POSIX_SOURCE
# define __USE_POSIX 1
#endif
#if defined _POSIX_C_SOURCE && _POSIX_C_SOURCE >= 2
# define __USE_POSIX2 1
#endif
#if defined _POSIX_C_SOURCE && _POSIX_C_SOURCE >= 199309L
# define __USE_POSIX199309 1
#endif
#if defined _POSIX_C_SOURCE && _POSIX_C_SOURCE >= 199506L
# define __USE_POSIX199506 1
#endif
#if defined _POSIX_C_SOURCE && _POSIX_C_SOURCE >= 200112L
# define __USE_XOPEN2K 1
# undef  __USE_ISOC95
# define __USE_ISOC95 1
# undef  __USE_ISOC99
# define __USE_ISOC99 1
#endif
#if defined _POSIX_C_SOURCE && _POSIX_C_SOURCE >= 200809L
# define __USE_XOPEN2K8 1
# ifdef _ATFILE_SOURCE
#  define __USE_ATFILE 1
# endif
#endif

/* X/Open selections. */
#ifdef _XOPEN_SOURCE
# define __USE_XOPEN 1
# if _XOPEN_SOURCE >= 500
#  define __USE_XOPEN_EXTENDED 1
#  define __USE_UNIX98 1
#  undef _LARGEFILE_SOURCE
#  define _LARGEFILE_SOURCE 1
#  if _XOPEN_SOURCE >= 600
#   if _XOPEN_SOURCE >= 700
#    define __USE_XOPEN2K8 1
#    define __USE_XOPEN2K8XSI 1
#   endif
#   define __USE_XOPEN2K 1
#   define __USE_XOPEN2KXSI 1
#   undef __USE_ISOC95
#   define __USE_ISOC95 1
#   undef __USE_ISOC99
#   define __USE_ISOC99 1
#  endif
# else
#  ifdef _XOPEN_SOURCE_EXTENDED
#   define __USE_XOPEN_EXTENDED 1
#  endif
# endif
#endif

#ifdef _LARGEFILE_SOURCE
# define __USE_LARGEFILE 1
#endif
#ifdef _LARGEFILE64_SOURCE
# define __USE_LARGEFILE64 1
#endif
#if defined _FILE_OFFSET_BITS && _FILE_OFFSET_BITS == 64
# define __USE_FILE_OFFSET64 1
#endif

#ifdef _DEFAULT_SOURCE
# define __USE_MISC 1
#endif

#ifdef _ATFILE_SOURCE
# define __USE_ATFILE 1
#endif

#ifdef _GNU_SOURCE
# define __USE_GNU 1
# define __USE_DYNAMIC_STACK_SIZE 1
#endif

/* No fortification by default. */
#ifndef __USE_FORTIFY_LEVEL
# define __USE_FORTIFY_LEVEL 0
#endif

/* rubycc presents the glibc x86-64 ABI; report the reference platform's version
   so version-gated header code takes the same branch it does under glibc. */
#define __GNU_LIBRARY__ 6
#define __GLIBC__       2
#define __GLIBC_MINOR__ 39
#define __GLIBC_PREREQ(maj, min) \
  ((__GLIBC__ << 16) + __GLIBC_MINOR__ >= ((maj) << 16) + (min))

#define __GLIBC_USE(F) __GLIBC_USE_ ## F
#define __GLIBC_USE_DEPRECATED_GETS 0
#define __GLIBC_USE_DEPRECATED_SCANF 0
#define __GLIBC_USE_C2X_STRTOL 0
#define __GLIBC_USE_ISOC2X 0
#define __GLIBC_USE_LIB_EXT2 0
#define __GLIBC_USE_IEC_60559_BFP_EXT 0
#define __GLIBC_USE_IEC_60559_BFP_EXT_C2X 0
#define __GLIBC_USE_IEC_60559_EXT 0
#define __GLIBC_USE_IEC_60559_FUNCS_EXT 0
#define __GLIBC_USE_IEC_60559_FUNCS_EXT_C2X 0
#define __GLIBC_USE_IEC_60559_TYPES_EXT 0

/* rubycc ships its own <stdc-predef.h>-level knowledge; glibc's headers expect
   __KERNEL_STRICT_NAMES cleared so the kernel-UAPI compatibility names appear. */
#undef  __KERNEL_STRICT_NAMES

/* The compiler-abstraction macros live here, exactly as glibc's <features.h>
   pulls in <sys/cdefs.h>. */
#include <sys/cdefs.h>

#endif /* !_FEATURES_H */
#endif /* _RUBYCC_FEATURES_H */
