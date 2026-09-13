# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
require "tmpdir"
require "fileutils"
require "stringio"

# rmake-suffix-rule-generated-source-1: an inference rule (`.c.o:`) must be
# able to compile a source that does not exist yet but that the Makefile can
# make — the target of an explicit rule, or of another inference rule. The
# motivating case is numo-narray 0.9.2.1, whose extconf appends explicit rules
# that generate `t_bit.c` and friends and relies on mkmf's `.c.o:` to compile
# them; rmake used to skip the inference (the `.c` did not exist), plan no
# compile at all, and fail only at the link.
#
# The second half pins the companion diagnosis: a prerequisite that is neither
# a file nor makeable stops planning with GNU make's `No rule to make target`
# wording, naming it and the target that needed it, instead of letting the
# build run on into a confusing failure further down.
#
# The expected transcripts come from GNU make 4.3, measured 2026-09-14 on the
# same Makefiles (see docs/development/STEPS.md). Recipes use rmake's builtins
# (cp/echo) only, so no compiler is involved.
class TestRmakeSuffixRuleGeneratedSource < Minitest::Test
  Rmake = Rubycc::Rmake
  Makefile = Rmake::Makefile

  def with_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def write(dir, name, content = "")
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def touch(dir, name, mtime)
    path = write(dir, name)
    time = Time.at(mtime)
    File.utime(time, time, path)
    path
  end

  # Run +goal+ of +text+ in +dir+ and return the echoed recipe lines.
  def run_make(text, dir, goal = nil)
    out = StringIO.new
    Makefile.parse(text, dir: dir).run(goal, out: out, err: StringIO.new)
    out.string.lines.map(&:chomp)
  end

  # The issue's Makefile with the compiler and linker replaced by `cp`, so the
  # chain x.c -> x.o -> prog is observable as file contents.
  GENERATED_SOURCE_MK = <<~MK
    all: prog
    prog: x.o
    \tcp x.o prog
    x.c: gen/src.txt
    \tcp gen/src.txt x.c
    .SUFFIXES: .c .o
    .c.o:
    \tcp $< $@
  MK

  # --- a source made by an explicit rule ------------------------------------

  def test_suffix_rule_compiles_a_source_generated_by_an_explicit_rule
    with_dir do |dir|
      write(dir, "gen/src.txt", "int main(void) { return 0; }\n")
      lines = run_make(GENERATED_SOURCE_MK, dir)

      # GNU make 4.3: cp gen/src.txt x.c / cc -c -o x.o x.c / cc -o prog x.o.
      assert_equal ["cp gen/src.txt x.c", "cp x.c x.o", "cp x.o prog"], lines
      assert_equal "int main(void) { return 0; }\n", File.read(File.join(dir, "prog"))
    end
  end

  def test_generated_source_orders_its_step_before_the_compile
    with_dir do |dir|
      write(dir, "gen/src.txt")
      plan = Makefile.parse(GENERATED_SOURCE_MK, dir: dir).plan

      assert_equal %w[x.c x.o prog], plan.steps.map(&:target)
      # The -j scheduler must see the compile wait for the generator.
      assert_equal ["x.c"], plan.steps[1].prereqs
    end
  end

  def test_generated_source_rule_written_after_the_suffix_rule
    with_dir do |dir|
      write(dir, "gen/src.txt")
      lines = run_make(<<~MK, dir)
        prog: x.o
        \tcp x.o prog
        .SUFFIXES: .c .o
        .c.o:
        \tcp $< $@
        x.c:
        \tcp gen/src.txt x.c
      MK
      assert_equal ["cp gen/src.txt x.c", "cp x.c x.o", "cp x.o prog"], lines
    end
  end

  def test_generated_source_is_up_to_date_on_the_second_run
    with_dir do |dir|
      touch(dir, "gen/src.txt", 1000)
      touch(dir, "x.c", 2000)
      touch(dir, "x.o", 3000)
      touch(dir, "prog", 4000)
      assert_empty Makefile.parse(GENERATED_SOURCE_MK, dir: dir).plan.steps
    end
  end

  def test_generator_input_change_rebuilds_the_whole_chain
    with_dir do |dir|
      touch(dir, "x.c", 2000)
      touch(dir, "x.o", 3000)
      touch(dir, "prog", 4000)
      touch(dir, "gen/src.txt", 5000)
      assert_equal %w[x.c x.o prog], Makefile.parse(GENERATED_SOURCE_MK, dir: dir).plan.steps.map(&:target)
    end
  end

  # numo-narray's shape: the generator is a recipe with automatic variables
  # and several inputs, one of them a glob-free variable list.
  def test_numo_narray_shaped_generator
    with_dir do |dir|
      write(dir, "gen/def/bit.rb", "bit\n")
      write(dir, "gen/cogen.rb")
      lines = run_make(<<~MK, dir)
        COGEN = gen/cogen.rb
        DEPENDS = $(COGEN)
        OBJS = t_bit.o
        all: lib.so
        lib.so: $(OBJS)
        \tcp $(OBJS) $@
        .SUFFIXES: .c .o
        .c.o:
        \tcp $< $@
        t_bit.c: gen/def/bit.rb $(DEPENDS)
        \tcp $< $@
      MK
      assert_equal ["cp gen/def/bit.rb t_bit.c", "cp t_bit.c t_bit.o", "cp t_bit.o lib.so"], lines
      assert_equal "bit\n", File.read(File.join(dir, "lib.so"))
    end
  end

  # --- wildcards in prerequisites ---------------------------------------------
  #
  # numo-narray's generator rules list `$(srcdir)/gen/*.rb`. Before this step
  # rmake silently skipped the literal pattern; now an unmakeable prerequisite
  # stops the build, so the pattern has to be expanded the way GNU make does.

  def test_wildcard_prerequisite_expands_to_sorted_matches
    with_dir do |dir|
      %w[b a c].each { |n| write(dir, "gen/#{n}.rb") }
      plan = Makefile.parse(<<~MK, dir: dir).plan
        x.c: gen/*.rb
        \techo $^ first=$<
      MK
      # GNU make 4.3: ^=gen/a.rb gen/b.rb gen/c.rb <=gen/a.rb
      assert_equal ["echo gen/a.rb gen/b.rb gen/c.rb first=gen/a.rb"], plan.command_lines
    end
  end

  def test_wildcard_prerequisite_through_a_variable_and_absolute_path
    with_dir do |dir|
      write(dir, "gen/a.rb")
      write(dir, "gen/x.txt")
      plan = Makefile.parse(<<~MK, dir: dir).plan
        DEPENDS = #{dir}/gen/*.rb gen/?.txt
        x.c: $(DEPENDS)
        \techo $^
      MK
      assert_equal ["echo #{dir}/gen/a.rb gen/x.txt"], plan.command_lines
    end
  end

  def test_wildcard_match_newer_than_target_rebuilds_it
    with_dir do |dir|
      touch(dir, "x.c", 1000)
      touch(dir, "gen/a.rb", 2000)
      assert_equal ["echo rebuilt"], Makefile.parse("x.c: gen/*.rb\n\techo rebuilt\n", dir: dir).plan.command_lines
    end
  end

  def test_wildcard_matching_nothing_is_a_missing_prerequisite
    with_dir do |dir|
      mk = Makefile.parse("x.c: gen/*.rb\n\techo x\n", dir: dir)
      error = assert_raises(Rmake::NoRuleError) { mk.plan }
      # GNU make 4.3: make: *** No rule to make target 'gen/*.rb', needed by 'x.c'.  Stop.
      assert_equal "No rule to make target 'gen/*.rb', needed by 'x.c'.  Stop.", error.message
    end
  end

  # The issue's control case: rmake built this before the step and still must.
  def test_generator_with_a_wildcard_prerequisite_still_builds
    with_dir do |dir|
      write(dir, "gen/a.rb", "a\n")
      lines = run_make(<<~MK, dir)
        x.c: gen/a.rb gen/*.rb
        \tcp gen/a.rb x.c
      MK
      assert_equal ["cp gen/a.rb x.c"], lines
    end
  end

  # --- a source made by another inference rule -------------------------------

  def test_inference_rules_chain_from_an_existing_file
    with_dir do |dir|
      write(dir, "x.t", "t\n")
      lines = run_make(<<~MK, dir)
        prog: x.o
        \tcp x.o prog
        .SUFFIXES: .t .c .o
        .t.c:
        \tcp $< $@
        .c.o:
        \tcp $< $@
      MK
      # GNU make runs the same three lines and then deletes the intermediate
      # x.c (`rm x.c`); rmake keeps it (see STEPS for why).
      assert_equal ["cp x.t x.c", "cp x.c x.o", "cp x.o prog"], lines
    end
  end

  def test_inference_rules_chain_three_levels
    with_dir do |dir|
      write(dir, "x.a")
      plan = Makefile.parse(<<~MK, dir: dir).plan("x.o")
        .SUFFIXES: .a .b .c .o
        .a.b:
        \tcp $< $@
        .b.c:
        \tcp $< $@
        .c.o:
        \tcp $< $@
      MK
      assert_equal ["cp x.a x.b", "cp x.b x.c", "cp x.c x.o"], plan.command_lines
    end
  end

  def test_inference_chain_from_an_explicitly_generated_file
    with_dir do |dir|
      write(dir, "gen/src.txt")
      plan = Makefile.parse(<<~MK, dir: dir).plan
        prog: x.o
        \tcp x.o prog
        x.t: gen/src.txt
        \tcp gen/src.txt x.t
        .SUFFIXES: .t .c .o
        .t.c:
        \tcp $< $@
        .c.o:
        \tcp $< $@
      MK
      assert_equal ["cp gen/src.txt x.t", "cp x.t x.c", "cp x.c x.o", "cp x.o prog"], plan.command_lines
    end
  end

  # GNU make 4.3: x.c present and x.t makeable only through `.s.t:` — it
  # compiles x.c. An existing file wins over a chain even when the chain's
  # suffix is listed first.
  def test_existing_source_wins_over_a_makeable_one
    with_dir do |dir|
      write(dir, "x.s")
      write(dir, "x.c")
      plan = Makefile.parse(<<~MK, dir: dir).plan("x.o")
        .SUFFIXES: .t .c .s .o
        .s.t:
        \tcp $< $@
        .t.o:
        \techo from-t > $@
        .c.o:
        \techo from-c > $@
      MK
      assert_equal ["echo from-c > x.o"], plan.command_lines
    end
  end

  def test_existing_source_wins_over_an_explicitly_generated_one
    with_dir do |dir|
      write(dir, "x.s")
      write(dir, "x.c")
      plan = Makefile.parse(<<~MK, dir: dir).plan("x.o")
        x.t: x.s
        \tcp x.s x.t
        .SUFFIXES: .t .c .s .o
        .t.o:
        \techo from-t > $@
        .c.o:
        \techo from-c > $@
      MK
      assert_equal ["echo from-c > x.o"], plan.command_lines
    end
  end

  def test_mutually_inverse_rules_do_not_recurse_forever
    with_dir do |dir|
      mk = Makefile.parse(<<~MK, dir: dir)
        .SUFFIXES: .c .o
        .c.o:
        \tcp $< $@
        .o.c:
        \tcp $< $@
      MK
      error = assert_raises(Rmake::NoRuleError) { mk.plan("x.o") }
      assert_equal "x.o", error.target
    end
  end

  # --- a prerequisite nothing can make ---------------------------------------

  def test_missing_object_stops_before_the_link
    with_dir do |dir|
      mk = Makefile.parse(<<~MK, dir: dir)
        prog: x.o
        \tcp x.o prog
        .SUFFIXES: .c .o
        .c.o:
        \tcp $< $@
      MK
      error = assert_raises(Rmake::NoRuleError) { mk.run(out: StringIO.new) }
      # GNU make 4.3: make: *** No rule to make target 'x.o', needed by 'prog'.  Stop.
      assert_equal "No rule to make target 'x.o', needed by 'prog'.  Stop.", error.message
      assert_equal "prog", error.needed_by
      refute File.exist?(File.join(dir, "prog"))
    end
  end

  def test_missing_prerequisite_of_a_generator_is_named
    with_dir do |dir|
      write(dir, "gen/src.txt")
      mk = Makefile.parse(<<~MK, dir: dir)
        all: prog
        prog: x.o
        \tcp x.o prog
        x.c: gen/src.txt gen/nope.txt
        \tcp gen/src.txt x.c
        .SUFFIXES: .c .o
        .c.o:
        \tcp $< $@
      MK
      error = assert_raises(Rmake::NoRuleError) { mk.plan }
      assert_equal "No rule to make target 'gen/nope.txt', needed by 'x.c'.  Stop.", error.message
      refute File.exist?(File.join(dir, "x.c")), "planning must stop before any recipe runs"
    end
  end

  def test_missing_plain_prerequisite
    with_dir do |dir|
      mk = Makefile.parse("all: foo\n\techo all\n", dir: dir)
      error = assert_raises(Rmake::NoRuleError) { mk.plan }
      assert_equal "No rule to make target 'foo', needed by 'all'.  Stop.", error.message
    end
  end

  def test_missing_goal_has_no_needed_by
    with_dir do |dir|
      mk = Makefile.parse("all:\n\techo all\n", dir: dir)
      error = assert_raises(Rmake::NoRuleError) { mk.plan("nope") }
      assert_equal "No rule to make target 'nope'.  Stop.", error.message
      assert_nil error.needed_by
    end
  end

  def test_cli_reports_the_missing_target_and_exits_2
    with_dir do |dir|
      write(dir, "Makefile", "prog: x.o\n\tcp x.o prog\n")
      out = StringIO.new
      err = StringIO.new
      code = Rmake::CLI.run(["-j1"], dir: dir, out: out, err: err)
      assert_equal 2, code
      assert_equal "rmake: No rule to make target 'x.o', needed by 'prog'.  Stop.\n", err.string
      assert_empty out.string
    end
  end

  # --- names that are made without a recipe (GNU make 4.3 accepts all four) --

  def test_empty_rule_target_is_not_an_error
    with_dir do |dir|
      assert_equal ["echo all"], Makefile.parse("all: FORCE\n\techo all\nFORCE:\n", dir: dir).plan.command_lines
    end
  end

  def test_prerequisite_only_rule_target_is_not_an_error
    with_dir do |dir|
      mk = Makefile.parse("all: foo\n\techo all\nfoo: bar\nbar:\n", dir: dir)
      assert_equal ["echo all"], mk.plan.command_lines
    end
  end

  def test_phony_target_without_a_rule_is_not_an_error
    with_dir do |dir|
      mk = Makefile.parse(".PHONY: foo\nall: foo\n\techo all\n", dir: dir)
      assert_equal ["echo all"], mk.plan.command_lines
    end
  end

  # An explicit rule without a recipe still makes its target a candidate
  # source; GNU make picks `.c.o:` here and the compile itself then fails.
  def test_recipe_less_explicit_source_still_selects_the_suffix_rule
    with_dir do |dir|
      write(dir, "gen/src.txt")
      plan = Makefile.parse(<<~MK, dir: dir).plan
        prog: x.o
        \tcp x.o prog
        x.c: gen/src.txt
        .SUFFIXES: .c .o
        .c.o:
        \tcp $< $@
      MK
      assert_equal ["cp x.c x.o", "cp x.o prog"], plan.command_lines
    end
  end
end
