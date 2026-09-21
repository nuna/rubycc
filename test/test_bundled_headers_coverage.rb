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

  # bundled-headers-core-batch-1 classified the core batch: the string,
  # formatted-I/O, arithmetic and signal headers, plus the four arch-layer
  # headers a C extension reads limits and clocks out of.
  # bundled-headers-io-batch-1 classified the socket, file and process headers
  # from sys/socket.h on; sys/stat.h and sys/select.h are the arch-layer
  # copies, audited on each arch against that arch's own file.
  AUDITED = %w[stdlib.h sched.h termios.h sys/ioctl.h sys/types.h unistd.h
               stdio.h string.h strings.h math.h signal.h assert.h locale.h
               langinfo.h ctype.h errno.h limits.h time.h
               sys/socket.h sys/mman.h sys/wait.h sys/uio.h sys/un.h sys/resource.h
               sys/statfs.h sys/param.h sys/utsname.h netinet/in.h netinet/tcp.h
               arpa/inet.h poll.h dirent.h pwd.h grp.h sys/stat.h sys/select.h].freeze

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

  # The glibc headers the mixing survey found failing under rubycc alone on
  # 2026-09-18 (23 of the 186 it does not bundle) and that
  # glibc-public-headers-mixed-1 fixed. Four causes, each of which a later
  # change could bring back: the bundled headers not pulling in <features.h>,
  # so __BEGIN_DECLS reached nothing (<net/ethernet.h> and eight more); the
  # bundled <sys/types.h> not pulling in <endian.h>/<sys/select.h>, so
  # <netinet/ip.h> declared every bit-field of struct ip twice and
  # <thread_db.h> lost sigset_t; names missing from the bundled <sys/cdefs.h>
  # (<sys/poll.h>, <stdbit.h>) or defined there without the builtin behind
  # them (<error.h>); and gcc's predefined type-name macros being absent
  # (<glob.h>).
  MIXED_GLIBC_HEADERS_FIXED = %w[arpa/nameser.h error.h glob.h net/ethernet.h
                                 net/if_arp.h netinet/in_systm.h netinet/ip.h
                                 netinet/ip_icmp.h netipx/ipx.h obstack.h
                                 stdbit.h stdio_ext.h sys/eventfd.h
                                 sys/fanotify.h sys/poll.h sys/signalfd.h
                                 thread_db.h utmpx.h].freeze

  def test_glibc_headers_read_over_the_bundled_ones_compile
    skip "x86-64 glibc headers not installed" unless File.exist?("/usr/include/spawn.h") && host_x86_64?

    failures = (MIXED_GLIBC_HEADERS + MIXED_GLIBC_HEADERS_FIXED).filter_map do |header|
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

  # bundled-unistd-process-group-1 (GAPS BU): ruby-termios 1.1.0's termios.c
  # calls tcgetpgrp() right after the tcflow() call BA added.
  def test_bundled_unistd_process_group_functions_are_declared
    skip "gcc unavailable" unless A.available_arches.include?("x86_64")

    unistd = A.audit("unistd.h", "x86_64", guard_probe: false)
    assert_empty unistd.missing.keys &
                 %w[tcgetpgrp tcsetpgrp getpgrp setpgid getpgid setsid getsid]
  end

  def test_tcgetpgrp_is_declared
    source = <<~C
      #include <unistd.h>
      int main(void) { return tcgetpgrp(0) == -2; }
    C
    Rubycc::Compiler.new.compile(source, filename: "probe.c", target: "x86_64", libc: "glibc")
  end

  # audit-reserved-public-macros-1 (GAPS BX): the audit used to drop every
  # name starting with "_" + an upper-case letter, so the POSIX macros glibc
  # spells in that space were neither provided nor recorded. _POSIX_VDISABLE
  # is the one a real gem stopped on -- ruby-termios 1.1.0's termios.c:759
  # publishes it as Termios::POSIX_VDISABLE -- and it is now a name the audit
  # counts (the assertion below) as well as one the bundled <unistd.h>
  # defines (the compile).
  def test_bundled_unistd_posix_vdisable_is_defined
    source = <<~C
      #include <unistd.h>
      int main(void) { return _POSIX_VDISABLE; }
    C
    Rubycc::Compiler.new.compile(source, filename: "probe.c", target: "x86_64", libc: "glibc")
  end

  # bundled-headers-core-batch-1: the names in this batch that rubycc rejected
  # before it and gcc accepts. Each one is what a gem's C extension writes:
  # a path buffer's size, the errno POSIX spells ENOTSUP, the unlocked getc a
  # reader loop uses, the float companion of an ISO C99 rounding call, the
  # GNU spelling of the handler type with an si_code to switch on, and ISO
  # C11's own clock read. Measured failing on 2026-09-18 (for example
  # "error: array size must be an integer constant" for PATH_MAX).
  CORE_BATCH_REPROS = {
    "limits.h" => "char abi_buf[PATH_MAX]; int main(void) { return sizeof abi_buf + IOV_MAX + INT_WIDTH; }",
    "errno.h" => "int main(void) { return ENOTSUP; }",
    "stdio.h" => "int main(void) { flockfile(stdin); int c = getc_unlocked(stdin); funlockfile(stdin); return c; }",
    "math.h" => "int main(void) { int q; return (int)lrintf(1.5f) + ilogbf(2.0f) + (int)remquo(4, 2, &q) + (int)j0(1.0); }",
    "signal.h" => "static void h(int s) { (void)s; } int main(void) { sig_t f = h; return (f != 0) + SI_USER + CLD_EXITED + SEGV_MAPERR; }",
    "time.h" => "int main(void) { struct timespec ts; return timespec_get(&ts, TIME_UTC); }",
    "string.h" => "int main(void) { char b[4]; explicit_bzero(b, sizeof b); return b[0]; }"
  }.freeze

  def test_the_core_batch_names_compile
    failures = CORE_BATCH_REPROS.filter_map do |header, body|
      source = "#include <#{header}>\n#{body}\n"
      Rubycc::Compiler.new.compile(source, filename: "probe.c", target: "x86_64", libc: "glibc")
      nil
    rescue Rubycc::Error => e
      "<#{header}>: #{e.message.lines.first.strip}"
    end
    assert_empty failures
  end

  def test_the_reserved_names_a_program_writes_are_audited
    skip "gcc unavailable" unless A.available_arches.include?("x86_64")

    unistd = A.audit("unistd.h", "x86_64", guard_probe: false)
    assert_includes unistd.glibc_own, "_POSIX_VDISABLE",
                    "a name programs write belongs to the measured surface"
    refute_includes unistd.missing.keys, "_POSIX_VDISABLE"
    refute_includes unistd.glibc_own, "_UNISTD_H", "an include guard is not a public name"
  end

  # bundled-headers-io-batch-1: glibc's <arpa/inet.h> includes <netinet/in.h>,
  # its <netinet/in.h> and <netinet/tcp.h> include <sys/socket.h>, and programs
  # lean on that -- each unit below uses a name only the pulled-in header
  # declares. All three compiled under gcc and failed under rubycc before this
  # step (measured 2026-09-18).
  PULLED_IN = {
    "arpa/inet.h" => "struct sockaddr_in sin; int probe(void) { sin.sin_family = AF_INET; return (int) sizeof sin; }",
    "netinet/in.h" => "int probe(void) { socklen_t n = 0; return socket(AF_INET, SOCK_STREAM, 0) + (int) n; }",
    "netinet/tcp.h" => "int probe(int fd) { int one = 1; " \
                       "return setsockopt(fd, SOL_TCP, TCP_NODELAY, &one, (socklen_t) sizeof one); }"
  }.freeze

  def test_socket_headers_pull_in_what_glibc_pulls_in
    failures = PULLED_IN.filter_map do |header, body|
      source = "#define _GNU_SOURCE 1\n#include <#{header}>\n#{body}\n"
      Rubycc::Compiler.new.compile(source, filename: "probe.c", target: "x86_64", libc: "glibc")
      nil
    rescue Rubycc::Error => e
      "<#{header}>: #{e.message.lines.first.strip}"
    end
    assert_empty failures
  end

  private

  def host_x86_64?
    RbConfig::CONFIG["host_cpu"].to_s.match?(/x86_64|amd64/)
  end
end
