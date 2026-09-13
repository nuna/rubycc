# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# include-absolute-path-1: an absolute header name in #include used to always
# fail even when the named file existed (issues/include-absolute-path.md,
# GAPS gap AO). #resolve_include only ever tried "includer's directory + name"
# and "a search-path directory + name" (File.join); with an absolute name both
# candidates are "some directory + an absolute path", so the name itself was
# never tried on its own. The reported trigger is numo-narray 0.9.2.1, whose
# extconf.rb leaves RUBY_EXTCONF_H set to an absolute path, and Ruby's
# ruby/internal/config.h:25 does `#include RUBY_EXTCONF_H`.
class TestIncludeAbsolutePath < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  def pp(source, **kwargs)
    Rubycc::Preprocess::Preprocessor.new.run(source, filename: "main.c", **kwargs)
  end

  # --- the four forms from the issue's reproduction table --------------------

  def test_quote_include_of_an_absolute_path_resolves
    Dir.mktmpdir do |dir|
      header = File.join(dir, "abs.h")
      File.write(header, "int from_abs = 1;\n")
      tokens = pp(%(#include "#{header}"\n)).reject(&:eof?)
      assert_equal ["int", "from_abs", "=", 1, ";"], tokens.map(&:value)
    end
  end

  def test_angle_include_of_an_absolute_path_resolves
    Dir.mktmpdir do |dir|
      header = File.join(dir, "abs.h")
      File.write(header, "int from_abs = 1;\n")
      tokens = pp("#include <#{header}>\n").reject(&:eof?)
      assert_equal ["int", "from_abs", "=", 1, ";"], tokens.map(&:value)
    end
  end

  def test_macro_expanding_to_an_absolute_path_resolves
    Dir.mktmpdir do |dir|
      header = File.join(dir, "abs.h")
      File.write(header, "int from_abs = 1;\n")
      tokens = pp(%(#define H "#{header}"\n#include H\n)).reject(&:eof?)
      assert_equal ["int", "from_abs", "=", 1, ";"], tokens.map(&:value)
    end
  end

  def test_command_line_macro_with_an_absolute_path_resolves
    # The shell spelling in numo-narray's Makefile is
    # -DRUBY_EXTCONF_H='"/.../extconf.h"'; after shell parsing, rubycc receives
    # the quoted absolute path as the macro value.
    Dir.mktmpdir do |dir|
      header = File.join(dir, "abs.h")
      File.write(header, "int from_abs = 1;\n")
      tokens = pp("#include RUBY_EXTCONF_H\n",
                  defines: [[:define, %(RUBY_EXTCONF_H="#{header}")]]).reject(&:eof?)
      assert_equal ["int", "from_abs", "=", 1, ";"], tokens.map(&:value)
    end
  end

  # --- relative resolution is unaffected --------------------------------------

  def test_relative_command_line_macro_still_resolves_along_the_search_path
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "ext.h"), "int from_ext = 1;\n")
      tokens = pp("#include RUBY_EXTCONF_H\n",
                  include_paths: [dir], system_includes: false,
                  defines: [[:define, 'RUBY_EXTCONF_H="ext.h"']]).reject(&:eof?)
      assert_equal ["int", "from_ext", "=", 1, ";"], tokens.map(&:value)
    end
  end

  def test_relative_quote_include_still_resolves_beside_the_includer
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "inc.h"), "int from_beside = 1;\n")
      main = File.join(dir, "main.c")
      tokens = Rubycc::Preprocess::Preprocessor.new
                 .run(%(#include "inc.h"\n), filename: main).reject(&:eof?)
      assert_equal ["int", "from_beside", "=", 1, ";"], tokens.map(&:value)
    end
  end

  # --- a nonexistent absolute path still diagnoses ----------------------------

  def test_nonexistent_absolute_path_is_diagnosed
    Dir.mktmpdir do |dir|
      header = File.join(dir, "gone.h")
      error = assert_raises(Rubycc::CompileError) { pp(%(#include "#{header}"\n)) }
      assert_match(/#{Regexp.escape(header)}: No such file or directory/, error.description)
    end
  end

  # --- #include_next consistency for a file opened by absolute path ----------

  # A file opened by absolute path is not found along the search path, so it
  # has no recorded #include_next origin -- the same situation as the main
  # source file (test_include_next_from_the_main_file_behaves_like_include in
  # test_preprocessor.rb). #include_next from it therefore falls back to a
  # plain #include search from the front of the -I list.
  def test_include_next_from_an_absolutely_included_header_behaves_like_a_plain_include
    Dir.mktmpdir do |searchdir|
      File.write(File.join(searchdir, "h.h"), "int from_dir = 1;\n")
      Dir.mktmpdir do |dir|
        abs_header = File.join(dir, "abs.h")
        File.write(abs_header, %(#include_next "h.h"\n))
        tokens = pp(%(#include "#{abs_header}"\n),
                    include_paths: [searchdir]).reject(&:eof?)
        assert_equal ["int", "from_dir", "=", 1, ";"], tokens.map(&:value)
      end
    end
  end

  # #resolve_include_next joins "a search-path directory + name" too, so an
  # absolute name reaching #include_next (rather than #include) hit the same
  # bug. Here h.h *is* found along the search path, giving it a recorded
  # origin, so this exercises #resolve_include_next's own absolute-path branch
  # rather than falling back to #resolve_include.
  def test_include_next_with_an_absolute_name_resolves_directly
    Dir.mktmpdir do |dir1|
      Dir.mktmpdir do |dir2|
        abs_header = File.join(dir2, "abs.h")
        File.write(abs_header, "int from_abs = 1;\n")
        File.write(File.join(dir1, "h.h"), %(#include_next "#{abs_header}"\n))
        tokens = Rubycc::Preprocess::Preprocessor.new
                   .run("#include <h.h>\n", filename: "main.c", include_paths: [dir1])
                   .reject(&:eof?)
        assert_equal ["int", "from_abs", "=", 1, ";"], tokens.map(&:value)
      end
    end
  end

  # --- gcc-differential execution ---------------------------------------------

  # Before this fix, compiling this source raised a diagnostic instead of
  # producing an object at all (GAPS gap AO, 2026-09-13). With the fix, a value
  # that only exists inside the absolutely-included header reaches the
  # running program, matching gcc.
  def test_absolutely_included_header_value_matches_gcc
    Dir.mktmpdir do |dir|
      header = File.join(dir, "abs.h")
      File.write(header, "#define ABS_VALUE 42\n")
      source = <<~C
        #include "#{header}"
        #include <stdio.h>
        int main(void) {
          printf("%d\\n", ABS_VALUE);
          return 0;
        }
      C
      assert_matches_gcc(source, "abs_include")
    end
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
