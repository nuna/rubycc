#!/usr/bin/env bash
# Container entry point for the aarch64 glibc acceptance job in
# .github/workflows/weekly.yml.
#
# The workflow itself stays on the x86-64 GitHub runner so Actions' Node
# runtime remains usable. This script is executed by an arm64 ruby:4.0 image
# under QEMU, which makes the Ruby process, gcc reference builds, and rubycc
# native-extension loads all run as aarch64 glibc processes.
#
# The existing differential tests normally invoke a cross compiler and QEMU.
# On a native arm64 image those names are redirected to the native compiler and
# a direct executable runner below, so the same aarch64 cases run without
# installing amd64-only cross-toolchain packages inside an arm64 container.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  build-essential \
  binutils \
  pkg-config \
  git \
  curl \
  ca-certificates \
  libffi-dev
rm -rf /var/lib/apt/lists/*

# The checkout is bind-mounted from the host, so Git needs an explicit trust
# entry when the container runs as root.
git config --global --add safe.directory /w

# The helper's constants are loaded by Ruby when the test process starts. On
# this native arm64 image gcc/objdump already produce aarch64 objects, and
# /usr/bin/env is a transparent direct runner for aarch64 executables. The
# loader/libc paths are kept explicit because the helper also passes the libc
# path to rubycc's shared linker.
export RUBYCC_AARCH64_GCC=gcc
export RUBYCC_AARCH64_OBJDUMP=objdump
export RUBYCC_AARCH64_QEMU=/usr/bin/env
export RUBYCC_AARCH64_SYSROOT=/
export RUBYCC_AARCH64_SYSROOT_INTERP=/lib/ld-linux-aarch64.so.1
# The generic execution harness normally follows RbConfig's host CPU. Make the
# native profile explicit as well: every object it compiles and every linker/run
# command it invokes must stay in the same aarch64 world.
export RUBYCC_EXECUTION_TARGET=aarch64
export RUBYCC_EXECUTION_GCC=gcc
export RUBYCC_EXECUTION_RUNNER=/usr/bin/env
AARCH64_LIBC=/lib/aarch64-linux-gnu/libc.so.6
if [ ! -f "${AARCH64_LIBC}" ]; then
  AARCH64_LIBC=$(ldconfig -p | awk '/libc\.so\.6.*aarch64/{print $NF; exit}')
fi
test -n "${AARCH64_LIBC}" && test -f "${AARCH64_LIBC}"
export RUBYCC_AARCH64_SYSROOT_LIBC="${AARCH64_LIBC}"

TEST_SCOPE=${AARCH64_TEST_SCOPE:-full}
case "${TEST_SCOPE}" in
  smoke|full) ;;
  *)
    echo "unsupported AARCH64_TEST_SCOPE=${TEST_SCOPE} (expected smoke or full)" >&2
    exit 2
    ;;
esac

mkdir -p tmp/ci

{
  echo "uname: $(uname -m)"
  ruby -rrbconfig -e 'puts "ruby arch: #{RbConfig::CONFIG["arch"]}"; abort "Ruby is not aarch64" unless RbConfig::CONFIG["host_cpu"].include?("aarch64")'
  echo "gcc target: $(gcc -dumpmachine)"
  gcc --version | head -n 1
  objdump --version | head -n 1
  echo "runner: ${RUBYCC_AARCH64_QEMU}"
  echo "sysroot libc: ${RUBYCC_AARCH64_SYSROOT_LIBC}"
  test -f "${RUBYCC_AARCH64_SYSROOT_INTERP}"
} | tee tmp/ci/aarch64-glibc-environment.log

bundle install --jobs 4 --retry 3

# Run both phases even when the suite fails so a single QEMU job leaves the
# gem-install evidence as well as the regression log. The final status still
# fails the job if either phase is red.
set +e

if [ "${TEST_SCOPE}" = smoke ]; then
  echo "test scope: smoke (nine native aarch64 acceptance tests; M2 is deferred)"
  # Rake's test loader treats the argument after --name as another file. Load
  # the small fixed file set directly so one regex can select one representative
  # test from each acceptance layer without paying for the full suite.
  bundle exec ruby -Ilib:test \
    -e 'files = ARGV.shift(9); files.each { |file| require File.expand_path(file) }' \
    test/test_aarch64_backend.rb \
    test/test_aarch64_execution.rb \
    test/test_aarch64_self_link.rb \
    test/test_aarch64_shared_object.rb \
    test/test_execution_harness.rb \
    test/test_c_suite.rb \
    test/test_ruby_smoke.rb \
    test/test_extension_build.rb \
    test/test_gcc_builtins.rb \
    --name '/test_(prologue_and_epilogue_frame_record|signed_arithmetic|main_return_status|self_contained_exports_run_under_qemu|compound_assignment_mod|c_suite_00101|includes_ruby_h_and_compiles_a_module_init_to_an_object|rubycc_built_extension_loads_and_runs_under_require|bit_scan_matches_gcc)/' \
    --verbose 2>&1 | tee tmp/ci/aarch64-glibc-suite.log
else
  echo "test scope: full"
  bundle exec rake test TESTOPTS="--verbose" 2>&1 | tee tmp/ci/aarch64-glibc-suite.log
fi
suite_status=${PIPESTATUS[0]}

if [ "${TEST_SCOPE}" = smoke ]; then
  CI_MAX_SKIPS=0 CI_MIN_RUNS=9 ruby tools/ci_check_skips.rb \
    tmp/ci/aarch64-glibc-suite.log 2>&1 \
    | tee tmp/ci/aarch64-glibc-skip-check.log
else
  ruby tools/ci_check_skips.rb tmp/ci/aarch64-glibc-suite.log 2>&1 \
  | tee tmp/ci/aarch64-glibc-skip-check.log
fi
skip_status=${PIPESTATUS[0]}

if [ "${TEST_SCOPE}" = smoke ]; then
  echo "M2 acceptance: deferred in smoke scope" | tee tmp/ci/aarch64-glibc-m2-acceptance.log
  m2_status=0
else
  RMAKE_ACCEPTANCE=1 ruby tools/m2_acceptance.rb /tmp/rubycc-aarch64-glibc-m2 2>&1 \
    | tee tmp/ci/aarch64-glibc-m2-acceptance.log
  m2_status=${PIPESTATUS[0]}
fi

set -e

echo "suite exit: ${suite_status}, skip check exit: ${skip_status}, m2 acceptance exit: ${m2_status}"
[ "${suite_status}" -eq 0 ] && [ "${skip_status}" -eq 0 ] && [ "${m2_status}" -eq 0 ]
