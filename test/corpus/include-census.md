# include-census — corpus C-extension `#include` census

**Generated file. Do not hand-edit.** This is a snapshot produced by
`rake corpus:census` (see `test/corpus/README.md`). Re-run that task to update
it, then commit the result. The task requires network access; `rake test` does not.

- Generated: 2026-07-27T23:30:40Z
- Ruby: ruby 3.4.5 (2025-07-16 revision 20cda200d3) +PRISM [x86_64-linux]
- Bundled header set: 40 angle spellings computed from `include/`
  (freestanding `include/*.h` + `include/libc/**`, arch layer normalized).

Angle-bracket (`#include <...>`) includes only; quoted local includes are ignored.
`ruby.h`, `ruby/...`, `rubycc*`, and each extension's own headers are excluded from
libc-gap analysis (they resolve via ruby's hdrdir or the ext directory). Raw include
scanning over-counts: headers behind SIMD / Windows / C++ gates are listed as gap
candidates with a note; the census does not evaluate the gate.

## Corpus gems

| gem | requested | resolved | fetched | status | ext .c/.h | note |
|-----|-----------|----------|---------|--------|-----------|------|
| json | 2.21.1 | 2.21.1 | 2026-07-27 | ok | 3/5 | Pure C parser/generator. SIMD paths are gated (JSON_DISABLE_SIMD); census counts gated headers as gap candidates without judging the gate. |
| msgpack | 1.8.3 | 1.8.3 | 2026-07-27 | ok | 12/15 | Pure C packer/unpacker; single ext dir. |
| bigdecimal | latest | 4.1.2 | 2026-07-27 | ok | 3/7 | Pure C arbitrary-precision decimal; default gem, widely depended on. |
| date | latest | 3.5.1 | 2026-07-27 | ok | 4/2 | Pure C date/time core (ext/date); default gem. |
| racc | latest | 1.8.1 | 2026-07-27 | ok | 1/0 | Pure C parser runtime (ext/racc/cparse); extconf.rb runs no probes. |
| redcarpet | latest | 3.6.1 | 2026-07-27 | ok | 10/8 | Pure C Markdown renderer; extconf.rb runs no probes. |
| digest | 3.2.1 | 3.2.1 | 2026-07-27 | ok | 10/9 | Six extconf.rb in one gem (ext/digest plus bubblebabble, md5, rmd160, sha1, sha2); first multi-ext gem in this corpus. |
| erb | 6.0.1.1 | 6.0.1.1 | 2026-07-27 | ok | 1/0 | Single ext dir (ext/erb/escape). |
| etc | 1.4.6 | 1.4.6 | 2026-07-27 | ok | 1/1 | Single ext dir (ext/etc). |
| fcntl | 1.3.0 | 1.3.0 | 2026-07-27 | ok | 1/0 | Small single-file ext (ext/fcntl). |
| io-console | 0.8.2 | 0.8.2 | 2026-07-27 | ok | 1/0 | Single ext dir (ext/io/console). |
| io-nonblock | 0.3.2 | 0.3.2 | 2026-07-27 | ok | 1/0 | Small single-file ext (ext/io/nonblock). |
| io-wait | 0.4.0 | 0.4.0 | 2026-07-27 | ok | 1/0 | Small single-file ext (ext/io/wait). |
| openssl | 4.0.2 | 4.0.2 | 2026-07-27 | ok | 33/21 | Depends on the system OpenSSL headers; DESIGN R10 names openssl as an expected-in-scope system-library gem. |
| prism | 1.8.1 | 1.8.1 | 2026-07-27 | ok | 3/1 | Ruby's own parser; a large extension including generated C sources. |
| psych | 5.3.1 | 5.3.1 | 2026-07-27 | ok | 5/5 | Depends on the system libyaml; DESIGN R10 names psych as an expected-in-scope system-library gem. |
| stringio | 3.2.0 | 3.2.0 | 2026-07-27 | ok | 1/0 | Single ext dir (ext/stringio). |
| strscan | 3.1.6 | 3.1.6 | 2026-07-27 | ok | 1/0 | Single ext dir (ext/strscan). |
| zlib | 3.2.3 | 3.2.3 | 2026-07-27 | ok | 1/0 | Depends on the system zlib headers; DESIGN R10 expects gems built against a system library (e.g. sqlite3) to be in scope. |
| websocket-driver | 0.8.2 | 0.8.2 | 2026-07-27 | ok | 1/0 | Single ext dir (ext/websocket-driver); extconf.rb only calls dir_config, no external library dependency, no C++. |
| puma | 8.0.2 | 8.0.2 | 2026-07-27 | ok | 3/1 | Single ext dir (ext/puma_http11). OpenSSL is an optional dependency: extconf.rb only probes for it unless PUMA_DISABLE_SSL is set, and the build continues without SSL if it is not found. No C++, no mini_portile. DESIGN §3.1 names puma among the expected-in-scope gems. |
| google-protobuf | 4.35.1 | 4.35.1 | 2026-07-27 | ok | 11/10 | ext/google/protobuf_c bundles ruby-upb.c (upb, a C implementation despite the gem's C++-sounding name) and utf8_range.c; the gem contains no .cc files. No mini_portile dependency. |
| bootsnap | 1.24.6 | 1.24.6 | 2026-07-27 | ok | 1/0 | Single ext dir (ext/bootsnap); no external library dependency, no C++. |
| oj | 3.17.4 | 3.17.4 | 2026-07-27 | ok | 41/25 | Single ext dir (ext/oj); no external library dependency, no C++. |
| sqlite3 | 2.9.5 | 2.9.5 | 2026-07-27 | excluded | — | Single ext dir (ext/sqlite3). By default builds the bundled sqlite3 amalgamation itself via mini_portile2; `--enable-system-libraries` switches to the system libsqlite3 instead. No C++ either way (the amalgamation is .c) and no configure is run. DESIGN §3.1 names "sqlite3 (when using the system library)" as expected in scope. rubycc already compiles the sqlite3 amalgamation (261,463 lines) standalone (docs/STEPS.md, Step 116), making this gem a promising corpus candidate. |

## Excluded / skipped

| gem | outcome | reason |
|-----|---------|--------|
| sqlite3 | excluded | configure / mini_portile dependency in extconf.rb — R10 excludes configure-dependent gems |

## gem × system header matrix

| header | class | json | msgpack | bigdecimal | date | racc | redcarpet | digest | erb | etc | fcntl | io-console | io-nonblock | io-wait | openssl | prism | psych | stringio | strscan | zlib | websocket-driver | puma | google-protobuf | bootsnap | oj |
|--------|-------|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `CommonCrypto/CommonDigest.h` | gap |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `arm_neon.h` | gap | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `arpa/inet.h` | bundled |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `assert.h` | bundled | x | x | x | x |  | x | x |  |  |  |  |  |  | x |  |  |  |  |  |  | x | x |  |  |
| `conio.h` | gap |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `cpuid.h` | gap | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `cstdbool` | gap | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `ctype.h` | bundled | x |  | x | x |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  |  |
| `dirent.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |
| `emmintrin.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `errno.h` | bundled |  |  | x | x |  |  |  |  | x |  |  |  |  | x |  |  |  |  |  |  |  | x | x | x |
| `fcntl.h` | bundled |  |  |  |  |  |  |  |  |  | x | x | x |  |  |  |  | x |  |  |  |  |  | x | x |
| `float.h` | bundled |  |  | x | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |
| `grp.h` | gap |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `ieeefp.h` | gap |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `intrin.h` | gap | x |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  | x |
| `inttypes.h` | bundled |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |
| `limits.h` | bundled |  | x | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |
| `locale.h` | gap |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `machine/endian.h` | gap |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `math.h` | bundled | x |  | x | x |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  | x |
| `nmmintrin.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `openssl/asn1.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/bio.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |
| `openssl/bn.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/conf.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/crypto.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/decoder.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/dh.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  | x |  |  |  |
| `openssl/dsa.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/engine.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/err.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  | x |  |  |  |
| `openssl/evp.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/kdf.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/ocsp.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/opensslv.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/pkcs12.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/pkcs7.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/provider.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/rand.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/rsa.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/ssl.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  | x |  |  |  |
| `openssl/ts.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `openssl/x509.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |
| `openssl/x509v3.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |
| `poll.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `pthread.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `pwd.h` | gap |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `regex.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `sanitizer/hwasan_interface.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |
| `sanitizer/msan_interface.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |
| `sched.h` | gap |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |
| `setjmp.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |
| `sgtty.h` | gap |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `shlobj.h` | gap |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `stdarg.h` | bundled |  |  |  |  |  | x |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  | x |  | x |
| `stdatomic.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |
| `stdbool.h` | bundled | x | x | x |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  |  |  | x | x | x |
| `stdckdint.h` | gap |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `stddef.h` | bundled |  | x | x |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  |  |
| `stdint.h` | bundled | x | x | x |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x | x |
| `stdio.h` | bundled |  |  | x |  |  | x | x |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  | x |
| `stdlib.h` | bundled |  | x | x | x |  | x | x |  | x |  |  |  |  |  |  |  |  |  |  |  | x | x |  | x |
| `string.h` | bundled | x | x | x | x |  | x | x |  |  |  |  |  |  |  |  |  |  |  |  |  | x | x |  | x |
| `strings.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `sys/cdefs.h` | bundled |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/endian.h` | gap |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/fcntl.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |
| `sys/ioctl.h` | gap |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/param.h` | gap |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/resource.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `sys/stat.h` | bundled |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |
| `sys/systm.h` | gap |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/time.h` | bundled |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `sys/types.h` | bundled |  |  |  |  |  |  | x |  | x |  |  |  |  |  |  |  |  |  |  |  | x |  | x | x |
| `sys/uio.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `sys/utsname.h` | gap |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `termio.h` | gap |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `termios.h` | gap |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `time.h` | bundled |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  | x |
| `unistd.h` | bundled |  |  |  |  |  |  |  |  | x |  | x | x |  |  |  |  |  |  |  |  |  |  | x | x |
| `valgrind/memcheck.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |
| `winioctl.h` | gap |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `x86intrin.h` | bundled | x |  | x |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |
| `yaml.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |  |  |  |
| `zlib.h` | gap |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | x |  |  |  |  |  |

## Gap candidates (not bundled, used by ≥1 corpus gem)

| header | used by | likely gate | verdict |
|--------|---------|-------------|---------|
| `CommonCrypto/CommonDigest.h` | digest | — | review |
| `arm_neon.h` | json, oj | SIMD/CPU-feature gate (arch/feature-conditional) | gated (likely not required) |
| `conio.h` | io-console | — | review |
| `cpuid.h` | json, oj | SIMD/CPU-feature gate (arch/feature-conditional) | gated (likely not required) |
| `cstdbool` | json | C++-only (C++ standard header) | gated (likely not required) |
| `dirent.h` | bootsnap | — | review |
| `emmintrin.h` | oj | SIMD/CPU-feature gate (arch/feature-conditional) | gated (likely not required) |
| `grp.h` | etc | — | review |
| `ieeefp.h` | bigdecimal | — | review |
| `intrin.h` | bigdecimal, google-protobuf, json, oj | Windows-only gate | gated (likely not required) |
| `locale.h` | bigdecimal | — | review |
| `machine/endian.h` | digest | — | review |
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
| `pwd.h` | etc | — | review |
| `regex.h` | oj | — | review |
| `sanitizer/hwasan_interface.h` | google-protobuf | — | review |
| `sanitizer/msan_interface.h` | google-protobuf | — | review |
| `sched.h` | etc, google-protobuf | — | review |
| `setjmp.h` | google-protobuf | — | review |
| `sgtty.h` | io-console | — | review |
| `shlobj.h` | etc | — | review |
| `stdatomic.h` | google-protobuf | — | review |
| `stdckdint.h` | bigdecimal | — | review |
| `sys/endian.h` | digest | — | review |
| `sys/fcntl.h` | stringio | — | review |
| `sys/ioctl.h` | io-console | — | review |
| `sys/param.h` | digest | — | review |
| `sys/resource.h` | oj | — | review |
| `sys/systm.h` | digest | — | review |
| `sys/uio.h` | oj | — | review |
| `sys/utsname.h` | etc | — | review |
| `termio.h` | io-console | — | review |
| `termios.h` | io-console | — | review |
| `valgrind/memcheck.h` | zlib | — | review |
| `winioctl.h` | io-console | — | review |
| `yaml.h` | psych | — | review |
| `zlib.h` | zlib | — | review |

