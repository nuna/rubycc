/*
 * Step 42: __builtin_offsetof, reached through <stddef.h>'s offsetof macro.
 * Unlike the traditional address-of-member form, this folds to a compile-time
 * constant, so it works in constant contexts: a static initializer, an array
 * bound, and a case label. This is the shape reflection/serialization code in
 * real C extensions uses — a static table mapping field names to their byte
 * offsets. Compiled by rubycc with no -I (bundled <stddef.h>), linked with
 * libc's printf.
 */

#include <stddef.h>

int printf(const char *, ...);

struct point { int x; int y; };

struct record {
  char tag;                 /* forces padding before the aligned members */
  long id;
  struct point where;       /* nested aggregate, for a nested designator */
  int history[4];           /* array member, for an indexed designator   */
};

/* offsetof in a static initializer (constant context). */
static const size_t field_offsets[] = {
  offsetof(struct record, tag),
  offsetof(struct record, id),
  offsetof(struct record, where),
  offsetof(struct record, where.y),   /* nested designator */
  offsetof(struct record, history[2]) /* indexed designator */
};

/* offsetof as an array bound (constant context). */
static char id_slot[offsetof(struct record, id)];

int main(void) {
  size_t n = sizeof(field_offsets) / sizeof(field_offsets[0]);
  for (size_t i = 0; i < n; i++)
    printf("offset[%zu]=%zu\n", i, field_offsets[i]);

  printf("id_slot=%zu\n", sizeof(id_slot));

  /* offsetof in a case label (constant context). */
  size_t probe = offsetof(struct record, where);
  switch (probe) {
    case offsetof(struct record, id):
      printf("at id\n");
      break;
    case offsetof(struct record, where):
      printf("at where\n");
      break;
    default:
      printf("elsewhere\n");
      break;
  }

  /* The sum doubles as the process exit status. */
  size_t total = 0;
  for (size_t i = 0; i < n; i++) total += field_offsets[i];
  return (int)total;
}
