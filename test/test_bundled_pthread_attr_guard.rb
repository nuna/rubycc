# frozen_string_literal: true

require_relative "test_helper"

# bundled-pthread-attr-guard-1 (GAPS row AU): the regression guard for
# issues/bundled-pthread-attr-guard.md, kept as its own file (rather than more
# Specs in test/test_header_abi.rb) because what is under test here is a
# *compile-success* regression against the exact minimal reproduction the
# issue records, not an ABI-value differential (test_header_abi.rb's
# TestHeaderAbi::PTHREAD_ATTR_NETDB_FORWARD/REVERSE Specs already cover that
# side, byte-comparing against the gcc oracle).
#
# glibc typedefs pthread_attr_t in two places -- bits/pthreadtypes.h and
# bits/types/sigevent_t.h (which <netdb.h> reaches under _GNU_SOURCE) -- behind
# the shared guard __have_pthread_attr_t, so only the first one to run actually
# defines the type. rubycc's bundled include/libc/glibc/{x86_64,aarch64}/
# pthread.h did not check that guard before this fix, so whichever of
# <pthread.h> and <netdb.h> ran second re-typedefed pthread_attr_t as a
# *different* type (glibc's "union pthread_attr_t" against this header's
# anonymous union), which C11 6.7p3 does not allow. gcc, which does check the
# guard, built the issue's repro fine; rubycc did not (measured 2026-09-13,
# this host's gcc 13.3 and glibc, both directions of the include order).
class TestBundledPthreadAttrGuard < Minitest::Test
  include ExecutionHelper

  def setup
    skip_unless_x86_64_host
    skip "gcc unavailable (needed as the ABI oracle)" unless tool?("gcc")
    skip "system libc headers not found (/usr/include/stdio.h missing)" unless File.exist?("/usr/include/stdio.h")
  end

  def tool?(name)
    _stdout, _stderr, status = Open3.capture3(name, "--version")
    status.success?
  rescue Errno::ENOENT
    false
  end

  # The issue's own minimal reproduction, verbatim: <pthread.h> then <netdb.h>
  # under _GNU_SOURCE. Both the gcc oracle and rubycc must compile it.
  PTHREAD_THEN_NETDB = <<~C
    #define _GNU_SOURCE 1
    #include <pthread.h>
    #include <netdb.h>
    int v(void) { return 0; }
  C

  # The include order reversed: <netdb.h> then <pthread.h>. Before this fix,
  # this direction failed too, but from a different line (rubycc's own
  # pthread.h re-typedefing pthread_attr_t after <netdb.h>'s sigevent_t.h had
  # already forward-declared it), since neither header checked the guard.
  # Pinning both orders here follows the same discipline
  # test_header_abi.rb's SIGSET_SELECT_FIRST/SIGSET_SIGNAL_FIRST Specs already
  # apply to the sigset_t collision Step 147 fixed (docs/development/STEPS.md).
  NETDB_THEN_PTHREAD = <<~C
    #define _GNU_SOURCE 1
    #include <netdb.h>
    #include <pthread.h>
    int v(void) { return 0; }
  C

  def test_pthread_then_netdb_compiles_with_gcc
    in_tmpdir do |dir|
      compile_with_gcc(PTHREAD_THEN_NETDB, File.join(dir, "forward_gcc.o"))
    end
  end

  def test_pthread_then_netdb_compiles_with_rubycc
    in_tmpdir do |dir|
      compile_with_rubycc(PTHREAD_THEN_NETDB, File.join(dir, "forward_rubycc.o"))
    end
  end

  def test_netdb_then_pthread_compiles_with_gcc
    in_tmpdir do |dir|
      compile_with_gcc(NETDB_THEN_PTHREAD, File.join(dir, "reverse_gcc.o"))
    end
  end

  def test_netdb_then_pthread_compiles_with_rubycc
    in_tmpdir do |dir|
      compile_with_rubycc(NETDB_THEN_PTHREAD, File.join(dir, "reverse_rubycc.o"))
    end
  end

  # pthread_attr_t is completed as a real (non-pointer) object here, not just
  # referenced through a pointer -- the case a forward-declaration-only fix
  # would still get wrong (see the header's own comment on why the tag's body
  # is completed in a statement separate from the typedef). sigev_notify_
  # attributes is the exact field bits/types/sigevent_t.h's forward
  # declaration exists for: a pointer to pthread_attr_t inside struct sigevent.
  def test_pthread_attr_t_is_a_complete_type_after_both_headers
    source = <<~C
      #define _GNU_SOURCE 1
      #include <pthread.h>
      #include <netdb.h>
      #include <stdio.h>
      int main(void) {
        pthread_attr_t attr;
        struct sigevent sev;
        sev.sigev_notify_attributes = &attr;
        printf("%zu %zu\\n", sizeof(attr), sizeof(sev));
        return pthread_attr_init(&attr);
      }
    C
    in_tmpdir do |dir|
      gcc_obj = compile_with_gcc(source, File.join(dir, "complete_gcc.o"))
      gcc_status, gcc_out = link_and_run(gcc_obj)
      assert_equal 0, gcc_status, "gcc oracle exited #{gcc_status}"

      rubycc_obj = compile_with_rubycc(source, File.join(dir, "complete_rubycc.o"))
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)
      assert_equal 0, rubycc_status, "rubycc exited #{rubycc_status}"
      assert_equal gcc_out, rubycc_out, "rubycc output differs from gcc"
    end
  end
end

# The aarch64 counterpart, checked against a hand-written stand-in for the
# colliding declaration rather than the real <netdb.h>: rubycc's aarch64
# system-header search cannot resolve <netdb.h> (or any header rubycc does not
# bundle) at all on the aarch64-linux-gnu cross toolchain this repository's CI
# installs -- rubycc's search for the aarch64 target expects the native
# multiarch layout (/usr/include/aarch64-linux-gnu + /usr/include, see
# Rubycc::Preprocess::Preprocessor::LIBC_MULTIARCH_INCLUDE_DIRS), but the cross
# package (installed on every push's *default* x86-64 runner,
# .github/workflows/test.yml, not only a developer sandbox) keeps its own
# sysroot at /usr/aarch64-linux-gnu/include instead, so
# /usr/include/aarch64-linux-gnu does not exist there and the preprocessor
# falls through to the host's own x86-64 /usr/include/netdb.h, which then
# fails to find the x86-64-only bits/stdint-uintn.h it needs (measured
# 2026-09-14). That is a pre-existing gap in how rubycc's default aarch64
# system search path relates to this Debian cross-toolchain layout, unrelated
# to the header fix this file guards -- so, like
# test_header_abi.rb's TestHeaderAbiAarch64#test_pthread_attr_guard_forward/
# reverse_abi_matches_cross_gcc, this checks the actual mechanism instead of
# one specific header that uses it: a hand-written stand-in for glibc's own
# pthread_attr_t forward declaration (the same guarded typedef
# bits/types/sigevent_t.h and bits/pthreadtypes.h each carry -- not copied
# from either file, since the guard name and the "typedef a forward-declared
# tag" shape are the shared ABI convention itself, not a creative expression;
# R11 / docs/reference/HEADER-LICENSING.md #4, the same reasoning Step 147
# already applied to __sigset_t).
class TestBundledPthreadAttrGuardAarch64 < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  def setup
    skip_unless_aarch64_toolchain
  end

  STAND_IN = <<~C.chomp
    #ifndef __have_pthread_attr_t
    typedef union pthread_attr_t pthread_attr_t;
    # define __have_pthread_attr_t 1
    #endif
  C

  # <pthread.h> first, then the stand-in -- mirrors
  # TestBundledPthreadAttrGuard's PTHREAD_THEN_NETDB order.
  def test_pthread_then_stand_in_compiles
    source = build_source("#include <pthread.h>\n#{STAND_IN}")
    assert_compiles(source, "forward")
  end

  # The stand-in first, then <pthread.h> -- mirrors NETDB_THEN_PTHREAD.
  def test_stand_in_then_pthread_compiles
    source = build_source("#{STAND_IN}\n#include <pthread.h>")
    assert_compiles(source, "reverse")
  end

  private

  def build_source(preamble)
    <<~C
      #define _GNU_SOURCE 1
      #{preamble}
      int v(void) { return 0; }
    C
  end

  def assert_compiles(source, order)
    in_tmpdir do |dir|
      compile_with_cross_gcc(source, File.join(dir, "#{order}_gcc.o"))
      compile_with_rubycc_aarch64(source, File.join(dir, "#{order}_rubycc.o"), libc: "glibc")
    end
  end
end
