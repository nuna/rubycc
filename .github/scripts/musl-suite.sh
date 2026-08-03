#!/bin/sh
# Container entry point for the `musl` job in .github/workflows/weekly.yml.
# Invoked as
#
#   docker run --rm -v "$PWD":/w -w /w ruby:4.0-alpine /w/.github/scripts/musl-suite.sh
#
# It lives in a file rather than an inline `run:` block for two reasons: the
# nested quoting of a `docker run ... sh -c '...'` one-liner is unreadable, and
# a file can be checked with `sh -n` outside CI. This is CI scaffolding only --
# rubycc itself still never shells out, and nothing here runs as part of
# `rake test`.
#
# Two phases run in one container so a single (slow) job answers both open
# questions: does the suite pass on musl, and does `RUBYCC=1 gem install`
# produce a working .so there. Phase 1's failure does not skip phase 2 -- the
# point of the run is to collect evidence, not to stop at the first problem --
# but the script exits non-zero if either phase failed.
set -eu

# build-base brings gcc, make and musl-dev. The differential tests call gcc
# unconditionally (docs/CI.md), and on Alpine that gcc targets musl, which is
# the entire point of this job: the reference implementation the suite compares
# rubycc against is a musl toolchain rather than a glibc one. libffi-dev is for
# the fiddle gem the tests dlopen generated .so files with. zlib-dev and
# yaml-dev are the host libraries zlib's and psych's extconf probe for; they are
# installed even though neither gem is in the list below, so that a probe that
# should succeed is not reported as a musl difference when it is really a
# missing package.
#
# There is no packaged aarch64-linux-musl cross toolchain, so the aarch64
# differential tests skip here by design -- see the job's note on why
# tools/ci_check_skips.rb is not run.
apk add --no-cache build-base binutils pkgconf git tar libffi-dev zlib-dev yaml-dev

# The checkout is bind-mounted from the host, so its owner does not match the
# container's root and git refuses to read the repository without this.
git config --global --add safe.directory /w

mkdir -p tmp/ci

bundle install --jobs 4 --retry 3

# Prove the run was on musl rather than merely intended to be: RbConfig's arch
# triplet is what MRI itself uses to tell a musl build from a glibc one, and it
# is also what tools/verify_gem_tests.rb reads to label its records.
{
  ruby -e 'puts "ruby arch: #{RbConfig::CONFIG["arch"]}"'
  echo "gcc target: $(gcc -dumpmachine)"
} | tee tmp/ci/musl-arch.log

# --- phase 1: rubycc's own suite ------------------------------------------
#
# Alpine's /bin/sh is busybox ash, which has no dependable `set -o pipefail`,
# so the exit status is carried out of the pipeline through a file. Streaming
# the log matters here: this job runs for the better part of an hour and a
# silent pipe would leave no way to see where it stopped.
{
  bundle exec rake test TESTOPTS="--verbose" 2>&1
  echo "$?" >tmp/ci/rake-status
} | tee tmp/ci/test-musl.log
suite_status=$(cat tmp/ci/rake-status)

# --- phase 2: gem install on musl -----------------------------------------
#
# Three gems, not all eighteen: the question this phase answers is whether the
# toolchain works at all on musl, and that is answered by the first gem. The
# other two are there because they exercise different shapes (io-wait has no
# extconf probes at all, stringio and json do), and because data/verified_gems.json
# has never held a musl record for any gem -- docs/GAPS.md section 3.
#
# VERIFY_STEP decides whether this is a recording run or a regression run,
# because the tool requires --step N with --update (the number goes into the
# recorded evidence, and a scheduled weekly run has no step number to give):
#
#   set    -- a manual dispatch that means to record. --update rewrites
#             data/verified_gems.json in the bind-mounted checkout; the file is
#             uploaded as an artifact and committed from there, so the database
#             is still only ever written by this tool. Nothing here pushes.
#   unset  -- the weekly schedule. Read-only: it answers "do these three still
#             build and pass on musl", which is the regression question.
if [ -n "${VERIFY_STEP:-}" ]; then
  set -- --update --step "${VERIFY_STEP}"
else
  set --
fi
{
  ruby tools/verify_gem_tests.rb "$@" io-wait stringio json 2>&1
  echo "$?" >tmp/ci/verify-status
} | tee tmp/ci/verify-gems-musl.log
verify_status=$(cat tmp/ci/verify-status)

echo "suite exit: ${suite_status}, gem verification exit: ${verify_status}"
[ "${suite_status}" = "0" ] && [ "${verify_status}" = "0" ]
