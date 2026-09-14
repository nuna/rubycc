/*
 * Step predefined-identifier-func-1: the predefined identifier __func__
 * (ISO C99 6.4.2.2) and its GNU synonyms __FUNCTION__ and
 * __PRETTY_FUNCTION__.
 *
 * gcc behaves as if
 *     static const char __func__[] = "<enclosing-function-name>";
 * were declared right after the enclosing function's opening brace: a
 * const char array, usable from a nested block, that decays to a pointer
 * and whose address is stable within one function. In C mode (unlike C++)
 * gcc's __PRETTY_FUNCTION__ is a plain synonym for __func__ -- no
 * decorated signature -- so all three names give the same string here.
 * Measured 2026-09-14 with gcc 13.3; see docs/development/STEPS.md,
 * predefined-identifier-func-1.
 *
 * rubycc fabricates it as an ordinary string literal at parse time (the
 * literal's bytes are the enclosing function's name), which is why sizeof,
 * pointer decay and "&__func__" all work with no dedicated IR support: they
 * are the same paths any other string literal already takes.
 *
 * The real case this closes: trilogy 2.13.0 links OpenSSL 3, whose
 * <openssl/err.h> OPENSSL_FUNC macro (used by ERR_put_error callers
 * throughout libcrypto's headers) expands to __func__.
 */

#include <stdio.h>
#include <string.h>

static int add(int a, int b)
{
    /* Reflects *this* function's name, not main's. */
    printf("inner: %s\n", __func__);
    return a + b;
}

int main(void)
{
    /* The standard name and its two GNU synonyms all agree in C mode. */
    printf("%s %s %s\n", __func__, __FUNCTION__, __PRETTY_FUNCTION__);

    /* sizeof counts the name's bytes plus the terminating NUL. */
    printf("%zu\n", sizeof(__func__));

    /* Usable inside a nested block, still naming the enclosing function. */
    if (1) {
        printf("nested: %s\n", __func__);
    }

    /* One object per function: two references share the same address, both
     * as a plain read and through "&". */
    const char *a = __func__;
    const char *b = __func__;
    const char *pa = (const char *)&__func__;
    const char *pb = (const char *)&__func__;

    int sum = add(3, 4);

    return (a == b) && (pa == pb) && strcmp(a, "main") == 0 && sum == 7 ? 0 : 1;
}
