# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/c_suite_oracle"
require "rbconfig"

# Runs the vendored c-testsuite (test/external/c-testsuite) as one Minitest
# case per source file: compile with rubycc, link with gcc (against libm, for
# the handful of cases that call math functions), run the binary, and require
# a clean exit plus byte-for-byte agreement with the upstream .expected file
# on the program's combined stdout+stderr — the same pass criterion as the
# suite's own `runners/single-exec/posix` reference runner.
#
# This is Step 28 Phase C5a: proof that the M1 subset survives contact with
# an external, compiler-agnostic conformance suite rather than only rubycc's
# own hand-written examples.
class TestCSuite < Minitest::Test
  include ExecutionHelper

  SUITE_DIR = File.expand_path("external/c-testsuite/single-exec", __dir__)

  CASE_SOURCES = Dir.glob(File.join(SUITE_DIR, "*.c")).sort.freeze

  # The host profile is derived from Ruby's actual architecture. The host suite
  # must never compile x86 objects and link them with a native AArch64 gcc (or
  # read x86 libc headers on an ARM runner).
  HOST_TARGET = HostTarget.name
  unless Rubycc::Compiler::TARGETS.key?(HOST_TARGET)
    raise "c-testsuite host profile does not support this CPU: #{HOST_TARGET.inspect}"
  end

  # The libc header directories on this host. gcc's private include directory
  # (/usr/lib/gcc/.../include, home to stdarg.h and the other compiler-supplied
  # headers) is deliberately absent: rubycc ships those itself and injects them,
  # together with the libc directories, as its default system search path
  # (Step 41), so this suite compiles without touching /usr/lib/gcc.
  SYSTEM_INCLUDE_PATHS = [
    Rubycc::Preprocess::Preprocessor::BUNDLED_INCLUDE_DIR,
    "/usr/local/include",
    (HOST_TARGET == "aarch64" ? "/usr/include/aarch64-linux-gnu" : "/usr/include/x86_64-linux-gnu"),
    "/usr/include"
  ].freeze

  # Cases the current rubycc subset cannot build or run correctly yet, each
  # with a one-line reason. Kept here (not silently dropped from the vendored
  # tree) so `rake test` reports them as skips, not omissions.
  SKIP = {
    "00140" => "struct passed to variadic function (known debt)",
    "00149" => "block-scope compound literals now work (Step 53), but this case uses a file-scope compound literal ('struct S *s = &(struct S){1,2};'), whose static-storage-duration object is a deliberate diagnostic",
    "00150" => "block-scope compound literals now work (Step 53), but this case uses file-scope compound literals with static storage duration (a deliberate diagnostic)",
    "00152" => "#line directive (accept-only planned)",
    "00170" => "passes 'int *' where 'unsigned int *' expected (enum underlying type is unsigned in gcc; rubycc models enums as int, so this pointer-sign mismatch is a conforming rejection) — the enum function-pointer identity itself is now fixed and unit-tested",
    "00201" => "macro re-expansion needs Prosser hide-set intersection (documented Step 27 deviation)",
    "00204" => "struct-by-value / HFA calling convention and struct va_arg (out of scope) — the exact-fit string initializer it also exercised is now fixed",
    "00206" => "#pragma push_macro/pop_macro (silently-ignored pragma)",
    "00207" => "variable-length arrays (out of scope)",
    "00209" => "K&R unspecified-parameter function type as parameter (out of scope)",
    "00216" => "block-scope compound literals now work (Step 53), but this case still stacks several out-of-scope features: file-scope compound literals with static storage duration (a deliberate diagnostic), empty structs, '[a ... b]' range designators, whole-struct-expression member initializers (6.7.9p13) and -fms-extensions unnamed members",
    "00218" => "bit-field access now works (Step 48), but this case reads an all-non-negative enum bit-field, which gcc zero-extends (its enum underlying type is unsigned); rubycc models enums as signed int, so the read sign-extends — the same enum-signedness modeling deviation as 00170",
    "00219" => "_Generic (out of scope for M1)",
    "00220" => "wide string literals (deliberate diagnostic)"
  }.freeze

  def test_c_suite_sources_are_present
    refute_empty CASE_SOURCES, "expected vendored c-testsuite cases under #{SUITE_DIR}"
  end

  def test_project_oracle_cases_are_not_reintroduced_as_shared_skips
    assert_empty(%w[00130 00151] & SKIP.keys,
                 "oracle-backed c-testsuite cases must not be hidden by the shared skip list")
    assert_equal "2 2 2 2\n", CTestSuiteOracle.expected_output("00130")
    assert_equal "1 6 7 7 2 3 5\n", CTestSuiteOracle.expected_output("00151")
  end

  # The upstream 00151 program returns zero when both values are zero, so a
  # compiler that drops every initializer can pass its original oracle. This
  # test runs a source-level zero-initializer mutant and proves that the
  # project-owned value oracle observes the difference.
  def test_c_suite_00151_initializer_mutation_is_observable
    c_path = File.join(SUITE_DIR, "00151.c")
    source = CTestSuiteOracle.source(c_path, "00151", mutation: :ignore_initializer)

    in_tmpdir do |dir|
      rubycc_object_path = File.join(dir, "00151-mutant-rubycc.o")
      gcc_object_path = File.join(dir, "00151-mutant-gcc.o")
      compile_c_suite_oracle_with_rubycc(source, rubycc_object_path, "00151-mutant.c")
      compile_with_gcc(source, gcc_object_path)

      rubycc_output, rubycc_status = link_and_run_with_libm(rubycc_object_path)
      gcc_output, gcc_status = link_and_run_with_libm(gcc_object_path)
      assert gcc_status.success?, "GCC 00151 initializer mutant exited #{gcc_status.exitstatus}, output:\n#{gcc_output}"
      assert rubycc_status.success?, "rubycc 00151 initializer mutant exited #{rubycc_status.exitstatus}, output:\n#{rubycc_output}"
      assert_equal CTestSuiteOracle.mutation_output("00151"), gcc_output,
                   "the mutation must produce the all-zero initializer observation"
      assert_equal gcc_output, rubycc_output,
                   "the source-level initializer mutation must agree with GCC"
      refute_equal CTestSuiteOracle.expected_output("00151"), rubycc_output,
                   "the 00151 oracle must reject an initializer-dropping result"
    end
  end

  CASE_SOURCES.each do |c_path|
    basename = File.basename(c_path, ".c")

    define_method("test_c_suite_#{basename}") do
      run_c_suite_case(c_path, basename)
    end
  end

  private

  def run_c_suite_case(c_path, basename)
    if (reason = SKIP[basename])
      skip reason
      return
    end

    expected = File.binread("#{c_path}.expected")

    in_tmpdir do |dir|
      object_path = File.join(dir, "#{basename}.o")

      begin
        binary = Rubycc::Compiler.new.compile(
          File.read(c_path), filename: File.basename(c_path), target: HOST_TARGET,
          include_paths: SYSTEM_INCLUDE_PATHS, system_includes: false
        )
      rescue Rubycc::CompileError => e
        flunk "rubycc failed to compile #{basename}.c: #{e.message}"
      end
      File.binwrite(object_path, binary)

      output, status = link_and_run_with_libm(object_path)
      assert status.success?, "#{basename} exited #{status.exitstatus}, output:\n#{output}"
      assert_equal expected, output, "#{basename} output mismatch"

      run_c_suite_oracle_case(c_path, basename) if CTestSuiteOracle.supported_case?(basename)
    end
  end

  def run_c_suite_oracle_case(c_path, basename)
    source = CTestSuiteOracle.source(c_path, basename)
    expected = CTestSuiteOracle.expected_output(basename)

    in_tmpdir do |dir|
      rubycc_object_path = File.join(dir, "#{basename}-rubycc.o")
      gcc_object_path = File.join(dir, "#{basename}-gcc.o")

      compile_c_suite_oracle_with_rubycc(source, rubycc_object_path, "#{basename}-oracle.c")
      compile_with_gcc(source, gcc_object_path)

      rubycc_output, rubycc_status = link_and_run_with_libm(rubycc_object_path)
      gcc_output, gcc_status = link_and_run_with_libm(gcc_object_path)

      assert gcc_status.success?, "GCC oracle for #{basename} exited #{gcc_status.exitstatus}, output:\n#{gcc_output}"
      assert rubycc_status.success?, "rubycc oracle for #{basename} exited #{rubycc_status.exitstatus}, output:\n#{rubycc_output}"
      assert_equal expected, gcc_output, "GCC oracle output mismatch for #{basename}"
      assert_equal gcc_status.exitstatus, rubycc_status.exitstatus,
                   "#{basename} oracle exit status mismatch (GCC vs rubycc)"
      assert_equal gcc_output, rubycc_output, "#{basename} oracle stdout mismatch (GCC vs rubycc)"
    end
  end

  def compile_c_suite_oracle_with_rubycc(source, object_path, filename)
    binary = Rubycc::Compiler.new.compile(
      source, filename: filename, target: HOST_TARGET, include_paths: SYSTEM_INCLUDE_PATHS,
      system_includes: false
    )
    File.binwrite(object_path, binary)
  rescue Rubycc::CompileError => e
    flunk "rubycc failed to compile #{filename}: #{e.message}"
  end
end
