# frozen_string_literal: true

require_relative "test_helper"

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

  # The system header search path gcc (13, on this host) uses by default
  # (`gcc -xc -E -v /dev/null`, "#include <...> search starts here"). rubycc
  # has no header-discovery logic of its own yet (ROADMAP), so the harness
  # pins the paths this environment's gcc reports rather than shelling out to
  # rediscover them on every run; if the host toolchain moves (gcc version,
  # distro layout), these need updating alongside it.
  SYSTEM_INCLUDE_PATHS = [
    "/usr/lib/gcc/x86_64-linux-gnu/13/include",
    "/usr/local/include",
    "/usr/include/x86_64-linux-gnu",
    "/usr/include"
  ].freeze

  # Cases the current rubycc subset cannot build or run correctly yet, each
  # with a one-line reason. Kept here (not silently dropped from the vendored
  # tree) so `rake test` reports them as skips, not omissions.
  SKIP = {
    "00078" => "block-scope function declarations (ROADMAP §3 deviation)",
    "00130" => "multidimensional arrays (known debt)",
    "00140" => "struct passed to variadic function (known debt)",
    "00149" => "compound literals (known debt)",
    "00150" => "compound literals (known debt)",
    "00151" => "multidimensional arrays (known debt)",
    "00152" => "#line directive (accept-only planned)",
    "00170" => "passes 'int *' where 'unsigned int *' expected (enum underlying type is unsigned in gcc; rubycc models enums as int, so this pointer-sign mismatch is a conforming rejection) — the enum function-pointer identity itself is now fixed and unit-tested",
    "00201" => "macro re-expansion needs Prosser hide-set intersection (documented Step 27 deviation)",
    "00204" => "struct-by-value / HFA calling convention and struct va_arg (out of scope) — the exact-fit string initializer it also exercised is now fixed",
    "00206" => "#pragma push_macro/pop_macro (silently-ignored pragma)",
    "00207" => "variable-length arrays (out of scope)",
    "00209" => "K&R unspecified-parameter function type as parameter (out of scope)",
    "00213" => "statement expressions (recorded M1 debt, early M2)",
    "00214" => "statement expressions (recorded M1 debt, early M2)",
    "00216" => "compound literals / empty struct (known debt)",
    "00218" => "bit-field access (recorded M2 debt)",
    "00219" => "_Generic (out of scope for M1)",
    "00220" => "wide string literals (deliberate diagnostic)"
  }.freeze

  def test_c_suite_sources_are_present
    refute_empty CASE_SOURCES, "expected vendored c-testsuite cases under #{SUITE_DIR}"
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
          File.read(c_path), filename: File.basename(c_path), include_paths: SYSTEM_INCLUDE_PATHS
        )
      rescue Rubycc::CompileError => e
        flunk "rubycc failed to compile #{basename}.c: #{e.message}"
      end
      File.binwrite(object_path, binary)

      output, status = link_and_run_with_libm(object_path)
      assert status.success?, "#{basename} exited #{status.exitstatus}, output:\n#{output}"
      assert_equal expected, output, "#{basename} output mismatch"
    end
  end
end
