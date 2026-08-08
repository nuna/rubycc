# frozen_string_literal: true

require "open3"

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
  # platform-literal: these are the two SONAME spellings selected from the host libc identity.
  def host_libc_soname
    musl_host? ? "libc.musl-#{host_arch}.so.1" : "libc.so.6" # platform-literal: host SONAME spellings
  end

  def musl_host?
    RbConfig::CONFIG["arch"].to_s.include?("musl")
  end

  def host_arch
    case RbConfig::CONFIG["host_cpu"].to_s
    when "aarch64", "arm64" then "aarch64"
    when "x86_64", "amd64" then "x86_64"
    else RbConfig::CONFIG["host_cpu"].to_s
    end
  end

  def host_libc_path
    return @host_libc_path if defined?(@host_libc_path)

    @host_libc_path = glibc_multiarch_paths.find { |p| File.exist?(p) } || host_libc_path_from_ldconfig
  end

  # The usual glibc multiarch install locations, a concrete DSO oracle for
  # acceptance cases; skip-guarded wherever none of these exist.
  def glibc_multiarch_paths
    multiarch = "#{host_arch}-linux-gnu"
    [
      "/lib/#{multiarch}/libc.so.6", # platform-literal: glibc multiarch candidate path
      "/usr/lib/#{multiarch}/libc.so.6", # platform-literal: glibc multiarch candidate path
      "/lib64/libc.so.6", # platform-literal: glibc generic candidate path
      "/usr/lib/libc.so.6" # platform-literal: glibc generic candidate path
    ]
  end

  def host_libc_nonshared_paths
    multiarch = "#{host_arch}-linux-gnu"
    [
      "/usr/lib/#{multiarch}/libc_nonshared.a",
      "/lib/#{multiarch}/libc_nonshared.a",
      "/usr/lib64/libc_nonshared.a",
      "/usr/lib/libc_nonshared.a"
    ]
  end

  def host_libc_path_from_ldconfig
    out, status = Open3.capture2e("ldconfig", "-p")
    return nil unless status.success?

    # Matches the same glibc SONAME the multiarch search above looks for.
    line = out.lines.find { |l| l =~ /\blibc\.so\.6\b.*=>\s*(\S+)/ }
    line && Regexp.last_match(1)
  rescue Errno::ENOENT
    nil
  end
end
