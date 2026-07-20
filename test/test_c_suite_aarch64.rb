# frozen_string_literal: true

require_relative "test_helper"
require_relative "test_c_suite"

# Runs the vendored c-testsuite a second time, for the aarch64 target: compile
# with rubycc's aarch64 backend, link with the cross gcc, run the result under
# qemu-aarch64 and require the same byte-for-byte agreement with the upstream
# .expected file that TestCSuite requires on the host.
#
# This is the payoff of building a second backend (M4 A3): the external suite is
# the largest body of C rubycc can run, so pointing it at aarch64 measures how
# much of the x86-64 subset the new backend actually reproduces, and turns every
# remaining gap into a named entry in one of the two skip lists below rather
# than an unknown. It also puts pressure on the parts of the compiler that are
# supposed to be target-independent: anything that quietly assumed x86-64 shows
# up here as a wrong answer instead of hiding behind a single backend.
#
# The whole file skips on a host without the cross toolchain, and adds roughly
# 50 seconds to `rake test` where the toolchain is present.
class TestCSuiteAArch64 < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  SUITE_DIR = TestCSuite::SUITE_DIR

  CASE_SOURCES = TestCSuite::CASE_SOURCES

  # The include search path for a cross compile. The host's libc headers
  # (/usr/include/x86_64-linux-gnu) describe the wrong ABI, and so do the
  # bundled compatibility headers under include/libc/glibc/x86_64, so neither
  # may be on the path: rubycc's default system directories are suppressed
  # (system_includes: false) and replaced by the compiler-supplied freestanding
  # headers, which are ABI-neutral, followed by the cross toolchain's aarch64
  # glibc headers. That second directory is the one the cross gcc itself reports
  # for angled includes ("aarch64-linux-gnu-gcc -E -v -", which lists
  # .../13/../../../../aarch64-linux-gnu/include); its own private include
  # directory is left out for the same reason TestCSuite leaves out the host's.
  CROSS_SYSTEM_INCLUDE_PATHS = [
    Rubycc::Preprocess::Preprocessor::BUNDLED_INCLUDE_DIR,
    "/usr/aarch64-linux-gnu/include"
  ].freeze

  # The aarch64 sysroot the cases are compiled against. Its absence means the
  # cross libc headers are not installed, which is a skip, not a failure.
  CROSS_SYSROOT_INCLUDE_DIR = CROSS_SYSTEM_INCLUDE_PATHS.last

  # Cases whose only obstacle is a feature the aarch64 backend has not been
  # taught yet (M4 A4). Everything here compiles and runs on x86-64 today, so
  # this list is exactly the aarch64 backend's remaining work, grouped by the
  # construct that stops it: the backend raises Backend::UnsupportedError rather
  # than emitting wrong code, which is why these are named here one by one.
  AARCH64_PENDING = {
    "00087" => "A4: indirect calls (call through a function pointer)",
    "00089" => "A4: indirect calls (call through a function pointer)",
    "00113" => "A4: floating-point arithmetic",
    "00119" => "A4: floating-point arithmetic",
    "00123" => "A4: floating-point arithmetic",
    "00124" => "A4: indirect calls (call through a function pointer)",
    "00159" => "A4: indirect calls (call through a function pointer)",
    "00174" => "A4: floating-point arithmetic",
    "00175" => "A4: floating-point parameters",
    "00189" => "A4: indirect calls (call through a function pointer)",
    "00195" => "A4: floating-point call arguments",
    "00210" => "A4: indirect calls (call through a function pointer)"
  }.freeze

  # The cases the host suite already skips are skipped here for the same
  # reasons, and are deliberately taken from TestCSuite::SKIP rather than copied:
  # they are front-end or known-debt limitations with no target dimension, so the
  # two runs must never disagree about them, and fixing one has to clear both.
  # A case not in this hash and not in AARCH64_PENDING is expected to pass.
  SHARED_SKIP = TestCSuite::SKIP

  def test_c_suite_aarch64_pending_list_is_disjoint_from_shared_skips
    assert_empty (AARCH64_PENDING.keys & SHARED_SKIP.keys),
                 "a case is both an aarch64 backend gap and a target-independent skip"
  end

  CASE_SOURCES.each do |c_path|
    basename = File.basename(c_path, ".c")

    define_method("test_c_suite_aarch64_#{basename}") do
      run_aarch64_c_suite_case(c_path, basename)
    end
  end

  private

  def run_aarch64_c_suite_case(c_path, basename)
    if (reason = SHARED_SKIP[basename])
      skip reason
      return
    end
    if (reason = AARCH64_PENDING[basename])
      skip reason
      return
    end

    skip_unless_aarch64_toolchain
    unless File.directory?(CROSS_SYSROOT_INCLUDE_DIR)
      skip "aarch64 libc headers (#{CROSS_SYSROOT_INCLUDE_DIR}) are not installed"
    end

    expected = File.binread("#{c_path}.expected")

    in_tmpdir do |dir|
      object_path = File.join(dir, "#{basename}.o")

      begin
        binary = Rubycc::Compiler.new.compile(
          File.read(c_path), filename: File.basename(c_path), target: "aarch64",
          include_paths: CROSS_SYSTEM_INCLUDE_PATHS, system_includes: false
        )
      rescue Rubycc::CompileError => e
        flunk "rubycc failed to compile #{basename}.c for aarch64: #{e.message}"
      end
      File.binwrite(object_path, binary)

      status, output = link_and_run_aarch64_with_libm(object_path)
      assert_equal 0, status, "#{basename} exited #{status}, output:\n#{output}"
      assert_equal expected, output, "#{basename} output mismatch"
    end
  end

  # Links statically with the cross gcc (against libm, as TestCSuite does, for
  # the cases that call math functions) and runs the result under qemu,
  # returning [exit_status, combined stdout+stderr] — the suite's pass criterion
  # is on the combined stream.
  def link_and_run_aarch64_with_libm(object_path)
    dir = File.dirname(object_path)
    exe_path = File.join(dir, "#{File.basename(object_path, ".*")}.out")

    stdout_and_stderr, status = Open3.capture2e(AArch64ExecutionHelper::CROSS_GCC, "-static",
                                                "-o", exe_path, object_path, "-lm")
    unless status.success?
      raise "#{AArch64ExecutionHelper::CROSS_GCC} failed to link object file " \
            "(exit #{status.exitstatus}):\n#{stdout_and_stderr}"
    end

    output, run_status = Open3.capture2e(AArch64ExecutionHelper::QEMU, exe_path)
    [run_status.exitstatus, output]
  end
end
