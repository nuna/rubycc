/* rubycc freestanding <stdalign.h>: alignment macros (ISO C 7.15).
   alignof maps onto rubycc's _Alignof operator. rubycc does not accept the
   _Alignas specifier yet, but the macro is still provided for source that only
   references it behind a feature guard. */

#ifndef _RUBYCC_STDALIGN_H
#define _RUBYCC_STDALIGN_H

#ifndef __cplusplus
#define alignas _Alignas
#define alignof _Alignof
#endif

#define __alignas_is_defined 1
#define __alignof_is_defined 1

#endif
