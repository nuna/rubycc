# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
require "tmpdir"
require "fileutils"
require "stringio"

# Step 57 (M3 / ROADMAP §6 B2): recipe-replay tests for the shell-less runner.
# Unlike the isolated unit tests in test_rmake_executor.rb, these run recipes
# end-to-end and assert the resulting filesystem effects:
#
#   * the real `clean` target of every fixture Makefile under test/fixtures/mkmf
#     is executed verbatim (it uses only builtins — rm/glob — so no external
#     tool is needed) and the object files, shared object and stamp/backup files
#     it names must be gone afterwards;
#   * a synthetic Makefile with a stand-in "compiler" (echo/ruby, since the real
#     $(CC) substitution is B3) confirms the dependency-ordered execution order
#     and that a non-zero exit stops the build and propagates.
class TestRmakeReplay < Minitest::Test
  Rmake = Rubycc::Rmake
  Makefile = Rmake::Makefile
  FIXTURES_ROOT = File.expand_path("fixtures/mkmf", __dir__)

  def with_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def path(dir, *parts)
    File.join(dir, *parts)
  end

  # --- real fixture `clean` recipes -----------------------------------------

  Dir.glob(File.join(FIXTURES_ROOT, "*-*/*/Makefile")).sort.each do |makefile_path|
    ext = File.basename(File.dirname(makefile_path))
    gem_dir = File.basename(File.dirname(File.dirname(makefile_path)))
    name = "#{gem_dir}_#{ext}".gsub(/[^a-z0-9]+/i, "_")

    define_method(:"test_clean_recipe_removes_build_artifacts_#{name}") do
      replay_clean(makefile_path)
    end
  end

  # Execute the fixture's real `clean` target against a scratch tree seeded with
  # the artefacts it is meant to remove, then assert the tree is empty.
  def replay_clean(makefile_path)
    with_dir do |dir|
      mk = Makefile.parse(File.read(makefile_path), dir: dir)
      objects = mk.variable_value("OBJS").split
      dllib = mk.variable_value("DLLIB")

      objects.each { |o| FileUtils.touch(path(dir, o)) }
      FileUtils.touch(path(dir, dllib))
      # Files that only the glob patterns (`*.bak`, `.*.time`, `mkmf.log`) reach.
      FileUtils.touch(path(dir, "junk.bak"))
      FileUtils.touch(path(dir, "mkmf.log"))
      FileUtils.touch(path(dir, ".stamp.time"))

      refute_empty Dir.children(dir), "sanity: artefacts were seeded"
      mk.run("clean", out: StringIO.new)

      assert_empty Dir.children(dir),
                   "clean should remove every seeded artefact for #{File.basename(File.dirname(makefile_path))}"
    end
  end

  # --- synthetic build: dependency order + exit propagation -----------------

  # A stand-in "compiler"/"linker" recipe appends a line to a trace file, so the
  # order recipes run in (prerequisites before dependents) is observable without
  # a real toolchain.
  ORDERED_MAKEFILE = <<~MK
    .SUFFIXES: .c .o
    all: lib.so
    lib.so: a.o b.o
    \techo link a.o b.o >> trace
    .c.o:
    \techo compile $< >> trace
  MK

  def test_recipes_run_in_dependency_order
    with_dir do |dir|
      mk = Makefile.parse(ORDERED_MAKEFILE, dir: dir)
      FileUtils.touch(path(dir, "a.c"))
      FileUtils.touch(path(dir, "b.c"))

      mk.run("all", out: StringIO.new)

      assert_equal ["compile a.c", "compile b.c", "link a.o b.o"],
                   File.read(path(dir, "trace")).split("\n")
    end
  end

  # The first `.c.o` compile succeeds (leaving a marker), the second exits
  # non-zero; the failure must stop the build so the link step never runs.
  FAILING_MAKEFILE = <<~MK
    .SUFFIXES: .c .o
    all: lib.so
    lib.so: a.o b.o
    \ttouch linked
    .c.o:
    \truby -e 'File.write("compiled_$*", ""); exit("$*" == "b" ? 1 : 0)'
  MK

  def test_nonzero_exit_stops_the_build_and_propagates
    with_dir do |dir|
      mk = Makefile.parse(FAILING_MAKEFILE, dir: dir)
      FileUtils.touch(path(dir, "a.c"))
      FileUtils.touch(path(dir, "b.c"))

      error = assert_raises(Rmake::CommandFailedError) { mk.run("all", out: StringIO.new) }

      assert_equal "b.o", error.target, "failure names the target whose recipe failed"
      assert File.exist?(path(dir, "compiled_a")), "the a.o compile ran"
      assert File.exist?(path(dir, "compiled_b")), "the b.o compile ran and failed"
      refute File.exist?(path(dir, "linked")), "the link step must not run after a failure"
    end
  end

  # A `-`-prefixed recipe line lets the build continue past a failing command.
  IGNORE_MAKEFILE = <<~MK
    all:
    \t-ruby -e 'exit(1)'
    \ttouch reached
  MK

  def test_dash_prefix_lets_the_build_continue_past_failure
    with_dir do |dir|
      mk = Makefile.parse(IGNORE_MAKEFILE, dir: dir)
      mk.run("all", out: StringIO.new)
      assert File.exist?(path(dir, "reached"))
    end
  end

  # `mk.run(dry_run: true)` prints the plan (matching #command_lines) and does
  # not touch the filesystem — the make -n contract for the runner.
  def test_dry_run_matches_plan_command_lines
    with_dir do |dir|
      mk = Makefile.parse(ORDERED_MAKEFILE, dir: dir)
      FileUtils.touch(path(dir, "a.c"))
      FileUtils.touch(path(dir, "b.c"))

      out = StringIO.new
      mk.run("all", out: out, dry_run: true)

      assert_equal mk.plan("all").command_lines, out.string.split("\n")
      refute File.exist?(path(dir, "trace")), "dry run must not execute recipes"
    end
  end
end
