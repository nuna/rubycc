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

  # Skips the calling test unless the cross toolchain is installed.
  def skip_unless_aarch64_toolchain
    return if AArch64ExecutionHelper.available?

    skip "aarch64 execution toolchain (#{AArch64ExecutionHelper::QEMU}, " \
         "#{AArch64ExecutionHelper::CROSS_GCC}) is not installed"
  end

  # Compiles `c_source` to an aarch64 relocatable object with rubycc. `pic`
  # selects the -fPIC lowering, which routes a reference to a symbol this unit
  # does not define through the GOT instead of forming its address directly.
  def compile_with_rubycc_aarch64(c_source, object_path, pic: false)
    filename = "#{File.basename(object_path, ".*")}.c"
    binary = Rubycc::Compiler.new.compile(c_source, filename: filename, target: "aarch64", pic: pic)
    File.binwrite(object_path, binary)
    object_path
  end

  # Compiles `c_source` to an aarch64 object with the cross gcc, the reference
  # side of every differential test.
  def compile_with_cross_gcc(c_source, object_path, pic: false)
    dir = File.dirname(object_path)
    source_path = File.join(dir, "#{File.basename(object_path, ".*")}.c")
    File.write(source_path, c_source)

    args = [AArch64ExecutionHelper::CROSS_GCC, "-c"]
    args << "-fPIC" if pic
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

    stdout_and_stderr, status = Open3.capture2e(AArch64ExecutionHelper::CROSS_GCC, "-static",
                                                "-o", exe_path, object_path)
    unless status.success?
      raise "#{AArch64ExecutionHelper::CROSS_GCC} failed to link object file " \
            "(exit #{status.exitstatus}):\n#{stdout_and_stderr}"
    end

    stdout, run_status = Open3.capture2(AArch64ExecutionHelper::QEMU, exe_path)
    [run_status.exitstatus, stdout]
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

  # Disassembles `object_path` with the cross objdump and returns the listing.
  def disassemble_aarch64(object_path)
    stdout, stderr, status = Open3.capture3(AArch64ExecutionHelper::CROSS_OBJDUMP, "-d", object_path)
    raise "#{AArch64ExecutionHelper::CROSS_OBJDUMP} failed (exit #{status.exitstatus}):\n#{stderr}" unless status.success?

    stdout
  end
end
