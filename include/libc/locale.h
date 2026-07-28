/* rubycc bundled <locale.h>: localization (ISO C11 7.11). Provenance: clean
   room against the POSIX/C11 public interface -- struct lconv's member names,
   types and order are the standard's own public contract (C11 7.11.1.1 fixes
   the sequence "the following members ... in the order shown"), not glibc
   implementation detail, so reproducing them is not a glibc derivation. Unlike
   the opaque-blob types elsewhere in this tree (pthread_t, jmp_buf), every
   member of struct lconv is used directly by callers, so it cannot be an
   opaque byte blob; instead its size and every member's offset were measured
   and confirmed against the glibc oracle (see test/test_header_abi.rb's LOCALE
   case). The LC_* category numbers are glibc runtime ABI (setlocale is
   answered by the host libc, so the numbers must match the host's own
   enumeration, the same reasoning as unistd.h's _SC_* constants) and were
   measured rather than invented. setlocale/localeconv are POSIX/ISO C
   declarations whose bodies resolve from the host libc at link time.
   Common layer: measured on both x86-64 and aarch64 glibc (both LP64), and
   struct lconv's size (96) and every member offset agreed exactly across the
   two arches (an all-pointer-and-char struct has no arch-dependent field
   widths on either LP64 target), so this header is arch-neutral, unlike
   pthread.h/setjmp.h/sys/stat.h.
   Not included: glibc's locale_t / newlocale / uselocale / freelocale /
   duplocale extensions. No corpus sample census hit needs them, so they are
   left out to keep the surface to what is actually used (bigdecimal's use of
   struct lconv via localeconv). */

#ifndef _RUBYCC_LOCALE_H
#define _RUBYCC_LOCALE_H

#ifndef NULL
#define NULL ((void*)0)
#endif

/* setlocale's category argument. Measured against glibc (matches the host's
   own __LC_* enumeration, since setlocale resolves from the host libc). */
#define LC_CTYPE          0
#define LC_NUMERIC        1
#define LC_TIME           2
#define LC_COLLATE        3
#define LC_MONETARY       4
#define LC_MESSAGES       5
#define LC_ALL            6
#define LC_PAPER          7
#define LC_NAME           8
#define LC_ADDRESS        9
#define LC_TELEPHONE      10
#define LC_MEASUREMENT    11
#define LC_IDENTIFICATION 12

/* The numeric/monetary formatting conventions localeconv() reports. Member
   names, types and order are the C11 7.11.1.1 public contract; every offset
   below was measured against the glibc oracle on both x86-64 and aarch64 and
   the two agreed byte for byte. */
struct lconv {
  char *decimal_point;
  char *thousands_sep;
  char *grouping;

  char *int_curr_symbol;
  char *currency_symbol;
  char *mon_decimal_point;
  char *mon_thousands_sep;
  char *mon_grouping;
  char *positive_sign;
  char *negative_sign;
  char int_frac_digits;
  char frac_digits;
  char p_cs_precedes;
  char p_sep_by_space;
  char n_cs_precedes;
  char n_sep_by_space;
  char p_sign_posn;
  char n_sign_posn;
  char int_p_cs_precedes;
  char int_p_sep_by_space;
  char int_n_cs_precedes;
  char int_n_sep_by_space;
  char int_p_sign_posn;
  char int_n_sign_posn;
};

char *setlocale(int __category, const char *__locale);
struct lconv *localeconv(void);

#endif /* _RUBYCC_LOCALE_H */
