# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "open3"
require "set"
require_relative "support/acceptance_fetch_helper"
require_relative "support/acceptance_manifest_helper"
require_relative "support/acceptance_result_reporter"

# Step 60 (M3 / ROADMAP §6 B5): conftest 完全対応(mkmf 統合 shim)。
#
# lib/rubycc/mkmf_shim.rb を require すると、mkmf が conftest コマンドを組み立てる
# RbConfig の CC / LDSHARED / CPP / PKG_CONFIG が rubycc 実行ファイルへ差し替わる。
# ここでは shim を読み込んだ *子プロセス* で本物の mkmf を動かし、代表的な probe
# API(have_header / have_func / have_library / try_compile / try_link / try_run /
# check_sizeof)が gcc と同じ真偽・値を返すこと、mkmf.log が本物の体裁で rubycc の
# コマンド行と "checked program was" 節を残すことを検証する。
#
# msgpack / json の extconf 再現(ネットワーク使用)は RMAKE_ACCEPTANCE=1 の opt-in
# ガード付きで、生成 Makefile の probe 結果(-DHAVE_* 集合)を Step 55 採取 fixtures と
# 突き合わせる。
class TestMkmfConftest < Minitest::Test
  LIB_DIR    = File.expand_path("../lib", __dir__)
  EXE_PATH   = File.expand_path("../exe/rubycc", __dir__)
  PKGCONF_PATH = File.expand_path("../exe/rubycc-pkgconf", __dir__)
  # What the shim writes as `CC`: this interpreter, then the executable.
  CC_COMMAND = "#{RbConfig.ruby} #{EXE_PATH}"
  FIXTURES_ROOT = File.expand_path("fixtures/mkmf", __dir__)

  # Runs `ruby_body` in a child interpreter that has loaded the mkmf shim and
  # then `require "mkmf"`, inside a fresh working directory. mkmf's console
  # chatter is redirected to a file (it still writes mkmf.log in the cwd); only
  # the Marshal-encoded value the body assigns to `result` reaches the parent,
  # plus the mkmf.log contents. Returns [result, mkmf_log, stderr, status].
  def run_in_mkmf(ruby_body)
    script = <<~RUBY
      require "rubycc/mkmf_shim"
      require "tmpdir"
      require "fileutils"
      work = Dir.mktmpdir("rubycc_mkmf")
      Dir.chdir(work)
      real_out = STDOUT.dup
      chatter = File.open("mkmf_stdout.log", "w")
      STDOUT.reopen(chatter)
      $stdout = chatter
      require "mkmf"
      result = nil
      begin
        #{ruby_body}
      ensure
        $stdout = STDOUT
        STDOUT.reopen(real_out)
        log = File.exist?("mkmf.log") ? File.read("mkmf.log") : ""
        real_out.write(Marshal.dump([result, log]))
        real_out.flush
      end
    RUBY

    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB_DIR}", "-e", script)
    result, log =
      begin
        Marshal.load(out)
      rescue ArgumentError, TypeError
        [nil, ""]
      end
    [result, log, err, status]
  end

  # --- the probe API surface, driven through real mkmf -----------------------

  def test_conftest_probe_api_matches_gcc_truth
    AcceptanceResultReporter.with_result("mkmf-fixture-probes") do
      result, _log, err, status = run_in_mkmf(<<~RUBY)
        result = {
          hdr_present: have_header("stdio.h"),
          hdr_missing: have_header("rubycc_definitely_no_such_header.h"),
          func_present: have_func("printf"),
          func_missing: have_func("rubycc_no_such_func_xyz"),
          lib_crc32: have_library("z", "crc32"),
          compile: try_compile("int main(void){return 0;}"),
          link: try_link("int main(void){return 0;}"),
          run: try_run("int main(void){return 0;}"),
          sizeof_int: check_sizeof("int"),
          sizeof_long: check_sizeof("long")
        }
      RUBY

      assert status.success?, "the mkmf child exited nonzero:\n#{err}"
      refute_nil result, "no Marshal result from the mkmf child:\n#{err}"

      assert_equal true, result[:hdr_present], "have_header('stdio.h') should be true"
      assert_equal false, result[:hdr_missing], "have_header of a missing header should be false"
      assert_equal true, result[:func_present], "have_func('printf') should be true"
      assert_equal false, result[:func_missing], "have_func of a missing function should be false"
      assert_equal true, result[:lib_crc32], "have_library('z','crc32') should be true"
      assert_equal true, result[:compile], "try_compile of a trivial program should be true"
      assert_equal true, result[:link], "try_link of a trivial program should be true"
      assert_equal true, result[:run], "try_run of an exit-0 program should be true"
      assert_equal 4, result[:sizeof_int], "check_sizeof('int') should be 4"
      assert_equal 8, result[:sizeof_long], "check_sizeof('long') should be 8"
    end
  end

  # mkmf.log is written by mkmf itself, so its format is the genuine article:
  # the shim only changes which program the echoed command lines name. It must
  # record rubycc's compile command and the "checked program was" source dump.
  def test_mkmf_log_records_rubycc_commands_and_program
    _result, log, err, status = run_in_mkmf(<<~RUBY)
      result = have_func("printf")
    RUBY

    assert status.success?, "the mkmf child exited nonzero:\n#{err}"
    refute_empty log, "mkmf.log should have been written"
    assert_includes log, EXE_PATH, "mkmf.log should echo the rubycc executable in its command lines"
    assert_includes log, "checked program was:", "mkmf.log should keep the checked-program section"
  end

  # The shim rewrites exactly the toolchain keys, in both RbConfig hashes, and
  # leaves everything else (CXX, the include flags, the ruby header dirs) intact.
  # Each rewritten command launches rubycc through the interpreter (Step
  # env-less-shebang-1), never through the executable's own shebang line.
  def test_shim_rewrites_toolchain_config_keys
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-I#{LIB_DIR}", "-e", <<~RUBY
        require "rubycc/mkmf_shim"
        keys = %w[CC LDSHARED CPP CXX PKG_CONFIG]
        data = {}
        keys.each { |k| data["CONFIG:\#{k}"] = RbConfig::CONFIG[k] }
        keys.each { |k| data["MAKEFILE:\#{k}"] = RbConfig::MAKEFILE_CONFIG[k] }
        STDOUT.write(Marshal.dump(data))
      RUBY
    )
    assert status.success?, err
    data = Marshal.load(out)

    assert_equal CC_COMMAND, data["CONFIG:CC"]
    assert_equal "#{CC_COMMAND} -shared", data["CONFIG:LDSHARED"]
    assert_equal "#{CC_COMMAND} -E", data["CONFIG:CPP"]
    # MAKEFILE_CONFIG is rewritten too, so the generated Makefile's CC line is rubycc.
    assert_equal CC_COMMAND, data["MAKEFILE:CC"]
    assert_equal "#{CC_COMMAND} -shared", data["MAKEFILE:LDSHARED"]
    # CXX is deliberately untouched (rubycc compiles no C++).
    refute_includes data["CONFIG:CXX"].to_s, EXE_PATH
    # PKG_CONFIG is the exception that stays a bare path: mkmf resolves it with
    # find_executable0, which stats the value as one file name, so a two-word
    # command would simply not be found. The interpreter is supplied at spawn
    # time instead (see the pkg-config array test below).
    assert_equal PKGCONF_PATH, data["CONFIG:PKG_CONFIG"]
  end

  # The interpreter named in CC is *this* Ruby, not whatever `ruby` the PATH
  # would find: the compiler has to run under the Ruby the gem is being
  # installed into, or it compiles against another one's RbConfig.
  def test_rewritten_commands_name_the_running_interpreter
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-I#{LIB_DIR}", "-e", <<~RUBY
        require "rubycc/mkmf_shim"
        STDOUT.write(Marshal.dump(RbConfig::CONFIG["CC"].split(" ", 2)))
      RUBY
    )
    assert status.success?, err
    interpreter, program = Marshal.load(out)

    assert_equal RbConfig.ruby, interpreter, "CC must launch rubycc through this very Ruby"
    assert_equal EXE_PATH, program
    assert File.file?(interpreter), "the interpreter word must be an absolute path to a real file"
  end

  # The pkg-config path, driven through mkmf's real `pkg_config` rather than a
  # stand-in: mkmf resolves `$PKGCONFIG` with find_executable0 (so the config
  # value has to stay a single stat-able path), probes with `xsystem([env, prog,
  # "--exists", pkg])` and then reads the flags with `xpopen([env, prog, ...])`.
  # Both spawns are arrays that reach the kernel verbatim, so it is the shim that
  # has to put the interpreter in front of them — and both carry a leading env
  # hash here, because dir_config found a `pkgconfig` directory and mkmf passes
  # PKG_CONFIG_PATH that way. The answer has to come back from the real
  # rubycc-pkgconf reading a real .pc file.
  def test_pkg_config_reads_a_real_pc_file_through_the_shim
    result, log, err, status = run_in_mkmf(<<~RUBY)
      prefix = File.join(Dir.pwd, "fake")
      FileUtils.mkdir_p(File.join(prefix, "lib", "pkgconfig"))
      FileUtils.mkdir_p(File.join(prefix, "include"))
      File.write(File.join(prefix, "lib", "pkgconfig", "rubyccprobe.pc"), <<~PC)
        Name: rubyccprobe
        Description: a .pc file written by the rubycc test suite
        Version: 4.5.6
        Cflags: -I\#{prefix}/include
        Libs: -L\#{prefix}/lib -lm
      PC
      # What `--with-rubyccprobe-lib=<dir>` would have set: it is what makes mkmf
      # pass PKG_CONFIG_PATH as the leading env hash of both spawns.
      $configure_args["--with-rubyccprobe-lib"] = File.join(prefix, "lib")
      result = {
        pkgconfig: RbConfig::CONFIG["PKG_CONFIG"],
        prefix: prefix,
        cflags: pkg_config("rubyccprobe", "cflags"),
        modversion: pkg_config("rubyccprobe", "modversion"),
        missing: pkg_config("rubycc_no_such_package_xyz", "cflags")
      }
    RUBY

    assert status.success?, "the mkmf child exited nonzero:\n#{err}"
    refute_nil result, "no Marshal result from the mkmf child:\n#{err}"

    assert_equal "-I#{result[:prefix]}/include", result[:cflags],
                 "pkg_config must return the Cflags rubycc-pkgconf read out of the .pc file"
    assert_equal "4.5.6", result[:modversion]
    assert_nil result[:missing], "a package with no .pc file must come back as not found"

    # The command mkmf logged is the one it spawned: interpreter first, then the
    # pkg-config shim — which is the only reason the array spawn does not have to
    # resolve `#!/usr/bin/env ruby`.
    assert_includes log, "#{RbConfig.ruby} #{PKGCONF_PATH}",
                     "mkmf.log must show pkg-config being launched through the interpreter"
    assert_includes log, "PKG_CONFIG_PATH", "the probe must have carried the env hash"
  end

  # A command has to travel as one string (`CC = ...` in the generated Makefile,
  # `ENV["MAKE"]` for RubyGems), so its words are quoted: an installation path is
  # allowed to contain a space, and an unquoted one would split into two
  # arguments and take the build apart. Both splitters that read the value back —
  # rubycc's own, and the Shellwords RubyGems uses — must return the paths whole.
  # Run in a child, like everything else here, because requiring the shim
  # rewrites the requiring process's RbConfig.
  def test_launcher_words_are_quoted_for_paths_with_spaces
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-I#{LIB_DIR}", "-e", <<~RUBY
        require "rubycc/mkmf_shim"
        require "shellwords"
        spaced = Rubycc::MkmfShim.launcher("/opt/ruby 4.0/bin/ruby", "/gems/rubycc 1.0.0/exe/rubycc")
        data = {
          spaced: spaced,
          own_split: Rubycc::CommandLine.argv(spaced),
          shellwords: Shellwords.split(spaced),
          with_flag: Rubycc::CommandLine.argv("\#{spaced} -shared"),
          plain: Rubycc::MkmfShim.launcher("/usr/bin/ruby", "/gems/exe/rubycc"),
          cc_split: Rubycc::CommandLine.argv(RbConfig::CONFIG["CC"])
        }
        STDOUT.write(Marshal.dump(data))
      RUBY
    )
    assert status.success?, err
    data = Marshal.load(out)

    words = ["/opt/ruby 4.0/bin/ruby", "/gems/rubycc 1.0.0/exe/rubycc"]
    assert_equal words, data[:own_split]
    assert_equal words, data[:shellwords]
    assert_equal words + ["-shared"], data[:with_flag],
                 "the driver's own flag must stay a separate word after the quoted ones"
    assert_equal "/usr/bin/ruby /gems/exe/rubycc", data[:plain],
                 "a path needing no quoting must be left alone, so the common case stays readable"
    # And the real CC of this checkout splits back into exactly its two words.
    assert_equal [RbConfig.ruby, EXE_PATH], data[:cc_split]
  end

  # --- how a conftest is spawned (Step mkmf-shell-free-conftest-1) -----------

  # mkmf builds every conftest command as one string and hands it to
  # `system`/`IO.popen`, which leaves Ruby to choose between exec'ing it and
  # passing it to /bin/sh. The shim converts the string to an argv array first,
  # so what reaches the spawn is never a command string: in an environment with
  # no /bin/sh (DESIGN R5) the shell branch fails with no diagnostic at all.
  # The probe replaces Kernel#system in the child to record the exact arguments.
  def test_conftest_commands_are_spawned_as_argv_not_as_a_command_string
    result, _log, err, status = run_in_mkmf(<<~RUBY)
      seen = []
      Object.prepend(Module.new {
        define_method(:system) { |*args| seen << args.drop(1); true }
      })
      xsystem("/bin/echo one 'two three'")
      xsystem("./conftest")
      xsystem(["/bin/echo", "already argv"])
      result = seen
    RUBY

    assert status.success?, "the mkmf child exited nonzero:\n#{err}"
    split, single, passthrough = result

    assert_equal ["/bin/echo", "one", "two three"], split,
                 "the string command should reach system() as separate argv words"
    # A one-word command would still be a lone String argument, which is where
    # Ruby decides for itself whether to involve a shell; the [program, argv0]
    # form settles it.
    assert_equal [["./conftest", "./conftest"]], single
    assert_equal ["/bin/echo", "already argv"], passthrough,
                 "a command mkmf already built as an array must pass through untouched"
  end

  # A command that genuinely needs a shell is refused, with the reason written
  # where a failed build is debugged from (mkmf.log). Returning false instead
  # would be read by mkmf as "the compiler cannot do this" — the misdiagnosis
  # ("You have to install development tools first") that hid this problem.
  def test_shell_only_constructs_are_refused_with_the_reason_in_mkmf_log
    # A non-interpolating heredoc: the body's regexp escapes have to reach the
    # child verbatim.
    result, log, err, status = run_in_mkmf(<<~'RUBY')
      result = ["/bin/echo a | /bin/cat", "/bin/echo a && /bin/echo b",
                "/bin/echo a > out.txt", "/bin/echo `date`"].map do |command|
        begin
          xsystem(command)
          "ran without a shell"
        rescue Rubycc::MkmfShim::ShellRequiredError => e
          e.message[/\((.+?)\)/, 1]
        end
      end
      result << File.exist?("out.txt")
    RUBY

    assert status.success?, "the mkmf child exited nonzero:\n#{err}"
    assert_equal ["pipe '|'", "command connector '&&'", "redirection",
                  "shell metacharacter '`'", false],
                 result, "each construct must raise, and nothing may be run"
    assert_includes log, "refusing to run a conftest command that needs a shell",
                     "the refusal must be recorded in mkmf.log"
    assert_includes log, "pipe '|'", "mkmf.log must name the construct at fault"
  end

  # --- corpus extconf reproduction (opt-in, networked) -----------------------

  # msgpack 1.8.3's extconf.rb, run under the shim, must generate a Makefile
  # whose probe result — the set of -DHAVE_* macros in its CPPFLAGS — matches the
  # Step 55 fixture (collected with the real toolchain). Tool-name differences
  # (CC = rubycc vs gcc) are excluded because only the HAVE_ set is compared.
  def test_msgpack_extconf_probe_set_matches_fixture
    AcceptanceResultReporter.with_result("mkmf-msgpack-extconf") do
      require_acceptance!

      ext_dir = fetch_and_unpack_ext("msgpack", "1.8.3", "ext/msgpack")
      makefile = run_extconf(ext_dir)

      expected = have_macros(File.read(File.join(FIXTURES_ROOT, "msgpack-1.8.3/msgpack/Makefile")))
      actual = have_macros(makefile)
      assert_equal expected, actual,
                   "rubycc's msgpack probe set (-DHAVE_*) must match the fixture's"
    end
  end

  # json 2.21.1's parser extconf, run under the shim with no JSON_DISABLE_SIMD
  # override, must settle the SIMD probe to *off* on its own: rubycc does not
  # ship the SIMD dispatch headers (cpuid.h / x86intrin.h) its own default search
  # path, so have_header for them is false and the extconf never enables SIMD —
  # the env-var workaround M2 needed is gone. The Makefile is generated (exit 0)
  # and carries no SIMD-enabling macro.
  def test_json_extconf_simd_probe_is_naturally_off
    AcceptanceResultReporter.with_result("mkmf-json-extconf") do
      require_acceptance!

      ext_dir = fetch_and_unpack_ext("json", "2.21.1", "ext/json/ext/parser")
      makefile = run_extconf(ext_dir)

      refute_match(/JSON_ENABLE_SIMD/, makefile, "SIMD must not be enabled for rubycc")
      refute_match(/-DHAVE_CPUID_H\b/, makefile, "cpuid.h must probe absent for rubycc")
    end
  end

  private

  def acceptance?
    ENV["RMAKE_ACCEPTANCE"] == "1" || AcceptanceFetchHelper.strict?
  end

  def require_acceptance!
    return true if acceptance?

    skip "set RMAKE_ACCEPTANCE=1 to run the networked acceptance"
  end

  # The set of HAVE_* macro names a Makefile defines through its CPPFLAGS, read
  # straight off the `-DHAVE_...` tokens anywhere in the file (a value, if any,
  # is dropped so only the macro name is compared).
  def have_macros(makefile_text)
    makefile_text.scan(/-D(HAVE_[A-Za-z0-9_]+)/).flatten.map { |m| m.split("=").first }.to_set
  end

  # Runs `extconf.rb` in `ext_dir` under the shim and returns the generated
  # Makefile's text. Fails loudly (with the child's output) when no Makefile is
  # produced.
  def run_extconf(ext_dir)
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-I#{LIB_DIR}", "-r", "rubycc/mkmf_shim", "extconf.rb",
      chdir: ext_dir
    )
    makefile_path = File.join(ext_dir, "Makefile")
    assert status.success?, "extconf.rb failed (#{status.exitstatus}):\n#{out}\n#{err}"
    assert File.exist?(makefile_path), "extconf.rb produced no Makefile:\n#{out}\n#{err}"
    File.read(makefile_path)
  end

  # Fetches and unpacks a gem, returning the absolute path of one of its ext
  # directories. Normal development runs preserve the opt-in skip behaviour;
  # strict acceptance turns the typed fetch failure into a test failure.
  def fetch_and_unpack_ext(gem_name, version, ext_subdir)
    work = File.join(Dir.tmpdir, "rubycc_mkmf_acceptance", "#{gem_name}-#{version}")
    artifact = AcceptanceManifestHelper.artifact("gem-#{gem_name}-#{version}-ruby")
    AcceptanceFetchHelper::Fetcher.new(work_dir: work).fetch_gem(
      gem_name: gem_name, version: version, extension_subdir: ext_subdir,
      expected_sha256: artifact.fetch("sha256"), artifact_id: artifact.fetch("id"),
      artifact_url: artifact.fetch("url")
    )
  rescue AcceptanceFetchHelper::Failure => e
    raise e if AcceptanceFetchHelper.strict?

    skip "could not prepare #{gem_name}-#{version}: #{e.message}"
  end
end
