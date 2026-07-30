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
against the resulting binaries.

| gem | result |
|---|---|
| json 2.21.1 | 606 tests / 3,433 assertions / 0 failures |
| bigdecimal 4.1.2 | 265 tests / 8,267 assertions / 0 failures |
| redcarpet 3.6.1 | 136 tests / 206 assertions / 0 failures |
| msgpack 1.8.3 | 468 examples, all MRI examples pass |
| racc 1.8.1 | 71 tests / 319 assertions / 0 failures |
| date 3.5.1 | 143 tests / 162,593 assertions / 0 failures |

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

Targets **x86-64** and **aarch64** Linux (ELF64). Bundled libc headers cover the C11
freestanding set plus the POSIX surface real gems use, so no libc development package is
needed for the headers.

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

Measured, not guessed — each item links to the record that establishes it.

- **Compile speed is 69% of the target.** 13,854 preprocessed lines/sec (Ruby 4.0 + YJIT,
  median over real gem sources) against a 20,000 goal. A typical gem still builds in
  seconds. See [docs/THROUGHPUT.md](docs/THROUGHPUT.md).
- **Generated code is unoptimized.** No register allocation: every value is spilled to the
  stack. Against `gcc -O2` the slowdown reaches 7.65x on tight loops (1.2x–2.6x on
  branch- and call-bound code); against `gcc -O0` it is 1.1x–2.9x. See
  [docs/BENCHMARKS.md](docs/BENCHMARKS.md).
- **`_Atomic` (C11 atomics) is not implemented**, so `<stdatomic.h>` is not bundled.
- **`ckd_*` (C23 checked arithmetic) is not implemented**, so `<stdckdint.h>` is not bundled.
- **`<regex.h>` is not bundled.** Reproducing `regex_t` faithfully is required by code that
  embeds it by value, and that is not done yet.
- **`__GNUC__` is deliberately not defined.** Headers take their non-GNU fallback path.
- **128-bit integers**: passing, returning and shifting work; division, remainder, bitwise
  `& | ^` and variadic passing do not.
- **Out of scope**: gems needing a C++ compiler (grpc), or that run `configure` through
  mini_portile (nokogiri's vendored build; `--use-system-libraries` is fine), or that ship
  assembly (ffi).
- **No CI matrix yet.** The suite is run by hand on Ruby 3.3, 3.4 and 4.0; nothing
  re-checks them on every change. Running it on 3.3 is what caught a silent
  float-constant miscompilation (a `String#to_f` bug in Ruby 3.3, worked around in
  the lexer), so the floor is genuinely exercised — just not continuously.

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
  (`test/corpus/gems.rb`, 25 gems) is the contract. If a release stops building a gem that
  the previous release built, that is major-version territory, not a patch — regardless of
  how small the code change was.
- **Minor** releases add language or header coverage, new targets, or new gems that build.
- **Patch** releases fix bugs and improve performance without changing what builds.
- The generated code's *speed* is not part of the compatibility contract, but throughput
  and runtime performance are tracked (`rake bench:throughput`, `benchmark/run.rb`) and
  regressions are treated as bugs.

The full picture is in [docs/C11-COVERAGE.md](docs/C11-COVERAGE.md) (clause-by-clause C11
conformance) and [docs/ROADMAP.md](docs/ROADMAP.md) §3 (known debts).

## How it works

Source → preprocessor (translation phases 1–4) → parser → typed AST → IR → machine code →
ELF writer. The linker resolves symbols, merges sections and emits `.so`/executables. No
step shells out; no step writes assembly text.

- [docs/DESIGN.md](docs/DESIGN.md) — requirements, architecture decisions, scope
- [docs/IR.md](docs/IR.md) — the intermediate representation
- [docs/STEPS.md](docs/STEPS.md) — a design record for every implementation step
- [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md) — non-functional requirement status
- [docs/HEADER-LICENSING.md](docs/HEADER-LICENSING.md) — provenance of every bundled header

## Development

```sh
rake test                  # full suite
rake bench:throughput      # compile-speed benchmark (network: fetches gems)
rake corpus:census         # which headers do real gems need? (network)
ruby benchmark/run.rb      # generated-code speed vs gcc
```

The suite compares rubycc against gcc on every layer it can: preprocessed token streams,
exit codes and stdout of compiled programs, cross-architecture ABI probes, and the
c-testsuite. gcc is a development-time dependency only — it is never required at runtime.

## License

MIT. See [LICENSE.txt](LICENSE.txt) and [NOTICE](NOTICE) — the bundled headers' provenance
is documented in [docs/HEADER-LICENSING.md](docs/HEADER-LICENSING.md).
