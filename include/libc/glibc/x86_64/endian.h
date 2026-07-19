/* rubycc bundled <endian.h>: byte-order identity macros and the host<->big/
   little conversions (glibc/BSD extension). Derived from musl's <endian.h>
   shape; the byte order and the glibc spellings (__BYTE_ORDER, bswap via the
   compiler builtins) are pinned to the little-endian x86-64 ABI. ABI switch
   layer: the byte order is arch specific. */

#ifndef _RUBYCC_ENDIAN_H
#define _RUBYCC_ENDIAN_H

#define __LITTLE_ENDIAN 1234
#define __BIG_ENDIAN    4321
#define __PDP_ENDIAN    3412
#define __BYTE_ORDER    __LITTLE_ENDIAN
#define __FLOAT_WORD_ORDER __BYTE_ORDER

/* BSD-style spellings (glibc exposes both under _DEFAULT_SOURCE). */
#define LITTLE_ENDIAN   __LITTLE_ENDIAN
#define BIG_ENDIAN      __BIG_ENDIAN
#define PDP_ENDIAN      __PDP_ENDIAN
#define BYTE_ORDER      __BYTE_ORDER

/* Byte reversals as static inline helpers (arithmetic, so no compiler byte-swap
   builtin is required and each argument is evaluated once). */
static inline unsigned short __rubycc_bswap16(unsigned short __x) {
  return (unsigned short) ((__x << 8) | (__x >> 8));
}
static inline unsigned int __rubycc_bswap32(unsigned int __x) {
  return ((__x & 0x000000ffU) << 24) | ((__x & 0x0000ff00U) << 8)
       | ((__x & 0x00ff0000U) >> 8) | ((__x & 0xff000000U) >> 24);
}
static inline unsigned long __rubycc_bswap64(unsigned long __x) {
  return ((__x & 0x00000000000000ffUL) << 56) | ((__x & 0x000000000000ff00UL) << 40)
       | ((__x & 0x0000000000ff0000UL) << 24) | ((__x & 0x00000000ff000000UL) << 8)
       | ((__x & 0x000000ff00000000UL) >> 8)  | ((__x & 0x0000ff0000000000UL) >> 24)
       | ((__x & 0x00ff000000000000UL) >> 40) | ((__x & 0xff00000000000000UL) >> 56);
}

/* Host is little-endian: the "le" forms are identities, the "be" forms swap. */
#define htobe16(x) __rubycc_bswap16(x)
#define htole16(x) ((unsigned short)(x))
#define be16toh(x) __rubycc_bswap16(x)
#define le16toh(x) ((unsigned short)(x))

#define htobe32(x) __rubycc_bswap32(x)
#define htole32(x) ((unsigned int)(x))
#define be32toh(x) __rubycc_bswap32(x)
#define le32toh(x) ((unsigned int)(x))

#define htobe64(x) __rubycc_bswap64(x)
#define htole64(x) ((unsigned long)(x))
#define be64toh(x) __rubycc_bswap64(x)
#define le64toh(x) ((unsigned long)(x))

#endif /* _RUBYCC_ENDIAN_H */
