/*
 * Step 53: compound literals (ISO C 6.5.2.5) — the last wall for the json
 * gem, whose parser pushes stack frames as "(json_frame){ .type = ..., ... }"
 * by value. A compound literal creates an unnamed automatic object initialized
 * in place: shown here passed by value with designated initializers, through a
 * pointer with "&", as a decayed array, and re-created each loop iteration.
 * Compiled by rubycc, linked with libc's printf.
 */

int printf(const char *, ...);

struct frame {
  int type;
  int phase;
  long head;
};

static long describe(struct frame f) {          /* by value, the json shape */
  return f.type * 100 + f.phase * 10 + f.head;
}

static void bump(struct frame *f) { f->head += 5; }

static int sum3(const int *xs) { return xs[0] + xs[1] + xs[2]; }

int main(void) {
  /* Designated initializers; unmentioned members are zeroed. */
  long a = describe((struct frame){ .type = 3, .head = 7 });      /* 307 */

  /* Address of the unnamed object. */
  struct frame tmp = (struct frame){ .type = 1, .phase = 2, .head = 3 };
  bump(&tmp);
  long b = describe(tmp);                                          /* 128 */

  /* An array compound literal decays to a pointer. */
  int c = sum3((int[]){ 10, 20, 12 });                             /* 42 */

  /* A scalar compound literal is just its value. */
  int d = (int){ 5 } + 1;                                          /* 6 */

  /* Re-initialized on every iteration. */
  long loop = 0;
  for (int i = 0; i < 3; i++)
    loop += describe((struct frame){ .type = i, .head = i });      /* 0+101+202 */

  printf("a=%ld b=%ld c=%d d=%d loop=%ld\n", a, b, c, d, loop);
  return (int)(a % 100) + c + d + (int)(loop % 50);  /* 7 + 42 + 6 + 3 = 58 */
}
