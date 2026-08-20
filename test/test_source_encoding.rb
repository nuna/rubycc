# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

# A C source file is a sequence of bytes (5.1.1.2), and rubycc has to read it as
# one. Reading it as *text* makes the compiler depend on Encoding.default_external
# — the process locale — in two ways, both of which these tests pin down:
#
#   1. Under a locale of "C" (LANG unset: cron, systemd units, and the Docker
#      images that ship no locale at all) File.read returns a US-ASCII string, so
#      the first byte past 0x7F anywhere in the translation unit raises
#      ArgumentError from the scanner's very first #split. The bundled stddef.h
#      has three such bytes, in a comment, which made "#include <stddef.h>"
#      alone impossible to compile.
#   2. Under a UTF-8 locale a file that is not valid UTF-8 — an ISO-8859-1
#      comment, a string literal holding raw bytes — raises the same error.
#
# Neither has anything to do with the C being compiled: the bytes in question sit
# in comments and in string literals, where C asks only that they be carried
# through. The tests below therefore come in pairs: an end-to-end compile with
# the locale variables removed from the environment (case 1, which needs a
# subprocess to have no locale), and an in-process one over bytes that are not
# valid UTF-8 (case 2, which fails under any locale).
class TestSourceEncoding < Minitest::Test
  include ExecutionHelper

  EXE_PATH = File.expand_path("../exe/rubycc", __dir__)

  # The environment of a process that has no locale. nil unsets the variable for
  # the child, rather than setting it to the empty string; either yields
  # Encoding.default_external == US-ASCII, and unsetting is the shape a stripped
  # container image actually has.
  NO_LOCALE = { "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil, "LANGUAGE" => nil }.freeze

  # A UTF-8 comment and a UTF-8 string literal: valid text, but not ASCII.
  UTF8_SOURCE = <<~C.b
    #include <stdio.h>
    /* 日本語のコメント — em dash and all */
    int main(void) {
      // ひらがな
      printf("%s\\n", "あいう");
      return 0;
    }
  C

  # The same shape with bytes that are not valid UTF-8 at all: 0xFF and 0xFE
  # never appear in UTF-8, and 0xE9 is "e acute" in ISO-8859-1. They sit in a
  # comment and in a string literal, so the program's meaning does not depend on
  # how they are interpreted — only on their being passed through untouched.
  LATIN1_SOURCE = (+"#include <stdio.h>\n" \
                    "/* caf\xE9 \xFF\xFE latin-1 comment */\n" \
                    "int main(void) {\n" \
                    "  printf(\"%s\\n\", \"caf\xE9\");\n" \
                    "  return 0;\n" \
                    "}\n").b.freeze

  def lib_dir
    File.expand_path("../lib", __dir__)
  end

  # --- no locale at all (the reported failure) --------------------------------

  # The reported reproduction: a translation unit whose only non-ASCII byte
  # comes from a bundled header's comment, compiled with no locale.
  def test_bundled_header_compiles_without_a_locale
    Dir.mktmpdir("rubycc-encoding") do |dir|
      source = File.join(dir, "input.c")
      File.binwrite(source, "#include <stddef.h>\nint main(void) { return 0; }\n")
      object = File.join(dir, "input.o")

      _stdout, stderr, status = Open3.capture3(NO_LOCALE, "ruby", "-I#{lib_dir}", EXE_PATH,
                                               "-c", source, "-o", object)

      assert_equal 0, status.exitstatus, "stderr: #{stderr}"
      assert_equal "\x7FELF".b, File.binread(object, 4)
    end
  end

  # The locale must not reach the object: the same source compiled with and
  # without one has to produce the same bytes, or "read the source as bytes"
  # would have become "compile something else".
  def test_the_object_does_not_depend_on_the_locale
    Dir.mktmpdir("rubycc-encoding") do |dir|
      source = File.join(dir, "input.c")
      File.binwrite(source, "#include <stddef.h>\nsize_t width(void) { return sizeof(int); }\n")

      objects = [NO_LOCALE, { "LC_ALL" => "C.UTF-8" }].each_with_index.map do |env, index|
        object = File.join(dir, "out#{index}.o")
        _stdout, stderr, status = Open3.capture3(env, "ruby", "-I#{lib_dir}", EXE_PATH,
                                                 "-c", source, "-o", object)
        assert_equal 0, status.exitstatus, "stderr: #{stderr}"
        File.binread(object)
      end

      assert_equal objects.first, objects.last
    end
  end

  # A user source with UTF-8 comments and a UTF-8 string literal, compiled with
  # no locale: it must build, and the literal's bytes must reach the executable
  # unchanged (gcc is the oracle for "unchanged").
  def test_utf8_source_compiles_without_a_locale_and_matches_gcc
    assert_matches_gcc(UTF8_SOURCE, env: NO_LOCALE)
  end

  # -E is a second reader (the driver preprocesses the file itself), so it gets
  # the same treatment: no locale, non-ASCII source, and the bytes come out.
  def test_preprocess_only_works_without_a_locale
    Dir.mktmpdir("rubycc-encoding") do |dir|
      source = File.join(dir, "input.c")
      File.binwrite(source, UTF8_SOURCE)

      stdout, stderr, status = Open3.capture3(NO_LOCALE, "ruby", "-I#{lib_dir}", EXE_PATH,
                                              "-E", source)

      assert_equal 0, status.exitstatus, "stderr: #{stderr}"
      assert_includes stdout.b, "\"あいう\"".b
    end
  end

  # -E re-spells the token stream into a buffer, which is the second place where
  # a locale-encoded string meets the source's bytes: __FILE__ expands to a
  # string literal spelled with the file name the driver was given, and that
  # name carries the locale's encoding rather than the source's. With a raw
  # UTF-8 literal in the same unit the buffer would hold both, which Ruby
  # refuses to concatenate. "ruby -EUTF-8" pins the encoding of that name
  # without depending on which locales the host happens to have installed.
  def test_preprocess_only_mixes_a_non_ascii_file_name_with_non_ascii_source
    Dir.mktmpdir("rubycc-encoding") do |dir|
      source = File.join(dir, "日本.c")
      File.binwrite(source, "const char *n = __FILE__;\nconst char *s = \"あ\";\n".b)
      output = File.join(dir, "out.i")

      stdout, stderr, status = Open3.capture3("ruby", "-EUTF-8", "-I#{lib_dir}", EXE_PATH,
                                              "-E", source)

      assert_equal 0, status.exitstatus, "stderr: #{stderr}"
      assert_includes stdout.b, "あ".b
      assert_includes stdout.b, "日本.c".b

      # ...and the same text when it is written to a file rather than printed.
      _stdout, stderr, status = Open3.capture3("ruby", "-EUTF-8", "-I#{lib_dir}", EXE_PATH,
                                               "-E", source, "-o", output)

      assert_equal 0, status.exitstatus, "stderr: #{stderr}"
      assert_equal stdout.b, File.binread(output)
    end
  end

  # --- bytes that are not valid UTF-8 (fails under any locale) ----------------

  def test_source_that_is_not_valid_utf8_compiles_and_matches_gcc
    assert_matches_gcc(LATIN1_SOURCE, env: NO_LOCALE)
  end

  # Compiler.compile_file is the driver's -c path and an embedder's entry point;
  # it reads the file itself, so it needs its own coverage. Bytes that are not
  # valid UTF-8 make the point without touching the process's locale.
  def test_compile_file_reads_bytes
    Dir.mktmpdir("rubycc-encoding") do |dir|
      source = File.join(dir, "input.c")
      File.binwrite(source, LATIN1_SOURCE)
      object = File.join(dir, "input.o")

      Rubycc::Compiler.compile_file(source, object, target: host_target)

      assert_equal "\x7FELF".b, File.binread(object, 4)
    end
  end

  # A string literal's non-ASCII bytes are its bytes: each one is one element of
  # the array, exactly as gcc emits them, and no transcoding happens on the way
  # into .rodata.
  def test_string_literal_keeps_its_bytes
    program = Rubycc::Preprocess::Preprocessor.new
                                              .run("char *s = \"\xE3\x81\x82\xFF\";".b, filename: "t.c")
    literal = program.find { |token| token.type == :string }

    assert_equal "\xE3\x81\x82\xFF".b, literal.value
    assert_equal Encoding::BINARY, literal.value.encoding
  end

  # --- the scanner's own contract ---------------------------------------------

  # What File.read hands over under a locale of "C": the file's bytes, tagged
  # US-ASCII and therefore invalid. The scanner re-tags rather than transcodes,
  # so the source survives whatever the caller's encoding was.
  def test_scanner_accepts_text_tagged_by_the_locale
    source = "/* \xE3\x81\x82 */ int x;\n".b.force_encoding(Encoding::US_ASCII)
    tokens = Rubycc::Preprocess::Scanner.new(source, filename: "t.c").scan
    identifier = tokens.find { |token| token.text == "x" }

    assert_equal :identifier, identifier.type
    assert_equal Encoding::BINARY, identifier.text.encoding
  end

  # Columns stay character counts, so a caret still lines up under a line with
  # multibyte characters in it. A byte that cannot start a UTF-8 character
  # counts as one column of its own — there is nothing better to do with it, and
  # the count must stay defined.
  def test_columns_count_characters_not_bytes
    utf8 = Rubycc::Preprocess::Scanner.new("/* あ */ int x;\n".b, filename: "t.c").scan
    latin1 = Rubycc::Preprocess::Scanner.new("/* \xE9\xE9 */ int x;\n".b, filename: "t.c").scan

    assert_equal 13, utf8.find { |token| token.text == "x" }.column
    assert_equal 14, latin1.find { |token| token.text == "x" }.column
  end

  # A character that belongs to no token class is one :other token per
  # character, not per byte (6.4p1). Per byte, a single stray character would
  # produce three errors and a caret pointing at the middle of it.
  def test_a_stray_multibyte_character_is_one_token
    tokens = Rubycc::Preprocess::Scanner.new("int \xE3\x81\x82;".b, filename: "t.c").scan
    others = tokens.select { |token| token.type == :other }

    assert_equal ["\xE3\x81\x82".b], others.map(&:text)
    assert_equal [5], others.map(&:column)
    # ...and the ";" after it is still at column 6, one column past the character.
    assert_equal 6, tokens.find { |token| token.text == ";" }.column
  end

  # A byte that cannot be part of any UTF-8 character stands alone, so a file
  # that is not UTF-8 still scans to completion.
  def test_a_byte_that_is_not_utf8_is_a_token_of_its_own
    tokens = Rubycc::Preprocess::Scanner.new("int \xFF\xFF;".b, filename: "t.c").scan
    others = tokens.select { |token| token.type == :other }

    assert_equal ["\xFF".b, "\xFF".b], others.map(&:text)
    assert_equal [5, 6], others.map(&:column)
  end

  # A lone continuation byte is a byte no character starts with, and the column
  # rule does not count it -- so two of them in a row report the *same* column,
  # and everything after them is reported one column short per byte. That is the
  # price of a context-free rule (see Scanner#column_at) and it is fixed here as
  # the expected answer rather than left to be discovered: input that is not
  # UTF-8 gets columns that still advance monotonically and still point into the
  # right line, but no longer count anything meaningful.
  def test_lone_continuation_bytes_share_a_column
    tokens = Rubycc::Preprocess::Scanner.new("int \x80\x80 x;".b, filename: "t.c").scan
    others = tokens.select { |token| token.type == :other }

    assert_equal ["\x80".b, "\x80".b], others.map(&:text)
    assert_equal [5, 5], others.map(&:column)
    # "x" is the 8th byte of the line and is reported at column 6: the two
    # uncounted bytes are exactly the difference.
    assert_equal 6, tokens.find { |token| token.text == "x" }.column
  end

  # --- diagnostics -------------------------------------------------------------

  # The message splices a source line (bytes) into a header built from a file
  # name (whatever the locale said). Both may hold non-ASCII bytes, and Ruby
  # refuses to concatenate two such strings of different encodings — which would
  # replace the diagnostic with an Encoding::CompatibilityError backtrace.
  def test_a_diagnostic_survives_a_non_ascii_file_name_and_source_line
    message = Rubycc::Diagnostics.render("error", "undeclared variable 'x'",
                                         filename: "日本.c", line: 1, column: 5,
                                         source_line: "int \xE3\x81\x82 x;".b)

    assert_equal "日本.c:1:5: error: undeclared variable 'x'\nint \xE3\x81\x82 x;\n    ^".b, message
  end

  # End to end: a compile error on a line with non-ASCII characters must still
  # be a diagnostic — with the offending line printed and the caret under the
  # right character — and not a Ruby backtrace.
  def test_a_compile_error_on_a_non_ascii_line_is_reported_without_a_locale
    Dir.mktmpdir("rubycc-encoding") do |dir|
      source = File.join(dir, "input.c")
      File.binwrite(source, "int main(void) { /* あ */ return undeclared; }\n")

      _stdout, stderr, status = Open3.capture3(NO_LOCALE, "ruby", "-I#{lib_dir}", EXE_PATH,
                                               "-c", source, "-o", File.join(dir, "input.o"))

      assert_equal 1, status.exitstatus
      assert_includes stderr.b, "error: undeclared variable 'undeclared'".b
      # Column 33 is the character position of "undeclared" on that line, so the
      # caret sits under it: 32 spaces then the caret.
      assert_includes stderr.b, "\n#{" " * 32}^".b
    end
  end

  private

  # Compiles `source` with rubycc (in `env`) and with gcc, runs both, and
  # asserts the two programs behave identically. Bytes the compiler is only
  # asked to carry through are exactly the ones this catches: the literal
  # reaches stdout, so a transcoding anywhere in the pipeline shows up.
  def assert_matches_gcc(source, env:)
    Dir.mktmpdir("rubycc-encoding") do |dir|
      path = File.join(dir, "input.c")
      File.binwrite(path, source)
      object = File.join(dir, "input.o")

      _stdout, stderr, status = Open3.capture3(env, "ruby", "-I#{lib_dir}", EXE_PATH,
                                               "-c", path, "-o", object)
      assert_equal 0, status.exitstatus, "stderr: #{stderr}"

      exit_status, output = link_and_run(object)
      oracle_status, oracle_output = link_and_run(compile_with_gcc(source, File.join(dir, "oracle.o")))

      assert_equal oracle_status, exit_status
      assert_equal oracle_output.b, output.b
    end
  end
end
