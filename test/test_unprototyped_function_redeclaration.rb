# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/aarch64_execution_helper"

# GAPS row BF (issues/unprototyped-function-redeclaration.md): a *named*
# function declared old-style ("int f();", unspecified parameters) and then
# redeclared or defined with a parameter-type list, or called with arguments
# before its prototyped definition, was refused ("conflicting types",
# "too many arguments"). gcc 13.3 accepts all three shapes (measured
# 2026-09-14, `-std=gnu11 -Wall -Wextra`, no diagnostics at all).
#
# The rule is C11 6.7.6.3p15 — the same one BD applied to pointers to
# function (test_unprototyped_function_pointer_compat.rb) — used through
# Type.composite: an old-style declaration and a prototype without "..."
# whose parameters the default argument promotions leave unchanged are
# compatible, and the name keeps the prototype (6.2.7p3). A call made while
# only the old-style declaration is visible takes the default argument
# promotions (6.5.2.2p6), like a call through a `T (*)()` pointer.
#
# gcc rejects every incompatible pairing as a hard "conflicting types" error
# (a parameter of type char/short/_Bool/float, a variadic prototype, a
# different return type), and "too many arguments" once a prototype is
# visible (measured the same day), so those stay errors here too.
class TestUnprototypedFunctionRedeclaration < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # The issue's first shape: an old-style declaration, then a definition
  # with a parameter.
  DEFINITION_AFTER_OLD_STYLE = <<~C
    #include <stdio.h>

    static int seen;
    void f();
    void f(int x) { seen = x; }

    int main(void) {
      f(41);
      printf("%d\\n", seen);
      return 0;
    }
  C

  # The second shape: old-style, then a prototype, then the definition.
  PROTOTYPE_BETWEEN = <<~C
    #include <stdio.h>

    int g();
    int g(int);
    int g(int x) { return x * 3; }

    int main(void) {
      printf("%d\\n", g(14));
      return 0;
    }
  C

  # The third shape: called with an argument while only the old-style
  # declaration is visible, defined with a prototype afterwards.
  CALL_BEFORE_DEFINITION = <<~C
    #include <stdio.h>

    int h();

    int use(void) { return h(3); }

    int h(int x) { return x + 100; }

    int main(void) {
      printf("%d %d\\n", use(), h(4));
      return 0;
    }
  C

  # Arguments whose type the default argument promotions change: char and
  # short arrive as int, float as double (in an SSE/FP register, with %al set
  # on x86-64 as for any unprototyped call). The later definition's parameter
  # types are exactly the promoted ones, so a missing promotion shows up as a
  # wrong sum.
  PROMOTED_ARGUMENTS = <<~C
    #include <stdio.h>

    double mix();

    double call_it(void) {
      char c = 3;
      short s = -4;
      float f = 2.5f;
      long l = 1000000000000L;
      int v = 7;
      return mix(c, s, f, l, &v);
    }

    double mix(int a, int b, double c, long d, int *e) {
      return a + b + c + (double)(d / 1000000000L) + *e;
    }

    int main(void) {
      printf("%.2f\\n", call_it());
      return 0;
    }
  C

  # A block-scope old-style declaration (it joins the same signature table)
  # used before the file-scope definition.
  BLOCK_SCOPE_DECLARATION = <<~C
    #include <stdio.h>

    int outer(void) {
      int twice();
      return twice(21);
    }

    int twice(int x) { return x * 2; }

    int main(void) {
      printf("%d\\n", outer());
      return 0;
    }
  C

  # An old-style declaration completed by an old-style (K&R) definition whose
  # parameter is narrow: the declaration-list's char promotes to int, which is
  # what the earlier call passes.
  KNR_DEFINITION = <<~C
    #include <stdio.h>

    int low();

    int use(void) { return low(300); }

    int low(a)
      char a;
    { return a; }

    int main(void) {
      printf("%d\\n", use());
      return 0;
    }
  C

  # The address of a function declared only old-style is a `T (*)()` value,
  # so it initializes a prototyped pointer (6.7.6.3p15) and a call through
  # that pointer is checked against the prototype.
  ADDRESS_OF_OLD_STYLE = <<~C
    #include <stdio.h>

    long scale();
    long (*scaler)(long, int) = scale;

    long scale(long v, int by) { return v * by; }

    int main(void) {
      long (*direct)(long, int) = scale;
      printf("%ld %ld\\n", scaler(6, 7), direct(5, 5));
      return 0;
    }
  C

  # The reverse order: a prototype, then the old-style form, which leaves the
  # prototype in force for the definition and every call.
  PROTOTYPE_THEN_OLD_STYLE = <<~C
    #include <stdio.h>

    int k(int, long);
    int k();
    int k(int a, long b) { return a - (int)b; }

    int main(void) {
      printf("%d\\n", k(50, 8L));
      return 0;
    }
  C

  # builtin-strlen-2's seed still yields to the program's first declaration,
  # now also when that declaration is old-style: the plain call goes through
  # the unprototyped declaration, while __builtin_strlen keeps its own fixed
  # prototype.
  BUILTIN_SEED_OLD_STYLE = <<~C
    #include <stdio.h>

    unsigned long strlen();

    int main(void) {
      char *p = "hello";
      printf("%lu %lu %d\\n", strlen(p), __builtin_strlen(p), (int)sizeof(__builtin_strlen(p)));
      return 0;
    }
  C

  DIFFERENTIAL_SOURCES = {
    "definition_after_old_style" => DEFINITION_AFTER_OLD_STYLE,
    "prototype_between" => PROTOTYPE_BETWEEN,
    "call_before_definition" => CALL_BEFORE_DEFINITION,
    "promoted_arguments" => PROMOTED_ARGUMENTS,
    "block_scope_declaration" => BLOCK_SCOPE_DECLARATION,
    "knr_definition" => KNR_DEFINITION,
    "address_of_old_style" => ADDRESS_OF_OLD_STYLE,
    "prototype_then_old_style" => PROTOTYPE_THEN_OLD_STYLE,
    "builtin_seed_old_style" => BUILTIN_SEED_OLD_STYLE
  }.freeze

  DIFFERENTIAL_SOURCES.each do |name, source|
    define_method("test_#{name}_matches_gcc_on_host") do
      skip "gcc unavailable (needed as the differential oracle)" unless tool?("gcc")

      assert_matches_gcc(source, name)
    end

    # Compiling alone needs no cross toolchain, so the aarch64 lowering of the
    # same shapes is exercised on every host; the run against the cross gcc
    # follows where it is installed.
    define_method("test_#{name}_compiles_for_aarch64") do
      Rubycc::Compiler.new.compile(source, filename: "#{name}.c", target: "aarch64")
      pass
    end

    define_method("test_#{name}_matches_cross_gcc_on_aarch64") do
      assert_aarch64_matches_gcc(source)
    end
  end

  # Pairings 6.7.6.3p15 does not make compatible. gcc 13.3 rejects each one
  # with "conflicting types for 'f'" (measured 2026-09-14), on the second
  # declaration's line.
  CONFLICTING_SOURCES = {
    "char_parameter" => "int f();\nint f(char);\n",
    "short_parameter" => "int f();\nint f(short);\n",
    "bool_parameter" => "int f();\nint f(_Bool);\n",
    "float_parameter" => "int f();\nint f(float);\n",
    "variadic_prototype" => "int f();\nint f(int, ...);\n",
    "variadic_prototype_no_int" => "int f();\nint f(const char *, ...);\n",
    "char_definition" => "int f();\nint f(char c) { return c; }\n",
    "char_prototype_first" => "int f(char);\nint f();\n",
    "return_type" => "int f();\nlong f(int);\n",
    "two_prototypes_through_old_style" => "int f();\nint f(int);\nint f(long);\n",
    "narrow_definition_after_call" => "int f();\nint g(void) { return f(1); }\nint f(unsigned char c) { return c; }\n"
  }.freeze

  CONFLICTING_SOURCES.each do |name, source|
    define_method("test_#{name}_stays_conflicting") do
      error = assert_raises(Rubycc::CompileError, "expected #{source.inspect} to be refused") do
        compile(source)
      end
      line = source.lines.size
      assert_match(/#{line}:\d+: error: conflicting types for 'f'/, error.message)
    end
  end

  # Once a prototype (or the definition) has been seen, the composite is
  # prototyped and a call with the wrong arity is refused — gcc 13.3 says
  # "too many arguments to function 'f'" for both shapes (measured 2026-09-14).
  def test_call_after_prototype_checks_arity
    error = assert_raises(Rubycc::CompileError) do
      compile("int f();\nint f(int);\nint g(void) { return f(1, 2); }\n")
    end
    assert_match(/too many arguments to function 'f'/, error.description)
  end

  def test_call_after_definition_checks_arity
    error = assert_raises(Rubycc::CompileError) do
      compile("int f();\nint f(int x) { return x; }\nint g(void) { return f(1, 2); }\n")
    end
    assert_match(/too many arguments to function 'f'/, error.description)
  end

  # A call before the prototype also checks nothing it cannot know: any
  # number of arguments is admitted (gcc accepts "f(1, 2.0f, (char)3)" after
  # "int f();" with no diagnostic, measured 2026-09-14).
  def test_call_with_any_arity_before_a_prototype_compiles
    compile("int f();\nint g(void) { return f(1, 2.0f, (char)3) + f(); }\n")
    pass
  end

  # A redefinition is still a redefinition even when the two definitions'
  # composite with an old-style declaration would be fine.
  def test_second_definition_still_redefinition
    error = assert_raises(Rubycc::CompileError) do
      compile("int f();\nint f(int x) { return x; }\nint f(int x) { return x; }\n")
    end
    assert_match(/3:\d+: error: redefinition of 'f'/, error.message)
  end

  # builtin-strlen-2: after the program's own old-style declaration of
  # strlen replaced the seed, a prototype with a different return type is an
  # ordinary conflict against *that* declaration, not against the seed.
  def test_builtin_seed_replaced_by_old_style_then_conflicting_prototype
    error = assert_raises(Rubycc::CompileError) do
      compile("int strlen();\nunsigned long strlen(char *);\n")
    end
    assert_match(/2:\d+: error: conflicting types for 'strlen'/, error.message)
  end

  private

  def compile(source, target: host_target)
    Rubycc::Compiler.new.compile(source, filename: "unproto_redecl.c", target: target)
  end

  def assert_matches_gcc(source, name)
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      compile_source(source, rubycc_obj, :rubycc)
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = File.join(dir, "#{name}_gcc.o")
      compile_source(source, gcc_obj, :gcc)
      gcc_status, gcc_out = link_and_run(gcc_obj)

      assert_equal 0, gcc_status, "#{name}: sanity — gcc's own program should exit 0"
      assert_equal gcc_status, rubycc_status, "#{name}: exit status differs from gcc"
      assert_equal gcc_out, rubycc_out, "#{name}: output differs from gcc"
    end
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
