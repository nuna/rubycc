# frozen_string_literal: true

require_relative "test_helper"

# GNU's zero-length array extension is used by pg's public structs. It differs
# from an ISO flexible array member (`[]`) in that the type is complete, but its
# storage contribution is zero and the member starts at the element alignment.
class TestZeroLengthArray < Minitest::Test
  include ExecutionHelper

  SOURCE = <<~C
    #include <stddef.h>
    struct packet { int size; int values[0]; };
    struct storage { struct packet packet; int tail; };
    _Static_assert(sizeof(struct packet) == 4, "zero array changes size");
    _Static_assert(offsetof(struct storage, tail) == 4, "zero array offset");
    int main(void) {
      struct storage s;
      s.packet.values[0] = 41;
      return s.tail == 41 ? 0 : 1;
    }
  C

  def test_zero_length_array_member_layout_and_access
    assert_c_program(SOURCE, exit_status: 0)
  end
end
