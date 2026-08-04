# frozen_string_literal: true

require "rbconfig"

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

  # <stdckdint.h>: ckd_add/ckd_sub/ckd_mul, C23's type-generic checked-arithmetic
  # macros (7.20.1), each a one-liner over the __builtin_*_overflow builtins
  # added in Step 177. Note the result pointer is the *first* argument here,
  # unlike the builtins it expands to.
  STDCKDINT_SOURCE = <<~C
    #include <stdckdint.h>
    #include <stdint.h>
    #include <stdio.h>
    int main(void) {
      size_t r;
      int ov1 = ckd_mul(&r, (size_t)SIZE_MAX, (size_t)SIZE_MAX);
      printf("%d %zu\\n", ov1, r);

      size_t r2;
      int ov2 = ckd_mul(&r2, (size_t)6, (size_t)7);
      printf("%d %zu\\n", ov2, r2);

      int q;
      int ov3 = ckd_add(&q, 2147483647, 1);
      printf("%d %d\\n", ov3, q);

      int q2;
      int ov4 = ckd_sub(&q2, -2147483647 - 1, 1);
      printf("%d %d\\n", ov4, q2);

      printf("%ld\\n", (long)__STDC_VERSION_STDCKDINT_H__);
      return 0;
    }
  C

  # Expected output of STDCKDINT_SOURCE, computed by hand from the type widths
  # involved (matching the table used to verify __builtin_*_overflow itself in
  # Step 177's docs/STEPS.md entry): SIZE_MAX * SIZE_MAX overflows size_t and
  # (per the builtin's truncation contract) leaves 1 in *r; 6 * 7 does not
  # overflow and stores 42; INT_MAX + 1 overflows int and wraps to INT_MIN;
  # INT_MIN - 1 overflows int and wraps to INT_MAX; and
  # __STDC_VERSION_STDCKDINT_H__ is the C23 202311L this header defines it as.
  STDCKDINT_EXPECTED_OUTPUT = <<~OUT
    1 1
    0 42
    1 -2147483648
    1 2147483647
    202311
  OUT

  # The name the partial include below asks for, which is the host libc's own:
  # glibc calls the bare va_list type __gnuc_va_list, musl calls it
  # __isoc_va_list (measured on musl, Step 175: gcc itself -- the oracle this
  # file diffs against -- fails to compile the __gnuc_va_list spelling there,
  # so the case proved nothing about rubycc). The libc is read from RbConfig's
  # arch triplet, the same source test/abi_harness/harness.rb's #host_libc and
  # tools/verify_gem_tests.rb's environment_string read: MRI spells a musl
  # build "x86_64-linux-musl" and a glibc one "x86_64-linux".
  VA_LIST_TYPE_NAME =
    RbConfig::CONFIG["arch"].to_s.include?("musl") ? "__isoc_va_list" : "__gnuc_va_list"

  # The glibc partial-include protocol: a header defines __need___va_list and
  # then includes <stdarg.h> to obtain only the bare va_list type (not va_list
  # itself and the macros). rubycc's stdarg.h must satisfy exactly that request.
  NEED_VA_LIST_SOURCE = <<~C
    #define __need___va_list
    #include <stdarg.h>
    #include <stdarg.h>
    #include <stdio.h>
    static int forward(int n, #{VA_LIST_TYPE_NAME} ap) { return va_arg(ap, int) + n; }
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

  # Not assert_matches_gcc: the host gcc used elsewhere in this file as the
  # cross-check oracle has no <stdckdint.h> of its own (verified locally --
  # "fatal error: stdckdint.h: No such file or directory" -- C23's freestanding
  # headers being a recent addition gcc has not shipped everywhere yet), so
  # there is no gcc-built binary to diff against here. Instead the program's
  # output is checked against a hand-computed expected value; the
  # __builtin_*_overflow instructions it expands to were already differentially
  # verified against gcc in Step 177, so that is where this expected value's
  # correctness ultimately rests.
  def test_stdckdint_checked_arithmetic_macros
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "stdckdint_rubycc.o")
      binary = Rubycc::Compiler.new.compile(STDCKDINT_SOURCE, filename: "stdckdint.c")
      File.binwrite(rubycc_obj, binary)
      status, out = link_and_run(rubycc_obj)

      assert_equal 0, status, "rubycc-built stdckdint exited #{status}"
      assert_equal STDCKDINT_EXPECTED_OUTPUT, out
    end
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
