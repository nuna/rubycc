# frozen_string_literal: true

# A native-only preflight for the focused AArch64 acceptance job. It records
# measured values rather than trusting CI_HOST/CI_TARGET declarations, and it
# writes a required result even when the runner is accidentally x86_64.

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "ci_result"

PROFILE = ENV.fetch("CI_PROFILE", "native-aarch64-smoke")
RESULT_PATH = ENV.fetch("CI_RESULT_PATH", "tmp/ci/native-aarch64-results.json")
CONTEXT_PATH = ENV.fetch("CI_NATIVE_CONTEXT_PATH", "tmp/ci/native-aarch64-context.json")

def command_output(*command)
  output, status = Open3.capture2e(*command)
  [output.to_s.strip, status.success?]
rescue SystemCallError => e
  ["#{e.class}: #{e.message}", false]
end

def run_ruby_header_probe
  rubyhdrdir = RbConfig::CONFIG["rubyhdrdir"].to_s
  rubyarchhdrdir = RbConfig::CONFIG["rubyarchhdrdir"].to_s
  return ["Ruby header directory is unavailable", false] if rubyhdrdir.empty?

  Dir.mktmpdir("rubycc-native-preflight") do |dir|
    source = File.join(dir, "ruby_header_probe.c")
    File.write(source, <<~C)
      #include <ruby.h>
      int main(void) { return (int)sizeof(VALUE); }
    C
    include_dirs = [rubyhdrdir, rubyarchhdrdir].reject(&:empty?).flat_map { |path| ["-I", path] }
    command_output("gcc", *include_dirs, "-fsyntax-only", source)
  end
rescue SystemCallError => e
  ["#{e.class}: #{e.message}", false]
end

def write_json(path, value)
  FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
  File.write(path, JSON.pretty_generate(value) + "\n")
end

def record_result(result)
  path = File.expand_path(RESULT_PATH)
  FileUtils.mkdir_p(File.dirname(path))
  lock_path = "#{path}.lock"
  File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
    lock.flock(File::LOCK_EX)
    document = if File.file?(path) && File.size(path).positive?
                 Rubycc::CIResult.read(path)
               else
                 Rubycc::CIResult.document(results: [], metadata: result.slice(
                   "profile", "host", "target", "runner", "libc", "network"
                 ))
               end
    results = document.fetch("results")
    if results.any? { |entry| entry["id"] == result["id"] }
      raise Rubycc::CIResult::Error, "duplicate native preflight result"
    end
    results << result
    Rubycc::CIResult.write(path, results: results, metadata: document.fetch("metadata"))
  ensure
    lock.flock(File::LOCK_UN) if lock
  end
end

uname_machine, uname_ok = command_output("uname", "-m")
ruby_host_cpu = RbConfig::CONFIG["host_cpu"].to_s
ruby_arch = RbConfig::CONFIG["arch"].to_s
gcc_machine, gcc_ok = command_output("gcc", "-dumpmachine")
gcc_version, gcc_version_ok = command_output("gcc", "--version")
libc_version, libc_ok = command_output("ldd", "--version")
ruby_elf, ruby_elf_ok = command_output("readelf", "-h", RbConfig.ruby)
ruby_dependencies, ruby_dependencies_ok = command_output("ldd", RbConfig.ruby)
ruby_header_probe_output, ruby_header_probe_ok = run_ruby_header_probe
fiddle_probe, fiddle_probe_ok = command_output(
  RbConfig.ruby, "-rfiddle", "-e", "Fiddle::Handle.new(nil); puts Fiddle::VERSION"
)
fiddle_ok = begin
  require "fiddle"
  true
rescue LoadError
  false
end
rubyhdrdir = RbConfig::CONFIG["rubyhdrdir"].to_s
loader_candidates = [
  "/lib/ld-linux-aarch64.so.1",
  "/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1",
  "/lib64/ld-linux-aarch64.so.1"
]
loader = loader_candidates.find { |path| File.file?(path) }

context = {
  "uname_machine" => uname_machine,
  "uname_ok" => uname_ok,
  "ruby_host_cpu" => ruby_host_cpu,
  "ruby_arch" => ruby_arch,
  "gcc_machine" => gcc_machine,
  "gcc_ok" => gcc_ok,
  "gcc_version" => gcc_version,
  "gcc_version_ok" => gcc_version_ok,
  "fiddle_available" => fiddle_ok,
  "fiddle_probe" => fiddle_probe,
  "fiddle_probe_ok" => fiddle_probe_ok,
  "rubyhdrdir" => rubyhdrdir,
  "ruby_headers_available" => File.directory?(rubyhdrdir),
  "ruby_header_probe" => ruby_header_probe_output,
  "ruby_header_probe_ok" => ruby_header_probe_ok,
  "ruby_elf" => ruby_elf,
  "ruby_elf_ok" => ruby_elf_ok,
  "ruby_dependencies" => ruby_dependencies,
  "ruby_dependencies_ok" => ruby_dependencies_ok,
  "loader" => loader,
  "libc_version" => libc_version,
  "libc_ok" => libc_ok
}
write_json(CONTEXT_PATH, context)

failures = []
failures << "uname -m=#{uname_machine.inspect}" unless uname_ok && uname_machine.match?(/\A(?:aarch64|arm64)\z/i)
failures << "Ruby host_cpu=#{ruby_host_cpu.inspect}" unless ruby_host_cpu.match?(/\A(?:aarch64|arm64)\z/i)
failures << "Ruby arch=#{ruby_arch.inspect}" unless ruby_arch.match?(/(?:aarch64|arm64)/i)
failures << "gcc -dumpmachine=#{gcc_machine.inspect}" unless gcc_ok && gcc_machine.match?(/aarch64/i)
failures << "gcc unavailable" unless gcc_version_ok
failures << "Fiddle unavailable" unless fiddle_ok
failures << "Fiddle loader probe failed: #{fiddle_probe.inspect}" unless fiddle_probe_ok
failures << "Ruby headers unavailable at #{rubyhdrdir.inspect}" unless File.directory?(rubyhdrdir)
failures << "Ruby header compile probe failed: #{ruby_header_probe_output.inspect}" unless ruby_header_probe_ok
failures << "Ruby ELF inspection failed: #{ruby_elf.inspect}" unless ruby_elf_ok
failures << "Ruby ELF is not AArch64" unless ruby_elf.match?(/Machine:\s+AArch64/i)
failures << "Ruby dynamic dependency inspection failed: #{ruby_dependencies.inspect}" unless ruby_dependencies_ok
failures << "AArch64 dynamic loader unavailable" unless loader
failures << "libc unavailable" unless libc_ok

metadata = {
  profile: PROFILE,
  host: ENV.fetch("CI_HOST", "aarch64"),
  target: ENV.fetch("CI_TARGET", "aarch64"),
  runner: ENV.fetch("CI_RUNNER", "native-aarch64"),
  libc: ENV.fetch("CI_LIBC", "glibc"),
  network: ENV.fetch("CI_NETWORK", "none")
}
result = Rubycc::CIResult.result(
  id: "native-aarch64-preflight",
  state: failures.empty? ? "pass" : "fail",
  reason: failures.empty? ? nil : failures.join("; "),
  **metadata,
  **context
)
record_result(result)

puts JSON.pretty_generate(context)
if failures.empty?
  puts "native-aarch64-preflight: pass"
  exit 0
end

warn "native-aarch64-preflight: fail: #{failures.join("; ")}"
exit 1
