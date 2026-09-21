# frozen_string_literal: true

require_relative "test_helper"

# int128-typedef-spellings-1 (GAPS row CB): rubycc accepted `__int128` and
# `unsigned __int128` (a lexer keyword, lib/rubycc/front/lexeme_reader.rb:38)
# but not gcc's predefined typedef spellings `__int128_t` / `__uint128_t`. The
# issue's reproduction, measured 2026-09-18 on this host (WSL2 / gcc 13.3):
#
#   int main(void) { __int128 a = 1; unsigned __int128 b = 2; __int128_t c = 3;
#                     return (int)(a + b + c) - 6; }
#
#   gcc 13.3   ok
#   rubycc     error: expected ';' (at `__int128_t`)
#
# Measured again 2026-09-22 (same host) to settle whether the two names are
# predefined typedefs or a keyword's alias, and how they interact with
# ordinary typedef/tag/scope rules gcc already applies to every name:
#
#   typedef int __int128_t;                    -- accepted (even -Wall -Wextra
#                                                  -pedantic -Werror), despite
#                                                  naming a DIFFERENT type than
#                                                  __int128 itself
#   { typedef int __int128_t; ... }             -- accepted; shadows the outer
#                                                  (predefined) binding for the
#                                                  block, as any typedef would
#   struct __int128_t { int x; };                -- accepted; tags and typedef
#                                                  names are separate namespaces
#   typedef __int128 __int128_t;                 -- accepted (identical
#                                                  redeclaration, C's ordinary
#                                                  typedef rule)
#   typedef int __int128_t; typedef long __int128_t;
#                                                -- REJECTED: "conflicting
#                                                  types for '__int128_t'"
#
# So gcc predeclares `__int128_t`/`__uint128_t` as typedef names, but not as a
# real prior declaration: the first program-written typedef of the name wins
# silently regardless of type, and only a *second* redeclaration is checked
# for a conflict. This matches how `__builtin_va_list` is already predeclared
# (lib/rubycc/front/parser.rb); the fix pre-seeds the two /128_t names the same
# way, with a "weak" marker in the ordinary-scope entry so the first
# redeclaration replaces it unconditionally (see
# Parser#declare_typedef_name).
class TestInt128TypedefSpellings < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  def compile(source, filename: "foo.c")
    Rubycc::Compiler.new.compile(source, filename: filename, target: host_target)
  end

  # --- the issue's own reproduction, gcc-differential ----------------------

  REPRO = "int main(void) { __int128 a = 1; unsigned __int128 b = 2; __int128_t c = 3; " \
          "return (int)(a + b + c) - 6; }"

  def test_repro_matches_gcc_on_x86_64
    skip_unless_x86_64_host

    assert_c_exit_status(0, REPRO, compiler: :gcc)
    assert_c_exit_status(0, REPRO, compiler: :rubycc)
  end

  def test_repro_matches_gcc_on_aarch64
    skip_unless_aarch64_toolchain

    assert_aarch64_matches_gcc(REPRO)
  end

  # --- sizeof/_Alignof/arithmetic agree with __int128/unsigned __int128 ----

  # Both spellings must behave exactly like their keyword counterparts: same
  # size, same alignment, and interchangeable in arithmetic. Compared against
  # gcc rather than hardcoding 16/16, so a wrong width on either target would
  # still be caught.
  SIZE_AND_ARITHMETIC = <<~C
    int printf(const char *, ...);
    int main(void) {
      __int128_t a = 1;
      __uint128_t b = 2;
      __int128 c = 3;
      unsigned __int128 d = 4;
      printf("%d %d %d %d\\n", (int)sizeof(a), (int)sizeof(b),
             (int)_Alignof(__int128_t), (int)_Alignof(__uint128_t));
      __int128_t sum = a + b + c + d;
      return (int)sum - 10;
    }
  C

  def test_sizeof_alignof_and_arithmetic_match_int128_on_x86_64
    skip_unless_x86_64_host

    in_tmpdir do |dir|
      gcc_object = File.join(dir, "gcc.o")
      compile_with_gcc(SIZE_AND_ARITHMETIC, gcc_object)
      gcc_status, gcc_stdout = link_and_run(gcc_object)

      rubycc_object = File.join(dir, "rubycc.o")
      compile_with_rubycc(SIZE_AND_ARITHMETIC, rubycc_object)
      rubycc_status, rubycc_stdout = link_and_run(rubycc_object)

      assert_equal gcc_status, rubycc_status, "exit status mismatch"
      assert_equal gcc_stdout, rubycc_stdout, "stdout mismatch"
    end
  end

  def test_sizeof_alignof_and_arithmetic_match_int128_on_aarch64
    skip_unless_aarch64_toolchain

    assert_aarch64_matches_gcc(SIZE_AND_ARITHMETIC)
  end

  # --- the measured shadowing/redeclaration cases ---------------------------

  def test_typedef_int_int128_t_at_file_scope_is_accepted_like_gcc
    source = "typedef int __int128_t; int main(void) { __int128_t a = 5; return a - 5; }"
    assert_c_exit_status(0, source, compiler: :gcc)
    assert_c_exit_status(0, source, compiler: :rubycc)
  end

  def test_int128_t_can_be_shadowed_by_a_block_scope_typedef
    source = "int main(void) { typedef int __int128_t; __int128_t a = 5; return a - 5; }"
    assert_c_exit_status(0, source, compiler: :gcc)
    assert_c_exit_status(0, source, compiler: :rubycc)
  end

  def test_struct_tag_named_int128_t_is_unrelated_to_the_typedef
    source = "struct __int128_t { int x; }; " \
             "int main(void) { struct __int128_t s; s.x = 3; return s.x - 3; }"
    assert_c_exit_status(0, source, compiler: :gcc)
    assert_c_exit_status(0, source, compiler: :rubycc)
  end

  def test_identical_redeclaration_of_int128_t_is_allowed
    source = "typedef __int128 __int128_t; int main(void) { __int128_t a = 5; return (int)a - 5; }"
    assert_c_exit_status(0, source, compiler: :gcc)
    assert_c_exit_status(0, source, compiler: :rubycc)
  end

  def test_uint128_t_behaves_the_same_as_int128_t
    source = "typedef unsigned __int128 __uint128_t; " \
             "int main(void) { __uint128_t a = 5; return (int)a - 5; }"
    assert_c_exit_status(0, source, compiler: :gcc)
    assert_c_exit_status(0, source, compiler: :rubycc)
  end

  # A second redeclaration, after the first has already replaced the
  # predefined weak binding, is a genuine conflict on both compilers (measured
  # 2026-09-22: gcc reports "conflicting types for '__int128_t'").
  def test_second_redeclaration_to_a_different_type_is_rejected_like_gcc
    source = "typedef int __int128_t; typedef long __int128_t; int main(void) { return 0; }"

    in_tmpdir do |dir|
      source_path = File.join(dir, "t.c")
      File.write(source_path, source)
      _out, gcc_status = Open3.capture2e("gcc", "-c", ExecutionHelper::REFERENCE_STD_FLAG,
                                          "-o", File.join(dir, "t.o"), source_path)
      assert !gcc_status.success?, "expected gcc to reject the second, conflicting redeclaration"
    end

    error = assert_raises(Rubycc::CompileError) { compile(source) }
    assert_match(/redefinition of typedef '__int128_t'/, error.description)
  end

  # --- -target aarch64 must reach the glibc header the issue's regression ---
  # --- named (sys/ucontext.h -> sys/user.h's `__uint128_t vregs[32];`)    ---

  def test_target_aarch64_compiles_sys_ucontext_h_like_the_cross_gcc
    skip_unless_aarch64_cross_headers

    source = "#include <sys/ucontext.h>\nint main(void) { return 0; }\n"
    assert_aarch64_matches_gcc(source)
  end
end
