# frozen_string_literal: true

require_relative "../compile_error"
require_relative "../ir/ir"
require_relative "../ir/analysis"
require_relative "../ir/promotion"
require_relative "../ir/simplify"
require_relative "slot_residency"

module Rubycc
  module Backend
    # Raised when a backend is handed an IR construct it does not yet lower.
    # It is a user-facing error rather than an internal one: the program is
    # valid C, this target simply cannot compile it yet, so the driver reports
    # it as a diagnostic instead of letting it surface as a Ruby crash.
    #
    # No backend raises it at the moment — the AArch64 one lowered its last gap
    # (alloca) in m4/aarch64-alloca-bitscan-2. The class and the driver's
    # handling of it stay because this is the contract a *new* target is written
    # against: a backend under construction refuses what it cannot yet lower
    # with `raise UnsupportedError, "<target>: not yet supported: <feature>"`
    # rather than emitting something plausible-looking.
    class UnsupportedError < Rubycc::Error; end

    # AArch64 (ARM64) code generator, the second backend behind the same
    # IR::Function -> Result contract the x86_64 one honors. It keeps the
    # spill-everything strategy for every value but the promoted one — each
    # virtual register owns an 8-byte stack slot and each IR instruction loads
    # its operands into scratch registers, computes, and stores the result back
    # — but the machine underneath is entirely different: fixed-length 32-bit
    # instructions, a flat register file, and load/store addressing that shapes
    # the frame layout.
    #
    # Frame layout (frame-base-relative, positive offsets). Unlike x86_64's
    # rbp-negative displacements, every slot is addressed as [base + off] with a
    # non-negative off, because AArch64's ldr/str unsigned-offset form scales a
    # 12-bit immediate by the access size (reaching 0..32760 for a 64-bit load)
    # while the signed form is only a 9-bit unscaled window (-256..255) that a
    # modest frame overruns at once. From the base upward the frame holds the
    # outgoing argument area, the saved frame record (x29/x30), the vreg slots,
    # the stack objects and the promoted registers' save slots. A slot whose
    # offset still overflows the scaled immediate is reached by composing its
    # address into a scratch register with add-immediate(s) — the path is built
    # in from the start rather than bolted on for large frames.
    #
    # The frame base is sp itself in an ordinary function, which costs nothing
    # and leaves x29 free. It is x29 in a function containing :alloca, because
    # there sp moves during the body and a slot named against it would change
    # address under the program's feet: the prologue copies sp into x29 once the
    # frame is set up and every fixed-frame access goes through
    # #frame_base_register from then on (see #emit_alloca).
    #
    # The outgoing argument area sits at the very bottom because AAPCS64 places
    # a call's stack arguments starting at the caller's sp, and it is reserved
    # once by the prologue — sized for the widest call in the function — rather
    # than pushed per call. That is the whole reason it exists: every value in
    # this backend is named as [sp + off], so moving sp to push arguments would
    # invalidate the offset of every slot at once, including the ones holding
    # the arguments still to be placed. Reserving the area up front leaves sp
    # fixed for the function's whole body, keeps it 16-aligned at the call (the
    # area's size is rounded to 16, and AAPCS64 requires sp 16-aligned at a
    # public interface), and costs nothing at run time. A function that makes no
    # call with stack arguments reserves nothing, so its frame is unchanged.
    #
    # A function containing :alloca is the exception, and it is the exception in
    # both directions: it reserves no static area (sp no longer names the bottom
    # of the fixed frame once a block has been allocated, so the area would be
    # unreachable) and instead lowers sp around each call, below the allocated
    # blocks. That is affordable precisely because the objection above no longer
    # applies — the slots are named against x29 there, so moving sp disturbs
    # nothing.
    #
    # Value representation is identical to the x86_64 backend's slot discipline
    # (see backend/x86_64.rb): a slot is always read and written 64 bits at a
    # time (ldr/str of an X register) so pointers survive intact, a value
    # narrower than 8 bytes lives sign/zero-extended in the low 32 bits with the
    # high half indeterminate, and 32-bit arithmetic runs on the W view of a
    # register — a W-register write zeroes the upper 32 bits, giving C's
    # wrap-around for `int` exactly as x86's eax does.
    #
    # AAPCS64 calling convention: the first eight integer/pointer arguments
    # arrive in x0..x7 and the result comes back in x0; the first eight
    # floating arguments arrive in v0..v7, allocated from a counter of their
    # own, and a floating result comes back in v0. The two sequences are
    # independent, exactly as System V's integer and xmm sequences are, which is
    # why the IR's :gp/:sse4/:sse8 tags carry over unchanged (:sse16, a whole
    # 16-byte value in one vector register, is this target's alone). The generator
    # classifies against this target's register budget (IR::CallConvention),
    # so a :gp tag really does mean one of the eight and a :mem tag really does
    # mean the stack — no seventh integer argument is spilled here that AAPCS64
    # would have kept in a register.
    #
    # A stack argument occupies eight bytes, whatever its type: AAPCS64 6.4.2
    # rounds each argument's size on the stack up to a multiple of eight and
    # aligns it to at least eight, so the IR's eightbyte view of the overflow
    # area is exactly the ABI's. A stack-passed `float` therefore travels as a
    # whole eightbyte whose low four bytes carry the value, which is what the
    # slot discipline already promises.
    #
    # Aggregates arrive here already cut into the pieces AAPCS64 6.4.2 moves
    # them in, the generator having classified them against this target's rules
    # rather than System V's (IR::CallConvention). What that leaves for this
    # backend is placing the pieces: an HFA's members each take a vector
    # register of their own, so struct { float a, b; } really does travel in s0
    # and s1 rather than packed into one — the one shape whose System V reading
    # would have been silently wrong rather than merely unsupported. A smaller
    # non-HFA aggregate's eightbytes take consecutive x registers, and one too
    # large for either is passed by reference, which the generator has already
    # reduced to an ordinary pointer argument.
    #
    # The one aggregate mechanism that needs a register no other kind names is
    # the indirect result: a result too large for registers is written through a
    # buffer address the caller puts in x8, tagged :indirect_result so it can be
    # kept clear of both argument sequences (see INDIRECT_RESULT_REGISTER).
    #
    # Under AAPCS64 a variadic call on this platform places its arguments in the
    # same registers a fixed call would, so the `fixed` half of a call's size
    # pair needs no action here — unlike System V, where it drives the count of
    # vector registers written to al.
    #
    # This backend covers the A2 core — control flow, integer arithmetic, local
    # variables, pointers to locals and direct calls — plus the A3 memory-access
    # layer (the addresses of global variables, string literals and functions,
    # formed with an adrp/add pair, and their -fPIC counterpart read from the
    # GOT with an adrp/ldr pair) and most of A4: indirect calls through a
    # function pointer, floating-point arithmetic, comparison, conversion,
    # argument passing and return, whole-object copies, aggregates passed and
    # returned by value, and variadic function definitions (a register-save-area
    # prologue and the AAPCS64 :va_start seed __builtin_va_arg walks), plus the
    # unsigned 64x64->128 multiply's high half (a single `umulh`) that a
    # synthesized 128-bit multiply needs, and the bit-scan builtins (`clz`, and
    # `rbit` before it for the trailing-zero direction). The atomic ops are
    # covered too, built from the armv8-a baseline load-acquire / store-release
    # exclusive pair (see the atomics section below), and dynamic stack
    # allocation, which moves sp below the fixed frame while x29 keeps that
    # frame addressable (see #emit_alloca). Every IR op the generator can hand
    # this backend is now lowered; there is nothing left it refuses.
    class AArch64
      # Every slot access goes through #load_reg / #store_reg, which use this to
      # skip a reload of a value the previous instruction has just left in a
      # register. See slot_residency.rb for why "nothing has been emitted since"
      # is a sufficient safety condition, and #emit_instruction's :label case
      # for the one state change it cannot see.
      include SlotResidency

      # Result of compiling one function, the same shape the x86_64 backend
      # returns: `bytes` the machine code, `symbols` an array of
      # { name:, offset:, size: }, and `relocations` an array of kind-tagged
      # records. The kinds emitted are :call (a `bl` site the linker fills in
      # with an R_AARCH64_CALL26) and the four address-forming kinds :string,
      # :global, :func and :got. Each of the latter records a single offset —
      # that of the leading `adrp` — even though it needs two ELF relocations;
      # splitting one record into the pair is the object writer's job, since how
      # many relocations an address costs is a property of the machine.
      Result = Data.define(:bytes, :symbols, :relocations)

      # Integer argument / result registers, in AAPCS64 order. Every argument
      # the IR classifies :gp lands here in order; an argument past the eighth
      # register, or one already classified onto the stack, is refused (see the
      # class comment).
      ARG_REGISTERS = [0, 1, 2, 3, 4, 5, 6, 7].freeze

      # Floating argument / result registers, v0..v7, allocated from a counter
      # independent of the integer one. They share the numbering of the integer
      # argument registers but not the register file: v0 and x0 are different
      # registers, so a call passing both an int and a double writes each once.
      FP_ARG_REGISTERS = [0, 1, 2, 3, 4, 5, 6, 7].freeze

      # x8, the indirect result register. AAPCS64 6.4.1 reserves it for the
      # address of the buffer a result too large for registers is written into,
      # which is what makes an aggregate return differ from System V's: there the
      # same pointer is an ordinary leading integer argument that eats x0's
      # equivalent, here it rides a register of its own and every real argument
      # keeps the place it would have had.
      INDIRECT_RESULT_REGISTER = 8

      # The registers an aggregate result comes back in, in piece order. An
      # integer piece fills x0 then x1 (an aggregate reaching here is 16 bytes or
      # less, so two is all it can need) and a floating one v0..v3 (an HFA has at
      # most four members). Which file a piece draws on follows its kind, so a
      # struct of two floats returns in s0/s1 while a struct of two longs returns
      # in x0/x1.
      RESULT_GP_REGISTERS = [0, 1].freeze
      RESULT_FP_REGISTERS = [0, 1, 2, 3].freeze

      # Scratch (temporary, caller-saved) registers used to evaluate one
      # instruction. A/B hold the two operands, C an extra working value (the
      # quotient a remainder needs), and ADDR composes a slot address when the
      # offset overruns the scaled load/store immediate. None is an argument
      # register, so spilling arguments never disturbs an address computation.
      A = 9
      B = 10
      C = 11
      ADDR = 12

      # Three further scratch registers, used only by the atomic sequences (see
      # #emit_atomic_cas), which are the one place a single IR instruction has
      # more values in flight than A/B/C hold: a compare-exchange juggles the
      # object address, the expected pointer, the expected value, the desired
      # value, the value actually read and the store-exclusive status at once.
      # x13..x15 are caller-saved temporaries like x9..x12 and are clear of
      # ADDR, so an address composed for a distant slot never collides with one
      # of them. (x16/x17 are deliberately skipped: the linker may insert a
      # veneer that clobbers them at any call site.)
      D = 13
      E = 14
      F = 15

      # The floating counterparts of A/B, holding the operands of one floating
      # instruction. v16..v31 are caller-saved like x9..x15 (v8..v15 are the
      # callee-saved vector registers, so they are avoided), and being clear of
      # v0..v7 means evaluating a floating value never disturbs an argument
      # already placed.
      FA = 16
      FB = 17

      # The registers whole-function promotion hands out, in the order it hands
      # them out (see IR::Promotion and #promotion_assignment). All ten are
      # callee-saved under AAPCS64 (5.1.1: x19..x28 are preserved across a
      # call), which is what lets a promoted value stay put across one, and all
      # ten are clear of everything else this backend names: the scratch
      # registers x9..x15, the argument/result registers x0..x8, the frame
      # pointer x29 and the link register x30.
      #
      # The three callee-saved-looking registers left out are left out on
      # purpose. x18 is the platform register, reserved by AAPCS64 5.1.1 for
      # whatever the running platform ABI wants it for, so no compiler may use
      # it as a general one. x16 and x17 (IP0/IP1) are corruptible by any
      # branch: the linker is free to insert a veneer at a `bl` site, and a
      # veneer clobbers them.
      #
      # Being disjoint from every register the residency table is keyed by is
      # what lets an instruction that writes a promoted register leave that
      # table standing (see SlotResidency#note_register_clobbered), and #load_reg
      # keeps the disjointness true from the other side by never recording a
      # residency against one.
      PROMOTION_REGISTERS = (19..28).to_a.freeze
      PROMOTION_REGISTER_SET = PROMOTION_REGISTERS.to_set.freeze

      # Special register numbers. In the load/store, add/sub-immediate and
      # stp/ldp encodings a register field of 31 denotes the stack pointer; in
      # the data-processing (arithmetic/logical shifted-register) encodings the
      # same 31 denotes the zero register, which is how `neg` (sub from xzr) and
      # `cmp` (subs into xzr) are formed.
      SP = 31
      XZR = 31
      FP = 29
      LR = 30

      # The saved frame record (x29, x30) occupies the lowest 16 bytes of the
      # frame; the first vreg slot sits just above it.
      SAVE_AREA_SIZE = 16

      # The largest byte offset the 64-bit scaled ldr/str immediate can name
      # (a 12-bit field scaled by 8). A slot beyond this is reached through a
      # composed address instead.
      MAX_SCALED_OFFSET = 4095 * 8

      # The largest byte offset the stp/ldp immediate can name (a 7-bit signed
      # field scaled by 8). The saved record is reached through a composed
      # address past this.
      MAX_PAIR_OFFSET = 63 * 8

      # IR comparison op -> AArch64 condition code applied to the flags left by
      # `cmp a, b` (a - b). The signed forms use the N/V-based conditions
      # (lt/le/gt/ge), the unsigned ones the carry-based conditions
      # (lo/ls/hi/hs), which is what an unsigned or pointer comparison needs.
      CONDITIONS = {
        eq: 0,  ne: 1,
        lt: 11, le: 13, gt: 12, ge: 10,
        ult: 3, ule: 9, ugt: 8, uge: 2
      }.freeze

      # IR floating comparison -> the condition code applied to the flags left by
      # `fcmp a, b`. FCMP reports an unordered compare (either operand NaN) as
      # N=0 Z=0 C=1 V=1, a combination no ordered result produces, and the four
      # conditions below are chosen so every one of them reads false there — which
      # is what C requires of <, <=, > and >= against a NaN:
      #
      #   :flt -> MI (N set)       only a strictly-less compare sets N
      #   :fle -> LS (C clear or Z) less clears C, equal sets Z; unordered sets C
      #                             and clears Z
      #   :fgt -> GT (Z clear, N=V) unordered has N=0, V=1, so N != V
      #   :fge -> GE (N=V)          likewise false when unordered
      #
      # Equality needs no combining pair the way x86's ucomis does: FCMP leaves Z
      # clear for an unordered compare (where x86 sets ZF), so plain EQ is already
      # false on NaN and plain NE already true.
      FLOAT_CONDITIONS = {
        feq: 0, fne: 1,
        flt: 4, fle: 9, fgt: 12, fge: 10
      }.freeze

      # `analysis` is the census of `ir_func`'s instruction list (IR::Analysis).
      # The compiler passes the one IR::Simplify already took on its way
      # through; a caller that hands over a function directly gets it taken
      # here.
      def compile(ir_func, analysis = IR::Analysis.of(ir_func))
        @code = +"".b
        reset_slot_residency
        # Slots this function never has to write: an expression temporary whose
        # one reader is the instruction right behind its producer stays in the
        # register it was computed in (see IR::Simplify#transient_flags and
        # #store_reg). The answer is a property of the instruction list, so it
        # is taken once here rather than rediscovered per instruction, and it
        # arrives as an array indexed by vreg number — the numbers are dense and
        # small, and this is asked on every store the backend emits.
        @transient = analysis.transient
        # Slots this function does not have at all: a promoted value lives in
        # one callee-saved register from the prologue to the epilogue, so its
        # slot is never read, written or named (see #promotion_assignment,
        # #load_reg and #store_reg). Like @transient this is a property of the
        # instruction list, decided once here, and indexed by vreg number for
        # the same reason.
        @promoted = promotion_assignment(ir_func, analysis)
        # @labels maps a label id to its resolved byte offset; @fixups collects
        # [patch_offset, label_id, kind] for each forward/backward branch whose
        # immediate is written once every label offset is known.
        @labels = {}
        @fixups = []
        @relocations = []

        # Kept for :va_start, which reads the named parameters' register classes
        # to seed __gr_offs / __vr_offs past the registers the fixed arguments
        # consumed.
        @param_kinds = ir_func.param_kinds
        layout_frame(ir_func.vreg_count, ir_func.stack_objects, ir_func.insts, ir_func.variadic)
        emit_prologue(ir_func.param_kinds, ir_func.variadic)
        ir_func.insts.each { |inst| emit_instruction(inst) }
        resolve_fixups

        Result.new(
          bytes: @code,
          symbols: [{ name: ir_func.name, offset: 0, size: @code.bytesize }],
          relocations: @relocations
        )
      end

      private

      # Binds the best promotion candidates to PROMOTION_REGISTERS in order,
      # returning the vreg -> register table the whole backend consults (an
      # array; a vreg that owns no register indexes nil). Taking the first few
      # of an ordered list is the entire allocation: one register each, held for
      # the function's length, so there is no interference to resolve and
      # nothing to undo when the registers run out — the candidates past the
      # tenth simply keep their slots.
      #
      # @promoted_registers is the same binding in assignment order, which is
      # the order the save slots are laid out in (#layout_frame).
      def promotion_assignment(ir_func, analysis)
        vregs = IR::Promotion.candidates(ir_func, analysis).first(PROMOTION_REGISTERS.size)
        @promoted_registers = PROMOTION_REGISTERS.first(vregs.size)
        promoted = Array.new(ir_func.vreg_count)
        vregs.each_with_index { |vreg, index| promoted[vreg] = PROMOTION_REGISTERS[index] }
        promoted
      end

      # Computes the frame's size and every object's base offset. From sp
      # upward: the outgoing argument area (empty unless some call in this
      # function passes an argument on the stack), the 16-byte saved record,
      # the vreg slots (8 bytes each, the region rounded to 16 so the objects
      # stay 16-aligned), then each stack object at a 16-byte-aligned size above
      # the previous, then one 8-byte save slot per promoted register. All
      # offsets are non-negative displacements from the frame base, which this
      # method also decides (see #frame_base_register).
      def layout_frame(vreg_count, stack_objects, insts, variadic)
        # Whether this function allocates dynamically decides two things at
        # once: which register names the fixed frame (see #frame_base_register)
        # and whether a static outgoing argument area is worth reserving. It is
        # a property of the whole function, not of a path through it, because a
        # slot's address must not depend on which branch reached it.
        @uses_alloca = insts.any? { |inst| inst.op == :alloca }
        # An alloca function reserves no static outgoing area: sp stops naming
        # the bottom of the fixed frame the moment a block is allocated, so the
        # area would be unreachable at the one moment it is needed. Each call
        # lowers sp for its own area instead (see #place_arguments).
        @outgoing_size = @uses_alloca ? 0 : outgoing_argument_bytes(insts)
        @save_offset = @outgoing_size
        vreg_region = align16(vreg_count * 8)
        running = @save_offset + SAVE_AREA_SIZE + vreg_region
        @object_offsets = []
        stack_objects.each do |object_size|
          @object_offsets << running
          running += align16(object_size)
        end
        # One save slot per promoted register, above every object. The
        # registers are callee-saved, so a function that takes one over has to
        # give it back exactly as it found it. This end of the frame is the one
        # place a new region can go without moving anything: the outgoing
        # argument area has to stay at the bottom (AAPCS64 has the callee read
        # its stack arguments from the sp of the `bl`), the saved record and the
        # vreg slots are what every offset in the body is measured against, and
        # the objects sit between. Putting the saves last therefore leaves every
        # other offset exactly what it would have been without promotion. Their
        # number is odd as often as not, but nothing above them cares: the one
        # region that has to end exactly at the frame's top is the variadic
        # register-save area, and a variadic function has no promoted register
        # at all (IR::Promotion refuses one), so the two never meet. The single
        # align16 below is what fixes the frame size, so sp stays 16-aligned
        # whatever the count. They are laid out in assignment order,
        # a function of the instruction list, so the frame stays deterministic
        # (N4).
        @promoted_saves = @promoted_registers.map do |reg|
          offset = running
          running += 8
          [reg, offset]
        end
        # A variadic function reserves the argument register-save area at the
        # very top of the frame — just below the caller's sp, exactly where the
        # AArch64 C library expects __gr_top/__vr_top to point. The vector area
        # (eight 16-byte slots) sits below the integer one (eight 8-byte slots),
        # and both tops (the ends of each) are the addresses :va_start writes.
        # The whole block is 192 bytes, a multiple of 16, so the frame stays
        # 16-aligned; a non-variadic function reserves nothing here.
        @vr_save_offset = @gr_save_offset = @gr_top_offset = @vr_top_offset = nil
        if variadic
          @vr_save_offset = running
          running += FP_ARG_REGISTERS.size * 16
          @vr_top_offset = running
          @gr_save_offset = running
          running += ARG_REGISTERS.size * 8
          @gr_top_offset = running
        end
        @frame_size = align16(running)
      end

      # The size of the outgoing argument area: eight bytes per stack argument
      # of the call in this function that passes the most of them, rounded to 16
      # so the saved record above it — and sp itself at every call — stays
      # 16-aligned. Sizing it for the widest call lets every call share the one
      # area, since only one call is in flight at a time.
      #
      # A :pad_stack slot occupies an eightbyte of the area exactly as a :mem
      # one does — it is the gap that 16-aligns the argument behind it — so it
      # is counted here on the same footing. #place_arguments counts the two
      # together as well, and the two counts have to agree or a call would write
      # past the area the frame reserved for it.
      def outgoing_argument_bytes(insts)
        widest = 0
        insts.each do |inst|
          next unless inst.op == :call || inst.op == :call_indirect

          count = inst.b.count { |_vreg, kind| kind == :mem || kind == :pad_stack }
          widest = count if count > widest
        end
        align16(widest * 8)
      end

      # sp + 8*n above the saved record: the byte offset of vreg n's slot.
      def slot_offset(vreg)
        @save_offset + SAVE_AREA_SIZE + 8 * vreg
      end

      # The byte offset of incoming stack argument `index`. The caller laid its
      # stack arguments out from its own sp upward, and this function's prologue
      # lowered sp by the whole frame, so the caller's sp is [sp + @frame_size]
      # here. Nothing sits between the two — AArch64 keeps the return address in
      # x30 rather than pushing it — so the first stack argument is at exactly
      # that address.
      def incoming_stack_offset(index)
        @frame_size + 8 * index
      end

      # Lowers sp by the frame size, saves x29/x30 into the record just above
      # the outgoing argument area, and spills the incoming arguments to their
      # parameter slots. In an ordinary function x29 is not used as a frame
      # pointer (every slot is sp-relative), but the pair is saved and restored
      # so the callee-saved x29 and the return address in x30 round-trip across
      # any call this function makes.
      #
      # An alloca function additionally anchors the fixed frame in x29. The
      # order matters and is forced: the caller's x29 has to reach the saved
      # record before it is overwritten, and the copy has to happen before the
      # parameters are spilled, since those stores already go through the frame
      # base. The record itself is therefore stored against sp explicitly rather
      # than through #frame_base_register, which at that instant would name a
      # register holding the caller's value.
      def emit_prologue(param_kinds, variadic)
        adjust_sp(@frame_size, sub: true)
        emit_save_record(store: true, base: SP)
        emit_add_imm(FP, SP, 0, shift12: false) if @uses_alloca # mov x29, sp
        # Before anything writes a promoted register — which the parameter
        # spilling right below is the first thing to do, a promoted parameter
        # being moved straight from the register it arrived in — and after the
        # frame base is established, since the saves are addressed against it.
        emit_save_promoted_registers
        spill_parameters(param_kinds)
        save_argument_registers if variadic
      end

      # Saves the promoted registers into their frame slots, one "str Xn,
      # [base + off]" apiece. A store into the frame rather than a push (or an
      # stp pair) keeps sp's 16-byte alignment a property of the single frame
      # adjustment in the prologue instead of the parity of the register count.
      def emit_save_promoted_registers
        @promoted_saves.each { |reg, offset| store_frame_at(reg, offset) }
      end

      # Puts the caller's values back, the exact inverse of
      # #emit_save_promoted_registers. #emit_epilogue carries it, and an
      # epilogue is emitted at every :ret rather than once per function, so a
      # function with several returns restores on each of them and no path
      # leaves with a callee-saved register holding this function's value.
      def emit_restore_promoted_registers
        @promoted_saves.each { |reg, offset| load_frame_at(reg, offset) }
      end

      # Spills every argument register into the variadic save area so a later
      # :va_start can hand __builtin_va_arg a pointer to each. The eight integer
      # registers go into the 8-byte slots at the top of the frame and the eight
      # vector ones into the 16-byte slots below them; parameter spilling above
      # only read the argument registers, so each still holds its incoming value
      # here. A vector register is saved at its low 8 bytes (the double a
      # va_arg(double) reads back) rather than the full 16 — like the x86_64
      # backend's movsd, this subset never fetches a wider vector argument — which
      # keeps the store to the ordinary 64-bit form. All eight of each file are
      # saved unconditionally, keeping the prologue's shape fixed regardless of
      # how many arguments the fixed part named.
      def save_argument_registers
        ARG_REGISTERS.each_with_index do |reg, i|
          store_frame_at(reg, @gr_save_offset + 8 * i)
        end
        FP_ARG_REGISTERS.each_with_index do |reg, i|
          emit_fp_slot_access(reg, @vr_save_offset + 16 * i, 8, load: false)
        end
      end

      # :va_start — fills the five AAPCS64 va_list fields at the address in
      # `ap_vreg`'s slot, seeding __builtin_va_arg's walk of the register-save
      # area the prologue laid down. The named parameters' classes (from
      # @param_kinds, the generator having resolved register-vs-stack placement)
      # count how far the fixed part consumed each register file: `named_gp` of
      # the eight integer registers and `named_fp` of the eight vector ones, the
      # rest being where the variable part begins. The fields (their byte offsets
      # fixed by AArch64VaListTag):
      #   [A+0]  __stack   = sp + frame_size + 8*named_stack (the first stacked
      #                      variable argument, past any named parameter that
      #                      itself spilled onto the caller's stack)
      #   [A+8]  __gr_top  = sp + gr_top_offset (the end of the integer area)
      #   [A+16] __vr_top  = sp + vr_top_offset (the end of the vector area)
      #   [A+24] __gr_offs = -(8 - named_gp) * 8   (negative, climbs to zero)
      #   [A+28] __vr_offs = -(8 - named_fp) * 16
      def emit_va_start(ap_vreg)
        # An alignment pad consumes a register/stack slot as much as a real
        # named argument does, so it counts toward where the variable part begins.
        named_gp = @param_kinds.count(:gp) + @param_kinds.count(:pad)
        named_fp = @param_kinds.count(:sse4) + @param_kinds.count(:sse8)
        named_stack = @param_kinds.count(:mem) + @param_kinds.count(:pad_stack)
        gr_offs = -(ARG_REGISTERS.size - named_gp) * 8
        vr_offs = -(FP_ARG_REGISTERS.size - named_fp) * 16

        load_reg(A, ap_vreg) # A = &__va_list
        emit_slot_address(B, incoming_stack_offset(named_stack))
        emit_piece_access(B, A, 0, 8, load: false, fp: false)
        emit_slot_address(B, @gr_top_offset)
        emit_piece_access(B, A, 8, 8, load: false, fp: false)
        emit_slot_address(B, @vr_top_offset)
        emit_piece_access(B, A, 16, 8, load: false, fp: false)
        materialize(B, gr_offs, 32)
        emit_piece_access(B, A, 24, 4, load: false, fp: false)
        materialize(B, vr_offs, 32)
        emit_piece_access(B, A, 28, 4, load: false, fp: false)
      end

      # Restores x29/x30, raises sp back, and returns. Emitted at every :ret.
      #
      # In an alloca function sp is wherever the last allocation left it, so it
      # is first brought back to the fixed frame from the anchor in x29. That
      # single instruction releases every block allocated in the body at once —
      # the storage lives until the function returns, as C requires, not until
      # the end of the scope that allocated it. The record is then reloaded and
      # the fixed frame released exactly as in an ordinary function (sp and x29
      # are equal by then, so the reload needs no special base).
      #
      # The promoted registers are given back here, after the return value has
      # been loaded (it may itself come out of one) and — in an alloca function
      # — after sp has been brought back to the fixed frame, which is the
      # moment the save slots become addressable again through sp. They are in
      # fact reached through x29 there, so the order is not what makes this
      # correct; it is what keeps the two cases reading the same way.
      def emit_epilogue
        emit_add_imm(SP, FP, 0, shift12: false) if @uses_alloca # mov sp, x29
        emit_restore_promoted_registers
        emit_save_record(store: false)
        adjust_sp(@frame_size, sub: false)
        emit_word(0xD65F03C0) # ret (branch to x30)
      end

      # Stores or reloads the x29/x30 pair at [base + @save_offset], `base`
      # defaulting to the frame base. The stp/ldp immediate is a 7-bit signed
      # field scaled by 8, so it reaches 504 bytes; an outgoing argument area
      # wider than that (a call with 64 or more stack arguments) is addressed
      # through the ADDR scratch instead, which holds no live value in either
      # the prologue or the epilogue.
      def emit_save_record(store:, base: nil)
        base ||= frame_base_register
        if @save_offset <= MAX_PAIR_OFFSET
          store ? emit_stp(FP, LR, base, @save_offset) : emit_ldp(FP, LR, base, @save_offset)
        else
          emit_base_address(ADDR, base, @save_offset)
          store ? emit_stp(FP, LR, ADDR, 0) : emit_ldp(FP, LR, ADDR, 0)
        end
      end

      # Brings each incoming argument into its home — its parameter slot, or
      # the callee-saved register it was promoted into, which #store_reg
      # decides — so it reads back like any other vreg. Integer/pointer
      # parameters come out of x0..x7 and floating ones out of v0..v7, each
      # sequence advancing its own counter; a :mem parameter is copied down
      # from the caller's stack argument area (through the A scratch, which is
      # not an argument register, so the copies never disturb an argument still
      # to be spilled, or through its promoted register) as a whole eightbyte,
      # which is right for a narrow or floating value too since the slot
      # discipline only promises its low bytes. A kind that would overrun its
      # register file is a generator contract violation and raises.
      def spill_parameters(param_kinds)
        next_gp = 0
        next_fp = 0
        next_stack = 0
        param_kinds.each_with_index do |kind, i|
          case kind
          when :gp
            raise "parameter :gp overruns the integer registers" if next_gp >= ARG_REGISTERS.size

            store_reg(ARG_REGISTERS[next_gp], i)
            next_gp += 1
          when :mem
            # Straight into the register a promoted parameter lives in: the
            # copy down from the caller's area is a load like any other, and
            # its destination is a free field, so nothing is gained by routing
            # it through A first. #store_reg then emits nothing at all, the
            # value being already home.
            target = @promoted[i] || A
            load_frame_at(target, incoming_stack_offset(next_stack))
            store_reg(target, i)
            next_stack += 1
          when :pad
            # An even-pair alignment pad consumes one integer register but binds
            # no parameter, so its slot is left unwritten and only the counter moves.
            next_gp += 1
          when :pad_stack
            # A stack alignment pad likewise consumes one incoming stack eightbyte
            # with no bound parameter.
            next_stack += 1
          when :sse4, :sse8
            raise "parameter #{kind} overruns the vector registers" if next_fp >= FP_ARG_REGISTERS.size

            store_fp(FP_ARG_REGISTERS[next_fp], i, kind == :sse8 ? 8 : 4)
            next_fp += 1
          when :indirect_result
            # The caller's result-buffer address arrives in x8, which is
            # caller-saved and would not survive the first call this function
            # makes; spilling it here, before any of them, is what lets the
            # eventual :ret still write through it.
            store_reg(INDIRECT_RESULT_REGISTER, i)
          else
            raise "unknown parameter kind #{kind.inspect}"
          end
        end
      end

      def emit_instruction(inst)
        # Once, at the top, rather than in each lowering that consults the
        # table. An instruction whose operands are all promoted loads nothing,
        # so it can reach #store_result — which revalidates the table — without
        # any of the loads that would otherwise have discarded a stale one
        # first. Refreshing here means the table is either true or empty by the
        # time any lowering touches it, whatever the instruction turns out to
        # be.
        refresh_slot_residency
        case inst.op
        when :const then emit_const(inst.dst, inst.a, inst.size)
        when :copy then emit_copy(inst.dst, inst.a)
        when :add then emit_arith(inst, ADD_SHIFTED, commutative: true)
        when :scaled_add then emit_scaled_add(inst.dst, inst.a, inst.b, inst.size)
        when :sub then emit_arith(inst, SUB_SHIFTED)
        when :and then emit_arith(inst, AND_SHIFTED, commutative: true)
        when :or then emit_arith(inst, ORR_SHIFTED, commutative: true)
        when :xor then emit_arith(inst, EOR_SHIFTED, commutative: true)
        when :mul then emit_mul(inst.dst, inst.a, inst.b, inst.size)
        when :div then emit_divmod(inst.dst, inst.a, inst.b, inst.size, signed: true, remainder: false)
        when :mod then emit_divmod(inst.dst, inst.a, inst.b, inst.size, signed: true, remainder: true)
        when :udiv then emit_divmod(inst.dst, inst.a, inst.b, inst.size, signed: false, remainder: false)
        when :umod then emit_divmod(inst.dst, inst.a, inst.b, inst.size, signed: false, remainder: true)
        when :shl then emit_shift(inst.dst, inst.a, inst.b, inst.size, LSLV)
        when :sar then emit_shift(inst.dst, inst.a, inst.b, inst.size, ASRV)
        when :shr then emit_shift(inst.dst, inst.a, inst.b, inst.size, LSRV)
        when :neg then emit_neg(inst.dst, inst.a, inst.size)
        when :eq, :ne, :lt, :le, :gt, :ge, :ult, :ule, :ugt, :uge
          emit_comparison(inst.dst, inst.a, inst.b, CONDITIONS.fetch(inst.op), inst.size,
                          commutative: inst.op == :eq || inst.op == :ne)
        when :sext then emit_sext(inst.dst, inst.a, inst.size)
        when :zext then emit_zext(inst.dst, inst.a, inst.size)
        when :label
          # The one place a register's meaning changes without an instruction
          # being emitted: control may arrive here from a branch whose registers
          # hold something else entirely, so nothing may be assumed resident
          # past a label (see SlotResidency).
          forget_slot_residency
          @labels[inst.a] = @code.bytesize
        when :jump then emit_b(inst.a)
        when :jump_if_zero then emit_jump_if_zero(inst.a, inst.b)
        when :call then emit_call(inst.dst, inst.a, inst.b, inst.size)
        when :addr_of then emit_slot_address_to(inst.dst, slot_offset(inst.a))
        when :object_addr then emit_slot_address_to(inst.dst, @object_offsets[inst.a])
        when :load then emit_load(inst.dst, inst.a, inst.size, signed: true)
        when :uload then emit_load(inst.dst, inst.a, inst.size, signed: false)
        when :store then emit_store(inst.a, inst.b, inst.size)
        when :ret then emit_ret(inst.a, inst.size)
        when :fadd then emit_float_binary(inst, FADD)
        when :fsub then emit_float_binary(inst, FSUB)
        when :fmul then emit_float_binary(inst, FMUL)
        when :fdiv then emit_float_binary(inst, FDIV)
        when :feq, :fne, :flt, :fle, :fgt, :fge
          emit_float_comparison(inst.dst, inst.a, inst.b, FLOAT_CONDITIONS.fetch(inst.op), inst.size)
        when :itof then emit_itof(inst.dst, inst.a, inst.b, inst.size)
        when :ftoi then emit_ftoi(inst.dst, inst.a, inst.b, inst.size)
        when :ftof then emit_ftof(inst.dst, inst.a, inst.size)
        when :call_indirect then emit_call_indirect(inst.dst, inst.a, inst.b, inst.size)
        when :mulhi then emit_mulhi(inst.dst, inst.a, inst.b)
        when :bit_scan then emit_bit_scan(inst.dst, inst.a, inst.b, inst.size)
        when :string_addr then emit_symbol_address(inst.dst, kind: :string, string_id: inst.a)
        when :global_addr then emit_symbol_address(inst.dst, kind: :global, symbol: inst.a)
        when :func_addr then emit_symbol_address(inst.dst, kind: :func, symbol: inst.a)
        when :got_addr then emit_got_address(inst.dst, inst.a)
        when :memcpy then emit_memcpy(inst.a, inst.b, inst.size)
        when :atomic_load then emit_atomic_load(inst.dst, inst.a, inst.size)
        when :atomic_store then emit_atomic_store(inst.a, inst.b, inst.size)
        when :atomic_rmw then emit_atomic_rmw(inst.dst, inst.a, inst.b[0], inst.b[1], inst.size)
        when :atomic_cas then emit_atomic_cas(inst.dst, inst.a, inst.b[0], inst.b[1], inst.size)
        when :atomic_fence then emit_atomic_fence
        when :va_start then emit_va_start(inst.a)
        when :alloca then emit_alloca(inst.dst, inst.a)
        else
          raise "aarch64: unsupported IR op: #{inst.op}"
        end
      end

      # :const — materializes an immediate into the destination slot. A size-8
      # constant is built as a full 64-bit value (a long/pointer); otherwise a
      # 32-bit value whose W-register move zeroes the slot's high half, matching
      # the x86_64 backend's "mov eax, imm32" behavior.
      def emit_const(dst, value, size)
        target = result_register(dst)
        materialize(target, value, size == 8 ? 64 : 32)
        store_result(target, dst, only_wrote: target) # movz/movk write target alone
      end

      # :copy — a 64-bit transfer between the two values' homes, whichever
      # those are: slot to slot, slot to register, register to slot, or one
      # `mov` between two promoted registers.
      def emit_copy(dst, src)
        target = result_register(dst)
        load_reg(target, src)
        store_result(target, dst, only_wrote: target) # the load wrote target, or nothing
      end

      # An arithmetic/logical binary op, combined with a shifted-register
      # instruction whose width follows the IR size (64-bit for size 8,
      # otherwise a 32-bit W-register op whose upper half is zeroed for free).
      # All three of Rd, Rn and Rm are free fields, so each end is named
      # wherever it lives: a promoted destination and two promoted operands
      # make the whole instruction one word with no traffic around it.
      def emit_arith(inst, base_table, commutative: false)
        rn, rm = binary_operand_registers(inst.a, inst.b, commutative: commutative)
        rd = result_register(inst.dst)
        emit_word(base_table[width(inst.size)] | (rm << 16) | (rn << 5) | rd)
        store_result(rd, inst.dst, only_wrote: rd) # one word, Rd its only written field
      end

      # :scaled_add — dst <- base + index * element_size, the address a
      # subscript forms. The shifted-register add carries the scale in its imm6
      # field as a left shift of the second operand, so the element-size
      # multiply and the add to the base are one instruction. It is always the
      # 64-bit (X) form: the value being computed is a pointer.
      def emit_scaled_add(dst, base_vreg, index_vreg, element_size)
        rn, rm = binary_operand_registers(base_vreg, index_vreg)
        rd = result_register(dst)
        shift = SHIFTED_SCALES.fetch(element_size)
        emit_word(ADD_SHIFTED[64] | (rm << 16) | (shift << 10) | (rn << 5) | rd)
        store_result(rd, dst, only_wrote: rd) # one word, Rd its only written field
      end

      # :mul — Rd = Rn * Rm, encoded as `madd Rd, Rn, Rm, xzr`.
      def emit_mul(dst, a, b, size)
        rn, rm = binary_operand_registers(a, b, commutative: true)
        rd = result_register(dst)
        base = size == 8 ? 0x9B007C00 : 0x1B007C00 # madd with Ra = xzr
        emit_word(base | (rm << 16) | (rn << 5) | rd)
        store_result(rd, dst, only_wrote: rd) # one word, Rd its only written field
      end

      # :mulhi — the unsigned high 64 bits of a 64x64 product, encoded as
      # `umulh Rd, Rn, Rm`. It is a "data-processing (3 source)" instruction
      # like madd/msub, but with op31 = 110 rather than 000 and Ra fixed to
      # xzr (the field the format still carries but this variant ignores);
      # unlike :mul it has no 32-bit operand form (there is no 16-bit-high-
      # of-a-32x32-product need for it here), so this always runs on the X
      # registers regardless of the IR size.
      def emit_mulhi(dst, a, b)
        rn, rm = binary_operand_registers(a, b, commutative: true)
        rd = result_register(dst)
        emit_word(UMULH | (rm << 16) | (rn << 5) | rd)
        store_result(rd, dst, only_wrote: rd) # one word, Rd its only written field
      end

      # :bit_scan — count the zero bits of a's value (__builtin_ctz/clz and
      # their "ll" forms). AArch64 has a count-leading-zeros instruction but no
      # trailing-zeros one, which decides the shape of both directions:
      #
      #   :reverse (clz) is CLZ on its own — the instruction *is* the leading
      #     zero count, so unlike x86-64 (where `bsr` yields the index of the
      #     highest set bit and the count is recovered by xor-ing with width-1)
      #     nothing follows it.
      #   :forward (ctz) is RBIT then CLZ. RBIT reverses the bit order within
      #     the register, so the operand's lowest set bit becomes the reversal's
      #     highest: the leading zeros of the reversed value are exactly the
      #     trailing zeros of the original.
      #
      # Both are "Data-processing (1 source)" instructions (ARM DDI 0487,
      # C4.1.2) differing only in their opcode field, and both come in a 32-bit
      # (W) and a 64-bit (X) form selected by sf — which is what makes the IR's
      # size 4 count within `unsigned int` and size 8 within `unsigned long`
      # rather than over a slot's indeterminate high half. A zero operand is
      # undefined behavior (as in gcc), so no guard is emitted; note that the
      # hardware would define it (CLZ of zero is the register width) but the IR
      # promises nothing there and the x86-64 backend cannot match it anyway.
      def emit_bit_scan(dst, src_vreg, direction, size)
        w = width(size)
        rn = operand_register(src_vreg, A)
        rd = result_register(dst)
        if direction == :forward
          emit_word(RBIT[w] | (rn << 5) | rd)
          rn = rd # the reversal is what CLZ counts, wherever it landed
        end
        emit_word(CLZ[w] | (rn << 5) | rd)
        store_result(rd, dst, only_wrote: rd) # RBIT and CLZ both write rd and nothing else
      end

      # :alloca — dynamic stack allocation (__builtin_alloca). The requested
      # byte count is rounded up to a multiple of 16 (add 15, then clear the low
      # four bits), sp is lowered by that much, and the resulting sp — the
      # lowest address of the block, the stack growing down — is the value the
      # destination slot receives.
      #
      # Rounding to 16 is what keeps sp 16-aligned, which AAPCS64 requires of it
      # at every public interface and which incidentally gives the block the
      # 16-byte alignment gcc's __builtin_alloca promises. The mask is a single
      # AND (immediate): 0xFFFF_FFFF_FFFF_FFF0 is a run of 60 ones, so it is
      # expressible as a bitmask immediate (N = 1, immr = 60, imms = 59) rather
      # than needing the four-instruction movz/movk sequence a general 64-bit
      # constant costs.
      #
      # The subtraction has to be the *extended-register* form: the ordinary
      # shifted-register sub reads register 31 as the zero register, and only
      # the extended form (and add/sub-immediate) reads it as sp.
      #
      # Nothing else in the function has to change position for this to be safe,
      # because #layout_frame has already switched every fixed-frame access to
      # x29 (see #frame_base_register) and every call to reserving its outgoing
      # argument area below the allocated blocks (see #place_arguments). The
      # blocks are released wholesale by the epilogue's "mov sp, x29".
      def emit_alloca(dst, size_vreg)
        load_reg(A, size_vreg)                        # A = requested byte count
        emit_add_imm(A, A, 15, shift12: false)        # add A, A, #15
        emit_word(AND_NOT15 | (A << 5) | A)           # and A, A, #-16
        emit_word(SUB_EXTENDED | (A << 16) | (SP << 5) | SP) # sub sp, sp, A
        # The rounded count in A is dead once sp has moved, so the block's base
        # address goes straight to wherever the destination lives.
        target = result_register(dst)
        emit_add_imm(target, SP, 0, shift12: false)    # mov target, sp
        # No `only_wrote:`: the rounding above overwrote A, which the load a
        # line earlier left holding the *requested* count and which any
        # residency in flight may name. Claiming otherwise would leave a reader
        # of the size value believing A still held it (see #store_result).
        store_result(target, dst)
      end

      # :div/:mod/:udiv/:umod. The quotient is `sdiv`/`udiv` of the dividend by
      # the divisor; a remainder is then dividend - quotient*divisor via
      # `msub`, since AArch64 has no direct remainder instruction. The
      # signed/unsigned split mirrors the IR's own.
      #
      # A remainder needs the quotient as well as the result, so that one keeps
      # the C scratch for it; C is never a promotion register, so the divisor
      # and dividend it is read alongside can be named in place regardless.
      def emit_divmod(dst, a, b, size, signed:, remainder:)
        rn, rm = binary_operand_registers(a, b)
        w = width(size)
        div_base = signed ? (w == 64 ? 0x9AC00C00 : 0x1AC00C00) : (w == 64 ? 0x9AC00800 : 0x1AC00800)
        if remainder
          rd = result_register(dst)
          emit_word(div_base | (rm << 16) | (rn << 5) | C)            # sdiv/udiv C, a, b
          msub_base = w == 64 ? 0x9B008000 : 0x1B008000
          emit_word(msub_base | (rm << 16) | (rn << 10) | (C << 5) | rd) # msub rd, C, b, a
          # No `only_wrote:`: the quotient went to C, which is a scratch a
          # residency may name — the quotient path right below computes into it
          # whenever its destination lives in a slot (see #store_result).
          store_result(rd, dst)
        else
          rd = result_register(dst, C)
          emit_word(div_base | (rm << 16) | (rn << 5) | rd)           # sdiv/udiv rd, a, b
          store_result(rd, dst, only_wrote: rd) # one word, Rd its only written field
        end
      end

      # :shl/:sar/:shr — a variable shift by the second operand's low bits
      # (masked to 5 bits for a 32-bit operand, 6 for a 64-bit one by the
      # hardware, matching C). The shift amount is an ordinary Rm here, not the
      # one fixed register x86 makes of it, so a promoted count needs no move.
      def emit_shift(dst, a, b, size, base_table)
        rn, rm = binary_operand_registers(a, b)
        rd = result_register(dst)
        emit_word(base_table[width(size)] | (rm << 16) | (rn << 5) | rd)
        store_result(rd, dst, only_wrote: rd) # one word, Rd its only written field
      end

      # :neg — Rd = -a, encoded as `sub Rd, xzr, a`.
      def emit_neg(dst, src, size)
        rn = operand_register(src, A)
        rd = result_register(dst)
        emit_word(SUB_SHIFTED[width(size)] | (rn << 16) | (XZR << 5) | rd)
        store_result(rd, dst, only_wrote: rd) # one word, Rd its only written field
      end

      # A comparison materialized into the destination as an int 0/1. `cmp`
      # sets the flags; `cset` then writes 1 when the condition holds. A size-8
      # comparison uses the 64-bit X view (full pointer values), otherwise the
      # 32-bit W view.
      #
      # Both ends are read-only fields and `cset`'s destination is free, so a
      # comparison between two promoted values that lands in a third is three
      # registers named in place and no traffic at all.
      def emit_comparison(dst, a, b, condition, size, commutative: false)
        rn, rm = binary_operand_registers(a, b, commutative: commutative)
        rd = result_register(dst)
        emit_word(SUBS_SHIFTED[width(size)] | (rm << 16) | (rn << 5) | XZR) # cmp rn, rm
        emit_cset(rd, condition)
        # The `cmp` writes the flags and register 31, which is xzr here and no
        # register at all; the `cset` writes rd. Nothing the table names.
        store_result(rd, dst, only_wrote: rd)
      end

      # :sext — sign-extend a's low `size` bytes to the full 64-bit register,
      # so a subsequent 64-bit use (pointer-offset scaling) sees a correct,
      # possibly negative, value.
      def emit_sext(dst, src, size)
        rn = operand_register(src, A)
        rd = result_register(dst)
        word =
          case size
          when 1 then 0x93401C00 # sxtb x, w
          when 2 then 0x93403C00 # sxth x, w
          else 0x93407C00        # sxtw x, w  (size 4)
          end
        emit_word(word | (rn << 5) | rd)
        store_result(rd, dst, only_wrote: rd) # one word, Rd its only written field
      end

      # :zext — zero-extend a's low `size` bytes. The 1/2-byte forms are 32-bit
      # uxtb/uxth (which zero the upper 32 bits too); size 4 is a 64-bit ubfx of
      # the low 32 bits, matching x86's "mov eax, eax".
      def emit_zext(dst, src, size)
        rn = operand_register(src, A)
        rd = result_register(dst)
        word =
          case size
          when 1 then 0x53001C00 # uxtb w, w
          when 2 then 0x53003C00 # uxth w, w
          else 0xD3407C00        # ubfx x, x, #0, #32  (size 4)
          end
        emit_word(word | (rn << 5) | rd)
        store_result(rd, dst, only_wrote: rd) # one word, Rd its only written field
      end

      # :load / :uload — read `size` bytes through the pointer in a's slot. A
      # signed load sign-extends a byte/halfword (ldrsb/ldrsh), the unsigned
      # form zero-extends (ldrb/ldrh); a 4-byte load is a plain W load (upper
      # half zeroed) and an 8-byte load a full X load, both sign-agnostic.
      #
      # The base register Rn is an ordinary five-bit field, so a promoted
      # pointer addresses memory where it stands — the extension x86_64's
      # ModR/M and SIB special cases made worth deferring there and which costs
      # nothing here.
      def emit_load(dst, ptr, size, signed:)
        rn = operand_register(ptr, A)
        rd = result_register(dst)
        word =
          case size
          when 8 then 0xF9400000                  # ldr  x, [x]
          when 2 then signed ? 0x79C00000 : 0x79400000 # ldrsh/ldrh w, [x]
          when 1 then signed ? 0x39C00000 : 0x39400000 # ldrsb/ldrb w, [x]
          else 0xB9400000                         # ldr  w, [x]  (size 4)
          end
        emit_word(word | (rn << 5) | rd)
        store_result(rd, dst, only_wrote: rd) # the load writes Rt; its base is read only
      end

      # :store — write value b's low `size` bytes through the pointer in a. The
      # narrower stores (strb/strh/str-w) are exactly the truncation a narrow
      # lvalue needs. Base and source register are both free fields, so a
      # promoted pointer and a promoted value make this one instruction.
      def emit_store(ptr, value, size)
        rn, rt = binary_operand_registers(ptr, value)
        word =
          case size
          when 8 then 0xF9000000 # str  x, [x]
          when 2 then 0x79000000 # strh w, [x]
          when 1 then 0x39000000 # strb w, [x]
          else 0xB9000000        # str  w, [x]  (size 4)
          end
        emit_word(word | (rn << 5) | rt)
      end

      # :jump_if_zero — branch when a's low 32 bits are zero. Testing the W view
      # (cbz w) mirrors the x86_64 backend's 32-bit "test eax, eax": the
      # condition is an int 0/1 or a truthiness test the generator has already
      # reduced.
      #
      # CBZ names the register it tests in a free field, so a promoted
      # condition is branched on where it lives and the loop's test costs one
      # instruction.
      def emit_jump_if_zero(cond, label_id)
        rt = operand_register(cond, A)
        @fixups << [@code.bytesize, label_id, :cbz]
        emit_word(0x34000000 | rt) # cbz w{rt}, <patched>
      end

      # :call — a direct call. Arguments are placed in x0..x7 / v0..v7, then `bl`
      # (its 26-bit immediate left zero and recorded as an R_AARCH64_CALL26
      # relocation the linker resolves), and the result is stored back from x0 or
      # v0 — or, for an aggregate returned in registers, scattered into the
      # caller's buffer (see #store_call_result).
      def emit_call(dst, name, args, size)
        _fixed, ret = size || [nil, nil]
        stack_bytes = place_arguments(args)
        @relocations << { kind: :call, offset: @code.bytesize, symbol: name }
        emit_word(0x94000000) # bl <patched by R_AARCH64_CALL26>
        store_call_result(dst, ret)
        release_dynamic_argument_area(stack_bytes)
      end

      # :call_indirect — the same sequence through a computed target. The
      # arguments go into their registers first and the callee's address is
      # loaded only afterwards, into the A scratch: A is not an argument register,
      # so the branch target cannot be one of the values just placed, and loading
      # it last means the argument loads never have to work around it. `blr`
      # branches to the register and sets x30, exactly as `bl` does to a label —
      # no relocation, the address being an ordinary run-time value.
      def emit_call_indirect(dst, target_vreg, args, size)
        _fixed, ret = size || [nil, nil]
        stack_bytes = place_arguments(args)
        load_reg(A, target_vreg)
        emit_word(0xD63F0000 | (A << 5)) # blr A
        store_call_result(dst, ret)
        release_dynamic_argument_area(stack_bytes)
      end

      # Parks a call's result in its destination slot. An in-register aggregate
      # result (`ret` a [buffer_vreg, pieces] array) is scattered into the
      # caller's scratch buffer and has no destination slot at all, the value
      # being that buffer's address; `ret` :sse4/:sse8 means the value comes back
      # in v0 (stored at its own width, like any floating value); otherwise the
      # result is the integer/pointer one in x0. A call whose value is discarded
      # has no destination and stores nothing.
      def store_call_result(dst, ret)
        return store_struct_call_result(ret) if ret.is_a?(Array)
        return unless dst

        if ret == :sse4 || ret == :sse8
          store_fp(FP_ARG_REGISTERS[0], dst, ret == :sse8 ? 8 : 4)
        else
          store_reg(ARG_REGISTERS[0], dst)
        end
      end

      # Scatters an in-register aggregate result into the caller's scratch
      # buffer. `ret` is [buffer_vreg, pieces]; buffer_vreg's slot holds the
      # buffer address, loaded into the A scratch — which is neither an integer
      # nor a vector result register, so loading it clobbers nothing the callee
      # just set. Each piece is written at its own offset and width, so a struct
      # of two floats lands as s0 at +0 and s1 at +4 while a struct of two longs
      # lands as x0 at +0 and x1 at +8.
      def store_struct_call_result(ret)
        buffer_vreg, pieces = ret
        load_reg(A, buffer_vreg)
        each_result_piece(pieces) do |piece, reg, fp|
          emit_piece_access(reg, A, piece.offset, piece.size, load: false, fp: fp)
        end
      end

      # Yields each aggregate-result piece with the register it travels in and
      # whether that register is a vector one, handing out x0/x1 and v0..v3 in
      # piece order. Shared by the caller-side scatter and the callee-side
      # gather, so the two cannot drift apart.
      def each_result_piece(pieces)
        next_gp = 0
        next_fp = 0
        pieces.each do |piece|
          if piece.kind == :gp
            yield piece, RESULT_GP_REGISTERS[next_gp], false
            next_gp += 1
          else
            yield piece, RESULT_FP_REGISTERS[next_fp], true
            next_fp += 1
          end
        end
      end

      # Places a call's arguments: an integer/pointer one into the next of
      # x0..x7, a floating one into the next of v0..v7, and a :mem one into the
      # outgoing argument area at [sp + 8*k] in left-to-right order, which is
      # where AAPCS64 6.4.2 has the callee look for it. A stack argument is moved
      # as a whole eightbyte, matching how the callee reads it back.
      #
      # The stack arguments are written first, in a pass of their own, because
      # they travel through the A scratch: doing them after the register loads
      # would be safe for A itself (no argument register is A), but keeping the
      # two passes apart makes the order independent of how the argument list
      # happens to interleave. Each load then writes only its own destination
      # and reads sp, so placing a later argument never clobbers an earlier one,
      # and the integer and vector register files never collide.
      #
      # In an alloca function there is no static area to write into, so this
      # call's own is carved out here by lowering sp — below every block the
      # body has allocated, which is exactly where the callee's arguments belong
      # and where they disturb nothing. #release_dynamic_argument_area gives the
      # space back once the call has returned. The byte count is returned so the
      # two halves cannot disagree about how much moved.
      def place_arguments(args)
        stack_bytes = align16(args.count { |_vreg, kind| kind == :mem || kind == :pad_stack } * 8)
        adjust_sp(stack_bytes, sub: true) if @uses_alloca && stack_bytes.positive?

        next_stack = 0
        args.each do |vreg, kind|
          # :pad_stack reserves one stack eightbyte to 16-align the aggregate
          # behind it; it carries no value, so it only advances the counter.
          next_stack += 1 if kind == :pad_stack
          next unless kind == :mem

          load_reg(A, vreg)
          store_outgoing_at(A, 8 * next_stack)
          next_stack += 1
        end

        next_gp = 0
        next_fp = 0
        args.each do |vreg, kind|
          case kind
          when :gp
            raise "call argument :gp overruns the integer registers" if next_gp >= ARG_REGISTERS.size

            load_reg(ARG_REGISTERS[next_gp], vreg)
            next_gp += 1
          when :pad
            # An even-pair alignment pad reserves one integer register, unloaded.
            next_gp += 1
          when :mem, :pad_stack then next
          when :sse4, :sse8
            raise "call argument #{kind} overruns the vector registers" if next_fp >= FP_ARG_REGISTERS.size

            load_fp(FP_ARG_REGISTERS[next_fp], vreg, kind == :sse8 ? 8 : 4)
            next_fp += 1
          when :sse16
            raise "call argument #{kind} overruns the vector registers" if next_fp >= FP_ARG_REGISTERS.size

            # A quad-precision argument (AAPCS64's `long double`) fills a whole
            # vector register, which no eightbyte slot could have held: its
            # vreg carries the *address* of the 16-byte value instead, and the
            # register is loaded from there. A is free here — the stack pass
            # above has finished with it and no argument register is A.
            load_reg(A, vreg)
            emit_word(LDR_Q | (A << 5) | FP_ARG_REGISTERS[next_fp]) # ldr q, [A]
            next_fp += 1
          when :indirect_result
            # The result buffer's address goes in x8, outside both argument
            # sequences, so it never displaces a real argument.
            load_reg(INDIRECT_RESULT_REGISTER, vreg)
          else
            raise "unknown call argument kind #{kind.inspect}"
          end
        end

        stack_bytes
      end

      # Gives back the outgoing argument area #place_arguments carved out of the
      # stack for a call in an alloca function, once the call has returned and
      # its result has been parked. Raising sp again is what keeps a call inside
      # a loop from walking the stack down one area per iteration. In an
      # ordinary function the area is part of the fixed frame and nothing moved,
      # so there is nothing to give back.
      def release_dynamic_argument_area(stack_bytes)
        adjust_sp(stack_bytes, sub: false) if @uses_alloca && stack_bytes.positive?
      end

      # :ret — loads the return value into its result register and runs the
      # epilogue. size nil is an integer/pointer return (x0), size 4/8 a floating
      # one (v0, loaded at that width) and a piece array an aggregate returned in
      # registers. A void return (nil operand) loads nothing. An aggregate too
      # large for registers is not returned this way: its callee copies the
      # result through the hidden x8 pointer, which reaches here as a plain
      # size-nil return of that pointer.
      def emit_ret(value_vreg, size)
        if size.is_a?(Array)
          emit_struct_ret(value_vreg, size)
        elsif size == 4 || size == 8
          load_fp(FP_ARG_REGISTERS[0], value_vreg, size)
        elsif value_vreg
          load_reg(ARG_REGISTERS[0], value_vreg)
        end
        emit_epilogue
      end

      # Gathers an in-register aggregate return into its result registers.
      # `buffer_vreg` holds the address of the value (a stack object the
      # generator has already filled), loaded into the A scratch — never itself a
      # result register — and each piece is read from its own offset at its own
      # width, leaving x0/x1 and v0..v3 set for the epilogue's `ret`.
      def emit_struct_ret(buffer_vreg, pieces)
        load_reg(A, buffer_vreg)
        each_result_piece(pieces) do |piece, reg, fp|
          emit_piece_access(reg, A, piece.offset, piece.size, load: true, fp: fp)
        end
      end

      # --- whole-object copies ----------------------------------------------

      # The most eightbytes #emit_memcpy will move with a straight-line run of
      # load/store pairs before it switches to a counted loop. Below the limit
      # the unrolled form is both shorter and branchless; above it the code size
      # would grow with the struct, which a loop bounds at a fixed six
      # instructions however large the object is.
      MEMCPY_UNROLL_LIMIT = 8

      # :memcpy — copies `byte_count` bytes from the address in `src_vreg`'s slot
      # to the address in `dest_vreg`'s slot. This is the whole-object move a
      # struct assignment needs, and equally the one that makes a struct
      # argument's private copy and brings a by-reference parameter into storage
      # of the callee's own.
      #
      # The count is a compile-time constant, so the shape of the copy is decided
      # here rather than tested at run time: the eightbytes go through a counted
      # loop when there are enough of them to be worth one and a straight run of
      # load/store pairs otherwise, and the trailing bytes (a struct's size need
      # not be a multiple of eight) follow in one access each of 4, 2 and 1
      # bytes. Every tail access is naturally aligned against the block before it
      # — a 4 follows a multiple of 8, a 2 a multiple of 4, a 1 a multiple of 2 —
      # so each fits the scaled unsigned-offset form without composing an address.
      #
      # A and B hold the two addresses, C the loop counter and ADDR the value in
      # flight. None is an argument register, so a copy made while a call's
      # arguments are being prepared never disturbs one already placed.
      def emit_memcpy(dest_vreg, src_vreg, byte_count)
        # Through #load_binary_operands rather than two bare loads: the source
        # address may be a transient waiting in A, which filling A with the
        # destination would destroy for good (its slot was never written).
        load_binary_operands(dest_vreg, src_vreg) # A = destination, B = source
        chunks = byte_count / 8
        if chunks > MEMCPY_UNROLL_LIMIT
          emit_memcpy_loop(chunks)
          offset = 0 # the loop leaves A and B just past the eightbytes it moved
        else
          chunks.times { |i| emit_memcpy_step(8 * i, 8) }
          offset = 8 * chunks
        end

        remaining = byte_count - 8 * chunks
        [4, 2, 1].each do |width|
          next if remaining < width

          emit_memcpy_step(offset, width)
          offset += width
          remaining -= width
        end
      end

      # Moves `chunks` eightbytes with a counted loop, advancing both addresses
      # as it goes so the caller's tail accesses start from offset zero. The
      # counter is decremented by a flag-setting `subs` and the branch taken
      # while it is non-zero, which needs no label fixup: the target is behind
      # the branch and its distance is already known.
      def emit_memcpy_loop(chunks)
        materialize(C, chunks, 64)
        start = @code.bytesize
        emit_memcpy_step(0, 8)
        emit_add_imm(B, B, 8, shift12: false)
        emit_add_imm(A, A, 8, shift12: false)
        emit_word(0xF1000400 | (C << 5) | C) # subs C, C, #1
        words = (start - @code.bytesize) / 4
        emit_word(0x54000000 | ((words & 0x7FFFF) << 5) | CONDITIONS.fetch(:ne)) # b.ne <start>
      end

      # One load/store pair of `width` bytes at `offset` from both addresses,
      # relaying the value through the ADDR scratch.
      def emit_memcpy_step(offset, width)
        emit_piece_access(ADDR, B, offset, width, load: true, fp: false)
        emit_piece_access(ADDR, A, offset, width, load: false, fp: false)
      end

      # --- atomics -----------------------------------------------------------
      #
      # Every atomic op lowers at sequential consistency, the strongest order
      # (the IR carries no weaker one — see IR::Generator#gen_builtin_atomic for
      # why strengthening is always sound), and `size` is only ever 4 or 8, the
      # generator having diagnosed every other width. The 8-byte forms differ
      # from the 4-byte ones only in the encoding's size field (bit 30), which is
      # what the ACQUIRE_/RELEASE_ tables below carry.
      #
      # Everything is built from the armv8-a *baseline* — the load-acquire /
      # store-release exclusive pair and a retry loop — and nothing else. The
      # single-instruction LSE atomics (`casal`, `ldadd`, `swp`) would be shorter
      # but need armv8.1-a, and gcc's alternative of calling into libgcc's
      # outline atomics (`__aarch64_ldadd4_acq_rel` and kin) would put rubycc's
      # output at the mercy of a runtime library it otherwise never links. The
      # baseline sequence runs on every AArch64 part.
      #
      # The retry loops branch backwards to a target inside the same IR
      # instruction, so they need no label fixup: the distance is already known
      # when the branch is emitted, exactly as in #emit_memcpy_loop.

      # The opcode tables these sequences draw on (LDAR/STLR, LDAXR/STLXR,
      # CBNZ_W, ATOMIC_RMW_OPCODES) sit with the rest of the machine encodings at
      # the foot of the class, since the read-modify-write table is built from
      # the same shifted-register forms the ordinary binary ops use.

      # :atomic_fence — DMB ISH, the full-system-domain barrier used by C11's
      # sequentially-consistent fence on the baseline AArch64 target.
      def emit_atomic_fence
        emit_word(0xD5033BBF)
      end

      # :atomic_load — a sequentially consistent read (LDAR).
      def emit_atomic_load(dst, ptr, size)
        load_reg(A, ptr)
        emit_word(LDAR.fetch(size) | (A << 5) | A)
        store_reg(A, dst)
      end

      # :atomic_store — a sequentially consistent write (STLR).
      def emit_atomic_store(ptr, value, size)
        load_reg(A, ptr)
        load_reg(B, value)
        emit_word(STLR.fetch(size) | (A << 5) | B)
      end

      # :atomic_rmw — every read-modify-write kind as one exclusive retry loop:
      #
      #   retry:
      #     ldaxr  C, [A]        ; C = the value read
      #     <op>   D, C, B       ; D = the value to store  (absent for :exchange,
      #                          ;      which stores the operand B unchanged)
      #     stlxr  wE, D, [A]
      #     cbnz   wE, retry
      #
      # The result is C for :exchange and the :fetch_* forms (the value read) and
      # D for the :*_fetch ones (the value stored). Unlike x86-64 — where an
      # exchange-add hands back the old value and the new one is recovered by
      # re-adding the operand — nothing is derived after the fact here: the loop
      # computes both values in registers already, so each form simply names the
      # one it wants. That is also why :or_fetch needs no special case on this
      # target: a loop is the only shape available, and every kind uses it.
      def emit_atomic_rmw(dst, ptr, value, kind, size)
        combine = ATOMIC_RMW_OPCODES.fetch(kind)
        load_reg(A, ptr)   # A = the atomic object's address
        load_reg(B, value) # B = the operand
        start = @code.bytesize
        emit_word(LDAXR.fetch(size) | (A << 5) | C) # C = the value read
        if combine
          emit_word(combine[width(size)] | (B << 16) | (C << 5) | D) # D = C <op> B
          stored = D
        else
          stored = B # :exchange stores the operand as it stands
        end
        emit_word(STLXR.fetch(size) | (E << 16) | (A << 5) | stored)
        emit_atomic_retry(start, E)
        store_reg(ATOMIC_RMW_NEW_VALUE_KINDS.include?(kind) ? stored : C, dst)
      end

      # :atomic_cas — __atomic_compare_exchange_n:
      #
      #     ldr    D, [B]          ; D = *expected
      #   retry:
      #     ldaxr  E, [A]          ; E = the value actually there
      #     cmp    E, D
      #     b.ne   done            ; a mismatch abandons the monitor and the loop
      #     stlxr  wF, C, [A]
      #     cbnz   wF, retry
      #   done:
      #     cset   wA, eq          ; the _Bool result
      #     b.eq   skip
      #     str    E, [B]          ; the failing path reports the value it saw
      #   skip:
      #
      # The flags `cmp` left are still live at `done` on both paths — neither
      # STLXR nor CBNZ writes them — which is what lets one `cset` answer for the
      # loop however it was left. The write-back through `expected` is guarded by
      # the branch rather than done unconditionally so an `expected` that aliases
      # the atomic object does not overwrite the value just exchanged into it.
      # It is also the side effect <ruby/atomic.h>'s RUBY_ATOMIC_CAS reads its
      # answer out of, so it is not optional.
      def emit_atomic_cas(dst, ptr, expected, desired, size)
        load_reg(A, ptr)      # A = the atomic object's address
        load_reg(B, expected) # B = &expected
        load_reg(C, desired)  # C = the value to store
        emit_word(INT_LDST.fetch(size)[:load] | (B << 5) | D) # D = *expected
        start = @code.bytesize
        emit_word(LDAXR.fetch(size) | (A << 5) | E)
        emit_word(SUBS_SHIFTED[width(size)] | (D << 16) | (E << 5) | XZR) # cmp E, D
        mismatch = emit_atomic_forward_branch(:ne)
        emit_word(STLXR.fetch(size) | (F << 16) | (A << 5) | C)
        emit_atomic_retry(start, F)
        patch_atomic_forward_branch(mismatch)
        emit_cset(A, CONDITIONS.fetch(:eq))
        matched = emit_atomic_forward_branch(:eq)
        emit_word(INT_LDST.fetch(size)[:store] | (B << 5) | E) # *expected = what we saw
        patch_atomic_forward_branch(matched)
        store_reg(A, dst)
      end

      # Closes a retry loop: `cbnz w{status}, start`, taken while the
      # store-exclusive keeps reporting failure. The target is behind the branch
      # and its distance is already known, so no fixup is recorded.
      def emit_atomic_retry(start, status)
        words = (start - @code.bytesize) / 4
        emit_word(CBNZ_W | ((words & 0x7FFFF) << 5) | status)
      end

      # Emits a `b.<condition>` whose target is a little further along in this
      # same instruction's code, leaving the 19-bit offset zero, and returns the
      # site so #patch_atomic_forward_branch can fill it in once the target is
      # reached. The IR's own label machinery is not used because neither end of
      # the branch is an IR label — both are interior to one instruction.
      def emit_atomic_forward_branch(condition)
        site = @code.bytesize
        emit_word(0x54000000 | CONDITIONS.fetch(condition))
        site
      end

      # Resolves a branch #emit_atomic_forward_branch left open, its target being
      # the current position.
      def patch_atomic_forward_branch(site)
        words = (@code.bytesize - site) / 4
        word = @code[site, 4].unpack1("L<") | ((words & 0x7FFFF) << 5)
        @code[site, 4] = [word].pack("L<")
      end

      # --- register / slot access -------------------------------------------

      # One ldr/str of `reg` at [base + offset], `size` bytes wide, from either
      # register file. The unsigned-offset immediate is scaled by the access
      # size, and every offset reaching here is a multiple of its own width (an
      # aggregate piece sits at a multiple of its width, and a copy step advances
      # by its own), so the scaled form always names it exactly.
      def emit_piece_access(reg, base, offset, size, load:, fp:)
        table = fp ? FP_LDST : INT_LDST
        emit_word(table.fetch(size)[load ? :load : :store] | ((offset / size) << 10) | (base << 5) | reg)
      end

      # ldr X{reg}, [slot]. Slots are always moved 64 bits at a time so a pointer
      # is never truncated; a 32-bit value's high half was zeroed when it was
      # produced. Reaches the slot through the scaled immediate when it fits,
      # otherwise through a composed address in the ADDR scratch.
      #
      # The load disappears when `reg` already holds this slot's value and
      # becomes a register move when another scratch register does (see
      # SlotResidency). ADDR is never tracked, so the address composition the
      # distant-slot path performs in it cannot leave a stale claim behind: it
      # is a scratch this method writes and reads within one instruction and
      # #load_reg is never asked to fill it.
      def load_reg(reg, vreg)
        refresh_slot_residency
        promoted = @promoted[vreg]
        if promoted
          # There is no slot to read: this value has been in `promoted` since
          # the prologue and stays there until the function returns, so the
          # load is a register move — or nothing at all when the caller wants
          # it where it already is. Either way only `reg` is written, which is
          # what the residency table has to be told.
          emit_move_register(reg, promoted) unless reg == promoted
          note_register_clobbered(reg)
          return
        end
        return if slot_resident_in?(reg, vreg)

        source = register_holding_slot(vreg)
        if source
          emit_move_register(reg, source)
        else
          load_frame_at(reg, slot_offset(vreg))
        end
        if PROMOTION_REGISTER_SET.include?(reg)
          # Filling a promoted register from some *other* value's slot happens
          # where that register is a result destination and the value is on its
          # way in (#emit_copy, a stack parameter). Recording a residency
          # against it would break the invariant every note_register_clobbered
          # in this backend rests on — that no entry in the table is keyed by a
          # promotion register — and would be short-lived anyway, the result
          # being written over it in the next instruction.
          note_register_clobbered(reg)
        else
          note_slot_loaded(reg, vreg)
        end
      end

      # mov Xd, Xn, which the architecture spells as an ORR with the zero
      # register.
      def emit_move_register(dst, src)
        emit_word(ORR_SHIFTED[64] | (src << 16) | (XZR << 5) | dst)
      end

      # str X{reg}, [slot]. The counterpart of #load_reg. The store itself is
      # never skipped: the slot is the value's home, and nothing here knows
      # whether a later branch reaches a reader by a path that goes nowhere near
      # this register.
      def store_reg(reg, vreg)
        refresh_slot_residency
        promoted = @promoted[vreg]
        if promoted
          # The value's home is a register, so the store is a move into it —
          # and nothing at all when the value was computed there. No slot is
          # written and no residency can name a promotion register, so every
          # entry in the table is still true.
          emit_move_register(promoted, reg) unless reg == promoted
          note_slots_undisturbed
          return
        end
        if @transient[vreg]
          # The value's only reader is the next instruction, which will find it
          # here; the slot itself is never named again, so nothing is written.
          note_slot_loaded(reg, vreg)
          return
        end
        store_frame_at(reg, slot_offset(vreg))
        note_slot_stored(reg, vreg)
      end

      # Loads a two-operand instruction's operands into A and B.
      #
      # Which one is fetched first stops being arbitrary once #load_reg can
      # reuse a resident value: if `b` is the value sitting in A, loading `a`
      # there first would throw it away and force `b` back out of memory.
      # Fetching B first instead keeps it, as a register move. A `commutative`
      # op can do better still — swapping the two makes the resident operand A's,
      # so nothing is moved at all — and is safe to swap precisely because the
      # instruction's two register operands are interchangeable (which is not
      # true of :sub, of the shifts, or of an ordering comparison).
      def load_binary_operands(a, b, commutative: false)
        refresh_slot_residency
        if slot_resident_in?(A, b) && !slot_resident_in?(A, a)
          if commutative
            a, b = b, a
          else
            load_reg(B, b)
          end
        end
        load_reg(A, a)
        load_reg(B, b)
      end

      # --- naming promoted registers in place -------------------------------
      #
      # AArch64's data-processing instructions are three-address — Rd, Rn and
      # Rm are independent five-bit fields naming any of the 31 general
      # registers — and its loads and stores name their base register just as
      # freely. So a promoted value is used *where it lives*, both as an
      # operand and as a destination, and a promoted addition really is one
      # instruction: `add x19, x19, x20`.
      #
      # That is the whole difference from the x86_64 backend, where the same
      # step had to be split in two (put the value in a register, then teach
      # each encoding to name it) because a two-address machine with one
      # memory operand cannot express the second half for free. The measured
      # consequence there was that promotion *alone* made code slower: every
      # memory operand it removed became two register instructions. There is no
      # such half-way state here.
      #
      # What is deliberately not widened is everything the ABI pins down: a
      # call's arguments (x0..x7, v0..v7), its result (x0/v0), the atomic
      # sequences' exclusive pair and the whole-object copy, whose loop
      # advances the addresses it was handed and so must be given scratch
      # registers of its own.

      # The register an instruction should read `vreg` out of: the callee-saved
      # register it was promoted into, a scratch register that already holds
      # the value, or `scratch` with the value loaded into it.
      #
      # The middle case is what keeps a transient free. #load_binary_operands
      # has to move one out of A when the *other* operand is on its way in
      # there; where the other operand is promoted nothing is on its way in at
      # all, so the value is read where its producer left it.
      #
      # Only A and B answer, though a residency may name any scratch register:
      # those two are the ones nothing writes between the operands being named
      # and the last instruction that reads them, while C is written in the
      # middle of a remainder (it takes the quotient) and could equally be
      # holding one of the values that remainder is about to read.
      def operand_register(vreg, scratch)
        promoted = @promoted[vreg]
        return promoted if promoted

        refresh_slot_residency
        return A if slot_resident_in?(A, vreg)
        return B if slot_resident_in?(B, vreg)

        load_reg(scratch, vreg)
        scratch
      end

      # The pair of registers a two-operand instruction should read, one per
      # operand. A promoted operand is named where it is; the rest go through
      # A and B as before, and when neither operand is promoted this is exactly
      # #load_binary_operands — including its rescue of an operand still
      # sitting in A, which only arises when something has to be loaded there.
      #
      # `commutative` is passed on for that rescue's sake alone. Nothing here
      # needs the two exchanged the way the x86_64 backend does to reach an
      # in-place form: this machine's destination field is free, so
      # `sub x19, x20, x19` and `sub x19, x19, x20` cost the same one
      # instruction and neither reads a register the other has overwritten —
      # every source is read before Rd is written.
      def binary_operand_registers(a, b, commutative: false)
        promoted_a = @promoted[a]
        promoted_b = @promoted[b]
        return [promoted_a, promoted_b] if promoted_a && promoted_b
        return [promoted_a, operand_register(b, B)] if promoted_a
        return [operand_register(a, A), promoted_b] if promoted_b

        load_binary_operands(a, b, commutative: commutative)
        [A, B]
      end

      # Where an instruction that computes a general-register result should put
      # it: the callee-saved register `dst` was promoted into, so the value is
      # written home directly, or `scratch` for a value that lives in a slot.
      def result_register(dst, scratch = A)
        @promoted[dst] || scratch
      end

      # Completes such an instruction. A destination that lives in a slot still
      # needs the store; a promoted `dst` *is* `reg`, so the value is already
      # home and all that is left is telling the residency table what the bytes
      # just emitted did to it.
      #
      # **The default answer is to throw the table away.** Bytes have been
      # emitted since it was last known true — the caller's own instruction —
      # and nothing here can see which registers they wrote. Keeping the table
      # alive across them is #note_register_clobbered's exception, sound only
      # when those bytes wrote `reg` and nothing else the table can name; that
      # is a fact about one lowering's encoding, so the lowering is what states
      # it, by passing `only_wrote: reg`. Anything that says nothing gets the
      # safe reading, which costs an optimization and never correctness — and a
      # lowering that later grows a second scratch write has to come back to its
      # own claim rather than silently reviving a stale residency. That is the
      # shape #emit_alloca and #emit_divmod were caught in: both wrote A or C on
      # the way to the result and both revalidated the table on the way out.
      #
      # "Nothing else the table can name" means none of A, B, C or x0..x8, which
      # are the registers #load_reg is ever asked to fill and so the only ones an
      # entry can be keyed by. Writing sp, ADDR, x13..x15 or a promotion register
      # does not disturb the table (see PROMOTION_REGISTERS and #load_reg), so it
      # does not stop a caller from claiming the fast path.
      def store_result(reg, dst, only_wrote: nil)
        unless @promoted[dst]
          store_reg(reg, dst) # which discards a stale table itself, before anything else
          return
        end

        if only_wrote == reg
          note_register_clobbered(reg)
        else
          refresh_slot_residency
        end
      end

      # ldr X{reg}, [frame base + offset] for any fixed-frame offset, not just a
      # vreg slot's: the variadic register-save area and the caller's incoming
      # argument area are addressed this way too. Reaches the address through
      # the scaled immediate when it fits, otherwise through a composed address
      # in the ADDR scratch. The base is sp or x29 as #frame_base_register says
      # — every offset that reaches here names a place in the fixed frame, which
      # is what makes the substitution safe.
      def load_frame_at(reg, offset)
        if offset <= MAX_SCALED_OFFSET
          emit_word(0xF9400000 | ((offset / 8) << 10) | (frame_base_register << 5) | reg)
        else
          emit_slot_address(ADDR, offset)
          emit_word(0xF9400000 | (ADDR << 5) | reg) # ldr x, [ADDR]
        end
      end

      # str X{reg}, [frame base + offset]. The counterpart of #load_frame_at.
      def store_frame_at(reg, offset)
        if offset <= MAX_SCALED_OFFSET
          emit_word(0xF9000000 | ((offset / 8) << 10) | (frame_base_register << 5) | reg)
        else
          emit_slot_address(ADDR, offset)
          emit_word(0xF9000000 | (ADDR << 5) | reg) # str x, [ADDR]
        end
      end

      # str X{reg}, [sp + offset] for a call's outgoing argument area. This one
      # is sp-relative on purpose and in every function: AAPCS64 has the callee
      # read its stack arguments from the sp the `bl` was executed with, so the
      # area is defined against sp and not against the fixed frame. In an
      # ordinary function the two coincide; in an alloca function they do not,
      # and the area is the block #place_arguments has just lowered sp over.
      def store_outgoing_at(reg, offset)
        if offset <= MAX_SCALED_OFFSET
          emit_word(0xF9000000 | ((offset / 8) << 10) | (SP << 5) | reg) # str x, [sp, #off]
        else
          emit_base_address(ADDR, SP, offset)
          emit_word(0xF9000000 | (ADDR << 5) | reg) # str x, [ADDR]
        end
      end

      # ldr S{reg}/D{reg}, [slot]. Unlike the integer path, a floating value is
      # moved at its *own* width rather than always 64 bits: a `float` slot holds
      # four meaningful bytes and its upper half is indeterminate, so reading the
      # slot as a D register would feed the arithmetic a different number
      # entirely. That is the same rule the x86_64 backend follows with
      # movss/movsd, and it stays consistent with the slot discipline, which only
      # ever promises the low `size` bytes of a value narrower than eight.
      #
      # The value travels between slot and vector register directly, never
      # through a general-purpose register: an `fmov` round trip would cost two
      # extra instructions per operand and buy nothing, since ldr/str address a
      # V register with the same sp-relative form the X registers use — the sole
      # difference being the V bit that selects the register file.
      #
      # As with #load_reg, the move disappears when `reg` already holds this
      # slot at this width and becomes a register-to-register `fmov` when
      # another vector register does — which copies exactly the bits a reload
      # would have produced at that width.
      #
      # Unlike #load_reg this asks nothing about promotion: a value the vector
      # register file touches is refused promotion outright (IR::Promotion's
      # VECTOR_OPS and VECTOR_KINDS), so every vreg reaching here has a slot.
      def load_fp(reg, vreg, size)
        refresh_slot_residency
        return if slot_resident_in_vector?(reg, vreg, size)

        source = vector_register_holding_slot(vreg, size)
        if source
          emit_word(FMOV_REG.fetch(size) | (source << 5) | reg)
        else
          emit_fp_slot_access(reg, slot_offset(vreg), size, load: true)
        end
        note_slot_loaded_to_vector(reg, vreg, size)
      end

      # Stages a floating instruction's operands into FA and FB. When the second
      # was never written to its slot (a transient waiting in FA), it is rescued
      # into FB before the first operand lands on top of it — the vector-file
      # version of the ordering rule #load_binary_operands follows.
      def load_float_operands(a, b, size)
        refresh_slot_residency
        load_fp(FB, b, size) if slot_resident_in_vector?(FA, b, size) &&
                                !slot_resident_in_vector?(FA, a, size)
        load_fp(FA, a, size)
        load_fp(FB, b, size)
      end

      # str S{reg}/D{reg}, [slot]. The counterpart of #load_fp.
      def store_fp(reg, vreg, size)
        refresh_slot_residency
        if @transient[vreg]
          note_slot_loaded_to_vector(reg, vreg, size)
          return
        end
        emit_fp_slot_access(reg, slot_offset(vreg), size, load: false)
        note_slot_stored_from_vector(reg, vreg, size)
      end

      # The shared body of #load_fp / #store_fp. The unsigned-offset immediate is
      # scaled by the access size, so a 4-byte access reaches half as far as an
      # 8-byte one; either way a slot past the field is reached through an
      # address composed into the ADDR scratch, exactly as the integer path does.
      def emit_fp_slot_access(reg, offset, size, load:)
        base = FP_LDST.fetch(size)[load ? :load : :store]
        if offset <= 4095 * size
          emit_word(base | ((offset / size) << 10) | (frame_base_register << 5) | reg)
        else
          emit_slot_address(ADDR, offset)
          emit_word(base | (ADDR << 5) | reg)
        end
      end

      # --- floating-point arithmetic ----------------------------------------

      # :fadd/:fsub/:fmul/:fdiv — the operands are loaded into the FA/FB vector
      # scratch pair at the IR's operand width and combined by the single/double
      # form of the same three-register instruction, `size` selecting the type
      # field. A floating negation has no op of its own: the generator flips the
      # sign bit with an integer :xor, which the integer path already lowers.
      def emit_float_binary(inst, base_table)
        size = inst.size
        load_float_operands(inst.a, inst.b, size)
        emit_word(base_table.fetch(size) | (FB << 16) | (FA << 5) | FA)
        store_fp(FA, inst.dst, size)
      end

      # :feq..:fge — materialized into the destination as an int 0/1 the same way
      # an integer comparison is, but through `fcmp`, whose NZCV encoding of an
      # unordered result lets a single `cset` carry the NaN rule (see
      # FLOAT_CONDITIONS). The `cset` is the 32-bit form, so the slot gets a
      # clean int with its upper half zeroed.
      def emit_float_comparison(dst, a, b, condition, size)
        load_float_operands(a, b, size)
        emit_word(FCMP.fetch(size) | (FB << 16) | (FA << 5)) # fcmp FA, FB
        emit_cset(A, condition)
        store_reg(A, dst)
      end

      # :itof — an integer in a slot converted to a floating value. `int_desc` is
      # the source [width, signed?]: a width-8 source reads the X view and a
      # narrower one the W view (where it already sits sign- or zero-extended),
      # and the descriptor's signedness picks `scvtf` or `ucvtf`. Because the
      # machine offers both, no widening trick is needed for an `unsigned int`
      # source the way the signed-only x86 instruction requires. (An `unsigned
      # long` source never reaches a backend; the generator synthesizes it.)
      def emit_itof(dst, src_vreg, int_desc, float_size)
        int_width, signed = int_desc
        load_reg(A, src_vreg)
        emit_word(fp_int_convert(int_width == 8 ? 1 : 0, float_size,
                                 0b00, signed ? 0b010 : 0b011, A, FA))
        store_fp(FA, dst, float_size)
      end

      # :ftoi — a floating value truncated toward zero into an integer slot.
      # `size` is the *source* float width and `int_desc` the destination
      # [width, signed?]; rmode 11 is the round-toward-zero mode the C cast
      # requires, and the descriptor picks `fcvtzs` or `fcvtzu`. Unlike x86, the
      # ISA has a native unsigned W-form, which is important at the rounded
      # 2^32 boundary: fcvtzu X yields 0x1_0000_0000 whose low 32 bits are zero,
      # while fcvtzu W saturates to UINT_MAX as gcc does. Use the C destination
      # width directly, so only a real 64-bit destination selects the X form.
      def emit_ftoi(dst, src_vreg, int_desc, float_size)
        int_width, signed = int_desc
        load_fp(FA, src_vreg, float_size)
        sf = int_width == 8 ? 1 : 0
        emit_word(fp_int_convert(sf, float_size,
                                 0b11, signed ? 0b000 : 0b001, FA, A))
        store_reg(A, dst)
      end

      # :ftof — a float<->double width change, the one-source `fcvt`. `size` is
      # the source width, so the result is stored at the opposite one.
      def emit_ftof(dst, src_vreg, src_size)
        load_fp(FA, src_vreg, src_size)
        # fcvt: the type field names the source, the opc field the destination.
        emit_word((src_size == 8 ? 0x1E624000 : 0x1E22C000) | (FA << 5) | FA)
        store_fp(FA, dst, src_size == 8 ? 4 : 8)
      end

      # "Conversion between floating-point and integer": sf selects the X (1) or
      # W (0) view of the integer side, the type field the float side, rmode the
      # rounding mode and opcode the direction and signedness.
      def fp_int_convert(sf, float_size, rmode, opcode, rn, rd)
        (sf << 31) | 0x1E200000 | (fp_type(float_size) << 22) |
          (rmode << 19) | (opcode << 16) | (rn << 5) | rd
      end

      # The two-bit type field every floating instruction carries: 00 names the
      # single-precision (S register) form, 01 the double-precision (D) one.
      def fp_type(size) = size == 8 ? 0b01 : 0b00

      # --- symbol addresses --------------------------------------------------

      # :string_addr / :global_addr / :func_addr — forms the address of a symbol
      # that lives outside the frame (a string literal in .rodata, a file-scope
      # variable, or a function whose address is taken).
      #
      # AArch64 cannot name a 64-bit address in one instruction, so the address
      # is built in two: `adrp` puts the base of the symbol's 4 KiB page into the
      # register (its 21-bit immediate reaching +/-4 GiB from the referring
      # instruction's own page) and `add` then applies the symbol's offset within
      # that page. Both immediates are emitted as zero and left to the linker,
      # which is why the relocation is recorded once, at the `adrp`, with the
      # machine description spelling out that this kind costs two ELF entries
      # four bytes apart (see ELFWriter::AARCH64). The pair is position-
      # independent by construction — nothing here depends on where the code is
      # finally loaded — but it does bind the symbol at link time, which is what
      # separates it from the GOT path below.
      def emit_symbol_address(dst, reloc)
        target = result_register(dst)
        @relocations << reloc.merge(offset: @code.bytesize)
        emit_word(0x90000000 | target)              # adrp target, <page of sym>
        emit_add_imm(target, target, 0, shift12: false) # add target, target, #:lo12:sym
        store_result(target, dst, only_wrote: target) # the pair writes target alone
      end

      # :got_addr — the PIC form of the above. Under -fPIC a symbol this unit
      # does not define must stay interposable, so its address is not formed but
      # *read*: `adrp` names the page of the symbol's Global Offset Table slot
      # and `ldr` loads the slot's contents, which the dynamic linker has filled
      # in with the symbol's run-time address. The shape is the same two-
      # instruction, two-relocation pair, differing only in the relocation types
      # and in the second instruction being a load rather than an add — so the
      # value that lands in the destination slot is a usable pointer either way
      # and every load or store through it is unchanged.
      def emit_got_address(dst, symbol)
        target = result_register(dst)
        @relocations << { kind: :got, offset: @code.bytesize, symbol: symbol }
        emit_word(0x90000000 | target)                       # adrp target, <page of GOT slot>
        emit_word(0xF9400000 | (target << 5) | target)       # ldr  target, [target, #:got_lo12:]
        store_result(target, dst, only_wrote: target) # the pair writes target alone
      end

      # :addr_of / :object_addr — compute a frame address (sp + offset) into a
      # scratch register and park it in the destination slot as a pointer value.
      def emit_slot_address_to(dst, offset)
        target = result_register(dst)
        emit_slot_address(target, offset)
        # However far the offset reaches, the composition builds it in target
        # and reads only the frame base (#emit_base_address).
        store_result(target, dst, only_wrote: target)
      end

      # Places (frame base) + offset (offset >= 0) into `reg`, the address of a
      # place in the fixed frame.
      def emit_slot_address(reg, offset)
        emit_base_address(reg, frame_base_register, offset)
      end

      # Places base + offset (offset >= 0) into `reg`. Small offsets are one
      # add-immediate; offsets past the 12-bit field are split into a shifted
      # high part plus a low part (two adds cover up to ~16 MB); anything larger
      # is materialized and added with the extended-register form (which, unlike
      # the shifted-register add, accepts sp as its base — the reason the
      # fallback is written this way even though x29 would not need it).
      def emit_base_address(reg, base, offset)
        if offset <= 0xFFF
          emit_add_imm(reg, base, offset, shift12: false)
        elsif offset <= 0xFFFFFF
          emit_add_imm(reg, base, offset >> 12, shift12: true)
          low = offset & 0xFFF
          emit_add_imm(reg, reg, low, shift12: false) if low.positive?
        else
          materialize(reg, offset, 64)
          emit_word(ADD_EXTENDED | (reg << 16) | (base << 5) | reg) # add reg, base, reg, uxtx
        end
      end

      # Which register names the fixed frame. sp in an ordinary function, where
      # it never moves after the prologue; x29 in one containing :alloca, where
      # it does. Every fixed-frame access asks here rather than naming sp, so
      # the two cases cannot drift apart — and an ordinary function's output is
      # unchanged, since the answer is still sp.
      def frame_base_register
        @uses_alloca ? FP : SP
      end

      # add Rd, Rn, #imm12 (optionally << 12). Rn = 31 addresses sp here.
      def emit_add_imm(dst, rn, imm12, shift12:)
        emit_word(0x91000000 | (shift12 ? (1 << 22) : 0) | ((imm12 & 0xFFF) << 10) | (rn << 5) | dst)
      end

      # Lowers or raises sp by `amount` (kept 16-aligned by the caller). Uses one
      # or two add/sub-immediates for realistic frames, falling back to a
      # materialized extended-register add/sub for an implausibly large frame.
      def adjust_sp(amount, sub:)
        base = sub ? 0xD1000000 : 0x91000000
        if amount <= 0xFFF
          emit_word(base | ((amount & 0xFFF) << 10) | (SP << 5) | SP)
        elsif amount <= 0xFFFFFF
          emit_word(base | (1 << 22) | (((amount >> 12) & 0xFFF) << 10) | (SP << 5) | SP)
          low = amount & 0xFFF
          emit_word(base | ((low & 0xFFF) << 10) | (SP << 5) | SP) if low.positive?
        else
          materialize(ADDR, amount, 64)
          ext = sub ? SUB_EXTENDED : ADD_EXTENDED
          emit_word(ext | (ADDR << 16) | (SP << 5) | SP) # add/sub sp, sp, ADDR, uxtx
        end
      end

      # stp Xt1, Xt2, [Xn, #offset] — the saved-record store (offset 0 here).
      def emit_stp(rt1, rt2, rn, offset)
        emit_word(0xA9000000 | (((offset / 8) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt1)
      end

      # ldp Xt1, Xt2, [Xn, #offset] — the saved-record reload.
      def emit_ldp(rt1, rt2, rn, offset)
        emit_word(0xA9400000 | (((offset / 8) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt1)
      end

      # --- immediate materialization ----------------------------------------

      # Builds `value` into `reg` with a movz for the low 16 bits followed by a
      # movk for each higher non-zero 16-bit field. `bits` is 32 (a movz to the
      # W view zeroes the upper 32) or 64. Always at least one instruction, and a
      # function only of the value, so the output stays deterministic.
      def materialize(reg, value, bits)
        value &= bits == 64 ? 0xFFFFFFFFFFFFFFFF : 0xFFFFFFFF
        sf = bits == 64 ? 1 : 0
        halfwords = bits / 16
        emit_movz(reg, value & 0xFFFF, 0, sf)
        (1...halfwords).each do |i|
          field = (value >> (16 * i)) & 0xFFFF
          emit_movk(reg, field, i, sf) unless field.zero?
        end
      end

      def emit_movz(reg, imm16, shift_hw, sf)
        base = sf == 1 ? 0xD2800000 : 0x52800000
        emit_word(base | (shift_hw << 21) | ((imm16 & 0xFFFF) << 5) | reg)
      end

      def emit_movk(reg, imm16, shift_hw, sf)
        base = sf == 1 ? 0xF2800000 : 0x72800000
        emit_word(base | (shift_hw << 21) | ((imm16 & 0xFFFF) << 5) | reg)
      end

      # --- comparisons and branches -----------------------------------------

      # cset Rd, <cond> — writes 1 when the condition held after `cmp`, else 0.
      # It is a `csinc Rd, xzr, xzr, <inverted cond>` (increment 0 when the
      # condition is false is inverted so a true condition yields 1). The 32-bit
      # form zeroes the upper half, giving a clean int 0/1.
      def emit_cset(dst, condition)
        inverted = condition ^ 1
        emit_word(0x1A800400 | (XZR << 16) | (inverted << 12) | (XZR << 5) | dst)
      end

      # b <label> — an unconditional branch, immediate left zero and recorded as
      # a fixup patched once the label offset is known.
      def emit_b(label_id)
        @fixups << [@code.bytesize, label_id, :b]
        emit_word(0x14000000)
      end

      # Patches every recorded branch with the signed word distance from the
      # branch to its target. b uses a 26-bit field (±128 MB), cbz a 19-bit one
      # (±1 MB); both are far wider than any single function needs, but an
      # overrun raises rather than silently truncating.
      def resolve_fixups
        @fixups.each do |patch_offset, label_id, kind|
          target = @labels[label_id]
          raise "unresolved label #{label_id}" unless target

          words = (target - patch_offset) / 4
          word = @code[patch_offset, 4].unpack1("L<")
          case kind
          when :b
            raise "branch displacement out of range" unless words.between?(-(1 << 25), (1 << 25) - 1)

            word |= words & 0x03FFFFFF
          when :cbz
            raise "conditional branch displacement out of range" unless words.between?(-(1 << 18), (1 << 18) - 1)

            word |= (words & 0x7FFFF) << 5
          end
          @code[patch_offset, 4] = [word].pack("L<")
        end
      end

      # --- encoding helpers -------------------------------------------------

      # The width key for the shifted-register op tables: 64 for a size-8 IR op
      # (long/pointer), 32 otherwise (the default int width).
      def width(size)
        size == 8 ? 64 : 32
      end

      # Base opcodes for the shifted-register data-processing instructions,
      # keyed by operand width. The Rm/Rn/Rd fields are OR-ed in by the caller;
      # the shift amount is always zero (a plain register operand).
      ADD_SHIFTED = { 32 => 0x0B000000, 64 => 0x8B000000 }.freeze
      SUB_SHIFTED = { 32 => 0x4B000000, 64 => 0xCB000000 }.freeze
      AND_SHIFTED = { 32 => 0x0A000000, 64 => 0x8A000000 }.freeze
      ORR_SHIFTED = { 32 => 0x2A000000, 64 => 0xAA000000 }.freeze
      EOR_SHIFTED = { 32 => 0x4A000000, 64 => 0xCA000000 }.freeze
      LSLV = { 32 => 0x1AC02000, 64 => 0x9AC02000 }.freeze
      LSRV = { 32 => 0x1AC02400, 64 => 0x9AC02400 }.freeze
      ASRV = { 32 => 0x1AC02800, 64 => 0x9AC02800 }.freeze

      # :scaled_add's element size -> the imm6 shift amount the shifted-register
      # add above applies to its second operand (the shift type field stays 00,
      # LSL). These four powers of two are exactly the set IR::Simplify fuses a
      # subscript for.
      SHIFTED_SCALES = { 1 => 0, 2 => 1, 4 => 2, 8 => 3 }.freeze

      # umulh Rd, Rn, Rm — a "data-processing (3 source)" instruction in the
      # same family as madd/msub, with op31 = 110 selecting the unsigned-high
      # variant and Ra fixed to xzr (31) in bits [14:10]. Only the 64-bit (sf=1)
      # encoding exists; there is no 32-bit counterpart to pick between.
      UMULH = 0x9BC07C00

      # "Data-processing (1 source)":
      #   sf(31) 1(30) S(29)=0 11010110(28:21) opcode2(20:16)=00000
      #   opcode(15:10) Rn(9:5) Rd(4:0)
      # opcode 000000 is RBIT (reverse the bit order in the register) and
      # 000100 is CLZ (count leading zeros), so the two differ by 4 in that
      # field — 0x1000 once shifted into place. Both exist at either operand
      # width, sf choosing the W or X view.
      RBIT = { 32 => 0x5AC00000, 64 => 0xDAC00000 }.freeze
      CLZ  = { 32 => 0x5AC01000, 64 => 0xDAC01000 }.freeze

      # "Add/subtract (extended register)", 64-bit, with option = 011 (UXTX, the
      # identity extension of an X operand) and no shift:
      #   sf(31)=1 op(30) S(29)=0 01011(28:24) opt(23:22)=00 1(21) Rm(20:16)
      #   option(15:13)=011 imm3(12:10)=000 Rn(9:5) Rd(4:0)
      # This family, not the shifted-register one, is what a register-sized
      # stack adjustment must use: here a register field of 31 reads as sp,
      # while in the shifted-register add/sub the same 31 reads as the zero
      # register (which is why "sub sp, sp, x9" has no shifted-register form).
      ADD_EXTENDED = 0x8B206000
      SUB_EXTENDED = 0xCB206000

      # "Logical (immediate)", 64-bit AND with the bitmask immediate
      # 0xFFFF_FFFF_FFFF_FFF0:
      #   sf(31)=1 opc(30:29)=00 100100(28:23) N(22)=1 immr(21:16) imms(15:10)
      #   Rn(9:5) Rd(4:0)
      # The mask is a run of 60 ones, so it is one of the patterns this encoding
      # can name: imms = 59 gives the run length (ones minus one) and immr = 60
      # the right rotation that moves the run's four-zero gap to the bottom.
      # Rounding an alloca size up to 16 therefore costs one instruction rather
      # than the four a movz/movk of an arbitrary 64-bit constant would.
      AND_NOT15 = 0x927CEC00

      # The flag-setting subtract, in the same shifted-register family. With the
      # zero register as its destination it is the `cmp` both a comparison and an
      # atomic compare-exchange leave their answer in.
      SUBS_SHIFTED = { 32 => 0x6B000000, 64 => 0xEB000000 }.freeze

      # Load-acquire (LDAR) / store-release (STLR), keyed by access width. A
      # seq_cst load is a plain LDAR and a seq_cst store a plain STLR: AArch64's
      # acquire/release instructions are *sequentially consistent* with respect
      # to one another (armv8 gives LDAR/STLR the RCsc property, unlike C++'s
      # weaker RCpc acquire/release), so neither needs an extra barrier.
      LDAR = { 4 => 0x88DFFC00, 8 => 0xC8DFFC00 }.freeze
      STLR = { 4 => 0x889FFC00, 8 => 0xC89FFC00 }.freeze

      # The exclusive pair every read-modify-write sequence is built from: LDAXR
      # takes the exclusive monitor and STLXR releases it, writing 0 into its
      # status register when the store went through and 1 when the monitor had
      # been lost. The status register is a W register at either access width.
      LDAXR = { 4 => 0x885FFC00, 8 => 0xC85FFC00 }.freeze
      STLXR = { 4 => 0x8800FC00, 8 => 0xC800FC00 }.freeze

      # cbnz w{Rt}, <offset> — the retry branch that closes each of those loops,
      # taken while the store-exclusive keeps reporting failure. The 19-bit
      # signed word offset is OR-ed in at bit 5.
      CBNZ_W = 0x35000000

      # The instruction each :atomic_rmw kind combines the value read with,
      # keyed the same way the shifted-register tables above are. :exchange has
      # none — it stores its operand unchanged.
      ATOMIC_RMW_OPCODES = {
        exchange: nil,
        fetch_add: ADD_SHIFTED, add_fetch: ADD_SHIFTED,
        fetch_sub: SUB_SHIFTED, sub_fetch: SUB_SHIFTED,
        or_fetch: ORR_SHIFTED
      }.freeze

      # The :atomic_rmw kinds whose value is the one *stored* rather than the one
      # read — gcc's "__atomic_<op>_fetch" half of each pair.
      ATOMIC_RMW_NEW_VALUE_KINDS = %i[add_fetch sub_fetch or_fetch].freeze

      # Base opcodes for the floating instructions, keyed by the IR operand size
      # (4 float / 8 double), which is the type field the encoding carries. The
      # first four are "Floating-point data-processing (2 source)" and differ
      # only in their opcode field; FCMP is the compare whose result goes to the
      # flags rather than to a register, so it names no destination.
      FMUL = { 4 => 0x1E200800, 8 => 0x1E600800 }.freeze
      FDIV = { 4 => 0x1E201800, 8 => 0x1E601800 }.freeze
      FADD = { 4 => 0x1E202800, 8 => 0x1E602800 }.freeze
      FSUB = { 4 => 0x1E203800, 8 => 0x1E603800 }.freeze
      FCMP = { 4 => 0x1E202000, 8 => 0x1E602000 }.freeze

      # "Load/store register (unsigned immediate)" with V = 1, which selects the
      # vector/floating register file. The size field follows the access width:
      # 10 for a 32-bit S register, 11 for a 64-bit D register.
      FP_LDST = {
        4 => { load: 0xBD400000, store: 0xBD000000 },
        8 => { load: 0xFD400000, store: 0xFD000000 }
      }.freeze

      # The same form at the 128-bit width, which the encoding reaches through
      # the opc field rather than the size field: size = 00 with opc = 11 is
      # "ldr q, [Xn]". Only the zero-offset load is needed — a quad-precision
      # argument is read once from the object the generator built it in — so
      # this is the bare instruction with an empty imm12.
      LDR_Q = 0x3DC00000

      # "fmov Sd, Sn" / "fmov Dd, Dn", the vector-file register move, keyed by
      # the value's width — which is also the encoding's type field (00 single,
      # 01 double). Used where a floating value wanted in one scratch register
      # is already in the other.
      FMOV_REG = { 4 => 0x1E204000, 8 => 0x1E604000 }.freeze

      # The same form with V = 0, the general-purpose register file, at each of
      # the four access widths. The narrow loads are the zero-extending ones
      # (ldrb/ldrh rather than ldrsb/ldrsh): both a whole-object copy and an
      # aggregate piece move bytes rather than numbers, so nothing here should
      # give them a sign.
      INT_LDST = {
        1 => { load: 0x39400000, store: 0x39000000 },
        2 => { load: 0x79400000, store: 0x79000000 },
        4 => { load: 0xB9400000, store: 0xB9000000 },
        8 => { load: 0xF9400000, store: 0xF9000000 }
      }.freeze

      def align16(value)
        (value + 15) & ~15
      end

      # Appends one 32-bit instruction word, little-endian (AArch64 is
      # little-endian and every instruction is exactly four bytes).
      def emit_word(word)
        @code << [word & 0xFFFFFFFF].pack("L<")
      end
    end
  end
end
