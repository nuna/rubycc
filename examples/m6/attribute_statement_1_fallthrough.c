/*
 * Step attribute-statement-1: a GNU attribute-specifier sequence written as
 * its own statement -- "__attribute__((fallthrough));" -- rather than in
 * front of a declaration.
 *
 * rubycc's parser used to treat any statement-leading "__attribute__" as the
 * start of a declaration (the same position "__attribute__((unused)) int
 * x;" uses), so it went looking for a type specifier after the attribute and
 * failed with "expected type specifier" once it hit the following ";"
 * instead. gcc accepts this: an attribute-specifier sequence directly in
 * front of a statement's terminating ";" is its own "empty declaration"
 * (gcc's own diagnostic wording for an unrecognized one), carried for the
 * attribute's sake alone.
 *
 * Per DESIGN R7, only 'aligned' and 'packed' carry any layout semantics
 * anywhere this parser reads a GNU attribute; every other attribute --
 * 'fallthrough' included -- is accepted syntactically and discarded. rubycc
 * gives 'fallthrough' no fallthrough-placement checking (it has no
 * -Wimplicit-fallthrough-style lint to feed), so unlike gcc it does not
 * diagnose the attribute appearing somewhere other than immediately before a
 * "case"/"default" -- see docs/development/STEPS.md, attribute-statement-1.
 *
 * The real-world shape this closes is liquid-c 4.2.0's
 * ext/liquid_c/parser.c:242, which writes exactly
 * "__attribute__ ((fallthrough));" to silence -Wimplicit-fallthrough.
 *
 * A plain declaration-leading attribute ("__attribute__((unused)) int y")
 * is also exercised here, unchanged by this fix, so the two forms stay
 * told apart.
 */

#include <stdio.h>

static int classify(int x)
{
    switch (x) {
    case 1:
        x += 1;
        __attribute__((fallthrough));
    case 2:
        return x;
    case 3:
        x = 30;
        /* An attribute statement with no fallthrough semantics attached to
         * it (an unrecognized name): still just accepted and discarded. */
        __attribute__((totally_unknown_to_rubycc));
        return x;
    default:
        return -1;
    }
}

int main(void)
{
    /* A declaration-leading attribute, still routed to #parse_declaration
     * because a type specifier follows the attribute sequence. */
    __attribute__((unused)) int y = 5;

    int a = classify(1); /* falls through case 1 -> case 2: returns 2 */
    int b = classify(2); /* returns 2 directly */
    int c = classify(3); /* returns 30 */
    int d = classify(9); /* returns -1 (default) */

    printf("%d %d %d %d\n", a, b, c, d);

    return a + b + c + d + y;
}
