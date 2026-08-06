/* rubycc freestanding <stdalign.h>: alignment macros (ISO C 7.15).
   alignas and alignof map onto rubycc's _Alignas specifier and _Alignof
   operator, both of which the compiler implements. */

#ifndef _RUBYCC_STDALIGN_H
#define _RUBYCC_STDALIGN_H

#ifndef __cplusplus
#define alignas _Alignas
#define alignof _Alignof
#endif

#define __alignas_is_defined 1
#define __alignof_is_defined 1

#endif
