# frozen_string_literal: true

require_relative "test_helper"

# Whether an unnamed bit-field's declared type raises the alignment of the
# aggregate containing it is an ABI decision, not a language one: the x86-64
# System V psABI says "unnamed bit-fields' types do not affect the alignment of
# a structure", while AAPCS64 has every bit-field's container contribute. So
# `struct { int : 32; int : 32; }` is 8 bytes aligned to 1 on x86-64 and 8 bytes
# aligned to 4 on aarch64, and `struct { char c; long : 1; }` is 2/1 against
# 8/8 — the same source, two answers, both correct.
#
# rubycc had only the System V rule, which stayed invisible while there was one
# backend and surfaced the moment the c-testsuite and the sample programs were
# built for aarch64 (an unnamed-bit-field struct's _Alignof came out 1 where the
# cross gcc said 4). The layout rule is therefore selected by the target, like
# plain `char`'s signedness.
#
# The layers below mirror TestPlainCharSignedness: the layout layer asserts the
# rule directly on StructType, the x86-64 execution layer is the regression
# guard that the default target's answers did not move, and the aarch64 layer
# runs the same program through the cross toolchain against a gcc that applies
# the AAPCS64 rule.
class TestUnnamedBitfieldAlignment < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  Type = Rubycc::Type

  # Every shape where the two ABIs can disagree: unnamed fields alone, an
  # unnamed field wider than its named neighbour, a zero-width field (which
  # places nothing yet still carries its container's alignment under AAPCS64),
  # and a union, whose members all sit at offset 0 but whose alignment is
  # decided the same way. `struct I` is the control: a *named* bit-field raises
  # the alignment under both ABIs, so it must read the same on either side.
  # printf is declared by hand rather than pulled from <stdio.h>: the same
  # source is built for both targets, and the host's libc headers describe the
  # wrong ABI for the aarch64 half (see TestCSuiteAArch64).
  LAYOUT_PROBE_SOURCE = <<~C
    int printf(const char *format, ...);
    #define P(T) printf("%s %d/%d\\n", #T, (int)sizeof(T), (int)_Alignof(T));
    struct A { int : 32; int : 32; };
    struct B { char c; int : 32; };
    struct C { char c; int : 0; };
    struct D { char c; short : 9; };
    union  E { int : 32; };
    union  F { char c; int : 32; };
    struct G { char c; long : 1; };
    union  H { char c; int : 0; };
    struct I { int a : 3; };
    struct J { char c; int : 32; char d; };
    int main(void) {
      P(struct A) P(struct B) P(struct C) P(struct D) P(union E)
      P(union F) P(struct G) P(union H) P(struct I) P(struct J)
      return 0;
    }
  C

  # --- the layout layer -----------------------------------------------------

  def test_unnamed_bitfield_leaves_alignment_alone_under_system_v
    type = define_aggregate([[nil, Type::Int, 32], [nil, Type::Int, 32]],
                            unnamed_bitfields_align: false)
    assert_equal 8, type.size
    assert_equal 1, type.alignment
  end

  def test_unnamed_bitfield_raises_alignment_under_aapcs64
    type = define_aggregate([[nil, Type::Int, 32], [nil, Type::Int, 32]],
                            unnamed_bitfields_align: true)
    assert_equal 8, type.size
    assert_equal 4, type.alignment
  end

  def test_zero_width_bitfield_carries_its_container_alignment_under_aapcs64
    # A ":0" field places no bits at all, so only the alignment rule can tell
    # the two ABIs apart here: the size is 4 either way (the char, rounded up).
    members = [["c", Type::Char, nil], [nil, Type::Int, 0]]
    assert_equal 1, define_aggregate(members, unnamed_bitfields_align: false).alignment
    assert_equal 4, define_aggregate(members, unnamed_bitfields_align: true).alignment
  end

  def test_named_bitfield_raises_alignment_under_both_abis
    [false, true].each do |flag|
      type = define_aggregate([["a", Type::Int, 3]], unnamed_bitfields_align: flag)
      assert_equal 4, type.alignment, "a named bit-field's type always aligns its struct"
    end
  end

  def test_union_follows_the_same_rule
    members = [["c", Type::Char, nil], [nil, Type::Int, 32]]
    assert_equal 1, define_aggregate(members, kind: :union, unnamed_bitfields_align: false).alignment
    assert_equal 4, define_aggregate(members, kind: :union, unnamed_bitfields_align: true).alignment
  end

  # --- the x86-64 execution layer -------------------------------------------

  def test_x86_64_layout_still_matches_gcc
    skip_unless_x86_execution
    skip "gcc unavailable (needed to cross-check)" unless gcc?

    in_tmpdir do |dir|
      object_path = File.join(dir, "bf.o")
      binary = Rubycc::Compiler.new.compile(LAYOUT_PROBE_SOURCE, filename: "bf.c")
      File.binwrite(object_path, binary)
      rubycc_status, rubycc_out = link_and_run(object_path)

      gcc_status, gcc_out = link_and_run(compile_with_gcc(LAYOUT_PROBE_SOURCE,
                                                          File.join(dir, "bf_gcc.o")))

      assert_equal 0, rubycc_status
      assert_equal gcc_status, rubycc_status
      assert_equal gcc_out, rubycc_out, "x86-64 aggregate layout differs from gcc"
    end
  end

  # --- the aarch64 execution layer ------------------------------------------

  def test_aarch64_layout_matches_the_cross_gcc
    assert_aarch64_matches_gcc(LAYOUT_PROBE_SOURCE)
  end

  private

  # Builds and lays out one aggregate from [name, Type, bit_width] triples.
  def define_aggregate(members, kind: :struct, unnamed_bitfields_align: false)
    type = Type::StructType.new(nil, kind: kind)
    type.define(members, unnamed_bitfields_align: unnamed_bitfields_align)
    type
  end

  def gcc?
    system("gcc", "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
