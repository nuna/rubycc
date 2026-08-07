# frozen_string_literal: true

require "tmpdir"
require "open3"
require "rbconfig"

# ExecutionHelper provides the scaffolding shared by execution tests:
# compile a C source string down to an object file, link it into an
# executable, run it, and assert on its exit status.
#
# `compiler: :gcc` exercises a reference path (using the system gcc) that
# exists purely to validate the harness itself. `compiler: :rubycc` drives the
# Almost Pure Ruby toolchain (Rubycc::Compiler).
module ExecutionHelper
  # Generic execution tests are intended to exercise the host ABI. The old
  # helper compiled rubycc's side with Compiler#compile's x86_64 default and
  # then linked it with the host gcc. That is coherent on x86-64, but an
  # aarch64 Ruby process consequently handed an x86_64 object to an aarch64
  # linker. Keep the x86-64 default on an x86 host and select the native target
  # and tools on an aarch64 host. The explicit AArch64ExecutionHelper remains
  # the cross-target oracle for tests that intentionally run a second target.
  HOST_TARGET = case RbConfig::CONFIG["host_cpu"].to_s
                when "aarch64", "arm64" then "aarch64"
                when "x86_64", "amd64" then "x86_64"
                else "x86_64"
                end
  EXECUTION_TARGET = ENV.fetch("RUBYCC_EXECUTION_TARGET", HOST_TARGET)
  EXECUTION_GCC = ENV.fetch("RUBYCC_EXECUTION_GCC", "gcc")
  EXECUTION_RUNNER = ENV.fetch("RUBYCC_EXECUTION_RUNNER", "")
  EXECUTION_LINK_FLAGS = ENV.fetch("RUBYCC_EXECUTION_LINK_FLAGS", "").split

  def execution_gcc_command(*args)
    [EXECUTION_GCC, *args]
  end

  def execution_link_command(*args)
    execution_gcc_command(*EXECUTION_LINK_FLAGS, *args)
  end

  def execution_run_command(*args)
    EXECUTION_RUNNER.empty? ? args : [EXECUTION_RUNNER, *args]
  end

  def skip_unless_x86_execution
    return if ExecutionHelper::EXECUTION_TARGET == "x86_64"

    skip "x86_64 execution profile is not active (current target: #{ExecutionHelper::EXECUTION_TARGET})"
  end

  def in_tmpdir
    Dir.mktmpdir("rubycc-test") do |dir|
      yield dir
    end
  end

  def compile_with_rubycc(c_source, output_path)
    filename = "#{File.basename(output_path, ".*")}.c"
    binary = Rubycc::Compiler.new.compile(c_source, filename: filename, target: EXECUTION_TARGET)
    File.binwrite(output_path, binary)
    output_path
  end

  # `pic:` compiles with -fPIC, matching AArch64ExecutionHelper#compile_with_cross_gcc's
  # kwarg of the same name and default (false), so a caller building the gcc
  # side of a differential case can pick its PIC-ness the same way on either
  # machine's oracle. Defaulted so every existing call site is unaffected.
  def compile_with_gcc(c_source, output_path, pic: false)
    dir = File.dirname(output_path)
    source_path = File.join(dir, "#{File.basename(output_path, ".*")}.c")
    File.write(source_path, c_source)

    args = execution_gcc_command("-c")
    args << "-fPIC" if pic
    stdout_and_stderr, status = Open3.capture2e(*args, "-o", output_path, source_path)
    unless status.success?
      raise "#{EXECUTION_GCC} failed to compile source (exit #{status.exitstatus}):\n#{stdout_and_stderr}"
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
      stdout, stderr, status = Open3.capture3(*execution_gcc_command("-E", "-P", source_path))
      raise "#{EXECUTION_GCC} failed to preprocess source (exit #{status.exitstatus}):\n#{stderr}" unless status.success?

      stdout
    end
  end

  # Links `object_path` into an executable, runs it, and returns
  # [exit_status, stdout] so callers can assert on either.
  def link_and_run(object_path)
    dir = File.dirname(object_path)
    exe_path = File.join(dir, "#{File.basename(object_path, ".*")}.out")

    stdout_and_stderr, status = Open3.capture2e(*execution_link_command("-o", exe_path, object_path))
    unless status.success?
      raise "#{EXECUTION_GCC} failed to link object file (exit #{status.exitstatus}):\n#{stdout_and_stderr}"
    end

    stdout, run_status = Open3.capture2(*execution_run_command(exe_path))
    [run_status.exitstatus, stdout]
  end

  # Like `link_and_run`, but also links against libm (`-lm`), for object
  # files that reference math functions (sqrt, sin, ...) resolved from a
  # separate archive on the host toolchain. Returns [stdout_and_stderr,
  # process_status] (unlike `link_and_run`) so callers can inspect both the
  # combined output and the exit status themselves.
  def link_and_run_with_libm(object_path)
    dir = File.dirname(object_path)
    exe_path = File.join(dir, "#{File.basename(object_path, ".*")}.out")

    stdout_and_stderr, status = Open3.capture2e(*execution_link_command("-o", exe_path, object_path, "-lm"))
    unless status.success?
      raise "#{EXECUTION_GCC} failed to link object file (exit #{status.exitstatus}):\n#{stdout_and_stderr}"
    end

    # Run with the executable's own scratch directory as the working directory,
    # not the test process's. Some c-testsuite cases exercise stdio by writing a
    # file through a *relative* path (00187.c does an fopen("fred.txt", "w")),
    # which would otherwise land in the repository root and stay there.
    Open3.capture2e(*execution_run_command(exe_path), chdir: dir)
  end

  # Links `object_path` into an executable and returns the linker's combined
  # stderr, so tests can assert it is warning-free (e.g. no missing
  # .note.GNU-stack executable-stack warning).
  def link_stderr(object_path)
    dir = File.dirname(object_path)
    exe_path = File.join(dir, "#{File.basename(object_path, ".*")}.out")
    _stdout, stderr, _status = Open3.capture3(*execution_link_command("-o", exe_path, object_path))
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
      stdout_and_stderr, status = Open3.capture2e(*execution_link_command("-o", exe_path, *object_paths))
      unless status.success?
        raise "#{EXECUTION_GCC} failed to link object files (exit #{status.exitstatus}):\n#{stdout_and_stderr}"
      end

      stdout, run_status = Open3.capture2(*execution_run_command(exe_path))
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
