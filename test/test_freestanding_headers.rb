# frozen_string_literal: true

require_relative "test_helper"

# Step 41: rubycc ships its own compiler-supplied ("freestanding") headers
# (stdarg.h, stddef.h, stdbool.h, stdalign.h, iso646.h, stdnoreturn.h, float.h)
# under the gem's include/ directory and injects that directory, ahead of the
# libc directories, as its default system search path. This proves an angled
# #include of those headers resolves with *no* -I at all, that each maps onto
# rubycc's builtins with the same run-time behavior gcc produces, that the
# glibc "__need_*" partial-include protocol works, and that -nostdinc turns the
# whole default path off.
class TestFreestandingHeaders < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
    skip "system libc headers not found (/usr/include/stdio.h missing)" unless File.exist?("/usr/include/stdio.h")
  end

  # <stdarg.h>: variable arguments via __builtin_va_*.
  STDARG_SOURCE = <<~C
    #include <stdarg.h>
    #include <stdio.h>
    static int add_all(int count, ...) {
      va_list ap;
      va_start(ap, count);
      int total = 0;
      for (int i = 0; i < count; i++) total += va_arg(ap, int);
      va_end(ap);
      return total;
    }
    int main(void) {
      printf("%d\\n", add_all(4, 5, 15, 25, 55));
      return 0;
    }
  C

  # <stddef.h>: offsetof, size_t and NULL (offsetof used in a run-time context).
  STDDEF_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>
    struct layout { char tag; int value; double weight; };
    int main(void) {
      size_t off = offsetof(struct layout, weight);
      size_t width = sizeof(size_t);
      int *p = NULL;
      printf("%zu %zu %d\\n", off, width, p == NULL);
      return 0;
    }
  C

  # <stdbool.h>: bool / true / false.
  STDBOOL_SOURCE = <<~C
    #include <stdbool.h>
    #include <stdio.h>
    int main(void) {
      bool a = true;
      bool b = false;
      printf("%d %d %d\\n", a, b, __bool_true_false_are_defined);
      return 0;
    }
  C

  # <stdalign.h>: alignof.
  STDALIGN_SOURCE = <<~C
    #include <stdalign.h>
    #include <stdio.h>
    struct wide { long a; double b; };
    int main(void) {
      printf("%d %d %d\\n", (int)alignof(double), (int)alignof(struct wide), __alignof_is_defined);
      return 0;
    }
  C

  # <iso646.h>: alternative operator spellings.
  ISO646_SOURCE = <<~C
    #include <iso646.h>
    #include <stdio.h>
    int main(void) {
      int x = 6, y = 0;
      int r = (x > 0 and y == 0) or (x bitand 1);
      printf("%d %d\\n", r, not y);
      return 0;
    }
  C

  # The glibc partial-include protocol: a header defines __need___va_list and
  # then includes <stdarg.h> to obtain only __gnuc_va_list (not va_list and the
  # macros). rubycc's stdarg.h must satisfy exactly that request.
  NEED_VA_LIST_SOURCE = <<~C
    #define __need___va_list
    #include <stdarg.h>
    #include <stdarg.h>
    #include <stdio.h>
    static int forward(int n, __gnuc_va_list ap) { return va_arg(ap, int) + n; }
    static int run(int n, ...) {
      va_list ap;
      va_start(ap, n);
      int r = forward(n, ap);
      va_end(ap);
      return r;
    }
    int main(void) {
      printf("%d\\n", run(100, 23));
      return 0;
    }
  C

  # __need_NULL: pull in only NULL from <stddef.h>, leaving size_t undeclared.
  NEED_NULL_SOURCE = <<~C
    #define __need_NULL
    #include <stddef.h>
    #include <stdio.h>
    int main(void) {
      void *p = NULL;
      printf("%d\\n", p == NULL);
      return 0;
    }
  C

  def test_stdarg_varargs_match_gcc
    assert_matches_gcc(STDARG_SOURCE, "stdarg")
  end

  def test_stddef_offsetof_size_t_null_match_gcc
    assert_matches_gcc(STDDEF_SOURCE, "stddef")
  end

  def test_stdbool_bool_true_false_match_gcc
    assert_matches_gcc(STDBOOL_SOURCE, "stdbool")
  end

  def test_stdalign_alignof_matches_gcc
    assert_matches_gcc(STDALIGN_SOURCE, "stdalign")
  end

  def test_iso646_operator_macros_match_gcc
    assert_matches_gcc(ISO646_SOURCE, "iso646")
  end

  def test_need_va_list_partial_include_matches_gcc
    assert_matches_gcc(NEED_VA_LIST_SOURCE, "need_va_list")
  end

  def test_need_null_partial_include_matches_gcc
    assert_matches_gcc(NEED_NULL_SOURCE, "need_null")
  end

  # -nostdinc (system_includes: false) removes the bundled directory from the
  # search path, so an angled include of a compiler-supplied header no longer
  # resolves and the preprocessor diagnoses it.
  def test_nostdinc_makes_stdarg_unresolvable
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(
        "#include <stdarg.h>\nint main(void) { return 0; }\n",
        filename: "no_stdarg.c", system_includes: false
      )
    end
    assert_includes error.message, "stdarg.h: No such file or directory"
  end

  private

  # Compiles `source` with rubycc using only the default (bundled + libc) system
  # search path — no -I is passed — and with gcc, links and runs both, and
  # asserts a clean exit and byte-identical output. rubycc supplying no
  # include_paths is the point: the bundled headers must be found on their own.
  def assert_matches_gcc(source, name)
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      binary = Rubycc::Compiler.new.compile(source, filename: "#{name}.c")
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
