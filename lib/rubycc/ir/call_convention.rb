# frozen_string_literal: true

module Rubycc
  module IR
    # One piece of a by-value aggregate as its convention moves it: the byte
    # `offset` within the aggregate the piece is read from (and written back to
    # at the far end), the `size` of that access, and the `kind` of place it
    # travels in (:gp an integer register, :sse4/:sse8 a vector one, :mem a
    # stack eightbyte).
    #
    # An aggregate is never moved as a whole — the generator takes it apart into
    # these pieces, loads each into a virtual register and hands the backend one
    # ABI slot per piece — so the piece list *is* the classification, and it is
    # exactly where the two conventions part ways. System V AMD64 always cuts on
    # eightbyte boundaries (offset 8*i, size 8, the eightbyte's class), while
    # AAPCS64 cuts a homogeneous floating aggregate along its members instead
    # (offset 4*i, size 4 for a struct of floats, each member its own vector
    # register). That is why a piece carries an offset and a width rather than
    # just an index: struct { float a, b; } is one eightbyte on x86-64 and two
    # single-precision registers on aarch64.
    AbiPiece = Data.define(:offset, :size, :kind)

    # How a convention passes one aggregate by value:
    #   :registers    — `pieces` names each register-borne piece;
    #   :memory       — the value is laid into the caller's stack argument area
    #                   whole, and a result of this shape is written through a
    #                   hidden pointer the caller passes as an ordinary leading
    #                   argument (System V AMD64's MEMORY class);
    #   :by_reference — the caller copies the value somewhere of its own and
    #                   passes the copy's *address* instead, and a result of
    #                   this shape is written through the convention's dedicated
    #                   indirect result register (AAPCS64's x8).
    # `even_gp` marks an aggregate whose first integer register must be an
    # even-numbered one (AAPCS64 rounds NGRN up for a composite of 16-byte
    # alignment, so it lands in an aligned x-register pair).
    AggregatePlan = Data.define(:mode, :pieces, :even_gp)

    # One argument as the placement pass sees it: the candidate kind of each of
    # its ABI slots, and the register alignment its aggregate demands. Placement
    # only ever needs to count and align, never to know a C type.
    ArgumentRequest = Data.define(:kinds, :even_gp)

    # The part of a target's calling convention the IR generator has to know
    # about, so that where every argument lands is decided once — where the
    # argument's C type is still in hand — rather than guessed at by a backend
    # that only sees a tag.
    #
    # Three things are target-specific and all three live here:
    #
    #  * how many registers there are to hand out. System V AMD64 offers six
    #    integer registers (rdi, rsi, rdx, rcx, r8, r9) and AAPCS64 eight
    #    (x0..x7); both offer eight vector ones. Getting the counts from the
    #    target is what lets a seventh integer argument reach x6 on aarch64
    #    instead of arriving tagged for the stack.
    #
    #  * how an aggregate is cut up and where the pieces go (#aggregate_plan).
    #    The System V eightbyte classification and the AAPCS64 HFA / 16-byte /
    #    by-reference rules disagree in ways that are silent when guessed at:
    #    struct { float a, b; } is one SSE eightbyte in xmm0 under System V and
    #    two single-precision registers, s0 and s1, under AAPCS64.
    #
    #  * how the register files are consumed as the argument list is walked
    #    (#placer). Both conventions place an argument as a unit, but they
    #    differ on what happens when one does not fit: System V leaves the
    #    registers it did not use available to a later argument, while AAPCS64
    #    declares the file exhausted (6.4.2 stage C sets NGRN or NSRN to eight),
    #    so a trailing int after a spilled two-register struct is in a register
    #    on x86-64 and on the stack on aarch64.
    #
    # `hidden_result_kind` is the kind of the implicit pointer to a
    # caller-provided result buffer: an ordinary leading integer argument under
    # System V, and its own mechanism (:indirect_result, the x8 register) under
    # AAPCS64.
    class CallConvention
      attr_reader :gp_registers, :fp_registers, :hidden_result_kind

      def initialize(gp_registers:, fp_registers:, hidden_result_kind: :gp)
        @gp_registers = gp_registers
        @fp_registers = fp_registers
        @hidden_result_kind = hidden_result_kind
        freeze
      end

      # The pieces a value of `size` bytes is cut into when it travels in the
      # stack argument area. Both conventions round a stack argument up to a
      # multiple of eight and align it to at least eight, so a spilled value is
      # ceil(size/8) whole eightbytes whatever shape it would have taken in
      # registers — an aarch64 HFA that runs out of vector registers is passed
      # as packed eightbytes, not as one stack slot per member.
      def self.memory_pieces(size)
        Array.new((size + 7) / 8) { |i| AbiPiece.new(offset: 8 * i, size: 8, kind: :mem) }
      end

      # The convention's plan for passing an aggregate of `type` by value.
      def aggregate_plan(_type)
        raise NotImplementedError
      end

      # A fresh running placement of one argument list (see the Placer classes).
      def placer
        raise NotImplementedError
      end
    end

    # System V AMD64 (psABI 3.2.3).
    class SystemVAMD64Convention < CallConvention
      def initialize
        super(gp_registers: 6, fp_registers: 8)
      end

      # Classifies an aggregate by the psABI's eightbyte rules. A struct or
      # union larger than two eightbytes — or one with any unaligned field — is
      # passed in memory; otherwise each of its one or two eightbytes gets a
      # class from the scalar fields that fall in it, :gp for an INTEGER
      # eightbyte and :sse8 for an SSE one (moved as a full 8-byte double even
      # when it holds two packed floats, since a single movsd carries the whole
      # eightbyte).
      #
      # The unaligned-field test is what a GNU __attribute__((packed)) demands
      # (Step 28): the psABI gives an aggregate "containing unaligned fields"
      # class MEMORY, and gcc follows it — a packed struct whose field would
      # straddle an eightbyte boundary is passed on the stack, not in registers.
      # Every non-packed layout here is naturally aligned, so this only ever
      # fires for a packed struct. (AAPCS64 has no such rule, which is one more
      # reason the classification cannot be shared.)
      def aggregate_plan(type)
        size = type.size
        if size > 16 || unaligned_field?(type, 0)
          return AggregatePlan.new(mode: :memory, pieces: CallConvention.memory_pieces(size), even_gp: false)
        end

        eightbytes = Array.new((size + 7) / 8, nil)
        classify_eightbytes(eightbytes, type, 0)
        # A NO_CLASS eightbyte (only padding fell in it) defaults to SSE, the
        # psABI's benign choice; INTEGER otherwise wins over SSE per #merge_class.
        pieces = eightbytes.each_with_index.map do |cls, i|
          AbiPiece.new(offset: 8 * i, size: 8, kind: cls == :integer ? :gp : :sse8)
        end
        AggregatePlan.new(mode: :registers, pieces: pieces, even_gp: false)
      end

      def placer
        Placer.new(self)
      end

      private

      # Whether any scalar field of `type`, placed at absolute byte offset
      # `base`, sits on an offset that does not satisfy its own alignment — the
      # mark of a packed layout. A nested aggregate recurses at its members'
      # offsets (a union's members all at 0) and an array at its element's; a
      # scalar checks base against its alignment directly.
      def unaligned_field?(type, base)
        if type.struct?
          # A bit-field is packed into a storage unit by design, so it is never an
          # "unaligned field" in the psABI sense; only its plain neighbours are
          # tested. gcc likewise passes a small bit-field struct in registers.
          type.members.reject(&:bitfield?).any? { |m| unaligned_field?(m.type, base + m.offset) }
        elsif type.array?
          unaligned_field?(type.element, base)
        else
          (base % type.alignment) != 0
        end
      end

      # Walks `type` at byte offset `base` and folds each scalar field's class
      # into the eightbyte (offset / 8) it lands in. A nested struct or union
      # recurses at its member offsets (a union overlays every member at the same
      # offset, which the members' zero offsets already encode), and an array
      # recurses element by element. A struct reaching here has already passed the
      # unaligned-field test in #aggregate_plan, so no scalar straddles an
      # eightbyte boundary and each falls wholly in the eightbyte at offset / 8.
      def classify_eightbytes(eightbytes, type, base)
        if type.struct?
          type.members.each do |m|
            if m.bitfield?
              classify_bitfield(eightbytes, base, m)
            else
              classify_eightbytes(eightbytes, m.type, base + m.offset)
            end
          end
        elsif type.array?
          type.length.times { |i| classify_eightbytes(eightbytes, type.element, base + i * type.element.size) }
        else
          # A scalar folds its class into every eightbyte it spans. All scalars but
          # a 128-bit integer fit in one (they are naturally aligned); a 16-byte
          # __int128 spans two, both INTEGER, so a struct wrapping one passes by
          # value in two integer registers, as gcc does.
          cls = type.float? ? :sse : :integer
          (base / 8..(base + type.size - 1) / 8).each do |index|
            eightbytes[index] = merge_class(eightbytes[index], cls)
          end
        end
      end

      # Folds a bit-field member into the eightbytes its bits span. Every
      # bit-field type in this subset is an integer type, so the field
      # contributes INTEGER to each eightbyte it touches (a field wide enough, or
      # placed so, that it straddles an eightbyte boundary marks both). `base` is
      # the enclosing aggregate's byte offset and the member's `bit_offset` its
      # bit position within that aggregate.
      def classify_bitfield(eightbytes, base, member)
        first_bit = base * 8 + member.bit_offset
        last_bit = first_bit + member.bit_width - 1
        (first_bit / 64..last_bit / 64).each do |index|
          eightbytes[index] = merge_class(eightbytes[index], :integer)
        end
      end

      # Combines two field classes sharing an eightbyte: NO_CLASS (nil) yields to
      # the other, and INTEGER dominates SSE (a mixed integer/float eightbyte is
      # passed in an integer register), matching the psABI merge rule this subset
      # needs.
      def merge_class(current, incoming)
        return incoming if current.nil?
        return current if incoming.nil?
        return :integer if current == :integer || incoming == :integer

        :sse
      end

      # Hands out the integer and SSE registers over one argument list. Each
      # argument is placed as a unit: its required registers of both files are
      # counted first, and only if *both* fit in what remains does it take them;
      # otherwise the whole argument spills and no register is consumed — the
      # psABI rule that an argument whose parts do not all fit in registers
      # passes wholly in memory, and the reason a later, smaller argument can
      # still be handed a register the spilled one could not use.
      class Placer
        def initialize(convention)
          @convention = convention
          @next_gp = 0
          @next_sse = 0
        end

        # :registers when the argument takes the registers its request asks for,
        # :stack when it passes in the overflow area. A request that is already
        # all-:mem (a MEMORY-classified aggregate) never wanted a register.
        def place(request)
          return :stack if request.kinds.all?(:mem)

          need_gp = request.kinds.count(:gp)
          need_sse = request.kinds.count { |kind| kind == :sse4 || kind == :sse8 }
          return :stack unless @next_gp + need_gp <= @convention.gp_registers &&
                               @next_sse + need_sse <= @convention.fp_registers

          @next_gp += need_gp
          @next_sse += need_sse
          :registers
        end
      end
    end

    # AAPCS64 (Procedure Call Standard for the Arm 64-bit Architecture, 6.4.2).
    class AAPCS64Convention < CallConvention
      # The most members a homogeneous floating aggregate may have and still
      # travel in vector registers (6.4.2 stage B: "at most four uniquely
      # addressable members"). A fifth member sends the whole aggregate by
      # reference, however small each member is.
      MAX_HFA_MEMBERS = 4

      # The largest aggregate that is passed in integer registers rather than by
      # reference. An HFA is exempt: four doubles are 32 bytes and still ride
      # d0..d3.
      MAX_REGISTER_AGGREGATE = 16

      def initialize
        super(gp_registers: 8, fp_registers: 8, hidden_result_kind: :indirect_result)
      end

      # Classifies an aggregate by AAPCS64 6.4.2, in the order the standard
      # tests it:
      #
      #  * a Homogeneous Floating-point Aggregate — every scalar in it, however
      #    deeply nested, is the same floating type, and there are at most four
      #    of them — puts each member in a vector register of its own. This is
      #    the rule with no System V counterpart at all: struct { float a, b; }
      #    is s0 and s1 here where System V packs both into one xmm0.
      #  * any other aggregate of 16 bytes or less takes one or two consecutive
      #    integer registers, whatever its members are (a packed struct
      #    included: AAPCS64 has no unaligned-field escape to memory). One whose
      #    alignment is 16 must start at an even-numbered register, which is
      #    what `even_gp` asks the placer for.
      #  * anything larger travels by reference: the caller copies it and passes
      #    the copy's address.
      def aggregate_plan(type)
        base, count = homogeneous_float(type)
        if base && count <= MAX_HFA_MEMBERS && type.size == base * count
          kind = base == 8 ? :sse8 : :sse4
          pieces = Array.new(count) { |i| AbiPiece.new(offset: base * i, size: base, kind: kind) }
          return AggregatePlan.new(mode: :registers, pieces: pieces, even_gp: false)
        end

        if type.size <= MAX_REGISTER_AGGREGATE
          pieces = Array.new((type.size + 7) / 8) { |i| AbiPiece.new(offset: 8 * i, size: 8, kind: :gp) }
          return AggregatePlan.new(mode: :registers, pieces: pieces, even_gp: type.alignment >= 16)
        end

        AggregatePlan.new(mode: :by_reference, pieces: [], even_gp: false)
      end

      def placer
        Placer.new(self)
      end

      private

      # Whether `type` is built entirely out of one floating type, and of how
      # many of them: [element_size, count], or nil for anything else. A struct
      # sums its members' counts, an array multiplies its element's by its
      # length, a union takes the widest member's (all of them overlay the same
      # storage), and a scalar float or double is one member of itself. A
      # bit-field, an integer or a pointer anywhere inside disqualifies the
      # whole aggregate at once.
      #
      # The count alone does not settle it: the caller also checks that the
      # aggregate's size is exactly count * element_size, which is what rejects
      # a struct that has been padded out of shape — struct { float a, b; }
      # __attribute__((aligned(16))) has two float members but occupies 16
      # bytes, and gcc passes it in x0/x1 rather than as an HFA.
      def homogeneous_float(type)
        if type.struct?
          homogeneous_members(type)
        elsif type.array?
          return nil if type.length.nil? || type.length.zero?

          element = homogeneous_float(type.element)
          element && [element[0], element[1] * type.length]
        elsif type.float?
          [type.size, 1]
        end
      end

      # The [element_size, count] of an aggregate's members, or nil when they
      # disagree (or when there are none, an aggregate C cannot form anyway).
      def homogeneous_members(type)
        return nil if type.members.nil? || type.members.empty?

        size = nil
        count = 0
        type.members.each do |member|
          return nil if member.bitfield?

          element = homogeneous_float(member.type)
          return nil if element.nil? || (size && size != element[0])

          size = element[0]
          count = type.union? ? [count, element[1]].max : count + element[1]
        end
        [size, count]
      end

      # Hands out x0..x7 and v0..v7 over one argument list, by 6.4.2 stage C.
      # An argument never draws on both files here (a scalar is one or the
      # other, an HFA is all vector, every other aggregate all integer, and an
      # aggregate passed by reference is just a pointer), so the two counters
      # advance independently.
      #
      # The difference from System V that matters is what an argument that does
      # not fit leaves behind: the standard sets NGRN (or NSRN) to eight, so the
      # file it overflowed is *exhausted* and every later argument of that class
      # goes to the stack as well. The other file is untouched — a spilled HFA
      # does not stop a following int from reaching x0.
      class Placer
        def initialize(convention)
          @convention = convention
          @ngrn = 0
          @nsrn = 0
        end

        def place(request)
          need_fp = request.kinds.count { |kind| kind == :sse4 || kind == :sse8 }
          return place_fp(need_fp) if need_fp.positive?

          need_gp = request.kinds.count(:gp)
          return place_gp(need_gp, request.even_gp) if need_gp.positive?

          # An :indirect_result pointer rides a register of its own (x8), which
          # is not part of either file's budget.
          :registers
        end

        private

        def place_fp(count)
          if @nsrn + count <= @convention.fp_registers
            @nsrn += count
            :registers
          else
            @nsrn = @convention.fp_registers
            :stack
          end
        end

        def place_gp(count, even)
          first = even && @ngrn.odd? ? @ngrn + 1 : @ngrn
          if first + count <= @convention.gp_registers
            @ngrn = first + count
            :registers
          else
            @ngrn = @convention.gp_registers
            :stack
          end
        end
      end
    end

    class CallConvention
      SYSTEM_V_AMD64 = SystemVAMD64Convention.new
      AAPCS64 = AAPCS64Convention.new
    end
  end
end
