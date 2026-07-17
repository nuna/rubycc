/*
 * Step 43: GNU variadic-macro extensions — named variadic parameters
 * ("#define m(head, rest...)") and comma deletion (", ## __VA_ARGS__").
 * Both are what the system headers demand: linux/stddef.h declares
 * "__struct_group(TAG, NAME, ATTRS, MEMBERS...)" (which every <sys/types.h>
 * user preprocesses), and glibc/CRuby headers routinely forward "fmt, ##args"
 * to printf-like functions so a bare call without extra arguments drops the
 * trailing comma. Compiled by rubycc, linked with libc's printf.
 */

int printf(const char *, ...);

/* A named variadic parameter: MEMBERS collects the rest, commas included —
 * the exact shape of linux/stddef.h's __struct_group. */
#define DECLARE_PAIR(TAG, MEMBERS...) struct TAG { MEMBERS }

DECLARE_PAIR(point, int x; int y;);
DECLARE_PAIR(span, long from; long to; int width;);

/* Comma deletion with the ISO spelling: with no extra arguments the ", ##"
 * drops the comma, so LOG("plain") forwards a lone format string. */
#define LOG(fmt, ...) printf(fmt, ##__VA_ARGS__)

/* Comma deletion with a named parameter: the format is glued onto a literal
 * prefix (translation-phase-6 concatenation), the rest forwarded — or dropped,
 * comma included, when absent. */
#define TRACE(fmt, args...) printf("[T] " fmt, ##args)

int main(void) {
  struct point p; p.x = 3; p.y = 4;
  struct span s; s.from = 10; s.to = 20; s.width = 2;

  LOG("plain\n");
  LOG("point %d %d\n", p.x, p.y);

  TRACE("bare\n");
  TRACE("sum %ld width %d\n", s.to - s.from, s.width);

  return p.x + p.y + (int)(s.to - s.from) + s.width; /* 3+4+10+2 = 19 */
}
