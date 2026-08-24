# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

# The sibling commands that classify ARGV themselves: rmake and rubycc-ar.
# test_argv_encoding.rb pins the same property for the compiler driver; the
# failures here take the two shapes that family keeps producing.
#
#   1. Loud: an argument the locale cannot decode reaches a Regexp — rmake's
#      `case arg`, rubycc-ar's leading flag word — and raises ArgumentError
#      before anything is read. rmake's goals and `VAR=value` operands are
#      written by mkmf's Makefile and by `gem install` rather than typed.
#   2. Silent: re-tagging as bytes (lib/rubycc.rb) points the other way wherever
#      an argument then meets a string that is not bytes — a Makefile's rule
#      names, an archive's member names, a path completed against Dir.pwd.
#      Those neither compare equal nor join: a build plans nothing, or an
#      archive grows a second member instead of replacing the first.
#
# Everything runs as a child under `ruby -EUTF-8`, which pins ARGV's encoding
# without depending on which locales this host has installed.
class TestCliArgvEncoding < Minitest::Test
  RMAKE_PATH = File.expand_path("../exe/rmake", __dir__)
  AR_PATH    = File.expand_path("../exe/rubycc-ar", __dir__)
  LIB_DIR    = File.expand_path("../lib", __dir__)

  # 0xE9 is "e acute" in ISO-8859-1 and cannot appear in valid UTF-8: an
  # argument holding it is the reported defect. "日本" is the other case — valid
  # UTF-8, not ASCII — which never raised but stops comparing equal the moment
  # the two sides of a comparison are tagged differently.
  INVALID = "\xE9".b
  NON_ASCII = "日本".b

  # Every path here is built from byte pieces: this file's own literals are
  # UTF-8 and the marks above are bytes, which Ruby refuses to join for the same
  # reason the CLIs could not classify them.
  def join(*parts) = File.join(*parts.map(&:b))

  def spell(*parts) = parts.map(&:b).join

  def in_tmpdir(&block) = Dir.mktmpdir("rubycc-cli-argv", &block)

  def rmake(*argv, dir:)
    Open3.capture3(RbConfig.ruby, "-EUTF-8", "-I#{LIB_DIR}", RMAKE_PATH, *argv, chdir: dir)
  end

  def rubycc_ar(*argv, dir:)
    Open3.capture3(RbConfig.ruby, "-EUTF-8", "-I#{LIB_DIR}", AR_PATH, *argv, chdir: dir)
  end

  # The failure this whole file is about looks the same wherever it happens: a
  # Ruby backtrace on stderr instead of a build or a diagnostic.
  def refute_backtrace(stderr, context)
    refute_match(/\.rb:\d+:in /, stderr.b, "#{context}: a Ruby backtrace reached the user")
  end

  # A Makefile whose only rule is named `mark`, echoing a variable the command
  # line can override. The recipe is echoed by rmake before it runs, so both the
  # goal that was matched and the value that was substituted come back on
  # stdout.
  def write_makefile(dir, mark, name: "Makefile")
    File.binwrite(join(dir, name),
                  spell("V = fromfile\n\ngoal", mark, ":\n\techo [$(V)]\n"))
  end

  # --- rmake: arguments the locale cannot decode ------------------------------

  # The reported reproduction. A goal is matched against the Makefile's rule
  # names, so this asserts the rule actually ran rather than merely that nothing
  # raised — planning nothing is a silent exit 0.
  def test_a_goal_that_is_not_valid_utf8_runs_its_rule
    in_tmpdir do |dir|
      write_makefile(dir, INVALID)

      out, err, status = rmake(spell("goal", INVALID), dir: dir)

      refute_backtrace(err, "a goal that is not UTF-8")
      assert_equal 0, status.exitstatus, err
      assert_includes out.b, "[fromfile]".b
    end
  end

  # A `VAR=value` operand overrides the Makefile's own assignment, so its bytes
  # are seeded into the variable table and expanded into a recipe. They have to
  # arrive unchanged: re-tagging is not transcoding.
  def test_an_override_value_that_is_not_valid_utf8_reaches_the_recipe
    in_tmpdir do |dir|
      write_makefile(dir, INVALID)

      out, err, status = rmake("V=" + INVALID, spell("goal", INVALID), dir: dir)

      refute_backtrace(err, "a VAR=value operand that is not UTF-8")
      assert_equal 0, status.exitstatus, err
      assert_includes out.b, "[".b + INVALID + "]".b
    end
  end

  # -f in both spellings make accepts: the separated operand is taken from the
  # next slot, the joined "-fFILE" comes out of a capture group. The named file
  # exists, so a mis-spelled path shows up as "No such file" rather than passing.
  def test_a_makefile_name_that_is_not_valid_utf8_is_read
    in_tmpdir do |dir|
      name = spell("Mk", INVALID)
      write_makefile(dir, INVALID, name: name)

      [["-f", name], ["-f".b + name]].each do |flag|
        out, err, status = rmake(*flag, spell("goal", INVALID), dir: dir)

        refute_backtrace(err, "#{flag.length == 2 ? "separated" : "joined"} -f that is not UTF-8")
        assert_equal 0, status.exitstatus, err
        assert_includes out.b, "[fromfile]".b
      end
    end
  end

  # A -f naming a file that is not there is the diagnostic path, and the bytes
  # go back out in the message.
  def test_a_missing_makefile_that_is_not_valid_utf8_is_diagnosed
    in_tmpdir do |dir|
      name = spell("Mk", INVALID)

      _out, err, status = rmake("-f", name, dir: dir)

      refute_backtrace(err, "-f naming a missing file that is not UTF-8")
      assert_equal 2, status.exitstatus
      assert_equal "rmake: ".b + name + ": No such file\n".b, err.b
    end
  end

  # A bare -j takes its count from the next argument when that argument is a
  # number, which means the goal that follows one is matched against a Regexp of
  # its own — a second place in the same classification that could not read it.
  def test_a_goal_after_a_bare_j_that_is_not_valid_utf8_runs
    in_tmpdir do |dir|
      write_makefile(dir, INVALID)

      out, err, status = rmake("-j", spell("goal", INVALID), dir: dir)

      refute_backtrace(err, "a goal after a bare -j")
      assert_equal 0, status.exitstatus, err
      assert_includes out.b, "[fromfile]".b
    end
  end

  # An option rmake does not model is ignored rather than fatal, and that branch
  # is reached by a Regexp too.
  def test_an_unknown_option_that_is_not_valid_utf8_is_ignored
    in_tmpdir do |dir|
      write_makefile(dir, INVALID)

      out, err, status = rmake("-x".b + INVALID, spell("goal", INVALID), dir: dir)

      refute_backtrace(err, "an unknown option that is not UTF-8")
      assert_equal 0, status.exitstatus, err
      assert_includes out.b, "[fromfile]".b
    end
  end

  # --- rmake: arguments that were always valid: the other direction -----------

  # A goal spelled in Japanese is valid UTF-8, so it never raised. It is the
  # case re-tagging can break instead: the rule names it is matched against are
  # words of the Makefile, which the parser hands over as bytes, and a mismatch
  # plans no steps at all — no output, exit 0.
  def test_a_japanese_goal_matches_the_makefiles_spelling
    in_tmpdir do |dir|
      write_makefile(dir, NON_ASCII)

      out, err, status = rmake(spell("goal", NON_ASCII), dir: dir)

      refute_backtrace(err, "a Japanese goal")
      assert_equal 0, status.exitstatus, err
      assert_includes out.b, "[fromfile]".b
    end
  end

  # A relative -f is completed against the working directory, which comes from
  # the process rather than from the argument. This is the meeting point
  # re-tagging created: a byte operand and a Dir.pwd tagged with the locale do
  # not join at all once either of them holds a non-ASCII byte.
  def test_a_relative_makefile_resolves_under_a_non_ascii_working_directory
    [NON_ASCII, INVALID].each do |mark|
      in_tmpdir do |parent|
        work = join(parent, spell("作業", mark))
        Dir.mkdir(work)
        name = spell("Mk", mark)
        write_makefile(work, mark, name: name)

        out, err, status = rmake("-f", name, spell("goal", mark), dir: work)

        refute_backtrace(err, "a relative -f under a non-ASCII working directory")
        assert_equal 0, status.exitstatus, err
        assert_includes out.b, "[fromfile]".b
      end
    end
  end

  # rmake's CLI is also driven in process, with an array that belongs to the
  # caller. Re-tagging builds a new array rather than replacing the caller's
  # entries, so nothing the caller holds changes.
  def test_the_callers_argument_array_is_left_alone
    in_tmpdir do |dir|
      write_makefile(dir, NON_ASCII)
      # Tagged the way ARGV hands them over, which is what the CLI re-tags.
      argv = ["V=x", spell("goal", NON_ASCII)].map { |arg| arg.dup.force_encoding(Encoding::UTF_8) }
      before = argv.map { |arg| [arg.dup, arg.encoding] }

      code = Rubycc::Rmake::CLI.run(argv, dir: dir, out: StringIO.new, err: StringIO.new)

      assert_equal 0, code
      assert_equal before, argv.map { |arg| [arg, arg.encoding] }
    end
  end

  # --- rubycc-ar --------------------------------------------------------------

  # The leading flag word is stripped of an optional dash with String#sub, which
  # is where an operation letter the locale cannot decode raised. Neither
  # spelling names an operation, so both owe the usage error with the bytes
  # echoed back.
  def test_a_flag_word_that_is_not_valid_utf8_is_diagnosed
    in_tmpdir do |dir|
      flags = spell("z", INVALID)

      [flags, "-".b + flags].each do |word|
        _out, err, status = rubycc_ar(word, "lib.a", dir: dir)

        refute_backtrace(err, "a flag word that is not UTF-8")
        assert_equal 1, status.exitstatus
        assert_includes err.b, "unknown or missing operation in flags '".b + flags + "'".b
      end
    end
  end

  # An archive whose own name is not valid UTF-8, holding members whose names
  # are not either: the archive name is a path and nothing else, so its bytes
  # only have to reach the filesystem unchanged. The member names go further —
  # `t` prints them straight out of the reader, which is the one place the CLI
  # does not normalize them, and the reader spells a short name and a long one
  # differently. Both lengths are listed so that printing stays byte-for-byte
  # whatever the reader hands over.
  def test_an_archive_name_that_is_not_valid_utf8_is_written_and_listed
    in_tmpdir do |dir|
      archive = spell("lib", INVALID, ".a")
      short = spell("s", INVALID, ".o")
      long = spell("l" * 20, INVALID, ".o")
      ["a.o".b, short, long].each { |name| File.binwrite(join(dir, name), "first".b) }

      _out, err, status = rubycc_ar("rcs", archive, "a.o", short, long, dir: dir)
      refute_backtrace(err, "rcs with an archive name that is not UTF-8")
      assert_equal 0, status.exitstatus, err
      assert File.exist?(join(dir, archive)), "the archive should be written under the name given"

      out, err, status = rubycc_ar("t", archive, dir: dir)
      refute_backtrace(err, "t listing member names that are not UTF-8")
      assert_equal 0, status.exitstatus, err
      assert_equal ["a.o".b, short, long], out.b.split("\n".b)
    end
  end

  # `r` decides replace-or-append by looking a file's basename up among the
  # member names read out of the archive, so the two sides have to be tagged
  # alike. Both marks and both name lengths are tried: ArReader tags a long name
  # (one that does not fit the 16-byte inline field, so it lives in the `//`
  # table) UTF-8 and leaves a short one as bytes, so a command line tagged
  # either way matches only one of them. A mismatch is silent — the archive
  # simply grows a second member with the same name, and a linker reading it
  # would take the stale one.
  def test_replace_does_not_duplicate_a_member_whose_name_is_not_ascii
    [NON_ASCII, INVALID].each do |mark|
      ["m".b + mark + ".o".b, spell("a_member_name_past_the_inline_field", mark, ".o")].each do |name|
        in_tmpdir do |dir|
          File.binwrite(join(dir, name), "first".b)
          _out, err, status = rubycc_ar("rcs", "lib.a", name, dir: dir)
          assert_equal 0, status.exitstatus, err

          File.binwrite(join(dir, name), "second".b)
          _out, err, status = rubycc_ar("r", "lib.a", name, dir: dir)

          refute_backtrace(err, "r with a member name that is not ASCII")
          assert_equal 0, status.exitstatus, err
          members = Rubycc::ObjFile::ArReader.read_file(join(dir, "lib.a")).members.reject(&:special?)
          assert_equal [name], members.map { |m| m.name.b },
                       "#{name.inspect} should be replaced, not appended a second time"
          assert_equal "second".b, members.first.data
        end
      end
    end
  end

  # `x` selects the members to write by the same name comparison, and the same
  # mismatch is even quieter there: nothing is extracted and the exit status is
  # still 0.
  def test_extract_finds_a_member_whose_name_is_not_ascii
    [NON_ASCII, INVALID].each do |mark|
      ["m".b + mark + ".o".b, spell("a_member_name_past_the_inline_field", mark, ".o")].each do |name|
        in_tmpdir do |dir|
          File.binwrite(join(dir, name), "payload".b)
          File.binwrite(join(dir, "other.o"), "other".b)
          _out, err, status = rubycc_ar("rcs", "lib.a", name, "other.o", dir: dir)
          assert_equal 0, status.exitstatus, err

          # Extract into a fresh directory so the originals are not what is read.
          ext = join(dir, "ext")
          Dir.mkdir(ext)
          File.binwrite(join(ext, "lib.a"), File.binread(join(dir, "lib.a")))
          _out, err, status = rubycc_ar("x", "lib.a", name, dir: ext)

          refute_backtrace(err, "x naming a member that is not ASCII")
          assert_equal 0, status.exitstatus, err
          assert_equal "payload".b, File.binread(join(ext, name))
          refute File.exist?(join(ext, "other.o")), "only the named member should be extracted"
        end
      end
    end
  end
end
