/*
 * Step atomic-type-10: old-style (K&R) function definitions.
 *
 * ISO C keeps two forms of function definition (6.9.1). The modern one writes
 * each parameter's type inside the parentheses; the old one writes only the
 * parameter *names* there -- an identifier-list declarator, 6.7.6.3 -- and
 * follows the declarator with a declaration-list that gives those names their
 * types:
 *
 *     int add(a, b)
 *       int a;
 *       int b;
 *     { return a + b; }
 *
 * Three rules make this more than a spelling.
 *
 * 1. An identifier the declaration-list never declares has type `int`
 *    (6.9.1p6), so a definition may leave parameters entirely untyped.
 *
 * 2. `register` is the only storage-class specifier a parameter declaration may
 *    carry (6.9.1p4). Every other one is a diagnostic.
 *
 * 3. A function defined this way has NO prototype, so every call to it applies
 *    the default argument promotions (6.5.2.2p6) and the definition receives its
 *    arguments in that promoted form (6.9.1p10): a `float` parameter is handed a
 *    `double`, and a `char`, `short` or `_Bool` parameter is handed an `int`.
 *    The body still sees the narrow object it declared, so sizeof reports the
 *    declared width and an assignment through the parameter truncates -- which
 *    is why take_char(300) below prints 44 and take_bool(2) prints 2 (gcc stores
 *    the low byte of the promoted argument and does not normalize a _Bool to
 *    0/1; measured, not assumed).
 *
 * The form is not a museum piece: gperf still emits it, and mysql2's bundled
 * ext/mysql2/mysql_enc_name_to_ruby.h is a gperf table whose two lookup
 * functions are written exactly like enc_hash and enc_lookup below, `register`
 * parameters and all. `gem install mysql2` stopped there before this step.
 *
 * test_examples.rb builds this file with gcc and with rubycc and demands the
 * same output from both.
 */

#include <stdio.h>
#include <string.h>

struct pair {
  int x;
  int y;
};

/* The plain form. */
int add(a, b)
  int a;
  int b;
{
  return a + b;
}

/* One declaration may declare several parameters, and the declaration-list's
   order need not follow the identifier list's. */
int spread(a, b, c)
  int b, c;
  long a;
{
  return (int)a * 100 + b * 10 + c;
}

/* 6.9.1p6: `a` is never declared, so it is an int. */
int defaulted(a, b)
  int b;
{
  return a * 100 + b;
}

/* The parameter adjustments of 6.7.6.3p7-8 apply here exactly as in a
   prototype: an array parameter becomes a pointer to its element (so sizeof
   inside the body is a pointer's 8, not the array's 40), and a function
   parameter becomes a pointer to that function. */
int through_array(a)
  int a[10];
{
  return a[1] + (int)sizeof(a);
}

static int doubler(n)
  int n;
{
  return n * 2;
}

int through_function(f, n)
  int f(int);
  int n;
{
  return f(n);
}

/* A struct parameter has no promoted form; it is passed by value as written. */
int by_value(p)
  struct pair p;
{
  return p.x * 10 + p.y;
}

/* An old-style definition of a function returning a pointer to a function. The
   identifier list belongs to the declarator buried in the parentheses; the
   trailing "(int)" is the ordinary prototype of the returned function type. */
int (*chooser(which))(int)
  int which;
{
  return which ? doubler : 0;
}

/* The default argument promotions, one parameter type each. Every callee here
   declares a type narrower than the one it is actually passed. */
int take_char(c)
  char c;
{
  return (int)c;
}

int take_uchar(c)
  unsigned char c;
{
  return (int)c;
}

int take_short(s)
  short s;
{
  return (int)s;
}

int take_bool(b)
  _Bool b;
{
  return (int)b;
}

double take_float(f)
  float f;
{
  return (double)f;
}

/* The declared width is what the body sees. */
int declared_widths(c, s, f)
  char c;
  short s;
  float f;
{
  return (int)(sizeof(c) * 100 + sizeof(s) * 10 + sizeof(f));
}

/* Writing through a narrow parameter truncates, and its address is the address
   of the narrow object -- both consequences of the parameter keeping its
   declared type even though it arrived promoted. */
int assign_through(c)
  char c;
{
  c = c + 1;
  return (int)c;
}

int address_of(c)
  char c;
{
  char *p = &c;
  *p = 9;
  return (int)c;
}

/* Enough floating parameters to run past the registers either calling
   convention hands out, so the promoted form has to be right on the stack too. */
double many_floats(a, b, c, d, e, f, g, h, i, j)
  float a, b, c, d, e, f, g, h, i, j;
{
  return (double)(a + b + c + d + e + f + g + h + i + j);
}

/* 6.7.6.3p14: the same function may be declared by a prototype and defined this
   way. gcc accepts both a prototype naming the promoted type (the conforming
   case) and one naming the declared type itself, and passes the arguments in
   the prototype's form either way -- measured, and matched here. */
int prototyped_promoted(int);
int prototyped_promoted(c)
  char c;
{
  return (int)c;
}

double prototyped_narrow(float);
double prototyped_narrow(f)
  float f;
{
  return (double)f;
}

/* The gperf shape, as mysql2 ships it: `register` on every parameter, an
   `__inline` guarded by __GNUC__, and no prototype anywhere. */
struct enc_map {
  const char *name;
  const char *rb_name;
};

#ifdef __GNUC__
__inline
#if defined __GNUC_STDC_INLINE__ || defined __GNUC_GNU_INLINE__
__attribute__ ((__gnu_inline__))
#endif
#endif
static unsigned int
enc_hash (str, len)
     register const char *str;
     register unsigned int len;
{
  static const unsigned char asso_values[] = { 5, 3, 9, 1, 7, 2, 8, 4, 6, 0 };

  return len + asso_values[(unsigned char)str[0] % 10] +
         asso_values[(unsigned char)str[len - 1] % 10];
}

#ifdef __GNUC__
__inline
#if defined __GNUC_STDC_INLINE__ || defined __GNUC_GNU_INLINE__
__attribute__ ((__gnu_inline__))
#endif
#endif
const struct enc_map *
enc_lookup (str, len)
     register const char *str;
     register unsigned int len;
{
  static const struct enc_map wordlist[] = {
    { "big5", "Big5" },
    { "latin1", "ISO-8859-1" },
    { "utf8", "UTF-8" },
    { "utf8mb4", "UTF-8" }
  };
  register unsigned int i;

  for (i = 0; i < 4; i++)
    if (strlen (wordlist[i].name) == len && strncmp (wordlist[i].name, str, len) == 0)
      return &wordlist[i];
  return 0;
}

int main(void)
{
  int arr[10];
  struct pair p;
  int (*chosen)(int);
  const char *names[3];
  int i;

  arr[1] = 41;
  p.x = 3;
  p.y = 4;
  chosen = chooser(1);
  names[0] = "utf8";
  names[1] = "latin1";
  names[2] = "nosuch";

  printf("%d %d %d\n", add(4, 5), spread(2L, 3, 4), defaulted(2, 3));
  printf("%d %d %d\n", through_array(arr), through_function(doubler, 21), by_value(p));
  printf("%d\n", chosen(9));

  printf("%d %d %d %d\n", take_char('A'), take_uchar(300), take_short(-3), take_bool(2));
  printf("%d %d\n", take_char(300), take_bool(0));
  printf("%f\n", take_float(1.5f));
  printf("%d %d %d\n", declared_widths('a', 1, 1.0f), assign_through('A'), address_of('A'));
  printf("%f\n", many_floats(1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f, 9.0f, 10.0f));
  printf("%d %f\n", prototyped_promoted('B'), prototyped_narrow(2.5f));

  for (i = 0; i < 3; i++) {
    const struct enc_map *m = enc_lookup(names[i], (unsigned int)strlen(names[i]));
    printf("%s -> %s (%u)\n", names[i], m ? m->rb_name : "(none)",
           enc_hash(names[i], (unsigned int)strlen(names[i])));
  }
  return 0;
}
