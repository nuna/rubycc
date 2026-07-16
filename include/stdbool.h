/* rubycc freestanding <stdbool.h>: boolean macros (ISO C 7.18).
   rubycc targets C11, so bool/true/false are ordinary macros over _Bool. */

#ifndef _RUBYCC_STDBOOL_H
#define _RUBYCC_STDBOOL_H

#ifndef __cplusplus
#define bool _Bool
#define true 1
#define false 0
#endif

#define __bool_true_false_are_defined 1

#endif
