# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../tools/qemu_aarch64_preflight"

class TestQemuAArch64Preflight < Minitest::Test
  Preflight = Rubycc::QemuAArch64Preflight

  def test_native_aarch64_docker_daemon_does_not_need_a_probe
    calls = []
    runner = lambda do |*command|
      calls << command
      ["aarch64\n", true]
    end

    result = Preflight.check("ruby:4.0", runner: runner)

    assert result.success?
    assert_equal :ready, result.state
    assert_equal [["docker", "info", "--format", "{{.Architecture}}"]], calls
  end

  def test_probe_success_allows_an_x86_docker_daemon
    calls = []
    runner = lambda do |*command|
      calls << command
      calls.length == 1 ? ["amd64\n", true] : ["", true]
    end

    result = Preflight.check("ruby:4.0", runner: runner)

    assert result.success?
    assert_equal [
      "docker", "run", "--rm", "--platform", "linux/arm64",
      "--entrypoint", "/bin/true", "ruby:4.0"
    ], calls.fetch(1)
  end

  def test_exec_failure_becomes_an_actionable_binfmt_result
    runner = lambda do |*command|
      command.first(2) == ["docker", "info"] ? ["x86_64\n", true] :
        ["exec /bin/true: exec format error\n", false]
    end
    Dir.mktmpdir do |dir|
      path = File.join(dir, "qemu-aarch64")
      File.write(path, "enabled\nflags: PO\n")

      result = Preflight.check("ruby:4.0", runner: runner, binfmt_path: path)

      refute result.success?
      assert_equal :binfmt, result.state
      assert_includes result.message, "F フラグ付き"
      assert_includes result.message, "F フラグなし"
      refute_includes result.message, "exec format error"
    end
  end

  def test_interpreter_missing_is_also_classified_as_binfmt
    runner = lambda do |*command|
      command.first(2) == ["docker", "info"] ? ["x86_64\n", true] :
        ["exec /bin/true: no such file or directory\n", false]
    end

    result = Preflight.check("ruby:4.0", runner: runner)

    assert_equal :binfmt, result.state
  end

  def test_unrelated_docker_failure_is_not_misdiagnosed
    runner = lambda do |*command|
      command.first(2) == ["docker", "info"] ? ["x86_64\n", true] :
        ["permission denied while connecting to the Docker daemon\n", false]
    end

    result = Preflight.check("ruby:4.0", runner: runner)

    refute result.success?
    assert_equal :docker, result.state
    assert_includes result.message, "binfmt の問題とは断定できません"
    assert_includes result.message, "permission denied"
  end

  def test_binfmt_diagnostic_reports_f_flag
    Dir.mktmpdir do |dir|
      path = File.join(dir, "qemu-aarch64")
      File.write(path, "enabled\nflags: POCF\n")

      assert_includes Preflight.binfmt_diagnostic(path), "F フラグあり"
    end
  end
end
