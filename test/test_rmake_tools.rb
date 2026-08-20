# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
require "tmpdir"
require "fileutils"
require "stringio"
require "fiddle"
require "rbconfig"
require_relative "support/acceptance_fetch_helper"
require_relative "support/acceptance_manifest_helper"
require_relative "support/acceptance_result_reporter"

# Step 58 (M3 / ROADMAP §6 B3): in-process tool substitution and the `-j`
# parallel scheduler for rmake. Where B2 (test_rmake_executor / _replay) pins the
# shell-less runner with external stand-ins, these tests drive the real thing:
#
#   * `tools: :rubycc` reroutes a Makefile's `$(CC)`/`$(LDSHARED)` commands to
#     rubycc's own Driver (in a forked child), so a mkmf-shaped Makefile builds a
#     working `.so` with no external compiler — verified by dlopening it;
#   * a forked worker contains a compiler failure (the build stops and names the
#     target, rmake itself survives) and two independent compiles in one run
#     reuse the process image without leaking state (identical deterministic
#     output);
#   * the `-j` scheduler runs independent stale steps concurrently (overlapping
#     wall-clock intervals) while still respecting the dependency edges, and a
#     `jobs: 1` run of the same plan does not overlap.
#
# The optional json acceptance (a real gem Makefile driven to `parser.so`) is
# gated behind RMAKE_ACCEPTANCE=1. CI_NETWORK=fixture supplies its pinned
# archive locally; the live profile fetches the same artifact from its URL.
class TestRmakeTools < Minitest::Test
  Rmake = Rubycc::Rmake
  Makefile = Rmake::Makefile
  FIXTURES_ROOT = File.expand_path("fixtures/mkmf", __dir__)
  RUBYCC_EXE = File.expand_path("../exe/rubycc", __dir__)

  def with_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def path(dir, *parts)
    File.join(dir, *parts)
  end

  # A minimal Makefile shaped like the ones mkmf emits: `CC = gcc`,
  # `LDSHARED = $(CC) -shared`, a `.c.o` suffix rule and a `$(DLLIB)` link rule,
  # with the same `$(COUTFLAG)$@` / `-o $@` spellings. Two objects so the link
  # depends on two compiles (something for `-j` to parallelise).
  MKMF_LIKE = <<~MK
    CC = gcc
    LDSHARED = $(CC) -shared
    empty =
    COUTFLAG = -o $(empty)
    CSRCFLAG = $(empty)
    INCFLAGS =
    CPPFLAGS =
    CFLAGS = -fPIC
    OBJS = a.o b.o
    DLLIB = mylib.so
    Q = @
    ECHO = @ echo
    RM = rm -f
    srcdir = .
    VPATH = $(srcdir)

    all: $(DLLIB)

    .SUFFIXES: .c .o

    .c.o:
    \t$(ECHO) compiling $(<)
    \t$(Q) $(CC) $(INCFLAGS) $(CPPFLAGS) $(CFLAGS) $(COUTFLAG)$@ -c $(CSRCFLAG)$<

    $(DLLIB): $(OBJS)
    \t$(ECHO) linking $(DLLIB)
    \t-$(Q)$(RM) $@
    \t$(Q) $(LDSHARED) -o $@ $(OBJS)
  MK

  def write_mkmf_like_sources(dir)
    File.write(path(dir, "Makefile"), MKMF_LIKE)
    File.write(path(dir, "a.c"), "int a_val(void) { return 11; }\n")
    File.write(path(dir, "b.c"), "int b_val(void) { return 31; }\n")
  end

  def call(lib, name, args, ret)
    Fiddle::Function.new(lib[name], args, ret)
  end

  # --- tool substitution builds a working shared object ---------------------

  def test_tools_substitution_builds_loadable_so_sequential
    AcceptanceResultReporter.with_result("rmake-fixture-build") do
      with_dir do |dir|
        write_mkmf_like_sources(dir)
        mk = Makefile.parse(File.read(path(dir, "Makefile")), dir: dir)
        mk.run("all", out: StringIO.new, tools: :rubycc, jobs: 1)

        so = path(dir, "mylib.so")
        assert File.exist?(so), "rmake+rubycc should produce mylib.so"
        assert File.exist?(path(dir, "a.o")), "the a.o compile ran through the Driver"
        assert File.exist?(path(dir, "b.o")), "the b.o compile ran through the Driver"

        lib = Fiddle.dlopen(so)
        assert_equal 11, call(lib, "a_val", [], Fiddle::TYPE_INT).call
        assert_equal 31, call(lib, "b_val", [], Fiddle::TYPE_INT).call
      ensure
        lib&.close
      end
    end
  end

  def test_tools_substitution_builds_loadable_so_parallel
    with_dir do |dir|
      write_mkmf_like_sources(dir)
      mk = Makefile.parse(File.read(path(dir, "Makefile")), dir: dir)
      mk.run("all", out: StringIO.new, tools: :rubycc, jobs: 2)

      so = path(dir, "mylib.so")
      assert File.exist?(so), "the -j build should also produce mylib.so"
      lib = Fiddle.dlopen(so)
      assert_equal 11, call(lib, "a_val", [], Fiddle::TYPE_INT).call
      assert_equal 31, call(lib, "b_val", [], Fiddle::TYPE_INT).call
    ensure
      lib&.close
    end
  end

  # A tool is an argv *prefix* — the words `$(CC)` expands to — not a program
  # name. For a plain gcc Makefile that prefix is one word, and `$(CC) -shared`
  # collapses onto it: the trailing option belongs to the compiler driver, which
  # reads it out of the recipe, so it is trimmed off the prefix rather than
  # dropped with it.
  def test_tool_prefixes_of_a_gcc_makefile
    mk = Makefile.parse("CC = gcc\nLDSHARED = $(CC) -shared\n")
    assert_equal [["gcc"]], mk.tool_prefixes
  end

  # Step env-less-shebang-1: the mkmf shim writes `CC = <ruby> <path>/exe/rubycc`
  # so the executable is launched through the interpreter rather than through its
  # `#!/usr/bin/env ruby` line. Both words name the program and both must be in
  # the prefix — dropping only the first would hand the script path to the Driver
  # as if it were a compiler argument.
  def test_tool_prefixes_cover_an_interpreter_launched_compiler
    mk = Makefile.parse("CC = #{RbConfig.ruby} #{RUBYCC_EXE}\nLDSHARED = $(CC) -shared\n")
    assert_equal [[RbConfig.ruby, RUBYCC_EXE]], mk.tool_prefixes
  end

  # The prefix is read off the Makefile, never guessed from what a word looks
  # like, so launchers rmake has never heard of work by construction. These three
  # are the cases a name-matching rule got wrong:
  #
  #   * `jruby <script>` — an interpreter whose name is not "ruby";
  #   * `ruby -Ilib <script>` — an interpreter flag between the two;
  #   * a recipe running `ruby /tmp/gcc` where the Makefile's CC is `gcc` — a
  #     different program that merely shares a basename with the tool.
  def test_tool_prefixes_do_not_guess_which_word_is_the_launcher
    jruby = Makefile.parse("CC = jruby /gem/exe/rubycc\nLDSHARED = $(CC) -shared\n")
    assert_equal [["jruby", "/gem/exe/rubycc"]], jruby.tool_prefixes

    flagged = Makefile.parse("CC = ruby -Ilib /gem/exe/rubycc\nLDSHARED = $(CC) -shared\n")
    assert_equal [["ruby", "-Ilib", "/gem/exe/rubycc"]], flagged.tool_prefixes
  end

  # What each of those does to a recipe line: the whole prefix is consumed and
  # only the words the recipe added reach the Driver, while a command that is not
  # the tool matches nothing and is left to be spawned.
  def test_tool_prefix_matching_consumes_exactly_the_launcher_words
    driver_argv = lambda do |cc, recipe|
      prefixes = Makefile.parse("CC = #{cc}\nLDSHARED = $(CC) -shared\n").tool_prefixes
      argv = Rubycc::CommandLine.argv(recipe)
      hit = prefixes.select { |prefix| Rmake::ToolCommand.match?(argv, prefix) }.max_by(&:length)
      hit && argv.drop(hit.length)
    end

    assert_equal ["-c", "a.c"], driver_argv.call("jruby /gem/exe/rubycc", "jruby /gem/exe/rubycc -c a.c")
    assert_equal ["-shared", "-o", "x.so"],
                 driver_argv.call("jruby /gem/exe/rubycc", "jruby /gem/exe/rubycc -shared -o x.so")
    assert_equal ["-c", "a.c"],
                 driver_argv.call("ruby -Ilib /gem/exe/rubycc", "ruby -Ilib /gem/exe/rubycc -c a.c")
    assert_nil driver_argv.call("gcc", "ruby /tmp/gcc -c a.c"),
               "a command that merely shares a basename with the tool must not be substituted"
    # The unchanged gcc behaviour, for contrast: matched, and `-shared` stays.
    assert_equal ["-c", "a.c"], driver_argv.call("gcc", "gcc -c a.c")
    assert_equal ["-shared", "-o", "x.so"], driver_argv.call("gcc", "gcc -shared -o x.so")
  end

  # A path with a space in it survives as one word: the shim quotes what it
  # writes, and both the Makefile's `$(CC)` and the recipe line are read back
  # through the same splitter.
  def test_tool_prefixes_keep_quoted_paths_with_spaces_whole
    mk = Makefile.parse("CC = '/a b/ruby' '/c d/exe/rubycc'\nLDSHARED = $(CC) -shared\n")
    assert_equal [["/a b/ruby", "/c d/exe/rubycc"]], mk.tool_prefixes
  end

  # And end to end: a Makefile whose CC is spelled the way the mkmf shim spells
  # it must still build through the Driver in-process. The interpreter word is a
  # path that does not exist, so nothing can be spawned from this Makefile at
  # all: the build can only succeed by never running the command as a process,
  # which is what substitution means.
  def test_interpreter_launched_compiler_is_substituted_in_process
    with_dir do |dir|
      write_mkmf_like_sources(dir)
      absent_ruby = path(dir, "no-such-bin", "ruby")
      text = File.read(path(dir, "Makefile")).sub("CC = gcc", "CC = #{absent_ruby} #{RUBYCC_EXE}")
      File.write(path(dir, "Makefile"), text)
      mk = Makefile.parse(text, dir: dir)
      mk.run("all", out: StringIO.new, tools: :rubycc, jobs: 1)

      so = path(dir, "mylib.so")
      assert File.exist?(so), "the interpreter-launched CC must still route to the Driver"
      lib = Fiddle.dlopen(so)
      assert_equal 11, call(lib, "a_val", [], Fiddle::TYPE_INT).call
    ensure
      lib&.close
    end
  end

  # The same build with both launcher words living under a directory whose name
  # contains a space, quoted in the Makefile the way the shim quotes them. The
  # link line's `-shared` has to survive the prefix trimming too, or the result
  # is an executable rather than a shared object and the dlopen fails.
  def test_launcher_paths_containing_spaces_still_build
    with_dir do |dir|
      write_mkmf_like_sources(dir)
      spaced = path(dir, "a b")
      FileUtils.mkdir_p(spaced)
      ruby_link = File.join(spaced, "ruby")
      rubycc_link = File.join(spaced, "rubycc")
      File.symlink(RbConfig.ruby, ruby_link)
      File.symlink(RUBYCC_EXE, rubycc_link)

      cc = "'#{ruby_link}' '#{rubycc_link}'"
      text = File.read(path(dir, "Makefile")).sub("CC = gcc", "CC = #{cc}")
      File.write(path(dir, "Makefile"), text)
      mk = Makefile.parse(text, dir: dir)
      assert_equal [[ruby_link, rubycc_link]], mk.tool_prefixes
      mk.run("all", out: StringIO.new, tools: :rubycc, jobs: 1)

      so = path(dir, "mylib.so")
      assert File.exist?(so), "a launcher path with a space must still build"
      lib = Fiddle.dlopen(so)
      assert_equal 31, call(lib, "b_val", [], Fiddle::TYPE_INT).call
    ensure
      lib&.close
    end
  end

  # With substitution off (the default) the compiler command is exec'd, not sent
  # to the Driver — so a Makefile naming a compiler that does not exist fails as a
  # missing external command rather than building anything.
  def test_tools_off_by_default_execs_externally
    with_dir do |dir|
      File.write(path(dir, "Makefile"), <<~MK)
        all:
        \tno-such-compiler-xyz -c thing.c
      MK
      mk = Makefile.parse(File.read(path(dir, "Makefile")), dir: dir)
      assert_raises(Rmake::CommandFailedError) { mk.run("all", out: StringIO.new) }
    end
  end

  # --- reentrancy: two Driver invocations in one run ------------------------

  # Building the same source twice (two separate runs) must yield byte-identical
  # objects: the Driver leaves no state behind between invocations, which is the
  # precondition for running it repeatedly in forked workers.
  def test_repeated_tool_builds_are_deterministic
    bytes = Array.new(2) do
      with_dir do |dir|
        write_mkmf_like_sources(dir)
        mk = Makefile.parse(File.read(path(dir, "Makefile")), dir: dir)
        mk.run("all", out: StringIO.new, tools: :rubycc, jobs: 2)
        File.binread(path(dir, "mylib.so"))
      end
    end
    assert_equal bytes[0], bytes[1], "rubycc's output must be deterministic across runs (N4)"
  end

  # --- failure isolation ----------------------------------------------------

  # A source rubycc cannot compile fails the step (naming its target) and stops
  # the build; the rmake process itself keeps running — the whole point of doing
  # the Driver work in a forked child.
  def test_compiler_failure_stops_build_and_survives_sequential
    with_dir do |dir|
      write_mkmf_like_sources(dir)
      File.write(path(dir, "a.c"), "int broken( { syntax error\n")
      mk = Makefile.parse(File.read(path(dir, "Makefile")), dir: dir)

      err = assert_raises(Rmake::CommandFailedError) do
        mk.run("all", out: StringIO.new, err: StringIO.new, tools: :rubycc, jobs: 1)
      end
      assert_equal "a.o", err.target
      refute File.exist?(path(dir, "mylib.so")), "the link must not run after a compile failure"
    end
  end

  def test_compiler_failure_stops_build_and_survives_parallel
    with_dir do |dir|
      write_mkmf_like_sources(dir)
      File.write(path(dir, "a.c"), "int broken( { syntax error\n")
      mk = Makefile.parse(File.read(path(dir, "Makefile")), dir: dir)

      err = assert_raises(Rmake::CommandFailedError) do
        mk.run("all", out: StringIO.new, tools: :rubycc, jobs: 2)
      end
      assert_equal "a.o", err.target
      refute File.exist?(path(dir, "mylib.so"))
    end
  end

  # --- -j scheduler: overlap and dependency order ---------------------------

  # A pseudo-compiler recipe: record a start/end interval for its target into a
  # shared trace file (append-mode writes are atomic for these short lines), with
  # a sleep long enough that two concurrent runs demonstrably overlap. Uses an
  # external `ruby` (spawned, not tool-substituted) so the scheduler's own
  # forking — not the Driver — is what is under test.
  PROBE = <<~RB
    name, trace = ARGV
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    File.open(trace, "a") { |f| f.puts("start \#{name} \#{t0}") }
    sleep 0.3
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    File.open(trace, "a") { |f| f.puts("end \#{name} \#{t1}") }
  RB

  PARALLEL_MAKEFILE = <<~MK
    .SUFFIXES: .c .o
    OBJS = a.o b.o
    all: lib.so
    lib.so: $(OBJS)
    \truby probe.rb link trace
    .c.o:
    \truby probe.rb $@ trace
  MK

  def write_parallel_project(dir)
    File.write(path(dir, "probe.rb"), PROBE)
    File.write(path(dir, "Makefile"), PARALLEL_MAKEFILE)
    FileUtils.touch(path(dir, "a.c"))
    FileUtils.touch(path(dir, "b.c"))
  end

  # Parse the trace into { "start"/"end" => { name => monotonic_time } }.
  def read_intervals(dir)
    intervals = Hash.new { |h, k| h[k] = {} }
    File.read(path(dir, "trace")).each_line do |line|
      phase, name, t = line.split
      intervals[phase][name] = t.to_f
    end
    intervals
  end

  def test_jobs_two_runs_independent_steps_concurrently
    with_dir do |dir|
      write_parallel_project(dir)
      mk = Makefile.parse(PARALLEL_MAKEFILE, dir: dir)
      mk.run("all", out: StringIO.new, jobs: 2)

      iv = read_intervals(dir)
      # a.o and b.o are independent: with two workers their intervals overlap.
      latest_start = [iv["start"]["a.o"], iv["start"]["b.o"]].max
      earliest_end = [iv["end"]["a.o"], iv["end"]["b.o"]].min
      assert_operator latest_start, :<, earliest_end,
                      "with jobs: 2 the two compiles should overlap in time"

      # The link depends on both objects and must start only after both finish.
      both_compiles_done = [iv["end"]["a.o"], iv["end"]["b.o"]].max
      assert_operator both_compiles_done, :<=, iv["start"]["link"],
                      "the link step must wait for both compiles (dependency order)"
    end
  end

  def test_jobs_one_runs_steps_sequentially
    with_dir do |dir|
      write_parallel_project(dir)
      mk = Makefile.parse(PARALLEL_MAKEFILE, dir: dir)
      mk.run("all", out: StringIO.new, jobs: 1)

      iv = read_intervals(dir)
      # Sequential: whichever compiles first must finish before the other starts.
      first_end = [iv["end"]["a.o"], iv["end"]["b.o"]].min
      last_start = [iv["start"]["a.o"], iv["start"]["b.o"]].max
      assert_operator first_end, :<=, last_start,
                      "with jobs: 1 the compiles must not overlap"
    end
  end

  # The plan carries the dependency edges the scheduler walks: the link step lists
  # both objects as prerequisites; the leaf compiles list none.
  def test_plan_records_step_prerequisites
    with_dir do |dir|
      write_parallel_project(dir)
      mk = Makefile.parse(PARALLEL_MAKEFILE, dir: dir)
      steps = mk.plan("all").steps.each_with_object({}) { |s, h| h[s.target] = s.prereqs.sort }

      assert_equal [], steps["a.o"]
      assert_equal [], steps["b.o"]
      assert_equal ["a.o", "b.o"], steps["lib.so"]
    end
  end

  def test_json_parser_makefile_template_is_portable
    fixture = File.join(FIXTURES_ROOT, "json-2.21.1/parser/Makefile")
    raw = File.read(fixture)
    assert_equal 1, raw.lines.count { |line| line == "topdir = /rubycc-fixture/ruby-4.0.6/include/ruby-4.0.6\n" }
    assert_equal 1, raw.lines.count { |line| line == "arch_hdrdir = /rubycc-fixture/ruby-4.0.6/include/ruby-4.0.6/x86_64-linux\n" }
    assert_equal 1, raw.lines.count { |line| line == "prefix = $(DESTDIR)/rubycc-fixture/ruby-4.0.6\n" }
    assert_equal 1, raw.lines.count { |line| line == "arch = x86_64-linux\n" }
    assert_equal 1, raw.lines.count { |line| line == "ruby_version = 4.0.6\n" }

    text = portable_json_parser_makefile(raw)

    refute_match(/__RUBY_[A-Z]+__/, text)
    refute_includes text, "/rubycc-fixture/ruby-4.0.6"
    assert_equal 1, text.lines.count { |line| line == "topdir = #{RbConfig::CONFIG.fetch('rubyhdrdir')}\n" }
    assert_equal 1, text.lines.count { |line| line == "arch_hdrdir = #{RbConfig::CONFIG.fetch('rubyarchhdrdir')}\n" }
    assert_equal 1, text.lines.count { |line| line == "prefix = $(DESTDIR)#{RbConfig::CONFIG.fetch('prefix')}\n" }
    assert_equal 1, text.lines.count { |line| line == "arch = #{RbConfig::CONFIG.fetch('arch')}\n" }
    assert_equal 1, text.lines.count { |line| line == "ruby_version = #{RbConfig::CONFIG.fetch('ruby_version')}\n" }
  end

  # --- optional real json acceptance (live or fixture) ----------------------

  # The ROADMAP B3 acceptance: drive the real fixture parser Makefile to
  # parser.so with `tools: :rubycc` and `jobs: 2`, then dlopen it. Needs the json
  # gem source, so it is opt-in (RMAKE_ACCEPTANCE=1). The fixture profile
  # supplies that source from a pinned local archive.
  def test_real_json_parser_makefile_builds_so
    AcceptanceResultReporter.with_result("rmake-json-parser") do
      unless ENV["RMAKE_ACCEPTANCE"] == "1" || AcceptanceFetchHelper.strict?
        skip "set RMAKE_ACCEPTANCE=1 to run the networked json acceptance"
      end

      src_parser = fetch_json_parser_src
      with_dir do |dir|
        fixture = File.join(FIXTURES_ROOT, "json-2.21.1/parser/Makefile")
        text = portable_json_parser_makefile(File.read(fixture))
        # Point srcdir/VPATH at the fetched source (fixtures stay untouched).
        text = text.sub(/^srcdir = .*$/, "srcdir = #{src_parser}")
        text = text.sub(/^VPATH = .*$/, "VPATH = #{src_parser}")
        File.write(path(dir, "Makefile"), text)

        mk = Makefile.parse(text, dir: dir)
        mk.run("all", out: StringIO.new, err: StringIO.new, tools: :rubycc, jobs: 2)

        so = path(dir, "parser.so")
        assert File.exist?(so), "rmake should build parser.so"

        lib = Fiddle.dlopen(so)
        refute_nil lib["Init_parser"], "parser.so must export Init_parser"
      ensure
        lib&.close
      end
    end
  end

  # The committed Makefile is a source fixture, not a snapshot of the machine
  # that generated it. Resolve the Ruby installation paths at test time so the
  # same acceptance runs on a developer checkout and on a GitHub Actions Ruby
  # installation with a different prefix, architecture, or Ruby ABI version.
  def portable_json_parser_makefile(text)
    assignments = {
      /^topdir = .*$/ => "topdir = #{RbConfig::CONFIG.fetch('rubyhdrdir')}",
      /^arch_hdrdir = .*$/ => "arch_hdrdir = #{RbConfig::CONFIG.fetch('rubyarchhdrdir')}",
      /^prefix = \$\(DESTDIR\).*$/ => "prefix = \$(DESTDIR)#{RbConfig::CONFIG.fetch('prefix')}",
      /^arch = .*$/ => "arch = #{RbConfig::CONFIG.fetch('arch')}",
      /^ruby_version = .*$/ => "ruby_version = #{RbConfig::CONFIG.fetch('ruby_version')}"
    }
    assignments.each do |pattern, replacement|
      count = text.scan(pattern).size
      raise "portable JSON fixture expected one #{pattern.inspect} assignment, got #{count}" unless count == 1

      text = text.sub(pattern, replacement)
    end
    text
  end

  # Fetch and unpack json 2.21.1, returning its ext/json/ext/parser dir. Normal
  # development runs preserve the opt-in skip behaviour; strict acceptance
  # turns a typed fetch failure into a test failure.
  def fetch_json_parser_src
    work = File.join(Dir.tmpdir, "rmake_json_acceptance")
    artifact = AcceptanceManifestHelper.artifact("gem-json-2.21.1-ruby")
    AcceptanceFetchHelper::Fetcher.new(work_dir: work).fetch_gem(
      gem_name: "json", version: "2.21.1", extension_subdir: "ext/json/ext/parser",
      required_file: "parser.c",
      expected_sha256: artifact.fetch("sha256"), artifact_id: artifact.fetch("id"),
      artifact_url: artifact.fetch("url"), fixture_path: artifact.fetch("fixture", nil)
    )
  rescue AcceptanceFetchHelper::Failure => e
    raise e if AcceptanceFetchHelper.strict?

    skip "could not prepare json-2.21.1: #{e.message}"
  end
end
