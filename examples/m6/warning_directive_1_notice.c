/* warning-directive-1: "#warning", and the diagnostic channel it needed.
 *
 * "#warning" (C23 6.10.2p2, and a GNU extension for decades before that) is
 * the one directive whose whole job is to report something and then let the
 * translation unit continue. Until this step rubycc could not do the second
 * half: every diagnostic it had was a raised error, so the portability shape
 * this sample imitates -- a header announcing that it does not recognize the
 * compiler, and falling back to a conservative choice -- ended the build.
 *
 * So the sample's job is to be a program whose *build* is the interesting
 * part: compiling it prints warnings to standard error under gcc and under
 * rubycc alike, and both still exit 0 and produce an object. What it prints at
 * run time is the fallback the "unrecognized" branch selected, so
 * test_examples.rb's [exit status, stdout] comparison covers the branch a
 * warned-about build actually took.
 *
 * Covered here: an unconditional warning; the quoted and unquoted spellings
 * (quoting is not required -- the message is the rest of the line either way);
 * a warning inside a skipped conditional group, which is silent because a
 * dropped group's directives are not acted on; and a warning reached through
 * the #else of a live conditional.
 */
#include <stdio.h>

#warning "this translation unit is built from a sample, not from real code"
#warning unquoted messages are accepted too

#if 0
#warning a warning in a skipped group is never reported
#endif

/* The portability shape itself: an unknown compiler is announced rather than
 * assumed away, and the code carries on with the conservative width. Neither
 * gcc nor rubycc defines __SAMPLE_KNOWN_COMPILER__, so the #else is the branch
 * both take and both warn from. */
#if defined(__SAMPLE_KNOWN_COMPILER__)
#define SCRATCH_ALIGNMENT 16
#else
#warning "Warning. Unrecognized compiler."
#define SCRATCH_ALIGNMENT 8
#endif

static int round_up(int value, int alignment)
{
    return (value + alignment - 1) / alignment * alignment;
}

int main(void)
{
    printf("alignment=%d\n", SCRATCH_ALIGNMENT);
    printf("round_up(1)=%d\n", round_up(1, SCRATCH_ALIGNMENT));
    printf("round_up(8)=%d\n", round_up(8, SCRATCH_ALIGNMENT));
    printf("round_up(9)=%d\n", round_up(9, SCRATCH_ALIGNMENT));
    return 0;
}
