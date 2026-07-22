# include-census — corpus C-extension `#include` census

**Generated file. Do not hand-edit.** This is a snapshot produced by
`rake corpus:census` (see `test/corpus/README.md`). Re-run that task to update
it, then commit the result. The task requires network access; `rake test` does not.

- Generated: 2026-07-22T13:53:42Z
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
| json | 2.21.1 | 2.21.1 | 2026-07-22 | ok | 3/5 | Pure C parser/generator. SIMD paths are gated (JSON_DISABLE_SIMD); census counts gated headers as gap candidates without judging the gate. |
| msgpack | 1.8.3 | 1.8.3 | 2026-07-22 | ok | 12/15 | Pure C packer/unpacker; single ext dir. |
| bigdecimal | latest | 4.1.2 | 2026-07-22 | ok | 3/7 | Pure C arbitrary-precision decimal; default gem, widely depended on. |
| date | latest | 3.5.1 | 2026-07-22 | ok | 4/2 | Pure C date/time core (ext/date); default gem. |
| racc | latest | 1.8.1 | 2026-07-22 | ok | 1/0 | Pure C parser runtime (ext/racc/cparse); extconf.rb runs no probes. |
| redcarpet | latest | 3.6.1 | 2026-07-22 | ok | 10/8 | Pure C Markdown renderer; extconf.rb runs no probes. |

## Excluded / skipped

None. All corpus gems were fetched and passed the R10 machine gate.

## gem × system header matrix

| header | class | json | msgpack | bigdecimal | date | racc | redcarpet |
|--------|-------|---|---|---|---|---|---|
| `arm_neon.h` | gap | x |  |  |  |  |  |
| `arpa/inet.h` | bundled |  | x |  |  |  |  |
| `assert.h` | bundled | x | x | x | x |  | x |
| `cpuid.h` | gap | x |  |  |  |  |  |
| `cstdbool` | gap | x |  |  |  |  |  |
| `ctype.h` | bundled | x |  | x | x |  | x |
| `errno.h` | bundled |  |  | x | x |  |  |
| `float.h` | bundled |  |  | x | x |  |  |
| `ieeefp.h` | gap |  |  | x |  |  |  |
| `intrin.h` | gap | x |  | x |  |  |  |
| `limits.h` | bundled |  | x | x |  |  |  |
| `locale.h` | gap |  |  | x |  |  |  |
| `math.h` | bundled | x |  | x | x |  |  |
| `stdarg.h` | bundled |  |  |  |  |  | x |
| `stdbool.h` | bundled | x | x | x |  |  |  |
| `stdckdint.h` | gap |  |  | x |  |  |  |
| `stddef.h` | bundled |  | x | x |  |  | x |
| `stdint.h` | bundled | x | x | x |  |  | x |
| `stdio.h` | bundled |  |  | x |  |  | x |
| `stdlib.h` | bundled |  | x | x | x |  | x |
| `string.h` | bundled | x | x | x | x |  | x |
| `sys/time.h` | bundled |  |  |  | x |  |  |
| `time.h` | bundled |  |  |  | x |  |  |
| `x86intrin.h` | bundled | x |  | x |  |  |  |

## Gap candidates (not bundled, used by ≥1 corpus gem)

| header | used by | likely gate | verdict |
|--------|---------|-------------|---------|
| `arm_neon.h` | json | SIMD/CPU-feature gate (arch/feature-conditional) | gated (likely not required) |
| `cpuid.h` | json | SIMD/CPU-feature gate (arch/feature-conditional) | gated (likely not required) |
| `cstdbool` | json | C++-only (C++ standard header) | gated (likely not required) |
| `ieeefp.h` | bigdecimal | — | review |
| `intrin.h` | bigdecimal, json | Windows-only gate | gated (likely not required) |
| `locale.h` | bigdecimal | — | review |
| `stdckdint.h` | bigdecimal | — | review |

