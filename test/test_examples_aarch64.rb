# frozen_string_literal: true

require_relative "test_helper"
require_relative "test_examples"
require_relative "test_c_suite_aarch64"

# Builds every sample program under examples/ for aarch64 as well, comparing
# exit status and stdout against the cross gcc under qemu — the aarch64 half of
# TestExamples.
#
# The samples are shaped differently from the c-testsuite cases (they are
# ordinary programs written against the libc rubycc ships headers for, rather
# than minimal conformance probes), so running them here covers ground the suite
# does not, at a fraction of its cost. As there, a sample the aarch64 backend
# cannot lower yet is named in PENDING with the construct that stops it, so the
# list is a work item rather than a silent gap.
#
# The whole file skips on a host without the cross toolchain.
class TestExamplesAArch64 < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  EXAMPLE_SOURCES = TestExamples::EXAMPLE_SOURCES

  CROSS_SYSTEM_INCLUDE_PATHS = TestCSuiteAArch64::CROSS_SYSTEM_INCLUDE_PATHS

  # Samples resting on an M4 A4 feature the aarch64 backend has yet to grow.
  # Each builds and runs on x86-64 today; the reason is the backend's own
  # UnsupportedError message.
  PENDING = {
    "step23_sum" => "A4: variadic functions",
    "step24_floats" => "A4: variadic functions",
    "step28_extensions" => "A4: alloca",
    "step28_wideint" => "A4: 128-bit multiply",
    "step41_freestanding" => "A4: variadic functions",
    "step44_builtins" => "A4: bit-scan builtins"
  }.freeze

  EXAMPLE_SOURCES.each do |path|
    basename = File.basename(path, ".c")

    define_method("test_example_aarch64_#{basename}") do
      run_example(path, basename)
    end
  end

  private

  def run_example(path, basename)
    if (reason = PENDING[basename])
      skip reason
      return
    end

    skip_unless_aarch64_toolchain
    unless File.directory?(TestCSuiteAArch64::CROSS_SYSROOT_INCLUDE_DIR)
      skip "aarch64 libc headers (#{TestCSuiteAArch64::CROSS_SYSROOT_INCLUDE_DIR}) are not installed"
    end

    assert_equal build_and_run_with_cross_gcc(path), build_and_run_with_rubycc(path),
                 "rubycc and the cross gcc disagree on [exit status, stdout] for #{basename}"
  end

  # The sample is compiled under its own path (not a copy in a temp dir) so a
  # quote #include resolves against its directory and __FILE__ reads the same
  # as it does for gcc, which is handed the same path.
  def build_and_run_with_rubycc(path)
    in_tmpdir do |dir|
      object_path = File.join(dir, "example.o")
      binary = Rubycc::Compiler.new.compile(
        File.read(path), filename: path, target: "aarch64",
        include_paths: CROSS_SYSTEM_INCLUDE_PATHS, system_includes: false
      )
      File.binwrite(object_path, binary)
      link_and_run_aarch64(object_path)
    end
  end

  def build_and_run_with_cross_gcc(path)
    in_tmpdir do |dir|
      object_path = File.join(dir, "example.o")
      stdout_and_stderr, status = Open3.capture2e(AArch64ExecutionHelper::CROSS_GCC, "-c",
                                                  "-o", object_path, path)
      unless status.success?
        raise "#{AArch64ExecutionHelper::CROSS_GCC} failed to compile #{path} " \
              "(exit #{status.exitstatus}):\n#{stdout_and_stderr}"
      end

      link_and_run_aarch64(object_path)
    end
  end
end
