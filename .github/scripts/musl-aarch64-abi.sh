#!/bin/sh
#
# Invoked as `sh <this file>` from the workflow, not by its own shebang: the
# repository has core.filemode=false, so a local `chmod +x` never reaches git
# and the file lands in the container mode 644. That cost a whole weekly run
# once already (docs/STEPS.md Step 198) -- calling the interpreter explicitly
# takes the exec bit out of the equation for good.
# Container entry point for the `musl-aarch64` job in
# .github/workflows/weekly.yml. Invoked as
#
#   docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w \
#     ruby:4.0-alpine /w/.github/scripts/musl-aarch64-abi.sh
#
# It lives in a file for the same two reasons musl-suite.sh does: the nested
# quoting of a `docker run ... sh -c '...'` one-liner is unreadable, and a file
# can be checked with `sh -n` outside CI. This is CI scaffolding only -- rubycc
# itself still never shells out, and nothing here runs as part of `rake test`.
#
# What it measures: the bundled headers' aarch64 layer
# (include/libc/glibc/aarch64/) was written from glibc measurements and carries
# no musl branches, because no aarch64 musl machine has ever been available to
# measure on -- each of those files says so in its own header comment. This job
# is that machine, under qemu. The differential the two test files run is the
# measurement: rubycc's bundled headers against the container's own musl gcc as
# the oracle, both compiled for and run on aarch64. A difference is the answer,
# not an accident, so this script is written to leave every difference in a log
# rather than to go green.
#
# Deliberately NOT the whole suite. Everything here runs under qemu user-mode
# emulation, where the suite takes hours (docs/ROADMAP.md rules it out), and the
# rest of the suite would only re-measure what the x86-64 musl job and the
# aarch64 cross job already cover. Only the two files that probe header ABI run.
set -eu

# build-base is the whole of it: it brings gcc, make and musl-dev, and on Alpine
# that gcc targets musl on this machine -- the oracle both test files compare
# rubycc against. (binutils comes with it; nothing here needs the tools by name.)
#
# No bundler and no libffi-dev, unlike musl-suite.sh: `bundle install` would
# build the fiddle gem from source, which needs libffi-dev and several
# qemu-emulated minutes, and fiddle exists in the Gemfile for the tests that
# dlopen a generated .so -- neither of the two files below does. minitest is the
# only gem they need. It ships with the image as a bundled gem; it is installed
# explicitly anyway so a run cannot fail on that assumption, and it is pure Ruby,
# so installing it compiles nothing.
apk add --no-cache build-base
gem install --no-document minitest

mkdir -p tmp/ci

# Prove the run was on aarch64 *and* on musl rather than merely intended to be.
# Both halves matter here: the point of the job is the combination, and a qemu
# registration that silently did not take would otherwise leave an x86-64 run
# labelled as the aarch64 measurement.
{
  uname -m
  ruby -e 'puts "ruby arch: #{RbConfig::CONFIG["arch"]}, host_cpu: #{RbConfig::CONFIG["host_cpu"]}"'
  echo "gcc target: $(gcc -dumpmachine)"
} | tee tmp/ci/musl-aarch64-arch.log

# Both files below are expected to report differences until the aarch64 headers
# carry musl values, and those differences are what the run is for, so errexit
# is off from here on: an aborted script would throw away the second file's
# half of the answer. Each file's status is captured explicitly instead, the way
# musl-suite.sh carries its phases' statuses (Alpine's /bin/sh is busybox ash,
# which has no dependable `set -o pipefail`, so the status travels in a file).
set +e

# --- the header ABI differential ------------------------------------------
#
# Every Spec in test/test_header_abi.rb, compiled twice -- rubycc against the
# bundled headers, the container's gcc against musl's own -- run on aarch64, and
# diffed byte for byte. A failing case names the header and prints both columns,
# which is the measurement the next step transcribes.
{
  ruby -Ilib -Itest test/test_header_abi.rb --verbose 2>&1
  echo "$?" >tmp/ci/abi-status
} | tee tmp/ci/abi-musl-aarch64.log
abi_status=$(cat tmp/ci/abi-status 2>/dev/null || echo "no-status")

# --- the freestanding headers ---------------------------------------------
#
# The compiler-supplied layer (stddef, stdarg, stdbool, stdalign, float, ...) is
# arch-dependent too -- va_list is a different type on each machine -- and this
# file is its differential against the same gcc.
{
  ruby -Ilib -Itest test/test_freestanding_headers.rb --verbose 2>&1
  echo "$?" >tmp/ci/freestanding-status
} | tee tmp/ci/freestanding-musl-aarch64.log
freestanding_status=$(cat tmp/ci/freestanding-status 2>/dev/null || echo "no-status")

echo "header ABI exit: ${abi_status}, freestanding exit: ${freestanding_status}"
[ "${abi_status}" = "0" ] && [ "${freestanding_status}" = "0" ]
