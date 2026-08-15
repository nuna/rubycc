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
# cannot lower yet would be named in PENDING with the construct that stops it,
# so the list is a work item rather than a silent gap — it is empty as of
# m4/aarch64-alloca-bitscan-2, every sample running on both targets.
#
# The whole file skips on a host without the cross toolchain.
class TestExamplesAArch64 < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  EXAMPLE_SOURCES = TestExamples::EXAMPLE_SOURCES

  CROSS_SYSTEM_INCLUDE_PATHS = TestCSuiteAArch64::CROSS_SYSTEM_INCLUDE_PATHS

  # Samples resting on an IR 6.5 target-specific limitation. Keep the source
  # paths and reasons shared with TestExamples so the native-host and
  # cross-runner paths cannot silently drift apart.
  PENDING = TestExamples::AARCH64_PENDING

  EXAMPLE_SOURCES.each do |path|
    basename = File.basename(path, ".c")

    define_method("test_example_aarch64_#{basename}") do
      run_example(path, basename)
    end
  end

  def test_aarch64_obsolete_example_uses_compatibility_flag
    flags = cross_gcc_compile_args("m5/atomic_type_10_knr_definitions.c")
    assert_includes flags, ExecutionHelper::OBSOLETE_C_FLAGS.first
    refute_includes cross_gcc_compile_args("m5/ordinary_example.c"),
                    ExecutionHelper::OBSOLETE_C_FLAGS.first
  end

  private

  def run_example(path, basename)
    relative_path = path.delete_prefix("#{TestExamples::EXAMPLES_ROOT}/")
    if (reason = PENDING[relative_path])
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
      relative_path = path.delete_prefix("#{TestExamples::EXAMPLES_ROOT}/")
      stdout_and_stderr, status = Open3.capture2e(*cross_gcc_compile_args(relative_path),
                                                  "-o", object_path, path)
      unless status.success?
        raise "#{AArch64ExecutionHelper::CROSS_GCC} failed to compile #{path} " \
              "(exit #{status.exitstatus}):\n#{stdout_and_stderr}"
      end

      link_and_run_aarch64(object_path)
    end
  end

  def cross_gcc_compile_args(relative_path)
    args = [AArch64ExecutionHelper::CROSS_GCC, "-c", ExecutionHelper::REFERENCE_STD_FLAG, "-fno-pie"]
    args.concat(ExecutionHelper::OBSOLETE_C_FLAGS) if obsolete_c_example?(relative_path)
    args
  end
end
