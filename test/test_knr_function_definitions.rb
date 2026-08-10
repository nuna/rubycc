# frozen_string_literal: true

require_relative "test_helper"

# Old-style (K&R) function definitions: the identifier-list declarator of ISO C
# 6.7.6.3 followed by the declaration-list of 6.9.1.
#
#   int add(a, b)
#     int a;
#     int b;
#   { return a + b; }
#
# The form survives in generated code — gperf emits it, which is how mysql2's
# bundled mysql_enc_name_to_ruby.h reaches a compiler — so it is not a museum
# piece.
#
# What makes it more than a parsing exercise is that such a function has no
# prototype: its arguments arrive default-argument promoted (6.9.1p10 with
# 6.5.2.2p6), so a `float` parameter is handed a `double` and a
# `char`/`short`/`_Bool` parameter an `int`, while the body still sees the
# narrow object it declared. Every expectation below about *which* value comes
# out of that is a differential against gcc rather than a reading of the
# standard, because the interesting cases are the ones where the two could
# differ: a `_Bool` parameter passed 2 reads back as 2 under gcc (it stores the
# low byte and does not normalize to 0/1), and a `char` parameter passed 300
# reads back as 44.
class TestKnrFunctionDefinitions < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # The whole feature in one program: the plain form, `register` parameters, a
  # parameter the declaration-list never mentions (type `int` by 6.9.1p6), an
  # array parameter adjusted to a pointer, a struct by value, and a definition
  # of a function returning a pointer to a function.
  DEFINITIONS_SOURCE = <<~C
    #include <stdio.h>

    struct pair { int x; int y; };

    /* The gperf shape, verbatim: `register` on every parameter and no
       prototype anywhere. */
    static unsigned int knr_hash (str, len)
         register const char *str;
         register unsigned int len;
    { return (unsigned int)str[0] + len; }

    int add(a, b)
      int a;
      int b;
    { return a + b; }

    /* One declaration may declare several of the parameters at once, and the
       order need not match the identifier list's. */
    int spread(a, b, c)
      int b, c;
      long a;
    { return (int)a * 100 + b * 10 + c; }

    /* 6.9.1p6: an identifier the declaration-list leaves out has type int. */
    int defaulted(a, b)
      int b;
    { return a * 100 + b; }

    /* 6.7.6.3p7-8: an array parameter adjusts to a pointer, a function
       parameter to a pointer to that function -- exactly as in a prototype. */
    int through_array(a)
      int a[10];
    { return a[1] + (int)sizeof(a); }

    int through_function(f, n)
      int f(int);
      int n;
    { return f(n); }

    int by_value(p)
      struct pair p;
    { return p.x * 10 + p.y; }

    static int doubler(n) int n; { return n * 2; }

    /* An old-style definition of a function returning a pointer to a function:
       the identifier list belongs to the buried declarator, not to the outer
       "(int)" suffix, which is an ordinary prototype. */
    int (*chooser(which))(int)
      int which;
    { return which ? doubler : 0; }

    int main(void) {
      int arr[10];
      struct pair p;
      int (*chosen)(int);

      arr[1] = 41;
      p.x = 3;
      p.y = 4;
      chosen = chooser(1);

      printf("%u %d %d\\n", knr_hash("A", 3), add(4, 5), spread(2L, 3, 4));
      printf("%d %d %d\\n", defaulted(2, 3), through_array(arr), through_function(doubler, 21));
      printf("%d %d\\n", by_value(p), chosen(9));
      return 0;
    }
  C

  # The default argument promotions, which are the whole reason an old-style
  # definition is not just a spelling. Each callee declares a type narrower than
  # the one it is passed, so a compiler that took the declared type as the ABI
  # type would read the wrong register (float) or fail to truncate (char).
  PROMOTIONS_SOURCE = <<~C
    #include <stdio.h>

    int take_char(c) char c; { return (int)c; }
    int take_schar(c) signed char c; { return (int)c; }
    int take_uchar(c) unsigned char c; { return (int)c; }
    int take_short(s) short s; { return (int)s; }
    int take_ushort(s) unsigned short s; { return (int)s; }
    int take_bool(b) _Bool b; { return (int)b; }
    double take_float(f) float f; { return (double)f; }
    double take_double(d) double d; { return d; }
    long take_long(l) long l; { return l; }
    unsigned long take_ulong(l) unsigned long l; { return l; }

    /* The declared (narrow) type is what the body sees, so sizeof reports it
       and an assignment through it truncates. */
    int declared_widths(c, s, f)
      char c;
      short s;
      float f;
    { return (int)(sizeof(c) * 100 + sizeof(s) * 10 + sizeof(f)); }

    int assign_through(c) char c; { c = c + 1; return (int)c; }
    int address_of(c) char c; { char *p = &c; *p = 9; return (int)c; }
    double narrow_then_widen(f) float f; { f = f / 3.0f; return (double)f; }

    /* Enough floating parameters to run past the registers the conventions hand
       out, so the promoted form has to be right on the stack too. */
    double many_floats(a, b, c, d, e, f, g, h, i, j)
      float a, b, c, d, e, f, g, h, i, j;
    { return (double)(a + b + c + d + e + f + g + h + i + j); }

    int main(void) {
      printf("%d %d %d\\n", take_char('A'), take_schar(-2), take_uchar(300));
      printf("%d %d %d\\n", take_short(-3), take_ushort(70000), take_bool(2));
      printf("%f %f\\n", take_float(1.5f), take_double(2.25));
      printf("%ld %lu\\n", take_long(1L << 40), take_ulong(~0UL));
      printf("%d %d %d\\n", declared_widths('a', 1, 1.0f), assign_through('A'), address_of('A'));
      printf("%f\\n", narrow_then_widen(1.0f));
      printf("%f\\n", many_floats(1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f, 9.0f, 10.0f));
      printf("%d %d\\n", take_char(300), take_bool(0));
      return 0;
    }
  C

  # An old-style definition of a name a prototype already declared (6.7.6.3p14).
  # gcc accepts each of these -- measured, including the two it warns about only
  # under -Wpedantic, where the prototype names the *unpromoted* declared type --
  # and passes the arguments in the prototype's form.
  WITH_PROTOTYPE_SOURCE = <<~C
    #include <stdio.h>

    /* Conforming: each prototype parameter is the promoted declared type. */
    int both_int(int, int);
    int both_int(a, b) int a; int b; { return a + b; }

    int promoted_char(int);
    int promoted_char(c) char c; { return (int)c; }

    double promoted_float(double);
    double promoted_float(f) float f; { return (double)f; }

    /* gcc's extension: the prototype names the declared type itself, so the
       argument arrives unpromoted and the definition must receive it that way. */
    int narrow_char(char);
    int narrow_char(c) char c; { return (int)c; }

    double narrow_float(float);
    double narrow_float(f) float f; { return (double)f; }

    int main(void) {
      printf("%d %d %f\\n", both_int(2, 3), promoted_char('A'), promoted_float(1.5f));
      printf("%d %f\\n", narrow_char('B'), narrow_float(2.5f));
      return 0;
    }
  C

  # The callee side alone, so it can be built by one compiler and called by the
  # other. A placement bug is invisible when the same compiler builds both ends.
  CROSS_CALLEE_SOURCE = <<~C
    double scale_float(f) float f; { return (double)f * 2.0; }
    int bump_char(c) char c; { return (int)c + 1; }
    int sum_floats(a, b, c, d, e, f, g, h, i, j)
      float a, b, c, d, e, f, g, h, i, j;
    { return (int)(a + b + c + d + e + f + g + h + i + j); }
  C

  # The caller declares each callee unprototyped, which is what makes its
  # arguments promoted -- the very form the definitions above receive.
  CROSS_CALLER_SOURCE = <<~C
    #include <stdio.h>
    double scale_float();
    int bump_char();
    int sum_floats();
    int main(void) {
      printf("%f %d %d\\n", scale_float(1.5f), bump_char('A'),
             sum_floats(1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f, 9.0f, 10.0f));
      return 0;
    }
  C

  # Constraint violations, each with the wording that must name what went wrong.
  # gcc rejects all but the last two, which it accepts with a warning; this
  # compiler models no unprototyped function type, so reading "int f(a, b);" as
  # "int f()" would give the name a "(void)" signature and then check every call
  # against it -- a confident wrong diagnosis in place of an accurate one.
  REFUSED = {
    "int f(a, b) int a; int q; { return a; }" =>
      /declaration for 'q', which is not a parameter/,
    "int f(a, b) int a; int a; int b; { return a; }" =>
      /redefinition of parameter 'a'/,
    "int f(a, a) int a; { return a; }" =>
      /duplicate parameter name 'a'/,
    "int f(a) static int a; { return a; }" => /'static' is not allowed here/,
    "int f(a) extern int a; { return a; }" => /'extern' is not allowed here/,
    "int f(a) typedef int a; { return 0; }" => /'typedef' is not allowed here/,
    "int f(a) auto int a; { return a; }" => /'auto' is not allowed here/,
    "int f(a) inline int a; { return a; }" => /'inline' is not allowed here/,
    "int f(a) int a = 1; { return a; }" => /parameter 'a' must not be initialized/,
    "int f(a) void a; { return 0; }" => /variable or field declared void/,
    "int f(a) _Alignas(8) int a; { return a; }" => /alignment specified for parameter 'a'/,
    "int f(a) int a; " => /expected a parameter declaration or '\{'/,
    "int f(x);" => /only allowed in a function definition/,
    "int (*g)(a, b);" => /only allowed in a function definition/,
    "typedef int F(a, b);" => /only allowed in a function definition/,
    "struct s { int m(a, b); };" => /only allowed in a function definition/,
    "int h(int g(a, b));" => /only allowed in a function definition/,
    "int f(a, b) int a; int b; { return a; }\nint g(void) { int q(c, d); return 0; }" =>
      /only allowed in a function definition/
  }.freeze

  # Where the definition and an earlier prototype genuinely disagree. gcc
  # rejects each of these too ("argument 'a' doesn't match prototype", "number of
  # arguments doesn't match prototype"); the wording here is this compiler's own
  # cross-declaration check, which compares the promoted parameter types.
  CONFLICTING_PROTOTYPES = [
    "int f(long); int f(a) int a; { return a; }",
    "int f(char); int f(a) int a; { return a; }",
    "int f(unsigned); int f(a) int a; { return a; }",
    "int f(int, int); int f(a) int a; { return a; }"
  ].freeze

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  def test_definitions_match_gcc
    assert_matches_gcc(DEFINITIONS_SOURCE, "knr_definitions")
  end

  def test_default_argument_promotions_match_gcc
    assert_matches_gcc(PROMOTIONS_SOURCE, "knr_promotions")
  end

  def test_definitions_with_a_visible_prototype_match_gcc
    assert_matches_gcc(WITH_PROTOTYPE_SOURCE, "knr_with_prototype")
  end

  # The promoted parameter types are an ABI contract, so they are checked across
  # a compiler boundary in both directions: rubycc's definition called by gcc's
  # code, and gcc's definition called by rubycc's.
  def test_promoted_parameters_interoperate_with_gcc_in_both_directions
    rubycc_callee = link_units_and_run([[CROSS_CALLEE_SOURCE, :rubycc], [CROSS_CALLER_SOURCE, :gcc]])
    gcc_callee = link_units_and_run([[CROSS_CALLEE_SOURCE, :gcc], [CROSS_CALLER_SOURCE, :gcc]])

    assert_equal gcc_callee, rubycc_callee,
                 "a rubycc-built old-style definition must receive what a gcc caller sends"
  end

  # An empty "()" is an empty identifier list, and this compiler's existing
  # treatment of it -- a function with no parameters -- is deliberately left
  # alone: nothing here turns "int f() { }" into an unprototyped function.
  def test_empty_parameter_list_keeps_its_existing_meaning
    assert_c_program("int f() { return 3; }\nint main(void) { return f(); }\n", exit_status: 3)

    error = assert_raises(Rubycc::CompileError) do
      compile("int f() { return 3; }\nint main(void) { return f(1); }\n")
    end
    assert_match(/too many arguments/, error.message)
  end

  def test_constraint_violations_are_diagnosed
    REFUSED.each do |source, pattern|
      error = assert_raises(Rubycc::CompileError, "expected #{source.inspect} to be refused") do
        compile(source)
      end
      assert_match(pattern, error.message, "wrong diagnostic for #{source.inspect}")
    end
  end

  def test_definitions_conflicting_with_a_prototype_are_diagnosed
    CONFLICTING_PROTOTYPES.each do |source|
      error = assert_raises(Rubycc::CompileError, "expected #{source.inspect} to be refused") do
        compile(source)
      end
      assert_match(/conflicting types for 'f'/, error.message)
    end
  end

  # The header that motivated the whole step: gperf's output, taken verbatim
  # from mysql2's bundled ext/mysql2/mysql_enc_name_to_ruby.h down to the
  # `__inline` and the `register` parameters. Its lookup is a pure function, so
  # gcc is the oracle for the answers.
  GPERF_SHAPED_SOURCE = <<~C
    #include <stdio.h>
    #include <string.h>

    struct enc_map { const char *name; const char *rb_name; };

    #ifdef __GNUC__
    __inline
    #if defined __GNUC_STDC_INLINE__ || defined __GNUC_GNU_INLINE__
    __attribute__ ((__gnu_inline__))
    #endif
    #endif
    static unsigned int
    enc_hash (str, len)
         register const char *str;
         register unsigned int len;
    {
      static const unsigned char asso_values[] =
        { 5, 3, 9, 1, 7, 2, 8, 4, 6, 0 };
      return len + asso_values[(unsigned char)str[0] % 10] +
             asso_values[(unsigned char)str[len - 1] % 10];
    }

    #ifdef __GNUC__
    __inline
    #if defined __GNUC_STDC_INLINE__ || defined __GNUC_GNU_INLINE__
    __attribute__ ((__gnu_inline__))
    #endif
    #endif
    const struct enc_map *
    enc_lookup (str, len)
         register const char *str;
         register unsigned int len;
    {
      static const struct enc_map wordlist[] =
        {
          { "big5", "Big5" },
          { "latin1", "ISO-8859-1" },
          { "utf8", "UTF-8" },
          { "utf8mb4", "UTF-8" }
        };
      register unsigned int i;
      register unsigned int key = enc_hash (str, len);

      for (i = 0; i < 4; i++)
        if (strlen (wordlist[i].name) == len && strncmp (wordlist[i].name, str, len) == 0)
          return &wordlist[i];
      return (const struct enc_map *)(key == 0 ? 0 : 0);
    }

    int main(void) {
      const char *names[5];
      int i;

      names[0] = "utf8";
      names[1] = "latin1";
      names[2] = "big5";
      names[3] = "utf8mb4";
      names[4] = "nosuch";
      for (i = 0; i < 5; i++) {
        const struct enc_map *m = enc_lookup(names[i], (unsigned int)strlen(names[i]));
        printf("%s -> %s (%u)\\n", names[i], m ? m->rb_name : "(none)",
               enc_hash(names[i], (unsigned int)strlen(names[i])));
      }
      return 0;
    }
  C

  def test_gperf_shaped_header_matches_gcc
    assert_matches_gcc(GPERF_SHAPED_SOURCE, "knr_gperf_shaped")
  end

  def test_aarch64_definitions_match_gcc
    assert_aarch64_matches_gcc(DEFINITIONS_SOURCE)
  end

  def test_aarch64_default_argument_promotions_match_gcc
    assert_aarch64_matches_gcc(PROMOTIONS_SOURCE)
  end

  def test_aarch64_definitions_with_a_visible_prototype_match_gcc
    assert_aarch64_matches_gcc(WITH_PROTOTYPE_SOURCE)
  end

  def test_aarch64_gperf_shaped_header_matches_gcc
    assert_aarch64_matches_gcc(GPERF_SHAPED_SOURCE)
  end

  # The aarch64 counterpart of the cross-compiler check above: AAPCS64 places a
  # promoted float in a vector register of its own, so a definition that read the
  # declared width instead would disagree with a cross-gcc caller.
  def test_aarch64_promoted_parameters_interoperate_with_gcc
    skip_unless_aarch64_toolchain

    rubycc_callee = link_units_and_run_aarch64([[CROSS_CALLEE_SOURCE, :rubycc],
                                                [CROSS_CALLER_SOURCE, :gcc]])
    gcc_callee = link_units_and_run_aarch64([[CROSS_CALLEE_SOURCE, :gcc],
                                             [CROSS_CALLER_SOURCE, :gcc]])

    assert_equal gcc_callee, rubycc_callee
  end

  private

  def compile(source)
    Rubycc::Compiler.new.compile(source, filename: "knr.c", target: host_target)
  end

  def run_source(source, compiler)
    in_tmpdir do |dir|
      object_path = File.join(dir, "knr.o")
      compile_source(source, object_path, compiler)
      link_and_run(object_path)
    end
  end

  def assert_matches_gcc(source, name)
    rubycc_status, rubycc_out = run_source(source, :rubycc)
    gcc_status, gcc_out = run_source(source, :gcc)

    assert_equal 0, rubycc_status, "rubycc-built #{name} exited #{rubycc_status}"
    assert_equal gcc_status, rubycc_status, "#{name}: exit status differs from gcc"
    assert_equal gcc_out, rubycc_out, "#{name}: output differs from gcc"
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
