# frozen_string_literal: true

require_relative "test_helper"

# stdc-no-vla-macro-1: C11 6.10.8.3 requires an implementation that does not
# support variable-length arrays to define __STDC_NO_VLA__ to the integer
# constant 1, so a portable header can avoid the feature instead of relying on
# a diagnostic. This reproduces the shape that blocked GAPS gap AP: brotli
# 0.8.0's vendor/brotli/c/include/brotli/port.h:257-263 selects a VLA-shaped
# array parameter only when !defined(__STDC_NO_VLA__), and an empty "[]"
# otherwise. Before this macro was defined, rubycc claimed VLA support it does
# not have, so brotli's header chose the VLA-shaped parameter and rubycc
# rejected it ("array size must be an integer constant").
class TestStdcNoVlaMacro < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # The macro reproduction of brotli's dispatch: an array parameter's bracket
  # contents come from ARRAY_PARAM(data_size), which is "(data_size)" (a VLA
  # parameter, adjusted to a pointer by 6.7.6.3p7) when the implementation
  # claims VLA support, or empty when it does not.
  BROTLI_SHAPE_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>

    #if defined(__STDC_VERSION__) && (__STDC_VERSION__ >= 199901L) && \\
        !defined(__STDC_NO_VLA__) && !defined(__cplusplus)
    #define ARRAY_PARAM(name) (name)
    #else
    #define ARRAY_PARAM(name)
    #endif

    static int sum(size_t data_size, const int data[ARRAY_PARAM(data_size)]) {
      size_t i;
      int total = 0;
      for (i = 0; i < data_size; i++) total += data[i];
      return total;
    }

    int main(void) {
      int values[] = {1, 2, 3, 4, 5};
      printf("%d\\n", sum(5, values));
      return 0;
    }
  C

  def test_stdc_no_vla_is_defined_to_one
    tokens = Rubycc::Preprocess::Preprocessor.new.run("__STDC_NO_VLA__", filename: "t.c").reject(&:eof?)
    num = tokens.find { |t| t.type == :num }
    refute_nil num, "expected __STDC_NO_VLA__ to expand to a numeric constant"
    assert_equal 1, num.value
  end

  def test_stdc_no_vla_selects_the_non_vla_branch
    source = "#ifdef __STDC_NO_VLA__\nint no_vla = 1;\n#else\nint no_vla = 0;\n#endif\n"
    tokens = Rubycc::Preprocess::Preprocessor.new.run(source, filename: "t.c").reject(&:eof?)
    assert_equal [1], tokens.select { |t| t.type == :num }.map(&:value)
  end

  # Before __STDC_NO_VLA__ was predefined, brotli's header chose the VLA
  # parameter branch and rubycc rejected it even though gcc accepts it (GAPS
  # gap AP, 2026-09-13). With the macro defined, both compilers take the
  # non-VLA branch and the program's behavior — not just its build — matches.
  def test_brotli_array_param_shape_matches_gcc
    assert_matches_gcc(BROTLI_SHAPE_SOURCE, "brotli_array_param")
  end

  def assert_matches_gcc(source, name)
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      binary = Rubycc::Compiler.new.compile(source, filename: "#{name}.c", target: host_target)
      File.binwrite(rubycc_obj, binary)
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = compile_with_gcc(source, File.join(dir, "#{name}_gcc.o"))
      gcc_status, gcc_out = link_and_run(gcc_obj)

      assert_equal 0, rubycc_status, "rubycc-built #{name} exited #{rubycc_status}"
      assert_equal gcc_status, rubycc_status, "#{name}: exit status differs from gcc"
      assert_equal gcc_out, rubycc_out, "#{name}: output differs from gcc"
    end
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
