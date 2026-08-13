# frozen_string_literal: true

require_relative "test_helper"

# The local IR rewrites (Rubycc::IR::Simplify). These are the transformations
# that take instructions *away* before a backend ever sees them, so a
# differential test cannot observe them at all — what it would observe is only
# that the answer is still right. What is asserted here is that the removals
# happen, and, at least as importantly, that the guards refuse the cases where
# they would be wrong.
class TestIRSimplify < Minitest::Test
  IR = Rubycc::IR
  Simplify = Rubycc::IR::Simplify

  def inst(op, **fields) = IR::Instruction.new(op, **fields)

  def function(insts, vregs: 16, params: 0)
    IR::Function.new("f", insts, vregs, params, [], :external, false, Array.new(params, :gp))
  end

  def shape(insts)
    insts.map { |i| [i.op, i.dst, i.a, i.b, i.size] }
  end

  # --- subscript fusion -----------------------------------------------------

  # "p[i]" arrives as a constant element size, a multiply of the index by it and
  # an add to the base. The multiply and the add become one :scaled_add carrying
  # the element size, and the constant, left with no reader, goes with them.
  def test_a_subscript_becomes_one_scaled_add
    result = Simplify.run(function([inst(:const, dst: 5, a: 4),
                                    inst(:mul, dst: 6, a: 4, b: 5, size: 8),
                                    inst(:add, dst: 7, a: 0, b: 6, size: 8),
                                    inst(:store, a: 7, b: 1, size: 4)]))
    assert_equal [[:scaled_add, 7, 0, 4, 4], [:store, nil, 7, 1, 4]], shape(result.insts)
  end

  # A stride the scale field cannot name (an array of a 12-byte struct) keeps
  # its multiply.
  def test_a_stride_that_is_not_a_power_of_two_keeps_its_multiply
    insts = [inst(:const, dst: 5, a: 12),
             inst(:mul, dst: 6, a: 4, b: 5, size: 8),
             inst(:add, dst: 7, a: 0, b: 6, size: 8),
             inst(:store, a: 7, b: 1, size: 4)]
    assert_equal shape(insts), shape(Simplify.run(function(insts)).insts)
  end

  # The product having a second reader means the multiply is wanted for its own
  # sake, so nothing is fused away.
  def test_a_product_read_twice_is_not_folded_into_the_add
    insts = [inst(:const, dst: 5, a: 4),
             inst(:mul, dst: 6, a: 4, b: 5, size: 8),
             inst(:add, dst: 7, a: 0, b: 6, size: 8),
             inst(:store, a: 7, b: 6, size: 8)]
    assert_equal shape(insts), shape(Simplify.run(function(insts)).insts)
  end

  # A "constant" whose slot address has been taken is no constant: a store
  # through that pointer can have replaced the value before the multiply runs.
  def test_a_constant_whose_address_is_taken_is_not_trusted
    insts = [inst(:const, dst: 5, a: 4),
             inst(:addr_of, dst: 8, a: 5),
             inst(:store, a: 8, b: 1, size: 8),
             inst(:mul, dst: 6, a: 4, b: 5, size: 8),
             inst(:add, dst: 7, a: 0, b: 6, size: 8),
             inst(:store, a: 7, b: 1, size: 4)]
    assert_equal shape(insts), shape(Simplify.run(function(insts)).insts)
  end

  # --- dead results ---------------------------------------------------------

  # The discarded value of a "i++" statement, and whatever fed it, fall out
  # together — one round of elimination exposing the next.
  def test_an_unread_result_and_its_feeders_are_dropped
    result = Simplify.run(function([inst(:sext, dst: 5, a: 0, size: 4),
                                    inst(:copy, dst: 6, a: 5),
                                    inst(:ret, a: 0)]))
    assert_equal [[:ret, nil, 0, nil, nil]], shape(result.insts)
  end

  # A division is not dropped however unread its result: a zero divisor traps,
  # and that is an effect. The same reasoning keeps loads, calls and stores.
  def test_a_trapping_or_faulting_instruction_stays_even_when_unread
    insts = [inst(:div, dst: 5, a: 0, b: 1),
             inst(:load, dst: 6, a: 0, size: 4),
             inst(:ret, a: 0)]
    assert_equal shape(insts), shape(Simplify.run(function(insts)).insts)
  end

  # --- copy forwarding ------------------------------------------------------

  # "T = a + b; V = T" becomes "V = a + b". It stays right when the producer
  # reads V as well, which is what an "i = i + 1" is.
  def test_a_single_use_copy_is_folded_into_its_producer
    result = Simplify.run(function([inst(:add, dst: 5, a: 4, b: 1),
                                    inst(:copy, dst: 4, a: 5),
                                    inst(:ret, a: 4)]))
    assert_equal [[:add, 4, 4, 1, nil], [:ret, nil, 4, nil, nil]], shape(result.insts)
  end

  # A temporary with a second reader is not folded away: the copy's destination
  # would then be the only place the value lived.
  def test_a_copy_of_a_twice_read_temporary_is_left_alone
    insts = [inst(:add, dst: 5, a: 4, b: 1),
             inst(:copy, dst: 6, a: 5),
             inst(:store, a: 0, b: 5, size: 8),
             inst(:ret, a: 6)]
    assert_equal shape(insts), shape(Simplify.run(function(insts)).insts)
  end

  # --- fail-safe ------------------------------------------------------------

  # An op the operand enumeration does not know about could be reading anything,
  # so the whole function is handed back untouched rather than rewritten on a
  # guess.
  def test_an_unknown_op_disables_the_pass_entirely
    insts = [inst(:sext, dst: 5, a: 0, size: 4), inst(:no_such_op, dst: 9, a: 5)]
    result = Simplify.run(function(insts))
    assert_same insts, result.insts
  end
end
