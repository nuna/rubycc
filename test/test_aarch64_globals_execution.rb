# frozen_string_literal: true

require_relative "test_helper"

# Differential execution tests for the aarch64 memory-access layer (M4 A3):
# global variables, global arrays and structs, pointers to globals, string
# literals, and their -fPIC/GOT counterparts.
#
# test_aarch64_execution.rb covers the A2 core (control flow, arithmetic,
# locals, direct calls) and predates string literals, so it reports wide
# values one digit at a time through a hand-rolled put_long. A3 adds the
# addressing instructions global/string/func references need — an adrp/add
# pair, or under -fPIC an adrp/ldr pair reading a GOT slot — which is also
# what makes printf reachable (it needs a format string). These tests lean on
# that directly: values go through printf's %d/%ld/%s/%c instead of a
# hand-rolled decimal writer, since exercising printf is itself part of what
# A3 is supposed to unlock.
#
# Every case follows the same differential shape as test_aarch64_execution.rb:
# the same C source is built for aarch64 by rubycc and by the cross gcc, both
# linked statically and run under qemu-aarch64, and the two runs must agree on
# exit status and stdout.
class TestAArch64GlobalsExecution < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # --- global variables ----------------------------------------------------

  def test_initialized_global_read_and_write
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int counter = 42;
      int main(void) {
        printf("%d\\n", counter);
        counter = counter + 8;
        printf("%d\\n", counter);
        counter = counter * 2;
        printf("%d\\n", counter);
        return counter & 255;
      }
    C
  end

  def test_uninitialized_global_is_zero_bss
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int untouched;
      int main(void) {
        printf("%d\\n", untouched);
        untouched = untouched + 5;
        printf("%d\\n", untouched);
        return untouched;
      }
    C
  end

  def test_static_global_has_internal_linkage_and_persists
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      static int hits = 0;
      void record(void) { hits = hits + 1; }
      int main(void) {
        record();
        record();
        record();
        printf("%d\\n", hits);
        return hits;
      }
    C
  end

  def test_const_global_participates_in_expressions
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      const int limit = 17;
      int scale = 3;
      int main(void) {
        int total = 0;
        int i;
        for (i = 0; i < limit; i = i + 1) { total = total + i * scale; }
        printf("%d %d\\n", limit, total);
        return total & 255;
      }
    C
  end

  def test_global_write_from_function_read_back_in_main
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      long balance = 1000;
      void deposit(long n) { balance = balance + n; }
      void withdraw(long n) { balance = balance - n; }
      int main(void) {
        deposit(250);
        withdraw(75);
        deposit(4000000000L);
        printf("%ld\\n", balance);
        return (int)(balance & 255);
      }
    C
  end

  # --- global arrays and structs -------------------------------------------

  def test_global_array_subscript_read_and_write
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int table[10];
      int main(void) {
        int i;
        int sum = 0;
        for (i = 0; i < 10; i = i + 1) { table[i] = i * i; }
        for (i = 0; i < 10; i = i + 1) { table[i] = table[i] - i; }
        for (i = 0; i < 10; i = i + 1) { sum = sum + table[i]; }
        printf("%d\\n", sum);
        return sum & 255;
      }
    C
  end

  def test_global_struct_member_access
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct Point { int x; int y; };
      struct Point origin = { 3, 4 };
      int main(void) {
        origin.x = origin.x + origin.y;
        origin.y = origin.y * 2;
        printf("%d %d\\n", origin.x, origin.y);
        return (origin.x + origin.y) & 255;
      }
    C
  end

  def test_global_array_of_structs_member_access
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      struct Rec { int a; long b; };
      struct Rec recs[3] = { {1, 10}, {2, 20}, {3, 30} };
      int main(void) {
        int i;
        long sum = 0;
        for (i = 0; i < 3; i = i + 1) { sum = sum + recs[i].a + recs[i].b; }
        recs[1].b = 999;
        sum = sum + recs[1].b;
        printf("%ld\\n", sum);
        return (int)(sum & 255);
      }
    C
  end

  # --- pointers --------------------------------------------------------------

  def test_global_pointer_variable
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int target = 99;
      int *ptr = &target;
      int main(void) {
        printf("%d\\n", *ptr);
        *ptr = *ptr + 1;
        printf("%d %d\\n", target, *ptr);
        return target & 255;
      }
    C
  end

  def test_pointer_to_global_array_read_write
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int arr[5] = { 1, 2, 3, 4, 5 };
      int *p = arr;
      int main(void) {
        int i;
        int sum = 0;
        for (i = 0; i < 5; i = i + 1) { *(p + i) = *(p + i) * 2; }
        for (i = 0; i < 5; i = i + 1) { sum = sum + arr[i]; }
        printf("%d\\n", sum);
        return sum & 255;
      }
    C
  end

  def test_function_pointer_address_comparison
    # Indirect calls are not part of A3, so this only compares addresses: a
    # function pointer variable is set to each function's own address and
    # compared for equality, never called through.
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      void f(void) {}
      void g(void) {}
      int main(void) {
        void (*a)(void) = f;
        void (*b)(void) = g;
        printf("%d %d %d\\n", a == b, a == f, b == g);
        return (a == f) + 2 * (b == g);
      }
    C
  end

  # --- string literals ---------------------------------------------------

  def test_printf_writes_string_literal
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        printf("hello, world\\n");
        return 0;
      }
    C
  end

  def test_char_pointer_assignment_from_string_literal
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        const char *msg = "assigned";
        printf("%s\\n", msg);
        msg = "reassigned";
        printf("%s\\n", msg);
        return 0;
      }
    C
  end

  def test_string_literal_subscript_access
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        printf("%c%c%c\\n", "abcdef"[0], "abcdef"[2], "abcdef"[5]);
        return "abcdef"[3];
      }
    C
  end

  def test_multiple_distinct_string_literals
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      static const char *first = "first";
      static const char *second = "second";
      int main(void) {
        printf("%s-%s\\n", first, second);
        printf("%s-%s\\n", "third", "fourth");
        return 0;
      }
    C
  end

  def test_identical_content_string_literals
    # Two literals with the same bytes need not share storage, but reading
    # through either one must observe the same content.
    assert_aarch64_matches_gcc(<<~C)
      #include <string.h>
      #include <stdio.h>
      int main(void) {
        const char *a = "same";
        const char *b = "same";
        printf("%d %d\\n", strcmp(a, b), a == b);
        return strcmp(a, b);
      }
    C
  end

  # --- -fPIC / GOT ---------------------------------------------------------

  def test_pic_matches_gcc_for_global_variable_access
    assert_aarch64_matches_gcc(<<~C, pic: true)
      #include <stdio.h>
      int counter = 42;
      static int hits = 0;
      void record(void) { hits = hits + 1; counter = counter + 1; }
      int main(void) {
        record();
        record();
        printf("%d %d\\n", counter, hits);
        return (counter + hits) & 255;
      }
    C
  end

  def test_pic_matches_gcc_for_pointer_to_global_array
    assert_aarch64_matches_gcc(<<~C, pic: true)
      #include <stdio.h>
      int arr[5] = { 1, 2, 3, 4, 5 };
      int *p = arr;
      int main(void) {
        int i;
        int sum = 0;
        for (i = 0; i < 5; i = i + 1) { *(p + i) = *(p + i) * 2; }
        for (i = 0; i < 5; i = i + 1) { sum = sum + arr[i]; }
        printf("%d\\n", sum);
        return sum & 255;
      }
    C
  end

  def test_pic_matches_gcc_for_string_literals
    assert_aarch64_matches_gcc(<<~C, pic: true)
      #include <stdio.h>
      int main(void) {
        printf("hello, pic world\\n");
        return 0;
      }
    C
  end

  def test_pic_extern_libc_global_goes_through_got
    # `stdout` is declared but not defined in this unit, so under -fPIC its
    # address is loaded from its GOT slot (an adrp/ldr pair) rather than
    # formed directly. Static linking resolves the slot at link time, but the
    # instruction sequence differs from the non-PIC case, which is what this
    # exercises.
    assert_aarch64_matches_gcc(<<~C, pic: true)
      #include <stdio.h>
      int main(void) {
        fprintf(stdout, "via got %d\\n", 7);
        return 0;
      }
    C
  end

  def test_pic_extern_function_address_goes_through_got
    # Taking the address of a function this unit does not define (printf,
    # declared by <stdio.h> but implemented in libc) also routes through the
    # GOT under -fPIC. This never calls through the pointer, only compares it.
    assert_aarch64_matches_gcc(<<~C, pic: true)
      #include <stdio.h>
      int (*fp)(const char *, ...);
      int main(void) {
        fp = printf;
        printf("%d\\n", fp != 0);
        return fp == 0;
      }
    C
  end

  # --- libc calls ----------------------------------------------------------

  def test_printf_format_specifiers
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void) {
        int i = -123;
        long l = 9876543210L;
        const char *s = "text";
        unsigned char c = 65;
        printf("%d %ld %s %c\\n", i, l, s, c);
        return 0;
      }
    C
  end

  def test_strlen_and_strcmp
    assert_aarch64_matches_gcc(<<~C)
      #include <string.h>
      #include <stdio.h>
      int main(void) {
        const char *words[4];
        int i;
        words[0] = "alpha";
        words[1] = "beta";
        words[2] = "alpha";
        words[3] = "";
        for (i = 0; i < 4; i = i + 1) {
          printf("%zu ", strlen(words[i]));
        }
        printf("\\n");
        printf("%d %d %d\\n", strcmp(words[0], words[1]) < 0,
               strcmp(words[0], words[2]) == 0, strcmp(words[1], words[0]) > 0);
        return (int)strlen(words[0]);
      }
    C
  end
end
