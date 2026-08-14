# frozen_string_literal: true

require_relative "test_helper"

# Which virtual registers may be kept in a machine register for a whole function
# (Rubycc::IR::Promotion), and in what order they are worth it.
#
# Nothing here can be observed differentially: promoting a value, promoting a
# different one, or promoting none at all all compute the same answers. What a
# differential test *would* catch is the guards being too loose — a value whose
# address is taken, or one that travels through the vector register file, is
# wrong in a register, not merely slower — so each refusal is asserted here on
# its own, together with the ordering that decides which candidates the five
# available registers go to.
class TestIRPromotion < Minitest::Test
  IR = Rubycc::IR
  Promotion = Rubycc::IR::Promotion

  def inst(op, **fields) = IR::Instruction.new(op, **fields)

  def function(insts, vregs: 16, params: 0, variadic: false, kinds: nil)
    IR::Function.new("f", insts, vregs, params, [], :external, variadic,
                     kinds || Array.new(params, :gp))
  end

  def candidates(insts, **options) = Promotion.candidates(function(insts, **options))

  # --- eligibility ----------------------------------------------------------

  # The ordinary case: values read and written by integer instructions, none of
  # them a transient, are all candidates.
  def test_integer_values_are_candidates
    insts = [inst(:add, dst: 2, a: 0, b: 1),
             inst(:sub, dst: 3, a: 2, b: 0),
             inst(:store, a: 3, b: 2, size: 8)]
    assert_equal [2, 0, 1], candidates(insts)
  end

  # "&v" hands out the address of v's slot, and a read through that pointer
  # looks in the slot. A promoted value is not there.
  def test_a_value_whose_address_is_taken_is_refused
    insts = [inst(:addr_of, dst: 4, a: 0),
             inst(:store, a: 4, b: 1, size: 8),
             inst(:add, dst: 2, a: 0, b: 1),
             inst(:store, a: 3, b: 2, size: 8)]
    refute_includes candidates(insts), 0
    assert_includes candidates(insts), 1
  end

  # A floating value lives in the same slot an integer would, but every
  # instruction that computes with it moves it through an xmm register — and
  # System V has no callee-saved one to promote it into. Both ends of such an
  # instruction are refused, the operands and the result alike.
  def test_a_value_a_vector_op_touches_is_refused
    insts = [inst(:fmul, dst: 2, a: 0, b: 1, size: 8),
             inst(:store, a: 3, b: 2, size: 8)]
    assert_equal [3], candidates(insts)
  end

  # :itof reads a general-purpose register and writes a vector one (:ftoi is the
  # mirror image). Refusing the pair costs one candidate and saves a rule per op.
  def test_a_conversion_between_the_register_files_refuses_both_ends
    insts = [inst(:itof, dst: 2, a: 0, b: [4, true], size: 8),
             inst(:store, a: 3, b: 2, size: 8)]
    assert_equal [3], candidates(insts)
  end

  # A parameter that arrives in an xmm register is spilled to its slot with
  # movss/movsd, so it touches the vector file even where no op names it.
  def test_a_floating_parameter_is_refused
    insts = [inst(:store, a: 0, b: 1, size: 8)]
    assert_equal [0], candidates(insts, params: 2, kinds: %i[gp sse8])
  end

  # The same on both sides of a call: an argument passed in an xmm register is
  # loaded from its slot with movsd, and a float result is written back to its
  # destination's slot from xmm0.
  def test_a_floating_call_argument_and_result_are_refused
    insts = [inst(:call, dst: 4, a: "g", b: [[0, :gp], [1, :sse8]], size: [nil, :sse8]),
             inst(:add, dst: 5, a: 0, b: 1)]
    order = candidates(insts)
    assert_includes order, 0   # passed in an integer register
    refute_includes order, 1   # passed in xmm1
    refute_includes order, 4   # returned in xmm0
  end

  # A single-precision `float` result is written back with movss rather than
  # movsd, but VECTOR_KINDS names both, so it is refused the same way an
  # :sse8 result is.
  def test_a_single_precision_call_result_is_refused
    insts = [inst(:call, dst: 4, a: "g", b: [[0, :gp]], size: [nil, :sse4]),
             inst(:add, dst: 5, a: 0, b: 4)]
    refute_includes candidates(insts), 4
  end

  # A `float` parameter is spilled with movss instead of movsd, one width
  # short of the :sse8 case above, and refused the same way.
  def test_a_single_precision_parameter_is_refused
    insts = [inst(:store, a: 0, b: 1, size: 4)]
    assert_equal [0], candidates(insts, params: 2, kinds: %i[gp sse4])
  end

  # :sse16 is only ever caution — an AAPCS64 quad-precision `long double`
  # carries an address rather than a value on this target — but VECTOR_KINDS
  # names it too, so a parameter classified that way is refused like any
  # other vector kind.
  def test_a_quad_precision_parameter_kind_is_refused
    insts = [inst(:store, a: 0, b: 1, size: 8)]
    assert_equal [0], candidates(insts, params: 2, kinds: %i[gp sse16])
  end

  # :call_indirect classifies its arguments and its result exactly like
  # :call (the same generator-fixed :gp/:sse4/:sse8/:mem placement), so the
  # same refusals apply to a call through a function pointer.
  def test_a_floating_call_indirect_argument_and_result_are_refused
    insts = [inst(:call_indirect, dst: 4, a: 5, b: [[0, :gp], [1, :sse8]], size: [nil, :sse8]),
             inst(:add, dst: 6, a: 0, b: 1)]
    order = candidates(insts)
    assert_includes order, 0   # passed in an integer register
    refute_includes order, 1   # passed in xmm1
    refute_includes order, 4   # returned in xmm0
  end

  # A float/double return is read into xmm0 too; `size` is nil for an integer
  # return and an AbiPiece array for a struct, so only the width means vector.
  def test_a_floating_return_value_is_refused
    assert_empty candidates([inst(:ret, a: 0, size: 8)])
    assert_equal [0], candidates([inst(:ret, a: 0)])
  end

  # A variadic function's prologue spills the six integer argument registers
  # into a register-save area that no instruction in the list describes, so the
  # whole function is refused rather than reasoned about.
  def test_a_variadic_function_promotes_nothing
    insts = [inst(:add, dst: 2, a: 0, b: 1),
             inst(:store, a: 3, b: 2, size: 8)]
    assert_empty candidates(insts, params: 1, variadic: true)
    refute_empty candidates(insts, params: 1)
  end

  # The read enumeration has to be exhaustive — a missed read would leave a
  # value in a slot nothing ever writes — and an op it does not recognize means
  # it is not. Same fail-safe as IR::Simplify.
  def test_an_unknown_op_disables_the_whole_function
    assert_empty candidates([inst(:add, dst: 2, a: 0, b: 1), inst(:no_such_op, dst: 9, a: 2)])
  end

  # A transient never reaches its slot at all (its one reader is the instruction
  # right behind its producer), so promoting one would replace two instructions
  # that do not exist with two register moves that do — and spend a register.
  # Here vreg 2 has the most occurrences and is still not a candidate.
  def test_a_transient_is_not_worth_promoting
    insts = [inst(:add, dst: 2, a: 0, b: 1),
             inst(:store, a: 0, b: 2, size: 8)]
    assert_equal [0, 1], candidates(insts)
  end

  # --- ordering -------------------------------------------------------------

  # Reads and writes count the same, both being one slot access, so the value
  # touched most often comes first. (Vregs 4 and 5 are transients here and drop
  # out; 3, whose reader is two instructions along, stays.)
  def test_candidates_are_ordered_by_how_often_they_are_touched
    insts = [inst(:add, dst: 3, a: 0, b: 1),    # 0, 1, 3
             inst(:add, dst: 4, a: 0, b: 2),    # 0, 2, 4
             inst(:add, dst: 5, a: 3, b: 4),    # 3, 4, 5
             inst(:store, a: 5, b: 0, size: 8)] # 5, 0
    assert_equal [0, 3, 1, 2], candidates(insts)
  end

  # An occurrence between a label and a branch back to it is worth ten of one
  # outside, and an inner loop's is worth ten of the enclosing loop's. So the
  # value touched twice in the inner loop (200) leads the one touched once there
  # (100), then the one touched twice in the outer loop (20), and last the one
  # touched four times where no loop reaches it (4) — which static counting
  # alone would have put first.
  def test_an_occurrence_inside_a_loop_outweighs_one_outside
    insts = [inst(:store, a: 3, b: 3, size: 8),
             inst(:store, a: 3, b: 3, size: 8),
             inst(:label, a: 0),
             inst(:store, a: 2, b: 2, size: 8),
             inst(:label, a: 1),
             inst(:store, a: 0, b: 0, size: 8),
             inst(:jump_if_zero, a: 1, b: 1),   # back to label 1: the inner loop
             inst(:jump, a: 0)]                 # back to label 0: the outer one
    assert_equal [0, 1, 2, 3], candidates(insts)
  end

  # A branch to a label ahead of it is not a loop's back edge, so nothing it
  # jumps over is weighted.
  def test_a_forward_branch_weights_nothing
    insts = [inst(:jump_if_zero, a: 0, b: 0),
             inst(:store, a: 1, b: 1, size: 8),
             inst(:label, a: 0)]
    assert_equal [1, 0], candidates(insts)
  end

  # Equal counts are broken by virtual register number, so the choice is a
  # function of the instruction list and nothing else: the same source keeps
  # producing the same bytes (N4). Vreg 9 is touched twice and leads; the four
  # operands are touched once each and follow in numerical order.
  def test_ties_are_broken_by_register_number
    insts = [inst(:add, dst: 9, a: 7, b: 5),
             inst(:add, dst: 8, a: 6, b: 4),
             inst(:store, a: 9, b: 8, size: 8)]
    assert_equal [9, 4, 5, 6, 7], candidates(insts)
  end

  # The same instructions in the same order give the same answer object for
  # object, there being nothing in the choice that depends on a hash's iteration
  # order or on an object's identity.
  def test_the_choice_is_reproducible
    insts = [inst(:add, dst: 2, a: 0, b: 1),
             inst(:sub, dst: 3, a: 2, b: 1),
             inst(:store, a: 3, b: 2, size: 8)]
    rebuilt = insts.map { |i| inst(i.op, dst: i.dst, a: i.a, b: i.b, size: i.size) }
    assert_equal candidates(insts), candidates(rebuilt)
  end
end
