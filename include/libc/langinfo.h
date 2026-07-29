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

   Not included: nl_langinfo_l (its locale_t parameter is part of the glibc
   locale extension set the bundled <locale.h> deliberately leaves out), and
   glibc's _NL_* internal item names beyond the three composition helpers.
   nkf, the gem that put this header on the list, reaches nl_langinfo with the
   POSIX item set. */

#ifndef _RUBYCC_LANGINFO_H
#define _RUBYCC_LANGINFO_H

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
