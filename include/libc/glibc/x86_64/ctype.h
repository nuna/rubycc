/* rubycc bundled <ctype.h>: character classification (ISO C 7.4). glibc does
   not return a bare 0/1 from isalpha() and kin -- it returns the masked bits of
   a per-locale classification table reached through __ctype_b_loc(), so the
   result values are part of its ABI. This header reproduces that mechanism clean
   room from the published _ISbit formula and accessor signatures (not copied
   from glibc, not derived from musl, whose ctype returns 0/1); the accessor
   functions themselves are resolved from the host libc at link time. The whole
   mechanism is glibc's, so under __RUBYCC_LIBC_MUSL__ (see the preprocessor's
   LIBCS) the classification macros are switched off and the plain function
   calls stand instead -- see the note above them. Placed in the glibc layer
   because that is where the arch-switched headers live; the values themselves
   are arch independent. */

#ifndef _RUBYCC_CTYPE_H
#define _RUBYCC_CTYPE_H

/* The classification bit for each property, as glibc lays them out in the table
   entry: properties 0-7 occupy the high byte, 8-11 the low byte. */
#ifndef _ISbit
# define _ISbit(bit) ((bit) < 8 ? ((1 << (bit)) << 8) : ((1 << (bit)) >> 8))
#endif

enum {
  _ISupper  = _ISbit(0),
  _ISlower  = _ISbit(1),
  _ISalpha  = _ISbit(2),
  _ISdigit  = _ISbit(3),
  _ISxdigit = _ISbit(4),
  _ISspace  = _ISbit(5),
  _ISprint  = _ISbit(6),
  _ISgraph  = _ISbit(7),
  _ISblank  = _ISbit(8),
  _IScntrl  = _ISbit(9),
  _ISpunct  = _ISbit(10),
  _ISalnum  = _ISbit(11)
};

extern const unsigned short int **__ctype_b_loc(void);
extern const int **__ctype_tolower_loc(void);
extern const int **__ctype_toupper_loc(void);

/* The out-of-line entry points (declared so code taking their address still
   links); the macros below inline the common case. */
extern int isalnum(int __c);
extern int isalpha(int __c);
extern int iscntrl(int __c);
extern int isdigit(int __c);
extern int islower(int __c);
extern int isgraph(int __c);
extern int isprint(int __c);
extern int ispunct(int __c);
extern int isspace(int __c);
extern int isupper(int __c);
extern int isxdigit(int __c);
extern int isblank(int __c);
extern int tolower(int __c);
extern int toupper(int __c);
extern int isascii(int __c);
extern int toascii(int __c);

/* The classification macros are glibc's mechanism and glibc's result values,
   so on musl they must not be used at all: the two libraries differ in the
   *shape* of the answer, not merely in a constant. glibc's isalpha('a') is the
   masked table entry (measured 1024, and 2048/8192/... for the other
   properties) while musl's is a bare 1; and musl has no __ctype_b_loc() /
   __ctype_tolower_loc() / __ctype_toupper_loc() to reach a table through in the
   first place, so a table-lookup macro would not even link there. Both
   behaviours measured with the ABI harness, glibc's on this host and musl's on
   the CI musl run (docs/STEPS.md Step 193). Under musl the macros are therefore
   left undefined and every classifier resolves to the out-of-line function
   declared above, which is what returns musl's 0/1. The accessor prototypes and
   the _IS* enumerators stay declared on both: a prototype that is never called
   emits nothing, and code that does call one is asking for glibc's own
   interface by name. */
#if !defined(__RUBYCC_LIBC_MUSL__)

#define __isctype(c, type) ((*__ctype_b_loc())[(int)(c)] & (unsigned short int)(type))

#define isalnum(c)  __isctype((c), _ISalnum)
#define isalpha(c)  __isctype((c), _ISalpha)
#define iscntrl(c)  __isctype((c), _IScntrl)
#define isdigit(c)  __isctype((c), _ISdigit)
#define islower(c)  __isctype((c), _ISlower)
#define isgraph(c)  __isctype((c), _ISgraph)
#define isprint(c)  __isctype((c), _ISprint)
#define ispunct(c)  __isctype((c), _ISpunct)
#define isspace(c)  __isctype((c), _ISspace)
#define isupper(c)  __isctype((c), _ISupper)
#define isxdigit(c) __isctype((c), _ISxdigit)
#define isblank(c)  __isctype((c), _ISblank)

#define tolower(c) ((int) (*__ctype_tolower_loc())[(int)(c)])
#define toupper(c) ((int) (*__ctype_toupper_loc())[(int)(c)])

#endif /* !__RUBYCC_LIBC_MUSL__ */

/* isascii/toascii: glibc declares these under __USE_MISC || __USE_XOPEN and
   defines them as pure bit tests (no locale classification table), so the
   inline value matches glibc's out-of-line result exactly -- no ABI subtlety
   like the isalpha() family above. Real sources (e.g. redcarpet's html.c) call
   isascii() with only <ctype.h> included. They stay macros under either C
   library: the probed values (isascii of 'a'/200/0/127, toascii of 0x1FF/'A')
   measured identical on glibc and musl (docs/STEPS.md Step 193), which is why
   they sit outside the branch above. */
#define isascii(c) (((c) & ~0x7f) == 0)
#define toascii(c) ((c) & 0x7f)

#endif /* _RUBYCC_CTYPE_H */
