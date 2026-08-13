# frozen_string_literal: true

require_relative "test_helper"

# Encoding contracts of the x86-64 code generator that an end-to-end GCC
# comparison cannot pin down, because several different instruction sequences
# compute the same answer and only one of them is the one intended.
#
# Two groups live here. The first is a genuine correctness contract the machine
# forces (the conversion instruction's width). The rest are the spill-traffic
# rules: which loads and stores the backend is expected *not* to emit. A
# differential test cannot see those at all — code that reloads every value is
# perfectly correct, merely slow — so the byte sequences are asserted directly,
# each written out from the Intel SDM's encoding of the instruction meant.
class TestX86_64Backend < Minitest::Test
  Backend = Rubycc::Backend::X86_64
  IR = Rubycc::IR

  # The fixed prologue: push rbp (1) + mov rbp, rsp (3) + sub rsp, imm32 (7).
  PROLOGUE_BYTES = 11

  # A vreg's rbp-relative displacement, as a byte in a disp8 ModR/M.
  def slot(vreg) = (-8 * (vreg + 1)) & 0xFF

  def test_float_to_integer_selects_rex_w_only_when_the_signed_primitive_needs_it
    assert_equal [0xF2, 0x0F, 0x2C, 0xC0], conversion_bytes([4, true])
    assert_equal [0xF2, 0x48, 0x0F, 0x2C, 0xC0], conversion_bytes([4, false])
    assert_equal [0xF2, 0x48, 0x0F, 0x2C, 0xC0], conversion_bytes([8, true])
    assert_equal [0xF2, 0x0F, 0x2C, 0xC0], conversion_bytes([2, false])
  end

  # --- spill traffic --------------------------------------------------------

  # Two rules at once, on a body whose values all have a second reader so that
  # none of them is a transient (see below) and every store stays:
  #
  #   * a binary op's second operand is read out of its slot rather than staged
  #     through ecx — "add r32, r/m32" (03 /r) is the same addition as "add
  #     r/m32, r32" (01 /r) with the operands the other way round;
  #   * the subtraction that follows does not re-read vreg 2, the value being
  #     still in eax where the store took it from.
  def test_an_operand_is_read_from_its_slot_and_a_just_stored_value_is_not
    body = body_bytes([IR::Instruction.new(:add, dst: 2, a: 0, b: 1),
                       IR::Instruction.new(:sub, dst: 3, a: 2, b: 0),
                       IR::Instruction.new(:store, a: 3, b: 2, size: 8),
                       IR::Instruction.new(:store, a: 3, b: 2, size: 8)],
                      vregs: 4)
    assert_equal [0x48, 0x8B, 0x45, slot(0),  # mov rax, [rbp-8]      (vreg 0)
                  0x03, 0x45, slot(1),        # add eax, [rbp-16]     (vreg 1)
                  0x48, 0x89, 0x45, slot(2),  # mov [rbp-24], rax
                  0x2B, 0x45, slot(0),        # sub eax, [rbp-8]      (no reload of vreg 2)
                  0x48, 0x89, 0x45, slot(3)], # mov [rbp-32], rax
                 body.first(18)
  end

  # A value produced by one instruction and read by the next, with no other
  # reader, is never written to its slot at all. Here vreg 2's only reader is
  # the :store behind it, so the add's result stays in eax — and the store's
  # value operand has to be rescued into rcx before eax is refilled with the
  # destination address, which is the only way it can still be reached.
  def test_a_single_use_temporary_is_never_written_to_its_slot
    body = body_bytes([IR::Instruction.new(:add, dst: 2, a: 0, b: 1),
                       IR::Instruction.new(:store, a: 3, b: 2, size: 8)],
                      vregs: 4)
    assert_equal [0x48, 0x8B, 0x45, slot(0),  # mov rax, [rbp-8]
                  0x03, 0x45, slot(1),        # add eax, [rbp-16]   (vreg 2, unstored)
                  0x48, 0x89, 0xC1,           # mov rcx, rax
                  0x48, 0x8B, 0x45, slot(3),  # mov rax, [rbp-32]
                  0x48, 0x89, 0x08],          # mov [rax], rcx
                 body
  end

  # A subscript's "index * element size" plus the add to the base is one `lea`,
  # whose SIB byte carries the element size as a two-bit scale. The IR pass
  # hands the backend a single :scaled_add whose `size` is that width
  # (IR::Simplify); mod = 00 with rm = 100 selects the SIB form with no
  # displacement.
  def test_a_scaled_add_is_one_lea
    body = body_bytes([IR::Instruction.new(:scaled_add, dst: 2, a: 0, b: 1, size: 4),
                       IR::Instruction.new(:store, a: 2, b: 2, size: 8)],
                      vregs: 3)
    assert_equal [0x48, 0x8B, 0x45, slot(0),  # mov rax, [rbp-8]    (base)
                  0x48, 0x8B, 0x4D, slot(1),  # mov rcx, [rbp-16]   (index)
                  0x48, 0x8D, 0x04, 0x88],    # lea rax, [rax + rcx*4]
                 body.first(12)
  end

  # An eight-byte element scales by 8, the largest the SIB field can name.
  def test_a_scaled_add_scales_an_eightbyte_element_by_eight
    body = body_bytes([IR::Instruction.new(:scaled_add, dst: 2, a: 0, b: 1, size: 8),
                       IR::Instruction.new(:store, a: 2, b: 2, size: 8)],
                      vregs: 3)
    assert_equal [0x48, 0x8D, 0x04, 0xC8], body[8, 4] # lea rax, [rax + rcx*8]
  end

  # A branch on a condition that is not already in eax compares the slot
  # against zero in place (83 /7 with a sign-extended imm8) instead of loading
  # it to test it. Both read the same low four bytes.
  def test_a_branch_tests_its_condition_in_place
    body = body_bytes([IR::Instruction.new(:jump_if_zero, a: 0, b: 0),
                       IR::Instruction.new(:label, a: 0)],
                      vregs: 1)
    assert_equal [0x83, 0x7D, slot(0), 0x00,  # cmp dword [rbp-8], 0
                  0x0F, 0x84],                # je rel32
                 body.first(6)
  end

  # A floating op reads its second operand out of its slot too: all four scalar
  # arithmetic opcodes take an "xmm, xmm/m" pair, so the memory form is the same
  # instruction with a different ModR/M.
  def test_a_floating_op_reads_its_second_operand_from_its_slot
    body = body_bytes([IR::Instruction.new(:fmul, dst: 2, a: 0, b: 1, size: 8),
                       IR::Instruction.new(:store, a: 2, b: 2, size: 8)],
                      vregs: 3)
    assert_equal [0xF2, 0x0F, 0x10, 0x45, slot(0),  # movsd xmm0, [rbp-8]
                  0xF2, 0x0F, 0x59, 0x45, slot(1)], # mulsd xmm0, [rbp-16]
                 body.first(10)
  end

  private

  def function(insts, vregs:, params: 0)
    IR::Function.new("f", insts, vregs, params, [], :external, false, Array.new(params, :gp))
  end

  # The emitted bytes past the fixed prologue.
  def body_bytes(insts, vregs:, params: 0)
    Backend.new.compile(function(insts, vregs: vregs, params: params))
           .bytes.byteslice(PROLOGUE_BYTES..).bytes
  end

  def conversion_bytes(int_desc)
    # The fixed prologue is 16 bytes before the floating conversion's prefix:
    # push/mov/sub (11 bytes), then movsd xmm0,[rbp-8] (5 bytes). A REX.W
    # conversion is one byte longer than the 32-bit form.
    length = int_desc[0] == 8 || (int_desc == [4, false]) ? 5 : 4
    function = function([IR::Instruction.new(:ftoi, dst: 2, a: 0, b: int_desc, size: 8)], vregs: 3)
    Backend.new.compile(function).bytes.byteslice(16, length).bytes
  end
end
