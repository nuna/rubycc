/*
 * Step 44: gcc builtins that real C extensions reach through CRuby's baked
 * config.h (HAVE_BUILTIN___BUILTIN_*): __builtin_choose_expr and
 * __builtin_constant_p (ruby.h's INT2FIX fast path takes this pair),
 * __builtin_ctz/clz and the ll variants (msgpack's bit-scan, json's float
 * parser), __builtin_memcpy, plus the __has_builtin preprocessor operator
 * (honest answers let guarded code pick its fallback) and binary integer
 * literals (0b0001, msgpack's flag constants). Compiled by rubycc, linked
 * with libc's printf.
 */

int printf(const char *, ...);

/* __has_builtin: an honest 1/0 lets this pick the right branch, the same way
 * json's parser probes for __builtin_bswap64 before using it. */
#if defined(__has_builtin) && __has_builtin(__builtin_ctz)
#define HAVE_CTZ 1
#else
#define HAVE_CTZ 0
#endif

#if defined(__has_builtin) && __has_builtin(__builtin_frobnicate)
#error "must not claim support for builtins that do not exist"
#endif

/* Binary literals (a gcc extension, standard in C23): msgpack's flag words. */
#define FLAG_RECURSIVE 0b0001
#define FLAG_FROZEN    0b0010

/* __builtin_choose_expr picks an expression at compile time; the unchosen arm
 * is neither evaluated nor code-generated, and the chosen arm supplies the
 * type — the shape ruby.h's INT2FIX dispatch takes. */
#define PICK_WIDE(cond, narrow, wide) \
  __builtin_choose_expr(cond, (wide), (narrow))

int main(void) {
  /* constant_p: 1 for something foldable, 0 otherwise — never an error. */
  int k = 3;
  int folded = __builtin_constant_p(40 + 2);
  int dynamic = __builtin_constant_p(k + 2);

  /* choose_expr: sizeof proves the chosen arm's type wins. */
  unsigned long wide = sizeof(PICK_WIDE(1, (char)0, (long)0));
  unsigned long narrow = sizeof(PICK_WIDE(0, (char)0, (long)0));

  /* Bit scans: trailing zeros of 0b1000 is 3, leading zeros of 1 in 32 bits
   * is 31; the ll variants walk a 64-bit value. */
  int tz = __builtin_ctz(0b1000);
  int lz = __builtin_clz(1u);
  int tzll = __builtin_ctzll(1ull << 40);
  int lzll = __builtin_clzll(1ull);

  /* memcpy through the builtin spelling. */
  char src[8] = "rubycc!";
  char dst[8];
  __builtin_memcpy(dst, src, 8);

  int flags = FLAG_RECURSIVE | FLAG_FROZEN;

  printf("have_ctz=%d folded=%d dynamic=%d\n", HAVE_CTZ, folded, dynamic);
  printf("wide=%lu narrow=%lu\n", wide, narrow);
  printf("tz=%d lz=%d tzll=%d lzll=%d\n", tz, lz, tzll, lzll);
  printf("copy=%s flags=%d\n", dst, flags);

  /* 3 + 31 + 40 + 63 - 137 + tiny pieces keeps the exit status readable. */
  return tz + lz + tzll + lzll - 137 + folded + flags + (int)wide; /* 3+31+40+63-137+1+3+8 = 12 */
}
