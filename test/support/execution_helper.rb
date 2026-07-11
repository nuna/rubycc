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

  # Preprocesses `c_source` with the system gcc ("-E -P": run the preprocessor
  # only, and suppress the #line markers so the output is bare token text) and
  # returns its standard output. This is the reference oracle the preprocessor's
  # differential tests lex and compare against rubycc's own token stream.
  def preprocess_with_gcc(c_source)
    in_tmpdir do |dir|
      source_path = File.join(dir, "input.c")
      File.write(source_path, c_source)
      stdout, stderr, status = Open3.capture3("gcc", "-E", "-P", source_path)
      raise "gcc failed to preprocess source (exit #{status.exitstatus}):\n#{stderr}" unless status.success?

      stdout
    end
  end

  # Links `object_path` into an executable, runs it, and returns
  # [exit_status, stdout] so callers can assert on either.
  def link_and_run(object_path)
    dir = File.dirname(object_path)
    exe_path = File.join(dir, "#{File.basename(object_path, ".*")}.out")

    stdout_and_stderr, status = Open3.capture2e("gcc", "-o", exe_path, object_path)
    unless status.success?
      raise "gcc failed to link object file (exit #{status.exitstatus}):\n#{stdout_and_stderr}"
    end

    stdout, run_status = Open3.capture2(exe_path)
    [run_status.exitstatus, stdout]
  end

  # Links `object_path` into an executable and returns the linker's combined
  # stderr, so tests can assert it is warning-free (e.g. no missing
  # .note.GNU-stack executable-stack warning).
  def link_stderr(object_path)
    dir = File.dirname(object_path)
    exe_path = File.join(dir, "#{File.basename(object_path, ".*")}.out")
    _stdout, stderr, _status = Open3.capture3("gcc", "-o", exe_path, object_path)
    stderr
  end

  # Compiles each [c_source, compiler] pair to its own object file, links them
  # all into one executable with gcc, runs it, and returns [exit_status, stdout].
  # Mixing compilers across translation units is what proves the calling
  # convention: both sides must agree on the psABI, not merely be self-consistent.
  def link_units_and_run(units)
    in_tmpdir do |dir|
      object_paths = units.each_with_index.map do |(c_source, compiler), index|
        object_path = File.join(dir, "unit#{index}.o")
        compile_source(c_source, object_path, compiler)
        object_path
      end

      exe_path = File.join(dir, "exe")
      stdout_and_stderr, status = Open3.capture2e("gcc", "-o", exe_path, *object_paths)
      unless status.success?
        raise "gcc failed to link object files (exit #{status.exitstatus}):\n#{stdout_and_stderr}"
      end

      stdout, run_status = Open3.capture2(exe_path)
      [run_status.exitstatus, stdout]
    end
  end

  # Compiles `c_source` to `object_path` with the requested compiler.
  def compile_source(c_source, object_path, compiler)
    case compiler
    when :rubycc
      compile_with_rubycc(c_source, object_path)
    when :gcc
      compile_with_gcc(c_source, object_path)
    else
      raise ArgumentError, "unknown compiler: #{compiler.inspect}"
    end
  end

  def assert_c_exit_status(expected, c_source, compiler: :rubycc)
    in_tmpdir do |dir|
      object_path = File.join(dir, "test.o")
      compile_source(c_source, object_path, compiler)

      actual, = link_and_run(object_path)
      assert_equal expected, actual, "expected C program to exit with #{expected}, got #{actual}"
    end
  end

  # Compiles, links and runs `c_source`, asserting on the exit status and,
  # when `stdout` is given, on the program's standard output too.
  def assert_c_program(c_source, exit_status:, stdout: nil, compiler: :rubycc)
    in_tmpdir do |dir|
      object_path = File.join(dir, "test.o")
      compile_source(c_source, object_path, compiler)

      actual_status, actual_stdout = link_and_run(object_path)
      assert_equal exit_status, actual_status,
                   "expected C program to exit with #{exit_status}, got #{actual_status}"
      assert_equal stdout, actual_stdout, "stdout mismatch" unless stdout.nil?
    end
  end
end
