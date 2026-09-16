# frozen_string_literal: true

require_relative "test_helper"

# An automatic object aligned more strictly than the frame provides
# (GAPS BW, issues/overaligned-automatic-object.md). A local asking for 32 or 64
# bytes used to be a diagnostic — the frame placed a stack object 16 bytes from
# a 16-byte-aligned base and a scalar in one cell of an 8-byte slot run, and
# neither backend could give it more — so this file is the acceptance test for
# the realigning prologue that replaced the diagnostic.
#
# What gcc 13.3 does on this host, measured 2026-09-16, is not one scheme but
# two, and rubycc matches the *placement* rather than either sequence:
#
#   x86-64: "pushq %rbp; movq %rsp,%rbp; andq $-32,%rsp; subq $N,%rsp", the
#     locals addressed from the masked rsp while rbp keeps the entry frame
#     pointer, so incoming stack arguments stay at 16(%rbp) and 24(%rbp) and a
#     va_list's overflow_arg_area at 16(%rbp); "leave" undoes it. With alloca
#     in the same function the mask moves ahead of the saved rbp instead
#     ("leaq 8(%rsp),%r10; andq $-32,%rsp; pushq -8(%r10); pushq %rbp;
#     movq %rsp,%rbp; pushq %r10"), and the exit is "movq -8(%rbp),%r10; leave;
#     leaq -8(%r10),%rsp".
#   aarch64: no realignment at all. The frame is over-allocated ("sub sp, sp,
#     #144" for a 64-aligned array of 32 bytes) and each over-aligned object's
#     address is rounded up at run time where it is taken ("add x0, sp, 144;
#     sub x0, x0, #80; add x0, x0, 31; lsr x0, x0, 6; lsl x0, x0, 6").
#
# rubycc realigns in the prologue on both targets instead (one scheme, both
# backends: the stack pointer is dropped past the frame plus one boundary,
# masked down to the boundary, and the entry stack pointer kept in a frame word
# that the incoming stack arguments, the va_list overflow pointer and the
# epilogue all read). Only the addresses and the values are observable, and
# those are what every case below reads back against gcc.
class TestOveralignedAutomaticObject < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  # The issue's own reproduction: a 32-byte scalar and a 32-byte aggregate in
  # main, printed as their address remainders and their values.
  REPRO_SOURCE = <<~C
    #include <stdio.h>
    int main(void) {
      _Alignas(32) long x = 1;
      struct s { long a, b; } __attribute__((aligned(32))) y;
      y.a = 2;
      printf("%d %d %ld %ld\\n", (int)((unsigned long)&x % 32 == 0),
             (int)((unsigned long)&y % 32 == 0), x, y.a);
      return 0;
    }
  C

  # Every shape the frame places differently, at every boundary past the one it
  # gives for free: a scalar (a virtual-register slot), a struct and an array (a
  # stack object), at 16, 32 and 64 bytes, in a plain function, in one that also
  # takes stack arguments, in a variadic one, in nested blocks and in a loop.
  # Each object's address is read modulo its boundary and each value is printed
  # too, so a frame that placed an object right but lost a stack argument, a
  # va_arg or a spilled temporary still shows a difference.
  PLACEMENT_SOURCE = <<~C
    #include <stdarg.h>
    #include <stdio.h>

    static int aligned_to(const void *p, unsigned long boundary) {
      return ((unsigned long)p % boundary) == 0;
    }

    static long scalars(long n) {
      _Alignas(16) int narrow = (int)n;
      _Alignas(32) long wide = n + 1;
      _Alignas(64) double real = 2.5;
      return narrow + wide + (long)real +
             1000L * aligned_to(&narrow, 16) +
             2000L * aligned_to(&wide, 32) +
             4000L * aligned_to(&real, 64);
    }

    static long aggregates(long n) {
      _Alignas(16) struct { long a, b; } small;
      _Alignas(32) struct { char c; } tiny;
      _Alignas(64) char text[20];
      _Alignas(32) long numbers[3] = { 1, 2, 3 };
      small.a = n;
      tiny.c = (char)n;
      text[0] = (char)(n + 1);
      return small.a + tiny.c + text[0] + numbers[2] +
             1000L * aligned_to(&small, 16) +
             2000L * aligned_to(&tiny, 32) +
             4000L * aligned_to(text, 64) +
             8000L * aligned_to(numbers, 32);
    }

    static long stacked(long a, long b, long c, long d, long e, long f, long g, long h) {
      _Alignas(64) long buf[4];
      buf[0] = a + h;
      buf[1] = g + f;
      buf[2] = e + d;
      buf[3] = c + b;
      return buf[0] + buf[1] + buf[2] + buf[3] + 1000L * aligned_to(buf, 64);
    }

    static long variable(int count, ...) {
      _Alignas(32) long seen[4];
      va_list ap;
      int i;
      va_start(ap, count);
      for (i = 0; i < count; i++) {
        seen[i] = va_arg(ap, long);
      }
      va_end(ap);
      return seen[0] + seen[1] + seen[2] + 1000L * aligned_to(seen, 32);
    }

    static long variable_stacked(long a, long b, long c, long d, long e, long f,
                                 long g, long h, ...) {
      _Alignas(64) long seen[2];
      va_list ap;
      va_start(ap, h);
      seen[0] = va_arg(ap, long);
      seen[1] = (long)va_arg(ap, double);
      va_end(ap);
      return a + g + h + seen[0] + seen[1] + 1000L * aligned_to(seen, 64);
    }

    static long nested(long n) {
      long total = 0;
      long i;
      {
        _Alignas(64) struct { long a, b; } inner;
        inner.a = n;
        total += inner.a + 1000L * aligned_to(&inner, 64);
      }
      {
        _Alignas(32) char buf[8];
        buf[0] = (char)n;
        total += buf[0] + 2000L * aligned_to(buf, 32);
      }
      for (i = 0; i < 3; i++) {
        _Alignas(32) long step[2];
        step[0] = i;
        step[1] = n;
        total += step[0] + step[1] + 4000L * aligned_to(step, 32);
      }
      return total;
    }

    int main(void) {
      printf("%ld %ld %ld\\n", scalars(5), aggregates(6), stacked(1, 2, 3, 4, 5, 6, 7, 8));
      printf("%ld %ld %ld\\n", variable(3, 10L, 20L, 30L),
             variable_stacked(1, 2, 3, 4, 5, 6, 7, 8, 9L, 10.0), nested(11));
      return 0;
    }
  C

  # A realigned frame doing everything else a frame does: making calls (with
  # stack arguments, and with a 32-byte-aligned aggregate whose own argument
  # area has to be rounded past 16), carving alloca blocks out of the stack,
  # returning a struct through a hidden pointer, recursing (which only comes
  # back if the epilogue puts the stack pointer back exactly), and holding more
  # live values than there are promotion registers.
  FRAME_CONSUMERS_SOURCE = <<~C
    #include <stdio.h>

    struct wide { long a, b, c, d; } __attribute__((aligned(32)));

    static int aligned_to(const void *p, unsigned long boundary) {
      return ((unsigned long)p % boundary) == 0;
    }

    static long consume(long a, long b, long c, long d, long e, long f, long g, long h) {
      return a + b + c + d + e + f + g + h;
    }

    static long take_wide(struct wide w, long tail) {
      return w.a + w.b + w.c + w.d + tail;
    }

    static struct wide make_wide(long n) {
      struct wide w;
      w.a = n;
      w.b = n + 1;
      w.c = n + 2;
      w.d = n + 3;
      return w;
    }

    static long calls(long n) {
      _Alignas(64) long buf[2];
      struct wide w = make_wide(n);
      buf[0] = consume(1, 2, 3, 4, 5, 6, 7, 8);
      buf[1] = take_wide(w, n);
      return buf[0] + buf[1] + 1000L * aligned_to(buf, 64) + 2000L * aligned_to(&w, 32);
    }

    static long dynamic(int n) {
      _Alignas(32) long fixed[2];
      char *block = (char *)__builtin_alloca(n);
      int i;
      for (i = 0; i < n; i++) {
        block[i] = (char)i;
      }
      fixed[0] = block[n - 1];
      fixed[1] = n;
      return fixed[0] + fixed[1] +
             1000L * aligned_to(fixed, 32) + 2000L * aligned_to(block, 16);
    }

    static long recurse(long n) {
      _Alignas(64) long here[2];
      here[0] = n;
      here[1] = aligned_to(here, 64);
      if (n <= 0) {
        return here[1];
      }
      return here[0] + here[1] + recurse(n - 1);
    }

    static long crowded(long n) {
      _Alignas(32) long anchor[2];
      long a = n + 1, b = n + 2, c = n + 3, d = n + 4;
      long e = n + 5, f = n + 6, g = n + 7, h = n + 8;
      long i = n + 9, j = n + 10, k = n + 11, l = n + 12;
      anchor[0] = a + b + c + d + e + f;
      anchor[1] = g + h + i + j + k + l;
      return anchor[0] + anchor[1] + a * 2 + l * 3 + 1000L * aligned_to(anchor, 32);
    }

    int main(void) {
      printf("%ld %ld %ld %ld\\n", calls(4), dynamic(40), recurse(6), crowded(2));
      return 0;
    }
  C

  def test_issue_reproduction_matches_gcc
    assert_matches_gcc(REPRO_SOURCE, "overaligned_repro")
  end

  def test_placements_match_gcc
    assert_matches_gcc(PLACEMENT_SOURCE, "overaligned_placement")
  end

  def test_frame_consumers_match_gcc
    assert_matches_gcc(FRAME_CONSUMERS_SOURCE, "overaligned_consumers")
  end

  def test_aarch64_issue_reproduction_matches_gcc
    assert_aarch64_matches_gcc(REPRO_SOURCE)
  end

  def test_aarch64_placements_match_gcc
    assert_aarch64_matches_gcc(PLACEMENT_SOURCE)
  end

  def test_aarch64_frame_consumers_match_gcc
    assert_aarch64_matches_gcc(FRAME_CONSUMERS_SOURCE)
  end

  # The frame's boundary is the strongest any one object asked for, and a
  # function that asks for nothing keeps the plain prologue: the IR carries the
  # request rather than the backend rediscovering it, so it is read back here.
  def test_frame_alignment_follows_the_strongest_request
    assert_equal 16, frame_alignment_of("int main(void) { long x = 1; return (int)x; }\n")
    assert_equal 32, frame_alignment_of("int main(void) { _Alignas(32) long x = 1; return (int)x; }\n")
    assert_equal 64, frame_alignment_of("int main(void) { _Alignas(32) long x = 1;\n" \
                                        "_Alignas(64) char b[4]; b[0] = 0; return (int)x + b[0]; }\n")
  end

  private

  # The IR::Function#frame_alignment of the first function in `source`.
  def frame_alignment_of(source)
    tokens = Rubycc::Front::Lexer.new(source, filename: "frame.c").tokenize
    ast = Rubycc::Front::Parser.new(tokens).parse
    Rubycc::IR::Generator.new.generate(ast).functions.first.frame_alignment
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
