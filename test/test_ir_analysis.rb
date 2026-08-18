# frozen_string_literal: true

require_relative "test_helper"

# The census IR::Analysis hands out after IR::Simplify has rewritten a
# function. Since c807f69, that census is not recomputed from the rewritten
# list — each rewrite updates the counts it is disturbing as it goes — so
# nothing here exercises the rewrites themselves (test_ir_simplify.rb already
# does that). What is asserted is the one invariant the differential update
# rests on: whatever IR::Analysis.simplified hands out for `reads`, `writes`
# and `transient` is exactly what counting the *rewritten* list from scratch
# would have given. The recount below is written independently of
# IR::Simplify's own counting code (Simplify.census, Simplify.transient_flags,
# Simplify.each_operand_vreg) — it walks each instruction's `dst` and operands
# itself — so a bug shared between the two would not cancel out.
class TestIRAnalysis < Minitest::Test
  IR = Rubycc::IR
  Analysis = Rubycc::IR::Analysis

  def inst(op, **fields) = IR::Instruction.new(op, **fields)

  def function(insts, vregs: 16, params: 0)
    IR::Function.new("f", insts, vregs, params, [], :external, false, Array.new(params, :gp))
  end

  def shape(insts)
    insts.map { |i| [i.op, i.dst, i.a, i.b, i.size] }
  end

  # --- an independent recount -------------------------------------------

  # The ops this file's test instructions use, and which of `a`/`b` each one
  # reads as a virtual register. Written from scratch rather than borrowed
  # from Simplify::OPERAND_SHAPES, on purpose.
  NAIVE_TWO_OPERAND_OPS = %i[add sub mul store scaled_add].freeze
  NAIVE_ONE_OPERAND_OPS = %i[copy load sext neg jump_if_zero ret].freeze
  NAIVE_NO_OPERAND_OPS = %i[const label].freeze

  def naive_operand_vregs(inst)
    case inst.op
    when *NAIVE_TWO_OPERAND_OPS
      [inst.a, inst.b].compact
    when *NAIVE_ONE_OPERAND_OPS
      inst.a.nil? ? [] : [inst.a]
    when *NAIVE_NO_OPERAND_OPS
      []
    else
      raise "test's naive operand scan does not know #{inst.op.inspect}"
    end
  end

  def naive_bump(array, index)
    array[index] = (array[index] || 0) + 1
  end

  # A one-pass, from-scratch count of how often each virtual register is
  # written and read in `insts`.
  def naive_census(insts, vreg_count)
    reads = Array.new(vreg_count, 0)
    writes = Array.new(vreg_count, 0)
    insts.each do |instruction|
      naive_bump(writes, instruction.dst) unless instruction.dst.nil?
      naive_operand_vregs(instruction).each { |vreg| naive_bump(reads, vreg) }
    end
    [reads, writes]
  end

  # Simplify::PRODUCER_OPS / CONSUMER_OPS, restricted to the ops this file's
  # instructions use, and written down from reading simplify.rb rather than
  # referenced from it.
  NAIVE_PRODUCER_OPS = %i[const copy add sub mul neg sext load scaled_add].freeze
  NAIVE_CONSUMER_OPS = %i[copy add sub mul neg sext load store scaled_add jump_if_zero ret].freeze

  # Simplify#transient_flags's rule, written independently: a register written
  # once and read once, by the very next instruction, outside the parameter
  # slots, where both ends are on the whitelists above. (None of this file's
  # instructions cross register files, so the width agreement Simplify also
  # requires is not modelled here — it can only ever be satisfied.)
  def naive_transient(insts, param_count, reads, writes)
    transient = []
    insts.each_with_index do |instruction, index|
      vreg = instruction.dst
      next if vreg.nil? || vreg < param_count
      next unless reads[vreg] == 1 && writes[vreg] == 1
      next unless NAIVE_PRODUCER_OPS.include?(instruction.op)

      reader = insts[index + 1]
      next unless reader && NAIVE_CONSUMER_OPS.include?(reader.op)
      next unless naive_operand_vregs(reader).include?(vreg)

      transient << vreg
    end
    transient
  end

  def transient_indices(flags)
    flags.each_index.select { |i| flags[i] }
  end

  # Runs IR::Analysis.simplified on `insts` and asserts that the reads,
  # writes and transient set it hands out match a from-scratch recount of the
  # list it actually produced. Returns the analysis so a test can go on to
  # check that a rewrite actually happened.
  def assert_analysis_matches_a_recount(insts, vregs:, params: 0)
    analysis = Analysis.simplified(function(insts, vregs: vregs, params: params))
    assert analysis.known?, "expected every op to be recognized"

    expected_reads, expected_writes = naive_census(analysis.insts, analysis.vreg_count)
    assert_equal expected_reads, analysis.reads
    assert_equal expected_writes, analysis.writes

    expected_transient = naive_transient(analysis.insts, analysis.param_count,
                                          expected_reads, expected_writes)
    assert_equal expected_transient.sort, transient_indices(analysis.transient).sort
    analysis
  end

  # --- single-use copy forwarding -----------------------------------------

  # "T = a + b; V = T" becomes one instruction, so T's one read and one write
  # both disappear from the census the forwarding rewrite kept true.
  def test_matches_a_recount_after_copy_forwarding
    insts = [inst(:add, dst: 5, a: 0, b: 1),
             inst(:copy, dst: 4, a: 5),
             inst(:ret, a: 4)]
    analysis = assert_analysis_matches_a_recount(insts, vregs: 6)
    assert_equal [[:add, 4, 0, 1, nil], [:ret, nil, 4, nil, nil]], shape(analysis.insts)
  end

  # --- subscript fusion, inside a loop with a backward-defined value --------

  # "p[i]" fuses to a :scaled_add inside a loop whose index (vreg 0) is read
  # at the top of the body and only written at the bottom ("i = i + 1"),
  # textually after its read — the shape that makes fusion decide from a
  # pre-pass snapshot rather than from the census as later rewrites see it.
  def test_matches_a_recount_after_subscript_fusion_in_a_backward_defined_loop
    insts = [inst(:const, dst: 0, a: 0),                  # i = 0
             inst(:const, dst: 1, a: 4),                  # element size
             inst(:const, dst: 9, a: 1),                  # the constant 1
             inst(:label, a: 0),                          # loop top
             inst(:mul, dst: 5, a: 0, b: 1, size: 8),      # i * 4 (reads i)
             inst(:add, dst: 6, a: 2, b: 5, size: 8),      # base + i*4 -> fuses
             inst(:load, dst: 7, a: 6, size: 4),
             inst(:store, a: 6, b: 7, size: 4),
             inst(:add, dst: 0, a: 0, b: 9, size: 4),      # i = i + 1, writes i after its read above
             inst(:jump_if_zero, a: 0, b: 0),              # back edge to the label
             inst(:ret)]
    analysis = assert_analysis_matches_a_recount(insts, vregs: 10)
    assert_includes analysis.insts.map(&:op), :scaled_add
    refute_includes analysis.insts.map(&:op), :mul
  end

  # --- dead result elimination, more than one round -------------------------

  # Nothing reads the :neg's result, so it is dropped; that orphans the
  # :copy that fed it, which is dropped in the next round; that in turn
  # orphans the :sext, dropped in a third. Three rounds of chained removal.
  def test_matches_a_recount_after_a_multi_round_dead_result_chain
    insts = [inst(:sext, dst: 5, a: 0, size: 4),
             inst(:copy, dst: 6, a: 5),
             inst(:neg, dst: 7, a: 6),
             inst(:add, dst: 8, a: 1, b: 2),
             inst(:ret, a: 8)]
    analysis = assert_analysis_matches_a_recount(insts, vregs: 9)
    assert_equal [[:add, 8, 1, 2, nil], [:ret, nil, 8, nil, nil]], shape(analysis.insts)
  end

  # --- all three rewrites interacting ---------------------------------------

  # A forwarded copy feeds a subscript that fuses, and the element-size
  # constant the fusion orphans is then dropped as a dead result — three
  # rewrites acting on the same short list, each changing what the next one
  # sees.
  def test_matches_a_recount_when_all_three_rewrites_interact
    insts = [inst(:add, dst: 4, a: 0, b: 1),        # T = a + b
             inst(:copy, dst: 3, a: 4),              # V = T -> forwarded
             inst(:const, dst: 5, a: 4),              # element size
             inst(:mul, dst: 6, a: 3, b: 5, size: 8), # V * 4
             inst(:add, dst: 7, a: 2, b: 6, size: 8), # base + V*4 -> fuses
             inst(:load, dst: 8, a: 7, size: 4),
             inst(:sext, dst: 9, a: 8, size: 4),      # dead: nothing reads it
             inst(:ret, a: 7)]
    analysis = assert_analysis_matches_a_recount(insts, vregs: 10)
    ops = analysis.insts.map(&:op)
    assert_includes ops, :scaled_add
    refute_includes ops, :copy
    refute_includes ops, :const
    refute_includes ops, :sext
  end

  # --- nothing to rewrite -----------------------------------------------

  # A straight-line function none of the three rewrites touches: every
  # register is read more than once or not at all eligible, so the census
  # Simplify hands back is the one #census would have taken to begin with.
  def test_matches_a_recount_when_nothing_is_rewritten
    insts = [inst(:add, dst: 2, a: 0, b: 1),
             inst(:store, a: 2, b: 0, size: 8),
             inst(:sub, dst: 3, a: 2, b: 1),
             inst(:ret, a: 3)]
    analysis = assert_analysis_matches_a_recount(insts, vregs: 4)
    assert_same insts, analysis.insts
  end
end
