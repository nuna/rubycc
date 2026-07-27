# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
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
