# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rubycc/command_line"

# Step mkmf-shell-free-conftest-1: the word splitter rmake and the mkmf shim
# share (lib/rubycc/command_line.rb). The recipe-level behaviour (connectors,
# redirections, builtins) is covered by test_rmake_executor.rb; what is tested
# here is the shared entry point the shim uses, CommandLine.argv, which accepts
# exactly one plain command and refuses everything a shell would have to
# interpret. The refusal matters as much as the split: a shell-less environment
# must fail loudly rather than quietly do something else.
class TestCommandLine < Minitest::Test
  def test_splits_a_plain_command_into_argv
    assert_equal ["gcc", "-o", "conftest", "conftest.c"],
                 Rubycc::CommandLine.argv("gcc -o conftest  conftest.c")
  end

  def test_quote_removal_matches_bin_sh
    # The shape mkmf writes for a define whose value is a C string literal.
    command = 'gcc -DSYSCONFDIR=\"/etc\" -DNAME="two words" -c a.c'
    words = Rubycc::CommandLine.argv(command)
    assert_equal ["gcc", '-DSYSCONFDIR="/etc"', "-DNAME=two words", "-c", "a.c"], words

    skip "/bin/sh is not available" unless File.executable?("/bin/sh")

    sh_command = command.sub(/\Agcc/, %q(printf '%s\n'))
    out, _err, status = Open3.capture3("/bin/sh", "-c", sh_command)
    assert status.success?
    assert_equal words.drop(1), out.lines.map(&:chomp)
  end

  def test_a_single_word_command_is_one_element
    assert_equal ["./conftest"], Rubycc::CommandLine.argv("./conftest")
  end

  def test_refuses_what_only_a_shell_could_run
    {
      "gcc a.c | tee log" => "pipe '|'",
      "gcc a.c && gcc b.c" => "command connector '&&'",
      "gcc a.c || true" => "command connector '||'",
      "gcc a.c ; gcc b.c" => "command connector ';'",
      "gcc a.c > out" => "redirection",
      "gcc a.c 2> err" => "redirection",
      "gcc a.c &" => "background '&'",
      "gcc `cat flags`" => "shell metacharacter '`'",
      "gcc $(cat flags)" => "shell metacharacter '('",
      "gcc < in" => "shell metacharacter '<'",
      "gcc 'unterminated" => "unterminated quote",
      "CFLAGS=-O2 gcc a.c" => "environment assignment 'CFLAGS=-O2'",
      "" => "empty command"
    }.each do |command, construct|
      error = assert_raises(Rubycc::CommandLine::UnsupportedSyntaxError, command) do
        Rubycc::CommandLine.argv(command)
      end
      assert_equal construct, error.construct, command
      assert_includes error.message, command.inspect
    end
  end
end
