/*
 * Step 40: GNU statement expressions "( { block-item* } )" (a GCC extension).
 *
 * This is the M1 supplementary feature that unblocks real Ruby C extensions:
 * ruby.h macros such as TypedData_Make_Struct / Data_Make_Struct / rb_intern
 * expand to statement expressions, so the compiler must accept a compound
 * statement in expression position and take its last expression-statement as
 * the value and type of the whole construct.
 *
 * Demonstrated here: the value/type of the last expression-statement, the
 * block's own scope, nested statement expressions, a statement expression used
 * as a macro body (the ruby.h idiom), the void form (last item is not an
 * expression-statement, evaluated only for its side effects), and __extension__
 * as a prefix. Compiled by rubycc, linked with libc's printf.
 */

int printf(const char *, ...);

/* A macro whose body is a statement expression: it introduces a temporary,
 * does some work, and yields a value — the shape ruby.h's object-allocation
 * macros take. The braces give `lo` and `hi` a scope local to each use. */
#define CLAMP(v, lo, hi)                        \
  ({                                            \
    int _v = (v), _lo = (lo), _hi = (hi);       \
    _v < _lo ? _lo : (_v > _hi ? _hi : _v);     \
  })

int main(void) {
  /* Last expression-statement supplies the value and type. */
  int a = ({ int x = 2; x + 3; });

  /* Nested statement expressions. */
  int b = ({ int y = ({ int z = 4; z * 2; }); y + 1; });

  /* The block has its own scope: this inner `a` shadows the outer one and
   * leaves it untouched. */
  int c = ({ int a = 100; a / 4; });

  /* Statement expression as a macro body, evaluated several times. */
  int lo = CLAMP(-5, 0, 10);
  int hi = CLAMP(42, 0, 10);
  int mid = CLAMP(7, 0, 10);

  /* __extension__ prefix (used to silence -pedantic in real headers). */
  int d = __extension__ ({ int t = 10; t - 1; });

  /* The void form: the last item is a loop, not an expression-statement, so the
   * construct has no value and runs only for its effect on `sum`. */
  int sum = 0;
  ({ for (int i = 1; i <= 4; i++) sum += i; });

  printf("a=%d b=%d c=%d\n", a, b, c);         /* 5, 9, 25          */
  printf("clamp=%d,%d,%d\n", lo, hi, mid);     /* 0, 10, 7          */
  printf("d=%d sum=%d\n", d, sum);             /* 9, 10             */

  return a + b + c + lo + hi + mid + d + sum;  /* 5+9+25+0+10+7+9+10 = 75 */
}
