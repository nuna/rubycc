# include-census — corpus C-extension `#include` census

**Generated file. Do not hand-edit.** This is a snapshot produced by
`rake corpus:census` (see `test/corpus/README.md`). Re-run that task to update
it, then commit the result. The task requires network access; `rake test` does not.
The snapshot is deterministic: gem versions are pinned in `gems.rb`, so nothing
that varies run-to-run (timestamps, the interpreter version, ...) belongs in it.

- Bundled header set: 64 angle spellings computed from `include/`
  (freestanding `include/*.h` + `include/libc/**`, arch layer normalized).

Angle-bracket (`#include <...>`) includes only; quoted local includes are ignored.
`ruby.h`, `ruby/...`, `rubycc*`, and each extension's own headers are excluded from
libc-gap analysis (they resolve via ruby's hdrdir or the ext directory). Raw include
scanning over-counts: headers behind SIMD / Windows / C++ gates are listed as gap
candidates with a note; the census does not evaluate the gate.

## Corpus gems

| gem | requested | resolved | status | ext .c/.h | note |
|-----|-----------|----------|--------|-----------|------|
| json | 2.21.1 | 2.21.1 | ok | 3/5 | Pure C parser/generator. SIMD paths are gated (JSON_DISABLE_SIMD); census counts gated headers as gap candidates without judging the gate. |
| msgpack | 1.8.3 | 1.8.3 | ok | 12/15 | Pure C packer/unpacker; single ext dir. |
| bigdecimal | 4.1.2 | 4.1.2 | ok | 3/7 | Pure C arbitrary-precision decimal; default gem, widely depended on. |
| date | 3.5.1 | 3.5.1 | ok | 4/2 | Pure C date/time core (ext/date); default gem. |
| racc | 1.8.1 | 1.8.1 | ok | 1/0 | Pure C parser runtime (ext/racc/cparse); extconf.rb runs no probes. |
| redcarpet | 3.6.1 | 3.6.1 | ok | 10/8 | Pure C Markdown renderer; extconf.rb runs no probes. |
| digest | 3.2.1 | 3.2.1 | ok | 10/9 | Six extconf.rb in one gem (ext/digest plus bubblebabble, md5, rmd160, sha1, sha2); first multi-ext gem in this corpus. |
| erb | 6.0.1.1 | 6.0.1.1 | ok | 1/0 | Single ext dir (ext/erb/escape). |
| etc | 1.4.6 | 1.4.6 | ok | 1/1 | Single ext dir (ext/etc). |
| fcntl | 1.3.0 | 1.3.0 | excluded | — | Small single-file ext (ext/fcntl). Upstream ruby/fcntl carries no test/ directory, no test task in its Rakefile, and no test step in its CI (measured against v1.3.0 and master, docs/STEPS.md Step 157); excluded from the R10 denominator because "gem's own tests passed" evidence is impossible to obtain, not because rubycc fails it. |
| io-console | 0.8.2 | 0.8.2 | ok | 1/0 | Single ext dir (ext/io/console). |
| io-nonblock | 0.3.2 | 0.3.2 | ok | 1/0 | Small single-file ext (ext/io/nonblock). |
| io-wait | 0.4.0 | 0.4.0 | ok | 1/0 | Small single-file ext (ext/io/wait). |
| openssl | 4.0.2 | 4.0.2 | ok | 33/21 | Depends on the system OpenSSL headers; DESIGN R10 names openssl as an expected-in-scope system-library gem. |
| prism | 1.8.1 | 1.8.1 | ok | 3/1 | Ruby's own parser; a large extension including generated C sources. |
| psych | 5.3.1 | 5.3.1 | ok | 5/5 | Depends on the system libyaml; DESIGN R10 names psych as an expected-in-scope system-library gem. |
| stringio | 3.2.0 | 3.2.0 | ok | 1/0 | Single ext dir (ext/stringio). |
| strscan | 3.1.6 | 3.1.6 | ok | 1/0 | Single ext dir (ext/strscan). |
| zlib | 3.2.3 | 3.2.3 | ok | 1/0 | Depends on the system zlib headers; DESIGN R10 expects gems built against a system library (e.g. sqlite3) to be in scope. |
| fiddle | 1.1.8 | 1.1.8 | ok | 8/4 | Ruby 4.0 bundled gem; C extension backed by the system libffi headers and library. |
| rbs | 3.10.0 | 3.10.0 | ok | 5/6 | Ruby 4.0 bundled gem; pure C parser/type-signature extension. |
| syslog | 0.3.0 | 0.3.0 | ok | 1/0 | Ruby 4.0 bundled gem; small pure C extension using the system syslog API. |
| websocket-driver | 0.8.2 | 0.8.2 | ok | 1/0 | Single ext dir (ext/websocket-driver); extconf.rb only calls dir_config, no external library dependency, no C++. |
| puma | 8.0.2 | 8.0.2 | ok | 3/1 | Single ext dir (ext/puma_http11). OpenSSL is an optional dependency: extconf.rb only probes for it unless PUMA_DISABLE_SSL is set, and the build continues without SSL if it is not found. No C++, no mini_portile. DESIGN §3.1 names puma among the expected-in-scope gems. |
| google-protobuf | 4.35.1 | 4.35.1 | ok | 11/10 | ext/google/protobuf_c bundles ruby-upb.c (upb, a C implementation despite the gem's C++-sounding name) and utf8_range.c; the gem contains no .cc files. No mini_portile dependency. |
| bootsnap | 1.24.6 | 1.24.6 | ok | 1/0 | Single ext dir (ext/bootsnap); no external library dependency, no C++. |
| oj | 3.17.4 | 3.17.4 | ok | 41/25 | Single ext dir (ext/oj); no external library dependency, no C++. |
| sqlite3 | 2.9.5 | 2.9.5 | excluded | — | Single ext dir (ext/sqlite3). By default builds the bundled sqlite3 amalgamation itself via mini_portile2; `--enable-system-libraries` switches to the system libsqlite3 instead. No C++ either way (the amalgamation is .c) and no configure is run. DESIGN §3.1 names "sqlite3 (when using the system library)" as expected in scope. rubycc already compiles the sqlite3 amalgamation (261,463 lines) standalone (docs/STEPS.md, Step 116), making this gem a promising corpus candidate. |
| nio4r | 2.7.5 | 2.7.5 | ok | 13/5 | 669,001,382 downloads. Single ext dir (ext/nio4r); extconf.rb only calls dir_config. C 13 files / H 5 files. The I/O selector behind Rails' ActionCable and puma. |
| byebug | 13.0.0 | 13.0.0 | excluded | — | 470,544,259 downloads. Single ext dir (ext/byebug); extconf.rb is 12 lines and only calls dir_config. C 5 files / H 1 file. Out of the R10 denominator: the upstream suite does not pass with the reference compiler either. Measured on 2026-08-07 with tools/verify_gem_tests.rb, control and rubycc runs reporting the same numbers to the digit — 535 runs, 776 assertions, 22 failures, 6 errors, 2 skips (docs/STEPS.md atomic-type-8). |
| pg | 1.6.3 | 1.6.3 | excluded | — | 458,822,794 downloads. Single ext dir (ext/); C 22 files / H 3 files. Important note: extconf.rb references mini_portile2 and `./configure`, but only inside the `--with-cross-build` path (extconf.rb:26, `if gem_platform = with_config("cross-build")`), which is only taken when building pre-built cross-platform binary gems. A normal source install locates the system libpq via pg_config / pkg-config instead. DESIGN R10 names pg as in scope. Because census.rb's mechanical check only looks for a mini_portile reference anywhere in extconf.rb, it may judge pg as excluded even though the mini_portile path is unused on a normal build. |
| mysql2 | 0.5.7 | 0.5.7 | ok | 5/8 | 238,399,342 downloads. Single ext dir (ext/mysql2); C 5 files / H 8 files. Depends on the system libmysqlclient / libmariadb headers via have_library, the same system-library-dependent-but-in-scope shape as openssl and zlib above. |
| thin | 2.0.1 | 2.0.1 | excluded | — | 207,539,292 downloads. Single ext dir (ext/thin_parser), a Ragel-generated parser: C 2 files / H 2 files. thin's own extension is pure C and passes the machine gate, but its runtime dependency eventmachine is a C++ extension, so `gem install thin` cannot complete without building one. Measured on 2026-08-08: rubycc reaches eventmachine's nine .cpp files and the build stops there (docs/STEPS.md atomic-type-9). Out of the R10 denominator by R10's own C++ exclusion, reaching one level past thin's own sources. |
| http_parser.rb | 0.8.1 | 0.8.1 | ok | 8/3 | 175,614,437 downloads. Single ext dir (ext/ruby_http_parser); C 8 files / H 3 files. extconf.rb only calls dir_config. |
| stackprof | 0.2.28 | 0.2.28 | ok | 1/0 | 153,037,422 downloads. Single ext dir (ext/stackprof); a single C file — one of the smallest C extensions in this corpus. extconf.rb is 16 lines but does carry four have_func probes (rb_postponed_job_preregister and friends), measured in Step 146; an earlier note here said "no probes", which was wrong. |
| unicorn | 6.1.0 | 6.1.0 | excluded | — | 118,284,401 downloads. Single ext dir (ext/unicorn_http); C 2 files / H 5 files, extconf.rb has no probes. Note: its dependencies kgio and raindrops are also C extensions, so `gem install unicorn` additionally requires building those; rubycc builds all three since atomic-type-6/7. Out of the R10 denominator: the upstream suite does not pass with the reference compiler either. Measured on 2026-08-07 by building both ways and running the same 15 files, with identical results — test_request.rb 10 errors, test_signals.rb 1 error, test_util.rb 3 failures. unicorn 6.1.0 is the newest release and announces at load that it was only tested up to MRI 3.0; the failures are Ruby 3.4 incompatibilities in its Ruby code (docs/STEPS.md atomic-type-7). |
| debug | 1.11.1 | 1.11.1 | excluded | — | 116,172,789 downloads. Single ext dir (ext/debug); C 2 files, extconf.rb 27 lines with no probes. Ruby's standard debugger. Out of the R10 denominator: the upstream suite does not pass with the reference compiler either. Measured on 2026-08-07 with tools/verify_gem_tests.rb, control and rubycc runs reporting the same numbers to the digit — 305 tests, 571 assertions, 1 failure, 1 omission (docs/STEPS.md atomic-type-8). |
| yajl-ruby | 1.4.3 | 1.4.3 | ok | 9/11 | 107,509,632 downloads. Single ext dir (ext/yajl); C 9 files / H 11 files, bundling the yajl C sources. extconf.rb 12 lines with no probes. |
| nkf | 0.3.0 | 0.3.0 | ok | 3/3 | 105,204,704 downloads. Single ext dir (ext/nkf); C 3 files / H 3 files. extconf.rb is only 3 lines. Was formerly a default gem, but is not in Ruby 4.0.6's default gem list, so it was not part of the default gem group in Step 117. |

## Excluded / skipped

| gem | outcome | reason |
|-----|---------|--------|
| fcntl | excluded | upstream ships no test suite — R10's "gem's own tests passed" evidence (verification level (d)) is impossible to obtain (docs/OUT-OF-SCOPE-GEMS.md basis D) |
| sqlite3 | excluded | configure / mini_portile dependency in extconf.rb — R10 excludes configure-dependent gems |
| byebug | excluded | upstream suite does not pass with the reference compiler either (measured with tools/verify_gem_tests.rb --control) — no compiler can earn R10's verification level (d) here |
| pg | excluded | configure / mini_portile dependency in extconf.rb — R10 excludes configure-dependent gems |
| thin | excluded | `gem install` requires eventmachine (C++ extension — docs/OUT-OF-SCOPE-GEMS.md basis A), which R10 already excludes — this gem's own sources pass the machine gate, but the install cannot complete without building an out-of-scope extension |
| unicorn | excluded | upstream suite does not pass with the reference compiler either (measured with tools/verify_gem_tests.rb --control) — no compiler can earn R10's verification level (d) here |
| debug | excluded | upstream suite does not pass with the reference compiler either (measured with tools/verify_gem_tests.rb --control) — no compiler can earn R10's verification level (d) here |

## R10 pass rate

DESIGN R10 targets >= 90% of the corpus at gem-install success *and* the gem's own test suite passing against the rubycc-built extension (`data/verified_gems.json`, verification level (d)). The denominator below is gems that passed the R10 machine gate above (`status: ok`); the numerator is how many of those have a `data/verified_gems.json` record.

Two kinds of gem are excluded from the denominator because *no* compiler could earn that record for them: one whose upstream ships no test suite at all, and one whose upstream suite does not pass with the reference compiler either (measured with `tools/verify_gem_tests.rb --control`). Both are declared per gem in `test/corpus/gems.rb`, whose field documentation states what evidence each claim requires — in particular, a gem whose control run fails *differently* from its rubycc run is not excluded, because the difference is rubycc's to answer for.

| R10 gate passes (denominator) | verified (numerator) | pass rate | remaining to 90% |
|---|---|---|---|
| 32 | 29 | 90.6% | 0 |

## gem × system header matrix

| header | class | json | msgpack | bigdecimal | date | racc | redcarpet | digest | erb | etc | io-console | io-nonblock | io-wait | openssl | prism | psych | stringio | strscan | zlib | fiddle | rbs | syslog | websocket-driver | puma | google-protobuf | bootsnap | oj | nio4r | mysql2 | http_parser.rb | stackprof | yajl-ruby | nkf |
|--------|-------|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `AvailabilityMacros.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `BaseTsd.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |
| `CommonCrypto/CommonDigest.h` | gap |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `WinNT.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `arm_neon.h` | gap | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |
| `arpa/inet.h` | bundled |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `assert.h` | bundled | x | x | x | x |  | x | x |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  | x | x |  |  | x |  | x |  | x | x |
| `builtins.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `conio.h` | gap |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `cpuid.h` | gap | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |
| `cstdbool` | gap | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `ctype.h` | bundled | x |  | x | x |  | x |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  | x | x |  |  |  |  | x |  | x |  |
| `dirent.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |
| `dlfcn.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `emmintrin.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |
| `errmsg.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |
| `errno.h` | bundled |  |  | x | x |  |  |  |  | x |  |  |  | x |  |  |  |  |  | x |  |  |  |  | x | x | x | x | x |  |  | x |  |
| `fcntl.h` | bundled |  |  |  |  |  |  |  |  |  | x | x |  |  |  |  | x |  |  |  |  |  |  |  |  | x | x | x | x |  |  |  | x |
| `ffi.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `ffi/ffi.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `float.h` | bundled |  |  | x | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  | x |  |  |  | x |  |
| `grp.h` | bundled |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `ieeefp.h` | gap |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `intrin.h` | gap | x |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  | x | x |  |  |  |  |  |
| `inttypes.h` | bundled |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  | x |  |  |  |  |  |
| `io.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  | x |
| `langinfo.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `libc/dosio.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `limits.h` | bundled |  | x | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  | x |  | x |  | x |  |
| `link.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `linux/aio_abi.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `linux/fs.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `linux/types.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `locale.h` | bundled |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `machine/endian.h` | gap |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `math.h` | bundled | x |  | x | x |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  | x | x |  |  |  | x |  |
| `mbarrier.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `mysql.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |
| `mysql/errmsg.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |
| `mysql/mysql.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |
| `nmmintrin.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |
| `openssl/asn1.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/bio.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |
| `openssl/bn.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/conf.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/crypto.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/decoder.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/dh.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |
| `openssl/dsa.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/engine.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/err.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |
| `openssl/evp.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/kdf.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/ocsp.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/opensslv.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/pkcs12.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/pkcs7.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/provider.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/rand.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/rsa.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/ssl.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |
| `openssl/ts.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `openssl/x509.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |
| `openssl/x509v3.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `os2.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `poll.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  |  |  |  |  |
| `port.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `pthread.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  |  | x |  |  |
| `pwd.h` | bundled |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `regex.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |
| `sanitizer/hwasan_interface.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |
| `sanitizer/msan_interface.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |
| `sched.h` | bundled |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |
| `setjmp.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |
| `sgtty.h` | gap |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `shlobj.h` | gap |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `signal.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  | x |  |  |
| `stdarg.h` | bundled |  |  |  |  |  | x |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  | x |  | x |  |  | x |  |  |  |
| `stdatomic.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  | x |  |  |  |  |  |
| `stdbool.h` | bundled | x | x | x |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  | x | x |  |  |  | x | x | x |  | x |  |  |  |  |
| `stdckdint.h` | bundled |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `stddef.h` | bundled |  | x | x |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  |  | x |  | x |  |  |  |
| `stdint.h` | bundled | x | x | x |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x | x | x |  | x |  |  |  |
| `stdio.h` | bundled |  |  | x |  |  | x | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  | x | x |  | x |  | x | x |
| `stdlib.h` | bundled |  | x | x | x |  | x | x |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  | x | x |  | x |  | x | x |
| `string.h` | bundled | x | x | x | x |  | x | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  | x | x |  | x |  | x | x |
| `strings.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |
| `sys/cdefs.h` | bundled |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/endian.h` | gap |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/epoll.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `sys/event.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `sys/fcntl.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/inotify.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `sys/ioctl.h` | bundled |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/mman.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `sys/param.h` | bundled |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/resource.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |
| `sys/select.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `sys/socket.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |
| `sys/stat.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  | x |  |  |  |  | x |
| `sys/statfs.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `sys/syscall.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `sys/systm.h` | gap |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/time.h` | bundled |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  | x | x |  |  |
| `sys/timerfd.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `sys/types.h` | bundled |  |  |  |  |  |  | x |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  | x | x | x | x | x |  |  | x |
| `sys/uio.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |
| `sys/utime.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `sys/utsname.h` | bundled |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `sys/wait.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `syslog.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |
| `termio.h` | gap |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `termios.h` | bundled |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `time.h` | bundled |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  | x | x | x |  | x |  |  |
| `unistd.h` | bundled |  |  |  |  |  |  |  |  | x | x | x |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x | x | x |  |  |  | x |
| `utime.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `valgrind/memcheck.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `windows.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  | x |  |  |  |  | x |
| `winioctl.h` | gap |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `winsock2.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `x86intrin.h` | bundled | x |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |
| `yaml.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `zlib.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |

## Gap candidates (not bundled, used by ≥1 corpus gem)

| header | used by | likely gate | verdict |
|--------|---------|-------------|---------|
| `AvailabilityMacros.h` | nio4r | — | review |
| `BaseTsd.h` | http_parser.rb | — | review |
| `CommonCrypto/CommonDigest.h` | digest | — | review |
| `WinNT.h` | nio4r | — | review |
| `arm_neon.h` | json, oj | SIMD/CPU-feature gate (arch/feature-conditional) | gated (likely not required) |
| `builtins.h` | nio4r | — | review |
| `conio.h` | io-console | — | review |
| `cpuid.h` | json, oj | SIMD/CPU-feature gate (arch/feature-conditional) | gated (likely not required) |
| `cstdbool` | json | C++-only (C++ standard header) | gated (likely not required) |
| `emmintrin.h` | oj | SIMD/CPU-feature gate (arch/feature-conditional) | gated (likely not required) |
| `errmsg.h` | mysql2 | — | review |
| `ffi.h` | fiddle | — | review |
| `ffi/ffi.h` | fiddle | — | review |
| `ieeefp.h` | bigdecimal | — | review |
| `intrin.h` | bigdecimal, google-protobuf, json, nio4r, oj | Windows-only gate | gated (likely not required) |
| `io.h` | nio4r, nkf | Windows-only gate | gated (likely not required) |
| `libc/dosio.h` | nkf | — | review |
| `linux/aio_abi.h` | nio4r | — | review |
| `linux/fs.h` | nio4r | — | review |
| `linux/types.h` | nio4r | — | review |
| `machine/endian.h` | digest | — | review |
| `mbarrier.h` | nio4r | — | review |
| `mysql.h` | mysql2 | — | review |
| `mysql/errmsg.h` | mysql2 | — | review |
| `mysql/mysql.h` | mysql2 | — | review |
| `nmmintrin.h` | oj | SIMD/CPU-feature gate (arch/feature-conditional) | gated (likely not required) |
| `openssl/asn1.h` | openssl | — | review |
| `openssl/bio.h` | puma | — | review |
| `openssl/bn.h` | openssl | — | review |
| `openssl/conf.h` | openssl | — | review |
| `openssl/crypto.h` | openssl | — | review |
| `openssl/decoder.h` | openssl | — | review |
| `openssl/dh.h` | openssl, puma | — | review |
| `openssl/dsa.h` | openssl | — | review |
| `openssl/engine.h` | openssl | — | review |
| `openssl/err.h` | openssl, puma | — | review |
| `openssl/evp.h` | openssl | — | review |
| `openssl/kdf.h` | openssl | — | review |
| `openssl/ocsp.h` | openssl | — | review |
| `openssl/opensslv.h` | openssl | — | review |
| `openssl/pkcs12.h` | openssl | — | review |
| `openssl/pkcs7.h` | openssl | — | review |
| `openssl/provider.h` | openssl | — | review |
| `openssl/rand.h` | openssl | — | review |
| `openssl/rsa.h` | openssl | — | review |
| `openssl/ssl.h` | openssl, puma | — | review |
| `openssl/ts.h` | openssl | — | review |
| `openssl/x509.h` | puma | — | review |
| `openssl/x509v3.h` | openssl | — | review |
| `os2.h` | nkf | — | review |
| `port.h` | nio4r | — | review |
| `sanitizer/hwasan_interface.h` | google-protobuf | — | review |
| `sanitizer/msan_interface.h` | google-protobuf | — | review |
| `sgtty.h` | io-console | — | review |
| `shlobj.h` | etc | — | review |
| `sys/endian.h` | digest | — | review |
| `sys/event.h` | nio4r | — | review |
| `sys/systm.h` | digest | — | review |
| `sys/utime.h` | nkf | — | review |
| `syslog.h` | syslog | — | review |
| `termio.h` | io-console | — | review |
| `utime.h` | nkf | — | review |
| `valgrind/memcheck.h` | zlib | — | review |
| `windows.h` | fiddle, nio4r, nkf | Windows-only gate | gated (likely not required) |
| `winioctl.h` | io-console | — | review |
| `winsock2.h` | nio4r | Windows-only gate | gated (likely not required) |
| `yaml.h` | psych | — | review |
| `zlib.h` | zlib | — | review |

