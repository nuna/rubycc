# frozen_string_literal: true

require "tmpdir"
require "open3"

# ExecutionHelper provides the scaffolding shared by execution tests:
# compile a C source string down to an object file, link it into an
# executable, run it, and assert on its exit status.
#
# `compiler: :gcc` exercises a reference path (using the system gcc) that
# exists purely to validate the harness itself. `compiler: :rubycc` drives the
# Pure Ruby toolchain (Rubycc::Compiler).
module ExecutionHelper
  def in_tmpdir
    Dir.mktmpdir("rubycc-test") do |dir|
      yield dir
    end
  end

  def compile_with_rubycc(c_source, output_path)
    filename = "#{File.basename(output_path, ".*")}.c"
    binary = Rubycc::Compiler.new.compile(c_source, filename: filename)
    File.binwrite(output_path, binary)
    output_path
  end

  def compile_with_gcc(c_source, output_path)
    dir = File.dirname(output_path)
    source_path = File.join(dir, "#{File.basename(output_path, ".*")}.c")
    File.write(source_path, c_source)

    stdout_and_stderr, status = Open3.capture2e("gcc", "-c", "-o", output_path, source_path)
    unless status.success?
      raise "gcc failed to compile source (exit #{status.exitstatus}):\n#{stdout_and_stderr}"
    end

    output_path
  end

  def link_and_run(object_path)
    dir = File.dirname(object_path)
    exe_path = File.join(dir, "#{File.basename(object_path, ".*")}.out")

    stdout_and_stderr, status = Open3.capture2e("gcc", "-o", exe_path, object_path)
    unless status.success?
      raise "gcc failed to link object file (exit #{status.exitstatus}):\n#{stdout_and_stderr}"
    end

    _, run_status = Open3.capture2e(exe_path)
    run_status.exitstatus
  end

  def assert_c_exit_status(expected, c_source, compiler: :rubycc)
    in_tmpdir do |dir|
      object_path = File.join(dir, "test.o")

      case compiler
      when :rubycc
        compile_with_rubycc(c_source, object_path)
      when :gcc
        compile_with_gcc(c_source, object_path)
      else
        raise ArgumentError, "unknown compiler: #{compiler.inspect}"
      end

      actual = link_and_run(object_path)
      assert_equal expected, actual, "expected C program to exit with #{expected}, got #{actual}"
    end
  end
end
