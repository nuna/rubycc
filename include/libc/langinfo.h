/* rubycc bundled <langinfo.h>: locale-dependent string lookup (POSIX.1).
   Provenance: clean room against the POSIX public interface and the glibc
   runtime ABI, not derived from musl or glibc source. nl_langinfo is answered
   by the host libc, so the nl_item numbers must match the host's own
   enumeration exactly -- the same reasoning <locale.h>'s LC_* values and
   <unistd.h>'s _SC_* values rest on -- and every value below was therefore
   printed from the glibc oracle rather than guessed.

   The numbering is not a flat sequence: an nl_item packs the locale category
   in the upper 16 bits and an index within that category in the lower 16, so
   e.g. D_T_FMT measures 0x20028 = category 2 (LC_TIME) index 40. That
   composition was itself measured, not assumed: a probe compared rubycc's
   own _NL_ITEM/_NL_ITEM_CATEGORY/_NL_ITEM_INDEX formulas against the glibc
   oracle's over every (category, index) pair in range and found them equal,
   and the category numbers the items carry match the LC_* values the bundled
   <locale.h> already reproduces. The constants below are still written out as
   their measured composed values so this header does not depend on
   <locale.h> being included.

   Common layer: every nl_item value measured identical on x86-64 and on
   aarch64 (cross gcc + qemu), and nl_item is `int` (4 bytes) on both, so the
   header is arch-neutral.

   Coverage against glibc's <langinfo.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, both arches, with tools/audit_bundled_headers.rb; table in
   docs/development/BUNDLED-HEADERS-COVERAGE.md). Nothing was added: the POSIX
   item set is complete above, and everything glibc has beyond it is a GNU item
   or an internal name. nkf, the gem that put this header on the list, reaches
   nl_langinfo with the POSIX set. Each item is a number this host's libc
   answers to, so -- as with <unistd.h>'s _SC_* -- they are added one consumer
   at a time rather than transcribed in bulk. Intentionally left out:
   omitted: _NL_* -- glibc's internal item names (the per-category tables it
   builds locales out of), beyond the three composition helpers above.
   omitted: ALTMON_1 ALTMON_2 ALTMON_3 ALTMON_4 ALTMON_5 ALTMON_6 ALTMON_7
   ALTMON_8 ALTMON_9 ALTMON_10 ALTMON_11 ALTMON_12 ERA_YEAR NL_LOCALE_NAME
   _DATE_FMT -- GNU items (glibc 2.27 and later for the ALTMON_ family), no
   corpus user. omitted: INT_CURR_SYMBOL CURRENCY_SYMBOL MON_DECIMAL_POINT
   MON_THOUSANDS_SEP MON_GROUPING POSITIVE_SIGN NEGATIVE_SIGN INT_FRAC_DIGITS
   FRAC_DIGITS P_CS_PRECEDES P_SEP_BY_SPACE N_CS_PRECEDES N_SEP_BY_SPACE
   P_SIGN_POSN N_SIGN_POSN INT_P_CS_PRECEDES INT_P_SEP_BY_SPACE
   INT_N_CS_PRECEDES INT_N_SEP_BY_SPACE INT_P_SIGN_POSN INT_N_SIGN_POSN
   GROUPING -- GNU items that ask nl_langinfo for what localeconv() already
   reports member by member through struct lconv, which the bundled <locale.h>
   provides. omitted: locale_t nl_langinfo_l -- the locale-object API the
   bundled <locale.h> leaves out. omitted: <nl_types.h> -- glibc reaches
   nl_item through it; rubycc bundles no such header and declares nl_item
   here. */

#ifndef _RUBYCC_LANGINFO_H
#define _RUBYCC_LANGINFO_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

/* The item selector. Measured: 4 bytes, 4-byte aligned, signed. glibc reaches
   for this typedef through <nl_types.h>; rubycc has no such header, so it is
   given here under its own guard. */
#ifndef _RUBYCC_NL_ITEM
#define _RUBYCC_NL_ITEM
typedef int nl_item;
#endif

/* The category/index composition, re-derived from the measured values (see
   the note above): category in bits 16.., index in bits 0..15. */
#define _NL_ITEM(category, index) (((category) << 16) | (index))
#define _NL_ITEM_CATEGORY(item)   ((item) >> 16)
#define _NL_ITEM_INDEX(item)      ((item) & 0xffff)

/* LC_CTYPE items (category 0). */
#define CODESET 14

/* LC_NUMERIC items (category 1). DECIMAL_POINT / THOUSANDS_SEP are glibc's
   alternate spellings of the same two items. */
#define RADIXCHAR     0x10000
#define THOUSEP       0x10001
#define DECIMAL_POINT 0x10000
#define THOUSANDS_SEP 0x10001

/* LC_TIME items (category 2), in the order glibc numbers them: the seven
   abbreviated day names, the seven full day names, the twelve abbreviated
   month names, the twelve full month names, then the format strings. */
#define ABDAY_1 0x20000
#define ABDAY_2 0x20001
#define ABDAY_3 0x20002
#define ABDAY_4 0x20003
#define ABDAY_5 0x20004
#define ABDAY_6 0x20005
#define ABDAY_7 0x20006

#define DAY_1 0x20007
#define DAY_2 0x20008
#define DAY_3 0x20009
#define DAY_4 0x2000a
#define DAY_5 0x2000b
#define DAY_6 0x2000c
#define DAY_7 0x2000d

#define ABMON_1  0x2000e
#define ABMON_2  0x2000f
#define ABMON_3  0x20010
#define ABMON_4  0x20011
#define ABMON_5  0x20012
#define ABMON_6  0x20013
#define ABMON_7  0x20014
#define ABMON_8  0x20015
#define ABMON_9  0x20016
#define ABMON_10 0x20017
#define ABMON_11 0x20018
#define ABMON_12 0x20019

#define MON_1  0x2001a
#define MON_2  0x2001b
#define MON_3  0x2001c
#define MON_4  0x2001d
#define MON_5  0x2001e
#define MON_6  0x2001f
#define MON_7  0x20020
#define MON_8  0x20021
#define MON_9  0x20022
#define MON_10 0x20023
#define MON_11 0x20024
#define MON_12 0x20025

#define AM_STR      0x20026
#define PM_STR      0x20027
#define D_T_FMT     0x20028
#define D_FMT       0x20029
#define T_FMT       0x2002a
#define T_FMT_AMPM  0x2002b
#define ERA         0x2002c
#define ERA_D_FMT   0x2002e
#define ALT_DIGITS  0x2002f
#define ERA_D_T_FMT 0x20030
#define ERA_T_FMT   0x20031

/* LC_MONETARY item (category 4). */
#define CRNCYSTR 0x4000f

/* LC_MESSAGES items (category 5). YESSTR / NOSTR are glibc legacy items kept
   for callers that still ask for them. */
#define YESEXPR 0x50000
#define NOEXPR  0x50001
#define YESSTR  0x50002
#define NOSTR   0x50003

char *nl_langinfo(nl_item __item);

#endif /* _RUBYCC_LANGINFO_H */
