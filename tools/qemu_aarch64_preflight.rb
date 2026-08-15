# frozen_string_literal: true

# Check that the Docker daemon can execute the arm64 base image before the
# QEMU acceptance image is built.  The Docker daemon is the authority here:
# the client's /proc may describe a different host when Docker is remote or
# runs inside a desktop VM.

require "open3"

module Rubycc
  module QemuAArch64Preflight
    BINFMT_PATH = "/proc/sys/fs/binfmt_misc/qemu-aarch64"
    ARM64_ARCHITECTURES = %w[aarch64 arm64].freeze

    Result = Struct.new(
      :state,
      :message,
      :daemon_architecture,
      :probe_output,
      :binfmt_diagnostic,
      keyword_init: true
    ) do
      def success?
        state == :ready
      end
    end

    module_function

    def check(base_image, runner: nil, binfmt_path: BINFMT_PATH)
      raise ArgumentError, "base_image must not be empty" if base_image.to_s.strip.empty?

      runner ||= method(:capture)
      architecture_output, architecture_status = runner.call(
        "docker", "info", "--format", "{{.Architecture}}"
      )
      unless command_success?(architecture_status)
        return docker_failure(
          "Docker デーモンの architecture を取得できません。",
          architecture_output
        )
      end

      architecture = architecture_output.to_s.strip
      if arm64_architecture?(architecture)
        return Result.new(
          state: :ready,
          message: nil,
          daemon_architecture: architecture,
          probe_output: nil,
          binfmt_diagnostic: nil
        )
      end

      probe_output, probe_status = runner.call(
        "docker", "run", "--rm", "--platform", "linux/arm64",
        "--entrypoint", "/bin/true", base_image
      )
      return Result.new(
        state: :ready,
        message: nil,
        daemon_architecture: architecture,
        probe_output: probe_output.to_s,
        binfmt_diagnostic: nil
      ) if command_success?(probe_status)

      if binfmt_failure?(probe_output)
        diagnostic = binfmt_diagnostic(binfmt_path)
        return Result.new(
          state: :binfmt,
          message: <<~MESSAGE.strip,
            Docker の linux/arm64 コンテナを起動できません。Docker ホストの
            binfmt_misc に F フラグ付きの AArch64 ハンドラを登録するか、
            docs/internals/CI.md に記載した qemu の bind-mount 手順を使ってください。
            クライアント側の参考情報: #{diagnostic}
          MESSAGE
          daemon_architecture: architecture,
          probe_output: probe_output.to_s,
          binfmt_diagnostic: diagnostic
        )
      end

      docker_failure(
        "Docker の linux/arm64 実行 probe に失敗しました。binfmt の問題とは断定できません。",
        probe_output,
        daemon_architecture: architecture
      )
    end

    def arm64_architecture?(architecture)
      ARM64_ARCHITECTURES.include?(architecture.to_s.strip.downcase)
    end

    def binfmt_failure?(output)
      text = output.to_s.downcase
      text.include?("exec format error") ||
        text.match?(/exec[^\n]*no such file or directory/) ||
        text.match?(/no such file or directory[^\n]*(?:qemu|interpreter)/)
    end

    def binfmt_diagnostic(path = BINFMT_PATH)
      return "#{path} がありません(ハンドラの状態を取得できません)" unless File.file?(path)

      text = File.read(path)
      flags = text[/^flags:\s*(\S+)/, 1]
      return "#{path} に flags がありません" if flags.to_s.empty?

      suffix = flags.include?("F") ? "F フラグあり" : "F フラグなし"
      "#{path}: flags=#{flags}(#{suffix})"
    rescue SystemCallError => e
      "#{path} を読めません(#{e.class}: #{e.message})"
    end

    def capture(*command)
      Open3.capture2e(*command)
    rescue SystemCallError => e
      ["#{e.class}: #{e.message}", false]
    end

    def command_success?(status)
      status.respond_to?(:success?) ? status.success? : status == true
    end

    def docker_failure(prefix, output, daemon_architecture: nil)
      detail = output.to_s.lines.map(&:strip).reject(&:empty?).last(3).join(" ")
      detail = "出力なし" if detail.empty?
      Result.new(
        state: :docker,
        message: [prefix, detail].join(" "),
        daemon_architecture: daemon_architecture,
        probe_output: output.to_s,
        binfmt_diagnostic: nil
      )
    end
  end
end
