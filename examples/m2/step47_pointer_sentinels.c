/*
 * Step 47: integer constants cast to pointer type in global initializers.
 * CRuby's RUBY_TYPED_DEFAULT_FREE expands to "(RUBY_DATA_FUNC)-1" — a sentinel
 * function pointer that is not an address at all, stored in a static
 * rb_data_type_t. The slot holds the raw integer bits with no relocation.
 * Compiled by rubycc, linked with libc's printf.
 */

int printf(const char *, ...);

/* The rb_data_type_t shape: a name and a free-function slot holding the
 * sentinel "(dfree_t)-1" (RUBY_TYPED_DEFAULT_FREE's expansion). */
typedef void (*dfree_t)(void *);
struct dtype {
  const char *name;
  dfree_t dfree;
};
static const struct dtype box_type = { "box", (dfree_t)-1 };

/* Absolute addresses and arithmetic on them. */
static void *mmio = (void *)0x1000;
static char *probe = (char *)16 + 2;

int main(void) {
  int sentinel_ok = (box_type.dfree == (dfree_t)-1);
  printf("name=%s sentinel=%d\n", box_type.name, sentinel_ok);
  printf("mmio=%p probe=%p\n", mmio, (void *)probe);

  return sentinel_ok * 24 + (int)(unsigned long)mmio / 256 + (int)(unsigned long)probe;
  /* 24 + 16 + 18 = 58 */
}
