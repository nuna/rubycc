# frozen_string_literal: true

require "tmpdir"
require "open3"

# AArch64ExecutionHelper is the aarch64 counterpart of ExecutionHelper: it
# compiles a C source string for the aarch64 target, links it with the cross
# toolchain and runs the result under qemu's user-mode emulator, so the
# generated code is checked by an execution oracle rather than by reading the
# instruction words back.
#
# The central assertion is differential: the same source is built twice, once by
# rubycc and once by the cross gcc, and the two runs must agree on both exit
# status and standard output. That compares against a reference implementation
# of the language instead of against hand-computed expectations, so a wrong
# expectation cannot hide a wrong result.
#
# The toolchain is optional. A host without qemu-aarch64 or the cross gcc skips
# these tests rather than failing them, so the suite stays green wherever the
# rest of it runs.
module AArch64ExecutionHelper
  QEMU = "qemu-aarch64"
  CROSS_GCC = "aarch64-linux-gnu-gcc"
  CROSS_OBJDUMP = "aarch64-linux-gnu-objdump"

  # The cross toolchain's sysroot, holding the aarch64 dynamic loader and libc.
  # A dynamically-linked executable rubycc's own linker produces names the
  # on-target loader path (/lib/ld-linux-aarch64.so.1); qemu resolves that (and
  # the shared libraries) beneath this prefix, so the self-linked binary runs
  # without the target's real root filesystem.
  SYSROOT = "/usr/aarch64-linux-gnu"
  SYSROOT_INTERP = "#{SYSROOT}/lib/ld-linux-aarch64.so.1"
  # platform-literal: the aarch64-linux-gnu cross toolchain's sysroot is always glibc
  # (there is no musl variant of this Debian cross package), so this name is a fact of
  # the cross toolchain, not an assumption about a host that could vary.
  SYSROOT_LIBC = "#{SYSROOT}/lib/libc.so.6"

  # The canonical on-target dynamic-loader path a consumer executable names in
  # its PT_INTERP; qemu resolves it beneath QEMU_LD_PREFIX, so it is the target
  # spelling (not the host sysroot path, which qemu would prefix a second time).
  TARGET_INTERP = "/lib/ld-linux-aarch64.so.1"

  # True when every tool the aarch64 execution tests need is on PATH. The probe
  # runs once per process (each tool is exec'd to see whether it exists at all)
  # and the answer is memoized, since every test in the file asks.
  def self.available?
    return @available if defined?(@available)

    @available = [QEMU, CROSS_GCC, CROSS_OBJDUMP].all? { |tool| tool_present?(tool) }
  end

  def self.tool_present?(tool)
    _stdout, _stderr, status = Open3.capture3(tool, "--version")
    status.success?
  rescue Errno::ENOENT
    false
  end

  # True when, in addition to the toolchain, the sysroot supplies the aarch64
  # dynamic loader and libc a rubycc-self-linked (dynamically-linked) executable
  # needs to run under qemu. Memoized alongside #available?.
  def self.self_link_available?
    return @self_link_available if defined?(@self_link_available)

    @self_link_available = available? && File.exist?(SYSROOT_INTERP) && File.exist?(SYSROOT_LIBC)
  end

  # Skips the calling test unless the cross toolchain is installed.
  def skip_unless_aarch64_toolchain
    return if AArch64ExecutionHelper.available?

    skip "aarch64 execution toolchain (#{AArch64ExecutionHelper::QEMU}, " \
         "#{AArch64ExecutionHelper::CROSS_GCC}) is not installed"
  end

  # Skips the calling test unless the sysroot loader/libc are also present, so
  # the rubycc-self-linked dynamic executable can run under qemu.
  def skip_unless_aarch64_self_link
    return if AArch64ExecutionHelper.self_link_available?

    skip "aarch64 self-link sysroot (#{AArch64ExecutionHelper::SYSROOT_INTERP}) is not available"
  end

  # Compiles `c_source` to an aarch64 relocatable object with rubycc. `pic`
  # selects the -fPIC lowering, which routes a reference to a symbol this unit
  # does not define through the GOT instead of forming its address directly.
  # `libc` selects which bundled libc-arch header layer (and __RUBYCC_LIBC_MUSL__
  # branch) the compile sees; nil leaves Rubycc::Compiler's own default (the
  # host's libc) in place, which is glibc on the x86-64/aarch64-cross CI hosts
  # this helper runs on.
  def compile_with_rubycc_aarch64(c_source, object_path, pic: false, libc: nil)
    filename = "#{File.basename(object_path, ".*")}.c"
    kwargs = { filename: filename, target: "aarch64", pic: pic }
    kwargs[:libc] = libc if libc
    binary = Rubycc::Compiler.new.compile(c_source, **kwargs)
    File.binwrite(object_path, binary)
    object_path
  end

  # Compiles `c_source` to an aarch64 object with the cross gcc, the reference
  # side of every differential test.
  def compile_with_cross_gcc(c_source, object_path, pic: false)
    dir = File.dirname(object_path)
    source_path = File.join(dir, "#{File.basename(object_path, ".*")}.c")
    File.write(source_path, c_source)

    # The cross compiler may also default to PIE. Make the BuildProfile's
    # non-PIC mode explicit so the gcc oracle and rubycc receive the same
    # relocation policy on the AArch64 path.
    args = [AArch64ExecutionHelper::CROSS_GCC, "-c", pic ? "-fPIC" : "-fno-pie"]
    stdout_and_stderr, status = Open3.capture2e(*args, "-o", object_path, source_path)
    unless status.success?
      raise "#{AArch64ExecutionHelper::CROSS_GCC} failed to compile source " \
            "(exit #{status.exitstatus}):\n#{stdout_and_stderr}"
    end

    object_path
  end

  # Links `object_path` statically with the cross gcc and runs the result under
  # qemu-aarch64, returning [exit_status, stdout]. Static linking keeps the run
  # independent of where the target's dynamic loader and libraries live on the
  # host.
  def link_and_run_aarch64(object_path)
    dir = File.dirname(object_path)
    exe_path = File.join(dir, "#{File.basename(object_path, ".*")}.out")

    # This helper is the ordinary hosted/non-PIE path. PIE has a dedicated
    # regression test (TestAbiHarnessPieLink), so do not leave the result to
    # the cross compiler's distro-specific default.
    stdout_and_stderr, status = Open3.capture2e(AArch64ExecutionHelper::CROSS_GCC, "-static", "-no-pie",
                                                "-o", exe_path, object_path)
    unless status.success?
      raise "#{AArch64ExecutionHelper::CROSS_GCC} failed to link object file " \
            "(exit #{status.exitstatus}):\n#{stdout_and_stderr}"
    end

    stdout, run_status = Open3.capture2(AArch64ExecutionHelper::QEMU, exe_path)
    [run_status.exitstatus, stdout]
  end

  # Links `object_path` into an executable with rubycc's OWN linker (no cross
  # gcc) and runs it under qemu, returning [exit_status, stdout]. The linker
  # discovers the aarch64 loader/libc through its sysroot defaults; qemu resolves
  # the named on-target loader path beneath QEMU_LD_PREFIX. This is the A5
  # acceptance path: rubycc compiles and links the whole executable itself.
  def link_and_run_aarch64_rubycc(object_path)
    dir = File.dirname(object_path)
    exe_path = File.join(dir, "#{File.basename(object_path, ".*")}.rubycc.out")

    Rubycc::Link::ExecutableLinker.link_to([object_path], exe_path)
    File.chmod(0o755, exe_path)

    stdout, run_status = Open3.capture2(
      { "QEMU_LD_PREFIX" => AArch64ExecutionHelper::SYSROOT },
      AArch64ExecutionHelper::QEMU, exe_path
    )
    [run_status.exitstatus, stdout]
  end

  # Compiles `c_source` for aarch64 with rubycc, links it with rubycc's own
  # linker, and runs the result under qemu; returns [exit_status, stdout].
  def run_aarch64_self_linked(c_source)
    in_tmpdir do |dir|
      object_path = File.join(dir, "test.o")
      compile_with_rubycc_aarch64(c_source, object_path)
      link_and_run_aarch64_rubycc(object_path)
    end
  end

  # The A5 differential assertion: a source rubycc compiles AND links itself must
  # agree, on exit status and standard output, with the cross gcc's reference
  # build of the same source. The reference side keeps the existing static
  # gcc-link path (its result is the language oracle, independent of link mode);
  # only the rubycc side exercises the new self-linker.
  def assert_aarch64_self_link_matches_gcc(c_source)
    skip_unless_aarch64_self_link

    rubycc_status, rubycc_stdout = run_aarch64_self_linked(c_source)
    gcc_status, gcc_stdout = run_aarch64(c_source, compiler: :gcc)

    assert_equal gcc_status, rubycc_status,
                 "exit status mismatch: gcc #{gcc_status}, rubycc self-link #{rubycc_status}"
    assert_equal gcc_stdout, rubycc_stdout, "stdout mismatch (rubycc self-link vs gcc)"
  end

  # Builds `c_source` for aarch64 with the requested compiler, runs it under
  # qemu and returns [exit_status, stdout].
  def run_aarch64(c_source, compiler:, pic: false)
    in_tmpdir do |dir|
      object_path = File.join(dir, "test.o")
      case compiler
      when :rubycc then compile_with_rubycc_aarch64(c_source, object_path, pic: pic)
      when :gcc then compile_with_cross_gcc(c_source, object_path, pic: pic)
      else raise ArgumentError, "unknown compiler: #{compiler.inspect}"
      end

      link_and_run_aarch64(object_path)
    end
  end

  # The differential assertion: rubycc's aarch64 output and the cross gcc's must
  # agree on exit status and standard output for the same source. `pic` builds
  # both sides as position-independent code.
  #
  # One property of the oracle shapes what the sources under test may do: only
  # the low 8 bits of main's return value reach the exit status, so a case that
  # computes a wider value reports it through stdout instead. Since A3 that
  # output can go through printf, string literals being available; before it,
  # putchar(int) was the whole of the stdout oracle.
  def assert_aarch64_matches_gcc(c_source, pic: false)
    skip_unless_aarch64_toolchain

    rubycc_status, rubycc_stdout = run_aarch64(c_source, compiler: :rubycc, pic: pic)
    gcc_status, gcc_stdout = run_aarch64(c_source, compiler: :gcc, pic: pic)

    assert_equal gcc_status, rubycc_status,
                 "exit status mismatch: gcc #{gcc_status}, rubycc #{rubycc_status}"
    assert_equal gcc_stdout, rubycc_stdout, "stdout mismatch"
  end

  # Compiles each [c_source, compiler] pair to its own aarch64 object (rubycc or
  # the cross gcc), links them all statically with the cross gcc, and runs the
  # result under qemu; returns [exit_status, stdout]. Mixing compilers across
  # translation units is what proves the calling convention: a pure register or
  # stack *placement* bug is invisible when one compiler builds both sides (they
  # agree with each other), and only shows when a rubycc caller must meet a gcc
  # callee, or the reverse.
  def link_units_and_run_aarch64(units)
    in_tmpdir do |dir|
      object_paths = units.each_with_index.map do |(c_source, compiler), index|
        object_path = File.join(dir, "unit#{index}.o")
        case compiler
        when :rubycc then compile_with_rubycc_aarch64(c_source, object_path)
        when :gcc then compile_with_cross_gcc(c_source, object_path)
        else raise ArgumentError, "unknown compiler: #{compiler.inspect}"
        end
        object_path
      end

      exe_path = File.join(dir, "exe")
      stdout_and_stderr, status = Open3.capture2e(AArch64ExecutionHelper::CROSS_GCC, "-static", "-no-pie",
                                                  "-o", exe_path, *object_paths)
      unless status.success?
        raise "#{AArch64ExecutionHelper::CROSS_GCC} failed to link object files " \
              "(exit #{status.exitstatus}):\n#{stdout_and_stderr}"
      end

      stdout, run_status = Open3.capture2(AArch64ExecutionHelper::QEMU, exe_path)
      [run_status.exitstatus, stdout]
    end
  end

  # Disassembles `object_path` with the cross objdump and returns the listing.
  def disassemble_aarch64(object_path)
    stdout, stderr, status = Open3.capture3(AArch64ExecutionHelper::CROSS_OBJDUMP, "-d", object_path)
    raise "#{AArch64ExecutionHelper::CROSS_OBJDUMP} failed (exit #{status.exitstatus}):\n#{stderr}" unless status.success?

    stdout
  end

  # Links `object_paths` into an aarch64 shared object with rubycc's OWN linker
  # (Rubycc::Link::SharedLinker) and returns the .so path. Imports (libc
  # functions and data) are resolved against the sysroot libc, the same way the
  # driver supplies -lc; a self-contained object passes no dependency. This is
  # the A5 shared-object acceptance path: rubycc compiles and links the whole
  # `.so` itself, with no cross gcc or cross ld.
  def link_shared_aarch64_rubycc(object_paths, so_path, soname:, needed: [AArch64ExecutionHelper::SYSROOT_LIBC])
    Rubycc::Link::SharedLinker.link_to(object_paths, so_path, needed: needed, soname: soname)
    so_path
  end

  # Builds a consumer executable from `consumer_source` against the rubycc-linked
  # shared object `so_path` with the cross gcc, then runs it under qemu with the
  # `.so` on the library path; returns [exit_status, stdout]. The consumer names
  # the on-target loader and finds the `.so` (and, transitively, libc) beneath
  # QEMU_LD_PREFIX, so the object is loaded by the real dynamic loader and its
  # exports are called — an execution oracle for the `.so`, since the host is
  # x86_64 and cannot dlopen an aarch64 object directly. Only the cross gcc is
  # used to build the reference *consumer*; the `.so` under test is rubycc's own.
  def run_against_aarch64_so(consumer_source, so_path)
    dir = File.dirname(so_path)
    consumer_c = File.join(dir, "consumer.c")
    File.write(consumer_c, consumer_source)
    exe = File.join(dir, "consumer")
    lib = File.basename(so_path).sub(/\Alib/, "").sub(/\.so\z/, "")

    out, status = Open3.capture2e(
      AArch64ExecutionHelper::CROSS_GCC, consumer_c, "-o", exe,
      "-L", dir, "-l#{lib}", "-Wl,-rpath,#{dir}",
      "-Wl,--dynamic-linker=#{AArch64ExecutionHelper::TARGET_INTERP}"
    )
    unless status.success?
      raise "#{AArch64ExecutionHelper::CROSS_GCC} failed to link the consumer " \
            "(exit #{status.exitstatus}):\n#{out}"
    end

    stdout, run_status = Open3.capture2(
      { "QEMU_LD_PREFIX" => AArch64ExecutionHelper::SYSROOT, "LD_LIBRARY_PATH" => dir },
      AArch64ExecutionHelper::QEMU, exe
    )
    [run_status.exitstatus, stdout]
  end
end
