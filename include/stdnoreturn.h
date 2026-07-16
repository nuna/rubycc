/* rubycc freestanding <stdnoreturn.h>: the _Noreturn convenience macro
   (ISO C 7.23). rubycc does not accept the _Noreturn function specifier yet,
   so the macro expands to nothing; the specifier is only an optimization hint,
   so dropping it changes no observable behavior. */

#ifndef _RUBYCC_STDNORETURN_H
#define _RUBYCC_STDNORETURN_H

#define noreturn

#endif
