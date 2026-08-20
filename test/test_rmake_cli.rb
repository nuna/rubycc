# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "stringio"
require "fiddle"

# Step 61 (M3 / ROADMAP §6 B6): the exe/rmake command-line front end. RubyGems
# drives rubycc by running this as `$(MAKE)`, so these tests pin the invocation
# shape it must accept — command-line `VAR=value` overrides (which win over the
# Makefile's own assignments), target selection with a default goal, `-j`/`-f`,
# and exit-code propagation — against synthetic Makefiles, plus the always-on
# rubycc tool substitution that lets it build a real `.so` from a `CC = gcc`
# Makefile without an external compiler.
class TestRmakeCli < Minitest::Test
  Rmake = Rubycc::Rmake
  CLI = Rmake::CLI

  def with_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def path(dir, *parts)
    File.join(dir, *parts)
  end

  def run_cli(argv, dir)
    out = StringIO.new
    err = StringIO.new
    code = CLI.run(argv, dir: dir, out: out, err: err)
    [code, out.string, err.string]
  end

  # A Makefile echoing a variable into a file, so a command-line override of that
  # variable is observable, and with a `.c.o`/link pair so tool substitution can
  # build a shared object. `CC = gcc` is deliberate: rmake must substitute rubycc
  # regardless.
  BUILD_MK = <<~MK
    CC = gcc
    LDSHARED = $(CC) -shared
    DESTDIR = /makefile/value
    empty =
    COUTFLAG = -o $(empty)
    CFLAGS = -fPIC
    OBJS = a.o b.o
    DLLIB = mylib.so
    srcdir = .
    VPATH = $(srcdir)

    all: $(DLLIB)

    .SUFFIXES: .c .o

    .c.o:
    \t$(CC) $(CFLAGS) $(COUTFLAG)$@ -c $<

    $(DLLIB): $(OBJS)
    \techo destdir=[$(DESTDIR)] > destmark.txt
    \t$(LDSHARED) -o $@ $(OBJS)

    show:
    \techo destdir=[$(DESTDIR)] > destmark.txt
  MK

  def write_build_project(dir)
    File.write(path(dir, "Makefile"), BUILD_MK)
    File.write(path(dir, "a.c"), "int a_val(void) { return 11; }\n")
    File.write(path(dir, "b.c"), "int b_val(void) { return 31; }\n")
  end

  def call(lib, name)
    Fiddle::Function.new(lib[name], [], Fiddle::TYPE_INT)
  end

  # --- tool substitution is always on ---------------------------------------

  def test_builds_shared_object_through_rubycc_despite_cc_gcc
    with_dir do |dir|
      write_build_project(dir)
      code, _out, err = run_cli(["all"], dir)

      assert_equal 0, code, err
      so = path(dir, "mylib.so")
      assert File.exist?(so), "rmake should build mylib.so with rubycc (CC=gcc notwithstanding)"
      lib = Fiddle.dlopen(so)
      assert_equal 11, call(lib, "a_val").call
      assert_equal 31, call(lib, "b_val").call
    ensure
      lib&.close
    end
  end

  def test_jobs_flag_still_builds
    with_dir do |dir|
      write_build_project(dir)
      code, _out, err = run_cli(["-j2", "all"], dir)
      assert_equal 0, code, err
      assert File.exist?(path(dir, "mylib.so"))
    end
  end

  def test_dash_j_with_separate_argument
    with_dir do |dir|
      write_build_project(dir)
      code, _out, err = run_cli(["-j", "2", "all"], dir)
      assert_equal 0, code, err
      assert File.exist?(path(dir, "mylib.so"))
    end
  end

  def test_default_jobs_is_processor_count
    cli = CLI.new(dir: Dir.pwd, out: StringIO.new, err: StringIO.new)
    options = cli.send(:parse_argv, ["all"])
    assert_equal cli.send(:processor_count), options[:jobs]
  end

  def test_dash_j1_forces_serial_jobs
    cli = CLI.new(dir: Dir.pwd, out: StringIO.new, err: StringIO.new)
    options = cli.send(:parse_argv, ["-j1", "all"])
    assert_equal 1, options[:jobs]
  end

  # --- command-line variable overrides --------------------------------------

  def test_command_line_variable_overrides_makefile_assignment
    with_dir do |dir|
      write_build_project(dir)
      code, _out, err = run_cli(["DESTDIR=/override", "show"], dir)

      assert_equal 0, code, err
      assert_equal "destdir=[/override]", File.read(path(dir, "destmark.txt")).strip
    end
  end

  def test_empty_command_line_variable_overrides_to_empty
    with_dir do |dir|
      write_build_project(dir)
      # RubyGems passes `DESTDIR=` (empty) to blank out the Makefile's value.
      code, _out, err = run_cli(["DESTDIR=", "show"], dir)

      assert_equal 0, code, err
      assert_equal "destdir=[]", File.read(path(dir, "destmark.txt")).strip
    end
  end

  # --- built-in MAKE variable -------------------------------------------------

  # POSIX requires make to define `MAKE` built in: recipes that recursively
  # invoke `$(MAKE)` (e.g. psych's bundled-libyaml `cd .. && $(MAKE)` rule)
  # would otherwise expand to the empty string and silently collapse into a
  # no-op instead of a recursive build.
  def with_env_make(value)
    had = ENV.key?("MAKE")
    prev = ENV["MAKE"]
    if value.nil?
      ENV.delete("MAKE")
    else
      ENV["MAKE"] = value
    end
    yield
  ensure
    if had
      ENV["MAKE"] = prev
    else
      ENV.delete("MAKE")
    end
  end

  # The default names the running interpreter as well as the program path
  # (Step env-less-shebang-1): rmake's own `#!/usr/bin/env ruby` line is not
  # resolvable on an image without /usr/bin/env, so a recursive `$(MAKE)` that
  # named the bare path would fail to exec with status 127 there.
  def test_make_variable_defaults_to_this_interpreter_and_process_path
    with_env_make(nil) do
      with_dir do |dir|
        File.write(path(dir, "Makefile"), "show:\n\techo make=[$(MAKE)] > out.txt\n")
        code, _out, err = run_cli(["show"], dir)

        assert_equal 0, code, err
        assert_equal "make=[#{RbConfig.ruby} #{File.expand_path($PROGRAM_NAME)}]",
                     File.read(path(dir, "out.txt")).strip
      end
    end
  end

  # RubyGems' rubygems_plugin sets `ENV["MAKE"]` to rmake before driving the
  # build, and that value (not this process's own path) must be what `$(MAKE)`
  # expands to, so any further recursive invocation stays rmake too.
  def test_make_variable_honours_env_make_when_set
    with_env_make("/env/rmake") do
      with_dir do |dir|
        File.write(path(dir, "Makefile"), "show:\n\techo make=[$(MAKE)] > out.txt\n")
        code, _out, err = run_cli(["show"], dir)

        assert_equal 0, code, err
        assert_equal "make=[/env/rmake]", File.read(path(dir, "out.txt")).strip
      end
    end
  end

  # An empty `ENV["MAKE"]` (unset in effect) falls back to this process's own
  # path rather than being treated as a defined-but-blank override.
  def test_make_variable_falls_back_when_env_make_is_empty
    with_env_make("") do
      with_dir do |dir|
        File.write(path(dir, "Makefile"), "show:\n\techo make=[$(MAKE)] > out.txt\n")
        code, _out, err = run_cli(["show"], dir)

        assert_equal 0, code, err
        assert_equal "make=[#{RbConfig.ruby} #{File.expand_path($PROGRAM_NAME)}]",
                     File.read(path(dir, "out.txt")).strip
      end
    end
  end

  # A Makefile's own `MAKE = ...` assignment beats the built-in default (make's
  # ordinary precedence rule — the built-in is not protected like an override).
  def test_makefile_assignment_wins_over_make_default
    with_env_make(nil) do
      with_dir do |dir|
        File.write(path(dir, "Makefile"), "MAKE = /makefile/make\nshow:\n\techo make=[$(MAKE)] > out.txt\n")
        code, _out, err = run_cli(["show"], dir)

        assert_equal 0, code, err
        assert_equal "make=[/makefile/make]", File.read(path(dir, "out.txt")).strip
      end
    end
  end

  # A command-line `MAKE=other` beats both the built-in default and a
  # Makefile's own assignment.
  def test_command_line_override_wins_over_make_default_and_makefile_assignment
    with_env_make(nil) do
      with_dir do |dir|
        File.write(path(dir, "Makefile"), "MAKE = /makefile/make\nshow:\n\techo make=[$(MAKE)] > out.txt\n")
        code, _out, err = run_cli(["MAKE=/cli/make", "show"], dir)

        assert_equal 0, code, err
        assert_equal "make=[/cli/make]", File.read(path(dir, "out.txt")).strip
      end
    end
  end

  # The recursive-make idiom `cd sub && $(MAKE)` must keep its command word:
  # without a built-in default this collapses to a silent no-op (the bug this
  # feature fixes). The line is `echo`d rather than actually run — checking
  # the expanded text is enough, no recursive rmake process needs to start.
  def test_recursive_make_recipe_line_keeps_command_word
    with_env_make("/env/rmake") do
      with_dir do |dir|
        FileUtils.mkdir_p(path(dir, "sub"))
        File.write(path(dir, "Makefile"), %(show:\n\tcd sub && echo "$(MAKE) -C sub" > out.txt\n))
        code, _out, err = run_cli(["show"], dir)

        assert_equal 0, code, err
        assert_equal "/env/rmake -C sub", File.read(path(dir, "sub", "out.txt")).strip
      end
    end
  end

  # --- target selection -----------------------------------------------------

  def test_absent_target_builds_default_goal
    with_dir do |dir|
      write_build_project(dir)
      code, _out, err = run_cli(["DESTDIR="], dir)

      assert_equal 0, code, err
      assert File.exist?(path(dir, "mylib.so")), "the default goal (all) should have built the .so"
    end
  end

  def test_multiple_targets_run_in_order
    with_dir do |dir|
      File.write(path(dir, "Makefile"), <<~MK)
        one:
        \techo one >> trace
        two:
        \techo two >> trace
      MK
      code, _out, err = run_cli(%w[one two], dir)

      assert_equal 0, code, err
      assert_equal %w[one two], File.read(path(dir, "trace")).split
    end
  end

  # --- exit codes -----------------------------------------------------------

  def test_missing_makefile_returns_two
    with_dir do |dir|
      code, _out, err = run_cli(["all"], dir)
      assert_equal 2, code
      assert_match(/No such file/, err)
    end
  end

  def test_named_makefile_via_dash_f
    with_dir do |dir|
      File.write(path(dir, "Custom.mk"), "all:\n\techo built > out.txt\n")
      code, _out, err = run_cli(["-f", "Custom.mk", "all"], dir)

      assert_equal 0, code, err
      assert File.exist?(path(dir, "out.txt"))
    end
  end

  def test_failing_recipe_returns_two
    with_dir do |dir|
      File.write(path(dir, "Makefile"), "all:\n\truby -e 'exit 3'\n")
      code, _out, err = run_cli(["all"], dir)

      assert_equal 2, code
      assert_match(/rmake:/, err)
    end
  end

  def test_no_default_goal_returns_two
    with_dir do |dir|
      File.write(path(dir, "Makefile"), "X = 1\n")
      code, _out, err = run_cli([], dir)

      assert_equal 2, code
      assert_match(/no target/, err)
    end
  end

  # --- the exe launcher actually runs ---------------------------------------

  def test_exe_rmake_launcher_runs
    require "open3"
    exe = File.expand_path("../exe/rmake", __dir__)
    with_dir do |dir|
      File.write(path(dir, "Makefile"), "all:\n\techo hi > out.txt\n")
      _out, _err, status = Open3.capture3(exe, "all", chdir: dir)
      assert status.success?, "exe/rmake should exit 0"
      assert_equal "hi", File.read(path(dir, "out.txt")).strip
    end
  end
end
