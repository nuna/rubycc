# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

# Step 61 (M3 / ROADMAP §6 B6): the rubygems_plugin that makes a plain
# `gem install <native-ext-gem>` build through rubycc, plus the packaging that
# ships it. The offline tests pin the plugin's decision logic (RUBYCC=1/0/auto),
# its idempotent ENV injection and its zero-side-effect disabled path, and check
# the gemspec globs carry the new files. The networked end-to-end acceptance —
# install rubycc into a scratch GEM_HOME, then `RUBYCC=1 gem install json`
# (msgpack) and prove the build ran through rubycc and the result works — needs
# the gems off the network, so it is opt-in behind RMAKE_ACCEPTANCE=1.
#
# The plugin file runs `install!` at load time when enabled, so it is required
# once here with RUBYCC forced off (and ENV restored) to avoid mutating the test
# process; the module's methods are then exercised directly under a saved ENV.
class TestGemInstall < Minitest::Test
  REPO_ROOT   = File.expand_path("..", __dir__)
  PLUGIN_PATH = File.join(REPO_ROOT, "lib/rubygems_plugin.rb")
  RMAKE_EXE   = File.join(REPO_ROOT, "exe/rmake")
  PKGCONF_EXE = File.join(REPO_ROOT, "exe/rubycc-pkgconf")
  LIB_DIR     = File.join(REPO_ROOT, "lib")

  # Load the plugin without letting its bottom-line auto-install touch this
  # process's ENV: force it off across the require, then restore ENV.
  saved = ENV.to_hash
  ENV["RUBYCC"] = "0"
  require PLUGIN_PATH
  ENV.clear
  saved.each { |k, v| ENV[k] = v }

  Plugin = Rubycc::GemPlugin

  # Run the block with a private copy of ENV, restoring the original after.
  def with_env
    saved = ENV.to_hash
    yield
  ensure
    ENV.clear
    saved.each { |k, v| ENV[k] = v }
  end

  # --- decision logic -------------------------------------------------------

  def test_rubycc_1_forces_enabled
    with_env do
      ENV["RUBYCC"] = "1"
      ENV["PATH"] = "/usr/bin" # cc/gcc/make may be present; forced on regardless
      assert Plugin.enabled?
    end
  end

  def test_rubycc_0_forces_disabled
    with_env do
      ENV["RUBYCC"] = "0"
      ENV["PATH"] = "" # no tools at all; still off because forced
      refute Plugin.enabled?
    end
  end

  def test_auto_enables_when_no_toolchain_on_path
    with_env do
      ENV.delete("RUBYCC")
      ENV["PATH"] = Dir.mktmpdir # an empty directory: no cc/gcc/make
      assert Plugin.enabled?
    ensure
      FileUtils.rm_rf(ENV["PATH"]) if ENV["PATH"] && File.directory?(ENV["PATH"])
    end
  end

  def test_auto_disables_when_a_toolchain_tool_is_present
    with_env do
      ENV.delete("RUBYCC")
      Dir.mktmpdir do |bin|
        fake = File.join(bin, "make")
        File.write(fake, "#!/bin/sh\n")
        File.chmod(0o755, fake)
        ENV["PATH"] = bin
        refute Plugin.enabled?, "a `make` on PATH should keep the plugin off by default"
      end
    end
  end

  # --- ENV injection --------------------------------------------------------

  def test_install_injects_all_four_variables
    with_env do
      %w[MAKE PKG_CONFIG RUBYLIB RUBYOPT].each { |k| ENV.delete(k) }
      Plugin.install!

      assert_equal RMAKE_EXE, ENV["MAKE"]
      assert_equal PKGCONF_EXE, ENV["PKG_CONFIG"]
      assert_equal LIB_DIR, ENV["RUBYLIB"].split(File::PATH_SEPARATOR).first
      assert_includes ENV["RUBYOPT"].split(/\s+/), "-rrubycc/mkmf_shim"
    end
  end

  def test_install_is_idempotent
    with_env do
      %w[MAKE PKG_CONFIG RUBYLIB RUBYOPT].each { |k| ENV.delete(k) }
      Plugin.install!
      Plugin.install!

      assert_equal [LIB_DIR], ENV["RUBYLIB"].split(File::PATH_SEPARATOR)
      assert_equal ["-rrubycc/mkmf_shim"], ENV["RUBYOPT"].split(/\s+/)
    end
  end

  def test_install_preserves_existing_rubylib_and_rubyopt_entries
    with_env do
      ENV["RUBYLIB"] = "/existing/lib"
      ENV["RUBYOPT"] = "-rfoo"
      Plugin.install!

      assert_equal [LIB_DIR, "/existing/lib"], ENV["RUBYLIB"].split(File::PATH_SEPARATOR)
      assert_equal ["-rrubycc/mkmf_shim", "-rfoo"], ENV["RUBYOPT"].split(/\s+/)
    end
  end

  # The disabled path must be inert: requiring/deciding does not alter ENV.
  def test_disabled_plugin_has_no_side_effects
    with_env do
      ENV["RUBYCC"] = "0"
      before = ENV.to_hash
      # Mirror the file's bottom line: only install when enabled.
      Plugin.install! if Plugin.enabled?
      assert_equal before, ENV.to_hash, "a disabled plugin must not touch the environment"
    end
  end

  # --- packaging ------------------------------------------------------------

  def test_gemspec_ships_plugin_and_rmake
    require "rubygems"
    spec = Dir.chdir(REPO_ROOT) { Gem::Specification.load(File.join(REPO_ROOT, "rubycc.gemspec")) }
    assert_includes spec.files, "lib/rubygems_plugin.rb", "the plugin must be packaged"
    assert_includes spec.files, "exe/rmake", "exe/rmake must be packaged"
  end

  # --- networked end-to-end acceptance (opt-in) -----------------------------

  # Install rubycc into a scratch GEM_HOME so its plugin auto-loads, then
  # `RUBYCC=1 gem install json` — the plain install command, no extra flags —
  # and prove: it succeeded, an extension `.so` was produced, the built gem
  # actually works, and the build genuinely ran through exe/rmake + rubycc.
  def test_gem_install_json_builds_through_rubycc
    acceptance_gem_install("json", "2.21.1") do |gem_home|
      out = child_ruby(gem_home, <<~RUBY)
        gem "json"; require "json"
        print JSON.parse(JSON.generate({"a" => [1, 2, 3]}))["a"].sum
      RUBY
      assert_equal "6", out, "json round-trip must work in the built gem"
    end
  end

  def test_gem_install_msgpack_builds_through_rubycc
    acceptance_gem_install("msgpack", "1.8.3") do |gem_home|
      out = child_ruby(gem_home, <<~RUBY)
        gem "msgpack"; require "msgpack"
        packed = MessagePack::Packer.new.write([1, "x", true]).to_s
        print MessagePack::Unpacker.new.feed(packed).read.inspect
      RUBY
      assert_equal '[1, "x", true]', out, "msgpack pack/unpack round-trip must work"
    end
  end

  # --- hermetic (bundled-headers-only) acceptance (opt-in) ------------------
  #
  # The M3 distroless criterion (Step 64): the same plain `gem install`, but with
  # RUBYCC_HERMETIC_HEADERS=1 so rubycc drops the host libc directories from its
  # search path and compiles every translation unit against its bundled headers
  # alone -- the posture a headerless (distroless) image forces. This proves the
  # bundled first batch carries everything json/msgpack reach for, end to end
  # through a real RubyGems install, and that no conftest or build step quietly
  # borrowed a declaration from /usr/include. (mkmf's conftests still *link*
  # against the host libc.so -- the linker reads only the .so binary, no dev
  # headers, per DESIGN 4.2 -- so that is expected and not asserted against.)

  def test_gem_install_json_hermetic_headers
    acceptance_gem_install("json", "2.21.1", hermetic: true) do |gem_home|
      out = child_ruby(gem_home, <<~RUBY)
        gem "json"; require "json"
        print JSON.parse(JSON.generate({"a" => [1, 2, 3]}))["a"].sum
      RUBY
      assert_equal "6", out, "json round-trip must work in the hermetically built gem"
    end
  end

  def test_gem_install_msgpack_hermetic_headers
    acceptance_gem_install("msgpack", "1.8.3", hermetic: true) do |gem_home|
      out = child_ruby(gem_home, <<~RUBY)
        gem "msgpack"; require "msgpack"
        packed = MessagePack::Packer.new.write([1, "x", true]).to_s
        print MessagePack::Unpacker.new.feed(packed).read.inspect
      RUBY
      assert_equal '[1, "x", true]', out, "msgpack round-trip must work in the hermetically built gem"
    end
  end

  private

  # Build+install rubycc into a fresh GEM_HOME, install +name+-+version+ from the
  # network with RUBYCC=1, assert success and a produced .so, verify the build
  # went through exe/rmake and rubycc (gem_make.out evidence), and yield the
  # GEM_HOME so the caller can require and drive the built gem.
  def acceptance_gem_install(name, version, hermetic: false)
    skip "set RMAKE_ACCEPTANCE=1 to run the networked gem-install acceptance" unless ENV["RMAKE_ACCEPTANCE"] == "1"

    Dir.mktmpdir("rubycc-gem-install") do |gem_home|
      install_rubycc_into(gem_home)

      env = { "RUBYCC" => "1", "GEM_HOME" => gem_home, "GEM_PATH" => gem_home }
      env["RUBYCC_HERMETIC_HEADERS"] = "1" if hermetic
      out, status = Open3.capture2e(env, "gem", "install", name, "--version", version,
                                    "--install-dir", gem_home, "--no-document")
      assert status.success?, "gem install #{name} failed:\n#{out}"

      sos = Dir.glob(File.join(gem_home, "gems", "#{name}-#{version}", "**", "*.so"))
      refute_empty sos, "#{name} should have produced at least one .so"

      assert_build_used_rubycc(gem_home, name)
      assert_no_host_include_headers(gem_home, name) if hermetic
      yield gem_home
    end
  end

  # Package rubycc from this checkout and install it into +gem_home+ so its
  # rubygems_plugin is discovered when the next `gem install` runs there.
  def install_rubycc_into(gem_home)
    gem_file = File.join(gem_home, "rubycc.gem")
    out, status = Open3.capture2e({ "GEM_HOME" => gem_home }, "gem", "build", "rubycc.gemspec",
                                  "--output", gem_file, chdir: REPO_ROOT)
    assert status.success?, "gem build rubycc failed:\n#{out}"

    out, status = Open3.capture2e({ "GEM_HOME" => gem_home, "GEM_PATH" => gem_home },
                                  "gem", "install", gem_file, "--install-dir", gem_home,
                                  "--local", "--no-document")
    assert status.success?, "installing rubycc into the scratch GEM_HOME failed:\n#{out}"
  end

  # The proof the build was rubycc's, from the transcripts RubyGems leaves in the
  # install tree:
  #   * gem_make.out records every command RubyGems ran, so its `$(MAKE)` line is
  #     `.../exe/rmake DESTDIR= sitearchdir=<tmp> sitelibdir=<tmp> [target]` —
  #     rmake is rubycc's build-only make, which always substitutes rubycc for the
  #     compiler, so its presence as MAKE is itself the proof;
  #   * mkmf.log records the actual conftest command lines mkmf ran, which name
  #     the rubycc executable as the compiler (the mkmf_shim's `CC = <rubycc>`).
  def assert_build_used_rubycc(gem_home, name)
    make_logs = Dir.glob(File.join(gem_home, "**", "gem_make.out"))
    refute_empty make_logs, "gem_make.out should exist for #{name}"
    make_out = make_logs.map { |f| File.read(f) }.join("\n")
    assert_match(%r{gems/rubycc-[^/]+/exe/rmake}, make_out, "the build's $(MAKE) must be rubycc's exe/rmake")

    mkmf_logs = Dir.glob(File.join(gem_home, "**", "mkmf.log"))
    refute_empty mkmf_logs, "mkmf.log should exist for #{name}"
    mkmf_out = mkmf_logs.map { |f| File.read(f) }.join("\n")
    assert_match(%r{gems/rubycc-[^/]+/exe/rubycc}, mkmf_out, "conftests must have run through the rubycc compiler")
  end

  # The host libc development-header directories rubycc drops in hermetic mode
  # (the same set Preprocessor::LIBC_SYSTEM_INCLUDE_PATHS carries). A hermetic
  # build must never pass one of these on a compile command line.
  HOST_LIBC_INCLUDE_DIRS = %w[/usr/include/x86_64-linux-gnu /usr/include].freeze

  # Best-effort evidence, from the RubyGems install transcripts, that the
  # hermetic build did not reach into the host libc development headers. The
  # strong guarantee is structural: RUBYCC_HERMETIC_HEADERS=1 makes rubycc drop
  # the host libc directories from its own default search path, so a translation
  # unit that needed a host-only declaration would have failed the build outright
  # (which it did not, since we got here). As a corroborating check, neither
  # transcript may show a host libc include directory passed on a compile command
  # line -- mkmf/extconf must not have injected one. The ruby header dir and the
  # libc.so the linker binds against (DESIGN 4.2: the linker reads only the .so
  # binary, no dev headers) are legitimate host paths and are not what this
  # checks.
  def assert_no_host_include_headers(gem_home, name)
    logs = Dir.glob(File.join(gem_home, "**", "gem_make.out")) +
           Dir.glob(File.join(gem_home, "**", "mkmf.log"))
    refute_empty logs, "install transcripts should exist for #{name}"
    logs.each do |path|
      File.foreach(path) do |line|
        HOST_LIBC_INCLUDE_DIRS.each do |dir|
          refute_match(/-I\s*#{Regexp.escape(dir)}(?:\s|\z)/, line,
                       "#{File.basename(path)} passed host libc include #{dir}:\n#{line}")
        end
      end
    end
  end

  # Run a one-liner in a child Ruby with the scratch GEM_HOME active, returning
  # its stdout. Fails the test if the child does not exit cleanly.
  def child_ruby(gem_home, script)
    env = { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home }
    out, status = Open3.capture2e(env, RbConfig.ruby, "-e", script)
    assert status.success?, "child Ruby using the built gem failed:\n#{out}"
    out
  end
end
