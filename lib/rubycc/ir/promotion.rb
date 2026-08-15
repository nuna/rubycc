# frozen_string_literal: true

require_relative "ir"
require_relative "simplify"
require_relative "analysis"

module Rubycc
  module IR
    # Chooses which virtual registers a backend should keep in a callee-saved
    # machine register for the whole of a function, instead of in the stack slot
    # the spill-everything discipline gives every value.
    #
    # The allocation this feeds is the crudest one that can pay: **one vreg owns
    # one register for the function's entire length**. Nothing is ever
    # reassigned, so two promoted values can never want the same register and
    # interference cannot arise by construction — which is what lets this file
    # exist without a control-flow graph, a live range, an interference graph or
    # a spill heuristic. It is the same bargain IR::Simplify strikes one step
    # earlier: decide from the flat instruction list, and refuse whatever the
    # flat list cannot decide.
    #
    # Two questions are answered below, and only these two:
    #
    #   1. **Which vregs may be promoted at all** (#candidates' guards). A value
    #      whose address is taken has to be in memory; a value that travels
    #      through the vector register file has no general-purpose home to be
    #      promoted into; a variadic function's register-save area is written
    #      behind the IR's back; and an op this file does not recognize could be
    #      reading anything.
    #   2. **In what order they are worth promoting** (#weighted_occurrences),
    #      there being fewer registers than candidates.
    #
    # Both answers are functions of the Function object alone — the instruction
    # list, plus `variadic` and `param_kinds` for the two effects the list does
    # not describe — with no dependence on hash iteration or anything else that
    # could differ between runs, so the same source keeps producing the same
    # bytes (N4).
    module Promotion
      module_function

      # What one backward branch's span multiplies an occurrence by. The figure
      # only has to order candidates, not predict a trip count: a value used
      # once per iteration should outrank one used a few times in straight-line
      # code. Nesting multiplies, a doubly nested use being worth
      # LOOP_WEIGHT ** 2, because an inner loop's body runs the product of the
      # two trip counts.
      LOOP_WEIGHT = 10

      # The ops that read or write a vreg through the vector register file. A
      # value either of these touches is refused outright: the slot convention
      # has floating values living in the same 8-byte slots as integers, so
      # promoting one would mean moving it between the two register files at
      # every use — and System V has no callee-saved xmm register to hold it in
      # instead. Integers and pointers are the whole of this version's business.
      VECTOR_OPS = %i[fadd fsub fmul fdiv feq fne flt fle fgt fge itof ftoi ftof].freeze

      # The ABI kinds that name a vector register. A parameter or argument so
      # classified is moved with movss/movsd straight between its slot and an xmm
      # register, so its vreg touches the vector file even though no op in
      # VECTOR_OPS mentions it. :sse16 (an AAPCS64 quad-precision `long double`
      # in a variadic call) carries an address rather than a value, so refusing
      # it is only caution — but caution costs one entry here.
      VECTOR_KINDS = %i[sse4 sse8 sse16].freeze

      # The same two lists as lookup tables; the arrays above are what the rules
      # are read and argued from, these are what the scan below asks per
      # instruction.
      VECTOR_OP = VECTOR_OPS.to_h { |op| [op, true] }.freeze
      VECTOR_KIND = VECTOR_KINDS.to_h { |kind| [kind, true] }.freeze

      # The virtual registers worth promoting in `function`, best first. A
      # backend takes as many as it has registers for; the tail is left in slots
      # and costs nothing.
      #
      # `analysis` is the census of `function`'s instruction list, which the
      # caller has usually taken already (the backend needs the transient set
      # for itself, and the transient set is one of the two exclusions here).
      def candidates(function, analysis = Analysis.of(function))
        insts = function.insts
        # A variadic function's prologue spills all six integer argument
        # registers into a register-save area __builtin_va_arg reads back, an
        # effect no instruction in the list describes. Rather than reason about
        # which values that can disturb, the whole function is refused.
        return [] if function.variadic
        # The read enumeration below has to be exhaustive — a missed read would
        # leave a value in a slot nobody ever writes — and an unrecognized op
        # means it is not. Same fail-safe as IR::Simplify#run.
        return [] unless analysis.known?

        blocked = ineligible_vregs(insts, function.param_kinds, function.vreg_count)
        transient = analysis.transient
        counts = weighted_occurrences(insts, function.vreg_count)
        chosen = []
        vreg = 0
        limit = counts.size
        while vreg < limit
          weight = counts[vreg]
          # An unmentioned register has no occurrences to weigh and is no
          # candidate: promoting one would spend a register, and a save and a
          # restore, on a value that is never named.
          chosen << vreg unless weight.nil? || weight.zero? || blocked[vreg] || transient[vreg]
          vreg += 1
        end
        # Heaviest first, ties broken by register number. The order is a total
        # one — no two candidates share a number — so it does not depend on the
        # sort being stable, and the same source keeps producing the same bytes
        # (N4). Comparing the two numbers in place is what a sort_by on
        # [-weight, vreg] would do, without the pair it would have built (and
        # then compared element by element) for every candidate.
        chosen.sort! do |left, right|
          by_weight = counts[right] <=> counts[left]
          by_weight.zero? ? left <=> right : by_weight
        end
        chosen
      end

      # The vregs that must stay in their slots whatever their use count, as an
      # array indexed by register number holding true for a blocked one.
      #
      # Besides the vector cases, one exclusion is about payoff rather than
      # correctness: a *transient* (IR::Simplify#transient_flags) never reaches
      # its slot at all, its one reader being the instruction right behind its
      # producer. Promoting one would replace two instructions that do not exist
      # with two register moves that do, and spend a register doing it, so the
      # occurrence count — which cannot tell a slot round trip from a value that
      # simply stayed in eax — is corrected in #candidates instead.
      def ineligible_vregs(insts, param_kinds, vreg_count = 0)
        blocked = Array.new(vreg_count)
        param_kinds&.each_with_index { |kind, slot| blocked[slot] = true if VECTOR_KIND[kind] }
        index = 0
        size = insts.size
        while index < size
          inst = insts[index]
          index += 1
          block_vector_uses(blocked, inst)
          # "&v" hands out the address of v's slot, and every later read through
          # that pointer expects to find the value there. A promoted value is
          # not there.
          blocked[inst.a] = true if inst.op == :addr_of
        end
        blocked
      end

      # Adds whatever of `inst` travels through the vector register file. Both
      # the operands and the result of a VECTOR_OPS instruction go in, even where
      # only one end is a vector one (:itof reads a general-purpose register and
      # :ftoi writes one), because refusing the pair costs one candidate and
      # saves a rule per op.
      def block_vector_uses(blocked, inst)
        op = inst.op
        if VECTOR_OP[op]
          blocked[inst.dst] = true unless inst.dst.nil?
          Simplify.each_operand_vreg(inst) { |vreg| blocked[vreg] = true }
        end
        case op
        when :call, :call_indirect
          inst.b.each { |vreg, kind| blocked[vreg] = true if vreg && VECTOR_KIND[kind] }
          # `size` is the [fixed, ret] descriptor; a :sse4/:sse8 result comes
          # back in xmm0 and is written to dst's slot with movss/movsd.
          blocked[inst.dst] = true if !inst.dst.nil? && VECTOR_KIND[inst.size&.last]
        when :ret
          # An integer return's `size` is nil and a struct's an AbiPiece array;
          # only a float/double return carries a width, and that one is read out
          # of its slot into xmm0.
          blocked[inst.a] = true if inst.size.is_a?(Integer)
        end
      end

      # How much each vreg's occurrences are worth, as an array indexed by
      # register number: one point per read and one per write, multiplied by the
      # loop weight of the instruction it appears in. Reads and writes count the
      # same because both are one slot access in a spill-everything backend,
      # which is exactly what promotion removes.
      #
      # The depth the weight comes from is accumulated over the same pass that
      # counts the occurrences — one running sum of #loop_deltas — rather than
      # materialized as a weight per instruction first.
      def weighted_occurrences(insts, vreg_count = 0)
        deltas = loop_deltas(insts)
        counts = Array.new(vreg_count, 0)
        depth = 0
        weight = 1
        index = 0
        size = insts.size
        while index < size
          inst = insts[index]
          delta = deltas[index]
          index += 1
          unless delta.zero?
            depth += delta
            weight = LOOP_WEIGHT**depth
          end
          dst = inst.dst
          unless dst.nil?
            count = counts[dst]
            counts[dst] = count ? count + weight : weight
          end
          Simplify.each_operand_vreg(inst) do |vreg|
            count = counts[vreg]
            counts[vreg] = count ? count + weight : weight
          end
        end
        counts
      end

      # A difference list over instruction positions: +1 where a loop body
      # begins, -1 just past where it ends, so nested spans accumulate into a
      # depth by one running sum (LOOP_WEIGHT ** depth being the weight).
      #
      # The loops are found without a control-flow graph: a branch to a label
      # that lies *behind* it can only be a loop's back edge, and everything
      # between the label and the branch is the body it repeats. That span is
      # what gets weighted. It over-counts an `if` whose two arms both sit inside
      # such a span (only one of them runs per iteration) and misses a loop
      # written with the branch out of line — but the answer only orders
      # candidates, so being approximate costs a worse choice, never a wrong one.
      #
      # One pass is enough to find the back edges: a label is recorded as it is
      # passed, so a branch finds its target in the table exactly when that
      # target lies behind it, and a forward branch — which is not a back edge —
      # finds nothing.
      def loop_deltas(insts)
        labels = nil
        size = insts.size
        deltas = Array.new(size + 1, 0)
        index = 0
        while index < size
          inst = insts[index]
          op = inst.op
          if op == :label
            (labels ||= {})[inst.a] = index
          elsif labels && (op == :jump || op == :jump_if_zero)
            start = labels[op == :jump ? inst.a : inst.b]
            unless start.nil?
              deltas[start] += 1
              deltas[index + 1] -= 1
            end
          end
          index += 1
        end
        deltas
      end

      # The label id `inst` may branch to, or nil when it is not a branch. The
      # id lives in `a` for an unconditional jump and in `b` for a conditional
      # one, whose `a` is the condition it tests.
      def branch_target(inst)
        case inst.op
        when :jump then inst.a
        when :jump_if_zero then inst.b
        end
      end
    end
  end
end
