# frozen_string_literal: true

require_relative "test_helper"

# Step glibc-alloca-without-gnuc-1: `alloca` called under its libc name on the
# include path that reads the C library's own <alloca.h> instead of the bundled
# one.
#
# glibc's header maps the name onto __builtin_alloca only under __GNUC__, which
# rubycc does not define (DESIGN R7), so on that path the call stayed a call of
# a function named `alloca` -- a symbol no libc defines, so the program failed
# to link. The bundled header's own mapping is unconditional, which is why the
# default include order never showed this (test_header_abi.rb's STDLIB_GNU
# covers it) and the aarch64 example runner, which compiles against the cross
# sysroot with the bundled libc layer off, did.
#
# Every case here is measured against gcc, which reads glibc's header too and
# keeps its own builtin of that name: the point is not that alloca works, it is
# that rubycc and gcc agree about which declarations of the name are the
# allocator and which are an ordinary function that has to come from somewhere.
# The aarch64 half of the same path is covered by
# examples/m6/glibc_alloca_without_gnuc_1_stack_blocks.c under
# test_examples_aarch64.rb.
class TestGlibcAllocaWithoutGnuc < Minitest::Test
  include ExecutionHelper

  # The allocator reached the ordinary way: through <alloca.h>, under the
  # prototype the header declares. On the rubycc side of this file that header
  # is glibc's own (no macro, a bare declaration); on the gcc side it is glibc's
  # own with the macro, which is the behavior being matched.
  HEADER_SOURCE = <<~C
    #include <alloca.h>
    #include <stdio.h>
    static long fill(int n) {
      unsigned char *p = (unsigned char *)alloca((size_t)n);
      long sum = 0;
      int i;
      for (i = 0; i < n; i++) p[i] = (unsigned char)(i + 1);
      for (i = 0; i < n; i++) sum += p[i];
      printf("block %d %lu\\n", ((unsigned long)p % 16) == 0, (unsigned long)n);
      return sum;
    }
    int main(void) {
      printf("sum %ld\\n", fill(20) + fill(3));
      return 0;
    }
  C

  # The declaration autoconf's alloca probe leaves behind for a compiler without
  # __GNUC__ when it finds no <alloca.h>: no prototype, returning void *. gcc
  # takes it as the builtin (measured 2026-09-18, gcc 13.3 -std=gnu17), so the
  # header is deliberately not included here -- under it, `alloca` would be a
  # function-like macro on the gcc side and this declaration would not compile.
  UNPROTOTYPED_SOURCE = <<~C
    #include <stdio.h>
    extern void *alloca();
    int main(void) {
      char *p = (char *)alloca(24);
      p[0] = 6;
      p[23] = 7;
      printf("%d %d %d\\n", p[0], p[23], ((unsigned long)p % 16) == 0);
      return 0;
    }
  C

  # A declaration gcc refuses to take as its builtin: the parameter is narrower
  # than size_t, so gcc warns "conflicting types for built-in function" and
  # emits the call, which then finds no such symbol. rubycc declines the same
  # shape, so both end at the same undefined reference.
  NARROW_PARAMETER_SOURCE = <<~C
    #include <stdio.h>
    extern void *alloca(unsigned int);
    int main(void) {
      char *p = (char *)alloca(24);
      p[0] = 6;
      printf("%d\\n", p[0]);
      return 0;
    }
  C

  # An object named `alloca` hides the allocator, as it does under gcc. The
  # header is included to prove the name is still declared as a function at file
  # scope while the local object shadows it.
  SHADOWED_SOURCE = <<~C
    #include <alloca.h>
    #include <stdio.h>
    int main(void) {
      int alloca = 5;
      printf("%d\\n", alloca + 1);
      return 0;
    }
  C

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
    unless Rubycc::Compiler::TARGETS.key?(HostTarget.name)
      skip "host CPU #{HostTarget.name.inspect} is not a rubycc target"
    end
    missing = glibc_first_include_paths.reject { |path| File.directory?(path) }
    skip "libc headers are not installed (#{missing.join(", ")})" unless missing.empty?
  end

  # The case the issue was filed for: a call of the allocator whose only
  # declaration is glibc's own, with no macro in sight, runs exactly as it does
  # under gcc instead of failing to link.
  def test_alloca_through_the_glibc_header_runs_like_gcc
    assert_equal run_with_gcc(HEADER_SOURCE), run_glibc_first(HEADER_SOURCE),
                 "rubycc and gcc disagree on alloca through glibc's own <alloca.h>"
  end

  # The bundled header maps the name onto __builtin_alloca itself, so the
  # default include order never depended on the call-site recognition. It must
  # keep behaving exactly as it did.
  def test_alloca_through_the_bundled_header_runs_like_gcc
    in_tmpdir do |dir|
      object_path = compile_with_rubycc(HEADER_SOURCE, File.join(dir, "bundled.o"))
      assert_equal run_with_gcc(HEADER_SOURCE), link_and_run(object_path),
                   "rubycc and gcc disagree on alloca through the bundled <alloca.h>"
    end
  end

  def test_unprototyped_declaration_is_the_allocator_as_it_is_under_gcc
    assert_equal run_with_gcc(UNPROTOTYPED_SOURCE), run_glibc_first(UNPROTOTYPED_SOURCE),
                 "rubycc and gcc disagree on an unprototyped 'void *alloca();'"
  end

  # Declining the same declarations gcc declines is half the agreement: this one
  # must stay an ordinary call on both sides, and so must fail to link on both.
  def test_declaration_gcc_declines_stays_an_ordinary_call
    assert_equal :unresolved, run_with_gcc(NARROW_PARAMETER_SOURCE),
                 "gcc no longer leaves a narrow-parameter alloca for the linker"
    assert_equal :unresolved, run_glibc_first(NARROW_PARAMETER_SOURCE),
                 "rubycc took a declaration as the allocator that gcc does not"
  end

  def test_object_named_alloca_shadows_the_allocator
    assert_equal run_with_gcc(SHADOWED_SOURCE), run_glibc_first(SHADOWED_SOURCE),
                 "rubycc and gcc disagree on an object named 'alloca'"
  end

  private

  # The include path of a translation unit that reads the C library's own
  # headers and not the bundled libc layer: the bundled freestanding headers
  # (stddef.h and kin are the compiler's, not the C library's) followed by the
  # host libc's directories. It is the host-arch shape of the path the aarch64
  # runners use against the cross sysroot
  # (TestCSuiteAArch64::CROSS_SYSTEM_INCLUDE_PATHS), which is where the
  # undefined reference was first seen.
  def glibc_first_include_paths
    [Rubycc::Preprocess::Preprocessor::BUNDLED_INCLUDE_DIR,
     *Rubycc::Preprocess::Preprocessor.libc_system_include_paths_for(HostTarget.name)]
  end

  # Builds `source` on that path, links and runs it, and returns [exit status,
  # stdout] — or :unresolved when the object left behind a call of `alloca` the
  # linker cannot resolve, which is a result to compare rather than an error
  # (gcc produces it for some declarations too).
  def run_glibc_first(source)
    in_tmpdir do |dir|
      object_path = File.join(dir, "probe.o")
      binary = Rubycc::Diagnostics.to(nil) do
        Rubycc::Compiler.new.compile(source, filename: "probe.c", target: HostTarget.name,
                                             include_paths: glibc_first_include_paths,
                                             system_includes: false)
      end
      File.binwrite(object_path, binary)
      link_result(object_path)
    end
  end

  # The same program under gcc, which reads glibc's headers on its own default
  # path and is the reference for every case here.
  def run_with_gcc(source)
    in_tmpdir do |dir|
      link_result(compile_with_gcc(source, File.join(dir, "probe.o")))
    end
  end

  def link_result(object_path)
    link_and_run(object_path)
  rescue RuntimeError => e
    raise unless e.message.include?("undefined reference to `alloca'")

    :unresolved
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
