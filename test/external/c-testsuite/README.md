# c-testsuite (vendored)

This directory vendors the `single-exec` test cases from
[c-testsuite/c-testsuite](https://github.com/c-testsuite/c-testsuite), a
compiler-agnostic C conformance suite. Snapshot: the `master` branch, vendored
on 2026-07-13.

`single-exec/` mirrors upstream's `tests/single-exec/`: each case is a
`NNNNN.c` source file, an `NNNNN.c.expected` file holding the program's
expected combined stdout+stderr, an `NNNNN.c.tags` file describing the
language dialect it exercises, and (for most cases) an `NNNNN.c.otags` file
recording the case's own provenance and license, per upstream's
`tests/LICENSE` (vendored here as `single-exec/LICENSE`).

`LICENSE` (this directory's top level) is upstream's own MIT license, which
covers the suite's tooling (runners, scripts) but not the individual test
cases — see `single-exec/LICENSE` for how each case's license is determined.

## Harness

`test/test_c_suite.rb` runs every `single-exec/*.c` case as its own Minitest
test method, mirroring the pass criterion of upstream's own
`runners/single-exec/posix` reference runner: compile the source with
rubycc, link the resulting object with the system `gcc` (against `libm`, for
the handful of cases that call math functions), run the binary, and require
both a zero exit status and that its stdout and stderr, combined, are
byte-for-byte identical to `NNNNN.c.expected`.

Cases the current rubycc subset cannot build or run yet are recorded in the
`SKIP` constant in `test/test_c_suite.rb`, each with a one-line reason, so
`rake test` reports them as skips rather than silently omitting them.
