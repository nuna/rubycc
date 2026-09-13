# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/aarch64_execution_helper"

# builtin-strlen-2: the builtin prototypes the generator seeds (strlen, memcpy)
# must never conflict with the program's own declaration of the function.
#
# builtin-strlen-1 seeded "unsigned long strlen(char *)" with a hard-coded
# signed `char`, and #declare_function compared every later declaration against
# it as if the program had written it. Two shapes then failed (full `rake test`,
# 2026-09-14): a program declaring "int strlen(char *);" (c-testsuite 00025) on
# every target, and any "size_t strlen(const char *)" on aarch64, whose plain
# char is unsigned. gcc 13.3 accepts both, at most warning that the builtin was
# redeclared.
#
# gcc also keeps __builtin_strlen's own type after such a declaration: with
# "int strlen(char *);" in scope, sizeof __builtin_strlen(p) is 8 and
# "__builtin_strlen(p) - 6 > 0" is 1 for a 5-byte string, while a plain
# strlen(p) there is 4 and 0 (measured with gcc 13.3, 2026-09-14). The sources
# below print exactly those observations so the differential sees them.
class TestBuiltinStrlenSeed < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # c-testsuite 00025's declaration, then a plain call (the program's own int
  # signature) and a __builtin_strlen call (the builtin's unsigned long one).
  INT_DECLARATION_SOURCE = <<~C
    int printf(const char *, ...);
    int strlen(char *);
    int main(void) {
      char *p = "hello";
      printf("%d %d\\n", (int)sizeof(strlen(p)), (int)sizeof(__builtin_strlen(p)));
      printf("%d %d\\n", strlen(p) - 6 > 0, __builtin_strlen(p) - 6 > 0);
      printf("%d %lu\\n", strlen(p), __builtin_strlen(p + 1));
      return strlen(p) - 5;
    }
  C

  # The libc header's own shape: size_t and a const-qualified parameter, the
  # form glibc's string.h and rubycc's bundled one both declare.
  CONST_SIZE_T_DECLARATION_SOURCE = <<~C
    int printf(const char *, ...);
    typedef unsigned long size_t;
    size_t strlen(const char *__s);
    int main(void) {
      const char *p = "rubycc";
      char buf[4] = "abc";
      printf("%lu %lu %lu\\n", strlen(p), __builtin_strlen(p), __builtin_strlen(buf));
      return 0;
    }
  C

  # The same shape through the real header, as c-testsuite 00179/00180 and the
  # examples include it.
  STRING_H_SOURCE = <<~C
    #include <stdio.h>
    #include <string.h>
    int main(void) {
      char buf[8] = "abcdef";
      char *p = buf;
      printf("%zu %lu\\n", strlen(p), __builtin_strlen(p + 2));
      return 0;
    }
  C

  # No declaration of strlen at all: __builtin_strlen of a non-literal still
  # calls libc's strlen under the builtin prototype.
  NO_DECLARATION_SOURCE = <<~C
    int printf(const char *, ...);
    int main(void) {
      char buf[8] = "abcdef";
      char *p = buf;
      printf("%lu %d\\n", __builtin_strlen(p), (int)sizeof(__builtin_strlen(p)));
      return 0;
    }
  C

  # A program declaring memcpy with its own (odd but gcc-accepted) prototype:
  # the memcpy seed yields to it just as strlen's does, and __builtin_memcpy
  # still copies under the builtin's prototype.
  MEMCPY_DECLARATION_SOURCE = <<~C
    int printf(const char *, ...);
    char *memcpy(char *, char *, unsigned long);
    int main(void) {
      char src[4] = "xyz";
      char dst[4] = {0};
      char alt[4] = {0};
      __builtin_memcpy(dst, src, 4);
      memcpy(alt, src, 4);
      printf("%s %s\\n", dst, alt);
      return 0;
    }
  C

  DIFFERENTIAL_SOURCES = {
    "int_declaration" => INT_DECLARATION_SOURCE,
    "const_size_t_declaration" => CONST_SIZE_T_DECLARATION_SOURCE,
    "string_h" => STRING_H_SOURCE,
    "no_declaration" => NO_DECLARATION_SOURCE,
    "memcpy_declaration" => MEMCPY_DECLARATION_SOURCE
  }.freeze

  DIFFERENTIAL_SOURCES.each do |name, source|
    define_method("test_#{name}_matches_gcc_on_host") do
      skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")

      assert_matches_gcc(source, name)
    end

    # Compiling alone needs no cross toolchain, so the aarch64 regression (a
    # const char * declaration resolving to unsigned char) is checked on
    # every host; the run against the cross gcc follows where it is installed.
    define_method("test_#{name}_compiles_for_aarch64") do
      Rubycc::Compiler.new.compile(source, filename: "#{name}.c", target: "aarch64")
      pass
    end

    define_method("test_#{name}_matches_cross_gcc_on_aarch64") do
      assert_aarch64_matches_gcc(source)
    end
  end

  # The seed itself, reached by a plain strlen call with no declaration in
  # the unit. gcc 13.3 accepts this with an implicit-declaration warning but gcc
  # 14 rejects it by default, so it is checked against rubycc's own result, not
  # against gcc.
  def test_plain_call_without_declaration_uses_the_seed
    source = <<~C
      int main(void) {
        char *p = "hello";
        return strlen(p) == 5 && sizeof(strlen(p)) == 8 ? 0 : 1;
      }
    C
    assert_c_exit_status(0, source)
  end

  # Only the seed yields: once the program has declared strlen, a later
  # disagreeing redeclaration is the ordinary conflicting-types error.
  def test_redeclaration_after_user_declaration_still_checked
    source = <<~C
      int strlen(char *);
      unsigned long strlen(char *);
      int main(void) { return 0; }
    C
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(source, filename: "strlen_redeclared.c", target: host_target)
    end
    assert_match(/2:1: error: conflicting types for 'strlen'/, error.message)
  end

  # An agreeing redeclaration after the user's first one stays accepted.
  def test_agreeing_redeclaration_after_user_declaration_accepted
    source = <<~C
      int strlen(char *);
      int strlen(char *);
      int main(void) { char *p = "ab"; return strlen(p) - 2; }
    C
    assert_c_exit_status(0, source)
  end

  # The seed yields to a file-scope object of the name too (gcc 13.3 compiles
  # "int strlen = 7;" with only a warning, measured 2026-09-14); the builtin
  # keeps working because it never consults the program's declaration. Only
  # compiled: running it would call the object's address.
  def test_seed_yields_to_file_scope_object
    source = <<~C
      int strlen = 7;
      int main(void) { return strlen - 7 + (int)__builtin_strlen("ab"); }
    C
    [host_target, "aarch64"].uniq.each do |target|
      Rubycc::Compiler.new.compile(source, filename: "strlen_object.c", target: target)
    end
    pass
  end

  def assert_matches_gcc(source, name)
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      binary = Rubycc::Compiler.new.compile(source, filename: "#{name}.c", target: host_target)
      File.binwrite(rubycc_obj, binary)
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = compile_with_gcc(source, File.join(dir, "#{name}_gcc.o"))
      gcc_status, gcc_out = link_and_run(gcc_obj)

      assert_equal gcc_status, rubycc_status, "#{name}: exit status differs from gcc"
      assert_equal gcc_out, rubycc_out, "#{name}: output differs from gcc"
    end
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
