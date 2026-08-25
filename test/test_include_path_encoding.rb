# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

# @include_paths (lib/rubycc/preprocess/preprocessor.rb) mixes two origins: the
# caller's -I, which arrives as bytes (lib/rubycc.rb), and the bundled/libc
# directories, which are built from __dir__ and so carry whatever encoding the
# process itself has -- UTF-8 when rubycc sits under a non-ASCII path. Both meet
# a header name, itself bytes (default-external-encoding-1), in File.join: at
# the end of the search (#search_include_paths) and in __has_include's lookup
# (#include_exists?). A UTF-8-tagged directory and a byte header name, both
# holding non-ASCII, made that join raise Encoding::CompatibilityError instead
# of resolving or reporting "not found".
#
# Two levels are covered. The reported trigger is rubycc's own tree sitting
# under a non-ASCII path, which the last two tests arrange for real by copying
# it there; the rest reproduce the same join through Preprocessor#run's
# include_paths: argument, which is the same shape a directory at a time.
class TestIncludePathEncoding < Minitest::Test
  # 0xE9 is "e acute" in ISO-8859-1 and cannot appear in valid UTF-8: a header
  # name built from it is not valid text in any encoding. "日本" is valid UTF-8
  # that is not ASCII -- the case that never raised on its own, only once it
  # meets a differently tagged operand.
  INVALID = "\xE9".b
  NON_ASCII = "日本".b
  MARKS = [NON_ASCII, INVALID].freeze

  REPO_ROOT = File.expand_path("..", __dir__)

  def preprocess(source, include_paths:)
    Rubycc::Preprocess::Preprocessor.new
                                    .run(source, filename: "main.c",
                                                 include_paths: include_paths,
                                                 system_includes: false)
  end

  # A subdirectory named with non-ASCII bytes, spelled as a UTF-8 literal and
  # left untouched, so it keeps the tag a process-derived string (__dir__,
  # Dir.pwd) actually has. The tmpdir root is ASCII, so this join never crosses
  # the encodings under test; only the header name below does.
  def non_ascii_search_dir(root)
    dir = File.join(root, "日本")
    Dir.mkdir(dir)
    dir
  end

  # Writes `content` at `dir`/`name` without joining a UTF-8-tagged dir to a byte
  # name -- the setup has to avoid the very mismatch under test.
  def write_under(dir, name, content)
    File.binwrite(dir.b + "/".b + name, content.b)
  end

  # --- the search path, one directory at a time -------------------------------

  def test_a_header_under_a_non_ascii_search_directory_resolves
    MARKS.each do |mark|
      Dir.mktmpdir("rubycc-include-encoding") do |root|
        dir = non_ascii_search_dir(root)
        name = "h".b + mark + ".h".b
        write_under(dir, name, "int VALUE_OK;\n")
        source = "#include \"".b + name + "\"\nint x = VALUE_OK;\n".b

        tokens = preprocess(source, include_paths: [dir])

        assert_includes tokens.map(&:value), "VALUE_OK"
      end
    end
  end

  def test_a_missing_header_under_a_non_ascii_search_directory_is_diagnosed
    MARKS.each do |mark|
      Dir.mktmpdir("rubycc-include-encoding") do |root|
        dir = non_ascii_search_dir(root)
        source = "#include \"".b + "gone".b + mark + ".h".b + "\"\n".b

        error = assert_raises(Rubycc::CompileError) do
          preprocess(source, include_paths: [dir])
        end

        assert_match(/No such file or directory/, error.description)
      end
    end
  end

  # __has_include answers without reading the file, through a lookup of its own
  # (#include_exists?) that joins the same two operands.
  def test_has_include_under_a_non_ascii_search_directory
    MARKS.each do |mark|
      Dir.mktmpdir("rubycc-include-encoding") do |root|
        dir = non_ascii_search_dir(root)
        present = "hi".b + mark + ".h".b
        write_under(dir, present, "")
        absent = "gone".b + mark + ".h".b

        [[present, "yes"], [absent, "no"]].each do |name, expected|
          source = "#if __has_include(\"".b + name + "\")\nint yes;\n#else\nint no;\n#endif\n".b
          tokens = preprocess(source, include_paths: [dir]).reject(&:eof?)

          assert_equal ["int", expected, ";"], tokens.map(&:value)
        end
      end
    end
  end

  # Whichever origin a directory came from, the search walks bytes. This is what
  # the two tests above cannot see: they pass their directory in, while the
  # bundled and libc ones are derived inside.
  def test_every_search_directory_is_bytes_including_the_bundled_ones
    preprocessor = Rubycc::Preprocess::Preprocessor.new
    preprocessor.run("int x;\n".b, filename: "main.c", include_paths: ["/tmp/日本"])
    paths = preprocessor.instance_variable_get(:@include_paths)

    refute_empty paths.drop(1), "the bundled and libc directories should be searched"
    not_bytes = paths.reject { |path| path.encoding == Encoding::BINARY }
    assert_empty not_bytes, "these search directories are not bytes: #{not_bytes.inspect}"
  end

  # --- the reported trigger: rubycc's own tree under a non-ASCII path ----------

  # Puts a working rubycc under a non-ASCII directory, so the bundled include
  # directory it derives from __dir__ is non-ASCII too. Copying is what makes it
  # move: __dir__ resolves symlinks, so a link would report the original path and
  # test nothing. lib/, include/ and exe/ are 2.3 MB between them.
  def relocate(root)
    home = File.join(root, "日本")
    Dir.mkdir(home)
    %w[lib include exe].each { |dir| FileUtils.cp_r(File.join(REPO_ROOT, dir), home) }
    home
  end

  def rubycc(home, *argv, dir:)
    Open3.capture3(RbConfig.ruby, "-EUTF-8", "-I#{home}/lib", "#{home}/exe/rubycc", *argv,
                   chdir: dir)
  end

  # A header that only the bundled directory holds, named with non-ASCII bytes:
  # the search reaches it only after the caller's -I are exhausted, which is the
  # join this step is about.
  def test_a_bundled_header_resolves_when_rubycc_sits_under_a_non_ascii_path
    Dir.mktmpdir("rubycc-relocated") do |root|
      home = relocate(root)
      header = "h".b + NON_ASCII + ".h".b
      File.binwrite(File.join(home, "include").b + "/".b + header, "int VALUE_OK;\n".b)
      File.binwrite(File.join(root, "s.c"),
                    "#include <".b + header + ">\nint main(void){ return VALUE_OK; }\n".b)

      _out, err, status = rubycc(home, "-c", "s.c", "-o", "s.o", dir: root)

      refute_match(/\.rb:\d+:in /, err.b, "a Ruby backtrace reached the user")
      assert_equal 0, status.exitstatus, err
      assert_equal "\x7FELF".b, File.binread(File.join(root, "s.o"), 4)
    end
  end

  # The reported reproduction. Nothing holds this header, so the search walks
  # every directory including the bundled ones and comes back empty -- which is
  # a diagnostic, and used to be a Ruby backtrace from File.join. A misspelling
  # is enough to reach it.
  def test_a_missing_header_is_diagnosed_when_rubycc_sits_under_a_non_ascii_path
    Dir.mktmpdir("rubycc-relocated") do |root|
      home = relocate(root)
      MARKS.each_with_index do |mark, index|
        name = "gone".b + mark + ".h".b
        source = "s#{index}.c"
        File.binwrite(File.join(root, source), "#include \"".b + name + "\"\n".b)

        _out, err, status = rubycc(home, "-c", source, "-o", "out.o", dir: root)

        refute_match(/\.rb:\d+:in /, err.b, "a Ruby backtrace reached the user")
        assert_equal 1, status.exitstatus
        assert_includes err.b, name + ": No such file or directory".b
      end
    end
  end
end
