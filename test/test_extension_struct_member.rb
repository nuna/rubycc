# frozen_string_literal: true

require_relative "test_helper"

# extension-struct-member-1: a leading "__extension__" (a GNU marker that
# silences pedantic diagnostics; it has no semantic effect) prefixing a
# struct/union member declaration. The parser already skipped a run of these
# at the head of an external declaration and of a block-scope declaration, but
# not at the head of a struct/union member declaration, so
# "struct s { __extension__ unsigned long long int v; int w; };" was rejected
# ("expected type specifier") even though gcc accepts it (measured 2026-09-13,
# issues/extension-struct-member.md).
#
# glibc's <bits/atomic_wide_counter.h> (pulled in by <threads.h>) declares its
# member exactly this way, so this issue is also what kept <threads.h> from
# compiling under rubycc at all.
class TestExtensionStructMember < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # The issue's own repro: a leading "__extension__" on an ordinary struct
  # member. Both the member it prefixes and the member after it must land at
  # the offsets gcc puts them at.
  STRUCT_MEMBER_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>

    struct s { __extension__ unsigned long long int v; int w; };

    int main(void) {
      printf("%zu %zu %zu\\n", sizeof(struct s), offsetof(struct s, v), offsetof(struct s, w));
      return 0;
    }
  C

  # The same prefix on a union member (6.7.2.1's struct-declaration-list
  # production is shared by struct and union, but the layout consequence
  # differs: every union member starts at offset 0).
  UNION_MEMBER_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>

    union u { __extension__ unsigned long long int v; int w; };

    int main(void) {
      printf("%zu %zu %zu\\n", sizeof(union u), offsetof(union u, v), offsetof(union u, w));
      return 0;
    }
  C

  # The prefix on a member of a struct nested inside another struct, so the
  # fix must reach the member-declaration parse regardless of nesting depth.
  NESTED_STRUCT_MEMBER_SOURCE = <<~C
    #include <stddef.h>
    #include <stdio.h>

    struct outer {
      int pre;
      struct inner { __extension__ unsigned long long int v; int w; } nested;
      int post;
    };

    int main(void) {
      printf("%zu %zu %zu %zu\\n", sizeof(struct outer), offsetof(struct outer, pre),
             offsetof(struct outer, nested), offsetof(struct outer, post));
      printf("%zu %zu %zu\\n", sizeof(struct inner),
             offsetof(struct inner, v), offsetof(struct inner, w));
      return 0;
    }
  C

  # The issue's motivating consequence: a C11 <threads.h> program. glibc's
  # <threads.h> pulls in <bits/atomic_wide_counter.h>, whose struct member is
  # declared with a leading "__extension__" (bits/atomic_wide_counter.h:27);
  # before this fix, that header alone failed to compile under rubycc.
  THREADS_H_SOURCE = <<~C
    #include <threads.h>
    #include <stdio.h>

    static int worker(void *arg) {
      int *value = (int *)arg;
      *value = 42;
      return 0;
    }

    int main(void) {
      thrd_t t;
      int value = 0;
      if (thrd_create(&t, worker, &value) != thrd_success) {
        return 1;
      }
      int res;
      if (thrd_join(t, &res) != thrd_success) {
        return 1;
      }
      printf("%d\\n", value);
      return 0;
    }
  C

  def test_struct_member_with_extension_prefix_matches_gcc
    assert_matches_gcc(STRUCT_MEMBER_SOURCE, "extension_struct_member")
  end

  def test_union_member_with_extension_prefix_matches_gcc
    assert_matches_gcc(UNION_MEMBER_SOURCE, "extension_union_member")
  end

  def test_nested_struct_member_with_extension_prefix_matches_gcc
    assert_matches_gcc(NESTED_STRUCT_MEMBER_SOURCE, "extension_nested_struct_member")
  end

  # <threads.h> now compiles, links and runs to the same output as gcc
  # (measured 2026-09-13): both print "42", the value the worker thread wrote
  # before thrd_join rejoined it.
  def test_threads_h_program_matches_gcc
    assert_matches_gcc(THREADS_H_SOURCE, "extension_threads_h")
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
