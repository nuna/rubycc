# frozen_string_literal: true

require_relative "test_helper"
require_relative "../tools/audit_bundled_headers"

# bundled-headers-coverage-audit-2: the headers this step audited in full
# (tools/audit_bundled_headers.rb) must account for every name glibc's
# same-named header shows under _GNU_SOURCE -- either the bundled header
# provides it, or its top comment lists it as "omitted: NAME -- reason". A name
# glibc adds later, or a line dropped from a comment, fails here rather than as
# the next gem's build error.
class TestBundledHeadersCoverage < Minitest::Test
  A = AuditBundledHeaders

  AUDITED = %w[stdlib.h sched.h termios.h sys/ioctl.h sys/types.h].freeze

  AUDITED.each do |header|
    define_method("test_#{header.gsub(/\W/, "_")}_accounts_for_every_glibc_name") do
      arches = A.available_arches
      skip "no glibc oracle compiler installed" if arches.empty?

      arches.each do |arch|
        result = A.audit(header, arch, guard_probe: false)
        assert_nil result.error, "<#{header}> on #{arch}: #{result.error}"
        assert_empty result.undocumented,
                     "<#{header}> on #{arch}: glibc names neither provided nor listed as omitted"
      end
    end
  end

  # glibc headers rubycc does not bundle, read on top of the bundled ones --
  # the shape GAPS AM (<spawn.h> over the bundled <sched.h>) and AQ
  # (<net/if.h> over the bundled <sys/types.h>) failed in. The first four
  # failed before bundled-headers-coverage-audit-2 (measured 2026-09-14 by the
  # audit's mixing survey); the last six passed before it and failed while a
  # struct __fsid_t sat in the bundled <sys/types.h>, so they guard against
  # an added name that is not a compatible redefinition of glibc's own.
  MIXED_GLIBC_HEADERS = %w[spawn.h net/if.h utmp.h sys/procfs.h
                           aio.h mqueue.h semaphore.h sys/acct.h sys/sem.h net/if_ppp.h].freeze

  def test_glibc_headers_read_over_the_bundled_ones_compile
    skip "x86-64 glibc headers not installed" unless File.exist?("/usr/include/spawn.h") && host_x86_64?

    failures = MIXED_GLIBC_HEADERS.filter_map do |header|
      source = "#define _GNU_SOURCE 1\n#include <#{header}>\nint probe;\n"
      Rubycc::Compiler.new.compile(source, filename: "probe.c", target: "x86_64", libc: "glibc")
      nil
    rescue Rubycc::Error => e
      "<#{header}>: #{e.message.lines.first.strip}"
    end
    assert_empty failures
  end

  # Bundled and glibc headers that define the same type behind a guard glibc
  # shares between its own headers, in both orders (the AU shape). GAPS BL:
  # <netdb.h> reads glibc's union sigval under __USE_GNU; <sys/pidfd.h> reads
  # glibc's siginfo_t. Both pairs failed in both orders before
  # bundled-headers-coverage-audit-2 (measured 2026-09-14) and gcc accepts
  # all four; each unit also touches the shared types, so a guard that hid a
  # definition both sides need would fail here too.
  GUARDED_PAIRS = [%w[signal.h netdb.h], %w[netdb.h signal.h],
                   %w[signal.h sys/pidfd.h], %w[sys/pidfd.h signal.h]].freeze

  def test_bundled_and_glibc_headers_sharing_a_guard_compile_in_either_order
    skip "x86-64 glibc headers not installed" unless File.exist?("/usr/include/netdb.h") && host_x86_64?

    failures = GUARDED_PAIRS.filter_map do |pair|
      next if pair.include?("sys/pidfd.h") && !File.exist?("/usr/include/x86_64-linux-gnu/sys/pidfd.h")

      includes = pair.map { |h| "#include <#{h}>\n" }.join
      body = pair.include?("netdb.h") ? "struct sigevent ev; union sigval v;" : "siginfo_t si; union sigval v;"
      source = "#define _GNU_SOURCE 1\n#{includes}#{body}\nint probe(siginfo_t *s) { return s->si_pid; }\n"
      Rubycc::Compiler.new.compile(source, filename: "probe.c", target: "x86_64", libc: "glibc")
      nil
    rescue Rubycc::Error => e
      "#{pair.join(" then ")}: #{e.message.lines.first.strip}"
    end
    assert_empty failures
  end

  # The seven gaps' own names, which the audit must no longer report missing.
  def test_the_seven_gaps_are_not_missing
    skip "gcc unavailable" unless A.available_arches.include?("x86_64")

    stdlib = A.audit("stdlib.h", "x86_64", guard_probe: false)
    refute_includes stdlib.missing.keys, "getloadavg"                  # AF
    refute_includes stdlib.missing.keys, "qsort_r"                     # AR
    refute_includes stdlib.missing_pulls, "alloca.h"                   # BG
    sched = A.audit("sched.h", "x86_64", guard_probe: false)
    refute_includes sched.missing.keys, "struct sched_param"           # AM
    types = A.audit("sys/types.h", "x86_64", guard_probe: false)
    refute_includes types.reserved_missing, "__caddr_t"                # AQ
    termios = A.audit("termios.h", "x86_64", guard_probe: false)
    assert_empty termios.missing.keys & %w[tcflow TCOOFF TCOON TCIOFF TCION] # BA
    ioctl = A.audit("sys/ioctl.h", "x86_64", guard_probe: false)
    assert_empty ioctl.missing.keys & %w[TIOCMGET TIOCMSET TIOCMBIS TIOCMBIC TIOCM_DTR] # BB
  end

  private

  def host_x86_64?
    RbConfig::CONFIG["host_cpu"].to_s.match?(/x86_64|amd64/)
  end
end
