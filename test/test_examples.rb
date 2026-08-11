# frozen_string_literal: true

require_relative "test_helper"

# Builds and runs every sample program under examples/, comparing exit status
# and stdout against gcc. The samples document what the toolchain can build at
# each milestone, and this test is the invariant that keeps them building as
# the compiler evolves — a regression that breaks a sample fails here.
class TestExamples < Minitest::Test
  include ExecutionHelper

  EXAMPLES_ROOT = File.expand_path("../examples", __dir__).freeze
  EXAMPLE_SOURCES = Dir.glob(File.join(EXAMPLES_ROOT, "**/*.c")).sort.freeze

  # Samples the AArch64 backend cannot lower yet, by relative path, with the
  # construct that stops each one. These would be backend limitations, not
  # environment-dependent failures, which is why they are named here rather than
  # skipped in bulk: each sample stays a test method of its own, so a native
  # AArch64 run still executes and reports every other example instead of
  # skipping one aggregate loop that contains 40+ independent samples.
  #
  # The list is **empty**: the last two entries (m2/step44_builtins.c for the
  # bit-scan builtins, m1/step28_extensions.c for __builtin_alloca) came off in
  # m4/aarch64-alloca-bitscan-1 and -2. It is kept rather than deleted because
  # it is also the mechanism a *new* gap is recorded in, and because
  # TestExamplesAArch64 shares it so the native and cross runners cannot
  # disagree about what is pending.
  AARCH64_PENDING = {}.freeze

  def test_example_sources_are_present
    refute_empty EXAMPLE_SOURCES, "expected sample programs under examples/"
  end

  EXAMPLE_SOURCES.each do |path|
    relative_path = path.delete_prefix("#{EXAMPLES_ROOT}/")
    test_name = relative_path.delete_suffix(".c").gsub(/[^A-Za-z0-9]+/, "_")

    define_method("test_example_#{test_name}") do
      if host_target == "aarch64" && (reason = AARCH64_PENDING[relative_path])
        skip reason
      end

      assert_equal build_and_run(path, :gcc), build_and_run(path, :rubycc),
                   "rubycc and gcc disagree on [exit status, stdout] for #{relative_path}"
    end
  end

  private

  # Compiles the sample at `path` with the requested compiler, links and runs
  # it, and returns [exit_status, stdout] for a bit-for-bit comparison. The
  # sample is compiled from its own location (not a copy in a temp dir) so a
  # quote #include resolves against examples/m1, the same base gcc uses.
  def build_and_run(path, compiler)
    in_tmpdir do |dir|
      object_path = File.join(dir, "example.o")
      compile_example(path, object_path, compiler)
      link_and_run(object_path)
    end
  end

  def compile_example(path, object_path, compiler)
    case compiler
    when :rubycc
      Rubycc::Compiler.compile_file(path, object_path, target: host_target)
    when :gcc
      stdout_and_stderr, status = Open3.capture2e("gcc", "-c", "-fno-pie", "-o", object_path, path)
      unless status.success?
        raise "gcc failed to compile #{path} (exit #{status.exitstatus}):\n#{stdout_and_stderr}"
      end
    end
  end
end
