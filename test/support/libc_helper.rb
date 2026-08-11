# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "host_target"

# LibcHelper centralizes the two host-libc facts differential and acceptance
# tests need, so a hard-coded assumption about which C library a host runs
# does not silently leak into individual test files again. This project has
# already lost differential discipline on exactly this axis four times
# (docs/GAPS.md gap I; docs/STEPS.md Steps 194, 197, 206): a probe that
# printed a glibc-only version macro (which musl's own gcc cannot even
# compile), and assertions that hard-coded glibc's SONAME where musl's is
# spelled differently.
#
# `host_libc_soname` answers "what name would libc's own DT_SONAME/soname
# field carry on THIS host", read from RbConfig rather than written in, so an
# assertion meaning "did the link reach libc" does not become "did it reach
# glibc specifically" by accident.
#
# `host_libc_path` locates a real, installed libc image to use as a concrete
# DSO in an acceptance case (linking against it, reading it back). Its search
# is deliberately shaped for one specific C library's install layout: those
# cases want *a* real shared object to exercise resolution/linking/reading
# machinery against, not a claim about which C library the host has, and they
# skip cleanly when the search finds nothing.
module LibcHelper
  # The canonical host-to-SONAME mapping (docs/STEPS.md Step 194); the sole place
  # in the suite allowed to name either spelling -- everything else calls this.
  def host_libc_soname
    musl_host? ? "libc.musl-#{libc_host_target}.so.1" : "libc.so.6" # platform-literal: see method doc above
  end

  def libc_host_target
    HostTarget.name
  end

  def musl_host?
    RbConfig::CONFIG["arch"].to_s.include?("musl")
  end

  def host_libc_path
    return @host_libc_path if defined?(@host_libc_path)

    @host_libc_path = glibc_multiarch_paths.find { |p| host_libc_candidate?(p) } || host_libc_path_from_ldconfig
  end

  # The usual glibc multiarch install locations, a concrete DSO oracle for
  # acceptance cases; skip-guarded wherever none of these exist.
  def glibc_multiarch_paths
    if libc_host_target == "aarch64"
      # platform-literal: Debian multiarch glibc locations used by the
      # target-specific native AArch64 host profile.
      ["/lib/aarch64-linux-gnu/libc.so.6", # platform-literal: Debian multiarch glibc location
       "/usr/lib/aarch64-linux-gnu/libc.so.6", # platform-literal: Debian multiarch glibc location
       "/usr/aarch64-linux-gnu/lib/libc.so.6", # platform-literal: Debian cross-root glibc location
       "/lib64/libc.so.6", # platform-literal: conventional glibc fallback
       "/usr/lib/libc.so.6"] # platform-literal: conventional glibc fallback
    else
      ["/lib/x86_64-linux-gnu/libc.so.6", "/lib64/libc.so.6", "/usr/lib/libc.so.6"] # platform-literal: see method doc above
    end
  end

  def host_libc_path_from_ldconfig
    out, status = Open3.capture2e("ldconfig", "-p")
    return nil unless status.success?

    # platform-literal: matches the same host SONAME the multiarch search above looks for.
    line = out.lines.find { |l| l =~ /\b#{Regexp.escape(host_libc_soname)}\b.*=>\s*(\S+)/ }
    candidate = line && Regexp.last_match(1)
    host_libc_candidate?(candidate) ? candidate : nil
  rescue Errno::ENOENT
    nil
  end

  # A native AArch64 runner may also have a Debian cross-root directory. The
  # path name alone is not sufficient evidence that a DSO is suitable for the
  # host; verify the ELF machine before handing it to the reader/linker tests.
  def host_libc_candidate?(path)
    return false unless path && File.file?(path)

    header = File.binread(path, 20)
    header.byteslice(0, 4) == "\x7FELF".b &&
      header.getbyte(4) == 2 &&
      header.getbyte(5) == 1 &&
      header.byteslice(18, 2).unpack1("S<") == host_elf_machine
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def host_elf_machine
    libc_host_target == "aarch64" ? 183 : 62
  end
end
