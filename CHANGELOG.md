# Changelog

Notable changes per release. The per-step design record — why each decision was made,
and what was measured to justify it — is in [docs/development/STEPS.md](docs/development/STEPS.md); this file is
the summary a consumer of the gem needs.

Versioning follows semver with one project-specific rule: **a regression in the corpus
pass rate is a breaking change**, whatever the code change looked like. See the
Versioning section of the README.

## 1.0.0 (unreleased)

First release. rubycc builds Ruby C extensions with no gcc, no binutils, no make and no
shell — it is a C compiler, assembler-free ELF writer, linker, `ar`, `make`, `pkg-config`
shim and preprocessor, written in Ruby.

### What works

- **31 gems verified**: bigdecimal, bootsnap, date, digest, erb, etc, fiddle,
  google-protobuf, http_parser.rb, io-console, io-nonblock, io-wait, json, msgpack,
  mysql2, nio4r, nkf, pg, prism, psych, puma, racc, redcarpet, sqlite3, stackprof,
  stringio, strscan, syslog, websocket-driver, yajl-ruby, zlib. "Verified" means the
  gem's own test suite passed against the `.so` that a `RUBYCC=1 gem install` produced
  — the record is `data/verified_gems.json`, written only by
  `tools/verify_gem_tests.rb`, never by hand. That is 31 of the 34 gems in the corpus
  denominator (**91.2%**), meeting the 90% the design sets as its acceptance criterion.
- **Two machines**: x86-64 and aarch64, each with its own backend and ABI.
- **Two C libraries**: glibc and musl. The bundled headers carry both where they differ,
  and every difference was measured against that environment's own gcc rather than
  copied from a libc's sources.
- **Bundled libc headers** so a distroless image with no libc development package still
  compiles `ruby.h`.
- `rubycc-doctor` reports whether a project's gems are known to build.

### Known limitations

Listed in full, with measurements, in the README. The ones most likely to matter:

- Compile throughput is 69% of the 20,000 lines/sec target.
- Generated code is unoptimized; up to 7.65x slower than `gcc -O2` on tight loops.
- C11 atomics are partial: `_Atomic` compiles to the unqualified type's layout and ABI
  for scalars of 1, 2, 4 and 8 bytes, and the bundled `<stdatomic.h>` carries the fences
  and the generic macros; `atomic_fetch_or`/`_and`/`_xor`, `atomic_flag` and the implicit
  sequential consistency of a plain access are missing.
- `long double` is compiled as `double` (8 bytes, not the ABI's 80-bit x87 in 16), so it
  loses precision and a value passed to `printf("%Lg", …)` reads back wrong.
- Shared objects bind their own global symbols directly (`ld -Bsymbolic` semantics),
  with no switch to turn it off.
- 128-bit integers: passing, returning and shifting work; division, remainder, bitwise
  operators and variadic passing do not.

### Not in scope

C++ (grpc), gems that run `configure` through mini_portile (nokogiri's vendored build —
`--use-system-libraries` is fine), and gems that ship assembly (ffi). The full list with
reasons is [docs/reference/OUT-OF-SCOPE-GEMS.md](docs/reference/OUT-OF-SCOPE-GEMS.md).
