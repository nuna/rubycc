# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"

# Step 57 (M3 / ROADMAP §6 B2): unit tests for the shell-less recipe runner —
# rmake's Executor, which interprets an execution Plan without /bin/sh (DESIGN
# R5). The construct set is fixed by the six real mkmf Makefiles under
# test/fixtures/mkmf: simple commands, the `&&`/`||`/`;` connectors, `>`/`>>`/
# `2>` redirections, `cd` and `VAR=value` prefixes, the `@`/`-` recipe
# attributes, and the FileUtils-backed builtins (rm/mkdir/rmdir/cp/install/echo/
# touch/`:`/exit). These tests pin each mechanism in isolation; the replay tests
# below exercise real fixture recipes end-to-end.
class TestRmakeExecutor < Minitest::Test
  Rmake = Rubycc::Rmake
  Executor = Rmake::Executor

  # Build a one-target Plan from raw recipe texts and execute it in +dir+.
  # Returns the captured stdout so echo/print effects can be asserted.
  def run_recipes(dir, texts, out: StringIO.new, dry_run: false, target: "t",
                  silent: false, ignore_error: false, env: ENV)
    commands = texts.map do |text|
      Rmake::Command.new(text: text, silent: silent, ignore_error: ignore_error, force: false)
    end
    plan = Rmake::Plan.new([Rmake::Step.new(target: target, commands: commands)])
    Executor.new(dir: dir, out: out, dry_run: dry_run, env: env).execute(plan)
    out.string
  end

  def with_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def path(dir, *parts)
    File.join(dir, *parts)
  end

  # --- word splitting and quoting -------------------------------------------

  def test_words_split_on_runs_of_whitespace
    with_dir do |dir|
      out = StringIO.new
      run_recipes(dir, ["echo a   b\tc"], out: out, silent: true)
      assert_equal "a b c\n", out.string
    end
  end

  def test_double_quotes_protect_whitespace
    with_dir do |dir|
      out = StringIO.new
      run_recipes(dir, ['echo "a   b" c'], out: out, silent: true)
      assert_equal "a   b c\n", out.string
    end
  end

  def test_single_quotes_protect_whitespace
    with_dir do |dir|
      out = StringIO.new
      run_recipes(dir, ["echo 'x  y'"], out: out, silent: true)
      assert_equal "x  y\n", out.string
    end
  end

  def test_adjacent_quoted_and_bare_join_into_one_word
    with_dir do |dir|
      # `a"b"c` is a single word `abc`, so touching it makes one file.
      run_recipes(dir, ['touch a"b"c'], target: "t")
      assert_equal ["abc"], Dir.children(dir)
    end
  end

  # --- backslash quote removal (Step 157 gap A) -----------------------------
  #
  # POSIX quote removal (XCU 2.2 / 2.2.3), each rule checked against /bin/sh
  # (dash) before being encoded here:
  #   1. Outside any quote a backslash preserves the literal value of the next
  #      character and disappears itself (`\`+newline is a line continuation:
  #      both vanish).
  #   2. Inside double quotes a backslash is special only before
  #      `$`/`` ` ``/`"`/`\`/newline; before any other character it stays in
  #      the word (counter-intuitive: `"a\b"` -> `a\b`, not `ab`).
  #   3. Inside single quotes a backslash is entirely literal.
  # mkmf's `-DSYSCONFDIR=\"...\"` relies on rule 1: /bin/sh unescapes the
  # backslash-quotes into a literal `"` inside one word.

  def test_backslash_outside_quotes_escapes_a_quote_character
    with_dir do |dir|
      run_recipes(dir, ['touch a\"b'])
      assert_equal ['a"b'], Dir.children(dir)
    end
  end

  def test_backslash_outside_quotes_escapes_a_space_so_the_word_stays_one
    with_dir do |dir|
      run_recipes(dir, ['touch a\ b'])
      assert_equal ["a b"], Dir.children(dir)
    end
  end

  def test_backslash_outside_quotes_escapes_a_backslash
    with_dir do |dir|
      run_recipes(dir, ["touch a\\\\b"])
      assert_equal ["a\\b"], Dir.children(dir)
    end
  end

  def test_backslash_in_double_quotes_keeps_a_quote_special
    with_dir do |dir|
      run_recipes(dir, ['touch "a\"b"'])
      assert_equal ['a"b'], Dir.children(dir)
    end
  end

  def test_backslash_in_double_quotes_keeps_a_dollar_special
    with_dir do |dir|
      run_recipes(dir, ['touch "a\$b"'])
      assert_equal ["a$b"], Dir.children(dir)
    end
  end

  def test_backslash_in_double_quotes_stays_before_an_ordinary_character
    with_dir do |dir|
      # The counter-intuitive rule: unlike outside quotes, a backslash before
      # an ordinary character inside double quotes is NOT special, so it
      # stays in the word. Verified against /bin/sh: `"a\bb"` -> `a\bb`.
      run_recipes(dir, ['touch "a\bb"'])
      assert_equal ["a\\bb"], Dir.children(dir)
    end
  end

  def test_backslash_in_single_quotes_is_literal
    with_dir do |dir|
      run_recipes(dir, ["touch 'a\\b'"])
      assert_equal ["a\\b"], Dir.children(dir)
    end
  end

  def test_tokenize_backslash_newline_is_a_line_continuation
    # Exercises tokenize directly: a shell-level backslash-newline vanishes
    # entirely. In real recipes this text never reaches tokenize with an
    # embedded newline, because Makefile recipe continuations (a trailing `\`
    # at the end of a physical line) are already folded into one logical line
    # by Parser#logical_lines before the Executor ever sees the text — that is
    # make's own continuation, distinct from this shell-level rule, and it
    # runs first. This test isolates the shell-level rule at the tokenizer.
    executor = Executor.new(dir: Dir.pwd, out: StringIO.new)
    tokens = executor.send(:tokenize, "t", "echo a\\\nb")
    assert_equal [[:word, "echo"], [:word, "ab"]], tokens
  end

  def test_mkmf_sysconfdir_define_matches_bin_sh_word_splitting
    # The exact shape mkmf writes for etc.c: `$(CC) -DSYSCONFDIR=\"...\" -c
    # etc.c -o etc.o`, after $(CC) has already been expanded to a bare
    # program name by the planner.
    recipe = 'gcc -DSYSCONFDIR=\"/tmp/x\" -c etc.c -o etc.o'
    executor = Executor.new(dir: Dir.pwd, out: StringIO.new)
    words = executor.send(:tokenize, "t", recipe).select { |t| t[0] == :word }.map { |t| t[1] }
    assert_equal ["gcc", '-DSYSCONFDIR="/tmp/x"', "-c", "etc.c", "-o", "etc.o"], words

    skip "/bin/sh is not available" unless File.executable?("/bin/sh")

    # Cross-check against /bin/sh itself: swap `gcc` for `printf '%s\n'` so the
    # same trailing arguments are split by the real shell without executing a
    # compiler, then compare word-for-word against tokenize's own split.
    sh_recipe = recipe.sub(/\Agcc/, %q(printf '%s\n'))
    out, _err, status = Open3.capture3("/bin/sh", "-c", sh_recipe)
    assert status.success?
    assert_equal words.drop(1), out.lines.map(&:chomp)
  end

  # --- connectors: && / || / ; ----------------------------------------------

  def test_and_runs_second_only_after_success
    with_dir do |dir|
      run_recipes(dir, ["true && touch made"])
      assert File.exist?(path(dir, "made"))
    end
  end

  def test_and_skips_second_after_failure
    with_dir do |dir|
      # `rm` of a missing file without -f fails, so the && side must not run.
      assert_raises(Rmake::CommandFailedError) do
        run_recipes(dir, ["rm missing && touch made"])
      end
      refute File.exist?(path(dir, "made"))
    end
  end

  def test_or_runs_second_only_after_failure
    with_dir do |dir|
      run_recipes(dir, ["rm missing || touch recovered"])
      assert File.exist?(path(dir, "recovered")), "|| side should run when left fails"
    end
  end

  def test_or_skips_second_after_success
    with_dir do |dir|
      run_recipes(dir, ["true || touch made"])
      refute File.exist?(path(dir, "made"))
    end
  end

  def test_semicolon_runs_both_unconditionally
    with_dir do |dir|
      # Left side fails but `;` still runs the right side; and since the final
      # command (touch) succeeds, the whole line succeeds.
      run_recipes(dir, ["rm missing ; touch made"], ignore_error: true)
      assert File.exist?(path(dir, "made"))
    end
  end

  def test_left_to_right_status_threads_through_and_or
    with_dir do |dir|
      # `false-ish && x || y`: the && is skipped (left failed), the || then runs y.
      run_recipes(dir, ["rm missing && touch x || touch y"])
      refute File.exist?(path(dir, "x"))
      assert File.exist?(path(dir, "y"))
    end
  end

  # --- redirections ---------------------------------------------------------

  def test_stdout_truncate_redirect_writes_file
    with_dir do |dir|
      run_recipes(dir, ["echo hi > out.txt"])
      assert_equal "hi\n", File.read(path(dir, "out.txt"))
    end
  end

  def test_stdout_append_redirect_appends
    with_dir do |dir|
      run_recipes(dir, ["echo one > log", "echo two >> log"])
      assert_equal "one\ntwo\n", File.read(path(dir, "log"))
    end
  end

  def test_truncate_redirect_creates_empty_file_even_without_output
    with_dir do |dir|
      # mkmf's `TOUCH = exit >` idiom: the `>` creates the stamp, `exit` succeeds.
      run_recipes(dir, ["exit > .stamp.time"])
      assert File.exist?(path(dir, ".stamp.time"))
      assert_equal "", File.read(path(dir, ".stamp.time"))
    end
  end

  def test_stderr_redirect_to_devnull_is_accepted
    with_dir do |dir|
      # rmdir of a non-empty dir writes to stderr; 2>/dev/null swallows it and
      # `|| true` keeps the line green.
      FileUtils.mkdir_p(path(dir, "d"))
      FileUtils.touch(path(dir, "d", "keep"))
      run_recipes(dir, ["rmdir d 2> /dev/null || true"])
      assert File.directory?(path(dir, "d")), "non-empty dir must survive"
    end
  end

  # --- cd scope -------------------------------------------------------------

  def test_cd_scopes_to_the_rest_of_its_line
    with_dir do |dir|
      FileUtils.mkdir_p(path(dir, "sub"))
      run_recipes(dir, ["cd sub && touch inside"])
      assert File.exist?(path(dir, "sub", "inside"))
    end
  end

  def test_cd_does_not_leak_into_the_next_line
    with_dir do |dir|
      FileUtils.mkdir_p(path(dir, "sub"))
      run_recipes(dir, ["cd sub && touch a", "touch b"])
      assert File.exist?(path(dir, "sub", "a"))
      # Second line starts from the base dir again, not from sub.
      assert File.exist?(path(dir, "b"))
      refute File.exist?(path(dir, "sub", "b"))
    end
  end

  def test_cd_into_missing_directory_fails_and_short_circuits
    with_dir do |dir|
      assert_raises(Rmake::CommandFailedError) do
        run_recipes(dir, ["cd nope && touch made"])
      end
      refute File.exist?(path(dir, "made"))
    end
  end

  # --- VAR=value prefix -----------------------------------------------------

  # Drop a small ruby probe that records ENV["RMK"] into the file named by its
  # first argument, so leading `VAR=value` assignments can be observed without
  # fragile inline quoting.
  def write_env_probe(dir)
    File.write(path(dir, "probe.rb"), <<~RB)
      File.write(ARGV[0], ENV.fetch("RMK", "unset"))
    RB
  end

  def test_var_prefix_sets_environment_for_one_command
    with_dir do |dir|
      write_env_probe(dir)
      run_recipes(dir, ["RMK=yes ruby probe.rb seen"])
      assert_equal "yes", File.read(path(dir, "seen"))
    end
  end

  def test_var_prefix_does_not_persist_to_later_command
    with_dir do |dir|
      write_env_probe(dir)
      run_recipes(dir, [
                    "RMK=yes ruby probe.rb first",
                    "ruby probe.rb second"
                  ])
      assert_equal "yes", File.read(path(dir, "first"))
      assert_equal "unset", File.read(path(dir, "second"))
    end
  end

  # --- builtins -------------------------------------------------------------

  def test_rm_f_ignores_missing_files
    with_dir do |dir|
      FileUtils.touch(path(dir, "present"))
      run_recipes(dir, ["rm -f present absent"]) # must not raise
      refute File.exist?(path(dir, "present"))
    end
  end

  def test_rm_without_f_fails_on_missing_file
    with_dir do |dir|
      assert_raises(Rmake::CommandFailedError) { run_recipes(dir, ["rm absent"]) }
    end
  end

  def test_rm_r_removes_directories_recursively
    with_dir do |dir|
      FileUtils.mkdir_p(path(dir, "tree", "deep"))
      FileUtils.touch(path(dir, "tree", "deep", "f"))
      run_recipes(dir, ["rm -fr tree"])
      refute File.exist?(path(dir, "tree"))
    end
  end

  def test_rm_expands_globs_and_leaves_nonmatching_literal
    with_dir do |dir|
      FileUtils.touch(path(dir, "a.bak"))
      FileUtils.touch(path(dir, "b.bak"))
      FileUtils.touch(path(dir, ".x.time"))
      # `*.o` matches nothing -> stays literal -> rm -f ignores it silently.
      run_recipes(dir, ["rm -f *.bak .*.time *.o"])
      assert_empty Dir.glob(path(dir, "*.bak"))
      refute File.exist?(path(dir, ".x.time"))
    end
  end

  def test_mkdir_p_creates_nested_directories
    with_dir do |dir|
      run_recipes(dir, ["mkdir -p a/b/c"])
      assert File.directory?(path(dir, "a", "b", "c"))
    end
  end

  def test_mkdir_p_is_idempotent_on_existing_dir
    with_dir do |dir|
      FileUtils.mkdir_p(path(dir, "exists"))
      run_recipes(dir, ["mkdir -p exists"]) # must not raise
      assert File.directory?(path(dir, "exists"))
    end
  end

  def test_absolute_path_command_resolves_to_builtin
    with_dir do |dir|
      # /usr/bin/mkdir is dispatched by basename to the in-process builtin, so
      # it works even where no such binary exists.
      run_recipes(dir, ["/usr/bin/mkdir -p made"])
      assert File.directory?(path(dir, "made"))
    end
  end

  def test_install_copies_and_sets_octal_mode
    with_dir do |dir|
      File.write(path(dir, "lib.so"), "BINARY")
      FileUtils.mkdir_p(path(dir, "dest"))
      run_recipes(dir, ["/usr/bin/install -c -m 0755 lib.so dest"])
      installed = path(dir, "dest", "lib.so")
      assert_equal "BINARY", File.read(installed)
      assert_equal 0o755, File.stat(installed).mode & 0o777
    end
  end

  def test_install_data_mode_644
    with_dir do |dir|
      File.write(path(dir, "data.rb"), "x")
      FileUtils.mkdir_p(path(dir, "dest"))
      run_recipes(dir, ["install -c -m 644 data.rb dest"])
      assert_equal 0o644, File.stat(path(dir, "dest", "data.rb")).mode & 0o777
    end
  end

  def test_cp_into_directory
    with_dir do |dir|
      File.write(path(dir, "src.txt"), "data")
      FileUtils.mkdir_p(path(dir, "d"))
      run_recipes(dir, ["cp src.txt d"])
      assert_equal "data", File.read(path(dir, "d", "src.txt"))
    end
  end

  def test_touch_creates_file
    with_dir do |dir|
      run_recipes(dir, ["touch fresh"])
      assert File.exist?(path(dir, "fresh"))
    end
  end

  def test_rmdir_removes_empty_directory
    with_dir do |dir|
      FileUtils.mkdir_p(path(dir, "empty"))
      run_recipes(dir, ["rmdir empty"])
      refute File.exist?(path(dir, "empty"))
    end
  end

  def test_rmdir_non_empty_fails_without_ignore_flag
    with_dir do |dir|
      FileUtils.mkdir_p(path(dir, "full"))
      FileUtils.touch(path(dir, "full", "f"))
      assert_raises(Rmake::CommandFailedError) { run_recipes(dir, ["rmdir full"]) }
    end
  end

  def test_rmdir_ignore_flag_tolerates_non_empty
    with_dir do |dir|
      FileUtils.mkdir_p(path(dir, "full"))
      FileUtils.touch(path(dir, "full", "f"))
      run_recipes(dir, ["rmdir --ignore-fail-on-non-empty full"]) # must not raise
      assert File.directory?(path(dir, "full"))
    end
  end

  def test_colon_and_true_are_no_op_successes
    with_dir do |dir|
      run_recipes(dir, [":", "true && touch after"])
      assert File.exist?(path(dir, "after"))
    end
  end

  # --- external commands ----------------------------------------------------

  def test_external_command_runs_with_argv_array
    with_dir do |dir|
      # Single quotes protect the script from word splitting, exactly as a recipe
      # would quote it; the runner passes it to ruby as one argv element.
      run_recipes(dir, ["ruby -e 'File.write(%q(out), %q(ext))'"])
      assert_equal "ext", File.read(path(dir, "out"))
    end
  end

  def test_external_nonzero_exit_propagates_as_failure
    with_dir do |dir|
      assert_raises(Rmake::CommandFailedError) do
        run_recipes(dir, ["ruby -e 'exit(3)'"])
      end
    end
  end

  def test_missing_external_command_is_a_failure
    with_dir do |dir|
      err = assert_raises(Rmake::CommandFailedError) do
        run_recipes(dir, ["definitely-not-a-real-tool-xyz arg"])
      end
      assert_equal "t", err.target
    end
  end

  # A one-word recipe command used to reach Process.spawn as a bare string,
  # which Ruby execs via /bin/sh whenever there is nothing else in argv (see
  # rmake-no-shell-fallback). A missing one-word command must fail the same
  # way a missing multi-word one does — "cannot execute", never a shell's own
  # "not found"/syntax-error text — regardless of the target environment
  # having a shell at all.
  def test_a_single_word_missing_command_is_not_run_through_a_shell
    with_dir do |dir|
      err = assert_raises(Rmake::CommandFailedError) do
        run_recipes(dir, ["definitely-not-a-real-tool-xyz"])
      end
      assert_equal "t", err.target
      assert_includes err.message, "cannot execute definitely-not-a-real-tool-xyz"
    end
  end

  # --- recipe attributes: - (ignore) and @ (silent) -------------------------

  def test_dash_attribute_ignores_a_failing_command
    with_dir do |dir|
      # A failing line with ignore_error keeps the build going.
      run_recipes(dir, ["rm absent", "touch after"], ignore_error: true)
      assert File.exist?(path(dir, "after"))
    end
  end

  def test_at_attribute_suppresses_command_echo_but_still_runs
    with_dir do |dir|
      out = StringIO.new
      run_recipes(dir, ["touch quiet"], out: out, silent: true)
      assert File.exist?(path(dir, "quiet")), "silent command must still run"
      refute_includes out.string, "touch quiet", "@ must suppress the echo"
    end
  end

  def test_non_silent_command_is_echoed_before_running
    with_dir do |dir|
      out = StringIO.new
      run_recipes(dir, ["touch shown"], out: out, silent: false)
      assert_includes out.string, "touch shown"
    end
  end

  # --- dry run --------------------------------------------------------------

  def test_dry_run_prints_every_line_and_runs_nothing
    with_dir do |dir|
      out = StringIO.new
      run_recipes(dir, ["touch a", "rm b"], out: out, dry_run: true, silent: true)
      # Even @-silent lines are printed under -n (matches make and #command_lines).
      assert_includes out.string, "touch a"
      assert_includes out.string, "rm b"
      refute File.exist?(path(dir, "a")), "dry run must not execute"
    end
  end

  # --- unsupported syntax fails loudly --------------------------------------

  def test_pipe_is_unsupported
    with_dir do |dir|
      err = assert_raises(Rmake::UnsupportedRecipeError) do
        run_recipes(dir, ["echo hi | cat"])
      end
      assert_equal "t", err.target
      assert_includes err.message, "echo hi | cat"
    end
  end

  def test_background_ampersand_is_unsupported
    with_dir do |dir|
      assert_raises(Rmake::UnsupportedRecipeError) { run_recipes(dir, ["sleep 1 &"]) }
    end
  end

  def test_command_substitution_backtick_is_unsupported
    with_dir do |dir|
      assert_raises(Rmake::UnsupportedRecipeError) { run_recipes(dir, ["echo `pwd`"]) }
    end
  end

  def test_subshell_paren_is_unsupported
    with_dir do |dir|
      assert_raises(Rmake::UnsupportedRecipeError) { run_recipes(dir, ["(cd x)"]) }
    end
  end

  def test_unterminated_quote_is_unsupported
    with_dir do |dir|
      assert_raises(Rmake::UnsupportedRecipeError) { run_recipes(dir, ['echo "open']) }
    end
  end

  # --- the shell subset: for / if / brace group / variables ------------------
  #
  # Step rmake-shell-subset-1. The syntax is Rubycc::Shell's (unit-tested in
  # test_shell.rb); what is pinned here is the join between the two layers —
  # Shell decides what runs, this runner runs it with the builtins, the cwd and
  # the redirections it owns.

  def test_the_automake_install_shape_produces_what_gnu_make_produces
    # The recipe from issues/rmake-automake-shell-recipes.md, already past
    # make's own `$$` -> `$` expansion (run_recipes hands Command texts straight
    # to the Executor). It used to be refused as a reserved word; with only
    # a.txt present GNU make prints `found: a.txt`, and so must rmake.
    recipe = 'list=\'a.txt b.txt\'; list2=; for p in $list; do if test -f $p; ' \
             'then list2="$list2 $p"; else :; fi; done; test -z "$list2" || { echo found: $list2; }'
    with_dir do |dir|
      FileUtils.touch(path(dir, "a.txt"))
      out = StringIO.new
      run_recipes(dir, [recipe], out: out, silent: true)
      assert_equal "found: a.txt\n", out.string
    end
  end

  def test_for_loop_runs_a_builtin_per_word
    with_dir do |dir|
      run_recipes(dir, ["for f in a b c; do touch $f; done"])
      assert_equal %w[a b c], Dir.children(dir).sort
    end
  end

  def test_for_loop_over_an_empty_list_does_nothing_and_succeeds
    with_dir do |dir|
      run_recipes(dir, ["list=; for f in $list; do touch $f; done"])
      assert_empty Dir.children(dir)
    end
  end

  def test_if_selects_a_branch_on_a_builtin_status
    with_dir do |dir|
      FileUtils.touch(path(dir, "there"))
      run_recipes(dir, ["if test -f there; then touch yes; else touch no; fi"])
      assert_equal %w[there yes], Dir.children(dir).sort
    end
  end

  def test_a_shell_variable_lives_for_one_recipe_line_only
    # make runs every line in its own shell, so the second line must not see
    # the first line's variable.
    with_dir do |dir|
      out = StringIO.new
      run_recipes(dir, ["name=first; echo got:$name", "echo got:$name"], out: out, silent: true)
      assert_equal "got:first\ngot:\n", out.string
    end
  end

  def test_a_variable_set_in_a_loop_accumulates_and_reaches_a_builtin
    with_dir do |dir|
      out = StringIO.new
      run_recipes(dir, ['list=; for p in a b; do list="$list $p"; done; echo kept:$list'],
                  out: out, silent: true)
      assert_equal "kept:a b\n", out.string
    end
  end

  def test_cd_inside_a_loop_still_moves_the_rest_of_the_line
    with_dir do |dir|
      FileUtils.mkdir(path(dir, "sub"))
      run_recipes(dir, ["cd sub; for f in a b; do touch $f; done"])
      assert_equal %w[a b], Dir.children(path(dir, "sub")).sort
    end
  end

  def test_a_brace_group_is_guarded_as_one_command
    with_dir do |dir|
      run_recipes(dir, ["rm missing || { touch recovered; touch again; }"])
      assert_equal %w[again recovered], Dir.children(dir).sort
    end
  end

  def test_a_redirection_inside_a_group_applies_to_its_own_command
    with_dir do |dir|
      run_recipes(dir, ['{ echo one > log; echo two >> log; }'])
      assert_equal "one\ntwo\n", File.read(path(dir, "log"))
    end
  end

  def test_an_expanded_word_is_globbed_like_any_other
    with_dir do |dir|
      FileUtils.touch(path(dir, "x.o"))
      out = StringIO.new
      run_recipes(dir, ['pat=*.o; echo $pat'], out: out, silent: true)
      assert_equal "x.o\n", out.string
    end
  end

  # --- the test / [ builtin -------------------------------------------------
  #
  # `test` is a builtin for the same reason as the rest of them: the minimal
  # target environment has no coreutils (DESIGN R5), so a recipe that branches
  # on `test -f` must not depend on /usr/bin/test being installed.

  def test_file_primaries_answer_about_the_commands_cwd
    with_dir do |dir|
      FileUtils.touch(path(dir, "file"))
      File.write(path(dir, "sized"), "x")
      FileUtils.mkdir(path(dir, "adir"))
      {
        "-f file" => true, "-f adir" => false, "-f missing" => false,
        "-d adir" => true, "-d file" => false,
        "-e file" => true, "-e adir" => true, "-e missing" => false,
        "-r file" => true, "-r missing" => false,
        "-s sized" => true, "-s file" => false
      }.each do |expression, expected|
        out = StringIO.new
        run_recipes(dir, ["test #{expression} && echo yes || echo no"], out: out, silent: true)
        assert_equal("#{expected ? "yes" : "no"}\n", out.string, expression)
      end
    end
  end

  def test_string_primaries_and_comparisons
    with_dir do |dir|
      {
        '-n "x"' => true, '-n ""' => false,
        '-z ""' => true, '-z "x"' => false,
        "a = a" => true, "a = b" => false,
        "a != b" => true, "a != a" => false,
        '"x"' => true, '""' => false
      }.each do |expression, expected|
        out = StringIO.new
        run_recipes(dir, ["test #{expression} && echo yes || echo no"], out: out, silent: true)
        assert_equal("#{expected ? "yes" : "no"}\n", out.string, expression)
      end
    end
  end

  def test_bang_negates_a_test
    with_dir do |dir|
      out = StringIO.new
      run_recipes(dir, ["test ! -f missing && echo yes || echo no"], out: out, silent: true)
      assert_equal "yes\n", out.string
    end
  end

  def test_bracket_form_requires_its_closing_bracket
    with_dir do |dir|
      out = StringIO.new
      run_recipes(dir, ["[ -d . ] && echo yes || echo no"], out: out, silent: true)
      assert_equal "yes\n", out.string

      assert_raises(Rmake::UnsupportedRecipeError) { run_recipes(dir, ["[ -d . "]) }
    end
  end

  def test_an_unimplemented_test_primary_is_refused_not_guessed
    with_dir do |dir|
      err = assert_raises(Rmake::UnsupportedRecipeError) { run_recipes(dir, ["test -x file"]) }
      assert_includes err.message, "test primary '-x'"
      assert_raises(Rmake::UnsupportedRecipeError) { run_recipes(dir, ["test 1 -eq 1"]) }
    end
  end

  def test_a_false_test_fails_the_recipe_line
    with_dir do |dir|
      assert_raises(Rmake::CommandFailedError) { run_recipes(dir, ["test -f missing"]) }
    end
  end

  # --- constructs that stay refused -----------------------------------------

  def test_a_loop_rmake_has_no_grammar_for_is_still_refused
    with_dir do |dir|
      err = assert_raises(Rmake::UnsupportedRecipeError) do
        run_recipes(dir, ["while true; do touch a; done"])
      end
      assert_equal "t", err.target
      assert_includes err.message, "shell reserved word 'while'"
      refute File.exist?(path(dir, "a")), "nothing may run when the line does not parse"
    end
  end

  def test_a_misplaced_keyword_is_reported_against_its_target
    with_dir do |dir|
      err = assert_raises(Rmake::UnsupportedRecipeError) do
        run_recipes(dir, ["touch a; done"])
      end
      assert_includes err.message, "unexpected 'done'"
    end
  end
end
