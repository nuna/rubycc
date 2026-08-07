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
AARCH64_LIBC=/lib/aarch64-linux-gnu/libc.so.6
if [ ! -f "${AARCH64_LIBC}" ]; then
  AARCH64_LIBC=$(ldconfig -p | awk '/libc\.so\.6.*aarch64/{print $NF; exit}')
fi
test -n "${AARCH64_LIBC}" && test -f "${AARCH64_LIBC}"
export RUBYCC_AARCH64_SYSROOT_LIBC="${AARCH64_LIBC}"

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

bundle exec rake test TESTOPTS="--verbose" 2>&1 | tee tmp/ci/aarch64-glibc-suite.log
suite_status=${PIPESTATUS[0]}

ruby tools/ci_check_skips.rb tmp/ci/aarch64-glibc-suite.log 2>&1 \
  | tee tmp/ci/aarch64-glibc-skip-check.log
skip_status=${PIPESTATUS[0]}

RMAKE_ACCEPTANCE=1 ruby tools/m2_acceptance.rb /tmp/rubycc-aarch64-glibc-m2 2>&1 \
  | tee tmp/ci/aarch64-glibc-m2-acceptance.log
m2_status=${PIPESTATUS[0]}

set -e

echo "suite exit: ${suite_status}, skip check exit: ${skip_status}, m2 acceptance exit: ${m2_status}"
[ "${suite_status}" -eq 0 ] && [ "${skip_status}" -eq 0 ] && [ "${m2_status}" -eq 0 ]
