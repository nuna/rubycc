# frozen_string_literal: true

require_relative "test_helper"

# The x86 conversion instruction is signed-only. The IR keeps the C width, so
# the backend must select the 64-bit cvtt form specifically for unsigned int;
# this is an encoding contract, not something an end-to-end GCC comparison
# should be left to infer.
class TestX86_64Backend < Minitest::Test
  Backend = Rubycc::Backend::X86_64
  IR = Rubycc::IR

  def test_float_to_integer_selects_rex_w_only_when_the_signed_primitive_needs_it
    assert_equal [0xF2, 0x0F, 0x2C, 0xC0], conversion_bytes([4, true])
    assert_equal [0xF2, 0x48, 0x0F, 0x2C, 0xC0], conversion_bytes([4, false])
    assert_equal [0xF2, 0x48, 0x0F, 0x2C, 0xC0], conversion_bytes([8, true])
    assert_equal [0xF2, 0x0F, 0x2C, 0xC0], conversion_bytes([2, false])
  end

  private

  def conversion_bytes(int_desc)
    function = IR::Function.new(
      "f",
      [IR::Instruction.new(:ftoi, dst: 2, a: 0, b: int_desc, size: 8)],
      3,
      0,
      [],
      :external,
      false,
      []
    )
    # The fixed prologue is 16 bytes before the floating conversion's prefix:
    # push/mov/sub (11 bytes), then movsd xmm0,[rbp-8] (5 bytes). A REX.W
    # conversion is one byte longer than the 32-bit form.
    length = int_desc[0] == 8 || (int_desc == [4, false]) ? 5 : 4
    Backend.new.compile(function).bytes.byteslice(16, length).bytes
  end
end
