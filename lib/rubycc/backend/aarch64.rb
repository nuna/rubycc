# frozen_string_literal: true

require_relative "../compile_error"
require_relative "../ir/ir"

module Rubycc
  module Backend
    # Raised when a backend is handed an IR construct it does not yet lower.
    # It is a user-facing error rather than an internal one: the program is
    # valid C, this target simply cannot compile it yet, so the driver reports
    # it as a diagnostic instead of letting it surface as a Ruby crash.
    class UnsupportedError < Rubycc::Error; end

    # AArch64 (ARM64) code generator, the second backend behind the same
    # IR::Function -> Result contract the x86_64 one honors. It keeps the
    # spill-everything strategy — every virtual register owns an 8-byte stack
    # slot and each IR instruction loads its operands into scratch registers,
    # computes, and stores the result back — but the machine underneath is
    # entirely different: fixed-length 32-bit instructions, a flat register
    # file, and load/store addressing that shapes the frame layout.
    #
    # Frame layout (sp-relative, positive offsets). Unlike x86_64's rbp-negative
    # displacements, every slot is addressed as [sp + off] with a non-negative
    # off, because AArch64's ldr/str unsigned-offset form scales a 12-bit
    # immediate by the access size (reaching 0..32760 for a 64-bit load) while
    # the fp-relative signed form is only a 9-bit unscaled window (-256..255)
    # that a modest frame overruns at once. From sp upward the frame holds the
    # outgoing argument area, the saved frame record (x29/x30), the vreg slots
    # and the stack objects. A slot whose offset still overflows the scaled
    # immediate is reached by composing its address into a scratch register with
    # add-immediate(s) — the path is built in from the start rather than bolted
    # on for large frames.
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
    # why the IR's :gp/:sse4/:sse8 tags carry over unchanged. The generator
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
    # prologue and the AAPCS64 :va_start seed __builtin_va_arg walks). Features
    # the generator can still hand it that belong to the rest of A4 (alloca, the
    # bit-scan builtins, a 128-bit multiply) are refused with an explicit "not
    # yet supported" error rather than miscompiled.
    class AArch64
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

      # The floating counterparts of A/B, holding the operands of one floating
      # instruction. v16..v31 are caller-saved like x9..x15 (v8..v15 are the
      # callee-saved vector registers, so they are avoided), and being clear of
      # v0..v7 means evaluating a floating value never disturbs an argument
      # already placed.
      FA = 16
      FB = 17

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

      def compile(ir_func)
        @code = +"".b
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

      # Computes the frame's size and every object's base offset. From sp
      # upward: the outgoing argument area (empty unless some call in this
      # function passes an argument on the stack), the 16-byte saved record,
      # the vreg slots (8 bytes each, the region rounded to 16 so the objects
      # stay 16-aligned), then each stack object at a 16-byte-aligned size above
      # the previous. All offsets are non-negative displacements from sp.
      def layout_frame(vreg_count, stack_objects, insts, variadic)
        @outgoing_size = outgoing_argument_bytes(insts)
        @save_offset = @outgoing_size
        vreg_region = align16(vreg_count * 8)
        running = @save_offset + SAVE_AREA_SIZE + vreg_region
        @object_offsets = []
        stack_objects.each do |object_size|
          @object_offsets << running
          running += align16(object_size)
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
      def outgoing_argument_bytes(insts)
        widest = 0
        insts.each do |inst|
          next unless inst.op == :call || inst.op == :call_indirect

          count = inst.b.count { |_vreg, kind| kind == :mem }
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
      # parameter slots. x29 is not used as a frame pointer (every slot is
      # sp-relative), but the pair is saved and restored so the callee-saved x29
      # and the return address in x30 round-trip across any call this function
      # makes.
      def emit_prologue(param_kinds, variadic)
        adjust_sp(@frame_size, sub: true)
        emit_save_record(store: true)
        spill_parameters(param_kinds)
        save_argument_registers if variadic
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
          store_at(reg, @gr_save_offset + 8 * i)
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
      def emit_epilogue
        emit_save_record(store: false)
        adjust_sp(@frame_size, sub: false)
        emit_word(0xD65F03C0) # ret (branch to x30)
      end

      # Stores or reloads the x29/x30 pair at [sp + @save_offset]. The stp/ldp
      # immediate is a 7-bit signed field scaled by 8, so it reaches 504 bytes;
      # an outgoing argument area wider than that (a call with 64 or more stack
      # arguments) is addressed through the ADDR scratch instead, which holds no
      # live value in either the prologue or the epilogue.
      def emit_save_record(store:)
        if @save_offset <= MAX_PAIR_OFFSET
          store ? emit_stp(FP, LR, SP, @save_offset) : emit_ldp(FP, LR, SP, @save_offset)
        else
          emit_slot_address(ADDR, @save_offset)
          store ? emit_stp(FP, LR, ADDR, 0) : emit_ldp(FP, LR, ADDR, 0)
        end
      end

      # Brings each incoming argument into its parameter slot so it reads back
      # like any other vreg. Integer/pointer parameters come out of x0..x7 and
      # floating ones out of v0..v7, each sequence advancing its own counter; a
      # :mem parameter is copied down from the caller's stack argument area
      # (through the A scratch, which is not an argument register, so the copies
      # never disturb an argument still to be spilled) as a whole eightbyte,
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
            load_at(A, incoming_stack_offset(next_stack))
            store_reg(A, i)
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
        case inst.op
        when :const then emit_const(inst.dst, inst.a, inst.size)
        when :copy then emit_copy(inst.dst, inst.a)
        when :add then emit_arith(inst, ADD_SHIFTED)
        when :sub then emit_arith(inst, SUB_SHIFTED)
        when :and then emit_arith(inst, AND_SHIFTED)
        when :or then emit_arith(inst, ORR_SHIFTED)
        when :xor then emit_arith(inst, EOR_SHIFTED)
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
          emit_comparison(inst.dst, inst.a, inst.b, CONDITIONS.fetch(inst.op), inst.size)
        when :sext then emit_sext(inst.dst, inst.a, inst.size)
        when :zext then emit_zext(inst.dst, inst.a, inst.size)
        when :label then @labels[inst.a] = @code.bytesize
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
        # The remaining ops belong to the rest of A4. They are refused
        # explicitly so a program using them fails loudly instead of silently.
        when :mulhi then unsupported("128-bit multiply")
        when :string_addr then emit_symbol_address(inst.dst, kind: :string, string_id: inst.a)
        when :global_addr then emit_symbol_address(inst.dst, kind: :global, symbol: inst.a)
        when :func_addr then emit_symbol_address(inst.dst, kind: :func, symbol: inst.a)
        when :got_addr then emit_got_address(inst.dst, inst.a)
        when :memcpy then emit_memcpy(inst.a, inst.b, inst.size)
        when :va_start then emit_va_start(inst.a)
        when :alloca then unsupported("alloca")
        when :bit_scan then unsupported("bit-scan builtins")
        else
          raise "aarch64: unsupported IR op: #{inst.op}"
        end
      end

      # :const — materializes an immediate into the destination slot. A size-8
      # constant is built as a full 64-bit value (a long/pointer); otherwise a
      # 32-bit value whose W-register move zeroes the slot's high half, matching
      # the x86_64 backend's "mov eax, imm32" behavior.
      def emit_const(dst, value, size)
        materialize(A, value, size == 8 ? 64 : 32)
        store_reg(A, dst)
      end

      # :copy — a 64-bit slot-to-slot transfer.
      def emit_copy(dst, src)
        load_reg(A, src)
        store_reg(A, dst)
      end

      # An arithmetic/logical binary op. The operands are loaded into A/B and
      # combined with a shifted-register instruction whose width follows the IR
      # size (64-bit for size 8, otherwise a 32-bit W-register op whose upper
      # half is zeroed for free).
      def emit_arith(inst, base_table)
        load_reg(A, inst.a)
        load_reg(B, inst.b)
        emit_word(base_table[width(inst.size)] | (B << 16) | (A << 5) | A)
        store_reg(A, inst.dst)
      end

      # :mul — Rd = Rn * Rm, encoded as `madd Rd, Rn, Rm, xzr`.
      def emit_mul(dst, a, b, size)
        load_reg(A, a)
        load_reg(B, b)
        base = size == 8 ? 0x9B007C00 : 0x1B007C00 # madd with Ra = xzr
        emit_word(base | (B << 16) | (A << 5) | A)
        store_reg(A, dst)
      end

      # :div/:mod/:udiv/:umod. The quotient is `sdiv`/`udiv` of A by B; a
      # remainder is then A - quotient*B via `msub`, since AArch64 has no direct
      # remainder instruction. The signed/unsigned split mirrors the IR's own.
      def emit_divmod(dst, a, b, size, signed:, remainder:)
        load_reg(A, a)
        load_reg(B, b)
        w = width(size)
        div_base = signed ? (w == 64 ? 0x9AC00C00 : 0x1AC00C00) : (w == 64 ? 0x9AC00800 : 0x1AC00800)
        emit_word(div_base | (B << 16) | (A << 5) | C) # sdiv/udiv C, A, B
        if remainder
          msub_base = w == 64 ? 0x9B008000 : 0x1B008000
          emit_word(msub_base | (B << 16) | (A << 10) | (C << 5) | A) # msub A, C, B, A
          store_reg(A, dst)
        else
          store_reg(C, dst)
        end
      end

      # :shl/:sar/:shr — a variable shift by B's low bits (masked to 5 bits for
      # a 32-bit operand, 6 for a 64-bit one by the hardware, matching C).
      def emit_shift(dst, a, b, size, base_table)
        load_reg(A, a)
        load_reg(B, b)
        emit_word(base_table[width(size)] | (B << 16) | (A << 5) | A)
        store_reg(A, dst)
      end

      # :neg — Rd = -a, encoded as `sub Rd, xzr, a`.
      def emit_neg(dst, src, size)
        load_reg(A, src)
        emit_word(SUB_SHIFTED[width(size)] | (A << 16) | (XZR << 5) | A)
        store_reg(A, dst)
      end

      # A comparison materialized into the destination as an int 0/1. `cmp`
      # sets the flags; `cset` then writes 1 when the condition holds. A size-8
      # comparison uses the 64-bit X view (full pointer values), otherwise the
      # 32-bit W view.
      def emit_comparison(dst, a, b, condition, size)
        load_reg(A, a)
        load_reg(B, b)
        w = width(size)
        subs_base = w == 64 ? 0xEB000000 : 0x6B000000
        emit_word(subs_base | (B << 16) | (A << 5) | XZR) # cmp A, B (subs xzr, A, B)
        emit_cset(A, condition)
        store_reg(A, dst)
      end

      # :sext — sign-extend a's low `size` bytes to the full 64-bit register,
      # so a subsequent 64-bit use (pointer-offset scaling) sees a correct,
      # possibly negative, value.
      def emit_sext(dst, src, size)
        load_reg(A, src)
        word =
          case size
          when 1 then 0x93401C00 # sxtb x, w
          when 2 then 0x93403C00 # sxth x, w
          else 0x93407C00        # sxtw x, w  (size 4)
          end
        emit_word(word | (A << 5) | A)
        store_reg(A, dst)
      end

      # :zext — zero-extend a's low `size` bytes. The 1/2-byte forms are 32-bit
      # uxtb/uxth (which zero the upper 32 bits too); size 4 is a 64-bit ubfx of
      # the low 32 bits, matching x86's "mov eax, eax".
      def emit_zext(dst, src, size)
        load_reg(A, src)
        word =
          case size
          when 1 then 0x53001C00 # uxtb w, w
          when 2 then 0x53003C00 # uxth w, w
          else 0xD3407C00        # ubfx x, x, #0, #32  (size 4)
          end
        emit_word(word | (A << 5) | A)
        store_reg(A, dst)
      end

      # :load / :uload — read `size` bytes through the pointer in a's slot. A
      # signed load sign-extends a byte/halfword (ldrsb/ldrsh), the unsigned
      # form zero-extends (ldrb/ldrh); a 4-byte load is a plain W load (upper
      # half zeroed) and an 8-byte load a full X load, both sign-agnostic.
      def emit_load(dst, ptr, size, signed:)
        load_reg(A, ptr) # A = pointer value
        word =
          case size
          when 8 then 0xF9400000                  # ldr  x, [x]
          when 2 then signed ? 0x79C00000 : 0x79400000 # ldrsh/ldrh w, [x]
          when 1 then signed ? 0x39C00000 : 0x39400000 # ldrsb/ldrb w, [x]
          else 0xB9400000                         # ldr  w, [x]  (size 4)
          end
        emit_word(word | (A << 5) | A)
        store_reg(A, dst)
      end

      # :store — write value b's low `size` bytes through the pointer in a. The
      # narrower stores (strb/strh/str-w) are exactly the truncation a narrow
      # lvalue needs.
      def emit_store(ptr, value, size)
        load_reg(A, ptr)   # A = destination address
        load_reg(B, value) # B = value
        word =
          case size
          when 8 then 0xF9000000 # str  x, [x]
          when 2 then 0x79000000 # strh w, [x]
          when 1 then 0x39000000 # strb w, [x]
          else 0xB9000000        # str  w, [x]  (size 4)
          end
        emit_word(word | (A << 5) | B)
      end

      # :jump_if_zero — branch when a's low 32 bits are zero. Testing the W view
      # (cbz w) mirrors the x86_64 backend's 32-bit "test eax, eax": the
      # condition is an int 0/1 or a truthiness test the generator has already
      # reduced.
      def emit_jump_if_zero(cond, label_id)
        load_reg(A, cond)
        @fixups << [@code.bytesize, label_id, :cbz]
        emit_word(0x34000000 | A) # cbz w{A}, <patched>
      end

      # :call — a direct call. Arguments are placed in x0..x7 / v0..v7, then `bl`
      # (its 26-bit immediate left zero and recorded as an R_AARCH64_CALL26
      # relocation the linker resolves), and the result is stored back from x0 or
      # v0. A struct result is a later milestone and is refused.
      def emit_call(dst, name, args, size)
        _fixed, ret = size || [nil, nil]
        place_arguments(args)
        @relocations << { kind: :call, offset: @code.bytesize, symbol: name }
        emit_word(0x94000000) # bl <patched by R_AARCH64_CALL26>
        store_call_result(dst, ret)
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
        place_arguments(args)
        load_reg(A, target_vreg)
        emit_word(0xD63F0000 | (A << 5)) # blr A
        store_call_result(dst, ret)
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
      def place_arguments(args)
        next_stack = 0
        args.each do |vreg, kind|
          # :pad_stack reserves one stack eightbyte to 16-align the aggregate
          # behind it; it carries no value, so it only advances the counter.
          next_stack += 1 if kind == :pad_stack
          next unless kind == :mem

          load_reg(A, vreg)
          store_at(A, 8 * next_stack)
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
          when :indirect_result
            # The result buffer's address goes in x8, outside both argument
            # sequences, so it never displaces a real argument.
            load_reg(INDIRECT_RESULT_REGISTER, vreg)
          else
            raise "unknown call argument kind #{kind.inspect}"
          end
        end
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
        load_reg(A, dest_vreg) # A = destination address
        load_reg(B, src_vreg)  # B = source address
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
      def load_reg(reg, vreg)
        load_at(reg, slot_offset(vreg))
      end

      # str X{reg}, [slot]. The counterpart of #load_reg.
      def store_reg(reg, vreg)
        store_at(reg, slot_offset(vreg))
      end

      # ldr X{reg}, [sp + offset] for any frame offset, not just a vreg slot's:
      # the outgoing argument area and the caller's incoming one are addressed
      # this way too. Reaches the address through the scaled immediate when it
      # fits, otherwise through a composed address in the ADDR scratch.
      def load_at(reg, offset)
        if offset <= MAX_SCALED_OFFSET
          emit_word(0xF9400000 | ((offset / 8) << 10) | (SP << 5) | reg) # ldr x, [sp, #off]
        else
          emit_slot_address(ADDR, offset)
          emit_word(0xF9400000 | (ADDR << 5) | reg) # ldr x, [ADDR]
        end
      end

      # str X{reg}, [sp + offset]. The counterpart of #load_at.
      def store_at(reg, offset)
        if offset <= MAX_SCALED_OFFSET
          emit_word(0xF9000000 | ((offset / 8) << 10) | (SP << 5) | reg) # str x, [sp, #off]
        else
          emit_slot_address(ADDR, offset)
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
      def load_fp(reg, vreg, size)
        emit_fp_slot_access(reg, slot_offset(vreg), size, load: true)
      end

      # str S{reg}/D{reg}, [slot]. The counterpart of #load_fp.
      def store_fp(reg, vreg, size)
        emit_fp_slot_access(reg, slot_offset(vreg), size, load: false)
      end

      # The shared body of #load_fp / #store_fp. The unsigned-offset immediate is
      # scaled by the access size, so a 4-byte access reaches half as far as an
      # 8-byte one; either way a slot past the field is reached through an
      # address composed into the ADDR scratch, exactly as the integer path does.
      def emit_fp_slot_access(reg, offset, size, load:)
        base = FP_LDST.fetch(size)[load ? :load : :store]
        if offset <= 4095 * size
          emit_word(base | ((offset / size) << 10) | (SP << 5) | reg)
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
        load_fp(FA, inst.a, size)
        load_fp(FB, inst.b, size)
        emit_word(base_table.fetch(size) | (FB << 16) | (FA << 5) | FA)
        store_fp(FA, inst.dst, size)
      end

      # :feq..:fge — materialized into the destination as an int 0/1 the same way
      # an integer comparison is, but through `fcmp`, whose NZCV encoding of an
      # unordered result lets a single `cset` carry the NaN rule (see
      # FLOAT_CONDITIONS). The `cset` is the 32-bit form, so the slot gets a
      # clean int with its upper half zeroed.
      def emit_float_comparison(dst, a, b, condition, size)
        load_fp(FA, a, size)
        load_fp(FB, b, size)
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
      # requires, and the descriptor picks `fcvtzs` or `fcvtzu`. A width-8
      # descriptor produces an X result, which is also how the generator asks for
      # an unsigned 32-bit destination — truncating at 64 bits is exact across
      # the whole 0..2^32-1 range, and only the low bytes are kept afterwards.
      def emit_ftoi(dst, src_vreg, int_desc, float_size)
        int_width, signed = int_desc
        load_fp(FA, src_vreg, float_size)
        emit_word(fp_int_convert(int_width == 8 ? 1 : 0, float_size,
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
        @relocations << reloc.merge(offset: @code.bytesize)
        emit_word(0x90000000 | A)              # adrp A, <page of sym>
        emit_add_imm(A, A, 0, shift12: false)  # add  A, A, #:lo12:sym
        store_reg(A, dst)
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
        @relocations << { kind: :got, offset: @code.bytesize, symbol: symbol }
        emit_word(0x90000000 | A)             # adrp A, <page of sym's GOT slot>
        emit_word(0xF9400000 | (A << 5) | A)  # ldr  A, [A, #:got_lo12:sym]
        store_reg(A, dst)
      end

      # :addr_of / :object_addr — compute a frame address (sp + offset) into a
      # scratch register and park it in the destination slot as a pointer value.
      def emit_slot_address_to(dst, offset)
        emit_slot_address(A, offset)
        store_reg(A, dst)
      end

      # Places sp + offset (offset >= 0) into `reg`. Small offsets are one
      # add-immediate; offsets past the 12-bit field are split into a shifted
      # high part plus a low part (two adds cover up to ~16 MB); anything larger
      # is materialized and added with the extended-register form (which, unlike
      # the shifted-register add, accepts sp as its base).
      def emit_slot_address(reg, offset)
        if offset <= 0xFFF
          emit_add_imm(reg, SP, offset, shift12: false)
        elsif offset <= 0xFFFFFF
          emit_add_imm(reg, SP, offset >> 12, shift12: true)
          low = offset & 0xFFF
          emit_add_imm(reg, reg, low, shift12: false) if low.positive?
        else
          materialize(reg, offset, 64)
          emit_word(0x8B206000 | (reg << 16) | (SP << 5) | reg) # add reg, sp, reg, uxtx
        end
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
          ext = sub ? 0xCB206000 : 0x8B206000
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

      def unsupported(feature)
        raise UnsupportedError, "aarch64: not yet supported: #{feature}"
      end
    end
  end
end
