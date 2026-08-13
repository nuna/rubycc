# frozen_string_literal: true

require_relative "ir"

module Rubycc
  module IR
    # Local rewrites applied to a function's instruction list on its way from
    # the generator to a backend. Everything here is decided from the flat list
    # alone — a census of how often each virtual register is written and read,
    # plus a look at the neighbouring instruction — so no control-flow graph,
    # live range or interference graph is built. That boundary is deliberate:
    # register allocation is a separate piece of work, and the transformations
    # below are the ones that pay off *before* it, because they delete
    # instructions an allocator would otherwise faithfully allocate registers
    # for.
    #
    # Three rewrites run, in this order:
    #
    #   1. Single-use copy forwarding. Assigning to a variable lands the
    #      expression in a temporary and copies the temporary into the
    #      variable's slot; when that copy is the temporary's only reader, the
    #      producer can write the variable's slot itself and the copy goes.
    #   2. Subscript fusion. The generator lowers "p[i]" as a multiply of the
    #      index by the element size followed by an add to the base, and the
    #      element size arrives as a :const of its own — three instructions,
    #      each costing a slot round trip. Both targets have a single
    #      instruction for exactly this shape (x86-64's `lea` with a SIB scale,
    #      AArch64's add with a shifted register operand), so the pair collapses
    #      into one :scaled_add and the constant is left with no readers.
    #   3. Dead result elimination, which is what then removes that constant —
    #      and the value of a discarded "i++", and anything else the generator
    #      materialized into a slot nobody reads. Only side-effect-free
    #      instructions are candidates (see PURE_OPS); a division that may trap,
    #      a load that may fault and anything that writes memory or calls stay
    #      put whether or not their result is read.
    #
    # The pass is fail-safe by construction: it needs to know every place a
    # virtual register can be *read*, and an op it does not recognize means it
    # cannot know that, so #run hands the function back untouched rather than
    # guessing (see #operand_vregs).
    module Simplify
      module_function

      # Rewrites `function`, returning it unchanged when nothing applies.
      # `vreg_count` is deliberately left alone: dropping an instruction must
      # not renumber slots, both because the backends address slots by number
      # and because a stable frame layout is what keeps the same source
      # producing the same bytes (N4).
      def run(function)
        insts = function.insts
        return function unless insts.all? { |inst| known_op?(inst.op) }

        # Instruction has no #== of its own, so the array comparison is
        # element identity: an untouched function really does come back as the
        # very objects the generator produced, and is handed on unwrapped.
        rewritten = drop_dead_results(fuse_subscripts(forward_single_use_copies(insts)))
        return function if rewritten == insts

        Function.new(function.name, rewritten, function.vreg_count, function.param_count,
                     function.stack_objects, function.linkage, function.variadic,
                     function.param_kinds)
      end

      # The element sizes a subscript's scale factor may have. Both targets
      # encode the scale as a shift of the index register, so these four powers
      # of two are exactly what fits in one instruction; any other stride keeps
      # its multiply.
      SCALES = [1, 2, 4, 8].freeze

      # Ops whose `a` and `b` fields are both plain virtual registers.
      TWO_OPERAND_OPS = %i[
        add sub mul mulhi div mod udiv umod and or xor shl sar shr
        eq ne lt le gt ge ult ule ugt uge
        fadd fsub fmul fdiv feq fne flt fle fgt fge
        scaled_add store memcpy atomic_store
      ].freeze

      # Ops whose `a` is a virtual register and whose `b`, if used at all, is
      # something else (a label id, a width descriptor, a scan direction, a
      # parameter count).
      ONE_OPERAND_OPS = %i[
        copy neg sext zext ftof itof ftoi load uload addr_of alloca
        bit_scan va_start atomic_load jump_if_zero
      ].freeze

      # Ops that read no virtual register at all: their `a` is an immediate, a
      # label id, an object id, a string-pool id or a symbol name.
      NO_OPERAND_OPS = %i[
        const label jump func_addr object_addr string_addr global_addr got_addr
        atomic_fence
      ].freeze

      # Ops whose operands need a shape of their own (a call's argument pairs, a
      # return's struct buffer, an atomic's packed second operand).
      IRREGULAR_OPS = %i[call call_indirect ret atomic_rmw atomic_cas].freeze

      # The ops whose only effect is to put a value in `dst`: dropping one when
      # nothing reads that value cannot change what the program does. The list
      # is a whitelist on purpose. :div/:mod and their unsigned forms are absent
      # because a zero divisor traps; :load/:uload because a wild pointer
      # faults; every memory write, call, atomic and :alloca because the effect
      # *is* the point.
      PURE_OPS = %i[
        const copy add sub mul mulhi and or xor shl sar shr neg
        eq ne lt le gt ge ult ule ugt uge
        fadd fsub fmul fdiv feq fne flt fle fgt fge itof ftoi ftof
        sext zext bit_scan scaled_add
        addr_of object_addr string_addr global_addr func_addr got_addr
      ].freeze

      def known_op?(op)
        TWO_OPERAND_OPS.include?(op) || ONE_OPERAND_OPS.include?(op) ||
          NO_OPERAND_OPS.include?(op) || IRREGULAR_OPS.include?(op)
      end

      # Every virtual register `inst` reads. Getting this exhaustive is what the
      # whole pass rests on — a missed read would let a live value be deleted —
      # so the shapes are enumerated rather than inferred, and #run refuses to
      # touch a function containing an op not listed above.
      def operand_vregs(inst)
        op = inst.op
        return [inst.a, inst.b] if TWO_OPERAND_OPS.include?(op)
        return [inst.a] if ONE_OPERAND_OPS.include?(op)
        return [] if NO_OPERAND_OPS.include?(op)

        case op
        when :call, :call_indirect
          # Each argument is a [vreg, kind] pair, whose vreg is nil for an
          # alignment pad; an indirect call also reads its target, and a struct
          # result read back in registers is scattered into a buffer whose
          # address is a further read (the second half of the size pair).
          vregs = inst.b.filter_map { |vreg, _kind| vreg }
          vregs << inst.a if op == :call_indirect
          ret = inst.size&.last
          vregs << ret.first if ret.is_a?(Array)
          vregs
        when :ret
          inst.a.nil? ? [] : [inst.a]
        when :atomic_rmw
          [inst.a, inst.b[0]]
        when :atomic_cas
          [inst.a, inst.b[0], inst.b[1]]
        end
      end

      # Counts how many instructions read each virtual register.
      def read_counts(insts)
        counts = Hash.new(0)
        insts.each do |inst|
          operand_vregs(inst).each { |vreg| counts[vreg] += 1 unless vreg.nil? }
        end
        counts
      end

      # Counts how many instructions write each virtual register.
      def write_counts(insts)
        counts = Hash.new(0)
        insts.each { |inst| counts[inst.dst] += 1 unless inst.dst.nil? }
        counts
      end

      # Maps each virtual register written by exactly one :const to
      # [that constant's value, the index of the instruction that sets it].
      # A register written more than once, or written by anything else, is
      # absent — as is one whose slot address is taken, since a store through
      # that address can replace the value the :const put there.
      def constant_definitions(insts)
        constants = {}
        rejected = {}
        insts.each_with_index do |inst, index|
          rejected[inst.a] = true if inst.op == :addr_of
          next if inst.dst.nil?

          if inst.op == :const && !constants.key?(inst.dst)
            constants[inst.dst] = [inst.a, index]
          else
            rejected[inst.dst] = true
          end
        end
        constants.reject { |vreg, _| rejected[vreg] }
      end

      # Rewrites "T = <anything>; V = T" as "V = <anything>" whenever T is
      # written once, read once, and that one read is the copy immediately
      # behind it. Assigning to a variable goes through such a pair — the
      # expression lands in a temporary and the temporary is copied into the
      # variable's slot — so this removes a whole slot round trip per
      # assignment, which in a floating-point loop is three instructions each
      # time (the value is stored from a vector register and copied through a
      # general-purpose one).
      #
      # Writing V one instruction earlier changes nothing, the two being
      # adjacent, and it stays correct when the producer *reads* V as well ("i =
      # i + 1" becomes an add whose destination is its own operand): every
      # backend loads an instruction's operands into registers before it stores
      # the result.
      def forward_single_use_copies(insts)
        reads = read_counts(insts)
        writes = write_counts(insts)
        forwarded = []
        skip_next = false
        insts.each_with_index do |inst, index|
          if skip_next
            skip_next = false
            next
          end
          copy = insts[index + 1]
          if inst.dst && copy && copy.op == :copy && copy.a == inst.dst && copy.dst != inst.dst &&
             reads[inst.dst] == 1 && writes[inst.dst] == 1
            forwarded << Instruction.new(inst.op, dst: copy.dst, a: inst.a, b: inst.b, size: inst.size)
            skip_next = true
          else
            forwarded << inst
          end
        end
        forwarded
      end

      # Collapses "index * element_size" followed by "base + that" into one
      # :scaled_add. The two must be adjacent, which is how the generator
      # actually emits a subscript and is also what makes the rewrite obviously
      # safe: with nothing in between, neither operand of the add can have been
      # rewritten since the multiply read it.
      def fuse_subscripts(insts)
        constants = constant_definitions(insts)
        reads = read_counts(insts)
        fused = []
        skip_next = false
        insts.each_with_index do |inst, index|
          if skip_next
            skip_next = false
            next
          end
          replacement = scaled_add_for(inst, insts[index + 1], index, constants, reads)
          if replacement
            fused << replacement
            skip_next = true
          else
            fused << inst
          end
        end
        fused
      end

      # The :scaled_add that replaces `mul` and the `add` right behind it, or
      # nil when the pair is not a subscript. The conditions are:
      #
      #   * both are 8-byte (pointer-width) operations — a narrower multiply is
      #     ordinary arithmetic, not address forming;
      #   * one multiply operand is a constant 1/2/4/8 defined earlier;
      #   * the add reads the multiply's result, and is its *only* reader, so
      #     removing the multiply leaves the product unwanted;
      #   * the add's other operand is a different register (a "t + t" would
      #     have read the product twice and is excluded by the count anyway).
      def scaled_add_for(mul, add, index, constants, reads)
        return nil unless mul.op == :mul && mul.size == 8
        return nil unless add && add.op == :add && add.size == 8
        return nil unless reads[mul.dst] == 1
        return nil unless add.a == mul.dst || add.b == mul.dst

        scale, index_vreg = scale_operand(mul, index, constants)
        return nil unless SCALES.include?(scale)

        base = add.a == mul.dst ? add.b : add.a
        Instruction.new(:scaled_add, dst: add.dst, a: base, b: index_vreg, size: scale)
      end

      # Splits a multiply into [constant factor, the other operand] when one
      # side is a constant set before instruction `index`, else [nil, nil]. The
      # position test is what makes reading the constant's value here sound: the
      # :const has already run wherever this multiply is reached from.
      def scale_operand(mul, index, constants)
        b_const = constants[mul.b]
        return [b_const[0], mul.a] if b_const && b_const[1] < index

        a_const = constants[mul.a]
        return [a_const[0], mul.b] if a_const && a_const[1] < index

        [nil, nil]
      end

      # Drops every pure instruction whose result nothing reads, repeating until
      # nothing more falls out: removing one instruction removes its own reads,
      # which can make the instruction that produced *those* values dead in
      # turn (a fused subscript's element-size constant is reached in one round,
      # the sign extension feeding a discarded "i++" in two).
      def drop_dead_results(insts)
        loop do
          reads = read_counts(insts)
          kept = insts.reject do |inst|
            PURE_OPS.include?(inst.op) && !inst.dst.nil? && reads[inst.dst].zero?
          end
          return insts if kept.size == insts.size

          insts = kept
        end
      end
    end
  end
end
