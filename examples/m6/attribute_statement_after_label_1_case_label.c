/*
 * Step attribute-statement-after-label-1: an attribute-only statement
 * ("__attribute__((fallthrough));", gcc's spelling of a fallthrough marker)
 * placed directly after a label, rather than after another statement inside
 * a block.
 *
 * Step attribute-statement-1 taught #parse_block_item this shape
 * ("__attribute__((fallthrough)); case 2: ...") but the statement right
 * after a label ("case"/"default"/a plain identifier label) is read through
 * #parse_nested_statement -> #parse_statement, a path that bypasses
 * #parse_block_item entirely -- so the very first statement of a "case"
 * body still failed with "expected expression" (measured 2026-09-13, gcc
 * 13.3, with attribute-statement-1 already applied). #parse_statement now
 * shares the same parse (#parse_attribute_only_statement) with
 * #parse_block_item, so this works uniformly right after any label.
 */

#include <stdio.h>

static int classify(int x)
{
    switch (x) {
    case 1:
        /* The attribute is the *first* thing after "case 1:" -- no other
         * statement precedes it, which is exactly the shape
         * attribute-statement-1 did not reach. */
        __attribute__((fallthrough));
    case 2:
        return x + 10;
    default:
        /* Same shape right after "default:" instead of "case N:". */
        __attribute__((fallthrough));
    case 9:
        return x + 100;
    }
}

static int loop_with_label(int x)
{
    int steps = 0;
loop:
    /* Same shape right after a plain (goto-target) label, exercising
     * #parse_labeled_statement's call into #parse_nested_statement. */
    __attribute__((fallthrough));
    steps += 1;
    x -= 1;
    if (x > 0) {
        goto loop;
    }
    return steps;
}

int main(void)
{
    int a = classify(1); /* falls through case 1 -> case 2: 1 + 10 = 11 */
    int b = classify(2); /* returns 2 + 10 = 12 directly */
    int c = classify(3); /* falls through default -> case 9: 3 + 100 = 103 */
    int d = loop_with_label(4); /* 4 iterations */

    printf("%d %d %d %d\n", a, b, c, d);

    return a + b + c + d;
}
