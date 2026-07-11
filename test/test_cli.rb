# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class TestCli < Minitest::Test
  EXE_PATH = File.expand_path("../exe/rubycc", __dir__)

  def run_cli(*args, chdir: nil)
    opts = {}
    opts[:chdir] = chdir if chdir
    Open3.capture3("ruby", "-Ilib", EXE_PATH, *args, **opts)
  end

  def lib_dir
    File.expand_path("../lib", __dir__)
  end

  def test_version_flag_prints_version_and_exits_zero
    stdout, _stderr, status = run_cli("--version")

    assert_equal "rubycc #{Rubycc::VERSION}\n", stdout
    assert status.success?
  end

  def test_no_arguments_exits_with_error
    _stdout, stderr, status = run_cli

    assert_equal 1, status.exitstatus
    assert_match(/no input file/, stderr)
  end

  def test_compiles_object_file_and_exits_zero
    Dir.mktmpdir("rubycc-cli") do |dir|
      File.write(File.join(dir, "foo.c"), "int main(void) { return 42; }")

      # Run with an absolute lib path so chdir does not break the require.
      _stdout, stderr, status = Open3.capture3(
        "ruby", "-I#{lib_dir}", EXE_PATH, "-c", "foo.c", "-o", "foo.o",
        chdir: dir
      )

      assert_equal 0, status.exitstatus, "stderr: #{stderr}"
      object_path = File.join(dir, "foo.o")
      assert File.exist?(object_path), "expected foo.o to be created"
      assert_equal "\x7FELF".b, File.binread(object_path, 4)
    end
  end

  def test_output_path_defaults_to_dot_o
    Dir.mktmpdir("rubycc-cli") do |dir|
      File.write(File.join(dir, "foo.c"), "int main(void) { return 1; }")

      _stdout, _stderr, status = Open3.capture3(
        "ruby", "-I#{lib_dir}", EXE_PATH, "-c", "foo.c", chdir: dir
      )

      assert_equal 0, status.exitstatus
      assert File.exist?(File.join(dir, "foo.o"))
    end
  end

  def test_syntax_error_exits_one_with_diagnostic
    Dir.mktmpdir("rubycc-cli") do |dir|
      # Missing semicolon on line 2.
      File.write(File.join(dir, "foo.c"), "int main(void) {\n  return 42\n}\n")

      _stdout, stderr, status = Open3.capture3(
        "ruby", "-I#{lib_dir}", EXE_PATH, "-c", "foo.c", "-o", "foo.o",
        chdir: dir
      )

      assert_equal 1, status.exitstatus
      assert_match(/foo\.c:3:1/, stderr) # caret points at '}' on line 3
      assert_match(/error:/, stderr)
    end
  end

  def test_unknown_option_exits_one
    _stdout, stderr, status = run_cli("--frobnicate")

    assert_equal 1, status.exitstatus
    assert_match(/unrecognized option/, stderr)
  end

  def test_include_path_option_resolves_a_header
    Dir.mktmpdir("rubycc-cli") do |dir|
      headers = File.join(dir, "include")
      Dir.mkdir(headers)
      File.write(File.join(headers, "answer.h"), "#define ANSWER 42\n")
      File.write(File.join(dir, "foo.c"), "#include <answer.h>\nint main(void) { return ANSWER; }\n")

      # The joined "-Idir" form; the header only resolves along the search path.
      _stdout, stderr, status = Open3.capture3(
        "ruby", "-I#{lib_dir}", EXE_PATH, "-c", "foo.c", "-o", "foo.o", "-I#{headers}",
        chdir: dir
      )

      assert_equal 0, status.exitstatus, "stderr: #{stderr}"
      assert File.exist?(File.join(dir, "foo.o")), "expected foo.o to be created"
    end
  end

  def test_missing_include_path_fails_without_the_option
    Dir.mktmpdir("rubycc-cli") do |dir|
      headers = File.join(dir, "include")
      Dir.mkdir(headers)
      File.write(File.join(headers, "answer.h"), "#define ANSWER 42\n")
      File.write(File.join(dir, "foo.c"), "#include <answer.h>\nint main(void) { return ANSWER; }\n")

      # Without -I the angled header is unreachable, so compilation fails.
      _stdout, stderr, status = Open3.capture3(
        "ruby", "-I#{lib_dir}", EXE_PATH, "-c", "foo.c", "-o", "foo.o",
        chdir: dir
      )

      assert_equal 1, status.exitstatus
      assert_match(%r{answer\.h: No such file or directory}, stderr)
    end
  end
end
