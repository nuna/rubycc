# frozen_string_literal: true

require_relative "test_helper"

# GAPS row BD (issues/unprototyped-function-pointer-compat.md): assigning a
# prototyped function pointer ("void (*)(int *, long)") to an old-style
# unprototyped one ("void (*)()") must be accepted, per C11 6.7.6.3p15 -- a
# function type with a parameter-type list and one declared with an empty
# identifier list that is not part of a function definition are compatible
# when the parameter list has no ellipsis and every parameter type is
# unchanged by the default argument promotions (6.5.2.2p6). gcc accepts the
# compatible cases with no warning at all (measured 2026-09-13, gcc 13.3,
# `-std=gnu11 -Wall -Wextra`).
#
# The incompatible combinations -- a parameter whose type *does* change under
# the default argument promotions (`char`, `short`, `float`), or a variadic
# prototype -- gcc only warns about (-Wincompatible-pointer-types, still exit
# 0; measured the same way, same date). That is the same
# constraint-violation-downgrade GAPS row AN documents for other pointer
# mismatches; this subset does not follow gcc there, so these stay hard
# errors here (see lib/rubycc/ir/generator.rb#function_types_compatible?).
#
# The real-world motivation is numo-narray 0.9.2.1's
# ext/numo/narray/ndloop.c, whose na_md_loop_t struct declares
# "void (*loop_func)();" and assigns a fully prototyped function pointer to
# it at ndloop.c:359 ("lp->loop_func = loop_func;"). Two more shapes from the
# same file, both covered below: ndloop.c:1297 calls the member directly and
# uncast ("(*(lp->loop_func))(nf, lp);"), which needs the arity check and
# type conversion skipped in favor of the default argument promotions
# (6.5.2.2p6), like a variadic call's variable part; ndloop.c:1275/1287
# compares it against a fully prototyped function designator with "=="
# ("if (lp->loop_func == loop_narray)"), which 6.5.9p2 allows between
# pointers to compatible types.
#
# 6.7.6.3p15 compatibility also has to hold everywhere two declarations of
# the *same* object are merged (6.2.7p3's composite type) — an object
# redeclared old-style and then with a real prototype, or vice versa, in
# either order, and a file-scope pointer initialized from a fully prototyped
# function. Adding the `prototyped` field to Type::FunctionType's Data
# equality made these fail with "conflicting types"/"incompatible types in
# initialization" (regressions caught in review, since Data equality no
# longer holds between "()" and "(void)"/a real prototype even when
# 6.7.6.3p15 makes them compatible); Type.composite and
# #function_address_constant now go through Type.function_types_compatible?
# instead of plain equality.
class TestUnprototypedFunctionPointerCompat < Minitest::Test
  include ExecutionHelper

  # The issue's own minimal repro, verbatim: a struct member declared
  # old-style ("void (*f)();"), assigned a fully prototyped function pointer
  # through a parameter, then called back through an explicit cast to the
  # full prototype.
  MINIMAL_REPRO = <<~C
    struct s { void (*f)(); };
    static void work(int *p, long n) { p[0] = (int)n; }
    void set(struct s *x, void (*lf)(int *, long)) { x->f = lf; }
    int run(void) { struct s x; int v = 0; set(&x, work); ((void (*)(int *, long))x.f)(&v, 7); return v; }
    int main(void) { return run(); }
  C

  # Both directions of the assignment (old-style <-> prototyped), plus
  # passing an old-style-typed value where a prototyped parameter is
  # expected, all through a struct member exactly like the gem's own code.
  BOTH_DIRECTIONS = <<~C
    struct s { void (*f)(); };
    static void work(int *p, long n) { p[0] = (int)n; }

    void call_proto(void (*proto)(int *, long), int *v) { proto(v, 11); }

    int main(void) {
      struct s x;
      x.f = work; /* forward: prototyped -> unprototyped */

      void (*proto)(int *, long) = x.f; /* reverse: unprototyped -> prototyped */
      int v1 = 0, v2 = 0;
      proto(&v1, 9);
      call_proto(x.f, &v2); /* argument passing: unprototyped value, prototyped parameter */
      return v1 + v2;
    }
  C

  # A prototyped function called through a pointer to the old-style
  # unprototyped type, with real arguments of every kind the default argument
  # promotions touch: an `int` and a pointer (unchanged), a `long` (unchanged,
  # already at or past `int`'s rank), a `char` (promotes to `int`) and a
  # `float` (promotes to `double`) -- the shape numo-narray's ndloop.c:1297
  # ("(*(lp->loop_func))(nf, lp);") exercises with two pointer arguments, and
  # the shape the issue's own minimal repro hid by casting back to the full
  # prototype before calling. `callee`'s real parameter types are exactly what
  # each argument's promoted type is, so a correct promotion here is the only
  # way the sum comes out right.
  MIXED_ARGUMENT_CALL = <<~C
    #include <stdio.h>

    static long callee(int a, int *b, long c, int d, double e) {
      return a + *b + c + d + (long)e;
    }

    long (*p)();

    int main(void) {
      int x = 10;
      char narrow = 3;
      float f = 2.5f;

      p = (long (*)())callee;
      /* Called directly through the unprototyped pointer, uncast, exactly
         like ndloop.c:1297 -- no arity check, default argument promotions. */
      printf("%ld\\n", p(1, &x, 100L, narrow, f));
      return 0;
    }
  C

  # ndloop.c:1275/1287's own shape: comparing the unprototyped member against
  # a fully prototyped function designator with "==" and "!=" (6.5.9p2:
  # pointers to compatible types compare).
  POINTER_EQUALITY = <<~C
    #include <stdio.h>

    struct s { void (*loop_func)(); };

    static void loop_narray(int *a, long *b) { *a += (int)*b; }
    static void other_func(int *a, long *b) { *a -= (int)*b; }

    int main(void) {
      struct s lp;
      lp.loop_func = loop_narray;

      printf("%d %d %d\\n", lp.loop_func == loop_narray, lp.loop_func != other_func,
             lp.loop_func == other_func);
      return 0;
    }
  C

  # A file-scope pointer initialized (not merely assigned) from a fully
  # prototyped function's address, old-style declared.
  FILE_SCOPE_INITIALIZER = <<~C
    #include <stdio.h>

    static void work(int *p, long n) { *p += (int)n; }

    void (*handler)() = work;

    int main(void) {
      int v = 1;
      ((void (*)(int *, long))handler)(&v, 4);
      printf("%d\\n", v);
      return 0;
    }
  C

  def setup
    skip "gcc unavailable (needed as the differential oracle)" unless tool?("gcc")
  end

  def test_minimal_repro_matches_gcc
    rubycc_status, rubycc_out = run_source(MINIMAL_REPRO, :rubycc)
    gcc_status, gcc_out = run_source(MINIMAL_REPRO, :gcc)

    assert_equal 7, gcc_status, "sanity: gcc's own run() should return 7"
    assert_equal gcc_status, rubycc_status, "run()'s result differs from gcc"
    assert_equal gcc_out, rubycc_out
  end

  def test_reverse_direction_and_argument_passing_match_gcc
    rubycc_status, rubycc_out = run_source(BOTH_DIRECTIONS, :rubycc)
    gcc_status, gcc_out = run_source(BOTH_DIRECTIONS, :gcc)

    assert_equal 20, gcc_status, "sanity: gcc's own program should return 9 + 11"
    assert_equal gcc_status, rubycc_status
    assert_equal gcc_out, rubycc_out
  end

  # A parameter type that the default argument promotions change (6.5.2.2p6:
  # char/short promote to int, float promotes to double) breaks the
  # 6.7.6.3p15 relaxation, so the assignment stays incompatible.
  def test_char_parameter_target_is_rejected
    assert_still_incompatible(<<~C)
      struct s { void (*f)(); };
      static void work(char c) { (void)c; }
      void set(struct s *x) { x->f = work; }
    C
  end

  def test_short_parameter_target_is_rejected
    assert_still_incompatible(<<~C)
      struct s { void (*f)(); };
      static void work(short c) { (void)c; }
      void set(struct s *x) { x->f = work; }
    C
  end

  def test_float_parameter_target_is_rejected
    assert_still_incompatible(<<~C)
      struct s { void (*f)(); };
      static void work(float c) { (void)c; }
      void set(struct s *x) { x->f = work; }
    C
  end

  # 6.7.6.3p15 explicitly excludes an ellipsis prototype from the relaxation.
  def test_ellipsis_prototype_target_is_rejected
    assert_still_incompatible(<<~C)
      struct s { void (*f)(); };
      static void work(int a, ...) { (void)a; }
      void set(struct s *x) { x->f = work; }
    C
  end

  # A parameter type the default argument promotions leave alone (a pointer,
  # a full-width integer) does not trip the same rejection -- only the
  # promotion-changing ones above do.
  def test_int_and_pointer_parameters_stay_accepted
    assert_c_program(<<~C, exit_status: 0)
      struct s { void (*f)(); };
      static void work(int *p, int n) { *p = n; }
      int main(void) {
        struct s x;
        x.f = work;
        int v;
        ((void (*)(int *, int))x.f)(&v, 5);
        return v == 5 ? 0 : 1;
      }
    C
  end

  # Two genuinely different *prototyped* function pointers (both sides have a
  # real parameter list, and they disagree) are unaffected by this fix --
  # GAPS row AN's own scope, left exactly as it was.
  def test_two_incompatible_prototypes_stay_rejected
    assert_still_incompatible(<<~C)
      static void work(int a) { (void)a; }
      void set(void (*lf)(long)) { (void)lf; }
      int main(void) { set(work); return 0; }
    C
  end

  # A call through a pointer to the old-style unprototyped function type
  # admits any number of arguments (there is no parameter-type list to check
  # arity against) and applies the default argument promotions to each one,
  # exactly like the variable part of a variadic call.
  def test_call_through_unprototyped_pointer_promotes_mixed_arguments_like_gcc
    rubycc_status, rubycc_out = run_source(MIXED_ARGUMENT_CALL, :rubycc)
    gcc_status, gcc_out = run_source(MIXED_ARGUMENT_CALL, :gcc)

    assert_equal 0, gcc_status, "sanity: gcc's own program should exit 0"
    assert_equal gcc_status, rubycc_status
    assert_equal gcc_out, rubycc_out
  end

  # "==" and "!=" between a pointer to the old-style unprototyped type and a
  # fully prototyped function designator (6.5.9p2: pointers to compatible
  # types), the numo-narray ndloop.c:1275/1287 shape.
  def test_pointer_equality_with_a_prototyped_function_designator_matches_gcc
    rubycc_status, rubycc_out = run_source(POINTER_EQUALITY, :rubycc)
    gcc_status, gcc_out = run_source(POINTER_EQUALITY, :gcc)

    assert_equal 0, gcc_status
    assert_equal gcc_status, rubycc_status
    assert_equal gcc_out, rubycc_out
  end

  # A file-scope pointer initializer (not just a later assignment) from a
  # fully prototyped function's address, old-style declared.
  def test_file_scope_initializer_from_a_prototyped_function_matches_gcc
    rubycc_status, rubycc_out = run_source(FILE_SCOPE_INITIALIZER, :rubycc)
    gcc_status, gcc_out = run_source(FILE_SCOPE_INITIALIZER, :gcc)

    assert_equal 0, gcc_status
    assert_equal gcc_status, rubycc_status
    assert_equal gcc_out, rubycc_out
  end

  # 6.2.7p3's composite type: two file-scope *object* (not function)
  # declarations of the same pointer-to-function variable, one old-style and
  # one with a real parameter list, in either order, merge into one object of
  # the prototyped type rather than conflicting. This is 6.7.6.3p15
  # compatibility applied at declaration-merge time, distinct from (and
  # requiring a separate fix from) the assignment/argument/return/comparison
  # checks the rest of this file covers.
  REDECLARATION_SOURCES = {
    # void (*p)(); void (*p)(void); -- unprototyped then an explicit
    # zero-parameter prototype.
    unprototyped_then_void: "void (*p)();\nvoid (*p)(void);\nint main(void) { return p == 0 ? 0 : 1; }\n",
    # A typedef to the unprototyped form, then a real prototype.
    typedef_then_prototype: "typedef int (*F)();\nF g;\nint (*g)(void);\n" \
                            "int main(void) { return g == 0 ? 0 : 1; }\n",
    # extern (unprototyped) then the defining declaration, with a
    # promotion-invariant parameter (int).
    extern_then_prototype: "extern int (*h)();\nint (*h)(int);\n" \
                           "int main(void) { return h == 0 ? 0 : 1; }\n",
    # The same pair in the opposite order.
    prototype_then_unprototyped: "int (*h)(int);\nextern int (*h)();\n" \
                                 "int main(void) { return h == 0 ? 0 : 1; }\n"
  }.freeze

  def test_redeclarations_across_prototyped_and_unprototyped_compile_like_gcc
    REDECLARATION_SOURCES.each_value do |source|
      assert_c_program(source, exit_status: 0)
    end
  end

  # The declaration-merge counterpart of test_two_incompatible_prototypes_stay_rejected:
  # two genuinely different prototypes for the same pointer object still
  # conflict.
  def test_redeclaration_of_two_incompatible_prototypes_stays_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("void (*p)(int);\nvoid (*p)(long);\nint main(void) { return 0; }\n")
    end
    assert_match(/conflicting types for 'p'/, error.description)
  end

  private

  def compile(source)
    Rubycc::Compiler.new.compile(source, filename: "unproto_fp.c", target: host_target)
  end

  def assert_still_incompatible(source)
    error = assert_raises(Rubycc::CompileError, "expected #{source.inspect} to be refused") do
      compile(source)
    end
    assert_match(/incompatible type/, error.description)
  end

  def run_source(source, compiler)
    in_tmpdir do |dir|
      object_path = File.join(dir, "unproto_fp.o")
      compile_source(source, object_path, compiler)
      link_and_run(object_path)
    end
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
