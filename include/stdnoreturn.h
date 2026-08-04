/* rubycc freestanding <stdnoreturn.h>: the _Noreturn convenience macro
   (ISO C 7.23).

   This header used to expand `noreturn` to nothing, because rubycc did not
   accept the _Noreturn function specifier and dropping an optimization hint
   changes no observable behavior. That workaround only ever covered code that
   reached the specifier through this header: musl's own <stdlib.h> writes the
   bare keyword (`_Noreturn void abort (void);`), so on a musl host rubycc
   stopped there and ruby.h did not preprocess at all -- measured in CI, see
   docs/STEPS.md Step 181. rubycc accepts the specifier itself as of Step 182,
   so the macro is now the plain C11 definition. */

#ifndef _RUBYCC_STDNORETURN_H
#define _RUBYCC_STDNORETURN_H

#define noreturn _Noreturn

#endif
