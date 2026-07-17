/*
 * Step 48: bit-field reads and writes. msgpack's unpacker packs five one-bit
 * bools into a flags word ("bool symbolize_keys : 1;" and friends) and its
 * option setters/getters assign and test them — the shift/mask lowering this
 * demonstrates. Also mixed-width int fields sharing one storage unit, and a
 * signed field whose top bit sign-extends on load. Compiled by rubycc, linked
 * with libc's printf.
 */

int printf(const char *, ...);

/* The msgpack unpacker shape: independent one-bit flags. */
struct options {
  _Bool symbolize_keys : 1;
  _Bool freeze : 1;
  _Bool allow_unknown : 1;
};

/* Mixed widths sharing a unit, including a signed field. */
struct packet {
  unsigned version : 3;
  unsigned kind : 5;
  int delta : 6;          /* signed: -32..31 */
  unsigned crc : 10;
};

static void set_freeze(struct options *o, _Bool v) { o->freeze = v; }

int main(void) {
  struct options o;
  o.symbolize_keys = 1;
  o.freeze = 0;
  o.allow_unknown = 1;
  set_freeze(&o, 1);

  printf("flags=%d%d%d\n", o.symbolize_keys, o.freeze, o.allow_unknown);

  struct packet p;
  p.version = 5;
  p.kind = 21;
  p.delta = -9;            /* sign-extends when read back */
  p.crc = 777;

  p.crc = p.crc + (unsigned)(p.delta + 9);   /* read-modify through locals */

  printf("v=%u k=%u d=%d crc=%u\n", p.version, p.kind, p.delta, p.crc);
  printf("size=%zu\n", sizeof(struct packet));

  return (int)(p.version + p.kind + p.crc % 100) + p.delta;
  /* 5 + 21 + 77 - 9 = 94 */
}
