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
      source = File.read(path)
      assert_equal build_and_run(source, :gcc), build_and_run(source, :rubycc),
                   "rubycc and gcc disagree on [exit status, stdout] for #{File.basename(path)}"
    end
  end

  private

  # Compiles `source` with the requested compiler, links and runs it, and
  # returns [exit_status, stdout] for a bit-for-bit comparison.
  def build_and_run(source, compiler)
    in_tmpdir do |dir|
      object_path = File.join(dir, "example.o")
      compile_source(source, object_path, compiler)
      link_and_run(object_path)
    end
  end
end
