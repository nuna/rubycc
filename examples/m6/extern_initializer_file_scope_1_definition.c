/* extern-initializer-file-scope-1: a file-scope "extern T x = init;" is an
 * external *definition*, not a mere reference -- the initializer is what
 * makes it one (C11 6.9.2p1's own example: "extern int i3 = 3; // definition,
 * external linkage"). gcc accepts the combination with a warning; rubycc
 * formerly rejected it outright with "has both 'extern' and initializer".
 *
 * The real-world shape this closes is cool.io's bundled libev
 * (ext/libev/ev.c:1845): "EV_API_DECL struct ev_loop *ev_default_loop_ptr
 * = 0;" where EV_API_DECL (ev.h:203) expands to "extern" -- the upstream
 * comment there says outright that the initializer is what "needs to be
 * initialised to make it a definition despite extern".
 *
 * This sample is a single translation unit (the multi-TU linking case -- a
 * second unit seeing only "extern int x;" and reading the value the first
 * unit's "extern ... = ..." defined -- is covered by the gcc-differential
 * execution test in test/test_extern_initializer_file_scope.rb, not here,
 * since a single sample file cannot exercise cross-TU linking). What this
 * sample demonstrates within one file is that the declaration compiles and
 * behaves exactly as if "extern" were absent: a scalar, a struct, and a
 * pointer to a struct all definable this way, and all readable and
 * mutable like an ordinary global.
 *
 * At *block* scope the same combination stays a constraint violation
 * (6.7.9p5) -- unlike at file scope, a block cannot supply the storage
 * duration the initializer would fill. That is exercised as a compile-time
 * diagnostic test, not here (a sample under examples/ must build).
 */
int printf(const char *, ...);

extern int counter = 10;

struct point {
  int x;
  int y;
};

extern struct point origin = {0, 0};

/* The libev shape itself: a pointer to a struct, initialized to a null
 * pointer constant, declared "extern". */
extern struct point *current = 0;

int main(void) {
  counter += 5;
  origin.x += 3;
  origin.y += 4;
  current = &origin;

  printf("%d %d %d %d\n", counter, origin.x, origin.y, current == &origin);
  return counter + origin.x + origin.y;
}
