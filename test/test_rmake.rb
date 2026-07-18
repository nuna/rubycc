# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
require "tmpdir"
require "fileutils"

# Step 56 (M3 / ROADMAP §6 B1): unit tests for the rmake core — the mkmf
# Makefile-subset parser, variable expander and dependency-graph planner. The
# feature set is derived from the six real mkmf Makefiles under
# test/fixtures/mkmf (see test_rmake_golden.rb for the end-to-end `make -n`
# comparison); these tests pin down each mechanism in isolation.
class TestRmake < Minitest::Test
  Makefile = Rubycc::Rmake::Makefile

  # Parse text with no filesystem interaction (dir defaults to ".").
  def parse(text)
    Makefile.parse(text)
  end

  # Build a Makefile whose #dir is a scratch directory and yield [makefile, dir]
  # so a test can create prerequisite/target files with controlled mtimes.
  def with_makefile(text)
    Dir.mktmpdir do |dir|
      yield Makefile.parse(text, dir: dir), dir
    end
  end

  def touch(dir, name, mtime)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.touch(path)
    time = Time.at(mtime)
    File.utime(time, time, path)
    path
  end

  # --- variable assignment flavours -----------------------------------------

  def test_recursive_assignment_is_expanded_at_reference
    mk = parse(<<~MK)
      X = 1
      Z = $(X)
      X = 2
    MK
    assert_equal "2", mk.variable_value("Z")
  end

  def test_simple_assignment_is_expanded_at_definition
    mk = parse(<<~MK)
      X = 1
      Y := $(X)
      X = 2
    MK
    assert_equal "1", mk.variable_value("Y")
  end

  def test_conditional_assignment_only_sets_when_undefined
    mk = parse(<<~MK)
      A = first
      A ?= second
      B ?= third
    MK
    assert_equal "first", mk.variable_value("A")
    assert_equal "third", mk.variable_value("B")
  end

  def test_append_assignment_recursive_and_simple
    recursive = parse(<<~MK)
      FLAGS = -a
      FLAGS += -b
    MK
    assert_equal "-a -b", recursive.variable_value("FLAGS")

    simple = parse(<<~MK)
      S := x
      S += y
    MK
    assert_equal "x y", simple.variable_value("S")

    fresh = parse("N += first")
    assert_equal "first", fresh.variable_value("N")
  end

  # --- command-line variable overrides (B6) ---------------------------------

  # A command-line `VAR=value` beats the Makefile's own assignment to the same
  # name — make's precedence rule, and what lets RubyGems' `DESTDIR=` blank out
  # the Makefile's value.
  def test_command_line_override_wins_over_makefile_assignment
    mk = Makefile.parse("DESTDIR = /makefile\nOUT = $(DESTDIR)/x\n", overrides: { "DESTDIR" => "/cli" })
    assert_equal "/cli", mk.variable_value("DESTDIR")
    assert_equal "/cli/x", mk.variable_value("OUT")
  end

  # An empty override (`DESTDIR=`) still wins, replacing the Makefile value with
  # the empty string rather than being ignored.
  def test_empty_command_line_override_wins
    mk = Makefile.parse("DESTDIR = /makefile\n", overrides: { "DESTDIR" => "" })
    assert_equal "", mk.variable_value("DESTDIR")
  end

  # An override is visible while a `:=` (simple) assignment elsewhere is being
  # expanded during the parse, not only afterwards.
  def test_override_is_seen_by_simple_assignment_during_parse
    mk = Makefile.parse("DESTDIR = /makefile\nP := $(DESTDIR)/lib\n", overrides: { "DESTDIR" => "/cli" })
    assert_equal "/cli/lib", mk.variable_value("P")
  end

  # An override beats even `?=`/`+=`, which the makefile cannot use to sneak past
  # a command-line definition.
  def test_override_wins_over_conditional_and_append
    mk = Makefile.parse("V ?= a\nV += b\n", overrides: { "V" => "cli" })
    assert_equal "cli", mk.variable_value("V")
  end

  # --- expansion ------------------------------------------------------------

  def test_nested_expansion
    mk = parse(<<~MK)
      A = hello
      B = $(A) world
      C = $(B)!
    MK
    assert_equal "hello world!", mk.variable_value("C")
  end

  def test_brace_and_paren_reference_forms_are_equivalent
    mk = parse(<<~MK)
      A = x
      P = $(A)
      Q = ${A}
    MK
    assert_equal "x", mk.variable_value("P")
    assert_equal "x", mk.variable_value("Q")
  end

  def test_undefined_variable_expands_empty
    mk = parse("A = [$(NOPE)]")
    assert_equal "[]", mk.variable_value("A")
  end

  def test_substitution_reference_is_end_of_word_replacement
    # Mirrors the V/Q/ECHO chain every mkmf Makefile opens with.
    mk = parse(<<~MK)
      V = 0
      V0 = $(V:0=)
      Q1 = $(V:1=)
      Q = $(Q1:0=@)
      ECHO1 = $(V:1=@ :)
      ECHO = $(ECHO1:0=@ echo)
    MK
    assert_equal "", mk.variable_value("V0")
    assert_equal "@", mk.variable_value("Q")
    assert_equal "@ echo", mk.variable_value("ECHO")
  end

  def test_substitution_reference_applies_per_word
    mk = parse(<<~MK)
      SRCS = a.c b.c c.c
      OBJS = $(SRCS:.c=.o)
    MK
    assert_equal "a.o b.o c.o", mk.variable_value("OBJS")
  end

  def test_leading_whitespace_stripped_trailing_preserved
    # make strips whitespace after `=` but keeps trailing whitespace; the golden
    # tests depend on this for byte-exact command output.
    mk = parse("V =   a b \n")
    assert_equal "a b ", mk.variable_value("V")
  end

  def test_line_continuation_joins_with_single_space
    mk = parse(<<~MK)
      LIST = a \\
             b \\
             c
    MK
    assert_equal "a b c", mk.variable_value("LIST")
  end

  def test_comment_is_stripped
    mk = parse("A = value # trailing comment")
    assert_equal "value ", mk.variable_value("A")
  end

  def test_expansion_cycle_is_diagnosed
    mk = parse(<<~MK)
      A = $(B)
      B = $(A)
    MK
    assert_raises(Rubycc::Rmake::ExpansionError) { mk.variable_value("A") }
  end

  # --- suffix rules and automatic variables ---------------------------------

  def test_suffix_rule_infers_recipe_from_source
    with_makefile(<<~MK) do |mk, dir|
      .SUFFIXES: .c .o
      all: foo.o
      .c.o:
      \tcc -c $< -o $@ stem=$*
    MK
      touch(dir, "foo.c", 1000)
      plan = mk.plan
      assert_equal ["cc -c foo.c -o foo.o stem=foo"], plan.command_lines
    end
  end

  def test_automatic_variables_in_explicit_rule
    with_makefile(<<~MK) do |mk, dir|
      app: a.o b.o
      \tlink -o $@ $<  all:$^
    MK
      touch(dir, "a.o", 1000)
      touch(dir, "b.o", 1000)
      plan = mk.plan("app")
      assert_equal ["link -o app a.o  all:a.o b.o"], plan.command_lines
    end
  end

  def test_dir_and_file_automatic_variable_modifiers
    with_makefile(<<~MK) do |mk, dir|
      .SUFFIXES: .c .o
      all: sub/foo.o
      .c.o:
      \tmk $(@D) $(@F) $(<D) $(<F)
    MK
      touch(dir, "sub/foo.c", 1000)
      plan = mk.plan
      assert_equal ["mk sub foo.o sub foo.c"], plan.command_lines
    end
  end

  # --- staleness ------------------------------------------------------------

  def test_target_newer_than_prerequisite_is_up_to_date
    with_makefile(<<~MK) do |mk, dir|
      out: in
      \tbuild
    MK
      touch(dir, "in", 1000)
      touch(dir, "out", 2000)
      assert_empty mk.plan("out").steps
    end
  end

  def test_target_older_than_prerequisite_is_stale
    with_makefile(<<~MK) do |mk, dir|
      out: in
      \tbuild
    MK
      touch(dir, "out", 1000)
      touch(dir, "in", 2000)
      assert_equal ["build"], mk.plan("out").command_lines
    end
  end

  def test_absent_target_is_stale
    with_makefile(<<~MK) do |mk, dir|
      out: in
      \tbuild
    MK
      touch(dir, "in", 1000)
      assert_equal ["build"], mk.plan("out").command_lines
    end
  end

  def test_staleness_propagates_through_chain
    with_makefile(<<~MK) do |mk, dir|
      app: mid
      \tlink
      mid: src
      \tcompile
    MK
      # src newer than mid forces mid to rebuild, which in turn forces app.
      touch(dir, "app", 2000)
      touch(dir, "mid", 2000)
      touch(dir, "src", 3000)
      assert_equal %w[compile link], mk.plan("app").command_lines
    end
  end

  # --- VPATH ----------------------------------------------------------------

  def test_vpath_resolves_prerequisite_in_another_directory
    with_makefile(<<~MK) do |mk, dir|
      VPATH = $(srcdir):alt
      srcdir = .
      .SUFFIXES: .c .o
      all: foo.o
      .c.o:
      \tcc -c $< -o $@
    MK
      touch(dir, "alt/foo.c", 1000)
      plan = mk.plan
      assert_equal ["cc -c alt/foo.c -o foo.o"], plan.command_lines
    end
  end

  # --- phony ----------------------------------------------------------------

  def test_phony_target_is_always_stale
    with_makefile(<<~MK) do |mk, dir|
      .PHONY: clean
      clean:
      \trm -f junk
    MK
      # Even with an up-to-date file literally named "clean", a phony target runs.
      touch(dir, "clean", 9_999_999)
      assert_equal ["rm -f junk"], mk.plan("clean").command_lines
    end
  end

  # --- recipe prefixes ------------------------------------------------------

  def test_recipe_prefixes_are_captured_as_attributes
    with_makefile(<<~MK) do |mk, _dir|
      all:
      \t@-echo hi
    MK
      cmd = mk.plan.steps.first.commands.first
      assert_equal "echo hi", cmd.text
      assert cmd.silent?
      assert cmd.ignore_error?
      refute cmd.force?
    end
  end

  def test_default_goal_is_first_normal_target
    mk = parse(<<~MK)
      .SUFFIXES: .c .o
      all: foo.o
      other: bar.o
    MK
    assert_equal "all", mk.default_goal
  end

  def test_plan_dump_shows_targets_and_prefixes
    with_makefile(<<~MK) do |mk, dir|
      .SUFFIXES: .c .o
      all: foo.o
      .c.o:
      \t@echo compiling $<
      \tcc -c $< -o $@
    MK
      touch(dir, "foo.c", 1000)
      dump = mk.plan.dump
      assert_includes dump, "foo.o:"
      assert_includes dump, "@ echo compiling foo.c"
      assert_includes dump, "cc -c foo.c -o foo.o"
    end
  end
end
