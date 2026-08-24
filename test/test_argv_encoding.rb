# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "stringio"
require "tmpdir"

# The command line is the third way text reaches rubycc, after the C it compiles
# and the .pc/Makefile/Gemfile it reads, and it is the one the process hands over
# already tagged: ARGV carries Encoding.default_external, which is the locale.
# Two things follow, and this file pins both.
#
#   1. An argument the locale's encoding cannot decode — a file name written
#      under a different locale, an archive unpacked with mangled names — made
#      the driver's `case arg` classification raise ArgumentError from the first
#      Regexp#=== it reached, before a byte of the file was read. The user saw a
#      Ruby backtrace with no hint of which argument caused it.
#   2. Re-tagging those arguments as bytes (lib/rubycc.rb) is what removes that,
#      but it points the other way at every place an argument later meets a
#      string that is *not* bytes: a path spliced onto Dir.pwd, a name used as a
#      Hash key, a spelling compared with ==. Under a non-ASCII argument those
#      neither join nor compare equal, so the second group of tests below is
#      about arguments that were always valid and must keep working.
#
# Both groups run the driver as a child under `ruby -EUTF-8`, which pins ARGV's
# encoding without depending on which locales this host has installed.
class TestArgvEncoding < Minitest::Test
  EXE_PATH = File.expand_path("../exe/rubycc", __dir__)
  LIB_DIR  = File.expand_path("../lib", __dir__)

  Reader = Rubycc::ObjFile::ELFReader

  # 0xE9 is "e acute" in ISO-8859-1 and cannot appear in valid UTF-8: an
  # argument holding it is the reported defect. "日本" is the other case — valid
  # UTF-8, not ASCII — which never raised but stops comparing equal the moment
  # the two sides of a comparison are tagged differently.
  INVALID = "\xE9".b
  NON_ASCII = "日本".b

  # Every path in this file is built from byte pieces: the test's own literals
  # are UTF-8 and the marks above are bytes, which Ruby refuses to join for the
  # same reason the driver could not classify them.
  def join(*parts)
    File.join(*parts.map(&:b))
  end

  # The same for a single name assembled from several pieces, where the pieces
  # are not path components (a UTF-8 literal and a mark do not concatenate).
  def spell(*parts) = parts.map(&:b).join

  # Run the driver exe with ARGV tagged UTF-8, whatever the host's locale is.
  def rubycc(*argv, dir:)
    Open3.capture3(RbConfig.ruby, "-EUTF-8", "-I#{LIB_DIR}", EXE_PATH, *argv, chdir: dir)
  end

  # The failure this whole file is about looks the same wherever it happens: a
  # Ruby backtrace on stderr instead of a compile or a diagnostic.
  def refute_backtrace(stderr, context)
    refute_match(/\.rb:\d+:in /, stderr.b, "#{context}: a Ruby backtrace reached the user")
  end

  def assert_compiled(object, stderr, status, context)
    refute_backtrace(stderr, context)
    assert_equal 0, status.exitstatus, "#{context}: #{stderr}"
    assert_equal "\x7FELF".b, File.binread(object, 4)
  end

  # A source, a header it includes, and the directory the header sits in, all
  # named with `mark` so every argument under test carries the same bytes.
  def write_project(dir, mark)
    include_dir = join(dir, "inc#{mark}")
    Dir.mkdir(include_dir) unless File.directory?(include_dir)
    File.binwrite(join(include_dir, "h#{mark}.h"), "#define VALUE 0\n".b)
    source = join(dir, "s#{mark}.c")
    File.binwrite(source, "#include \"h".b + mark + ".h\"\nint main(void){ return VALUE; }\n".b)
    [source, include_dir]
  end

  def in_tmpdir(&block) = Dir.mktmpdir("rubycc-argv", &block)

  # --- arguments the locale cannot decode (the reported defect) ---------------

  # The reported reproduction: a file name holding a byte that is not valid
  # UTF-8, compiled under a UTF-8 locale. It never reached the file.
  def test_a_file_name_that_is_not_valid_utf8_compiles
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, INVALID)
      object = join(dir, "out.o")

      _out, err, status = rubycc("-c", source, "-I".b + include_dir, "-o", object, dir: dir)

      assert_compiled(object, err, status, "-c with a file name that is not UTF-8")
    end
  end

  # -I in both spellings gcc accepts: the joined "-Idir" reaches the regexp
  # branch, the separated "-I dir" reaches the operand branch, and the directory
  # has to actually be searched — a header that is not found is a diagnostic, so
  # a silently mis-spelled path would show up here rather than pass.
  def test_an_include_directory_that_is_not_valid_utf8_is_searched
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, INVALID)

      [["-I".b + include_dir], ["-I", include_dir]].each_with_index do |flag, index|
        object = join(dir, "out#{index}.o")
        _out, err, status = rubycc("-c", source, *flag, "-o", object, dir: dir)

        assert_compiled(object, err, status, "-I #{index.zero? ? "joined" : "separated"}")
      end
    end
  end

  # A -D operand is turned into a #define directive and scanned, so its bytes
  # travel through the preprocessor rather than merely being classified. They
  # must arrive unchanged: the object is compared against the one the same
  # #define written in the source produces, which no transcoding could match.
  def test_a_macro_value_that_is_not_valid_utf8_reaches_the_source_unchanged
    in_tmpdir do |dir|
      source = join(dir, "greeting.c")
      literal = "\"caf".b + INVALID + "\"".b
      File.binwrite(source, "#ifndef GREETING\n#define GREETING ".b + literal +
                            "\n#endif\nconst char *greeting = GREETING;\n".b)
      object = join(dir, "greeting.o")

      _out, err, status = rubycc("-c", source, "-o", object, dir: dir)
      assert_compiled(object, err, status, "the in-source spelling")
      from_source = File.binread(object)

      _out, err, status = rubycc("-c", source, "-DGREETING=".b + literal, "-o", object, dir: dir)
      assert_compiled(object, err, status, "-D with a value that is not UTF-8")

      assert_equal from_source, File.binread(object)
    end
  end

  # A -U operand is a macro name and nothing else, so bytes the locale cannot
  # decode do not spell one: the answer is a diagnostic, which is what the
  # driver owes and what it could not reach before. The operand is turned into
  # an #undef directive and scanned like any other, so the report names
  # <command-line> and echoes the bytes back. Both spellings gcc accepts pass
  # through separate branches of the classification.
  def test_an_undef_operand_that_is_not_valid_utf8_is_diagnosed
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, INVALID)
      name = spell("VALUE", INVALID)

      [["-U".b + name], ["-U", name]].each do |flag|
        _out, err, status = rubycc("-c", source, "-I".b + include_dir, *flag,
                                   "-o", join(dir, "out.o"), dir: dir)

        refute_backtrace(err, "-U with an operand that is not UTF-8")
        assert_equal 1, status.exitstatus
        assert_includes err.b, "<command-line>:1:".b
        assert_includes err.b, "#undef ".b + name
      end
    end
  end

  # -o names the file to create, so the bytes have to survive as far as the
  # filesystem call rather than only past the classification.
  def test_an_output_path_that_is_not_valid_utf8_is_written
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, INVALID)
      object = join(dir, "out#{INVALID}.o")

      _out, err, status = rubycc("-c", source, "-I".b + include_dir, "-o", object, dir: dir)

      assert_compiled(object, err, status, "-o with a path that is not UTF-8")
    end
  end

  # -l and -L are resolved by LibraryResolver, which composes "lib<name>.so" and
  # joins it onto each search directory. The library does not exist, so what is
  # asserted is the diagnostic: rubycc's own message, carrying the requested
  # bytes back verbatim, and not a backtrace.
  def test_a_library_request_that_is_not_valid_utf8_is_diagnosed
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, INVALID)

      _out, err, status = rubycc("-o", join(dir, "prog"), source, "-I".b + include_dir,
                                 "-L".b + dir.b, "-l".b + INVALID, dir: dir)

      refute_backtrace(err, "-l with a name that is not UTF-8")
      assert_equal 1, status.exitstatus
      assert_equal "rubycc: error: cannot find -l".b + INVALID + "\n".b, err.b
    end
  end

  # -target is the argument the crash was first seen on: the regexp branch for
  # "-target=CPU" is the driver's first Regexp#===. Neither spelling names a
  # backend, so both must reach the driver's own "unsupported target" error with
  # the requested bytes spliced into it.
  def test_a_target_that_is_not_valid_utf8_is_diagnosed
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, INVALID)
      expected = "rubycc: error: unsupported target '".b + INVALID + "'\n".b

      [["-target=".b + INVALID], ["-target", INVALID]].each do |flag|
        _out, err, status = rubycc("-c", source, "-I".b + include_dir, *flag,
                                   "-o", join(dir, "out.o"), dir: dir)

        refute_backtrace(err, "#{flag.first} that is not UTF-8")
        assert_equal 1, status.exitstatus
        assert_equal expected, err.b
      end
    end
  end

  # A -Wl, passthrough is split on commas and its -soname operand is written
  # into the shared object's .dynstr, so these bytes end up inside an artifact
  # rather than in a message. Both spellings of the option carry them.
  def test_a_soname_that_is_not_valid_utf8_reaches_the_shared_object
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, INVALID)
      soname = "lib".b + INVALID + ".so.1".b

      [["-Wl,-soname,".b + soname], ["-Wl,-soname=".b + soname]].each_with_index do |flag, index|
        object = join(dir, "lib#{index}.so")
        _out, err, status = rubycc("-shared", "-fPIC", source, "-I".b + include_dir,
                                   *flag, "-o", object, dir: dir)

        assert_compiled(object, err, status, "-Wl,-soname with a name that is not UTF-8")
        assert_equal soname, Reader.read_file(object).soname.b
      end
    end
  end

  # -E is the driver's own reader: it re-spells the token stream into a byte
  # buffer of its own, and __FILE__ expands to a string literal spelled with the
  # name this driver was handed rather than with anything the scanner read. A
  # source that also holds raw bytes puts both in that buffer, which is the
  # concatenation Ruby refuses when their tags differ (Driver#token_bytes). The
  # name has to come back out byte for byte: re-tagging is not transcoding, so
  # what was passed in is what is printed.
  def test_preprocessing_a_file_whose_name_is_not_valid_utf8_expands_file
    in_tmpdir do |dir|
      source = join(dir, "e#{INVALID}.c")
      File.binwrite(source, "const char *path = __FILE__;\nconst char *raw = \"caf".b +
                            INVALID + "\";\n".b)

      out, err, status = rubycc("-E", source, dir: dir)

      refute_backtrace(err, "-E on a file name that is not UTF-8")
      assert_equal 0, status.exitstatus, err
      assert_includes out.b, "\"".b + source + "\";".b
      assert_includes out.b, "\"caf".b + INVALID + "\";".b
    end
  end

  # A compile error in a file whose name is not valid UTF-8, on a line that also
  # holds non-ASCII bytes: the diagnostic header splices the two together, which
  # is the concatenation Ruby refuses when their tags differ.
  def test_a_diagnostic_names_a_file_whose_name_is_not_valid_utf8
    in_tmpdir do |dir|
      source = join(dir, "err#{INVALID}.c")
      File.binwrite(source, "int main(void){ /* caf".b + INVALID +
                            " */ return undeclared; }\n".b)

      _out, err, status = rubycc("-c", source, "-o", join(dir, "err.o"), dir: dir)

      refute_backtrace(err, "a diagnostic naming a file that is not UTF-8")
      assert_equal 1, status.exitstatus
      assert_includes err.b, source + ":1:".b
      assert_includes err.b, "error: undeclared variable 'undeclared'".b
      # The offending line is echoed with its bytes intact, and the caret sits
      # under the identifier that starts at character 35 of it.
      assert_includes err.b, "\nint main(void){ /* caf".b + INVALID + " */ return undeclared; }\n".b
      assert_includes err.b, "\n#{" " * 34}^".b
    end
  end

  # An unrecognized option is warned about and dropped, which means its bytes go
  # into a message on the way out; the compile itself still has to happen.
  def test_an_unknown_option_that_is_not_valid_utf8_is_warned_about
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, INVALID)
      object = join(dir, "out.o")

      _out, err, status = rubycc("-c", source, "-I".b + include_dir,
                                 "-x".b + INVALID, "-o", object, dir: dir)

      assert_compiled(object, err, status, "an unknown option that is not UTF-8")
      assert_equal "rubycc: warning: unknown option '-x".b + INVALID + "' ignored\n".b, err.b
    end
  end

  # --version is answered before any argument is classified, so it was already
  # safe; it is here because that ordering is what makes it safe, and nothing
  # else in the driver states it.
  def test_version_is_printed_beside_an_argument_that_is_not_valid_utf8
    in_tmpdir do |dir|
      out, err, status = rubycc("--version", "-c", "s#{INVALID}.c", dir: dir)

      refute_backtrace(err, "--version beside an argument that is not UTF-8")
      assert_equal 0, status.exitstatus
      assert_equal "rubycc #{Rubycc::VERSION}\n", out
    end
  end

  # --- arguments that were always valid: the other direction ------------------

  # A file name, an include directory and an output path spelled in Japanese:
  # valid UTF-8 the whole way, so this never raised on the reported path. It is
  # the case re-tagging can break instead — a byte path that no longer joins,
  # compares or hashes with the strings it meets downstream.
  def test_japanese_paths_still_compile
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, NON_ASCII)
      object = join(dir, "out#{NON_ASCII}.o")

      _out, err, status = rubycc("-c", source, "-I".b + include_dir, "-o", object, dir: dir)

      assert_compiled(object, err, status, "Japanese paths")
    end
  end

  # The link path with Japanese names: the driver compiles in memory, hands the
  # object bytes to the linker and writes an executable at the named path.
  def test_a_japanese_source_links_into_an_executable
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, NON_ASCII)
      program = join(dir, spell("実行", NON_ASCII))

      _out, err, status = rubycc("-o", program, source, "-I".b + include_dir, dir: dir)

      refute_backtrace(err, "linking a Japanese source")
      assert_equal 0, status.exitstatus, err
      assert_equal "\x7FELF".b, File.binread(program, 4)
    end
  end

  # A relative -I under a working directory that is itself not ASCII. This is
  # the meeting point re-tagging created: the preprocessor normalizes a resolved
  # header path to decide file identity, and a relative path is normalized
  # against Dir.pwd, which comes from the process rather than from the argument.
  def test_relative_paths_resolve_under_a_non_ascii_working_directory
    [NON_ASCII, INVALID].each do |mark|
      in_tmpdir do |parent|
        work = join(parent, spell("作業", mark))
        Dir.mkdir(work)
        source, include_dir = write_project(work, mark)

        _out, err, status = rubycc("-c", File.basename(source),
                                   "-I".b + File.basename(include_dir),
                                   "-o", "out.o", dir: work)

        assert_compiled(join(work, "out.o"), err, status,
                        "a relative -I under a non-ASCII working directory")
      end
    end
  end

  # "#pragma once" is keyed on the resolved header's absolute path, and a
  # relative -I under a non-ASCII working directory is where that path has to be
  # completed from Dir.pwd. A key that failed to match would let the header be
  # read a second time, which redefines the enumerator: a diagnostic rather than
  # a crash, so this one would go unnoticed without an assertion.
  def test_pragma_once_holds_for_a_relative_path_under_a_non_ascii_directory
    in_tmpdir do |parent|
      work = join(parent, spell("作業", NON_ASCII))
      Dir.mkdir(work)
      include_dir = join(work, spell("inc", NON_ASCII))
      Dir.mkdir(include_dir)
      header = spell("h", NON_ASCII, ".h")
      File.binwrite(join(include_dir, header), "#pragma once\nenum { VALUE = 0 };\n".b)
      File.binwrite(join(work, "s.c"),
                    spell("#include \"", header, "\"\n#include \"", header,
                          "\"\nint main(void){ return VALUE; }\n"))

      _out, err, status = rubycc("-c", "s.c", spell("-I", File.basename(include_dir)),
                                 "-o", "out.o", dir: work)

      assert_compiled(join(work, "out.o"), err, status,
                      "#pragma once under a non-ASCII working directory")
    end
  end

  # -L and -l are resolved by composing "lib<name>.so", joining it onto each
  # search directory and listing that directory's entries. A search directory
  # and a library name tagged differently would not join, and a listing compared
  # against a differently tagged name would not match — so what has to be pinned
  # here is the success, with both spelled in non-ASCII bytes. The library is
  # built by rubycc itself so the two halves meet the way a real link does.
  def test_a_library_in_a_non_ascii_directory_is_resolved
    in_tmpdir do |dir|
      lib_dir = join(dir, spell("lib", NON_ASCII))
      Dir.mkdir(lib_dir)
      name = spell("helper", NON_ASCII)
      File.binwrite(join(dir, "helper.c"), "int helper(void){ return 0; }\n".b)
      File.binwrite(join(dir, "main.c"),
                    "int helper(void);\nint main(void){ return helper(); }\n".b)

      _out, err, status = rubycc("-shared", "-fPIC", join(dir, "helper.c"),
                                 "-o", join(lib_dir, spell("lib", name, ".so")), dir: dir)
      assert_equal 0, status.exitstatus, err

      program = join(dir, "prog")
      _out, err, status = rubycc("-o", program, join(dir, "main.c"),
                                 "-L".b + lib_dir, "-l".b + name, dir: dir)

      refute_backtrace(err, "-L and -l naming a non-ASCII directory and library")
      assert_equal 0, status.exitstatus, err
      assert_includes Reader.read_file(program).needed.map(&:b), spell("lib", name, ".so")
    end
  end

  # #include_next resumes the search past the directory the including header was
  # found in, and it finds that directory by looking the header up in a map keyed
  # on its absolute path (Preprocessor#absolute_path). A key that failed to match
  # would not raise: the directive would fall back to plain #include semantics and
  # resolve to the same header again, so the enumerator below would never be
  # defined. Both -I directories and the header itself are non-ASCII.
  def test_include_next_resumes_past_a_non_ascii_directory
    in_tmpdir do |dir|
      first = join(dir, spell("a", NON_ASCII))
      second = join(dir, spell("b", NON_ASCII))
      [first, second].each { |path| Dir.mkdir(path) }
      header = spell("h", NON_ASCII, ".h")
      File.binwrite(join(first, header), spell("#include_next \"", header, "\"\n"))
      File.binwrite(join(second, header), "enum { VALUE = 0 };\n".b)
      File.binwrite(join(dir, "s.c"),
                    spell("#include \"", header, "\"\nint main(void){ return VALUE; }\n"))
      object = join(dir, "out.o")

      _out, err, status = rubycc("-c", join(dir, "s.c"), "-I".b + first,
                                 "-I".b + second, "-o", object, dir: dir)

      assert_compiled(object, err, status, "#include_next past a non-ASCII directory")
    end
  end

  # The driver is also called in-process, by rmake's executor, with an array
  # that belongs to the caller. Re-tagging builds a new array rather than
  # replacing the caller's entries, so nothing the caller holds changes.
  def test_the_callers_argument_array_is_left_alone
    in_tmpdir do |dir|
      source, include_dir = write_project(dir, NON_ASCII)
      # Tagged the way ARGV hands them over, which is what the driver re-tags.
      argv = ["-c", source, "-I".b + include_dir, "-o", join(dir, "out.o")]
             .map { |arg| arg.dup.force_encoding(Encoding::UTF_8) }
      before = argv.map { |arg| [arg.dup, arg.encoding] }

      status = Rubycc::Driver.run(argv, stdout: StringIO.new, stderr: StringIO.new)

      assert_equal 0, status
      assert_equal before, argv.map { |arg| [arg, arg.encoding] }
    end
  end
end
