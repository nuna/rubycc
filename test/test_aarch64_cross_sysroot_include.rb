# frozen_string_literal: true

require_relative "test_helper"

# aarch64-cross-sysroot-include-1 (GAPS row BI): with `-target aarch64` on an
# x86-64 host, rubycc used to look for a header it does not bundle in
# /usr/include/aarch64-linux-gnu and then in /usr/include -- the native
# multiarch layout -- so on a host whose aarch64 headers come from a *cross*
# package the first directory did not exist and the second answered with this
# machine's own x86-64 copy. The reproduction the issue records, measured again
# on this host 2026-09-18 (WSL2 / x86-64, Ubuntu 24.04, libc6-dev-arm64-cross
# and gcc-13 cross package installed):
#
#   #include <netdb.h>
#   int main(void) { return 0; }
#
#   aarch64-linux-gnu-gcc -c   ok
#   rubycc -target aarch64 -c  /usr/include/netdb.h:28:1: error:
#                              bits/stdint-uintn.h: No such file or directory
#
# -- x86-64's netdb.h reaching for a bits/ header that lives only in x86-64's
# multiarch directory, which is not (and must not be) on an aarch64 search path.
#
# The fix offers both layouts and searches whichever exists
# (Preprocessor::LIBC_CROSS_SYSROOT_INCLUDE_DIRS), so the two halves of this
# file are: the search path's shape, which needs no toolchain, and what a real
# cross compile now resolves and runs, which needs the cross package and skips
# without it (the same guard the rest of the aarch64 suite uses, see
# test/support/aarch64_execution_helper.rb).
class TestAArch64CrossSysrootInclude < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  PP = Rubycc::Preprocess::Preprocessor

  # --- the search path's shape (no toolchain needed) --------------------------

  # Each target offers two candidate directories for the same headers and
  # searches the ones that exist, in multiarch-then-sysroot order, always ahead
  # of /usr/include. Asserting "contains it if and only if it exists" rather
  # than naming this host's answer keeps the test true on a native aarch64 host
  # (where the multiarch directory is the one that exists) and on a host with no
  # cross package at all.
  def test_each_target_searches_whichever_of_its_two_layouts_exists
    PP::LIBC_ARCHS.each do |arch|
      paths = PP.libc_system_include_paths_for(arch)
      multiarch = PP::LIBC_MULTIARCH_INCLUDE_DIRS.fetch(arch)
      sysroot = PP::LIBC_CROSS_SYSROOT_INCLUDE_DIRS.fetch(arch)

      assert_equal multiarch, paths.first, "#{arch}: the multiarch directory must stay first"
      assert_equal "/usr/include", paths.last, "#{arch}: /usr/include must stay last"

      if File.directory?(sysroot)
        assert_equal [multiarch, sysroot, "/usr/include"], paths,
                     "#{arch}: an installed cross sysroot must be searched between the two"
      else
        assert_equal [multiarch, "/usr/include"], paths,
                     "#{arch}: an absent cross sysroot must leave the path as it was"
      end
    end
  end

  # The host target's own path is what every ordinary (non-cross) compile uses,
  # and this change must not have touched it: a native host does not have the
  # cross package for its own architecture installed, so its list is the two
  # entries it has always been.
  def test_host_target_search_path_is_unchanged
    sysroot = PP::LIBC_CROSS_SYSROOT_INCLUDE_DIRS.fetch(HostTarget.name) { nil }
    skip "no known cross sysroot for host CPU #{HostTarget.name.inspect}" unless sysroot
    if File.directory?(sysroot)
      skip "this host has #{sysroot} installed for its own architecture"
    end

    assert_equal [PP::LIBC_MULTIARCH_INCLUDE_DIRS.fetch(HostTarget.name), "/usr/include"],
                 PP.libc_system_include_paths_for(HostTarget.name)
  end

  # The diagnostic that covers the case this fix cannot: a cross compile on a
  # host that has no headers for the target under *either* layout still falls
  # through to this host's own /usr/include, so the "No such file or directory"
  # it eventually reports says which target was being built and where its
  # headers were looked for. It is a pure function of its inputs precisely so
  # this can be asserted on a host where those headers *are* installed.
  def test_absent_target_libc_headers_note_names_both_candidate_directories
    note = PP.absent_target_libc_headers_note("aarch64", "x86_64", false)

    refute_nil note
    assert_includes note, "targets aarch64"
    assert_includes note, "x86_64 host"
    assert_includes note, PP::LIBC_MULTIARCH_INCLUDE_DIRS.fetch("aarch64")
    assert_includes note, PP::LIBC_CROSS_SYSROOT_INCLUDE_DIRS.fetch("aarch64")
  end

  # Nothing is added when the target's headers are installed (the ordinary
  # cross compile, and the one this host runs), nor when the "cross" compile is
  # really a native one -- a non-multiarch native host has neither candidate
  # directory and a /usr/include that is exactly right.
  def test_absent_target_libc_headers_note_is_silent_when_it_would_mislead
    assert_nil PP.absent_target_libc_headers_note("aarch64", "x86_64", true)
    assert_nil PP.absent_target_libc_headers_note("x86_64", "x86_64", false)
  end

  # --- what a cross compile resolves (needs the cross headers) ---------------

  # The resolution itself, read off the preprocessor's own output: every token
  # of `#include <netdb.h>` that came from a file comes from the cross sysroot,
  # and none from this host's /usr/include. This is the half the differential
  # below cannot see -- a compile that read the wrong copy and happened to
  # succeed would still be wrong.
  def test_cross_target_resolves_system_headers_in_the_sysroot
    skip_unless_aarch64_cross_headers

    files = preprocessed_files("aarch64", "#include <netdb.h>\n")

    assert_includes files, "#{AArch64ExecutionHelper::SYSROOT_INCLUDE_DIR}/netdb.h"
    assert_empty files.grep(%r{\A/usr/include/}),
                 "an aarch64 compile read this host's own headers"
  end

  # The host target reads the host's directories exactly as before -- the other
  # side of the same measurement, so a change that redirected every target to a
  # sysroot would fail here.
  def test_host_target_still_resolves_system_headers_in_usr_include
    skip "system libc headers not found (/usr/include/netdb.h missing)" unless File.exist?("/usr/include/netdb.h")

    files = preprocessed_files(HostTarget.name, "#include <netdb.h>\n")

    assert_includes files, "/usr/include/netdb.h"
  end

  # The issue's reproduction, end to end and differentially: rubycc's aarch64
  # object for a program that uses <netdb.h> -- a header rubycc does not bundle,
  # so it can only come from the target's own headers -- must run under qemu
  # with the same output and exit status as the cross gcc's build of the same
  # source. The values printed are the ones that would differ if the wrong
  # architecture's header had been read (before this fix the compile did not get
  # that far: it died inside x86-64's netdb.h).
  NETDB_PROBE = <<~C
    #include <netdb.h>
    #include <stdio.h>
    #include <string.h>
    #include <sys/socket.h>

    int main(void) {
      struct addrinfo hints;
      struct addrinfo *res = 0;

      printf("%zu %zu %zu\\n",
             sizeof(struct addrinfo), sizeof(struct hostent), sizeof(struct servent));
      printf("%d %d %d\\n", NI_MAXHOST, NI_MAXSERV, EAI_NONAME);
      memset(&hints, 0, sizeof(hints));
      hints.ai_family = AF_INET;
      hints.ai_socktype = SOCK_STREAM;
      hints.ai_flags = AI_NUMERICHOST;
      printf("%d\\n", getaddrinfo("127.0.0.1", "80", &hints, &res));
      printf("%d %d\\n", res ? res->ai_family : -1, res ? (int)res->ai_addrlen : -1);
      freeaddrinfo(res);
      printf("%s\\n", gai_strerror(EAI_NONAME));
      return 0;
    }
  C

  def test_netdb_program_matches_cross_gcc
    skip_unless_aarch64_cross_headers

    assert_aarch64_matches_gcc(NETDB_PROBE)
  end

  private

  # The distinct source files the preprocessor read while preprocessing
  # `source` for `target`, as the resulting tokens name them. The preprocessor
  # is built the way Compiler builds it for that target (its own arch macros
  # and bundled libc-arch layer), since a header's own #if branches depend on
  # them; glibc is pinned because the cross toolchain's headers are glibc's.
  def preprocessed_files(target, source)
    entry = Rubycc::Compiler::TARGETS.fetch(target)
    tokens = PP.new(char_unsigned: !entry[:char_signed],
                    arch_macros: entry[:arch_macros],
                    libc_arch: entry[:libc_arch],
                    libc: "glibc")
              .run(source, filename: "probe.c")
    tokens.map(&:filename).uniq
  end
end
