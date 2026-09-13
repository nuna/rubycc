/* unprototyped-function-pointer-compat-1: a prototyped function pointer
 * ("void (*)(int *, long)") assigned to an old-style unprototyped one
 * ("void (*)()"), and back again, per ISO C 6.7.6.3p15.
 *
 * A function type with a parameter-type list and one declared with an empty
 * identifier list that is not part of a function definition are compatible
 * types when the parameter list has no ellipsis and every parameter type is
 * unchanged by the default argument promotions (6.5.2.2p6). rubycc used to
 * reject this outright ("incompatible types in assignment"), even though gcc
 * accepts it with no warning at all.
 *
 * numo-narray 0.9.2.1's ext/numo/narray/ndloop.c declares its na_md_loop_t
 * struct member exactly this way ("void (*loop_func)();") and assigns a
 * fully prototyped function pointer to it, which is what this example
 * mirrors.
 */
#include <stdio.h>

struct dispatch_table {
    void (*handler)(); /* old-style: unspecified parameters */
};

static void increment_by(int *p, long n) { *p += (int)n; }

void register_handler(struct dispatch_table *t, void (*h)(int *, long)) {
    t->handler = h; /* prototyped -> unprototyped */
}

void call_through(void (*proto)(int *, long), int *p, long n) {
    proto(p, n); /* argument passing: unprototyped value, prototyped parameter */
}

int main(void) {
    struct dispatch_table t;
    int v = 0;

    register_handler(&t, increment_by);
    ((void (*)(int *, long))t.handler)(&v, 7);

    void (*proto)(int *, long) = t.handler; /* unprototyped -> prototyped */
    proto(&v, 3);

    call_through(t.handler, &v, 5);

    printf("%d\n", v);
    return 0;
}
