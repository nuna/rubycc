/*
 * Step 46: flexible array members (ISO C 6.7.2.1). A struct's last member may
 * be an incomplete array; it contributes nothing to sizeof, and the enclosing
 * code allocates "sizeof(struct) + n * sizeof(element)" and indexes the tail —
 * msgpack's held-buffer (a size_t header followed by a VALUE tail) is exactly
 * this shape. Compiled by rubycc, linked with libc's printf/malloc.
 */

int printf(const char *, ...);
void *malloc(unsigned long);
void free(void *);

struct held {
  unsigned long count;
  long tail[];           /* the flexible array member */
};

int main(void) {
  /* sizeof ignores the tail: only the header (padded) is counted. */
  printf("header=%zu\n", sizeof(struct held));

  unsigned long n = 5;
  struct held *h = malloc(sizeof(struct held) + n * sizeof(long));
  h->count = n;
  for (unsigned long i = 0; i < n; i++)
    h->tail[i] = (long)(i * 11);      /* 0 11 22 33 44 */

  long sum = 0;
  for (unsigned long i = 0; i < h->count; i++)
    sum += h->tail[i];
  printf("sum=%ld last=%ld\n", sum, h->tail[n - 1]);

  int status = (int)sum - 68;        /* 110 - 68 = 42 */
  free(h);
  return status;
}
