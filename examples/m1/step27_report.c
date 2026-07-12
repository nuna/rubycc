/* Step 27: function-like macros, the # and ## operators, __VA_ARGS__ and the
   predefined __FILE__ / __LINE__. Includes a "#pragma once" header twice (read
   only the first time), applies MAX / MIN, stringizes an expression with SHOW,
   pastes an identifier with COUNTER, and forwards a variable argument list to
   printf through LOG. Uses only features available through Step 27. */
#include "step27_logging.h"
#include "step27_logging.h"

int printf(const char *format, ...);

int main(void) {
    int hi = MAX(3, 9);
    int lo = MIN(3, 9);
    /* COUNTER(hits) pastes to "counter_hits", the name declared here. */
    int COUNTER(hits) = hi - lo;

    SHOW(hi);
    SHOW(MAX(lo, 7));
    LOG("%s:%d span=%d\n", __FILE__, __LINE__, counter_hits);
    printf("range=%d\n", hi - lo);

    return hi + lo + counter_hits;
}
