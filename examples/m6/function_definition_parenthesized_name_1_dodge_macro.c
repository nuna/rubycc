/*
 * Step function-definition-parenthesized-name-1: a function definition whose
 * declarator parenthesizes the function name, "int (add)(int a, int b)".
 *
 * "(add)(int a, int b)" is a parenthesized declarator ("(add)") followed by a
 * parameter list -- a function declarator per ISO C11 6.7.6p1 and 6.7.6.3 --
 * and is just as valid a function definition's declarator as the
 * unparenthesized "add(int a, int b)". 6.9.1p2 forbids only *inheriting* the
 * function type from a typedef name; it says nothing about parenthesizing the
 * declared name itself. Parenthesizing the name is the standard trick to dodge
 * a same-named function-like macro (the parentheses keep the macro from
 * matching, since a macro invocation needs the name immediately followed by
 * "("). Measured 2026-09-14 with gcc 13.3.
 *
 * Real case this closes: iodine 0.7.59's mustache_parser.h:1018 defines
 * "MUSTACHE_FUNC int(mustache_build)(mustache_build_args_s args) { ... }"
 * this way, guarding against a MUSTACHE_FUNC macro from elsewhere.
 */

/* A same-named function-like macro: without the parenthesized name below, its
 * own definition would try to expand itself. */
#define add(x, y) ((x) + (y) + 100)

int (add)(int a, int b)
{
    return a + b;
}

/* "static", a pointer return type, and doubled parentheses all still parse as
 * ordinary function declarators once the name itself is parenthesized. */
static int (f)(void)
{
    return 5;
}

int *(g)(void)
{
    static int value = 7;
    return &value;
}

int ((h))(int x)
{
    return x + 1;
}

/* Old-style (K&R) parameter list, with the name itself parenthesized. */
int (old_style_add)(a, b)
    int a;
    int b;
{
    return a + b;
}

int main(void)
{
    /* Calling through the macro exercises the macro's own expansion, not the
     * function -- "add(1, 2)" the macro gives 103, not 3. */
    int via_macro = add(1, 2);

    /* "(add)(1, 2)" parenthesizes the call's function designator so the
     * macro (which only matches "add" immediately followed by "(") does not
     * fire, reaching the real function instead. */
    int via_function = (add)(1, 2);

    int via_static = f();
    int via_pointer = *g();
    int via_double_paren = h(4);
    int via_old_style = old_style_add(5, 6);

    return via_macro == 103 && via_function == 3 && via_static == 5 &&
                   via_pointer == 7 && via_double_paren == 5 && via_old_style == 11
               ? 0
               : 1;
}
