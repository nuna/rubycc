# rubycc

**Almost Pure Ruby C toolchain** — build Ruby native extensions without gcc, binutils, or a shell.

rubycc is a C compiler, linker, archiver and `make` written entirely in Ruby. It compiles
C to ELF64 machine code directly (no assembly text, no external assembler) and links
shared objects itself, so a `gem install` that needs a C extension can run on a machine
that has no toolchain installed.

```
$ RUBYCC=1 gem install msgpack
Building native extensions. This could take a while...
Successfully installed msgpack-1.8.3
```

## Status

Working. The toolchain compiles and links real gems, and the gems' own test suites pass
against the resulting binaries. **31 gems are verified this way**, each by running the
gem's own suite against the `.so` a `RUBYCC=1 gem install` produced — never by inspection:

    bigdecimal  bootsnap  date  digest  erb  etc  fiddle  google-protobuf  http_parser.rb
    io-console  io-nonblock  io-wait  json  msgpack  mysql2  nio4r  nkf  pg  prism  psych
    puma  racc  redcarpet  sqlite3  stackprof  strscan  stringio  syslog  websocket-driver
    yajl-ruby  zlib

The verified environments are:

| environment | verified gems |
|---|---|
| glibc x86-64 | 31 |
| musl x86-64 (Alpine) | 3 |
| glibc aarch64 | 6 |

The bundled headers match the ABI of the supported environments on both architectures
and both C libraries.

The current corpus census has 39 candidates, 34 gems in the R10 machine-gate denominator,
and 31 verified gems: **91.2%**, which meets the 90% the design requires. `pg` and
`sqlite3` are in that denominator through explicit DESIGN-compatible profiles (pg's
native-source path, sqlite3 with `--enable-system-libraries`), so the rate is measured
against a larger corpus than the 90.6% reported before those two were added. See
[`test/corpus/include-census.md`](test/corpus/include-census.md) for the generated report.

It also compiles the SQLite amalgamation — a single 261,463-line translation unit — in
8.1 s using 467 MB of memory.

## What's in the box

| command | stands in for |
|---|---|
| `rubycc` | `cc` — preprocessor, compiler, linker driver (`-c`, `-o`, `-E`, `-shared`, `-fPIC`, `-I`, `-D`, `-L`, `-l`) |
| `rmake` | `make` — parses Makefiles, runs recipes without a shell, parallel by default |
| `rubycc-ar` | `ar` — deterministic archives |
| `rubycc-pkgconf` | `pkg-config` |
| `rubycc-doctor` | diagnostics: check an environment or a gem for compatibility |

Targets **x86-64** and **aarch64** Linux (ELF64). The repository currently carries 81
physical bundled header files, representing 64 normalized angle-bracket spellings in the
census. They cover the C11 freestanding set plus the POSIX surface real gems use, so no
libc development package is needed for the headers.

## Requirements

- **Ruby 3.3 or newer.** The suite is run on 3.3, 3.4 and 4.0; see *Known limitations*.
- **Ruby's own headers** (`ruby.h` and friends) and `rbconfig`. Official ruby images have
  them; on a distro Ruby you need the `-dev`/`-devel` package.
- **Shared libraries you link against** must be present as binaries (`libc.so`, `libz.so`,
  …). Their *headers* are not needed — the linker reads `.dynsym` and emits `DT_NEEDED`.
- A Ruby built with `--enable-shared` is recommended, because mkmf's `try_link` conftests
  link an executable.

## Usage

Set `RUBYCC=1` and install as usual:

```sh
RUBYCC=1 gem install <gem>
```

For a complete build-stage/runtime-stage example aimed at shell-less images,
see [examples/distroless](examples/distroless/README.md).

`RUBYCC=0` forces it off. With neither set, rubycc activates itself only when `cc` and
`make` are absent from `PATH`, so it stays out of the way on a normal development machine.

Direct use works too:

```sh
rubycc -c foo.c -o foo.o
rubycc -shared -fPIC -o foo.so foo.o
rubycc -E foo.c              # preprocess only
rubycc --target=aarch64 -c foo.c -o foo.o
```

## Known limitations

- **Compile speed is 69% of the target.** 13,854 preprocessed lines/sec (Ruby 4.0 + YJIT,
  median over real gem sources) against a 20,000 goal. A typical gem still builds in
  seconds.
- **Generated code is unoptimized.** No register allocation: every value is spilled to the
  stack. Against `gcc -O2` the slowdown reaches 7.65x on tight loops (1.2x–2.6x on
  branch- and call-bound code); against `gcc -O0` it is 1.1x–2.9x.
- **C11 atomics are partial.** `_Atomic` is accepted in both spellings (`_Atomic int`,
  `_Atomic(int)`) and compiles to the unqualified type's layout and ABI — measured
  against gcc — for integer, floating and pointer types of 1, 2, 4 or 8 bytes; an
  aggregate, a 16-byte scalar, an array or a function under `_Atomic` is a compile
  error rather than a silently non-atomic object. The bundled `<stdatomic.h>` provides
  the memory-order constants, `atomic_thread_fence`/`atomic_signal_fence`,
  `atomic_init`, and the load/store/exchange/compare-exchange/fetch-add/fetch-sub
  generic macros, all lowered to locked machine sequences at 4 and 8 bytes.
  What is missing: `atomic_fetch_or`/`_and`/`_xor`, `atomic_flag`,
  `atomic_is_lock_free`, and the implicit sequential consistency C11 gives a plain
  read or write of an `_Atomic` object (such an access compiles to an ordinary,
  still-indivisible, instruction — use the macros where the ordering matters).
  See `docs/reference/C11-COVERAGE.md`.
- **C23 checked arithmetic is partial.** The bundled `<stdckdint.h>` maps `ckd_add`,
  `ckd_sub`, and `ckd_mul` to rubycc's overflow builtins; the rest of C23 is not implemented.
- **`<regex.h>` is a minimal ABI header.** It provides the glibc-compatible `regex_t`/
  `regmatch_t` layout needed by C extensions, but the full POSIX regex implementation is
  not part of rubycc.
- **`__GNUC__` is deliberately not defined.** Headers take their non-GNU fallback path.
- **128-bit integers**: passing, returning and shifting work; division, remainder, bitwise
  `& | ^` and variadic passing do not.
- **`long double` carries double's range and precision, and `sizeof(long double)` is 8**
  where the x86-64 psABI says 16 (80-bit x87) and AArch64 says 16 (IEEE binary128).
  Arithmetic therefore has double's 53-bit significand rather than the wider format's.

  **Passing one to a variadic function does work**: a call site converts the value to the
  platform's wide format, so `printf("%Lg", x)` prints what gcc prints — including the
  signed zeros, the infinities, NaNs and subnormals, checked against gcc's own bytes.

  What still differs is everything that depends on the *width*: `sizeof`, `_Alignof`,
  `max_align_t`, a struct member's offset, and a `long double` passed as a **named**
  argument or returned by value (so a call to `frexpl` and friends still mismatches).
  Closing that changes the ABI of every object file, so it is batched with the other two
  known ABI deviations into one major release rather than shipped piecemeal.
- **Out of scope**: C++ input is rejected with a diagnostic (the compiler accepts C only),
  so gems needing a C++ compiler (grpc) are out of scope. Gems that run `configure` through
  mini_portile (nokogiri's vendored build; `--use-system-libraries` is fine), or that ship
  assembly (ffi), are also out of scope.
- **Shared objects bind their own global symbols directly.** A symbol a shared object
  both defines and references resolves to that object's own definition, not to an
  earlier one in the process — the behaviour `ld -Bsymbolic` gives, which many
  distributions enable on purpose because it skips the PLT/GOT indirection. rubycc
  always does it and offers no switch. Calls, struct passing, varargs and alignment
  are unaffected; what changes is `LD_PRELOAD` interposition of such a symbol, and
  the case where the same symbol is already defined elsewhere in the process (two
  live copies instead of one).

## No gem-side changes required

Compatibility is rubycc's job, not the gem's. A gem must build **unmodified**: rubycc never
asks for source changes, `extconf.rb` or gemspec edits, install-time patches, or
rubycc-specific code such as `#ifdef __RUBYCC__`. If a gem does not build, that is a rubycc
bug.

Two things are *not* considered gem-side changes: turning rubycc on (`RUBYCC=1`), and
choosing an install option the gem itself offers — for example
`gem install nokogiri -- --use-system-libraries`, which is a supported flag of that gem,
not a rubycc workaround.

## Versioning

Semantic versioning, with one project-specific rule:

- **A regression in the corpus pass rate is a breaking change.** The corpus
  (`test/corpus/gems.rb`, 39 candidates and currently 34 R10 machine-gate targets) is the
  contract. The selected profile and exact extconf arguments are part of each target's
  identity; they do not by themselves count as an upstream-suite verification.
  If a release stops building a gem that the previous release built, that is major-version
  territory, not a patch — regardless of how small the code change was.
- **A change to the generated code's ABI is a breaking change too**, even when the corpus
  pass rate goes up. Type sizes, alignments and struct layouts are what object files agree
  on: an object compiled by one major cannot be linked against one compiled by another if
  those move. `long double`'s width, `enum`'s underlying type and `wchar_t`'s signedness
  are the three known deviations from the platform ABI still open, and closing any of them
  moves exactly those values.
- **Known ABI deviations are closed together, not one at a time.** Each one alone would
  justify a major release, and shipping three majors would make every consumer rebuild
  three times for what is, from their side, one change: "rubycc now matches the platform
  ABI". They are batched into a single major for that reason.
- **Minor** releases add language or header coverage, new targets, or new gems that build.
- **Patch** releases fix bugs and improve performance without changing what builds.
- The generated code's *speed* is not part of the compatibility contract, but throughput
  and runtime performance are tracked (`rake bench:throughput`, `benchmark/run.rb`) and
  regressions are treated as bugs.

The full picture is in [docs/reference/C11-COVERAGE.md](docs/reference/C11-COVERAGE.md) (clause-by-clause C11
conformance) and [docs/development/ROADMAP.md](docs/development/ROADMAP.md) §3 (known limitations).

## How it works

Source → preprocessor (translation phases 1–4) → parser → typed AST → IR → machine code →
ELF writer. The linker resolves symbols, merges sections and emits `.so`/executables. No
stage shells out; no stage writes assembly text.

- [docs/development/DESIGN.md](docs/development/DESIGN.md) — requirements, architecture decisions, scope
- [docs/internals/IR.md](docs/internals/IR.md) — the intermediate representation
- [docs/development/RELEASE-CHECKLIST.md](docs/development/RELEASE-CHECKLIST.md) — non-functional requirement status
- [docs/reference/HEADER-LICENSING.md](docs/reference/HEADER-LICENSING.md) — provenance of every bundled header

## Development

```sh
rake test                  # full suite
rake bench:throughput      # compile-speed benchmark (network: fetches gems)
rake corpus:census         # which headers do real gems need? (network)
R10_CORPUS_CACHE=... rake corpus:r10_scan # provenance + variadic candidates (no network)
ruby benchmark/run.rb      # generated-code speed vs gcc
```

The suite compares rubycc against gcc on every layer it can: preprocessed token streams,
exit codes and stdout of compiled programs, cross-architecture ABI probes, and the
c-testsuite. gcc is a development-time dependency only — it is never required at runtime.

## License

MIT. See [LICENSE.txt](LICENSE.txt) and [NOTICE](NOTICE) — the bundled headers' provenance
is documented in [docs/reference/HEADER-LICENSING.md](docs/reference/HEADER-LICENSING.md).
