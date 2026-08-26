# frozen_string_literal: true

require "set"
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
    # guessing (see #each_operand_vreg).
    #
    # The census the three rewrites decide from — how often each virtual
    # register is read and written — is taken **once**, by #census, and then
    # kept true by each rewrite as it goes: forwarding a copy removes exactly
    # one read and one write of the temporary, fusing a subscript removes the
    # reads of the pair it replaces, and dropping a dead instruction removes
    # its own. What comes out is therefore the census of the list that comes
    # out, which is what IR::Analysis hands on to IR::Promotion and to the
    # backend so neither has to count the list again.
    module Simplify
      module_function

      # Rewrites `function`, returning it unchanged when nothing applies.
      # `vreg_count` is deliberately left alone: dropping an instruction must
      # not renumber slots, both because the backends address slots by number
      # and because a stable frame layout is what keeps the same source
      # producing the same bytes (N4).
      def run(function)
        run_counted(function).first
      end

      # #run plus the census of the list it decided on: [function, reads,
      # writes]. `reads` and `writes` are arrays indexed by virtual register
      # number — the numbers are dense and small, so an array is what a hash
      # was standing in for — and both are nil when an unrecognized op made the
      # pass refuse the function, which is the same answer as "nothing here may
      # be counted on" for every later consumer (IR::Analysis).
      def run_counted(function)
        insts = function.insts
        reads, writes = census(insts, function.vreg_count)
        return [function, nil, nil] if reads.nil?

        rewritten = drop_dead_results(
          fuse_subscripts(forward_single_use_copies(insts, reads, writes), reads, writes),
          reads, writes
        )
        # Each rewrite hands its own array back untouched when it changed
        # nothing, so an untouched function really does come back as the very
        # objects the generator produced, and is handed on unwrapped.
        return [function, reads, writes] if rewritten.equal?(insts)

        [Function.new(function.name, rewritten, function.vreg_count, function.param_count,
                      function.stack_objects, function.linkage, function.variadic,
                      function.param_kinds),
         reads, writes]
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
        bit_scan popcount va_start atomic_load jump_if_zero
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
        sext zext bit_scan popcount scaled_add
        addr_of object_addr string_addr global_addr func_addr got_addr
      ].freeze

      # The four groups above as one op -> shape table. The arrays are the
      # documentation, one line per op in reading order; this is what the scans
      # ask, a single hash probe per instruction rather than up to four linear
      # searches through thirty symbols. The irregular ops each get a shape of
      # their own, their operands living in fields no other op uses.
      OPERAND_SHAPES = {}.tap do |shapes|
        TWO_OPERAND_OPS.each { |op| shapes[op] = :two }
        ONE_OPERAND_OPS.each { |op| shapes[op] = :one }
        NO_OPERAND_OPS.each { |op| shapes[op] = :none }
        IRREGULAR_OPS.each { |op| shapes[op] = op }
      end.freeze

      def known_op?(op)
        OPERAND_SHAPES.key?(op)
      end

      # Yields every virtual register `inst` reads, nils skipped and repeats
      # kept ("t + t" reads t twice). Getting this exhaustive is what the whole
      # pass rests on — a missed read would let a live value be deleted — so the
      # shapes are enumerated rather than inferred, and #run refuses to touch a
      # function containing an op not listed above (which yields nothing here).
      #
      # It yields rather than returning the list it used to return because it
      # runs once per instruction per scan, and that list was garbage every
      # time — one array per instruction per pass, on a path the GC already
      # dominates. #reads_vreg? is the one question a caller asked the list
      # rather than the elements.
      def each_operand_vreg(inst)
        case OPERAND_SHAPES[inst.op]
        when :two
          a = inst.a
          b = inst.b
          yield a unless a.nil?
          yield b unless b.nil?
        when :one
          a = inst.a
          yield a unless a.nil?
        when :none
          nil
        when :call, :call_indirect
          # Each argument is a [vreg, kind] pair, whose vreg is nil for an
          # alignment pad; an indirect call also reads its target, and a struct
          # result read back in registers is scattered into a buffer whose
          # address is a further read (the second half of the size pair).
          inst.b.each { |vreg, _kind| yield vreg unless vreg.nil? }
          yield inst.a if inst.op == :call_indirect
          ret = inst.size&.last
          yield ret.first if ret.is_a?(Array)
        when :ret
          a = inst.a
          yield a unless a.nil?
        when :atomic_rmw
          yield inst.a
          yield inst.b[0]
        when :atomic_cas
          yield inst.a
          yield inst.b[0]
          yield inst.b[1]
        end
      end

      # Whether `inst` reads `vreg` — #each_operand_vreg's membership test,
      # without the list it would have had to build to answer.
      def reads_vreg?(inst, vreg)
        each_operand_vreg(inst) { |operand| return true if operand == vreg }
        false
      end

      # How often each virtual register is read and written, as the pair of
      # arrays [reads, writes] indexed by register number, or nil when some op
      # is not one this file knows how to read (the fail-safe #run rests on,
      # tested here because this is the one scan every caller starts from).
      #
      # `vreg_count` only sizes the arrays: a register past it still counts,
      # growing them, so a hand-built function with a loose count is answered
      # the same as a generated one.
      #
      # This scan and the ones below walk the list by index rather than with
      # each_with_index, which is the one place in this file where speed decided
      # the shape: the block call per instruction was measured at a sixth of the
      # whole back half of the compiler (stackprof, bigdecimal.c, 2026-08-15).
      def census(insts, vreg_count = 0)
        reads = Array.new(vreg_count, 0)
        writes = Array.new(vreg_count, 0)
        index = 0
        size = insts.size
        while index < size
          inst = insts[index]
          index += 1
          return nil unless OPERAND_SHAPES.key?(inst.op)

          dst = inst.dst
          unless dst.nil?
            count = writes[dst]
            writes[dst] = count ? count + 1 : 1
          end
          each_operand_vreg(inst) do |vreg|
            count = reads[vreg]
            reads[vreg] = count ? count + 1 : 1
          end
        end
        [reads, writes]
      end

      # Maps each virtual register written by exactly one :const to
      # [that constant's value, the index of the instruction that sets it].
      # A register written more than once, or written by anything else, is
      # absent — as is one whose slot address is taken, since a store through
      # that address can replace the value the :const put there. That last
      # exclusion is the same aliasing rule the backends' residency tracking
      # obeys, applied at instruction granularity because here there is no
      # emitted-nothing test to lean on.
      def constant_definitions(insts)
        constants = {}
        rejected = {}
        index = 0
        size = insts.size
        while index < size
          inst = insts[index]
          op = inst.op
          rejected[inst.a] = true if op == :addr_of
          dst = inst.dst
          unless dst.nil?
            if op == :const && !constants.key?(dst)
              constants[dst] = [inst.a, index]
            else
              rejected[dst] = true
            end
          end
          index += 1
        end
        return constants if rejected.empty?

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
      #
      # `reads` and `writes` come from #census and are brought up to date as the
      # rewrite goes: the pair "T = ...; V = T" becomes one instruction writing
      # V, so T loses its single read and its single write and nothing else
      # moves. Updating them in flight cannot change a later decision, which is
      # what makes keeping the census incrementally the same pass as counting it
      # afresh would have been: the guard has just established that this pair is
      # T's only reader and only writer, so no instruction the loop has yet to
      # reach mentions T at all.
      def forward_single_use_copies(insts, reads, writes)
        forwarded = nil
        index = 0
        size = insts.size
        while index < size
          inst = insts[index]
          dst = inst.dst
          copy = insts[index + 1]
          if dst && copy && copy.op == :copy && copy.a == dst && copy.dst != dst &&
             reads[dst] == 1 && writes[dst] == 1
            forwarded ||= insts[0, index]
            forwarded << Instruction.new(inst.op, dst: copy.dst, a: inst.a, b: inst.b, size: inst.size)
            reads[dst] -= 1
            writes[dst] -= 1
            index += 2 # the copy is the second half of what was just written
          else
            forwarded << inst if forwarded
            index += 1
          end
        end
        forwarded || insts
      end

      # Collapses "index * element_size" followed by "base + that" into one
      # :scaled_add. The two must be adjacent, which is how the generator
      # actually emits a subscript and is also what makes the rewrite obviously
      # safe: with nothing in between, neither operand of the add can have been
      # rewritten since the multiply read it.
      #
      # The census is kept true the same way #forward_single_use_copies keeps
      # it: the two instructions the :scaled_add replaces stop reading what they
      # read and it starts reading what it reads. Here, though, the decisions
      # are deliberately taken from `census`, which stops following `reads` the
      # moment the first fusion would disturb it — a loop may read a value the
      # list defines further down, so a fusion *can* lower the read count a
      # later fusion's guard consults, and the answer has to stay the one the
      # pre-pass count gave.
      def fuse_subscripts(insts, reads, writes)
        constants = constant_definitions(insts)
        return insts if constants.empty?

        census = reads
        fused = nil
        index = 0
        size = insts.size
        while index < size
          inst = insts[index]
          add = insts[index + 1]
          replacement = scaled_add_for(inst, add, index, constants, census)
          if replacement
            census = reads.dup if census.equal?(reads)
            fused ||= insts[0, index]
            fused << replacement
            each_operand_vreg(inst) { |vreg| reads[vreg] -= 1 }
            each_operand_vreg(add) { |vreg| reads[vreg] -= 1 }
            each_operand_vreg(replacement) { |vreg| reads[vreg] += 1 }
            writes[inst.dst] -= 1 # the add's destination is the replacement's
            index += 2 # the add is the second half of the :scaled_add
          else
            fused << inst if fused
            index += 1
          end
        end
        fused || insts
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

      # --- transient values --------------------------------------------------
      #
      # A virtual register whose slot never has to be written at all: the value
      # is produced by one instruction, read by the very next one, and read
      # nowhere else, so it can simply stay in the register its producer left it
      # in. Every intermediate result of an expression is of this shape, which is
      # why a spill-everything backend writes so many slots nobody ever reads —
      # in "b[i] += scale * a[i]" nine of the twelve stores in the loop are these.
      #
      # This is deliberately *not* a liveness computation. Four conditions, all
      # decided from the flat list, make the answer sound without one:
      #
      #   * exactly one instruction writes the register and exactly one reads it,
      #     so there is no other definition to reach a reader and no other reader
      #     to reach;
      #   * the reader is the instruction immediately after the writer. Nothing
      #     can be interposed, and because every branch target in this IR is a
      #     :label — which is never a reader — control cannot enter between them
      #     or reach the reader without having run the writer;
      #   * the register is not one of the parameter slots, which the prologue
      #     writes before any instruction runs;
      #   * producer and consumer agree on which register file the value lives
      #     in, and at which width (see #vector_result_width). A double computed
      #     into a vector register is no use to a reader that expects it in a
      #     general-purpose one.
      #
      # The last gate is the whitelist below. An op only qualifies as a producer
      # if its final act is to store its result, and only as a consumer if it
      # reads its operands before disturbing anything — which is why a call is
      # neither: staging its arguments overwrites the very register the value
      # would be waiting in.
      PRODUCER_OPS = %i[
        const copy add sub mul mulhi and or xor shl sar shr neg
        eq ne lt le gt ge ult ule ugt uge
        fadd fsub fmul fdiv feq fne flt fle fgt fge itof ftoi ftof
        sext zext bit_scan popcount scaled_add load uload
        div mod udiv umod alloca
        addr_of object_addr string_addr global_addr func_addr got_addr
      ].freeze

      CONSUMER_OPS = %i[
        copy add sub mul mulhi and or xor shl sar shr neg
        eq ne lt le gt ge ult ule ugt uge
        fadd fsub fmul fdiv feq fne flt fle fgt fge itof ftoi ftof
        sext zext bit_scan popcount scaled_add load uload store memcpy
        div mod udiv umod alloca jump_if_zero ret
      ].freeze

      # The three whitelists above, and PURE_OPS, as lookup tables. The arrays
      # are the documentation — one line per op, in reading order, which is how
      # each of them is read and argued about — and these are what the scans ask
      # once per instruction.
      PURE = PURE_OPS.to_h { |op| [op, true] }.freeze
      PRODUCERS = PRODUCER_OPS.to_h { |op| [op, true] }.freeze
      CONSUMERS = CONSUMER_OPS.to_h { |op| [op, true] }.freeze

      # Which virtual registers a backend may leave in a register instead of
      # writing out, as an array indexed by register number holding true for a
      # transient and nil for everything else — the form the backends ask on
      # every store they emit. `param_count` names the leading slots the
      # prologue fills; `reads` and `writes` are #census of this very list.
      def transient_flags(insts, param_count, reads, writes, vreg_count = 0)
        flags = Array.new(vreg_count)
        index = 0
        size = insts.size
        while index < size
          inst = insts[index]
          index += 1
          vreg = inst.dst
          next if vreg.nil? || vreg < param_count
          next unless reads[vreg] == 1 && writes[vreg] == 1
          next unless PRODUCERS.key?(inst.op)

          reader = insts[index]
          next unless reader && CONSUMERS.key?(reader.op)
          next unless reads_vreg?(reader, vreg)
          next unless vector_result_width(inst) == vector_operand_width(reader, vreg)

          flags[vreg] = true
        end
        flags
      end

      # The same answer as a set of register numbers, for a caller that has no
      # census in hand and wants to read the result rather than index it.
      def transient_vregs(insts, param_count)
        reads, writes = census(insts)
        return Set.new if reads.nil?

        transient = Set.new
        transient_flags(insts, param_count, reads, writes).each_with_index do |flag, vreg|
          transient << vreg if flag
        end
        transient
      end

      # The width at which `inst` leaves its result in a vector register, or nil
      # when the result goes to a general-purpose one. :ftof is the one op whose
      # `size` names its *source*, so its destination is the other width.
      def vector_result_width(inst)
        case inst.op
        when :fadd, :fsub, :fmul, :fdiv, :itof then inst.size
        when :ftof then inst.size == 8 ? 4 : 8
        end
      end

      # The width at which `inst` reads `vreg` out of a vector register, or nil
      # when it reads it into a general-purpose one. A float comparison's result
      # is an int but its operands are floats; :itof is the mirror image, and
      # :ret carries the width in `size` only when returning a float or double
      # (an integer return leaves it nil, a struct return an array of pieces).
      def vector_operand_width(inst, _vreg)
        case inst.op
        when :fadd, :fsub, :fmul, :fdiv, :feq, :fne, :flt, :fle, :fgt, :fge, :ftoi, :ftof
          inst.size
        when :ret
          inst.size if inst.size.is_a?(Integer)
        end
      end

      # Drops every pure instruction whose result nothing reads, repeating until
      # nothing more falls out: removing one instruction removes its own reads,
      # which can make the instruction that produced *those* values dead in
      # turn (a fused subscript's element-size constant is reached in one round,
      # the sign extension feeding a discarded "i++" in two).
      #
      # Each round subtracts the reads it drops as it drops them rather than
      # counting the whole list again, which makes the passes over the list a
      # function of what is actually dead instead of of the depth of the chain.
      # Applying a subtraction inside the round it was made in can only bring a
      # removal forward from the next round to this one, never add or lose one:
      # an instruction with no readers keeps having none as more instructions
      # go, so the process removes exactly the instructions no chain of readers
      # reaches, whatever order it visits them in.
      #
      # `orphaned` is what ends the loop one round earlier than "a round that
      # dropped nothing" would: an instruction can only have *become* dead
      # through a subtraction that took one of its readers' counts to zero, so a
      # round in which no count reached zero has left nothing behind for the
      # next one to find. The commonest round of all is exactly that shape — the
      # element-size :const a fused subscript orphans reads nothing itself — so
      # the confirming pass over the whole list usually goes.
      def drop_dead_results(insts, reads, writes)
        loop do
          kept = nil
          orphaned = false
          index = 0
          size = insts.size
          while index < size
            inst = insts[index]
            dst = inst.dst
            if !dst.nil? && (reads[dst] || 0).zero? && PURE.key?(inst.op)
              kept ||= insts[0, index]
              each_operand_vreg(inst) do |vreg|
                count = reads[vreg] - 1
                reads[vreg] = count
                orphaned = true if count.zero?
              end
              writes[dst] -= 1
            elsif kept
              kept << inst
            end
            index += 1
          end
          return insts if kept.nil?

          insts = kept
          return insts unless orphaned
        end
      end
    end
  end
end
