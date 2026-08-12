# R10 manual classification

This is a human-reviewed source/build-path ledger for the 34 machine-gate targets. It does not by itself prove gem install, extension load, or upstream-suite success.

## Summary

| target count | actual use | false positive | needs more evidence | no candidate |
|---:|---:|---:|---:|---:|
| 34 | 0 | 5 | 0 | 29 |

Zero-finding scoped assessments: `a0`=20, `b0`=1, `c`=8. These labels do not replace the machine-scan state `no_candidate`; `c` is not a pass.

`no_candidate` means the selected extension source had no lexical candidate. It is not an absence proof for generated code or unselected platform branches. `source_tree_sha256` identifies the reviewed unpacked snapshot; `source_tarball_sha256` is null because it was not separately collected. Verification fields remain explicit when not run.

## Cross review

Every target below was classified by `Codex`. Every target in this ledger was classified by a single agent (reviewer=Codex), which is the same system that wrote the scanner. A second agent re-derives the conclusion by its own route so the result does not rest on one reviewer.

| reviewer | date | verdict | scope | findings covered |
|---|---|---|---|---:|
| Claude Opus 5 | 2026-08-11 | **confirmed** | date, google-protobuf, oj, http_parser.rb, nkf | 128 |

The false_positive classification of all 128 findings is confirmed by an independent route. No candidate was reclassified.

Method:

- Fetch each gem from the provenance URL recorded in this ledger and verify the pinned SHA-256 before reading anything.
- Resolve every finding_key file:line against the unpacked source and confirm the line exists.
- Read the va_arg_struct_or_union findings directly, since those are the only category that would be an actual use if correct.
- Check each finding path against selected_build_path.translation_units.
- Cross-check verification.rubycc, because rubycc rejects both target operations with a hard error.

Results:

- `digests_verified`: 5/5 matched the pinned gem_sha256
- `findings_resolved`: 128/128 resolved to an existing line
- `va_arg_candidates`: All 4 are va_arg(ap, struct message *) -- a pointer to struct, not a struct value -- in ruby_http_parser/vendor/http-parser*/test.c.
- `build_path`: No vendored or test source appears in any of the five targets selected translation_units.
- `compiler_evidence`: verification.rubycc is pass for all five, so the built path compiled under a compiler that hard-errors on both operations.

Issues the cross review raised (none change a classification):

- **Rationales are group-level, not per-finding.** Each of the five targets carries one shared rationale covering all of its candidates, while finding_key is per-finding. The ledger therefore implies a per-finding review it does not contain. _Impact:_ No classification changes; the group-level reasoning holds for every finding checked.
- **Scanner line attribution is imprecise.** Two of the four va_arg_struct_or_union findings cite lines that do not contain a va_arg call (test.c:1988 is assert(len > slen + dlen); test.c:2012 is an opening brace). The other two cite the va_arg line exactly. _Impact:_ Does not affect the classification, but a finding_key line cannot be treated as an exact source location.

## Critical review and integration

Three independent source reviews were integrated. They found that the first draft overclaimed the zero-result set and listed inventory files as compiler-selected units. The ledger now separates declared source selection from compiler verification, includes root-source/textual-include/generated-source boundaries, records nkf preprocessor exclusion and http_parser.rb vendor exclusions, and keeps external-library/profile risks unresolved.

The resulting trade-off is deliberate: 20 zero-finding targets are `a0` only within their declared profile, one is `b0` because non-target va_list formatting exists, and eight are `c` until preprocessed/source-selection or external-ABI evidence is collected. This improves false-pass resistance at the cost of leaving R10 source classification and install/suite acceptance incomplete.

## Target ledger

| gem | version | profile | manual | zero review | findings | selected source/build path | generated source | control | rubycc | extension load | upstream suite |
|---|---|---|---|---|---:|---|---|---|---|---|---|
| json | 2.21.1 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/json-2.21.1`; ext=ext/json/ext/generator, ext/json/ext/parser | source_snapshot_inspected | pass | pass | pass | pass |
| msgpack | 1.8.3 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/msgpack-1.8.3`; ext=ext/msgpack | not_present_in_snapshot | pass | pass | pass | pass |
| bigdecimal | 4.1.2 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/bigdecimal-4.1.2`; ext=ext/bigdecimal | not_present_in_snapshot | pass | pass | pass | pass |
| date | 3.5.1 | default-source | false_positive | — | 2 | `unpacked/date-3.5.1`; ext=ext/date | generated_checked_in | pass | pass | pass | pass |
| racc | 1.8.1 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/racc-1.8.1`; ext=ext/racc/cparse | source_snapshot_inspected | pass | pass | pass | pass |
| redcarpet | 3.6.1 | default-source | no_candidate | b0 / non_target_variadic_wrapper | 0 | `unpacked/redcarpet-3.6.1`; ext=ext/redcarpet | not_present_in_snapshot | pass | pass | pass | pass |
| digest | 3.2.1 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/digest-3.2.1`; ext=ext/digest, ext/digest/bubblebabble, ext/digest/md5, ext/digest/rmd160, ext/digest/sha1, ext/digest/sha2 | not_present_in_snapshot | pass | pass | pass | pass |
| erb | 6.0.1.1 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/erb-6.0.1.1`; ext=ext/erb/escape | not_present_in_snapshot | pass | pass | pass | pass |
| etc | 1.4.6 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/etc-1.4.6`; ext=ext/etc | not_present_in_snapshot | pass | pass | pass | pass |
| io-console | 0.8.2 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/io-console-0.8.2`; ext=ext/io/console | not_present_in_snapshot | pass | pass | pass | pass |
| io-nonblock | 0.3.2 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/io-nonblock-0.3.2`; ext=ext/io/nonblock | not_present_in_snapshot | pass | pass | pass | pass |
| io-wait | 0.4.0 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/io-wait-0.4.0`; ext=ext/io/wait | not_present_in_snapshot | pass | pass | pass | pass |
| openssl | 4.0.2 | default-source | no_candidate | c / needs_more_evidence | 0 | `unpacked/openssl-4.0.2`; ext=ext/openssl | not_present_in_snapshot | pass | pass | pass | fail |
| prism | 1.8.1 | default-source | no_candidate | c / needs_more_evidence | 0 | `unpacked/prism-1.8.1`; ext=ext/prism | checked_in_source | pass | pass | pass | pass |
| psych | 5.3.1 | default-source | no_candidate | c / needs_more_evidence | 0 | `unpacked/psych-5.3.1`; ext=ext/psych | source_snapshot_inspected | pass | pass | pass | pass |
| stringio | 3.2.0 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/stringio-3.2.0`; ext=ext/stringio | not_present_in_snapshot | pass | pass | pass | pass |
| strscan | 3.1.6 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/strscan-3.1.6`; ext=ext/strscan | not_present_in_snapshot | pass | pass | pass | pass |
| zlib | 3.2.3 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/zlib-3.2.3`; ext=ext/zlib | not_present_in_snapshot | pass | pass | pass | pass |
| fiddle | 1.1.8 | default-source | no_candidate | c / needs_more_evidence | 0 | `unpacked/fiddle-1.1.8`; ext=ext/fiddle | not_present_in_snapshot | pass | pass | pass | pass |
| rbs | 3.10.0 | default-source | no_candidate | c / needs_more_evidence | 0 | `unpacked/rbs-3.10.0`; ext=ext/rbs_extension | generated_not_reproduced | pass | pass | pass | inconclusive |
| syslog | 0.3.0 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/syslog-0.3.0`; ext=ext/syslog | not_present_in_snapshot | pass | pass | pass | pass |
| websocket-driver | 0.8.2 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/websocket-driver-0.8.2`; ext=ext/websocket-driver | not_present_in_snapshot | pass | pass | pass | pass |
| puma | 8.0.2 | default-source | no_candidate | c / needs_more_evidence | 0 | `unpacked/puma-8.0.2`; ext=ext/puma_http11 | generated_checked_in | pass | pass | pass | inconclusive |
| google-protobuf | 4.35.1 | default-source | false_positive | — | 41 | `unpacked/google-protobuf-4.35.1`; ext=ext/google/protobuf_c | source_snapshot_inspected | pass | pass | pass | pass |
| bootsnap | 1.24.6 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/bootsnap-1.24.6`; ext=ext/bootsnap | not_present_in_snapshot | pass | pass | pass | inconclusive |
| oj | 3.17.4 | default-source | false_positive | — | 60 | `unpacked/oj-3.17.4`; ext=ext/oj | source_snapshot_inspected | pass | pass | pass | inconclusive |
| sqlite3 | 2.9.5 | sqlite3-system-libraries | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/sqlite3-2.9.5`; ext=ext/sqlite3 | not_present_in_snapshot | inconclusive | inconclusive | not_run | not_run |
| nio4r | 2.7.5 | default-source | no_candidate | c / needs_more_evidence | 0 | `unpacked/nio4r-2.7.5`; ext=ext/nio4r | not_present_in_snapshot | pass | pass | pass | fail |
| pg | 1.6.3 | pg-native-source | no_candidate | c / needs_more_evidence | 0 | `unpacked/pg-1.6.3`; ext=ext | not_present_in_snapshot | inconclusive | inconclusive | not_run | not_run |
| mysql2 | 0.5.7 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/mysql2-0.5.7`; ext=ext/mysql2 | not_present_in_snapshot | pass | pass | pass | inconclusive |
| http_parser.rb | 0.8.1 | default-source | false_positive | — | 23 | `unpacked/http_parser.rb-0.8.1`; ext=ext/ruby_http_parser | generated_not_reproduced | pass | pass | pass | pass |
| stackprof | 0.2.28 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/stackprof-0.2.28`; ext=ext/stackprof | not_present_in_snapshot | pass | pass | pass | pass |
| yajl-ruby | 1.4.3 | default-source | no_candidate | a0 / scoped_no_candidate | 0 | `unpacked/yajl-ruby-1.4.3`; ext=ext/yajl | source_snapshot_inspected | pass | pass | pass | pass |
| nkf | 0.3.0 | default-source | false_positive | — | 2 | `unpacked/nkf-0.3.0`; ext=ext/nkf | textual_include | pass | pass | pass | inconclusive |

## Recorded verification evidence

These are local x86_64 / Ruby evidence records. They do not establish AArch64 behavior. Build, extension load, and upstream-suite claims remain separate; an identical control/rubycc suite failure is recorded as `inconclusive`, never as a pass.

### json 2.21.1

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-control-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — control suite: 603 tests, 3425 assertions, 0 failures, 0 errors; rubycc suite: 603 tests, 3425 assertions, 0 failures, 0 errors

### msgpack 1.8.3

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-control-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — control suite: 455 examples, 0 failures, 1 pending; rubycc suite: 455 examples, 0 failures, 1 pending

### bigdecimal 4.1.2

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-control-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — control suite: 265 tests, 8267 assertions, 0 failures, 0 errors, 11 omissions; rubycc suite: 265 tests, 8267 assertions, 0 failures, 0 errors, 11 omissions

### date 3.5.1

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-control-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — control suite: 143 tests, 162593 assertions, 0 failures, 0 errors; rubycc suite: 143 tests, 162593 assertions, 0 failures, 0 errors

### racc 1.8.1

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-control-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — control suite: 71 tests, 319 assertions, 0 failures, 0 errors; rubycc suite: 71 tests, 319 assertions, 0 failures, 0 errors

### redcarpet 3.6.1

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-control-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — control suite: 136 tests, 206 assertions, 0 failures, 0 errors; rubycc suite: 136 tests, 206 assertions, 0 failures, 0 errors

### digest 3.2.1

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 98 tests, 215 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications; rubycc suite: 98 tests, 215 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications

### erb 6.0.1.1

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 48 tests, 143 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications; rubycc suite: 48 tests, 143 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications

### etc 1.4.6

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 18 tests, 589 assertions, 0 failures, 0 errors, 0 pendings, 2 omissions, 0 notifications; rubycc suite: 18 tests, 589 assertions, 0 failures, 0 errors, 0 pendings, 2 omissions, 0 notifications

### io-console 0.8.2

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 28 tests, 109 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications; rubycc suite: 28 tests, 109 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications

### io-nonblock 0.3.2

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 2 tests, 8 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications; rubycc suite: 2 tests, 8 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications

### io-wait 0.4.0

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 26 tests, 41 assertions, 0 failures, 0 errors, 0 pendings, 1 omissions, 0 notifications; rubycc suite: 26 tests, 41 assertions, 0 failures, 0 errors, 0 pendings, 1 omissions, 0 notifications

### openssl 4.0.2

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-control-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **fail**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — control suite: 592, tests, 4370 assertions, 0 failures, 0 errors; rubycc suite: suite child exited non-zero without a test_unit summary; captured output ended in a process memory map, so the exact crash cause is not established

### prism 1.8.1

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-control-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — control suite: 17306, tests, 1762400 assertions, 0 failures, 0 errors; rubycc suite: 17306, tests, 1762400 assertions, 0 failures, 0 errors

### psych 5.3.1

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 633 tests, 1598 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications; rubycc suite: 633 tests, 1598 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications

### stringio 3.2.0

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-control-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — control suite: 103 tests, 626 assertions, 0 failures, 0 errors; rubycc suite: 103 tests, 626 assertions, 0 failures, 0 errors

### strscan 3.1.6

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-control-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — control suite: 150 tests, 1047 assertions, 0 failures, 0 errors; rubycc suite: 150 tests, 1047 assertions, 0 failures, 0 errors

### zlib 3.2.3

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 97 tests, 540 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications; rubycc suite: 97 tests, 540 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications

### fiddle 1.1.8

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-control-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — control suite: 227, tests, 615 assertions, 0 failures, 0 errors; rubycc suite: 227, tests, 615 assertions, 0 failures, 0 errors

### rbs 3.10.0

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-rbs-control-2026-08-10`, artifact=`data/r10_verification_rbs.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-rbs-rubycc-2026-08-10`, artifact=`data/r10_verification_rbs.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-rbs-rubycc-2026-08-10`, artifact=`data/r10_verification_rbs.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **inconclusive**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-rbs-rubycc-2026-08-10`, artifact=`data/r10_verification_rbs.json` — control suite: 707 tests, 5400 assertions, 22 failures, 7 errors, 0 pendings, 10 omissions, 0 notifications; rubycc suite: 707 tests, 5400 assertions, 22 failures, 7 errors, 0 pendings, 10 omissions, 0 notifications

### syslog 0.3.0

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 32 tests, 234 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications; rubycc suite: 32 tests, 234 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications

### websocket-driver 0.8.2

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 196 examples, 0 failures; rubycc suite: 196 examples, 0 failures

### puma 8.0.2

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-control-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **inconclusive**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — control suite: suite timed out after 900s without a test_unit summary; not converted to skip; rubycc suite: suite exited without a parseable summary; status was not promoted to pass

### google-protobuf 4.35.1

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-control-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated rubycc build state: pass; gem_make.out:rmake (overwritten by later extension; recipe-specific exception); Makefile:CC=rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — control suite: 328, tests, 532032 assertions, 0 failures, 0 errors; rubycc suite: 328, tests, 577046 assertions, 0 failures, 0 errors

### bootsnap 1.24.6

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-control-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **inconclusive**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — control suite: suite exited without a parseable summary; status was not promoted to pass; rubycc suite: suite exited without a parseable summary; status was not promoted to pass

### oj 3.17.4

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-control-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **inconclusive**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — control suite: 627, tests, 9566 assertions, 7 failures, 8 errors; rubycc suite: 627, tests, 9584 assertions, 1 failures, 3 errors

### sqlite3 2.9.5

- `control`: **inconclusive**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4d-control-2026-08-10`, artifact=`data/r10_verification_m4d.json` — isolated control build state: inconclusive; gem install failed during extconf; mkmf.log: sqlite3.h not found; mkmf.log: pkg-config for sqlite3 not found
- `rubycc`: **inconclusive**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4d-rubycc-2026-08-10`, artifact=`data/r10_verification_m4d.json` — isolated rubycc build state: inconclusive; RUBYCC=1 gem install failed during extconf; mkmf.log: sqlite3.h not found; mkmf.log: pkg-config for sqlite3 not found

### nio4r 2.7.5

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-control-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **fail**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — control suite: suite child exited non-zero without an RSpec summary: symbol lookup error, undefined symbol ev_loop_new; rubycc suite: 112, examples, 0 failures, 0 errors

### pg 1.6.3

- `control`: **inconclusive**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4d-control-2026-08-10`, artifact=`data/r10_verification_m4d.json` — isolated control build state: inconclusive; gem install failed during extconf; mkmf.log: pg_config not found; mkmf.log: pkg-config for libpq not found; mkmf.log: libpq-fe.h not found
- `rubycc`: **inconclusive**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4d-rubycc-2026-08-10`, artifact=`data/r10_verification_m4d.json` — isolated rubycc build state: inconclusive; RUBYCC=1 gem install failed during extconf; mkmf.log: pg_config not found; mkmf.log: pkg-config for libpq not found; mkmf.log: libpq-fe.h not found

### mysql2 0.5.7

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-control-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated rubycc build state: pass; rubycc build completed; suite precondition stopped before final table
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **inconclusive**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — control suite: suite_exec requires Docker container rubycc-mariadb; docker inspect reported it is not running; rubycc suite: suite_exec requires Docker container rubycc-mariadb; docker inspect reported it is not running

### http_parser.rb 0.8.1

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-control-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4b-rubycc-2026-08-10`, artifact=`data/r10_verification_m4b.json` — control suite: 72 examples, 0 failures; rubycc suite: 72 examples, 0 failures

### stackprof 0.2.28

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-control-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc; mkmf.log:rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — control suite: 31 runs, 184 assertions, 0 failures, 0 errors; rubycc suite: 31 runs, 184 assertions, 0 failures, 0 errors

### yajl-ruby 1.4.3

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-control-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4c-rubycc-2026-08-10`, artifact=`data/r10_verification_m4c.json` — control suite: 416 examples, 0 failures; rubycc suite: 416 examples, 0 failures

### nkf 0.3.0

- `control`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-control-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated control build state: pass; no rubycc traces (host cc)
- `rubycc`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — isolated rubycc build state: pass; gem_make.out:rmake; Makefile:CC=rubycc
- `extension_load`: **pass**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — sanity state: control=true, rubycc=true; injected extension load is kept separate from suite state
- `upstream_suite`: **inconclusive**, environment=`glibc x86_64 / ruby 3.4.5`, run=`local-r10-m4a-rubycc-2026-08-10`, artifact=`data/r10_verification_m4a.json` — control suite: 8 tests, 44 assertions, 0 failures, 1 error; rubycc suite: 8 tests, 44 assertions, 0 failures, 1 error

## Zero-finding assessments

- `json 2.21.1`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI parser and generator extensions`, selected=`yes` — The selected JSON extension path has no struct variadic candidate. It does contain va_list forwarding to Ruby formatting helpers, so this is not a claim that all variadic code is absent.
  - source evidence: ext/json/ext/parser/parser.c and ext/json/ext/generator/generator.c are the selected extension sources; va_list wrappers forward to rb_vsprintf and do not extract a struct.
- `msgpack 1.8.3`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI ext/msgpack`, selected=`yes` — The selected MRI extension sources contain no scanner candidate. Platform and endianness branches remain outside this source-only conclusion.
  - source evidence: ext/msgpack/extconf.rb creates msgpack/msgpack from the ext/msgpack C sources; no struct va_arg or struct-by-value variadic call was identified.
- `bigdecimal 4.1.2`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI ext/bigdecimal`, selected=`yes` — The selected BigDecimal extension sources contain no scanner candidate. Builtin, atomic, and CPU-specific probes are not proven by the lexical scan.
  - source evidence: ext/bigdecimal/extconf.rb selects bigdecimal.c and missing.c; missing/dtoa.c is included support code and no target operation was identified.
- `racc 1.8.1`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI ext/racc/cparse`, selected=`yes` — The selected cparse extension has no scanner candidate. The generated Ruby parser is a separate build artifact and has not been regenerated here.
  - source evidence: ext/racc/cparse/extconf.rb creates cparse from cparse.c; the R10 target operation is not present in the C source snapshot.
- `redcarpet 3.6.1`: **b0** (`non_target_variadic_wrapper`), scope=`default-source / MRI ext/redcarpet`, selected=`yes` — The selected extension has va_list/vsnprintf formatting helpers, but no struct-by-value variadic call or struct va_arg. This is recorded as b0 rather than treating zero scanner findings as absence of variadic code.
  - source evidence: ext/redcarpet C sources define bufprintf-style formatting through va_list/vsnprintf; the arguments are formatting scalars/pointers, not struct values.
- `digest 3.2.1`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI digest family extensions`, selected=`yes` — The reviewed digest family extension sources contain no scanner candidate for the selected Linux source path. CommonCrypto and other platform branches are separate profiles.
  - source evidence: The six digest extconf paths select the digest, bubblebabble, md5, rmd160, sha1, and sha2 sources; no target operation was identified in the snapshot.
- `erb 6.0.1.1`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI ext/erb/escape`, selected=`yes` — The selected escape extension has no scanner candidate. Pure Ruby fallback and non-MRI dummy paths are not represented as native proof.
  - source evidence: ext/erb/escape/extconf.rb creates escape from escape.c; no struct variadic operation was identified.
- `etc 1.4.6`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI ext/etc on the reviewed host`, selected=`yes` — The selected etc extension has no scanner candidate. OS-specific generated constants still require a platform build check.
  - source evidence: ext/etc/extconf.rb selects etc.c and generates constdefs.h from system headers; the source snapshot has no target operation.
- `io-console 0.8.2`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI POSIX console extension`, selected=`yes` — The reviewed POSIX console path has no scanner candidate. TTY and Windows implementations are separate execution paths.
  - source evidence: ext/io/console/extconf.rb selects console.c with termios/Windows probes; no target operation was identified in the selected source.
- `io-nonblock 0.3.2`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI POSIX nonblock extension`, selected=`yes` — The selected nonblock extension has no scanner candidate. The result is scoped to the extconf probes used by the reviewed host.
  - source evidence: ext/io/nonblock/extconf.rb selects nonblock.c and probes O_NONBLOCK/F_GETFL/F_SETFL; no target operation was identified.
- `io-wait 0.4.0`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI POSIX wait extension`, selected=`yes` — The selected wait extension has no scanner candidate. OS wait and TTY behavior is not established for every supported libc or platform.
  - source evidence: ext/io/wait/extconf.rb selects wait.c for the reviewed MRI path; no target operation was identified.
- `openssl 4.0.2`: **c** (`needs_more_evidence`), scope=`default-source / MRI ext/openssl with system crypto headers`, selected=`yes` — The ext/openssl snapshot has no scanner candidate, but it contains va_list/Ruby formatting wrappers and depends on OpenSSL version, generated headers, and feature probes. The selected preprocessed source and linked library are not yet recorded.
  - source evidence: ext/openssl/extconf.rb selects the extension sources through system OpenSSL probes; ossl.c contains ordinary va_list forwarding, while the external ABI and generated configuration remain unverified.
  - follow-up: Run the same-profile control/rubycc builds, save mkmf.log/Makefile/extconf.h and linked OpenSSL identity, then rescan selected preprocessed units. (owner=R10 maintainers, due=2026-08-24)
- `prism 1.8.1`: **c** (`needs_more_evidence`), scope=`default-source / MRI ext/prism plus root src and src/util`, selected=`yes` — The scanner's ext-only zero result does not cover all sources selected by ext/prism/extconf.rb. The root Prism sources and packaged/generated headers must be scanned under the actual source list.
  - source evidence: ext/prism/extconf.rb sets $srcs to ext/prism, src, and src/util; src/diagnostic.c and related root sources contain ordinary va_list formatting code outside the original scanner scope.
  - follow-up: Capture the exact $srcs and template/generated-header state, preprocess those units under control/rubycc, and rescan before classifying the profile. (owner=R10 maintainers, due=2026-08-24)
- `psych 5.3.1`: **c** (`needs_more_evidence`), scope=`default-source / MRI psych with system or selected libyaml path`, selected=`yes` — The ext/psych source snapshot has no scanner candidate, but the selected libyaml acquisition path and generated parser/header state are not fixed. A zero result cannot represent all libyaml/profile variants.
  - source evidence: ext/psych/extconf.rb selects psych sources and probes system/source-dir/fallback libyaml; the library identity and generated build configuration are not recorded.
  - follow-up: Run control/rubycc with the same libyaml/profile, record extconf.h/Makefile/DT_NEEDED, and rescan the selected preprocessed extension sources. (owner=R10 maintainers, due=2026-08-24)
- `stringio 3.2.0`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI ext/stringio`, selected=`yes` — The selected MRI StringIO extension has no scanner candidate. Non-MRI dummy paths are outside this profile.
  - source evidence: ext/stringio/extconf.rb selects stringio.c for MRI; no target operation was identified.
- `strscan 3.1.6`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI ext/strscan with bundled Ruby Onig API`, selected=`yes` — The selected MRI StringScanner extension has no scanner candidate. Onig/Ruby API probes still make the result profile-specific.
  - source evidence: ext/strscan/extconf.rb selects strscan.c after Onig/Ruby API probes; no target operation was identified.
- `zlib 3.2.3`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI ext/zlib with system libz`, selected=`yes` — The selected zlib glue source has no scanner candidate. The bundled or alternate libz path is not covered by this profile.
  - source evidence: ext/zlib/extconf.rb selects zlib.c against the reviewed system libz path; no target operation was identified in the gem source.
- `fiddle 1.1.8`: **c** (`needs_more_evidence`), scope=`default-source / MRI ext/fiddle with system libffi`, selected=`yes` — The ext/fiddle snapshot has no scanner candidate, but Fiddle exercises libffi variadic/struct calling behavior and architecture-specific generated headers. The source-only scan cannot close that ABI boundary.
  - source evidence: ext/fiddle/extconf.rb selects the Fiddle C sources and generates/locates libffi target headers; the external libffi ABI and architecture path are not recorded.
  - follow-up: Use the same libffi/header profile in control/rubycc, run struct and variadic Fiddle calls on each target CPU, and retain loader/link evidence. (owner=R10 maintainers, due=2026-08-24)
- `rbs 3.10.0`: **c** (`needs_more_evidence`), scope=`default-source / MRI root src plus ext/rbs_extension`, selected=`yes` — The scanner's ext-only zero result omits the root C sources selected by ext/rbs_extension/extconf.rb. Generated/template/re2c output and root va_list wrappers must be included.
  - source evidence: ext/rbs_extension/extconf.rb sets $srcs to src/**/*.c and ext/rbs_extension/*.c; the original scan did not cover the full selected source list.
  - follow-up: Capture the exact $srcs and generated/template state, preprocess and rescan all selected units under control/rubycc, then classify the profile. (owner=R10 maintainers, due=2026-08-24)
- `syslog 0.3.0`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI POSIX syslog extension`, selected=`yes` — The reviewed POSIX syslog path has no scanner candidate. Windows dummy/API paths are separate profiles.
  - source evidence: ext/syslog/extconf.rb selects syslog.c after POSIX header/library probes; no target operation was identified.
- `websocket-driver 0.8.2`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI websocket mask extension`, selected=`yes` — The selected MRI C mask extension has no scanner candidate. The JRuby Java service is not represented by this native profile.
  - source evidence: ext/websocket-driver/extconf.rb selects websocket_mask.c; no target operation was identified.
- `puma 8.0.2`: **c** (`needs_more_evidence`), scope=`default-source / MRI puma_http11 with optional SSL`, selected=`yes` — The checked-in Ragel parser C is selected, but its generated-source provenance, optional SSL feature gates, and actual preprocessor path are not recorded. A zero lexical result is insufficient for the complete build path.
  - source evidence: ext/puma_http11/extconf.rb builds puma_http11.c, checked-in http11_parser.c, and optional mini_ssl.c; http11_parser.c carries the http11_parser.rl source marker.
  - follow-up: Record the generated parser/Ragel provenance and SSL feature macros, then run control/rubycc extension builds and rescan the selected preprocessed units. (owner=R10 maintainers, due=2026-08-24)
- `bootsnap 1.24.6`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI Linux bootsnap extension`, selected=`yes` — The reviewed Linux bootsnap extension has no scanner candidate. POSIX syscall probes and non-Linux paths remain outside this scoped assessment.
  - source evidence: ext/bootsnap/extconf.rb selects bootsnap.c after POSIX feature probes; no target operation was identified.
- `sqlite3 2.9.5`: **a0** (`scoped_no_candidate`), scope=`sqlite3-system-libraries / ext glue only`, selected=`yes` — For the explicitly selected system-library profile, the sqlite3 Ruby glue sources have no scanner candidate. The bundled/packaged amalgamation path is a different profile and is not covered.
  - source evidence: ext/sqlite3/extconf.rb --enable-system-libraries selects the Ruby glue C sources and links system libsqlite3; rb_scan_args uses VALUE pointers, not struct variadic values.
- `nio4r 2.7.5`: **c** (`needs_more_evidence`), scope=`default-source / MRI nio4r with textual libev include`, selected=`yes` — The scanner's ext inventory does not by itself cover the textual inclusion of libev/ev.c, whose platform/CPU branches select the event backend. The full preprocessed source and architecture path are not recorded.
  - source evidence: ext/nio4r/nio4r_ext.c includes ../libev/ev.c; extconf.rb defines EV_USE_* based on Linux AIO/io_uring/epoll/kqueue probes.
  - follow-up: Preprocess the exact nio4r/libev translation unit under each target profile, rescan it, and run native control/rubycc event-loop/load tests on the relevant CPUs. (owner=R10 maintainers, due=2026-08-24)
- `pg 1.6.3`: **c** (`needs_more_evidence`), scope=`pg-native-source / MRI extension with system libpq`, selected=`yes` — The selected pg extension source has no scanner candidate, but it contains ordinary va_list formatting and generated error-code input, while pg_config/libpq and cross-build branches are profile-sensitive. The exact native source and generated artifact are not yet recorded.
  - source evidence: ext/pg_connection.c defines pg_raise_conn_error(..., format, ...) and forwards va_list to Ruby formatting; extconf.rb has native pg_config/pkg-config and separate --with-cross-build paths.; ext/errorcodes.def is consumed by the extension and its generation/link identity has not been captured.
  - follow-up: Run the native system-libpq profile with the same pg_config in control/rubycc, capture generated errorcodes, Makefile/DT_NEEDED, and rescan selected preprocessed units. (owner=R10 maintainers, due=2026-08-24)
- `mysql2 0.5.7`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI Linux system MySQL/MariaDB client`, selected=`yes` — The reviewed Linux system-client glue path has no scanner candidate. Client version, generated gperf header, and Windows import paths remain separate verification concerns.
  - source evidence: ext/mysql2/extconf.rb selects the client glue and generated encoding header against the system client; no target operation was identified in the gem source.
- `stackprof 0.2.28`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI host profiling extension`, selected=`yes` — The selected stackprof source has no scanner candidate. Atomic, clock, and host feature probes still require profile-specific verification.
  - source evidence: ext/stackprof/extconf.rb selects stackprof.c after host feature probes; no target operation was identified.
- `yajl-ruby 1.4.3`: **a0** (`scoped_no_candidate`), scope=`default-source / MRI ext/yajl`, selected=`yes` — The selected yajl extension sources have no scanner candidate. This does not establish behavior for other Ruby engines or unselected build paths.
  - source evidence: ext/yajl/extconf.rb/Rakefile select the packaged yajl C sources; no target operation was identified.

## Candidate review details

### date 3.5.1

- `date/date_core.c:7397:43:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The two candidates are selected date_core.c calls, but c is a char and FIX2INT(y) - s is an integer expression. Neither argument is a struct/union value or struct va_arg operation.
  - source evidence: date/date_core.c:7397 passes scalar c and integer FIX2INT(y) - s to snprintf; no aggregate argument is present.
- `date/date_core.c:7397:46:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The two candidates are selected date_core.c calls, but c is a char and FIX2INT(y) - s is an integer expression. Neither argument is a struct/union value or struct va_arg operation.
  - source evidence: date/date_core.c:7397 passes scalar c and integer FIX2INT(y) - s to snprintf; no aggregate argument is present.

### google-protobuf 4.35.1

- `google/protobuf_c/ruby-upb.c:2268:6:va_list_wrapper`: **false_positive**, selected=`yes` — This is va_list forwarding/declaration plumbing, not a struct/union va_arg or aggregate variadic argument.
  - source evidence: google/protobuf_c/ruby-upb.c:2268 declares or forwards va_list; no struct value is extracted.
- `google/protobuf_c/ruby-upb.c:2276:6:va_list_wrapper`: **false_positive**, selected=`yes` — This is va_list forwarding/declaration plumbing, not a struct/union va_arg or aggregate variadic argument.
  - source evidence: google/protobuf_c/ruby-upb.c:2276 declares or forwards va_list; no struct value is extracted.
- `google/protobuf_c/ruby-upb.c:3414:72:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:3414:81:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:3415:59:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:3426:70:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:3426:79:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:4024:81:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:4062:81:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:4159:77:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5100:36:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5483:36:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5486:36:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5489:43:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5492:43:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5518:36:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5521:36:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5524:36:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5527:36:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5743:39:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5745:45:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5757:39:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:5759:45:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:10770:63:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:11404:67:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:11445:76:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:11460:78:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:11561:49:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:12155:70:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:12250:33:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:12282:43:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:13119:60:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:15249:41:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:15251:41:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:15253:41:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:15255:41:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:15257:37:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.c:15259:38:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — The selected ruby-upb.c/ruby-upb.h candidates are either va_list forwarding wrappers or variadic formatting calls whose arguments are scalar fields, pointers, strings, and format macros. No struct/union object is passed by value and no va_arg extracts a struct/union value.
  - source evidence: google/protobuf_c/ruby-upb.c:2268/2276 and ruby-upb.h:5502/5504/15144 are va_list plumbing, not struct va_arg.; The formatting candidates pass d->line, msg, status.msg, StringView data/size, numeric union members, and enum/string pointers; UPB_STRINGVIEW_ARGS expands to scalar data/size arguments.
- `google/protobuf_c/ruby-upb.h:5502:6:va_list_wrapper`: **false_positive**, selected=`yes` — This is va_list forwarding/declaration plumbing, not a struct/union va_arg or aggregate variadic argument.
  - source evidence: google/protobuf_c/ruby-upb.h:5502 declares or forwards va_list; no struct value is extracted.
- `google/protobuf_c/ruby-upb.h:5504:6:va_list_wrapper`: **false_positive**, selected=`yes` — This is va_list forwarding/declaration plumbing, not a struct/union va_arg or aggregate variadic argument.
  - source evidence: google/protobuf_c/ruby-upb.h:5504 declares or forwards va_list; no struct value is extracted.
- `google/protobuf_c/ruby-upb.h:15144:16:va_list_wrapper`: **false_positive**, selected=`yes` — This is va_list forwarding/declaration plumbing, not a struct/union va_arg or aggregate variadic argument.
  - source evidence: google/protobuf_c/ruby-upb.h:15144 declares or forwards va_list; no struct value is extracted.

### oj 3.17.4

- `oj/dump.c:759:69:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:759:78:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:759:86:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:759:94:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:759:103:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:759:111:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:763:74:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:764:39:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:765:38:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:766:38:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:767:39:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:768:38:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:782:35:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:782:44:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:782:52:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:782:60:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:782:69:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:782:77:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:791:35:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:791:44:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:791:52:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:791:60:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:791:69:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/dump.c:791:77:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:254:66:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:255:31:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:256:30:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:257:30:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:258:31:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:259:30:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:266:65:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:266:74:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:266:82:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:266:90:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:266:99:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:266:107:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:269:70:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:270:35:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:271:34:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:272:34:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:273:35:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:274:34:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:288:35:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:288:44:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:288:52:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:288:60:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:288:69:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:288:77:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:297:35:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:297:44:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:297:52:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:297:60:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:297:69:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/rails.c:297:77:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/wab.c:211:58:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/wab.c:212:27:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/wab.c:213:26:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/wab.c:214:26:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/wab.c:215:27:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.
- `oj/wab.c:216:26:struct_argument_to_variadic_candidate`: **false_positive**, selected=`yes` — All 60 selected oj calls pass scalar time fields, integer casts, or scalar timezone/nanosecond values to sprintf. The containing ti object is not passed as an aggregate.
  - source evidence: oj/dump.c, oj/rails.c, and oj/wab.c pass ti.year/mon/day/hour/min/sec, tzsign/tzhour/tzmin, and nsec; each is a scalar member or cast.

### http_parser.rb 0.8.1

- `ruby_http_parser/vendor/http-parser-java/test.c:1988:35:va_arg_struct_or_union`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser-java/test.c:2012:35:va_arg_struct_or_union`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser-java/test.c:2590:42:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser-java/test.c:2590:56:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser-java/test.c:2598:14:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser-java/test.c:2599:33:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser-java/test.c:2600:33:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser-java/test.c:2601:33:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/contrib/url_parser.c:10:42:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/contrib/url_parser.c:10:56:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/contrib/url_parser.c:18:14:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/contrib/url_parser.c:19:33:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/contrib/url_parser.c:20:33:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/contrib/url_parser.c:21:33:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/test.c:2668:35:va_arg_struct_or_union`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/test.c:2692:35:va_arg_struct_or_union`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/test.c:3322:42:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/test.c:3322:56:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/test.c:3330:14:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/test.c:3331:33:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/test.c:3332:33:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/test.c:3333:33:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.
- `ruby_http_parser/vendor/http-parser/test.c:3689:73:struct_argument_to_variadic_candidate`: **false_positive**, selected=`no` — All 23 candidates are in vendored test/contrib programs, not the ruby_http_parser extension translation unit. The va_arg type is struct message * (a pointer), and the printf/fprintf arguments are scalar fields or pointers; none is struct-by-value or struct va_arg.
  - source evidence: ruby_http_parser/vendor/http-parser*/test.c and contrib/url_parser.c are auxiliary source paths; ext/ruby_http_parser/ruby_http_parser.c is the extension entry path.; va_arg(ap, struct message *) extracts a pointer to a struct, not a struct value; u->field_set/port/field_data members are scalar values or pointers.

### nkf 0.3.0

- `nkf/nkf-utf8/nkf.c:1169:22:struct_argument_to_variadic_candidate`: **false_positive**, selected=`preprocessor_inactive` — The selected nkf-utf8 source passes a FILE pointer, format/string pointers, and scalar option data to fprintf. The scanner's struct shape is a member/macro heuristic and does not identify a struct value or struct va_arg.
  - source evidence: ext/nkf/nkf.c defines PERL_XS before including nkf-utf8/nkf.c; the candidate blocks at nkf-utf8/nkf.c:1169 and :6794 are excluded by the active preprocessor conditions.; Even in the standalone source, the fprintf arguments are FILE*/char*/scalar values rather than a struct value.
- `nkf/nkf-utf8/nkf.c:6794:53:struct_argument_to_variadic_candidate`: **false_positive**, selected=`preprocessor_inactive` — The selected nkf-utf8 source passes a FILE pointer, format/string pointers, and scalar option data to fprintf. The scanner's struct shape is a member/macro heuristic and does not identify a struct value or struct va_arg.
  - source evidence: ext/nkf/nkf.c defines PERL_XS before including nkf-utf8/nkf.c; the candidate blocks at nkf-utf8/nkf.c:1169 and :6794 are excluded by the active preprocessor conditions.; Even in the standalone source, the fprintf arguments are FILE*/char*/scalar values rather than a struct value.
