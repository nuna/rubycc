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
against the resulting binaries. **18 gems are verified this way**, each by running the
gem's own suite against the `.so` a `RUBYCC=1 gem install` produced — never by inspection:

    bigdecimal  date  digest  erb  etc  io-console  io-nonblock  io-wait  json
    msgpack  nkf  psych  racc  redcarpet  stackprof  stringio  strscan  zlib

A few of the larger runs, for scale:

| gem | result |
|---|---|
| date 3.5.1 | 143 tests / 162,593 assertions / 0 failures |
| json 2.21.1 | 606 tests / 3,433 assertions / 0 failures |
| bigdecimal 4.1.2 | 265 tests / 8,267 assertions / 0 failures |
| psych 5.3.1 | 633 tests / 1,598 assertions / 0 failures |
| digest 3.2.1 | 98 tests / 215 assertions / 0 failures (six extensions in one gem) |

Beyond glibc/x86-64, the same procedure has been run on other environments. Those
columns are thinner on purpose — each entry is a measured run, so the count is what has
actually been executed, not what is expected to work:

| environment | verified gems |
|---|---|
| glibc x86-64 | 18 |
| musl x86-64 (Alpine) | 3 |
| glibc aarch64 | 2 |

The bundled headers are checked against each environment's own gcc by a differential
ABI harness, on both machines and both C libraries.

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

Measured, not guessed — each item links to the record that establishes it.

- **Compile speed is 69% of the target.** 13,854 preprocessed lines/sec (Ruby 4.0 + YJIT,
  median over real gem sources) against a 20,000 goal. A typical gem still builds in
  seconds. See [docs/THROUGHPUT.md](docs/THROUGHPUT.md).
- **Generated code is unoptimized.** No register allocation: every value is spilled to the
  stack. Against `gcc -O2` the slowdown reaches 7.65x on tight loops (1.2x–2.6x on
  branch- and call-bound code); against `gcc -O0` it is 1.1x–2.9x. See
  [docs/BENCHMARKS.md](docs/BENCHMARKS.md).
- **`_Atomic` (C11 atomics) is not implemented**, so `<stdatomic.h>` is not bundled.
- **`<regex.h>` is not bundled.** Reproducing `regex_t` faithfully is required by code that
  embeds it by value, and that is not done yet.
- **`__GNUC__` is deliberately not defined.** Headers take their non-GNU fallback path.
- **128-bit integers**: passing, returning and shifting work; division, remainder, bitwise
  `& | ^` and variadic passing do not.
- **Out of scope**: gems needing a C++ compiler (grpc), or that run `configure` through
  mini_portile (nokogiri's vendored build; `--use-system-libraries` is fine), or that ship
  assembly (ffi).
- **Shared objects bind their own global symbols directly.** A symbol a shared object
  both defines and references resolves to that object's own definition, not to an
  earlier one in the process — the behaviour `ld -Bsymbolic` gives, which many
  distributions enable on purpose because it skips the PLT/GOT indirection. rubycc
  always does it and offers no switch. Calls, struct passing, varargs and alignment
  are unaffected; what changes is `LD_PRELOAD` interposition of such a symbol, and
  the case where the same symbol is already defined elsewhere in the process (two
  live copies instead of one). Measured for both data and functions. See
  [docs/STEPS.md](docs/STEPS.md) Step 195 and the decision recorded with it.

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
