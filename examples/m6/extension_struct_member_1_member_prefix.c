/* extension-struct-member-1: a leading "__extension__" on a struct/union
 * member declaration (part of ISO C 6.7.2.1's struct-declaration-list).
 *
 * "__extension__" is a GNU marker that silences pedantic diagnostics; it has
 * no effect on the declaration it prefixes. rubycc already skipped a leading
 * run of these at the head of an external declaration and of a block-scope
 * declaration, but not at the head of a struct/union member declaration, so
 * "struct s { __extension__ unsigned long long int v; int w; };" was
 * rejected ("expected type specifier") even though gcc accepts it.
 *
 * glibc's bits/atomic_wide_counter.h (pulled in by <threads.h>) declares its
 * member exactly this way, so this was also what kept <threads.h> from
 * compiling under rubycc at all.
 */
#include <stddef.h>
#include <stdio.h>

struct pair {
    __extension__ unsigned long long int v;
    int w;
};

union either {
    __extension__ unsigned long long int v;
    int w;
};

struct wrapper {
    int pre;
    struct pair nested;
    int post;
};

int main(void) {
    printf("%zu %zu %zu\n", sizeof(struct pair), offsetof(struct pair, v), offsetof(struct pair, w));
    printf("%zu %zu %zu\n", sizeof(union either), offsetof(union either, v), offsetof(union either, w));
    printf("%zu %zu %zu\n", sizeof(struct wrapper), offsetof(struct wrapper, pre), offsetof(struct wrapper, nested));
    return 0;
}
