# frozen_string_literal: true

require_relative "test_helper"

# issues/builtin-strlen.md (GAPS row AZ): __builtin_strlen. gcc folds a
# string-literal argument to the byte count before the first NUL, a genuine
# constant-expression usable in a static initializer, an array bound, a case
# label and a _Static_assert (measured against gcc 13.3, 2026-09-13); a
# non-literal argument is an ordinary run-time call, matching libc's strlen.
class TestBuiltinStrlen < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # A literal argument and a char * variable argument, both matched against
  # gcc's value. The embedded-NUL literal proves the fold stops at the first
  # NUL byte rather than counting the whole storage width.
  BASIC_SOURCE = <<~C
    #include <stdio.h>
    int main(void) {
      unsigned long lit_len = __builtin_strlen("rubycc");
      unsigned long empty_len = __builtin_strlen("");

      char buf[8] = "abcdef";
      char *p = buf;
      unsigned long var_len = __builtin_strlen(p);

      unsigned long embedded_len = __builtin_strlen("ab\\0cd");

      printf("%lu %lu %lu %lu\\n", lit_len, empty_len, var_len, embedded_len);
      return 0;
    }
  C

  # The same fold in every constant context a header relies on: a static
  # initializer, an array bound, an enumerator, a _Static_assert and a case
  # label. None of these reaches a backend at all — the constant evaluator
  # answers them — so this is the second of the two paths a fold has to agree
  # with gcc on.
  CONSTANT_CONTEXT_SOURCE = <<~C
    #include <stdio.h>
    static unsigned long abcd_len = __builtin_strlen("abcd");
    static char sized[__builtin_strlen("abc") + 1];
    enum { AB_LEN = __builtin_strlen("ab") };
    int classify(int n) {
      switch (n) {
        case __builtin_strlen("ab"): return 100;
        case __builtin_strlen("abc"): return 300;
        default: return -1;
      }
    }
    int main(void) {
      _Static_assert(__builtin_strlen("abc") == 3, "builtin_strlen constant fold");
      _Static_assert(__builtin_strlen("") == 0, "the empty literal folds to 0");
      printf("%lu %zu %d %d %d %d\\n",
             abcd_len, sizeof(sized), (int)AB_LEN,
             classify(2), classify(3), classify(9));
      return 0;
    }
  C

  # herb 0.10.4's src/include/lib/hb_string.h:27 wraps the builtin in a macro
  # exactly like this, casting the folded constant to a narrower type.
  MACRO_SOURCE = <<~C
    #include <stdio.h>
    #define HB_STRLEN(s) ((unsigned) __builtin_strlen(s))
    int main(void) {
      printf("%u\\n", HB_STRLEN("herb"));
      return 0;
    }
  C

  def test_literal_and_variable_arguments_match_gcc
    assert_matches_gcc(BASIC_SOURCE, "builtin_strlen_basic")
  end

  def test_constant_contexts_match_gcc
    assert_matches_gcc(CONSTANT_CONTEXT_SOURCE, "builtin_strlen_constant")
  end

  def test_macro_wrapped_use_matches_gcc
    assert_matches_gcc(MACRO_SOURCE, "builtin_strlen_macro")
  end

  # __builtin_strlen takes exactly one argument; any other count is an arity
  # diagnostic.
  def test_wrong_argument_count_rejected
    source = <<~C
      int main(void) {
        return __builtin_strlen("a", "b");
      }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "builtin_strlen_arity.c", target: host_target)
    end
    assert_match(/'__builtin_strlen' expects 1 argument, have 2/, error.message)
  end

  # __has_builtin reports __builtin_strlen present, the same probe a header
  # guarding a fallback would make.
  def test_has_builtin_reports_strlen_present
    source = <<~C
      int main(void) {
      #if __has_builtin(__builtin_strlen)
        return 0;
      #else
        return 1;
      #endif
      }
    C
    assert_c_exit_status(0, source)
  end

  def assert_matches_gcc(source, name)
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      binary = Rubycc::Compiler.new.compile(source, filename: "#{name}.c", target: host_target)
      File.binwrite(rubycc_obj, binary)
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = compile_with_gcc(source, File.join(dir, "#{name}_gcc.o"))
      gcc_status, gcc_out = link_and_run(gcc_obj)

      assert_equal 0, rubycc_status, "rubycc-built #{name} exited #{rubycc_status}"
      assert_equal gcc_status, rubycc_status, "#{name}: exit status differs from gcc"
      assert_equal gcc_out, rubycc_out, "#{name}: output differs from gcc"
    end
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
