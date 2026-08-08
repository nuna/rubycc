/*
 * Step atomic-type-11: the null pointer constant, widened to ISO C's actual
 * definition.
 *
 * 6.3.2.3p3: "An integer constant expression with the value 0, or such an
 * expression cast to type void *, is called a null pointer constant." The
 * first alternative is broader than a bare "0": 6.6p6 lets a cast to another
 * integer type appear inside an integer constant expression, so the *whole*
 * cast "(unsigned long)0" is itself an integer constant expression whose
 * value is 0 -- not merely a cast of one. It stays a null pointer constant
 * whether the destination is void * or some other integer type entirely, as
 * long as the value folds to 0: an enum constant of value 0, or an arithmetic
 * fold like "1 - 1", both qualify the same way a literal "0" does. What is
 * NOT a null pointer constant is a cast whose value is not 0 ("(VALUE)1"), or
 * whose operand could never be an integer constant expression at all -- a
 * cast to a *floating* type is excluded by 6.6p6 itself (a constant-expression
 * cast may only convert to an integer type, outside sizeof/alignof), so
 * "(double)0" does not qualify even though its value is 0.
 *
 * CRuby's ext/mysql2/client.c compares rb_thread_call_without_gvl's VALUE
 * result against Qfalse, whose expansion is exactly this shape:
 *
 *     typedef unsigned long VALUE;
 *     enum ruby_special_consts { RUBY_Qfalse = 0, ... };
 *     #define Qfalse ((VALUE)RUBY_Qfalse)
 *     ... == Qfalse
 *
 * RUBY_Qfalse is an enum constant of value 0, cast to VALUE (unsigned long) --
 * a null pointer constant this front end rejected before this step, which is
 * where `gem install mysql2` stopped.
 *
 * Every accepted form below is exercised in every context 6.3.2.3p3 admits a
 * null pointer constant: a static and a local initializer, a plain
 * assignment, an "=="/"!=" comparison in both operand orders, a function
 * argument, a return value and both arms of "?:". test_examples.rb builds
 * this file with gcc and with rubycc and demands the same output from both.
 */

#include <stdio.h>

typedef unsigned long VALUE;
enum ruby_special_consts { RUBY_Qfalse = 0, RUBY_Qtrue = 2 };
#define Qfalse ((VALUE)RUBY_Qfalse)

/* A static-storage-duration initializer: the address constant machinery
   folds this at compile time into eight zero bytes, no code needed. */
void *global_from_cast = (VALUE)0;
void *global_slot;

void *return_ulong_zero(void) { return (VALUE)0; }
void *return_char_zero(void) { return (char)0; }
void *return_qfalse(void) { return Qfalse; }

int is_null(void *p) { return p == 0; }

int main(void)
{
  int x;
  void *p = &x;

  /* A local initializer and a plain assignment, for a cast to an integer
     type other than void *, an arithmetic fold, a 1-byte integer type and
     the CRuby Qfalse shape itself. */
  void *a = (VALUE)0;
  void *b = (VALUE)(1 - 1);
  void *c = (char)0;
  void *d = Qfalse;
  global_slot = (VALUE)0;

  printf("%d %d %d %d %d\n", a == 0, b == 0, c == 0, d == 0, global_slot == 0);

  /* "=="/"!=" against a pointer, both operand orders. */
  printf("%d %d %d %d\n", p == (VALUE)0, p != (VALUE)0, (VALUE)0 == p, (VALUE)0 != p);
  printf("%d %d %d\n", p == (VALUE)(1 - 1), p == (char)0, p == Qfalse);

  /* A function argument and a return value. */
  printf("%d %d %d %d\n", is_null((VALUE)0), return_ulong_zero() == 0,
         return_char_zero() == 0, return_qfalse() == 0);

  /* Both arms of "?:", and the static initializer above. */
  printf("%d %d %d\n", global_from_cast == 0,
         (1 ? (VALUE)0 : p) == 0, (0 ? p : (VALUE)0) == 0);

  /* RUBY_Qtrue, cast the same way, is an ordinary nonzero VALUE -- not a null
     pointer constant, so it is only ever compared as an integer here (a
     pointer comparison against it is a diagnostic, covered separately by
     test/test_conditional_null_pointer.rb, not by this executed example). */
  printf("%d %lu\n", RUBY_Qtrue == 2, (VALUE)RUBY_Qtrue);

  return 0;
}
