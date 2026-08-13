# frozen_string_literal: true

require_relative "test_helper"

# Encoding contracts of the x86-64 code generator that an end-to-end GCC
# comparison cannot pin down, because several different instruction sequences
# compute the same answer and only one of them is the one intended: the
# conversion instruction's width, which the machine forces, and the address
# forming an IR :scaled_add is meant to become, which it does not (a multiply
# and an add compute the same address, merely slower). The byte sequences are
# asserted directly, each written out from the Intel SDM's encoding of the
# instruction meant.
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
