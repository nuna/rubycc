# frozen_string_literal: true

require_relative "test_helper"

# Differential execution tests for aarch64 variadic function definitions
# (M4 A4): the register-save-area prologue, the AAPCS64 :va_start seed and the
# __builtin_va_arg / __builtin_va_copy walks the generator lowers against the
# five-field __va_list tag.
#
# test_aarch64_backend.rb checks each instruction word against the Arm
# Architecture Reference Manual (ARM DDI 0487), but the AAPCS64 va_list is a
# structure whose semantics a correct encoding says nothing about: the offsets
# count *back* from the ends of the save areas and climb toward zero, the
# vector slots are 16 bytes wide where a stacked argument is 8, and a forwarded
# va_list is a pointer into the caller's frame. These tests decide those by
# running the code — the same source built for aarch64 by rubycc and by the
# cross gcc, both linked statically and run under qemu-aarch64, required to
# agree on exit status and stdout.
#
# Results go through printf, whose %d/%ld/%g put the whole value on the stream
# where the eight-bit exit status could not; a wrong slot therefore shows up as
# a differing digit rather than a masked one.
class TestAArch64VariadicExecution < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # Integer variable arguments read wholly from the register save area (three
  # fit) and then across into the stack overflow area (ten cross it): __gr_offs
  # climbs from its seed to zero and the walk switches to __stack.
  def test_integer_varargs_registers_and_overflow
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      long isum(int n, ...) {
        __builtin_va_list ap;
        __builtin_va_start(ap, n);
        long total = 0;
        for (int i = 0; i < n; i++) total += __builtin_va_arg(ap, int);
        __builtin_va_end(ap);
        return total;
      }
      int main(void) {
        printf("%ld\\n", isum(3, 10, 20, 30));
        printf("%ld\\n", isum(10, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10));
        printf("%ld\\n", isum(0));
        return 0;
      }
    C
  end

  # Double variable arguments, walking the vector save area (__vr_offs, 16-byte
  # slots) independently and then spilling to __stack (eight bytes each there).
  def test_double_varargs_registers_and_overflow
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      double dsum(int n, ...) {
        __builtin_va_list ap;
        __builtin_va_start(ap, n);
        double total = 0.0;
        for (int i = 0; i < n; i++) total += __builtin_va_arg(ap, double);
        __builtin_va_end(ap);
        return total;
      }
      int main(void) {
        printf("%g\\n", dsum(4, 2.0, 4.0, 6.0, 8.0));
        printf("%g\\n", dsum(10, 1., 2., 3., 4., 5., 6., 7., 8., 9., 10.));
        return 0;
      }
    C
  end

  # A mixed variable part: each va_arg(int) walks __gr_offs and each
  # va_arg(double) __vr_offs, the two counters advancing apart so neither
  # disturbs the other's slots.
  def test_mixed_integer_and_double_varargs
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      double blend(int n, ...) {
        __builtin_va_list ap;
        __builtin_va_start(ap, n);
        double total = 0.0;
        for (int i = 0; i < n; i++) {
          total += (double)__builtin_va_arg(ap, int);
          total += __builtin_va_arg(ap, double);
        }
        __builtin_va_end(ap);
        return total;
      }
      int main(void) {
        printf("%g\\n", blend(3, 1, 1.5, 2, 2.5, 3, 3.5));
        return 0;
      }
    C
  end

  # A va_list handed to a helper that takes a __builtin_va_list parameter: the
  # array decays to a pointer into the caller's frame, and the helper walks it
  # in place.
  def test_va_list_forwarded_to_helper
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      long vsum(int n, __builtin_va_list ap) {
        long total = 0;
        for (int i = 0; i < n; i++) total += __builtin_va_arg(ap, int);
        return total;
      }
      long forward(int n, ...) {
        __builtin_va_list ap;
        __builtin_va_start(ap, n);
        long result = vsum(n, ap);
        __builtin_va_end(ap);
        return result;
      }
      int main(void) {
        printf("%ld\\n", forward(5, 100, 200, 300, 400, 500));
        return 0;
      }
    C
  end

  # __builtin_va_copy duplicates the traversal state so the same variable part
  # can be walked twice from the start.
  def test_va_copy_walks_twice
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      long twice(int n, ...) {
        __builtin_va_list ap, ap2;
        __builtin_va_start(ap, n);
        __builtin_va_copy(ap2, ap);
        long a = 0, b = 0;
        for (int i = 0; i < n; i++) a += __builtin_va_arg(ap, int);
        for (int i = 0; i < n; i++) b += __builtin_va_arg(ap2, int);
        __builtin_va_end(ap);
        __builtin_va_end(ap2);
        return a + b;
      }
      int main(void) {
        printf("%ld\\n", twice(4, 7, 8, 9, 10));
        return 0;
      }
    C
  end

  # Forwarding a started va_list to the libc vprintf: the decayed pointer is
  # exactly the by-reference argument AAPCS64 has vprintf read the list through.
  def test_va_list_forwarded_to_vprintf
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      void logline(const char *fmt, ...) {
        __builtin_va_list ap;
        __builtin_va_start(ap, fmt);
        vprintf(fmt, ap);
        __builtin_va_end(ap);
      }
      int main(void) {
        logline("%d and %s and %.2f\\n", 42, "hi", 3.14);
        logline("%ld %ld %ld %ld\\n", 1L, 2L, 3L, 4L);
        return 0;
      }
    C
  end

  # Seven fixed integer parameters consume x0..x6, so __gr_offs seeds past them
  # and the first variable argument comes from x7 (still a register) and the
  # next from the stack.
  def test_fixed_params_consume_registers_before_varargs
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      long tail(int a, int b, int c, int d, int e, int f, int g, ...) {
        __builtin_va_list ap;
        __builtin_va_start(ap, g);
        long total = a + b + c + d + e + f + g;
        total += __builtin_va_arg(ap, int);
        total += __builtin_va_arg(ap, int);
        total += __builtin_va_arg(ap, int);
        __builtin_va_end(ap);
        return total;
      }
      int main(void) {
        printf("%ld\\n", tail(1, 2, 3, 4, 5, 6, 7, 8, 9, 10));
        return 0;
      }
    C
  end

  # More than eight arguments in total, so the fixed part alone spills onto the
  # stack and the variable part follows it there — no register slot is left.
  def test_more_than_eight_arguments
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      long wide(int a, int b, int c, int d, int e, int f, int g, int h, int i, ...) {
        __builtin_va_list ap;
        __builtin_va_start(ap, i);
        long total = a + b + c + d + e + f + g + h + i;
        for (int k = 0; k < 3; k++) total += __builtin_va_arg(ap, int);
        __builtin_va_end(ap);
        return total;
      }
      int main(void) {
        printf("%ld\\n", wide(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12));
        return 0;
      }
    C
  end

  # <stdarg.h> spelling (va_list / va_start / va_arg / va_copy / va_end) rather
  # than the __builtin_ intrinsics, to check the bundled header maps onto them.
  def test_stdarg_header_spelling
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      #include <stdarg.h>
      long isum(int n, ...) {
        va_list ap, copy;
        va_start(ap, n);
        va_copy(copy, ap);
        long total = 0;
        for (int i = 0; i < n; i++) total += va_arg(ap, int);
        for (int i = 0; i < n; i++) total += va_arg(copy, int);
        va_end(ap);
        va_end(copy);
        return total;
      }
      int main(void) {
        printf("%ld\\n", isum(3, 10, 20, 30));
        return 0;
      }
    C
  end
end
