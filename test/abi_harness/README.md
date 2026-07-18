# ABI verification harness

`test/test_header_abi.rb` drives `harness.rb`. For each header it declares a
`Spec` (types to size, macros to print, struct offsets, compile-only snippets),
generates one probe program, compiles and runs it twice -- **gcc against the
real headers** (the oracle) and **rubycc against the bundled headers** (its
default search path already prefers them, so no `-I` is passed) -- and asserts
byte-identical output. Every bundled header should arrive with a `Spec` here, so
its ABI correctness is machine-checked instead of eyeballed.

The freestanding layer (`include/`, Step 41) is the current green baseline:
`stddef`, `stdarg`, `stdbool`, `stdalign`, `float`, `iso646`.

## Known freestanding discrepancies (not asserted, open rubycc gaps)

These are surfaced by the harness but excluded from the asserted set because
they are rubycc limitations, not header or harness defects. They are the first
things the next ABI-hardening pass should close:

- **`max_align_t` (stddef.h)** — rubycc models `long double` as an 8-byte double,
  so `sizeof/_Alignof` are `16/8` where the glibc psABI is `32/16`. Fixing this
  needs x87 80-bit `long double` support in the backend, not a header change.
- **`FLT_MAX` (float.h)** — rubycc's float32 literal conversion rounds the
  bundled `3.40282347e+38F` up to `+inf`; gcc yields `0x1.fffffep+127`. Every
  other `float`/`double` magnitude macro (`FLT_MIN`, `DBL_MAX`, epsilons, true
  minimums, all integer characteristics) matches to the byte.

---

# B7 first-batch target list (measured inventory)

Method: every TU of **ruby.h**, **json 2.21.1** (parser / generator / vendor
fpconv) and **msgpack 1.8.3** (all 12 ext TUs) was run through `gcc -H -E` with
the ruby header dirs (`rubyhdrdir`, `rubyarchhdrdir`) and each ext dir on the
include path. The gems themselves `#include` almost nothing from libc directly
(only `assert.h` and `string.h` appear at depth 1); the entire libc surface is
pulled in transitively through `ruby.h`.

Totals over all TUs (deduplicated):

- **133** headers read from `/usr/include` (the libc surface below).
- **106** headers read from `/usr/lib/gcc/.../include` — the compiler-supplied
  *freestanding* set (stdarg/stddef/limits + the `*intrin.h` family). rubycc
  supplies these itself already, so they are **out of scope** for the bundled
  libc; the SIMD `*intrin.h` chain in particular is behind gem SIMD probes that
  fail naturally under rubycc.

Of the 133 libc headers: **25 canonical top-level names**, **84** glibc-internal
`bits/` split headers, **2** `gnu/` headers, and **22** kernel-UAPI headers
(`asm/`, `asm-generic/`, `linux/`). The `bits/` and `gnu/` chains are glibc's own
implementation splitting; a bundled libc header **collapses** them (it defines
the types/macros directly), so rubycc does not reproduce those 86 files -- they
are a measure of how much machinery each top-level name fans out into on glibc,
not a list to port.

## Top-level headers to provide (25), coarse classification

Classes: **(a)** declarations/macros only (opaque types are fine), **(b)** exact
type widths or struct layout required, **(c)** value/layout that ultimately comes
from a kernel-UAPI chain (errno numbers, socket/stat constants and structs).
`chain` = distinct `/usr/include` headers glibc fans this one out into when
included alone (a rough weight); `uapi` = how many of those are kernel-UAPI.

| Header | Class | chain / uapi | Notes |
|---|---|---|---|
| `stdio.h` | a | 29 / 0 | Functions + **opaque `FILE`** (keep the struct hidden). |
| `stdlib.h` | a | 49 / 0 | malloc/free/strto*, `size_t`, `div_t`/`ldiv_t`. Big fan-out is `bits/`. |
| `string.h` | a | 15 / 0 | Pure declarations. Directly `#include`d by a gem TU. |
| `strings.h` | a | 13 / 0 | Pure declarations. |
| `ctype.h` | a | 21 / 0 | Declarations + glibc's `__ctype_b_loc` table accessor. |
| `assert.h` | a | 11 / 0 | `assert` macro + `__assert_fail`. Directly `#include`d by a gem TU. |
| `alloca.h` | a | 11 / 0 | `alloca` decl (maps to rubycc's builtin). |
| `math.h` | a | 33 / 0 | Declarations + `INFINITY`/`NAN`/`HUGE_VAL` macros. |
| `errno.h` | c | 16 / 4 | `errno` = `*__errno_location()`; numbers via `asm-generic/errno*`. |
| `limits.h` | a | 19 / 1 | `INT_MAX` &c. macros (glibc reaches gcc's via `#include_next`). |
| `stdint.h` | b | 23 / 0 | Exact-width typedefs + `INT*_MAX`/`*_C` macros. Not yet bundled. |
| `inttypes.h` | b | 24 / 0 | `stdint` + `PRId64`/`SCNu32` format-macro widths. |
| `endian.h` | a | 21 / 0 | `__BYTE_ORDER`, `bswap` macros. |
| `time.h` | b | 29 / 0 | `time_t` width, **`struct tm` / `struct timespec` layout**. |
| `unistd.h` | a | 24 / 0 | Declarations + a few types (`ssize_t`, `off_t`). |
| `features.h` | a | 10 / 0 | glibc feature-test plumbing; bundle a minimal own version. |
| `features-time64.h` | a | — | glibc time64 plumbing; subsumed by our own `features`. |
| `sys/cdefs.h` | a | 10 / 0 | glibc `__BEGIN_DECLS`/`__THROW` macros; provide minimal own. |
| `sys/types.h` | b | 40 / 0 | Width-critical typedefs (`off_t`,`pid_t`,`ssize_t`,`time_t`,...). |
| `sys/stat.h` | c | 23 / 0 | **`struct stat`** layout, via `linux/stat.h` (heaviest single struct). |
| `sys/time.h` | b | 26 / 0 | `struct timeval`. |
| `sys/select.h` | b | 25 / 0 | `fd_set`. |
| `sys/socket.h` | c | 57 / 11 | `struct sockaddr`, constants via `asm/socket.h` UAPI chain. |
| `netinet/in.h` | c | 62 / 11 | `struct sockaddr_in`, `in_addr`, byte-order + UAPI chain. |
| `arpa/inet.h` | c | 63 / 11 | inet_* decls; pulls the full socket + UAPI chain (heaviest overall). |

### Heaviest chains to plan for

- **`arpa/inet.h` / `netinet/in.h` / `sys/socket.h`** (chain 63/62/57, 11 UAPI
  each) — the networking cluster drags the entire `asm*/socket`, `asm*/sockios`,
  `linux/*` UAPI set. These are (c): their constants and `sockaddr*` layouts must
  match the kernel ABI. Likely deferrable past the ruby.h/json/msgpack first cut
  (ruby.h pulls them, but the gems do not use sockets).
- **`sys/stat.h` → `linux/stat.h`** — `struct stat`'s glibc/kernel layout is the
  single most error-prone struct; give it its own dense ABI Spec.
- **`sys/types.h` (chain 40)** and **`stdlib.h` (chain 49)** — large `bits/`
  fan-out but no UAPI; the bundled versions collapse them to flat definitions,
  so the real work is getting the handful of type widths in `sys/types.h` right.

### Kernel-UAPI headers reached (22, category (c) sources)

`asm/{bitsperlong,errno,posix_types,posix_types_64,socket,sockios,types}.h`,
`asm-generic/{bitsperlong,errno-base,errno,int-ll64,posix_types,socket,sockios,types}.h`,
`linux/{close_range,errno,limits,posix_types,stat,stddef,types}.h`.
A bundled libc must reproduce the **values** these define (errno numbers, socket
option constants, `struct stat`) directly, since rubycc will not ship the kernel
UAPI tree.
