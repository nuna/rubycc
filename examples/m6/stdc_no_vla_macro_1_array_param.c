/* stdc-no-vla-macro-1: __STDC_NO_VLA__ (C11 6.10.8.3).
 *
 * rubycc does not support variable-length arrays (ROADMAP §3 diagnoses one as
 * an error; DESIGN R7 calls the feature optional), so 6.10.8.3 requires it to
 * predefine __STDC_NO_VLA__ to the integer constant 1. Before this step it
 * did not, so a header could not tell "no #pragma-style diagnostic, but also
 * no VLA support" apart from "the feature exists" -- a portable header that
 * checked the macro would pick the VLA-shaped branch and rubycc would reject
 * it, even though the header meant to avoid exactly that.
 *
 * This is the shape that blocked the corpus candidate brotli 0.8.0: its
 * vendor/brotli/c/include/brotli/port.h:257-263 selects a VLA-shaped array
 * parameter ("(name)") only when !defined(__STDC_NO_VLA__), and an empty
 * "[]" (adjusted to a pointer, 6.7.6.3p7) otherwise. The macro is what makes
 * the header choose the branch rubycc actually supports.
 */
#include <stddef.h>
#include <stdio.h>

#if defined(__STDC_VERSION__) && (__STDC_VERSION__ >= 199901L) && \
    !defined(__STDC_NO_VLA__) && !defined(__cplusplus)
#define ARRAY_PARAM(name) (name)
#else
#define ARRAY_PARAM(name)
#endif

static int sum(size_t count, const int values[ARRAY_PARAM(count)]) {
    size_t i;
    int total = 0;
    for (i = 0; i < count; i++) {
        total += values[i];
    }
    return total;
}

int main(void) {
    int values[] = {1, 2, 3, 4, 5, 6};
    printf("%d\n", sum(sizeof(values) / sizeof(values[0]), values));
    return 0;
}
