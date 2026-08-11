# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require "open3"
require_relative "execution_helper"

# Helpers for guarantees that require the Ruby process, dynamic loader and libc
# themselves to be AArch64. QEMU target execution is intentionally not used
# here; that is covered by AArch64ExecutionHelper.
module NativeAArch64Helper
  NATIVE_INCLUDE_PATHS = [
    Rubycc::Preprocess::Preprocessor::BUNDLED_INCLUDE_DIR,
    "/usr/include/aarch64-linux-gnu",
    "/usr/include"
  ].freeze

  def native_aarch64?
    host_cpu = RbConfig::CONFIG["host_cpu"].to_s
    ruby_arch = RbConfig::CONFIG["arch"].to_s
    host_cpu.match?(/\A(?:aarch64|arm64)\z/i) && ruby_arch.match?(/(?:aarch64|arm64)/i)
  end

  def native_context
    uname_machine, = Open3.capture2("uname", "-m")
    gcc_machine, gcc_status = Open3.capture2("gcc", "-dumpmachine")
    {
      uname_machine: uname_machine.to_s.strip,
      ruby_host_cpu: RbConfig::CONFIG["host_cpu"].to_s,
      ruby_arch: RbConfig::CONFIG["arch"].to_s,
      gcc_machine: gcc_status.success? ? gcc_machine.to_s.strip : "unavailable"
    }
  rescue SystemCallError
    {
      uname_machine: "unavailable",
      ruby_host_cpu: RbConfig::CONFIG["host_cpu"].to_s,
      ruby_arch: RbConfig::CONFIG["arch"].to_s,
      gcc_machine: "unavailable"
    }
  end

  def skip_unless_native_aarch64
    return if native_aarch64?

    if ENV["NATIVE_AARCH64_REQUIRED"] == "1"
      raise Minitest::Assertion, "CI requested native AArch64 but Ruby is " \
                                 "#{RbConfig::CONFIG["host_cpu"]}/#{RbConfig::CONFIG["arch"]}"
    end

    skip "native AArch64 smoke runs only on an AArch64 Ruby runner"
  end

  def compile_native_target(source, object_path, pic: false)
    kwargs = {
      filename: "#{File.basename(object_path, ".*")}.c", target: "aarch64", pic: pic,
      include_paths: NATIVE_INCLUDE_PATHS, system_includes: false
    }
    File.binwrite(object_path, Rubycc::Compiler.new.compile(source, **kwargs))
    object_path
  end

  def compile_with_native_gcc(source, object_path, pic: false)
    dir = File.dirname(object_path)
    source_path = File.join(dir, "#{File.basename(object_path, ".*")}.c")
    File.write(source_path, source)
    # Native Debian GCC also defaults to PIE. Keep the non-PIC native oracle
    # explicit, matching ExecutionHelper's ordinary differential path.
    args = ["gcc", "-c", ExecutionHelper::REFERENCE_STD_FLAG, pic ? "-fPIC" : "-fno-pie"]
    output, status = Open3.capture2e(*args, "-o", object_path, source_path)
    raise "native gcc failed (exit #{status.exitstatus}):\n#{output}" unless status.success?

    object_path
  end

  def link_and_run_native(object_path)
    dir = File.dirname(object_path)
    executable = File.join(dir, "#{File.basename(object_path, ".*")}.out")
    output, status = Open3.capture2e("gcc", "-no-pie", "-o", executable, object_path)
    raise "native gcc link failed (exit #{status.exitstatus}):\n#{output}" unless status.success?

    stdout, run_status = Open3.capture2(executable, chdir: dir)
    [run_status.exitstatus, stdout]
  end

  def link_objects_and_run_native(object_paths, executable_path)
    output, status = Open3.capture2e("gcc", "-no-pie", "-o", executable_path, *object_paths)
    raise "native gcc link failed (exit #{status.exitstatus}):\n#{output}" unless status.success?

    stdout, run_status = Open3.capture2e(executable_path, chdir: File.dirname(executable_path))
    [run_status.exitstatus, stdout]
  end
end
