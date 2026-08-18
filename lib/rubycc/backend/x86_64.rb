# frozen_string_literal: true

require_relative "../ir/ir"
require_relative "../ir/analysis"
require_relative "../ir/promotion"
require_relative "../ir/simplify"
require_relative "slot_residency"

module Rubycc
  module Backend
    # x86_64 code generator using a spill-everything strategy: every virtual
    # register lives in its own 8-byte stack slot at [rbp - 8*(n+1)], and each
    # IR instruction loads its operands into eax/ecx, computes, and stores the
    # result back. Two kinds of value are exempt: a transient, which stays in
    # the register its producer left it in (IR::Simplify#transient_vregs), and a
    # promoted one, which owns a callee-saved register for the whole function
    # and so has no slot at all (IR::Promotion, #promotion_assignment).
    #
    # Arithmetic on a 4-byte-or-narrower type stays 32-bit (using
    # eax/ecx), whose natural wrap-around reproduces C's semantics for free;
    # `long`/`unsigned long`/pointer arithmetic is 64-bit (a REX.W prefix,
    # selected by an IR op's size == 8). Slots are always read and written 64
    # bits at a time so a pointer value survives intact (see #load_reg /
    # #store_reg).
    #
    # Value representation: an integer value narrower than 8 bytes is held in
    # its slot's low 32 bits, extended to 32 bits following its type's
    # signedness (sign-extended when signed, zero-extended when unsigned); the
    # slot's bits 32..63 are indeterminate for such a value. An 8-byte value
    # (long/unsigned long/pointer) uses the whole 64-bit slot. Every change of
    # width happens only at two boundaries: a memory access (:load sign-extends,
    # :uload zero-extends, :store truncates to `size` bytes) and an explicit
    # widening/narrowing op (:sext / :zext, whose `size` is the source width).
    # Same-width, sign-only reinterpretations (int <-> unsigned int) need no
    # code, since the two share a bit pattern.
    #
    # A floating value follows the same slot discipline: a `float` lives in its
    # slot's low 4 bytes as an IEEE754 single-precision bit pattern, a `double`
    # in the whole 8-byte slot as a double-precision one; a `float`'s bits 32..63
    # are indeterminate, exactly like a narrow integer's. The floating ops read
    # and write these slots with movss/movsd through xmm0/xmm1 (scratch), so a
    # floating constant materialized by :const (its bit pattern as an integer
    # immediate) is picked up unchanged, and int<->float conversions (:itof,
    # :ftoi, :ftof) move between a GP slot and an xmm register with the cvt*
    # family.
    #
    # System V AMD64 calling convention: an integer/pointer result comes back in
    # eax/rax and a float/double one in xmm0 (:ret's float width and a :call's
    # `ret` class select movss/movsd through it); a void function's ":ret" (a nil
    # operand) leaves both unset. Arguments are classified per parameter: an
    # integer/pointer takes the next of edi,esi,edx,ecx,r8d,r9d, a float/double
    # the next of xmm0..7, and whatever class overflows its registers spills to
    # the stack (each an eightbyte, the low bits carrying either class). A
    # variadic call sets al to the number of xmm registers it used, and a
    # variadic definition's prologue saves all six integer and all eight xmm
    # argument registers into a 176-byte register-save area so __builtin_va_arg
    # can reach the variable part.
    class X86_64
      # Every slot access goes through #load_reg / #store_reg, which use this to
      # skip a reload of a value the previous instruction has just left in a
      # register. See slot_residency.rb for why "nothing has been emitted since"
      # is a sufficient safety condition, and #emit_instruction's :label case
      # for the one state change it cannot see.
      include SlotResidency

      # Result of compiling one function: `bytes` is the machine code (an
      # ASCII-8BIT String), `symbols` is an array of
      # { name:, offset:, size: } describing the emitted function symbols, and
      # `relocations` is an array of relocation records the linker must resolve
      # (each `offset` is relative to the start of this function's code). Every
      # record carries a `kind`:
      #   * { kind: :call, offset:, symbol: } — a "call rel32" site, resolved
      #     against the named symbol (R_X86_64_PLT32);
      #   * { kind: :string, offset:, string_id: } — a "lea rip" displacement
      #     addressing read-only string `string_id` (R_X86_64_PC32 against the
      #     .rodata section);
      #   * { kind: :global, offset:, symbol: } — a "lea rip" displacement
      #     addressing the named file-scope variable `symbol` (R_X86_64_PC32
      #     against that symbol);
      #   * { kind: :func, offset:, symbol: } — a "lea rip" displacement taking
      #     the address of the function `symbol` (a function designator or
      #     "&f"), resolved like a `call` against that (defined or undefined)
      #     symbol;
      #   * { kind: :got, offset:, symbol: } — a "mov rax, [rip+disp32]" that
      #     loads `symbol`'s address from its Global Offset Table slot (the PIC
      #     form of :global/:func for a symbol this unit does not define),
      #     resolved as R_X86_64_REX_GOTPCRELX against that symbol.
      Result = Data.define(:bytes, :symbols, :relocations)

      # Register numbers. For eax/ecx/edx these are the low 3 bits of the
      # ModR/M reg field; edi/esi likewise (6, 7); r8d/r9d are 8/9 and need a
      # REX.R prefix with the low 3 bits going into the reg field.
      EAX = 0
      ECX = 1
      EDX = 2
      ESI = 6
      EDI = 7
      R8D = 8
      R9D = 9
      # r10 is a System V caller-saved scratch register that is not an argument
      # register, so it can hold an indirect call's target without clobbering
      # any argument already loaded into edi..r9d.
      R10 = 10
      # The stack pointer's register number (its ModR/M reg/rm field). It is only
      # ever named as the source of a "mov [rbp+disp], rsp" that captures the
      # post-alloca rsp as the block's base address.
      RSP = 4

      # The registers whole-function promotion hands out, in the order it hands
      # them out (see IR::Promotion and #promotion_assignment). All five are
      # callee-saved under System V AMD64 (psABI 3.2.1: rbx, rbp and r12..r15
      # are preserved across a call), which is what lets a promoted value stay
      # put across one — and none of them is used for anything else here, the
      # scratch, argument and return registers all being caller-saved. rbp is
      # excluded, being the frame pointer every slot is addressed from.
      #
      # rbx is register 3 and needs no REX extension; r12..r15 have their high
      # bit carried by REX.R when they land in a ModR/M reg field, by REX.B when
      # they land in an rm field (or a SIB base, or an opcode's low three bits)
      # and by REX.X in a SIB index — every one of which they do land in, since
      # a promoted value is named where it lives rather than moved to a scratch
      # register first. #emit_rex is where all four bits are decided.
      #
      # None of these is a scratch, argument or return register, so no residency
      # the SlotResidency table keeps is ever keyed by one; that is what lets an
      # instruction writing a promoted register leave the table standing (see
      # SlotResidency#note_register_clobbered).
      RBX = 3
      R12 = 12
      R13 = 13
      R14 = 14
      R15 = 15
      PROMOTION_REGISTERS = [RBX, R12, R13, R14, R15].freeze

      # The two vector (xmm) scratch registers the floating ops use. Their
      # numbers 0/1 double as the ModR/M reg/rm fields, so no REX.R is ever
      # needed to name them. Every floating value round-trips through a GP stack
      # slot, so these hold nothing across instructions.
      XMM0 = 0
      XMM1 = 1

      # System V AMD64 integer argument registers, in order. A call with N
      # arguments passes the first six here; any beyond that go on the stack.
      ARG_REGISTERS = [EDI, ESI, EDX, ECX, R8D, R9D].freeze

      # The registers an aggregate result comes back in, in eightbyte order: an
      # INTEGER eightbyte fills rax then rdx, an SSE eightbyte fills xmm0 then
      # xmm1 (psABI 3.2.3). A mixed struct uses one from each list in the order
      # its eightbytes are classified.
      GP_RETURN_REGISTERS = [EAX, EDX].freeze
      SSE_RETURN_REGISTERS = [XMM0, XMM1].freeze

      # :scaled_add's element size -> the SIB byte's two-bit scale field. The
      # four sizes are the only ones the encoding can name, which is exactly the
      # set IR::Simplify fuses a subscript for.
      SIB_SCALES = { 1 => 0, 2 => 1, 4 => 2, 8 => 3 }.freeze

      # IR comparison op -> setcc opcode (second byte of the 0F 9x encoding).
      # The result is materialized into eax as an int 0/1 by movzx. The signed
      # forms (setl/setle/setg/setge) test the sign/overflow flags; the unsigned
      # forms (setb/setbe/seta/setae) test the carry flag, which is what an
      # unsigned or pointer comparison needs.
      SETCC_OPCODES = {
        eq: 0x94,  # sete
        ne: 0x95,  # setne
        lt: 0x9C,  # setl
        le: 0x9E,  # setle
        gt: 0x9F,  # setg
        ge: 0x9D,  # setge
        ult: 0x92, # setb   (below, unsigned <)
        ule: 0x96, # setbe  (below or equal, unsigned <=)
        ugt: 0x97, # seta   (above, unsigned >)
        uge: 0x93  # setae  (above or equal, unsigned >=)
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
        # one callee-saved register from the prologue to every ret, so its slot
        # is never read, written or named (see #promotion_assignment, #load_reg
        # and #store_reg). Like @transient this is a property of the instruction
        # list, decided once here, and indexed by vreg number for the same
        # reason.
        @promoted = promotion_assignment(ir_func, analysis)
        # Control-flow bookkeeping: `@labels` maps a label id to its resolved
        # code offset; `@fixups` collects [patch_offset, label_id] pairs whose
        # rel32 field is overwritten once every label offset is known.
        @labels = {}
        @fixups = []
        # Each `call` and each string-literal reference records a kind-tagged
        # relocation here (see Result) so the object writer can emit a
        # .rela.text entry once this function's base in .text is known.
        @relocations = []
        # Kept for :va_start, which derives its gp_offset/fp_offset seeds and
        # overflow start from the named parameters' register classes.
        @param_kinds = ir_func.param_kinds
        emit_prologue(ir_func.vreg_count, ir_func.param_count, ir_func.param_kinds,
                      ir_func.stack_objects, ir_func.variadic)
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
      # fifth simply keep their slots.
      #
      # @promoted_registers is the same binding in assignment order, which is
      # the order the save slots are laid out in (#emit_prologue).
      def promotion_assignment(ir_func, analysis)
        vregs = IR::Promotion.candidates(ir_func, analysis).first(PROMOTION_REGISTERS.size)
        @promoted_registers = PROMOTION_REGISTERS.first(vregs.size)
        promoted = Array.new(ir_func.vreg_count)
        vregs.each_with_index { |vreg, index| promoted[vreg] = PROMOTION_REGISTERS[index] }
        promoted
      end

      # Frame layout, from rbp downward: first the virtual-register slots
      # (8 bytes each, rounded up to a 16-byte region), then the stack objects,
      # then one 8-byte save slot per promoted register, and last — for a
      # variadic function — a 176-byte register-save area below everything else.
      # Each object is placed at a 16-byte-aligned size below the previous one,
      # and @object_offsets[id] records the rbp-relative displacement of the
      # object's base (its lowest address, i.e. element 0).
      def emit_prologue(vreg_count, param_count, param_kinds, stack_objects, variadic)
        vreg_region = align16(vreg_count * 8)
        @object_offsets = []
        running = vreg_region
        stack_objects.each do |object_size|
          running += align16(object_size)
          @object_offsets << -running
        end
        # One save slot per promoted register. The registers are callee-saved,
        # so a function that uses one has to give it back exactly as it found
        # it; saving them into the frame with mov rather than with push keeps
        # rsp's 16-byte alignment — which every call depends on — a property of
        # the single `sub` below instead of the parity of the register count.
        # They are laid out in assignment order, and their number is a function
        # of the instruction list, so the frame stays deterministic (N4).
        @promoted_saves = @promoted_registers.map do |reg|
          running += 8
          [reg, -running]
        end
        # A variadic function reserves a 176-byte register-save area at the very
        # bottom of the frame; :va_start points reg_save_area here and the
        # prologue spills the six integer argument registers (48 bytes) followed
        # by the eight xmm registers (128 bytes, one 16-byte slot each) into it,
        # the System V psABI layout __builtin_va_arg reads back. 176 is a
        # multiple of 16, so the frame stays 16-aligned.
        @reg_save_area_offset = nil
        if variadic
          running += 176
          @reg_save_area_offset = -running
        end
        frame_size = align16(running)
        emit(0x55)                          # push rbp
        emit(0x48, 0x89, 0xE5)              # mov rbp, rsp
        emit(0x48, 0x81, 0xEC)              # sub rsp, imm32
        emit_bytes([frame_size].pack("L<"))
        # Before anything writes a promoted register — which the parameter
        # spilling right below is the first thing to do, a promoted parameter
        # being moved straight from its incoming argument register.
        emit_save_promoted_registers
        spill_parameters(param_kinds)
        if variadic
          emit_save_gp_registers
          emit_save_xmm_registers
        end
      end

      # Saves the promoted registers into their frame slots, "mov [rbp+disp],
      # r64" apiece. REX.W widens the move and REX.R extends r12..r15, whose low
      # three bits go into the ModR/M reg field; the rm field is rbp's, so no SIB
      # byte is involved on either side.
      def emit_save_promoted_registers
        @promoted_saves.each do |reg, disp|
          emit(0x48 | (reg >= 8 ? 0x04 : 0)) # REX.W (+ REX.R for r12..r15)
          emit(0x89)                          # mov [rbp + disp], r64
          emit_modrm_rbp_disp(reg & 7, disp)
        end
      end

      # Puts the caller's values back, the exact inverse of
      # #emit_save_promoted_registers (8B reads memory into the register). Every
      # :ret emits this immediately before its "leave", and a :ret is the only
      # way out of a function, so no path returns with a callee-saved register
      # holding this function's value.
      def emit_restore_promoted_registers
        @promoted_saves.each do |reg, disp|
          emit(0x48 | (reg >= 8 ? 0x04 : 0)) # REX.W (+ REX.R for r12..r15)
          emit(0x8B)                          # mov r64, [rbp + disp]
          emit_modrm_rbp_disp(reg & 7, disp)
        end
      end

      # Brings each incoming argument into its parameter slot (the first
      # `param_count` vregs, one per param_kinds entry) so it reads back like any
      # other vreg. The generator has already fixed where each parameter arrives:
      # a :gp in the next integer argument register (spilled directly), an
      # :sse4/:sse8 in the next xmm (spilled with movss/movsd), and a :mem on the
      # stack — pushed by the caller and now sitting above the return address at
      # [rbp + 16 + 8*k] (k the :mem running index), copied down through rax as a
      # whole eightbyte. A kind that would overrun its register file is a
      # generator contract violation and raises.
      def spill_parameters(param_kinds)
        next_gp = 0
        next_sse = 0
        next_stack = 0
        param_kinds.each_with_index do |kind, i|
          case kind
          when :gp
            raise "parameter :gp overruns the integer registers" if next_gp >= ARG_REGISTERS.size

            store_reg(ARG_REGISTERS[next_gp], i)
            next_gp += 1
          when :sse4, :sse8
            raise "parameter #{kind} overruns the xmm registers" if next_sse >= 8

            store_xmm(next_sse, i, kind == :sse8 ? 8 : 4)
            next_sse += 1
          when :mem
            emit(0x48, 0x8B)                # mov rax, [rbp + disp]
            emit_modrm_rbp_disp(EAX, 16 + 8 * next_stack)
            store_reg(EAX, i)
            next_stack += 1
          when :pad_stack
            # A 16-alignment pad occupies one incoming stack eightbyte with no
            # bound parameter, so its slot is left unwritten and only the counter
            # advances (see the caller's matching gap in #emit_call_args).
            next_stack += 1
          else
            raise "unknown parameter kind #{kind.inspect}"
          end
        end
      end

      # Spills all six System V integer argument registers into the variadic
      # register-save area, in ABI order from its base, so :va_start's
      # reg_save_area pointer plus a gp_offset reaches each one. The spill reads
      # the argument registers (unmodified by the parameter spilling above, which
      # only writes their values out to slots), so every register still holds its
      # incoming argument here.
      def emit_save_gp_registers
        ARG_REGISTERS.each_with_index do |reg, i|
          emit(0x48 | (reg >= 8 ? 0x04 : 0)) # REX.W (+ REX.R for r8/r9)
          emit(0x89)                          # mov [rbp + disp], r64
          emit_modrm_rbp_disp(reg & 7, @reg_save_area_offset + 8 * i)
        end
      end

      # Spills all eight xmm argument registers into the variadic register-save
      # area, each into the low 8 bytes of its 16-byte psABI slot (the slots
      # start at offset 48, just past the six saved GP registers). All eight are
      # saved unconditionally rather than guarded by al: this subset's va_arg only
      # ever reads back a double's 8 bytes, so saving the low half of each slot is
      # enough, and saving every register keeps the emitted code fixed regardless
      # of the actual argument count (a determinism the al-guarded form would give
      # up for a branch this backend does not need).
      def emit_save_xmm_registers
        8.times do |i|
          emit(0xF2, 0x0F, 0x11)              # movsd [rbp + disp], xmm_i
          emit_modrm_rbp_disp(i, @reg_save_area_offset + 48 + 16 * i)
        end
      end

      def emit_instruction(inst)
        case inst.op
        when :const
          emit_const(inst.dst, inst.a, inst.size)
        when :copy
          load_reg(EAX, inst.a)
          store_reg(EAX, inst.dst)
        when :add
          # 03 /r is "add r32, r/m32" — the same addition as 01 /r's "add
          # r/m32, r32" with the operands the other way round, which is what
          # lets the second one be a slot. Every entry below pairs the two
          # directions the same way (the group's low opcode plus two).
          emit_binary(inst.dst, inst.a, inst.b, [0x01, 0xC8], inst.size,
                      memory_bytes: [0x03], commutative: true)
        when :scaled_add
          emit_scaled_add(inst.dst, inst.a, inst.b, inst.size)
        when :sub
          emit_binary(inst.dst, inst.a, inst.b, [0x29, 0xC8], inst.size, memory_bytes: [0x2B])
        when :mul
          # imul (0F AF /r) is already a "r32, r/m32" form, so its register and
          # memory encodings share the same opcode.
          emit_binary(inst.dst, inst.a, inst.b, [0x0F, 0xAF, 0xC1], inst.size,
                      memory_bytes: [0x0F, 0xAF], commutative: true)
        when :mulhi
          emit_mulhi(inst.dst, inst.a, inst.b) # high 64 bits of an unsigned 64x64 product
        when :div
          emit_divmod(inst.dst, inst.a, inst.b, EAX, inst.size) # quotient in eax
        when :mod
          emit_divmod(inst.dst, inst.a, inst.b, EDX, inst.size) # remainder in edx
        when :udiv
          emit_udivmod(inst.dst, inst.a, inst.b, EAX, inst.size) # quotient in eax
        when :umod
          emit_udivmod(inst.dst, inst.a, inst.b, EDX, inst.size) # remainder in edx
        when :and
          emit_binary(inst.dst, inst.a, inst.b, [0x21, 0xC8], inst.size,
                      memory_bytes: [0x23], commutative: true)
        when :or
          emit_binary(inst.dst, inst.a, inst.b, [0x09, 0xC8], inst.size,
                      memory_bytes: [0x0B], commutative: true)
        when :xor
          emit_binary(inst.dst, inst.a, inst.b, [0x31, 0xC8], inst.size,
                      memory_bytes: [0x33], commutative: true)
        when :shl
          # shl eax, cl (D3 /4): the count comes from cl, which #emit_binary
          # loads into ecx alongside the value in eax. A size-8 operand takes a
          # REX.W prefix (shl rax, cl). The x86 shift masks the count to 5 bits
          # for a 32-bit operand, 6 for a 64-bit one.
          emit_binary(inst.dst, inst.a, inst.b, [0xD3, 0xE0], inst.size)
        when :sar
          # sar eax, cl (D3 /7): the arithmetic (sign-preserving) right shift,
          # so a negative value shifts in copies of its sign bit, matching C's
          # implementation-defined ">>" on a signed value.
          emit_binary(inst.dst, inst.a, inst.b, [0xD3, 0xF8], inst.size)
        when :shr
          # shr eax, cl (D3 /5): the logical (zero-filling) right shift, the
          # unsigned counterpart of :sar.
          emit_binary(inst.dst, inst.a, inst.b, [0xD3, 0xE8], inst.size)
        when :eq, :ne, :lt, :le, :gt, :ge, :ult, :ule, :ugt, :uge
          emit_comparison(inst.dst, inst.a, inst.b, SETCC_OPCODES.fetch(inst.op), inst.size,
                          commutative: inst.op == :eq || inst.op == :ne)
        when :fadd
          emit_float_binary(inst.dst, inst.a, inst.b, inst.size, 0x58) # addss/addsd
        when :fsub
          emit_float_binary(inst.dst, inst.a, inst.b, inst.size, 0x5C) # subss/subsd
        when :fmul
          emit_float_binary(inst.dst, inst.a, inst.b, inst.size, 0x59) # mulss/mulsd
        when :fdiv
          emit_float_binary(inst.dst, inst.a, inst.b, inst.size, 0x5E) # divss/divsd
        when :feq, :fne, :flt, :fle, :fgt, :fge
          emit_float_comparison(inst.op, inst.dst, inst.a, inst.b, inst.size)
        when :itof
          emit_itof(inst.dst, inst.a, inst.b, inst.size)
        when :ftoi
          emit_ftoi(inst.dst, inst.a, inst.b, inst.size)
        when :ftof
          emit_ftof(inst.dst, inst.a, inst.size)
        when :neg
          load_reg(EAX, inst.a)
          emit(0x48) if inst.size == 8                        # REX.W for neg rax
          emit(0xF7, 0xD8)                                    # neg eax/rax
          store_reg(EAX, inst.dst)
        when :sext
          emit_sext(inst.dst, inst.a, inst.size)
        when :zext
          emit_zext(inst.dst, inst.a, inst.size)
        when :string_addr
          emit_string_addr(inst.dst, inst.a)
        when :global_addr
          emit_global_addr(inst.dst, inst.a)
        when :got_addr
          emit_got_addr(inst.dst, inst.a)
        when :label
          # The one place a register's meaning changes without an instruction
          # being emitted: control may arrive here from a branch whose registers
          # hold something else entirely, so nothing may be assumed resident
          # past a label (see SlotResidency).
          forget_slot_residency
          @labels[inst.a] = @code.bytesize
        when :jump
          emit_jump(inst.a)
        when :jump_if_zero
          emit_jump_if_zero(inst.a, inst.b)
        when :call
          emit_call(inst.dst, inst.a, inst.b, inst.size)
        when :call_indirect
          emit_call_indirect(inst.dst, inst.a, inst.b, inst.size)
        when :func_addr
          emit_func_addr(inst.dst, inst.a)
        when :addr_of
          emit_addr_of(inst.dst, inst.a)
        when :object_addr
          emit_object_addr(inst.dst, inst.a)
        when :load
          emit_load(inst.dst, inst.a, inst.size)
        when :uload
          emit_uload(inst.dst, inst.a, inst.size)
        when :store
          emit_store(inst.a, inst.b, inst.size)
        when :memcpy
          emit_memcpy(inst.a, inst.b, inst.size)
        when :va_start
          emit_va_start(inst.a, inst.b)
        when :alloca
          emit_alloca(inst.dst, inst.a)
        when :bit_scan
          emit_bit_scan(inst.dst, inst.a, inst.b, inst.size)
        when :atomic_load
          emit_atomic_load(inst.dst, inst.a, inst.size)
        when :atomic_store
          emit_atomic_store(inst.a, inst.b, inst.size)
        when :atomic_rmw
          emit_atomic_rmw(inst.dst, inst.a, inst.b[0], inst.b[1], inst.size)
        when :atomic_cas
          emit_atomic_cas(inst.dst, inst.a, inst.b[0], inst.b[1], inst.size)
        when :atomic_fence
          emit_atomic_fence
        when :ret
          emit_ret(inst.a, inst.size)
        else
          raise "unsupported IR op: #{inst.op}"
        end
      end

      # Emits a direct call: place the arguments (see #emit_call_args), set al for
      # a variadic callee (see #emit_variadic_al), then "call rel32" with a zero
      # displacement placeholder recorded as a relocation, undo any stack-argument
      # adjustment, and read the result back (see #store_call_result). `size` is
      # the [fixed, ret] descriptor (or nil).
      def emit_call(dst, name, args, size)
        fixed, ret = size || [nil, nil]
        reclaim, sse_count = emit_call_args(args)
        emit_variadic_al(fixed, sse_count)
        emit(0xE8)                          # call rel32
        @relocations << { kind: :call, offset: @code.bytesize, symbol: name }
        emit_bytes([0].pack("l<"))          # linker patches this via R_X86_64_PLT32
        emit_reclaim_stack_args(reclaim)
        store_call_result(dst, ret)
      end

      # Emits an indirect call through a function-pointer value: place the
      # arguments, load the target address into r10 (a non-argument scratch, so
      # it survives the argument setup), set al for a variadic callee, "call r10",
      # then undo any stack-argument adjustment and read the result. The al load
      # comes after the r10 load so it lands right before the call, and r10 (a
      # distinct register) is not disturbed by it.
      def emit_call_indirect(dst, target_vreg, args, size)
        fixed, ret = size || [nil, nil]
        reclaim, sse_count = emit_call_args(args)
        load_reg(R10, target_vreg)          # mov r10, [rbp + disp]
        emit_variadic_al(fixed, sse_count)
        emit(0x41, 0xFF, 0xD2)              # call r10
        emit_reclaim_stack_args(reclaim)
        store_call_result(dst, ret)
      end

      # Reads a call's result into its destination. An in-register struct result
      # (`ret` a [buffer_vreg, pieces] array) is scattered into the caller's
      # scratch buffer (dst is unused, the value being that buffer's address); a
      # float/double comes back in xmm0 (movss/movsd, `ret` being :sse4/:sse8);
      # every other value — including a MEMORY struct's hidden pointer — in rax.
      def store_call_result(dst, ret)
        if ret.is_a?(Array)
          store_struct_call_result(ret)
        elsif ret
          store_xmm(XMM0, dst, ret == :sse8 ? 8 : 4)
        else
          store_reg(EAX, dst)
        end
      end

      # Scatters an in-register struct result into the caller's scratch buffer.
      # `ret` is [buffer_vreg, pieces]; buffer_vreg's slot (kept live across the
      # call) holds the buffer address, loaded into rcx — a register the return
      # values (rax/rdx, xmm0/xmm1) never occupy, so loading it clobbers none of
      # them. Each eightbyte is stored at its piece's offset from its return
      # register: INTEGER eightbytes from rax then rdx, SSE eightbytes from xmm0
      # then xmm1, taken in eightbyte order.
      def store_struct_call_result(ret)
        buffer_vreg, pieces = ret
        load_reg(ECX, buffer_vreg)          # rcx = buffer address
        each_return_eightbyte(pieces) do |offset, reg, sse|
          if sse
            emit(0xF2, 0x0F, 0x11)          # movsd [rcx + disp8], xmm
            emit(0x40 | (reg << 3) | 0x01, offset)
          else
            emit(0x48, 0x89)                # mov [rcx + disp8], r64
            emit(0x40 | (reg << 3) | 0x01, offset)
          end
        end
      end

      # Yields each result eightbyte's [byte offset in the buffer, register,
      # sse?], handing out the INTEGER (rax, rdx) and SSE (xmm0, xmm1) return
      # registers in classification order. Shared by the caller-side scatter
      # (#store_struct_call_result) and the callee-side gather (#emit_struct_ret).
      #
      # A System V aggregate piece is always a whole eightbyte, so the movsd /
      # mov r64 below carry it entire and only the piece's offset is read here;
      # its width needs no attention the way an AAPCS64 HFA member's would.
      def each_return_eightbyte(pieces)
        next_gp = 0
        next_sse = 0
        pieces.each do |piece|
          if piece.kind == :gp
            yield piece.offset, GP_RETURN_REGISTERS[next_gp], false
            next_gp += 1
          else
            yield piece.offset, SSE_RETURN_REGISTERS[next_sse], true
            next_sse += 1
          end
        end
      end

      # Sets al before a variadic call, as the System V AMD64 ABI requires: al
      # holds the number of vector (xmm) registers used to pass arguments, which
      # #emit_call_args counted while classifying them. `fixed` is nil for a
      # non-variadic callee (nothing emitted) and the fixed parameter count
      # otherwise (its value unused — only its non-nil-ness marks the call
      # variadic). "mov al, imm8" writes just al; eax's upper bytes held only a
      # scratch relay for the stack arguments, so overwriting al harms nothing,
      # while the argument registers (edi..r9d, xmm0..7) are already loaded.
      def emit_variadic_al(fixed, sse_count)
        return if fixed.nil?

        emit(0xB0, sse_count)               # mov al, imm8
      end

      # Places a call's arguments (each a [vreg, kind] pair the generator has
      # already assigned a class) for the System V AMD64 convention and returns
      # [reclaim_bytes, sse_count]: the bytes the caller must drop from the stack
      # afterwards, and the number of xmm registers used (for a variadic al). A
      # :gp argument goes to its integer register, an :sse4/:sse8 to its xmm and a
      # :mem to the stack (see #classify_call_args). The :mem arguments are pushed
      # in reverse so the first ends up at the lowest address ([rsp] at the call),
      # each a whole eightbyte (the slot's low bits carry its value). When their
      # count is odd an extra 8-byte pad is
      # pushed first so rsp stays 16-aligned at the call, as the ABI requires (the
      # prologue already leaves it 16-aligned). All arguments live in rbp-relative
      # slots, so the rsp changes never disturb a not-yet-loaded one.
      def emit_call_args(args)
        gp_args, sse_args, stack_args = classify_call_args(args)
        pad = stack_args.size.odd? ? 8 : 0
        emit_sub_rsp(pad) if pad.positive?
        stack_args.reverse_each do |vreg|
          if vreg == :pad_stack
            emit_sub_rsp(8)                 # reserve a 16-alignment gap, no value stored
          else
            load_reg(EAX, vreg)             # rax = argument value (whole eightbyte)
            emit(0x50)                      # push rax
          end
        end
        gp_args.each { |reg, vreg| load_reg(reg, vreg) }
        sse_args.each { |xmm, vreg, width| load_xmm(xmm, vreg, width) }
        [stack_args.size * 8 + pad, sse_args.size]
      end

      # Routes each [vreg, kind] argument to its register class, returning
      # [gp_args, sse_args, stack_args]: gp_args are [reg, vreg] pairs bound to
      # edi..r9d, sse_args are [xmm, vreg, width] triples bound to xmm0..7, and
      # stack_args are the vregs (in left-to-right order) passed on the stack. The
      # generator has already fixed the placement: a :gp takes the next integer
      # register, an :sse4/:sse8 the next xmm and a :mem the next stack eightbyte,
      # each class handed out strictly in order. A kind that would overrun its
      # register file (say a seventh :gp) is a generator contract violation, not a
      # user error, so it raises rather than silently spilling.
      def classify_call_args(args)
        next_gp = 0
        next_sse = 0
        gp_args = []
        sse_args = []
        stack_args = []
        args.each do |vreg, kind|
          case kind
          when :gp
            raise "call argument :gp overruns the integer registers" if next_gp >= ARG_REGISTERS.size

            gp_args << [ARG_REGISTERS[next_gp], vreg]
            next_gp += 1
          when :sse4, :sse8
            raise "call argument #{kind} overruns the xmm registers" if next_sse >= 8

            sse_args << [next_sse, vreg, kind == :sse8 ? 8 : 4]
            next_sse += 1
          when :mem
            stack_args << vreg
          when :pad_stack
            # A 16-alignment pad is a stack eightbyte carrying no value; it holds
            # its place in the stacked-argument order so the aggregate behind it
            # lands on a 16-byte boundary (see the gap in #emit_call_args).
            stack_args << :pad_stack
          else
            raise "unknown call argument kind #{kind.inspect}"
          end
        end
        [gp_args, sse_args, stack_args]
      end

      # Reclaims `bytes` of stack space (the pushed arguments and any alignment
      # pad) after a call returns; a no-op when nothing was pushed.
      def emit_reclaim_stack_args(bytes)
        return if bytes.zero?

        emit(0x48, 0x81, 0xC4)              # add rsp, imm32
        emit_bytes([bytes].pack("L<"))
      end

      # sub rsp, imm32 — reserves `bytes` of stack space (the pre-call alignment
      # pad for an odd number of stack arguments).
      def emit_sub_rsp(bytes)
        emit(0x48, 0x81, 0xEC)              # sub rsp, imm32
        emit_bytes([bytes].pack("L<"))
      end

      # :ret — loads the return value into its ABI register(s), then "leave; ret".
      # `size` is nil for an integer/pointer return (rax, via load_reg), 4/8 for a
      # floating one (movss/movsd into xmm0), or a piece array for an in-register
      # struct return, whose eightbytes are gathered from the buffer `value_vreg`
      # points at into the return registers. A void return (a nil operand) loads
      # nothing.
      def emit_ret(value_vreg, size)
        if value_vreg.nil?
          nil
        elsif size.is_a?(Array)
          emit_struct_ret(value_vreg, size)
        elsif size
          load_xmm(XMM0, value_vreg, size)
        else
          load_reg(EAX, value_vreg)
        end
        # After the value is loaded, since it may itself come out of a promoted
        # register, and before "leave" while rbp still addresses the frame.
        emit_restore_promoted_registers
        emit(0xC9)                          # leave
        emit(0xC3)                          # ret
      end

      # Gathers an in-register struct return into its result registers. `buffer_vreg`
      # holds the address of the value (a stack object the generator filled), loaded
      # into rcx; each eightbyte at its piece's offset is loaded into its return register —
      # INTEGER eightbytes into rax then rdx, SSE into xmm0 then xmm1 — leaving them
      # set for "leave; ret". rcx is loaded first and never itself a return register.
      def emit_struct_ret(buffer_vreg, pieces)
        load_reg(ECX, buffer_vreg)          # rcx = buffer address
        each_return_eightbyte(pieces) do |offset, reg, sse|
          if sse
            emit(0xF2, 0x0F, 0x10)          # movsd xmm, [rcx + disp8]
            emit(0x40 | (reg << 3) | 0x01, offset)
          else
            emit(0x48, 0x8B)                # mov r64, [rcx + disp8]
            emit(0x40 | (reg << 3) | 0x01, offset)
          end
        end
      end

      # :func_addr — lea rax, [rip + disp32] takes the address of the named
      # function, like :global_addr but recorded as a { kind: :func } relocation
      # the compiler resolves against the function symbol (defined here or an
      # undefined external), giving a usable function-pointer value.
      def emit_func_addr(dst, name)
        emit(0x48, 0x8D, 0x05)              # REX.W lea rax, [rip + disp32]
        @relocations << { kind: :func, offset: @code.bytesize, symbol: name }
        emit_bytes([0].pack("l<"))
        store_reg(EAX, dst)
      end

      # :string_addr — lea rax, [rip + disp32] materializes the address of
      # read-only string `string_id`. The disp32 is a zero placeholder recorded
      # as a { kind: :string } relocation; the linker patches it PC-relatively
      # (R_X86_64_PC32) against the .rodata section. A 64-bit store then parks
      # the resulting char * in the destination slot.
      def emit_string_addr(dst, string_id)
        emit(0x48, 0x8D, 0x05)              # REX.W lea rax, [rip + disp32]
        @relocations << { kind: :string, offset: @code.bytesize, string_id: string_id }
        emit_bytes([0].pack("l<"))
        store_reg(EAX, dst)
      end

      # :global_addr — lea rax, [rip + disp32] materializes the address of the
      # named file-scope variable `symbol`. Like :string_addr, the disp32 is a
      # zero placeholder recorded as a relocation ({ kind: :global }); the linker
      # patches it PC-relatively (R_X86_64_PC32) against that symbol, and a
      # 64-bit store parks the resulting address in the destination slot.
      def emit_global_addr(dst, symbol)
        emit(0x48, 0x8D, 0x05)              # REX.W lea rax, [rip + disp32]
        @relocations << { kind: :global, offset: @code.bytesize, symbol: symbol }
        emit_bytes([0].pack("l<"))
        store_reg(EAX, dst)
      end

      # :got_addr — the PIC form of :global_addr / :func_addr. "mov rax, [rip +
      # disp32]" (48 8B 05) loads the address of `symbol` from its Global Offset
      # Table slot rather than forming it PC-relatively: the slot holds the
      # symbol's run-time address, so the load yields a usable pointer directly
      # and any following load/store through it is unchanged. The disp32 is a
      # zero placeholder recorded as a { kind: :got } relocation; the linker
      # patches it PC-relatively against the symbol's GOT entry
      # (R_X86_64_REX_GOTPCRELX). Emitted only under -fPIC, and only for a symbol
      # this translation unit does not itself define, so a definition in another
      # shared object can interpose on it.
      def emit_got_addr(dst, symbol)
        emit(0x48, 0x8B, 0x05)              # REX.W mov rax, [rip + disp32]
        @relocations << { kind: :got, offset: @code.bytesize, symbol: symbol }
        emit_bytes([0].pack("l<"))
        store_reg(EAX, dst)
      end

      # "&x": lea rax, [rbp+disp] computes the absolute address of the operand's
      # slot, which a 64-bit store then parks in the destination slot.
      def emit_addr_of(dst, slot_vreg)
        emit(0x48, 0x8D)                # REX.W lea rax, [rbp+disp]
        emit_modrm_rbp_disp(EAX, slot_disp(slot_vreg))
        store_reg(EAX, dst)
      end

      # :object_addr — lea rax, [rbp+disp] loads a stack object's base address
      # (an array's first element) into rax, then a 64-bit store parks it in the
      # destination slot, giving the decayed pointer value.
      def emit_object_addr(dst, object_id)
        emit(0x48, 0x8D)                # REX.W lea rax, [rbp+disp]
        emit_modrm_rbp_disp(EAX, @object_offsets[object_id])
        store_reg(EAX, dst)
      end

      # :sext — sign-extend a's low `size` bytes to the full 64-bit register.
      # size 4 is a movsxd (the classic int -> long widening, so pointer-offset
      # scaling sees a correct, possibly negative index); size 2 a movsx r64,
      # r/m16 and size 1 a movsx r64, r/m8, which re-derive a signed
      # short/char value from just its stored low bytes.
      #
      # Both halves of the instruction are free of a fixed register: the source
      # is an r/m field, so a promoted operand is read in place, and the
      # destination a reg field, so a promoted result is written in place
      # (#widen_in_registers).
      def emit_sext(dst, src_vreg, size)
        case size
        when 1 then widen_in_registers(dst, src_vreg, [0x0F, 0xBE], rex_w: true) # movsx r64, r/m8
        when 2 then widen_in_registers(dst, src_vreg, [0x0F, 0xBF], rex_w: true) # movsx r64, r/m16
        else        widen_in_registers(dst, src_vreg, [0x63], rex_w: true)       # movsxd r64, r/m32
        end
      end

      # :zext — zero-extend a's low `size` bytes to the full 64-bit register.
      # size 1/2 are a movzx r32, r/m8 / movzx r32, r/m16; size 4 a plain 32-bit
      # mov. Each writes a 32-bit register, which x86-64 defines to clear the
      # upper 32 bits of its 64-bit whole, so all three leave a clean
      # zero-extended value.
      def emit_zext(dst, src_vreg, size)
        case size
        when 1 then widen_in_registers(dst, src_vreg, [0x0F, 0xB6]) # movzx r32, r/m8
        when 2 then widen_in_registers(dst, src_vreg, [0x0F, 0xB7]) # movzx r32, r/m16
        else        widen_in_registers(dst, src_vreg, [0x8B])       # mov r32, r/m32
        end
      end

      # The shared shape of :sext and :zext: one "reg, r/m" instruction from
      # wherever the source lives to wherever the destination lives. A promoted
      # source is the r/m operand outright; any other source goes through eax
      # first, as before, since a slot holds eight bytes and these opcodes'
      # 1/2-byte forms would read the wrong count of them. A promoted
      # destination is the reg field, so no move follows either.
      def widen_in_registers(dst, src_vreg, opcode_bytes, rex_w: false)
        refresh_slot_residency
        source = @promoted[src_vreg]
        unless source
          load_reg(EAX, src_vreg)       # rax = value
          source = EAX
        end
        target = result_register(dst)
        emit_register_rm(opcode_bytes, source, reg: target, rex_w: rex_w)
        # One "reg, r/m" instruction: its reg field is the only thing written.
        store_result(target, dst, only_wrote: target)
      end

      # :bit_scan — count the zero bits of a's value (__builtin_ctz/clz). The
      # value is loaded into rcx and the result computed into rax. A :forward
      # scan is `bsf eax, ecx` (0F BC /r), which yields the trailing zero count
      # directly. A :reverse scan is `bsr eax, ecx` (0F BD /r), giving the index
      # of the highest set bit; xor-ing that with (bits-1) turns it into the
      # leading zero count (since the index lies in 0..bits-1, the xor equals
      # (bits-1) - index). A size-8 operand adds a REX.W prefix throughout. A zero
      # operand is undefined, so no guard is emitted.
      def emit_bit_scan(dst, src_vreg, direction, size)
        load_reg(ECX, src_vreg)          # rcx = value to scan
        if direction == :forward
          emit(0x48) if size == 8        # REX.W: 64-bit bsf
          emit(0x0F, 0xBC, 0xC1)         # bsf eax, ecx  (trailing zero count)
        else
          emit(0x48) if size == 8        # REX.W: 64-bit bsr
          emit(0x0F, 0xBD, 0xC1)         # bsr eax, ecx  (index of highest set bit)
          emit(0x48) if size == 8        # REX.W: 64-bit xor
          emit(0x83, 0xF0, size * 8 - 1) # xor eax, bits-1  ->  (bits-1) - index
        end
        store_reg(EAX, dst)
      end

      # --- atomics -----------------------------------------------------------
      #
      # The four atomic ops all lower at sequential consistency, the strongest
      # order (the IR carries no weaker one — see IR::Generator#gen_builtin_atomic
      # for why strengthening is always sound). `size` is only ever 4 or 8, the
      # generator having diagnosed every other width, so each helper distinguishes
      # exactly those two: an 8-byte form is the 4-byte one with a REX.W prefix.
      #
      # x86-64's memory model (Intel SDM 3A §8.2, "loads are not reordered with
      # other loads, stores are not reordered with other stores, and a store is
      # not reordered with an *older* load") already provides everything acquire
      # and release need, so a seq_cst load is a plain mov. Only the one
      # store-then-load reordering the model does permit has to be closed for a
      # seq_cst *store*, which the implicitly locked `xchg` does — a lock-prefixed
      # instruction is a full barrier — and which is why a store is an exchange
      # here rather than a mov. Every read-modify-write carries an explicit `lock`
      # (F0) except `xchg` with a memory operand, whose lock is architecturally
      # implicit; adding a redundant F0 there would only make the encoding longer.

      # :atomic_fence — a full sequentially-consistent fence. The encoding is
      # MFENCE (0f ae f0); unlike an empty inline-asm memory clobber this also
      # constrains the hardware's store/load ordering.
      def emit_atomic_fence
        emit(0x0F, 0xAE, 0xF0)
      end

      # :atomic_load — a sequentially consistent read. On this target that is an
      # ordinary aligned mov (see the section comment), so the code is exactly
      # #emit_load's 4/8-byte case; it is spelled out separately because the
      # *reason* it is a plain mov is a property of x86-64's model, not of the IR.
      def emit_atomic_load(dst, ptr_vreg, size)
        load_reg(EAX, ptr_vreg)         # rax = pointer value
        emit(0x48) if size == 8         # REX.W
        emit(0x8B, 0x00)                # mov eax/rax, [rax]
        store_reg(EAX, dst)
      end

      # :atomic_store — a sequentially consistent write, lowered as an exchange
      # whose result is thrown away. `xchg r/m, r` (87 /r) is atomic and, being
      # implicitly locked, is also the full barrier a seq_cst store needs; a mov
      # followed by an mfence would be equivalent and longer.
      def emit_atomic_store(ptr_vreg, value_vreg, size)
        load_binary_operands(ptr_vreg, value_vreg) # rax = destination address, rcx = value
        emit(0x48) if size == 8         # REX.W
        emit(0x87, 0x08)                # xchg [rax], ecx/rcx
      end

      # :atomic_rmw — the read-modify-write family. Three shapes cover the six
      # kinds:
      #
      #   :exchange   `xchg [rax], ecx` leaves the previous value in ecx.
      #   the add family  `lock xadd [rax], ecx` (F0 0F C1 /r) writes the sum and
      #     leaves the previous value in ecx, which is :fetch_add outright.
      #     :fetch_sub negates the operand first, since subtraction is addition of
      #     the negation and the machine has no `xsub`. The two "_fetch" forms want
      #     the *new* value instead: rather than a compare-exchange loop they
      #     recompute it from the exchange-add's own result (old + operand == new),
      #     which is both shorter and lock-free by construction — and is what gcc
      #     itself emits. The operand is kept in edx across the xadd for that.
      #   :or_fetch   has no exchange-or instruction to derive from, so it is the
      #     one kind that needs a compare-exchange retry loop (see below).
      def emit_atomic_rmw(dst, ptr_vreg, value_vreg, kind, size)
        return emit_atomic_or_fetch(dst, ptr_vreg, value_vreg, size) if kind == :or_fetch

        load_binary_operands(ptr_vreg, value_vreg) # rax = address, rcx = operand
        negate = kind == :fetch_sub || kind == :sub_fetch
        keep = kind == :add_fetch || kind == :sub_fetch
        if negate
          emit(0x48) if size == 8
          emit(0xF7, 0xD9)              # neg ecx/rcx
        end
        if keep
          emit(0x48) if size == 8
          emit(0x89, 0xCA)              # mov edx/rdx, ecx/rcx   (save the addend)
        end
        if kind == :exchange
          emit(0x48) if size == 8
          emit(0x87, 0x08)              # xchg [rax], ecx/rcx
        else
          emit(0xF0)                    # lock
          emit(0x48) if size == 8
          emit(0x0F, 0xC1, 0x08)        # xadd [rax], ecx/rcx  (ecx <- old)
        end
        if keep
          emit(0x48) if size == 8
          emit(0x01, 0xD1)              # add ecx/rcx, edx/rdx  ->  the new value
        end
        store_reg(ECX, dst)
      end

      # :atomic_rmw with kind :or_fetch — the one member of the family with no
      # single-instruction form, so it retries a compare-exchange until it wins:
      #
      #     mov  eax, [rdi]          ; eax = the value we are betting on
      #   loop:
      #     mov  edx, eax            ; edx = that value
      #     or   edx, esi            ;     ... with the operand or-ed in
      #     lock cmpxchg [rdi], edx  ; if [rdi] is still eax, store edx and set ZF;
      #                              ; otherwise reload eax with what is there now
      #     jne  loop
      #     mov  eax, edx            ; the value stored is the result
      #
      # cmpxchg reads and writes eax implicitly, so the address and the operand
      # are held in rdi/rsi (which no other operand of this instruction needs)
      # rather than in the usual rax/rcx scratch pair. The retry branch's
      # displacement is computed from the emitted byte count rather than recorded
      # as a fixup, because both ends are inside this one instruction's code.
      def emit_atomic_or_fetch(dst, ptr_vreg, value_vreg, size)
        load_reg(EDI, ptr_vreg)         # rdi = address
        load_reg(ESI, value_vreg)       # rsi = operand
        emit(0x48) if size == 8
        emit(0x8B, 0x07)                # mov eax/rax, [rdi]
        loop_start = @code.bytesize
        emit(0x48) if size == 8
        emit(0x89, 0xC2)                # mov edx/rdx, eax/rax
        emit(0x48) if size == 8
        emit(0x09, 0xF2)                # or edx/rdx, esi/rsi
        emit(0xF0)                      # lock
        emit(0x48) if size == 8
        emit(0x0F, 0xB1, 0x17)          # cmpxchg [rdi], edx/rdx
        emit(0x75)                      # jne rel8
        emit((loop_start - (@code.bytesize + 1)) & 0xFF)
        emit(0x48) if size == 8
        emit(0x89, 0xD0)                # mov eax/rax, edx/rdx  (the value stored)
        store_reg(EAX, dst)
      end

      # :atomic_cas — __atomic_compare_exchange_n. `lock cmpxchg [rdi], edx`
      # (F0 0F B1 /r) compares [rdi] against eax: on a match it stores edx and
      # sets ZF, otherwise it loads what was really there into eax and clears ZF.
      #
      #     mov   eax, [rsi]         ; eax = *expected
      #     lock cmpxchg [rdi], edx
      #     sete  cl                 ; cl = the boolean result (leaves the flags)
      #     je    skip
      #     mov   [rsi], eax         ; the failing path reports the value it saw
      #   skip:
      #     movzx eax, cl
      #
      # The write-back is guarded by the branch rather than done unconditionally
      # (which would store the same bits on the winning path) for one reason: an
      # `expected` that aliases the atomic object itself would otherwise have the
      # freshly exchanged value overwritten by the old one. `sete` does not
      # disturb the flags, so the `je` still reads cmpxchg's ZF.
      def emit_atomic_cas(dst, ptr_vreg, expected_vreg, desired_vreg, size)
        load_reg(EDI, ptr_vreg)         # rdi = the atomic object's address
        load_reg(ESI, expected_vreg)    # rsi = &expected
        load_reg(EDX, desired_vreg)     # rdx = the value to store
        emit(0x48) if size == 8
        emit(0x8B, 0x06)                # mov eax/rax, [rsi]
        emit(0xF0)                      # lock
        emit(0x48) if size == 8
        emit(0x0F, 0xB1, 0x17)          # cmpxchg [rdi], edx/rdx
        emit(0x0F, 0x94, 0xC1)          # sete cl
        emit(0x74)                      # je skip
        skip_patch = @code.bytesize
        emit(0x00)                      # placeholder, filled in below
        emit(0x48) if size == 8
        emit(0x89, 0x06)                # mov [rsi], eax/rax
        @code.setbyte(skip_patch, @code.bytesize - (skip_patch + 1))
        emit(0x0F, 0xB6, 0xC1)          # movzx eax, cl  ->  the _Bool result
        store_reg(EAX, dst)
      end

      # "*p" read, sign-extending: load the pointer into rax, then read through
      # it. An 8-byte load moves a full pointer/long (mov r64, [rax]); a 4-byte
      # load reads an int (mov r32, [rax]), whose upper bits the 32-bit write
      # zeroes; a 2/1-byte load reads a short/char and sign-extends it to the
      # register (movsx), so the slot holds a promoted signed value.
      #
      # The destination is a reg field in every one of the four, so a promoted
      # one is written directly (#emit_deref).
      def emit_load(dst, ptr_vreg, size)
        case size
        when 8 then emit_deref(dst, ptr_vreg, [0x8B], rex_w: true)  # mov r64, [rax]
        when 2 then emit_deref(dst, ptr_vreg, [0x0F, 0xBF])         # movsx r32, word [rax]
        when 1 then emit_deref(dst, ptr_vreg, [0x0F, 0xBE])         # movsx r32, byte [rax]
        else        emit_deref(dst, ptr_vreg, [0x8B])               # mov r32, [rax]
        end
      end

      # "*p" read, zero-extending: the unsigned counterpart of #emit_load for an
      # unsigned char/short (and _Bool). The 2/1-byte forms use movzx; the 4/8
      # forms are identical to a signed load (a plain mov already zero-extends a
      # 32-bit read, and an 8-byte value has no spare bits).
      def emit_uload(dst, ptr_vreg, size)
        case size
        when 8 then emit_deref(dst, ptr_vreg, [0x8B], rex_w: true)  # mov r64, [rax]
        when 2 then emit_deref(dst, ptr_vreg, [0x0F, 0xB7])         # movzx r32, word [rax]
        when 1 then emit_deref(dst, ptr_vreg, [0x0F, 0xB6])         # movzx r32, byte [rax]
        else        emit_deref(dst, ptr_vreg, [0x8B])               # mov r32, [rax]
        end
      end

      # The shared shape of :load and :uload: the pointer into rax and one read
      # through [rax] into wherever the destination lives. The ModR/M is mod =
      # 00 with rm = 000, the plain "[rax]" form — no SIB byte and no
      # displacement — so only the reg field varies, and REX.R is all a promoted
      # destination costs.
      def emit_deref(dst, ptr_vreg, opcode_bytes, rex_w: false)
        load_reg(EAX, ptr_vreg)         # rax = pointer value
        target = result_register(dst)
        emit_rex(rex_w: rex_w, reg: target)
        opcode_bytes.each { |byte| emit(byte) }
        emit((target & 7) << 3)         # mod=00, rm=000: [rax]
        # The read through [rax] writes its reg field and nothing else; rax
        # itself was written by the load above, which accounted for itself.
        store_result(target, dst, only_wrote: target)
      end

      # "*p = v": rax holds the destination address, rcx the value, then rcx is
      # written through the address. An 8-byte store writes a full pointer/long
      # (mov [rax], rcx); a 4-byte store writes an int (mov [rax], ecx); a
      # 2-byte store writes a word (a 66 operand-size prefix + mov [rax], cx);
      # a 1-byte store writes just the low byte (mov [rax], cl). The narrower
      # writes are exactly the truncation a narrow lvalue needs.
      def emit_store(ptr_vreg, value_vreg, size)
        load_binary_operands(ptr_vreg, value_vreg) # rax = destination address, rcx = value
        case size
        when 8
          emit(0x48, 0x89, 0x08)        # mov [rax], rcx
        when 2
          emit(0x66, 0x89, 0x08)        # mov [rax], cx
        when 1
          emit(0x88, 0x08)              # mov [rax], cl
        else # 4
          emit(0x89, 0x08)              # mov [rax], ecx
        end
      end

      # :memcpy — a whole-struct copy "s = t". Load the destination address
      # into rdi and the source into rsi, the byte count into ecx (a struct's
      # size fits well within 32 bits), then "rep movsb" copies count bytes
      # forward. cld clears the direction flag first so the copy runs upward;
      # the System V ABI already guarantees DF is clear on entry, but clearing
      # it costs one byte and keeps this instruction self-contained. rdi/rsi/rcx
      # are all caller-saved scratch here, so nothing needs preserving.
      def emit_memcpy(dest_vreg, src_vreg, byte_count)
        load_reg(EDI, dest_vreg)            # rdi = destination address
        load_reg(ESI, src_vreg)             # rsi = source address
        emit(0xB9)                          # mov ecx, imm32
        emit_bytes([byte_count].pack("L<"))
        emit(0xFC)                          # cld
        emit(0xF3, 0xA4)                    # rep movsb
      end

      # :va_start — initializes the four System V va_list fields at the address
      # in `ap_vreg`. The named parameters' fixed classes (from @param_kinds, the
      # generator having already resolved register-vs-stack placement) count how
      # far the GP and SSE registers were consumed: `gp_named` of the six integer
      # registers arrived as :gp and `sse_named` of the eight xmm ones as
      # :sse4/:sse8, while `stack_named` (the :mem parameters) spilled to the
      # stack. rax holds the __va_list_tag address and r10 is a second scratch for
      # the two pointer fields:
      #   [rax+0]  gp_offset = 8 * gp_named             (GP registers consumed)
      #   [rax+4]  fp_offset = 48 + 16 * sse_named      (past the saved GP block,
      #                                            then the xmm registers the named
      #                                            parameters consumed)
      #   [rax+8]  overflow_arg_area = rbp + 16 + 8*stack_named (the first stacked
      #                                            variable argument, past any
      #                                            named parameter that spilled)
      #   [rax+16] reg_save_area = rbp + @reg_save_area_offset
      def emit_va_start(ap_vreg, _named)
        gp_named = @param_kinds.count(:gp)
        sse_named = @param_kinds.count(:sse4) + @param_kinds.count(:sse8)
        # A 16-alignment pad consumes a stacked slot like a spilled named
        # parameter, so the variable part begins past it too.
        stack_named = @param_kinds.count(:mem) + @param_kinds.count(:pad_stack)

        load_reg(EAX, ap_vreg)              # rax = &__va_list_tag
        emit(0xC7, 0x40, 0x00)              # mov dword [rax+0], imm32
        emit_bytes([8 * gp_named].pack("l<"))
        emit(0xC7, 0x40, 0x04)              # mov dword [rax+4], imm32
        emit_bytes([48 + 16 * sse_named].pack("l<"))
        # overflow_arg_area
        emit(0x4C, 0x8D)                    # REX.WR lea r10, [rbp + disp]
        emit_modrm_rbp_disp(R10 & 7, 16 + 8 * stack_named)
        emit(0x4C, 0x89, 0x50, 0x08)        # mov [rax+8], r10
        # reg_save_area
        emit(0x4C, 0x8D)                    # REX.WR lea r10, [rbp + disp]
        emit_modrm_rbp_disp(R10 & 7, @reg_save_area_offset)
        emit(0x4C, 0x89, 0x50, 0x10)        # mov [rax+16], r10
      end

      # :alloca — dynamic stack allocation (__builtin_alloca). Loads the
      # requested byte count, rounds it up to a 16-byte multiple (add 15; and
      # -16), lowers rsp by that amount, and captures the resulting rsp as the
      # block's base address. The rounding keeps rsp 16-aligned — so the block is
      # 16-byte aligned as gcc guarantees, and a later call still meets the ABI's
      # alignment — while the storage lives until the function's "leave" (mov
      # rsp, rbp) reclaims the whole frame on return. Every vreg slot and stack
      # object is rbp-relative, so the moved rsp disturbs none of them; a call's
      # push-based argument setup works off this lowered rsp and restores it
      # afterwards, leaving the block intact across the call.
      def emit_alloca(dst, size_vreg)
        load_reg(EAX, size_vreg)            # rax = requested byte count
        emit(0x48, 0x83, 0xC0, 0x0F)        # add rax, 15
        emit(0x48, 0x83, 0xE0, 0xF0)        # and rax, -16  (round up to 16)
        emit(0x48, 0x29, 0xC4)              # sub rsp, rax
        store_reg(RSP, dst)                 # dst = rsp (block base address)
      end

      # A size of 8 compares full 64-bit pointer values (REX.W); otherwise the
      # 32-bit int compare is used. The signed setcc still suits pointer
      # ordering here, since stack addresses stay within the positive half of
      # the 64-bit range. The second operand is named where it lives (3B /r,
      # "cmp r32, r/m32") wherever it can be, as in #emit_binary.
      #
      # `cmp` reads both of its operands and writes neither, which the first one
      # takes advantage of too: a promoted `a` is named in the reg field
      # directly rather than moved into eax to be looked at. The result still
      # goes through eax, `setcc` writing al and nothing else — one of the fixed
      # registers this file does not try to talk out of its choice.
      #
      # An equality test is the one comparison whose operands may be exchanged
      # without changing its setcc: "a == b" and "b == a" leave the same ZF,
      # while every ordering test would need its condition mirrored as well.
      def emit_comparison(dst, a, b, setcc_opcode, size = nil, commutative: false)
        refresh_slot_residency
        a, b = b, a if commutative && prefer_swapped_operands?(a, b)
        if rm_operand?(b)
          left = @promoted[a]
          unless left
            load_reg(EAX, a)
            left = EAX
          end
          emit_vreg_rm([0x3B], b, reg: left, rex_w: size == 8) # cmp r32, r/m32
        else
          load_binary_operands(a, b, commutative: commutative)
          emit(0x48) if size == 8       # REX.W widens the following cmp
          emit(0x39, 0xC8)              # cmp eax, ecx  (rax, rcx when REX.W)
        end
        emit(0x0F, setcc_opcode, 0xC0)  # setcc al
        emit(0x0F, 0xB6, 0xC0)          # movzx eax, al
        store_reg(EAX, dst)
      end

      # A floating binary op (:fadd/:fsub/:fmul/:fdiv). The first operand is
      # loaded into xmm0, the second read straight out of its slot, and the
      # result stored back. The mandatory prefix selects the scalar-single (F3,
      # size 4) or scalar-double (F2, size 8) form of the shared 0F <opcode>
      # encoding, and all four take an "xmm, xmm/m" operand pair — so the memory
      # form is the same instruction with a different ModR/M, one shorter than
      # staging the operand through xmm1 would be.
      #
      # The operands are never exchanged the way a commutative integer op's are:
      # SSE arithmetic takes a NaN result's payload from a particular source
      # operand, so the two orders are not interchangeable even where the
      # arithmetic itself is.
      def emit_float_binary(dst, a, b, size, opcode)
        load_float_operands(a, b, size)
        emit(size == 8 ? 0xF2 : 0xF3)
        emit(0x0F, opcode)
        emit_float_rm(b)
        store_xmm(XMM0, dst, size)
      end

      # Stages a floating instruction's operands: the first into xmm0, and the
      # second into xmm1 only when its slot was never written (a transient left
      # in a register, which no memory operand can name). The rescue happens
      # *before* xmm0 is filled, because the value being rescued is the one
      # sitting in xmm0 — this is the vector-file version of the ordering rule
      # #load_binary_operands follows.
      def load_float_operands(a, b, size)
        refresh_slot_residency
        load_xmm(XMM1, b, size) unless slot_written?(b)
        load_xmm(XMM0, a, size)
      end

      # The r/m half of a floating instruction whose reg half is xmm0: b's slot
      # when it was written, xmm1 when #load_float_operands had to stage it.
      def emit_float_rm(b)
        if slot_written?(b)
          emit_modrm_rbp_disp(XMM0, slot_disp(b))
        else
          emit(modrm_reg(XMM0, XMM1))
        end
      end

      # A floating comparison (:feq..:fge), materialized into eax as an int 0/1
      # like an integer comparison but through ucomiss/ucomisd, whose result is
      # read from the flags with NaN awareness. The ordering ops reduce to a
      # single seta/setae: an "above" test is false whenever ucomis leaves the
      # carry set, which it does for a greater-than *or an unordered* compare, so
      # a NaN operand yields 0. To make that reduction work for "<"/"<=", whose
      # natural test would be "below" (true on NaN), the operands are swapped so
      # "a < b" is emitted as "b > a" (still seta) — false on NaN. Equality needs
      # two flags combined (see #emit_float_equality).
      def emit_float_comparison(op, dst, a, b, size)
        case op
        when :feq then return emit_float_equality(dst, a, b, size, equal: true)
        when :fne then return emit_float_equality(dst, a, b, size, equal: false)
        when :fgt then first, second, setcc = a, b, 0x97 # seta  (a > b)
        when :fge then first, second, setcc = a, b, 0x93 # setae (a >= b)
        when :flt then first, second, setcc = b, a, 0x97 # seta  (b > a  == a < b)
        when :fle then first, second, setcc = b, a, 0x93 # setae (b >= a == a <= b)
        end
        emit_ucomis(first, second, size)
        emit(0x0F, setcc, 0xC0)         # setcc al
        emit(0x0F, 0xB6, 0xC0)          # movzx eax, al
        store_reg(EAX, dst)
      end

      # Floating equality/inequality, which a single setcc cannot express because
      # ucomis reports an unordered (NaN) compare with ZF=PF=1, the same ZF a true
      # equality sets. "==" is therefore "equal AND ordered" (sete AND setnp) and
      # "!=" its negation "unequal OR unordered" (setne OR setp), so a NaN operand
      # makes "==" 0 and "!=" 1, as C requires.
      def emit_float_equality(dst, a, b, size, equal:)
        emit_ucomis(a, b, size)
        if equal
          emit(0x0F, 0x94, 0xC0)        # sete  al   (ZF: equal or unordered)
          emit(0x0F, 0x9B, 0xC1)        # setnp cl   (not unordered)
          emit(0x20, 0xC8)              # and al, cl
        else
          emit(0x0F, 0x95, 0xC0)        # setne al   (not-equal, false on NaN)
          emit(0x0F, 0x9A, 0xC1)        # setp  cl   (unordered)
          emit(0x08, 0xC8)              # or al, cl
        end
        emit(0x0F, 0xB6, 0xC0)          # movzx eax, al
        store_reg(EAX, dst)
      end

      # ucomiss xmm0, xmm/m32 (size 4) / ucomisd (size 8, a 66 prefix), the
      # ordered scalar compare that sets ZF/PF/CF for the setcc that follows.
      # The first operand is loaded into xmm0 and the second named where it
      # lives, exactly as #emit_float_binary does.
      def emit_ucomis(a, b, size)
        load_float_operands(a, b, size)
        emit(0x66) if size == 8         # ucomisd operand-size prefix
        emit(0x0F, 0x2E)                # ucomiss/ucomisd
        emit_float_rm(b)
      end

      # :itof — cvtsi2ss/cvtsi2sd converts a signed integer in a GP register to
      # a floating value in xmm0, stored back to `dst`. `int_desc` is the source
      # [width, signed?]; the mandatory prefix (F3 for a float destination, F2
      # for double) picks the format, and REX.W treats the source as 64-bit. The
      # 64-bit source is used for a `long` and, because cvtsi2s* is signed-only,
      # for an `unsigned int` too — whose slot is zero-extended into the high 32
      # bits by construction, so the signed 64-bit conversion is exact for its
      # full 0..2^32-1 range. Every narrower or signed 32-bit source is already
      # sign/zero-extended within its low 32 bits, so the 32-bit conversion reads
      # the correct value directly. (An `unsigned long` source never reaches the
      # backend; the generator rejects it.)
      def emit_itof(dst, src_vreg, int_desc, float_size)
        int_width, signed = int_desc
        wide = int_width == 8 || (int_width == 4 && !signed)
        load_reg(EAX, src_vreg)         # rax = integer value
        emit(float_size == 8 ? 0xF2 : 0xF3)
        emit(0x48) if wide              # REX.W: 64-bit integer source
        emit(0x0F, 0x2A)
        emit(modrm_reg(XMM0, EAX))      # cvtsi2s* xmm0, eax/rax
        store_xmm(XMM0, dst, float_size)
      end

      # :ftoi — cvttss2si/cvttsd2si truncates a floating value in xmm0 toward
      # zero to a signed integer in a GP register, stored back to `dst`. The
      # mandatory prefix follows the *source* float width (F3 from float, F2 from
      # double); REX.W produces a 64-bit result for a `long` destination and for
      # an `unsigned int`, whose full 0..2^32-1 range does not fit the signed
      # 32-bit form. A destination narrower than the 32-bit result is re-ranged
      # by the generator afterwards. (An `unsigned long` destination is rejected
      # upstream.)
      def emit_ftoi(dst, src_vreg, int_desc, float_size)
        int_width, signed = int_desc
        load_xmm(XMM0, src_vreg, float_size)
        emit(float_size == 8 ? 0xF2 : 0xF3)
        wide = int_width == 8 || (int_width == 4 && !signed)
        emit(0x48) if wide             # REX.W: 64-bit signed conversion
        emit(0x0F, 0x2C)
        emit(modrm_reg(EAX, XMM0))      # cvttss2si/cvttsd2si eax/rax, xmm0
        store_reg(EAX, dst)
      end

      # :ftof — a float<->double width change. cvtss2sd (F3, from float) widens
      # and cvtsd2ss (F2, from double) narrows, in place in xmm0; `size` is the
      # source width, so the destination is stored at the opposite width.
      def emit_ftof(dst, src_vreg, src_size)
        load_xmm(XMM0, src_vreg, src_size)
        emit(src_size == 8 ? 0xF2 : 0xF3)
        emit(0x0F, 0x5A)
        emit(modrm_reg(XMM0, XMM0))     # cvtss2sd/cvtsd2ss xmm0, xmm0
        store_xmm(XMM0, dst, src_size == 8 ? 4 : 8)
      end

      # movss/movsd xmm, [rbp + disp]: loads a floating value from its slot into
      # an xmm register. The F3 (size 4) / F2 (size 8) prefix selects the scalar
      # single/double form; the rbp-relative ModR/M reuses the integer helper,
      # the xmm number sitting in its reg field (0..7 for the scratch pair and the
      # eight argument registers alike, all within the 3-bit field, so no REX.R).
      #
      # As with #load_reg, the move disappears when `xmm` already holds this
      # slot at this width and becomes a register-to-register move when another
      # vector register does. The register form is `movaps` (0F 28 /r), which
      # copies all 128 bits: that is exactly what a reload would have produced,
      # since a movss/movsd *from memory* zeroes the bits above the value it
      # loads, so the source register's upper half is already what the
      # destination's would be.
      def load_xmm(xmm, vreg, size)
        refresh_slot_residency
        return if slot_resident_in_vector?(xmm, vreg, size)

        source = vector_register_holding_slot(vreg, size)
        if source
          emit(0x0F, 0x28, modrm_reg(xmm, source)) # movaps xmm, xmm_source
        else
          emit(size == 8 ? 0xF2 : 0xF3)
          emit(0x0F, 0x10)
          emit_modrm_rbp_disp(xmm, slot_disp(vreg))
        end
        note_slot_loaded_to_vector(xmm, vreg, size)
      end

      # movss/movsd [rbp + disp], xmm: stores an xmm register into a slot, the
      # counterpart of #load_xmm (opcode 0x11 writes memory from the register).
      def store_xmm(xmm, vreg, size)
        refresh_slot_residency
        if @transient[vreg]
          note_slot_loaded_to_vector(xmm, vreg, size)
          return
        end
        emit(size == 8 ? 0xF2 : 0xF3)
        emit(0x0F, 0x11)
        emit_modrm_rbp_disp(xmm, slot_disp(vreg))
        note_slot_stored_from_vector(xmm, vreg, size)
      end

      # Emits "jmp rel32" with a zero placeholder and records a fixup so the
      # displacement can be patched once the target label offset is known.
      def emit_jump(label_id)
        emit(0xE9)                      # jmp rel32
        record_fixup(label_id)
      end

      # The condition is tested where it lives unless it is already in eax: a
      # "cmp dword [rbp+disp], 0" — or "cmp r32, 0" for a promoted condition —
      # reads the same low four bytes "test eax, eax" would have, and saves the
      # load. (The 83 /7 form takes a sign-extended imm8, which is all a
      # comparison against zero needs.)
      def emit_jump_if_zero(cond, label_id)
        refresh_slot_residency
        if rm_operand?(cond) && !slot_resident_in?(EAX, cond)
          emit_vreg_rm([0x83], cond, reg: 7)
          emit(0x00)                    # cmp r/m32, 0
        else
          load_reg(EAX, cond)
          emit(0x85, 0xC0)              # test eax, eax
        end
        emit(0x0F, 0x84)                # je rel32
        record_fixup(label_id)
      end

      # Remembers the current offset as a rel32 patch site and reserves four
      # bytes for the displacement.
      def record_fixup(label_id)
        @fixups << [@code.bytesize, label_id]
        emit_bytes([0].pack("l<"))
      end

      # Overwrites each reserved rel32 with the signed distance from the end of
      # the branch instruction to its target label.
      def resolve_fixups
        @fixups.each do |patch_offset, label_id|
          target = @labels[label_id]
          raise "unresolved label #{label_id}" unless target

          rel = target - (patch_offset + 4)
          @code[patch_offset, 4] = [rel].pack("l<")
        end
      end

      # A size of 8 materializes a full 64-bit immediate (movabs rax, imm64),
      # needed for a `long`/`unsigned long` constant that does not fit — or
      # would not sign-extend correctly — in 32 bits. Otherwise a 32-bit
      # "mov r32, imm32" suffices: it fills the low 32 bits (the whole value of
      # a 4-byte-or-narrower type) and zeroes the register's upper half.
      #
      # "mov r64/r32, imm" (B8+rd) names its destination in the opcode's low
      # three bits, extended by REX.B, so a promoted destination is written
      # directly and no move follows (#result_register).
      def emit_const(dst, value, size = nil)
        refresh_slot_residency
        target = result_register(dst)
        if size == 8
          emit_rex(rex_w: true, rm: target)                   # REX.W (+ REX.B)
          emit(0xB8 | (target & 7))                           # movabs r64, imm64
          emit_bytes([value & 0xFFFFFFFFFFFFFFFF].pack("Q<"))
        else
          emit_rex(rm: target)                                # REX.B for r12..r15
          emit(0xB8 | (target & 7))                           # mov r32, imm32
          emit_bytes([value & 0xFFFFFFFF].pack("L<"))
        end
        # Either form is one "mov r, imm" writing the opcode's own register.
        store_result(target, dst, only_wrote: target)
      end

      # A size of 8 prefixes REX.W so the operation runs on the full 64-bit
      # rax (pointer arithmetic and index scaling); otherwise it stays a 32-bit
      # int operation. The opcode bytes are identical either way.
      #
      # `memory_bytes`, when the op has such a form, is the opcode of its
      # "register, r/m" direction, which #emit_vreg_rm then points at b's own
      # slot or promoted register — so only `a` is ever loaded and the whole
      # instruction costs one load plus itself. `opcode_bytes` is the fallback
      # "eax, ecx" encoding, used by the shifts, whose count has to reach cl and
      # cannot be a memory operand at all. `commutative` lets the two be
      # exchanged, which is worth doing when it makes the one remaining load
      # free — or when it puts a promoted destination on the left, where the
      # result can be accumulated in place (#emit_promoted_binary).
      def emit_binary(dst, a, b, opcode_bytes, size = nil, memory_bytes: nil, commutative: false)
        refresh_slot_residency
        a, b = b, a if commutative && swap_binary_operands?(dst, a, b)
        if memory_bytes && @promoted[dst] && (dst == a || dst != b)
          emit_promoted_binary(dst, a, b, memory_bytes, size)
        elsif memory_bytes && rm_operand?(b)
          load_reg(EAX, a)
          emit_vreg_rm(memory_bytes, b, rex_w: size == 8)
          store_reg(EAX, dst)
        else
          load_binary_operands(a, b, commutative: commutative)
          emit(0x48) if size == 8
          opcode_bytes.each { |byte| emit(byte) }
          store_reg(EAX, dst)
        end
      end

      # The "register, r/m" direction of a binary op with its reg field aimed
      # straight at the callee-saved register `dst` was promoted into, so the
      # result is written where it lives and no move follows.
      #
      # `a` is brought into that register first, a move that disappears when
      # `dst` and `a` are the same value — the shape "i = i + 1" and "sum += x"
      # take once the single-use copies are forwarded, and the reason this path
      # exists. The caller has ruled out the one arrangement the move would
      # break: dst == b with dst != a, whose b it would overwrite before the
      # arithmetic could read it.
      #
      # Only the promoted register is written, and the residency table can name
      # none of them (PROMOTION_REGISTERS is disjoint from the scratch,
      # argument and return registers every entry is keyed by), so every
      # residency in flight survives; #note_register_clobbered still drops the
      # one the `load_reg` above may have recorded against the target itself.
      def emit_promoted_binary(dst, a, b, memory_bytes, size)
        target = @promoted[dst]
        load_reg(target, a) unless dst == a
        if rm_operand?(b)
          emit_vreg_rm(memory_bytes, b, reg: target, rex_w: size == 8)
        else
          # A transient has neither slot nor register of its own; it is still
          # in whichever scratch register its producer computed it in.
          source = register_holding_slot(b)
          unless source
            load_reg(ECX, b)
            source = ECX
          end
          emit_register_rm(memory_bytes, source, reg: target, rex_w: size == 8)
        end
        note_register_clobbered(target)
      end

      # Whether `vreg` may be named as an instruction's r/m operand, and so
      # read without being loaded first. A value in a slot is named [rbp +
      # disp] and a promoted one register-direct; only a transient is neither,
      # its value never having reached a slot and its register being whichever
      # one its producer happened to use.
      def rm_operand?(vreg)
        !@transient[vreg]
      end

      # Emits an instruction whose r/m operand is wherever `vreg` lives: its
      # stack slot, or — for a promoted value, which has no slot at all — the
      # callee-saved register it owns, named register-direct (mod = 11). `reg`
      # is the ModR/M reg field, a register number in a two-operand form and an
      # opcode extension in a group instruction. The caller must have asked
      # #rm_operand? first.
      def emit_vreg_rm(opcode_bytes, vreg, reg: EAX, rex_w: false)
        promoted = @promoted[vreg]
        if promoted
          emit_register_rm(opcode_bytes, promoted, reg: reg, rex_w: rex_w)
        else
          emit_slot_rm(opcode_bytes, vreg, reg: reg, rex_w: rex_w)
        end
      end

      # Emits an instruction whose r/m operand is `vreg`'s stack slot: the REX
      # prefix the operand width and register numbers call for, the opcode
      # bytes, then a ModR/M whose reg field is `reg` and whose r/m field
      # addresses [rbp + slot].
      #
      # Reading an operand straight out of its slot is as correct as loading it
      # into a register first and is one instruction shorter. The slot is where
      # the spill-everything discipline keeps the value; nothing is emitted
      # between the load of the first operand and this that could write memory;
      # and the width the instruction reads (4 bytes, or 8 under REX.W) is
      # exactly the width the register form's arithmetic would have used, so the
      # value representation is honored unchanged — a narrow value's
      # indeterminate high half is never looked at either way.
      def emit_slot_rm(opcode_bytes, vreg, reg: EAX, rex_w: false)
        emit_rex(rex_w: rex_w, reg: reg)
        opcode_bytes.each { |byte| emit(byte) }
        emit_modrm_rbp_disp(reg & 7, slot_disp(vreg))
      end

      # The register-direct counterpart of #emit_slot_rm: the same reg field
      # against an rm field that names register `rm` (mod = 11) rather than a
      # memory operand. This is how a promoted value is read in place. Two
      # encoding traps a memory operand has do not exist here — an rm of 100
      # names r12/rsp instead of introducing a SIB byte, and an rm of 101 names
      # r13/rbp instead of meaning "no base" — so REX.B is all r12..r15 need.
      def emit_register_rm(opcode_bytes, rm, reg: EAX, rex_w: false)
        emit_rex(rex_w: rex_w, reg: reg, rm: rm)
        opcode_bytes.each { |byte| emit(byte) }
        emit(0xC0 | ((reg & 7) << 3) | (rm & 7))
      end

      # The REX prefix an instruction needs, emitted only when some field asks
      # for one. W widens the operation to 64 bits; R extends the ModR/M reg
      # field, X the SIB index field and B the ModR/M r/m (or SIB base, or
      # opcode-embedded) register — each supplying the high bit of a register
      # number 8..15 whose low three bits stay in the field itself.
      def emit_rex(rex_w: false, reg: 0, rm: 0, index: 0)
        rex = 0x40 | (rex_w ? 0x08 : 0) | (reg >= 8 ? 0x04 : 0) |
              (index >= 8 ? 0x02 : 0) | (rm >= 8 ? 0x01 : 0)
        emit(rex) unless rex == 0x40
      end

      # Where an instruction that computes a general-register result should put
      # it: the callee-saved register `dst` was promoted into, so the value is
      # written home directly, or eax for a value that lives in a slot.
      def result_register(dst)
        @promoted[dst] || EAX
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
      # own claim rather than silently reviving a stale residency. All four
      # callers here claim the fast path today; the aarch64 backend, whose
      # #emit_alloca rounds its size in rax's counterpart and whose remainder
      # takes a scratch for the quotient, has two that cannot.
      #
      # "Nothing else the table can name" means none of rax, rcx, rdx, rsi, rdi,
      # r10, the argument registers or a promoted one — the registers #load_reg
      # is ever asked to fill, and so the only ones an entry can be keyed by.
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

      # :scaled_add — dst <- base + index * element_size, the address a
      # subscript forms. `lea` (8D /r) computes an address rather than loading
      # from it, and its SIB byte carries the scale as a two-bit shift, so the
      # element-size multiply and the add to the base become one instruction
      # that touches no flags. REX.W makes it a 64-bit computation, which is
      # what a pointer needs.
      #
      # All three of the instruction's registers are free — base and index are
      # named independently in the SIB byte and the destination in the ModR/M
      # reg field — so a promoted value may be any of them and the whole address
      # is formed without a move. That freedom is what brings the three encoding
      # traps of the SIB byte into reach, none of which a pair of scratch
      # registers could ever have hit (Intel SDM Vol. 2A, Tables 2-5 and 2-3;
      # REX.B extends the base, REX.X the index and REX.R the destination):
      #
      #   * a SIB **base** field of 101 with mod = 00 does not name rbp/r13 but
      #     "no base register, disp32 follows", so those two take mod = 01 with
      #     a zero disp8 instead — one byte for the register the encoding's
      #     shorter form has spent on something else;
      #   * a SIB base field of 100 does name rsp/r12 (it is the *ModR/M* rm
      #     field where 100 means "a SIB byte follows"), so r12 as a base needs
      #     nothing beyond its REX.B;
      #   * a SIB **index** field of 100 means "no index" — but only at REX.X =
      #     0. With REX.X set it is r12, which is why r12 works as an index and
      #     rsp, whose REX.X is 0 by construction, is the register that cannot.
      def emit_scaled_add(dst, base_vreg, index_vreg, element_size)
        base, index = address_operands(base_vreg, index_vreg)
        target = result_register(dst)
        emit_rex(rex_w: true, reg: target, index: index, rm: base)
        emit(0x8D)                              # lea r64, [base + index*scale]
        sib = (SIB_SCALES.fetch(element_size) << 6) | ((index & 7) << 3) | (base & 7)
        if (base & 7) == 5
          emit(0x44 | ((target & 7) << 3), sib, 0x00) # mod=01, rm=100 (SIB), disp8 = 0
        else
          emit(0x04 | ((target & 7) << 3), sib)       # mod=00, rm=100 (SIB follows)
        end
        # `lea` writes its reg field; base and index are read (#address_operands
        # loaded them and accounted for that itself).
        store_result(target, dst, only_wrote: target)
      end

      # Reports which register holds a scaled address's base and which its
      # index. A promoted operand is used where it already is; anything else is
      # loaded into a scratch register. Unlike an arithmetic opcode, `lea` names
      # its base and index independently, so either assignment encodes — which
      # also lets whichever operand is already resident keep the register it is
      # in when neither is promoted.
      def address_operands(base_vreg, index_vreg)
        refresh_slot_residency
        base = @promoted[base_vreg]
        index = @promoted[index_vreg]
        if base && index
          [base, index]
        elsif base
          load_reg(EAX, index_vreg)
          [base, EAX]
        elsif index
          load_reg(EAX, base_vreg)
          [EAX, index]
        elsif slot_resident_in?(EAX, index_vreg) && !slot_resident_in?(EAX, base_vreg)
          load_reg(ECX, base_vreg)
          load_reg(EAX, index_vreg)
          [ECX, EAX]
        else
          load_reg(EAX, base_vreg)
          load_reg(ECX, index_vreg)
          [EAX, ECX]
        end
      end

      # :mulhi — the unsigned high 64 bits of a 64x64 product, the piece a
      # synthesized __int128 multiply needs beyond the low 64 that :mul gives.
      # `mul` (REX.W F7 /4) multiplies rax by its one operand — b's slot or
      # promoted register, or rcx when it has neither — into rdx:rax; the high
      # half lands in rdx, which is stored to the destination. The one-operand
      # `mul` is the unsigned multiply, so this is the unsigned high product
      # regardless of the operands' declared signedness (the low 64 bits, and
      # hence a full 128-bit low result, are identical for signed and unsigned).
      def emit_mulhi(dst, a, b)
        refresh_slot_residency
        a, b = b, a if prefer_swapped_operands?(a, b)
        if rm_operand?(b)
          load_reg(EAX, a)
          emit_vreg_rm([0xF7], b, reg: 4, rex_w: true) # mul qword r/m64  (/4)
        else
          load_binary_operands(a, b, commutative: true)
          emit(0x48, 0xF7, 0xE1)        # mul rcx  -> rdx:rax = rax * rcx
        end
        store_reg(EDX, dst)             # dst = high 64 bits
      end

      # A size of 8 does a 64-bit signed division (REX.W cqo + REX.W idiv), used
      # for pointer differences; otherwise the 32-bit int division. The divisor
      # is the one-operand `idiv`'s r/m, which is b's slot wherever it can be.
      def emit_divmod(dst, a, b, result_reg, size = nil)
        divisor_in_register = load_dividend_and_divisor(a, b)
        emit(0x48) if size == 8    # REX.W turns cdq into cqo
        emit(0x99)                 # cdq/cqo: sign-extend eax/rax into edx:eax / rdx:rax
        emit_divisor_operand(divisor_in_register, b, 7, size) # idiv (/7)
        store_reg(result_reg, dst)
      end

      # Unsigned division/remainder. Unlike the signed form, the high half of
      # the dividend is zeroed (xor edx, edx, which also clears the upper 32
      # bits of rdx for the 64-bit case) rather than sign-extended, and the
      # unsigned `div` opcode is used. size 8 divides the full 64-bit rax by the
      # divisor; otherwise the 32-bit division. Quotient in eax, remainder in edx.
      def emit_udivmod(dst, a, b, result_reg, size = nil)
        divisor_in_register = load_dividend_and_divisor(a, b)
        emit(0x31, 0xD2)            # xor edx, edx
        emit_divisor_operand(divisor_in_register, b, 6, size) # div (/6)
        store_reg(result_reg, dst)
      end

      # Stages a division's operands: the dividend always into eax, the divisor
      # into ecx only when it is a transient, which the one-operand `div`/`idiv`
      # can name no other way. Returns true when the divisor is in ecx. Both
      # loads happen before the sign-extension step that follows, which writes
      # edx and must not be undone.
      #
      # The dividend and the quotient/remainder pair are fixed at rax and
      # rdx:rax by the instruction itself, so this is one of the places a
      # promoted destination changes nothing; a promoted *divisor*, though, is
      # named in place like any other r/m operand, and rdx cannot collide with
      # it (PROMOTION_REGISTERS holds none of the scratch registers).
      def load_dividend_and_divisor(a, b)
        if rm_operand?(b)
          load_reg(EAX, a)
          false
        else
          load_binary_operands(a, b)
          true
        end
      end

      # The r/m operand of the one-operand `div`/`idiv` group (F7 /6 unsigned,
      # /7 signed): ecx when #load_dividend_and_divisor put it there, and b's
      # slot or promoted register otherwise.
      def emit_divisor_operand(in_register, b, extension, size)
        if in_register
          emit(0x48) if size == 8
          emit(0xF7, 0xC0 | (extension << 3) | ECX)
        else
          emit_vreg_rm([0xF7], b, reg: extension, rex_w: size == 8)
        end
      end

      # mov r64, [rbp + disp]: slots are always moved 64 bits at a time so a
      # pointer value is not truncated to 32 bits. This is safe for ints too:
      # every int is produced by a 32-bit write to eax, which x86-64 defines to
      # zero the upper 32 bits of rax, so the slot's high half is already zero.
      # The REX prefix carries W (64-bit operand) plus R for r8/r9 (>= 8), whose
      # low 3 bits go into the ModR/M reg field.
      #
      # The load disappears when `reg` already holds this slot's value and
      # becomes a register-to-register move when another scratch register does
      # (SlotResidency decides both). Either way `reg` ends up with the same 64
      # bits the memory form would have fetched — the slot was written 64 bits
      # at a time and it is those bits being reused — so the value
      # representation above is untouched, and a narrow value's high half is as
      # indeterminate (or as zero) as it was before.
      def load_reg(reg, vreg)
        refresh_slot_residency
        promoted = @promoted[vreg]
        if promoted
          # There is no slot to read: this value has been in `promoted` since
          # the prologue and stays there until the function returns, so the
          # load is a register-to-register move — or nothing at all when the
          # caller happens to want it where it already is. The move writes
          # `reg` and touches no memory, which is exactly what the residency
          # table has to be told (see SlotResidency#note_register_clobbered).
          emit_reg_move(reg, promoted) unless reg == promoted
          note_register_clobbered(reg)
          return
        end
        return if slot_resident_in?(reg, vreg)

        source = register_holding_slot(vreg)
        if source
          emit_reg_move(reg, source)
        else
          emit(0x48 | (reg >= 8 ? 0x04 : 0)) # REX.W (+ REX.R for r8/r9)
          emit(0x8B)
          emit_modrm_rbp_disp(reg & 7, slot_disp(vreg))
        end
        note_slot_loaded(reg, vreg)
      end

      # mov [rbp + disp], r64. See load_reg for the 64-bit and REX rationale.
      # The store itself is never skipped: the slot is the value's home, and
      # nothing here knows whether a later branch reaches a reader by a path
      # that goes nowhere near this register.
      def store_reg(reg, vreg)
        refresh_slot_residency
        promoted = @promoted[vreg]
        if promoted
          # The value's home is a register, so the store is a move into it. No
          # slot is written and no scratch register can be describing one (a
          # promoted vreg is never recorded), so every residency in flight is
          # still true — it is only the emitted bytes that have to be accounted
          # for (SlotResidency#note_slots_undisturbed).
          emit_reg_move(promoted, reg) unless reg == promoted
          note_slots_undisturbed
          return
        end
        if @transient[vreg]
          # The value's only reader is the next instruction, which will find it
          # here; the slot itself is never named again, so nothing is written.
          note_slot_loaded(reg, vreg)
          return
        end
        emit(0x48 | (reg >= 8 ? 0x04 : 0)) # REX.W (+ REX.R for r8/r9)
        emit(0x89)
        emit_modrm_rbp_disp(reg & 7, slot_disp(vreg))
        note_slot_stored(reg, vreg)
      end

      # Whether `vreg`'s slot may be named as an instruction's memory operand.
      # It may not when the value never reached it: a transient is left in the
      # register its producer computed it in, and a promoted value lives in a
      # register of its own for the whole function, so in both cases the slot
      # holds nothing. The test is on the two sets, not on what happens to be
      # resident, so it does not depend on how far into an instruction it is
      # asked.
      #
      # Only the floating ops ask any more; the integer ones ask #rm_operand?
      # instead, a promoted value being nameable there as a register even though
      # its slot is not. The difference does not arise in practice — a value the
      # vector register file touches is refused promotion outright
      # (IR::Promotion::VECTOR_OPS), so a floating operand is only ever a slot or
      # a transient — and the stricter test is the one to ask on a path that has
      # no register form to fall back to but xmm1.
      def slot_written?(vreg)
        !@transient[vreg] && !@promoted[vreg]
      end

      # mov r64, r64 — the register-to-register form of #load_reg's mov, for a
      # value that is already in another scratch register or that lives in a
      # promoted one. REX.W widens it, REX.R extends the source (the ModR/M reg
      # field) and REX.B the destination (the rm field), so r8/r9 and r12..r15
      # work on either side. The ModR/M is register-direct (mod = 11), where an
      # rm of 100 names r12 rather than selecting a SIB byte, so no promoted
      # register needs a special case the way a memory operand's base would.
      def emit_reg_move(dst, src)
        emit(0x48 | (src >= 8 ? 0x04 : 0) | (dst >= 8 ? 0x01 : 0))
        emit(0x89, 0xC0 | ((src & 7) << 3) | (dst & 7))
      end

      # Loads a two-operand instruction's operands into eax and ecx.
      #
      # Which one is fetched first stops being arbitrary once #load_reg can
      # reuse a resident value: if `b` is the value sitting in eax, loading `a`
      # there first would throw it away and force `b` to be re-read from memory.
      # Fetching ecx first instead keeps it, as a register move. A `commutative`
      # op can do better still — swapping the two makes the resident operand
      # eax's, so nothing is moved at all — and is safe to swap precisely
      # because the opcode's two operands are interchangeable (this is not true
      # of :sub or of the shifts, whose count must reach cl).
      def load_binary_operands(a, b, commutative: false)
        refresh_slot_residency
        if commutative && prefer_swapped_operands?(a, b)
          a, b = b, a
        elsif slot_resident_in?(EAX, b) && !slot_resident_in?(EAX, a)
          # Fetch ecx first: eax is where b is, and loading a would lose it —
          # which for a transient b would lose it for good, its slot never
          # having been written.
          load_reg(ECX, b)
        end
        load_reg(EAX, a)
        load_reg(ECX, b)
      end

      # Whether a commutative op should exchange its operands. A promoted
      # destination outranks everything else: "sum = x + sum" is the same
      # addition as "sum = sum + x", and only the second can be accumulated in
      # place (#emit_promoted_binary), which saves a move whatever the operands
      # cost. With that settled either way, the older question stands alone.
      def swap_binary_operands?(dst, a, b)
        return dst == b && dst != a if @promoted[dst]

        prefer_swapped_operands?(a, b)
      end

      # Whether a commutative op is better off with its operands exchanged.
      # Two cases want it, and they are one case seen twice: whichever operand
      # is already in eax should be the one taken from a register, leaving the
      # other free to be read where it lives. An operand that can be named
      # neither in a slot nor in a promoted register (a transient) has to be
      # that one, since no r/m field can reach it.
      def prefer_swapped_operands?(a, b)
        return false unless rm_operand?(a)

        !rm_operand?(b) || (slot_resident_in?(EAX, b) && !slot_resident_in?(EAX, a))
      end

      def slot_disp(vreg)
        -8 * (vreg + 1)
      end

      # Emits the ModR/M byte (+ displacement bytes) for a memory operand of
      # the form [rbp + disp] with the given reg field. Uses an 8-bit
      # displacement form when it fits, otherwise 32-bit. Emits directly to
      # @code instead of building and concatenating pack() strings, since
      # this runs on the instruction-encoding hot path.
      def emit_modrm_rbp_disp(reg, disp)
        rbp_rm = 0x05
        if disp >= -128 && disp <= 127
          emit(0x40 | (reg << 3) | rbp_rm)  # mod=01 (disp8)
          emit(disp & 0xFF)
        else
          emit(0x80 | (reg << 3) | rbp_rm)  # mod=10 (disp32)
          emit((disp >> 0) & 0xFF, (disp >> 8) & 0xFF, (disp >> 16) & 0xFF, (disp >> 24) & 0xFF)
        end
      end

      # A register-direct ModR/M byte (mod=11) with the given reg and rm fields,
      # used by the floating ops to name two xmm registers (or an xmm and a GP
      # register in a cvt*). Both fields are 0/1/eax here, so no REX extension
      # bit is ever required.
      def modrm_reg(reg, rm)
        0xC0 | (reg << 3) | rm
      end

      def align16(value)
        (value + 15) & ~15
      end

      # Fixed-arity on purpose: this is the instruction-encoding hot path, and
      # a splat would allocate a new Array on every call. Four bytes covers
      # the longest fixed-count call site in this file.
      def emit(byte1, byte2 = nil, byte3 = nil, byte4 = nil)
        @code << byte1
        @code << byte2 if byte2
        @code << byte3 if byte3
        @code << byte4 if byte4
      end

      # Callers always pass the result of Array#pack (or a concatenation of
      # such results), which is already ASCII-8BIT, so no re-encoding copy
      # is needed here.
      def emit_bytes(string)
        @code << string
      end
    end
  end
end
