// Step 25: passing and returning structs by value (the System V AMD64
// classification). Earlier steps handled a struct only through a pointer;
// Phase B classifies each struct into eightbytes and carries it in registers
// when it fits (INTEGER eightbytes in rax/rdx and the argument GP registers,
// SSE eightbytes in xmm0/xmm1 and the argument xmm registers) or through a
// hidden pointer when it is larger than two eightbytes (MEMORY). These helpers
// take and return structs directly, so a whole record flows across the call
// boundary, and main prints the results with printf.

int printf(const char *, ...);

// Two ints pack into a single eightbyte: an INTEGER-class register return.
struct Point {
  int x;
  int y;
};

// A mixed record: the int and the double land in separate eightbytes, so it is
// returned in one integer register and one xmm register ([:gp, :sse8]).
struct Mix {
  int tag;
  double value;
};

// Three longs are 24 bytes, past two eightbytes, so this record is passed and
// returned in memory through a hidden pointer (MEMORY class).
struct Vec3 {
  long a;
  long b;
  long c;
};

// A struct argument and a struct return, both in registers: translate a point.
struct Point translate(struct Point p, int dx, int dy) {
  struct Point r;
  r.x = p.x + dx;
  r.y = p.y + dy;
  return r;
}

// A mixed-class struct returned by value: the int eightbyte comes back in rax,
// the double eightbyte in xmm0.
struct Mix scale_mix(struct Mix m, double factor) {
  struct Mix r;
  r.tag = m.tag + 1;
  r.value = m.value * factor;
  return r;
}

// A MEMORY struct passed and returned by value: the caller supplies the result
// buffer and the sum is written through it.
struct Vec3 add3(struct Vec3 u, struct Vec3 v) {
  struct Vec3 r;
  r.a = u.a + v.a;
  r.b = u.b + v.b;
  r.c = u.c + v.c;
  return r;
}

// Returning *p exercises the "read a whole struct through a pointer" path,
// which copies into a scratch buffer before splitting into eightbytes.
struct Point origin_offset(struct Point *p) {
  return *p;
}

int main(void) {
  // A register-class struct through a call, its members accessed on the result.
  struct Point p;
  p.x = 40;
  p.y = 2;
  struct Point moved = translate(p, 1, -1);
  printf("moved = (%d, %d)\n", moved.x, moved.y);          // (41, 1)

  // Chaining: the result of one struct-returning call feeds the next.
  struct Point twice = translate(translate(p, 10, 10), 100, 100);
  printf("twice = (%d, %d)\n", twice.x, twice.y);          // (150, 112)

  // A mixed [:gp, :sse8] struct returned and printed from both classes.
  struct Mix m;
  m.tag = 7;
  m.value = 1.5;
  struct Mix s = scale_mix(m, 4.0);
  printf("mix = tag %d value %g\n", s.tag, s.value);       // tag 8 value 6

  // MEMORY structs added by value; the whole 24-byte record travels via a
  // hidden result pointer.
  struct Vec3 u;
  u.a = 1;
  u.b = 2;
  u.c = 3;
  struct Vec3 v;
  v.a = 10;
  v.b = 20;
  v.c = 30;
  struct Vec3 w = add3(u, v);
  printf("vec3 = %ld %ld %ld\n", w.a, w.b, w.c);           // 11 22 33

  // return *p: initialize a struct object from a by-value struct return.
  struct Point q = origin_offset(&moved);
  printf("q = (%d, %d)\n", q.x, q.y);                      // (41, 1)

  return 0;
}
