# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/shell"

# Step rmake-shell-subset-1: the shell subset rubycc interprets itself
# (lib/rubycc/shell.rb) — the `for` loop, `if`, brace groups, shell variables
# and parameter expansion that Automake and libtool write their install rules
# with. What is pinned here is the syntax layer only: Shell never runs a simple
# command, it hands each one to the runner its caller supplied, so these tests
# supply a runner that records the commands and answers with a fixed status.
# Running them for real (the builtins, `test`, redirections) is rmake's job and
# is covered in test_rmake_executor.rb.
#
# The refusals matter as much as the constructs. A shell-less build must fail
# loudly on syntax it does not interpret rather than approximate it, so every
# construct left out is pinned to UnsupportedSyntaxError too.
class TestShell < Minitest::Test
  Shell = Rubycc::Shell

  # Run +text+, recording each simple command. A command named `false` fails
  # and everything else succeeds, which is enough to drive every branch and
  # status rule without a filesystem.
  def run_shell(text, variables: {}, environment: {})
    @commands = []
    @shell = Shell.new(variables: variables, environment: environment) do |command|
      @commands << command
      command.argv.first != "false"
    end
    @shell.run(text)
  end

  # The argv of every simple command that ran, in order.
  def argvs
    @commands.map(&:argv)
  end

  def refusal(text)
    assert_raises(Shell::UnsupportedSyntaxError) { run_shell(text) }
  end

  # --- for ------------------------------------------------------------------

  def test_for_runs_the_body_once_per_word
    assert run_shell("for p in a b c; do echo $p; done")
    assert_equal [%w[echo a], %w[echo b], %w[echo c]], argvs
  end

  def test_for_splits_an_unquoted_expansion_into_words
    # The reason field splitting has to exist at all: Automake builds the list
    # as one string and loops over it.
    assert run_shell("list='a b'; for p in $list; do echo $p; done")
    assert_equal [%w[echo a], %w[echo b]], argvs
  end

  def test_for_over_an_empty_variable_runs_nothing_and_succeeds
    assert run_shell("list=; for p in $list; do echo $p; done")
    assert_empty argvs
  end

  def test_for_takes_the_status_of_the_last_iteration
    refute run_shell("for p in true false; do $p; done")
    assert run_shell("for p in false true; do $p; done")
  end

  def test_for_leaves_the_variable_set_to_the_last_word
    run_shell("for p in a b; do echo $p; done")
    assert_equal "b", @shell.variables["p"]
  end

  def test_do_inside_the_word_list_is_an_ordinary_word
    # The list ends at the `;`, not at the first `do`. Verified against
    # /bin/sh: `for p in a do b; do echo $p; done` prints a, do, b.
    assert run_shell("for p in a do b; do echo $p; done")
    assert_equal [%w[echo a], %w[echo do], %w[echo b]], argvs
  end

  def test_a_for_without_a_separator_before_do_is_refused
    # Also what /bin/sh does: `for p in a b do ...; done` is a syntax error.
    refusal("for p in a b do echo $p; done")
  end

  # --- if -------------------------------------------------------------------

  def test_if_runs_the_then_branch_when_the_condition_succeeds
    assert run_shell("if true; then echo yes; else echo no; fi")
    assert_equal [%w[true], %w[echo yes]], argvs
  end

  def test_if_runs_the_else_branch_when_the_condition_fails
    assert run_shell("if false; then echo yes; else echo no; fi")
    assert_equal [%w[false], %w[echo no]], argvs
  end

  def test_elif_conditions_are_tried_in_order
    assert run_shell("if false; then echo a; elif false; then echo b; elif true; then echo c; else echo d; fi")
    assert_equal [%w[false], %w[false], %w[true], %w[echo c]], argvs
  end

  def test_an_if_with_no_branch_taken_and_no_else_succeeds
    assert run_shell("if false; then echo a; fi")
    assert_equal [%w[false]], argvs
  end

  def test_the_condition_is_the_status_of_its_last_command
    # An `if` condition is a whole list, not one command.
    assert run_shell("if false; true; then echo yes; fi")
    assert_equal [%w[false], %w[true], %w[echo yes]], argvs
  end

  def test_if_inside_for_accumulates_across_iterations
    # The shape the Automake install rule is built from.
    assert run_shell("list='a b'; kept=; for p in $list; do if true; then kept=\"$kept $p\"; else :; fi; done")
    assert_equal " a b", @shell.variables["kept"]
  end

  # --- brace group ----------------------------------------------------------

  def test_brace_group_runs_its_body_and_takes_the_last_status
    refute run_shell("{ echo a; false; }")
    assert_equal [%w[echo a], %w[false]], argvs
  end

  def test_brace_group_is_a_single_command_for_a_connector
    # `||` guards the whole group, which is what the group is there for.
    assert run_shell("false || { echo recovered; }")
    assert_equal [%w[false], %w[echo recovered]], argvs
  end

  def test_a_brace_group_does_not_isolate_its_variables
    # Unlike a subshell (which is not supported), a group shares the line's
    # variables.
    run_shell("{ x=1; }; echo $x")
    assert_equal [%w[echo 1]], argvs
  end

  # --- variables and expansion ---------------------------------------------

  def test_an_assignment_persists_for_the_rest_of_the_line
    assert run_shell("x=1; echo $x")
    assert_equal [%w[echo 1]], argvs
    assert_equal "1", @shell.variables["x"]
  end

  def test_an_assignment_in_front_of_a_command_is_that_commands_environment
    # `VAR=value cmd` must keep meaning what it meant before this layer
    # existed: the command's environment, not a shell variable.
    assert run_shell("X=1 echo hi; echo $X")
    assert_equal [%w[echo hi], %w[echo]], argvs
    assert_equal ["X=1"], @commands.first.assignments
    refute @shell.variables.key?("X")
  end

  def test_braced_expansion_names_the_variable_explicitly
    run_shell("x=1; echo ${x}2")
    assert_equal [%w[echo 12]], argvs
  end

  def test_an_unset_variable_expands_to_nothing
    run_shell("echo a$missing b")
    assert_equal [%w[echo a b]], argvs
  end

  def test_a_quoted_expansion_is_one_word_even_when_it_holds_spaces
    run_shell("x='a b'; echo \"$x\"")
    assert_equal [["echo", "a b"]], argvs
  end

  def test_a_quoted_expansion_of_an_empty_variable_is_an_empty_word
    # `test -z "$list2"` depends on this: the word must survive so that the
    # command still sees an operand.
    run_shell("x=; echo \"$x\"")
    assert_equal [["echo", ""]], argvs
  end

  def test_single_quotes_suppress_expansion
    run_shell("x=1; echo '$x'")
    assert_equal [["echo", "$x"]], argvs
  end

  def test_a_backslash_keeps_a_dollar_literal
    run_shell('x=1; echo \\$x')
    assert_equal [["echo", "$x"]], argvs
  end

  def test_a_dollar_that_names_nothing_stays_a_dollar
    run_shell('echo a$ $/')
    assert_equal [["echo", "a$", "$/"]], argvs
  end

  def test_an_expanded_value_is_data_not_syntax
    # A value holding shell punctuation must not become structure — the whole
    # point of expanding into quoted words.
    run_shell("x='a; echo b'; echo $x")
    assert_equal [%w[echo a; echo b]], argvs
  end

  def test_a_value_with_a_space_splits_only_when_unquoted
    run_shell("x='a b'; echo $x; echo \"$x\"")
    assert_equal [%w[echo a b], ["echo", "a b"]], argvs
  end

  def test_expansion_inside_double_quotes_keeps_the_words_together
    run_shell("a=1; b='x y'; echo \"$a-$b\"")
    assert_equal [["echo", "1-x y"]], argvs
  end

  # --- status propagation ---------------------------------------------------

  def test_and_runs_the_next_command_only_after_success
    assert run_shell("true && echo yes")
    assert_equal [%w[true], %w[echo yes]], argvs
    refute run_shell("false && echo yes")
    assert_equal [%w[false]], argvs
  end

  def test_or_runs_the_next_command_only_after_failure
    assert run_shell("false || echo recovered")
    assert_equal [%w[false], %w[echo recovered]], argvs
  end

  def test_semicolon_always_runs_the_next_command_and_the_last_status_wins
    refute run_shell("true; false")
    assert_equal [%w[true], %w[false]], argvs
  end

  def test_a_status_carries_left_to_right_through_a_mixed_list
    assert run_shell("false && echo a || echo b")
    assert_equal [%w[false], %w[echo b]], argvs
  end

  def test_an_empty_line_succeeds
    assert run_shell("")
    assert_empty argvs
  end

  # --- what is still refused ------------------------------------------------

  def test_constructs_without_an_interpreter_are_refused
    {
      "pipeline" => "echo a | cat",
      "subshell" => "(echo a)",
      "backtick substitution" => "echo `pwd`",
      "dollar substitution" => 'echo "$(pwd)"',
      "case" => "case x in a) echo a;; esac",
      "while" => "while true; do echo a; done",
      "until" => "until false; do echo a; done",
      "negation" => "! false",
      "background" => "sleep 1 &",
      "function definition" => "f() { echo a; }",
      "word expansion modifier" => "echo ${x:-y}",
      "positional parameter" => "echo $1",
      "special parameter" => "echo $@",
      "pid parameter" => "echo $$",
      "unterminated quote" => 'echo "open'
    }.each do |name, text|
      assert_raises(Shell::UnsupportedSyntaxError, name) { run_shell(text) }
    end
  end

  def test_a_misplaced_keyword_is_a_syntax_error_not_a_command
    refusal("fi")
    refusal("done; echo a")
    refusal("echo a; }")
  end

  def test_an_unterminated_compound_command_is_refused
    refusal("for p in a; do echo $p")
    refusal("if true; then echo a")
    refusal("{ echo a")
  end

  def test_for_over_the_positional_parameters_is_refused
    # `for p; do ...` iterates over "$@", which this shell does not have.
    refusal("for p; do echo $p; done")
    refusal("for p do echo $p; done")
  end

  def test_a_redirection_on_a_compound_command_is_refused
    # `{ ...; } > f` needs the group's output redirected as a unit, which the
    # runner is not given a way to do.
    refusal("{ echo a; } > out")
  end

  def test_nothing_runs_when_the_line_does_not_parse
    # A shell rejects a line as a whole before executing any of it; so must
    # this one, or a half-run recipe would leave the tree in a state that
    # depends on where the parser gave up.
    error = assert_raises(Shell::UnsupportedSyntaxError) do
      run_shell("echo a; while true; do echo b; done")
    end
    assert_equal "shell reserved word 'while'", error.construct
    assert_empty argvs
  end

  def test_a_quoted_keyword_is_an_ordinary_command_name
    # Quoting takes a word's keyword-hood away (XCU 2.9), so this is a command
    # named `for`, not a loop — and the runner, not the parser, decides what
    # becomes of it.
    assert run_shell('"for" x')
    assert_equal [%w[for x]], argvs
  end

  def test_a_keyword_in_argument_position_is_a_plain_word
    assert run_shell("echo done fi }")
    assert_equal [%w[echo done fi }]], argvs
  end

  # --- the runner contract --------------------------------------------------

  def test_the_runner_receives_expanded_words_and_redirections
    run_shell("x=out; echo hi > $x")
    command = @commands.first
    assert_equal %w[echo hi], command.argv
    assert_equal 1, command.redirections.length
    assert_equal "out", command.redirections.first.path
  end

  def test_a_callable_runner_may_be_passed_instead_of_a_block
    seen = []
    shell = Shell.new(runner: ->(command) { seen << command.argv; true })
    assert shell.run("echo a; echo b")
    assert_equal [%w[echo a], %w[echo b]], seen
  end

  def test_variables_may_be_seeded_by_the_caller
    variables = { "top" => "/src" }
    run_shell("echo $top/x", variables: variables)
    assert_equal [%w[echo /src/x]], argvs
  end
  # --- the environment answers for names this line never set -----------------

  def test_a_name_the_line_never_set_comes_from_the_environment
    # sh expands $PATH from the environment, and so must this: the commands the
    # runner spawns see that same table, and one recipe cannot hold two answers
    # for one name.
    run_shell("echo $GREETING", environment: { "GREETING" => "hello" })
    assert_equal [%w[echo hello]], argvs
  end

  def test_an_assignment_in_the_line_shadows_the_environment
    run_shell("GREETING=bye; echo $GREETING", environment: { "GREETING" => "hello" })
    assert_equal [%w[echo bye]], argvs
  end

  def test_a_name_in_neither_expands_to_nothing
    # No `set -u` here either: the word disappears rather than raising, which is
    # why `echo $missing` is `echo` and not an error.
    run_shell("echo $MISSING", environment: { "OTHER" => "x" })
    assert_equal [%w[echo]], argvs
  end

  def test_an_environment_value_that_holds_blanks_still_splits_into_fields
    # The environment is not special: an unquoted expansion of it splits like
    # any other, and quoting it keeps one word.
    run_shell("touch $FILES", environment: { "FILES" => "a.txt  b.txt" })
    assert_equal [%w[touch a.txt b.txt]], argvs

    run_shell(%(touch "$FILES"), environment: { "FILES" => "a.txt  b.txt" })
    assert_equal [["touch", "a.txt  b.txt"]], argvs
  end
end
