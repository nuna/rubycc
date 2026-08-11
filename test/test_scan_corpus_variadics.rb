# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

require_relative "../tools/scan_corpus_variadics"

class TestScanCorpusVariadics < Minitest::Test
  SCANNER = CorpusVariadicsScanner::Scanner
  TOOL = File.expand_path("../tools/scan_corpus_variadics.rb", __dir__)

  def test_finds_requested_variadic_candidates
    Dir.mktmpdir("rubycc-variadics") do |root|
      File.write(File.join(root, "sample.c"), <<~C)
        #include <stdarg.h>
        struct payload { int value; };
        union alternate { int value; };
        typedef struct payload payload_t;
        typedef va_list wrapped_va_list;
        typedef void (*callback_type)(const char *format, ...);

        void consume(const char *format, ...);
        void (*callback)(const char *format, ...);
        callback_type callback_alias;

        void forward(va_list ap) { (void)ap; }
        void read_struct(va_list ap) {
          struct payload value;
          union alternate alternate_value;
          (void)va_arg(ap, struct payload);
          (void)va_arg(ap, payload_t);
          va_copy(ap, ap);
          consume("%d", value);
          printf("%d", value);
          callback("%d", value);
          callback_alias("%d", value);
          consume("%d", alternate_value);
        }
      C

      report = SCANNER.new(roots: [root]).scan
      kinds = report.fetch("findings").map { |finding| finding.fetch("kind") }

      assert_includes kinds, "va_arg_struct_or_union"
      typedef_finding = report.fetch("findings").find do |finding|
        finding["kind"] == "va_arg_struct_or_union" && finding.dig("details", "type_form") == "struct_or_union_typedef"
      end
      refute_nil typedef_finding, "typedef struct passed to va_arg must be a corpus candidate"
      assert_includes kinds, "va_copy_candidate"
      assert_includes kinds, "va_list_wrapper"
      assert_includes kinds, "function_pointer_variadic_api"
      assert_operator kinds.count("struct_argument_to_variadic_candidate"), :>=, 3

      caller_findings = report.fetch("findings").select do |finding|
        finding["kind"] == "struct_argument_to_variadic_candidate"
      end
      assert caller_findings.any? { |finding| finding.dig("details", "callee") == "consume" }
      assert caller_findings.any? { |finding| finding.dig("details", "callee") == "printf" }
      assert caller_findings.any? { |finding| finding.dig("details", "callee") == "callback" }
      assert caller_findings.any? { |finding| finding.dig("details", "callee") == "callback_alias" }
      assert caller_findings.any? { |finding| finding.dig("details", "argument_shape") == "known_struct_or_union_variable" && finding.dig("details", "callee") == "consume" }
    end
  end

  def test_ignores_comments_and_string_or_character_literals
    Dir.mktmpdir("rubycc-variadics") do |root|
      File.write(File.join(root, "noise.c"), <<~C)
        /* va_arg(ap, struct from_comment); va_copy(copy, ap); */
        const char *text = "va_arg(ap, struct from_string)";
        int character = 'x'; /* __builtin_va_copy(a, b) */
        // printf("%d", struct from_line_comment);
        int value;
      C

      report = SCANNER.new(roots: [root]).scan
      assert_empty report.fetch("findings")
    end
  end

  def test_macro_expansion_is_a_documented_limit
    Dir.mktmpdir("rubycc-variadics") do |root|
      File.write(File.join(root, "macro.c"), <<~C)
        #define READ(ap, type) va_arg(ap, type)
        #define COPY(a, b) va_copy(a, b)
        struct payload { int value; };
        void use(va_list ap) {
          struct payload value;
          (void)READ(ap, struct payload);
          COPY(ap, ap);
          (void)value;
        }
      C

      report = SCANNER.new(roots: [root]).scan
      kinds = report.fetch("findings").map { |finding| finding.fetch("kind") }

      # The raw macro body exposes va_copy, but the struct type only appears at
      # the expansion site.  A preprocessor-aware scan would be needed to
      # connect those tokens; this tool deliberately does not claim to do so.
      assert_includes kinds, "va_copy_candidate"
      refute_includes kinds, "va_arg_struct_or_union"
      assert report.fetch("limitations").any? { |text| text.include?("Macros are not expanded") }
    end
  end

  def test_anonymous_struct_variable_is_a_caller_candidate
    Dir.mktmpdir("rubycc-variadics") do |root|
      File.write(File.join(root, "anonymous.c"), <<~C)
        void consume(const char *format, ...);
        void call(void) {
          struct { int value; } payload;
          consume("%d", payload);
        }
      C

      report = SCANNER.new(roots: [root]).scan
      finding = report.fetch("findings").find do |candidate|
        candidate["kind"] == "struct_argument_to_variadic_candidate"
      end
      refute_nil finding
      assert_equal "known_struct_or_union_variable", finding.dig("details", "argument_shape")
    end
  end

  def test_does_not_borrow_a_c_declaration_from_another_source_file
    Dir.mktmpdir("rubycc-variadics") do |root|
      File.write(File.join(root, "provider.c"), "void emit(int fixed, ...);\n")
      File.write(File.join(root, "caller.c"), <<~C)
        struct payload { int value; };
        void call(void) {
          struct payload value;
          emit(1, value);
        }
      C

      report = SCANNER.new(roots: [root]).scan
      borrowed_declaration = report.fetch("findings").any? do |finding|
        finding["kind"] == "struct_argument_to_variadic_candidate" &&
          finding.dig("details", "callee") == "emit"
      end
      refute borrowed_declaration
    end
  end

  def test_output_is_sorted_and_has_no_run_specific_metadata
    Dir.mktmpdir("rubycc-variadics") do |root|
      FileUtils.mkdir_p(File.join(root, "z"))
      FileUtils.mkdir_p(File.join(root, "a"))
      File.write(File.join(root, "z", "z.c"), "void f(va_list ap) { va_copy(ap, ap); }\n")
      File.write(File.join(root, "a", "a.c"), "void f(va_list ap) { va_copy(ap, ap); }\n")

      first = SCANNER.new(roots: [root]).scan
      second = SCANNER.new(roots: [root]).scan
      assert_equal first, second
      assert_equal ["a/a.c", "z/z.c"], first.fetch("findings").map { |finding| finding.fetch("path") }.uniq
      refute_match(/\d{4}-\d{2}-\d{2}/, JSON.generate(first))
      refute_includes JSON.generate(first), RUBY_DESCRIPTION
    end
  end

  def test_cli_help_states_non_proof_contract
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, TOOL, "--help")
    assert status.success?, stderr
    assert_includes stdout, "not an absence proof"
    assert_includes stdout, "does not expand or evaluate macros"
  end

  def test_cli_json_is_network_free_and_uses_relative_paths
    Dir.mktmpdir("rubycc-variadics") do |root|
      FileUtils.mkdir_p(File.join(root, "nested"))
      File.write(File.join(root, "nested", "sample.c"), "void f(va_list ap) { va_copy(ap, ap); }\n")
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, TOOL, "--root", root, "--format", "json")

      assert status.success?, stderr
      report = JSON.parse(stdout)
      assert_equal 1, report.fetch("files_scanned")
      assert_equal ["nested/sample.c"], report.fetch("findings").map { |finding| finding.fetch("path") }.uniq
      refute_includes stdout, "http://"
      refute_includes stdout, "https://"
    end
  end
end
