# frozen_string_literal: true

require_relative "test_helper"

# Builds and runs every sample program under examples/, comparing exit status
# and stdout against gcc. The samples document what the toolchain can build at
# each milestone, and this test is the invariant that keeps them building as
# the compiler evolves — a regression that breaks a sample fails here.
class TestExamples < Minitest::Test
  include ExecutionHelper

  EXAMPLE_SOURCES = Dir.glob(File.expand_path("../examples/**/*.c", __dir__)).sort.freeze

  def test_example_sources_are_present
    refute_empty EXAMPLE_SOURCES, "expected sample programs under examples/"
  end

  def test_examples_match_gcc_exit_status_and_stdout
    EXAMPLE_SOURCES.each do |path|
      assert_equal build_and_run(path, :gcc), build_and_run(path, :rubycc),
                   "rubycc and gcc disagree on [exit status, stdout] for #{File.basename(path)}"
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
      Rubycc::Compiler.compile_file(path, object_path, target: EXECUTION_TARGET)
    when :gcc
      stdout_and_stderr, status = Open3.capture2e(*execution_gcc_command("-c", "-fno-pie", "-o", object_path, path))
      unless status.success?
        raise "gcc failed to compile #{path} (exit #{status.exitstatus}):\n#{stdout_and_stderr}"
      end
    end
  end
end
