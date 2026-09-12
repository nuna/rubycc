# Changelog

Notable changes per release. The per-step design record — why each decision was made,
and what was measured to justify it — is in [docs/development/STEPS.md](docs/development/STEPS.md); this file is
the summary a consumer of the gem needs.

Versioning follows semver with one project-specific rule: **a regression in the corpus
pass rate is a breaking change**, whatever the code change looked like. See the
Versioning section of the README.

## 1.1.0 (2026-09-12)

84 pull requests since 1.0.0, and no breaking change — including under this project's own
rule, since the corpus pass rate went up rather than down.

### Corpus

- **Pass rate 91.2% → 94.3%**: 33 of the 35 gems in the R10 machine-gate denominator are
  verified. `rbs` left the denominator because its upstream suite fails identically under
  the reference compiler — the basis `byebug`, `unicorn` and `debug` were excluded on —
  and `debug_inspector` and `bindex` were added and verified in the same step, so the
  denominator grew from 34 to 35 rather than shrinking. Verification is recorded per
  environment; both new gems are recorded against glibc x86-64 / Ruby 3.3.12.
- A candidate-discovery pipeline: a scanner over popularity rankings, a pinned artifact
  schema, arbitrary candidate code confined to a manual workflow, and a skill that
  inspects one candidate at a time.

### Compiler

- **`long double` passed to a variadic function now works** (the first half of the known
  limitation). The width stays 8 bytes, but a value handed to `...` is converted to the
  80-bit extended format (binary128 on AArch64) before it is pushed, so
  `printf("%Lg", x)` agrees with glibc.
- **Macro re-expansion now matches gcc**: the hide set of a call is the intersection of
  its name's and its closing paren's (6.10.3.4), and argument-borne tokens are painted
  with the call's own name. c-testsuite 00201 passes, and so does `f(f)(1)`.
- `__builtin_popcountll` and the other bit-count / bit-scan builtins.
- The five byte-order predefined macros gcc supplies (`__BYTE_ORDER__` and friends).
- The `#warning` directive.
- The `__attr_*` macros in the bundled `sys/cdefs.h`, which the host's `<malloc.h>` reaches
  for on a glibc host.

### Generated code

- Spill traffic reduction and a register allocator that keeps a value in one register
  across a function, on both x86-64 and AArch64.

### Toolchain

- **rmake interprets a shell subset itself** — `for`, `if`, brace groups, shell variables
  and the `test` / `[` builtins — so the install rules Automake and libtool generate run.
  It never hands anything to `/bin/sh`: pipes, command substitution and `while` are
  refused rather than approximated.
- A recipe fragment could reach `/bin/sh` after all: `Process.spawn` routes a lone shell
  reserved word to a shell, so a one-word command behaved differently from a two-word one.
  Closed.
- mkmf's conftest command runs without a shell.
- **Everything rubycc reads is bytes**: C source, `ARGV`, the include search path, and the
  names `ar` and ELF readers return. Two strings holding the same non-ASCII bytes under
  different encodings are not equal, so one spelling per name is the only way the
  comparisons hold.

### CI

- The deterministic acceptance contract (pinned archives, no network) runs on **every pull
  request**. Tier A skips five of its seven required IDs, so a pull request had never run
  extconf or either gem install.
- The musl weekly job is green again: shared-object fixtures, a glibc-only fixture that is
  not valid C on musl, and symbol collisions between fixtures that musl's no-op `dlclose`
  leaves resident.

## 1.0.0 (2026-08-12)

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
