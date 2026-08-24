# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/pkgconf/pkgconf"
require "rubycc/rmake/rmake"
require "rubycc/doctor"
require "open3"
require "tmpdir"

# C source is not the only text rubycc reads: a `.pc` file answers pkg-config, a
# Makefile drives a build, a Gemfile/Gemfile.lock tells the doctor what an
# application depends on, the shipped verified-gem database is consulted on every
# doctor run, and a GNU-ld linker script resolves `-l`. None of them is ASCII in
# practice, and File.read tagged what it returned with Encoding.default_external
# — US-ASCII where no locale is set (cron, systemd units, CI containers, images
# that ship no locale at all), which raises on the first byte past 0x7F.
#
# The fix is the one the C reader already took (docs/development/STEPS.md,
# default-external-encoding-1): read bytes, scan bytes. The rule that follows
# from it, and the reason both directions need testing, is in lib/rubycc.rb.
# Three groups —
#
#   1. end-to-end, with the locale variables removed from the child's
#      environment, which is the reported failure;
#   2. in-process, handing each parser a string tagged the way File.read would
#      have tagged it, which pins the parsers' own contract;
#   3. the other direction, which reading bytes introduced: a name that came out
#      of one of these files (bytes) meeting a string that came from the process
#      (ARGV, ENV, Dir.pwd, a directory listing).
class TestLocaleIndependentReads < Minitest::Test
  EXE_DIR = File.expand_path("../exe", __dir__)
  LIB_DIR = File.expand_path("../lib", __dir__)

  # The environment of a process that has no locale. nil unsets the variable for
  # the child rather than setting it to the empty string; either yields
  # Encoding.default_external == US-ASCII, and unsetting is the shape a stripped
  # container image actually has.
  NO_LOCALE = { "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil, "LANGUAGE" => nil }.freeze

  # An 18-byte ELF header naming a shared object (ET_DYN at e_type): exactly
  # what LibraryResolver#classify reads to decide a file's kind, so the linker
  # script tests need no compiler to produce a credible target.
  FAKE_SHARED_OBJECT = ("\x7FELF".b + ("\0".b * 12) + [3].pack("S<")).freeze

  def exe(name)
    File.join(EXE_DIR, name)
  end

  # Run +argv+ as a child with no locale at all. Returns [stdout, stderr, status].
  def without_locale(*argv, chdir: nil, env: {})
    opts = {}
    opts[:chdir] = chdir if chdir
    Open3.capture3(NO_LOCALE.merge(env), RbConfig.ruby, "-I#{LIB_DIR}", *argv, **opts)
  end

  # Run +argv+ as a child whose default_external is UTF-8, named explicitly so
  # the test does not depend on which locales this host happens to have
  # installed. This is the encoding a file name from ARGV or Dir.pwd carries.
  def under_utf8(*argv, chdir: nil)
    opts = {}
    opts[:chdir] = chdir if chdir
    Open3.capture3(RbConfig.ruby, "-EUTF-8", "-I#{LIB_DIR}", *argv, **opts)
  end

  def assert_clean(stderr, status, context)
    assert_empty stderr, "#{context}: stderr was not empty"
    assert_equal 0, status.exitstatus, "#{context}: #{stderr}"
  end

  # --- .pc files ---------------------------------------------------------------

  # A .pc whose Description holds U+00A9 and an accented name — the shape real
  # packages ship. Nothing outside the Description matters to --cflags/--libs,
  # which is the point: the bytes only have to be carried past.
  def write_pc(dir)
    File.binwrite(File.join(dir, "widget.pc"), <<~PC.b)
      prefix=/opt/widget
      libdir=${prefix}/lib
      Name: widget
      Description: Widget toolkit \xC2\xA9 2026 Herv\xC3\xA9
      Version: 3.1
      Cflags: -I${prefix}/include
      Libs: -L${libdir} -lwidget
    PC
  end

  def test_pc_file_with_a_non_ascii_description_resolves_without_a_locale
    Dir.mktmpdir("rubycc-pc") do |dir|
      write_pc(dir)

      stdout, stderr, status = without_locale(exe("rubycc-pkgconf"), "--cflags", "--libs", "widget",
                                              env: { "PKG_CONFIG_PATH" => dir })

      assert_clean(stderr, status, "--cflags --libs")
      assert_equal "-I/opt/widget/include -L/opt/widget/lib -lwidget", stdout.strip
    end
  end

  # --exists is the probe mkmf's pkg_config() makes first, and it loads the whole
  # file to answer, so it meets the same bytes.
  def test_pc_file_with_a_non_ascii_description_answers_exists_without_a_locale
    Dir.mktmpdir("rubycc-pc") do |dir|
      write_pc(dir)

      _stdout, stderr, status = without_locale(exe("rubycc-pkgconf"), "--exists", "widget",
                                               env: { "PKG_CONFIG_PATH" => dir })

      assert_clean(stderr, status, "--exists")
    end
  end

  # The parser's own contract: what File.read hands over under a locale of "C"
  # is the file's bytes tagged US-ASCII, and therefore invalid. Re-tagging rather
  # than transcoding means the field survives whatever the caller's encoding was.
  def test_pkgconf_parser_accepts_text_tagged_by_the_locale
    text = "Name: widget\nDescription: \xC2\xA9\nCflags: -Iinc\n".b.force_encoding(Encoding::US_ASCII)
    package = Rubycc::Pkgconf::Parser.parse(text, path: "widget.pc")

    assert_equal "\xC2\xA9".b, package.description
    assert_equal Encoding::BINARY, package.description.encoding
    assert_equal "-Iinc", package.cflags
  end

  # --- Gemfile / Gemfile.lock --------------------------------------------------

  # json 2.21.1 is in the shipped verified-gem database, so the doctor answers
  # this Gemfile offline: no network, no build, and a verdict of ADOPTABLE. That
  # keeps the test about the read rather than about what a build would do.
  def test_gemfile_with_utf8_comments_is_read_without_a_locale
    Dir.mktmpdir("rubycc-doctor") do |dir|
      File.binwrite(File.join(dir, "Gemfile"), <<~'GEMFILE'.b)
        # 日本語のコメント: このアプリの依存関係
        source "https://rubygems.org"

        gem "json", "2.21.1"   # JSON パーサ — 標準添付
      GEMFILE

      stdout, stderr, status = without_locale(exe("rubycc-doctor"), "--max-builds", "0", chdir: dir)

      assert_clean(stderr, status, "rubycc-doctor on a Gemfile")
      assert_includes stdout, "json 2.21.1"
      assert_includes stdout, "ADOPTABLE"
    end
  end

  # The lock file is preferred over the Gemfile and has its own parser, so it
  # needs its own coverage. A `path:` source pointing at a directory named
  # outside ASCII is where a lock file's non-ASCII actually comes from.
  def test_gemfile_lock_with_a_non_ascii_path_source_is_read_without_a_locale
    Dir.mktmpdir("rubycc-doctor") do |dir|
      File.binwrite(File.join(dir, "Gemfile"), "source \"https://rubygems.org\"\n".b)
      File.binwrite(File.join(dir, "Gemfile.lock"), <<~'LOCK'.b)
        PATH
          remote: vendor/日本語ライブラリ
          specs:
            widget (1.0.0)

        GEM
          remote: https://rubygems.org/
          specs:
            json (2.21.1)

        PLATFORMS
          ruby

        DEPENDENCIES
          json
          widget!
      LOCK

      stdout, stderr, status = without_locale(exe("rubycc-doctor"), "--max-builds", "0", chdir: dir)

      assert_clean(stderr, status, "rubycc-doctor on a Gemfile.lock")
      assert_includes stdout, "json 2.21.1"
      assert_includes stdout, "widget 1.0.0"
      assert_includes stdout, "ADOPTABLE"
    end
  end

  # The database rubycc ships is itself one of these files, and it is read on
  # every doctor run before the user's project is looked at: its notes contain
  # typographic punctuation, so without a locale the doctor died in JSON.parse
  # no matter what the project's Gemfile said. JSON is UTF-8 by definition
  # (RFC 8259 8.1), so this one names its encoding rather than reading bytes.
  def test_the_verified_gem_database_loads_without_a_locale
    script = <<~'RUBY'
      require "rubycc/doctor"
      db = Rubycc::Doctor::VerifiedGems.load
      puts db.records.size
    RUBY

    stdout, stderr, status = without_locale("-e", script)

    assert_clean(stderr, status, "VerifiedGems.load")
    assert_operator stdout.to_i, :>, 0
  end

  def test_gemfile_parsers_accept_text_tagged_by_the_locale
    gemfile = "# \xE6\x97\xA5\nsource \"x\"\ngem \"json\", \"2.7\"\n".b.force_encoding(Encoding::US_ASCII)
    lock = "PATH\n  remote: \xE6\x97\xA5\n  specs:\n    widget (1.0.0)\n".b.force_encoding(Encoding::US_ASCII)

    from_gemfile = Rubycc::Doctor::Gemfile.parse_gemfile(gemfile)
    from_lock = Rubycc::Doctor::Gemfile.parse_lock(lock)

    assert_equal ["json"], from_gemfile.entries.map(&:name)
    assert_equal ["2.7"], from_gemfile.entries.map(&:version)
    assert_equal ["widget"], from_lock.entries.map(&:name)
  end

  # --- Makefile ----------------------------------------------------------------

  # A Makefile that comments in the author's own language, continues a line
  # holding non-ASCII, and echoes a non-ASCII word from a recipe. Tool
  # substitution is always on, so `CC = gcc` is built by rubycc in-process and
  # the test needs no external compiler.
  def write_makefile_project(dir)
    File.binwrite(File.join(dir, "widget.c"), "int widget(void) { return 7; }\n".b)
    File.binwrite(File.join(dir, "Makefile"), <<~'MAKEFILE'.b)
      # 日本語のコメント — このターゲットをビルドする
      CC = gcc
      CFLAGS = -O0 \
               -DGREETING="こんにちは"

      all: widget.o
      	@echo built ✓

      widget.o: widget.c
      	$(CC) $(CFLAGS) -c widget.c -o widget.o
    MAKEFILE
  end

  def test_makefile_with_utf8_comments_builds_without_a_locale
    Dir.mktmpdir("rubycc-rmake") do |dir|
      write_makefile_project(dir)

      stdout, stderr, status = without_locale(exe("rmake"), chdir: dir)

      assert_clean(stderr, status, "rmake")
      assert_equal "\x7FELF".b, File.binread(File.join(dir, "widget.o"), 4)
      # The continued line's bytes reach the recipe, and the recipe's own
      # non-ASCII reaches the terminal, both unchanged.
      assert_includes stdout.b, '-DGREETING="こんにちは"'.b
      assert_includes stdout.b, "built ✓".b
    end
  end

  def test_makefile_parser_accepts_text_tagged_by_the_locale
    text = "# \xE6\x97\xA5\nCC = gcc\nall:\n\t@echo hi\n".b.force_encoding(Encoding::US_ASCII)
    mk = Rubycc::Rmake::Makefile.parse(text, dir: ".")

    assert_equal "all", mk.default_goal
    assert_equal "gcc", mk.variables["CC"].value
  end

  # --- linker scripts ----------------------------------------------------------

  # glibc ships libc.so as a text linker script; anything that is neither ELF nor
  # `ar` is read as one. This one carries the comment such a file carries.
  def write_linker_script(dir, target_name: "libwidget.so.1")
    File.binwrite(File.join(dir, target_name), FAKE_SHARED_OBJECT)
    File.binwrite(File.join(dir, "libwidget.so"),
                  "/* GNU ld script \xC2\xA9 2026 Herv\xC3\xA9 */\nGROUP ( #{target_name} )\n".b)
  end

  # Resolve `-l<ARGV[1]>` against the single search directory ARGV[0] and print
  # what was found, one path per line.
  RESOLVE_SCRIPT = <<~'RUBY'
    require "rubycc"
    r = Rubycc::Link::LibraryResolver.resolve([ARGV[1]], search_dirs: [ARGV[0]])
    r.needed.each { |p| $stdout.write(p.b, "\n") }
  RUBY

  def test_linker_script_with_a_non_ascii_comment_resolves_without_a_locale
    Dir.mktmpdir("rubycc-link") do |dir|
      write_linker_script(dir)

      stdout, stderr, status = without_locale("-e", RESOLVE_SCRIPT, dir, "widget")

      assert_clean(stderr, status, "LibraryResolver.resolve")
      assert_equal File.join(dir, "libwidget.so.1").b, stdout.b.chomp
    end
  end

  def test_linker_script_reader_accepts_text_tagged_by_the_locale
    text = "/* \xC2\xA9 */ GROUP ( libwidget.so.1 -lm )\n".b.force_encoding(Encoding::US_ASCII)

    assert_equal ["libwidget.so.1", "-lm"], Rubycc::Link::LinkerScript.parse(text)
  end

  # --- the other direction: bytes meeting the locale ---------------------------
  #
  # These pass on the unmodified tree — they are not the reported defect. They
  # are here because reading bytes introduced their failure: a name that came out
  # of one of these files is now a byte string, and the strings it meets come
  # from the process. Under a non-ASCII spelling the two never join, never
  # compare equal and never hash alike (lib/rubycc.rb), so each of these covers
  # one meeting point that reading bytes had to repair.

  def test_linker_script_names_a_file_outside_ascii_under_a_utf8_locale
    Dir.mktmpdir("rubycc-link") do |dir|
      # The *directory* has to be outside ASCII too: a byte-string file name
      # joined onto an ASCII directory is compatible, so both halves are needed
      # to reach the incompatibility.
      libdir = File.join(dir, "ライブラリ")
      Dir.mkdir(libdir)
      write_linker_script(libdir, target_name: "libウィジェット.so.1")

      stdout, stderr, status = under_utf8("-e", RESOLVE_SCRIPT, libdir, "widget")

      assert_clean(stderr, status, "LibraryResolver.resolve under UTF-8")
      assert_equal File.join(libdir, "libウィジェット.so.1").b, stdout.b.chomp
    end
  end

  # The `-l` name itself comes from the command line, and only the versioned form
  # of the library is present, so the search has to read the directory
  # (LibraryResolver#directory_entries) and match its entries against a prefix
  # composed from that name. Three process-side spellings meet the search path
  # here — the `-L` directory, the `-l` name and the directory listing — and none
  # of them reaches the file unless all three are spelled the same way.
  def test_a_versioned_shared_object_outside_ascii_resolves_from_a_dash_l_name
    Dir.mktmpdir("rubycc-link") do |dir|
      libdir = File.join(dir, "ライブラリ")
      Dir.mkdir(libdir)
      File.binwrite(File.join(libdir, "libウィジェット.so.1"), FAKE_SHARED_OBJECT)

      stdout, stderr, status = under_utf8("-e", RESOLVE_SCRIPT, libdir, "ウィジェット")

      assert_clean(stderr, status, "LibraryResolver.resolve of -lウィジェット under UTF-8")
      assert_equal File.join(libdir, "libウィジェット.so.1").b, stdout.b.chomp
    end
  end

  def test_makefile_names_a_file_outside_ascii_under_a_utf8_locale
    Dir.mktmpdir("rubycc-rmake") do |dir|
      work = File.join(dir, "作業")
      Dir.mkdir(work)
      File.binwrite(File.join(work, "部品.c"), "int part(void) { return 1; }\n".b)
      File.binwrite(File.join(work, "Makefile"), <<~'MAKEFILE'.b)
        all: 部品.o
        	cp 部品.o 控え.o

        部品.o: 部品.c
        	gcc -c 部品.c -o 部品.o
      MAKEFILE

      _stdout, stderr, status = under_utf8(exe("rmake"), chdir: work)

      assert_clean(stderr, status, "rmake under UTF-8")
      assert_equal "\x7FELF".b, File.binread(File.join(work, "部品.o"), 4)
      # `cp` is one of rmake's built-in recipe commands, and it resolves its
      # operands against the working directory — the second place the two
      # spellings meet.
      assert_path_exists File.join(work, "控え.o")
    end
  end

  # A `VAR=value` operand is the third place the two spellings meet: RubyGems
  # drives rmake with `sitearchdir=<tmp>` operands, so the value comes off the
  # command line in the locale's encoding and is then expanded into the
  # Makefile's own (byte) text.
  def test_a_command_line_override_outside_ascii_expands_into_a_makefile
    Dir.mktmpdir("rubycc-rmake") do |dir|
      File.binwrite(File.join(dir, "Makefile"), <<~'MAKEFILE'.b)
        # コメント
        DEST = /tmp/既定
        all:
        	@echo $(DEST)/成果
      MAKEFILE

      stdout, stderr, status = under_utf8(exe("rmake"), "DEST=/tmp/上書き", chdir: dir)

      assert_clean(stderr, status, "rmake with an override under UTF-8")
      assert_includes stdout.b, "/tmp/上書き/成果".b
    end
  end

  # A goal named on the command line has to find its rule, and the rule names are
  # words of the Makefile. This is the meeting point where nothing raises: the
  # lookup simply misses, so rmake plans no step, prints nothing and exits 0 —
  # the goal is silently not built.
  def test_a_command_line_goal_outside_ascii_selects_its_rule
    Dir.mktmpdir("rubycc-rmake") do |dir|
      File.binwrite(File.join(dir, "Makefile"), <<~'MAKEFILE'.b)
        all:
        	@echo 既定の目標

        別の目標:
        	@echo 名指しの目標
      MAKEFILE

      stdout, stderr, status = under_utf8(exe("rmake"), "別の目標", chdir: dir)

      assert_clean(stderr, status, "rmake with a named goal under UTF-8")
      assert_includes stdout.b, "名指しの目標".b
      refute_includes stdout.b, "既定の目標".b
    end
  end

  # pkg-config's system-directory lists come from the environment, while the
  # `-I`/`-L` they are compared against come from a .pc file. This meeting point
  # is an equality test rather than a join, so a mismatch is silent too: the flag
  # the environment asked to suppress is emitted instead.
  def test_a_system_directory_named_outside_ascii_suppresses_a_pc_files_flag
    env = { "PKG_CONFIG_SYSTEM_INCLUDE_PATH" => "/opt/含める",
            "PKG_CONFIG_SYSTEM_LIBRARY_PATH" => "/opt/ライブラリ" }
    filter = Rubycc::Pkgconf::SystemPathFilter.new(env)

    assert_equal ["-DWIDGET=1".b], filter.cflags(["-I/opt/含める".b, "-DWIDGET=1".b])
    assert_equal ["-lwidget".b], filter.libs(["-L/opt/ライブラリ".b, "-lwidget".b])
  end
end
