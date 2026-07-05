# frozen_string_literal: true

require_relative "../ir/ir"

module Rubycc
  module Backend
    # x86_64 code generator using a spill-everything strategy: every virtual
    # register lives in its own 8-byte stack slot at [rbp - 8*(n+1)], and each
    # IR instruction loads its operands into eax/ecx, computes, and stores the
    # result back. Integer arithmetic stays 32-bit (using eax/ecx), which
    # reproduces C `int` wrap-around semantics for free; slots themselves are
    # read and written 64 bits at a time so a pointer value survives intact
    # (see #load_reg / #store_reg).
    #
    # System V AMD64: the integer return value is passed in eax.
    class X86_64
      # Result of compiling one function: `bytes` is the machine code (an
      # ASCII-8BIT String), `symbols` is an array of
      # { name:, offset:, size: } describing the emitted function symbols, and
      # `relocations` is an array of { offset:, symbol: } marking each `call`
      # site whose rel32 field the linker must resolve (offset is relative to
      # the start of this function's code).
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

      # System V AMD64 integer argument registers, in order. A call with N
      # arguments (N <= 6) uses the first N entries.
      ARG_REGISTERS = [EDI, ESI, EDX, ECX, R8D, R9D].freeze

      # IR comparison op -> setcc opcode (second byte of the 0F 9x encoding).
      # The result is materialized into eax as an int 0/1 by movzx.
      SETCC_OPCODES = {
        eq: 0x94, # sete
        ne: 0x95, # setne
        lt: 0x9C, # setl
        le: 0x9E, # setle
        gt: 0x9F, # setg
        ge: 0x9D  # setge
      }.freeze

      def compile(ir_func)
        @code = +"".b
        # Control-flow bookkeeping: `@labels` maps a label id to its resolved
        # code offset; `@fixups` collects [patch_offset, label_id] pairs whose
        # rel32 field is overwritten once every label offset is known.
        @labels = {}
        @fixups = []
        # Each `call` records a { offset:, symbol: } here so the object writer
        # can emit a .rela.text entry once this function's base in .text is
        # known.
        @relocations = []
        emit_prologue(ir_func.vreg_count, ir_func.param_count)
        ir_func.insts.each { |inst| emit_instruction(inst) }
        resolve_fixups

        Result.new(
          bytes: @code,
          symbols: [{ name: ir_func.name, offset: 0, size: @code.bytesize }],
          relocations: @relocations
        )
      end

      private

      def emit_prologue(vreg_count, param_count)
        frame_size = align16(vreg_count * 8)
        emit(0x55)                          # push rbp
        emit(0x48, 0x89, 0xE5)              # mov rbp, rsp
        emit(0x48, 0x81, 0xEC)              # sub rsp, imm32
        emit_bytes([frame_size].pack("L<"))
        # Spill the incoming argument registers into the parameter slots (the
        # first `param_count` vregs) so they read back like any other vreg.
        param_count.times { |i| store_reg(ARG_REGISTERS[i], i) }
      end

      def emit_instruction(inst)
        case inst.op
        when :const
          emit_const(inst.dst, inst.a)
        when :copy
          load_reg(EAX, inst.a)
          store_reg(EAX, inst.dst)
        when :add
          emit_binary(inst.dst, inst.a, inst.b, [0x01, 0xC8]) # add eax, ecx
        when :sub
          emit_binary(inst.dst, inst.a, inst.b, [0x29, 0xC8]) # sub eax, ecx
        when :mul
          emit_binary(inst.dst, inst.a, inst.b, [0x0F, 0xAF, 0xC1]) # imul eax, ecx
        when :div
          emit_divmod(inst.dst, inst.a, inst.b, EAX)          # quotient in eax
        when :mod
          emit_divmod(inst.dst, inst.a, inst.b, EDX)          # remainder in edx
        when :eq, :ne, :lt, :le, :gt, :ge
          emit_comparison(inst.dst, inst.a, inst.b, SETCC_OPCODES.fetch(inst.op))
        when :neg
          load_reg(EAX, inst.a)
          emit(0xF7, 0xD8)                                    # neg eax
          store_reg(EAX, inst.dst)
        when :label
          @labels[inst.a] = @code.bytesize
        when :jump
          emit_jump(inst.a)
        when :jump_if_zero
          emit_jump_if_zero(inst.a, inst.b)
        when :call
          emit_call(inst.dst, inst.a, inst.b)
        when :addr_of
          emit_addr_of(inst.dst, inst.a)
        when :load
          emit_load(inst.dst, inst.a, inst.size)
        when :store
          emit_store(inst.a, inst.b, inst.size)
        when :ret
          load_reg(EAX, inst.a)
          emit(0xC9)                                          # leave
          emit(0xC3)                                          # ret
        else
          raise "unsupported IR op: #{inst.op}"
        end
      end

      # Emits a call: load each argument from its slot into the matching
      # System V argument register, then "call rel32" with a zero displacement
      # placeholder recorded as a relocation, then spill eax to the result
      # slot. All arguments already live in slots, so loading them in order
      # cannot clobber a not-yet-loaded argument. The prologue keeps rsp
      # 16-aligned (push rbp plus a 16-aligned sub), so at the call the stack
      # meets the System V alignment requirement without extra adjustment.
      def emit_call(dst, name, arg_vregs)
        arg_vregs.each_with_index { |vreg, i| load_reg(ARG_REGISTERS[i], vreg) }
        emit(0xE8)                          # call rel32
        @relocations << { offset: @code.bytesize, symbol: name }
        emit_bytes([0].pack("l<"))          # linker patches this via R_X86_64_PLT32
        store_reg(EAX, dst)
      end

      # "&x": lea rax, [rbp+disp] computes the absolute address of the operand's
      # slot, which a 64-bit store then parks in the destination slot.
      def emit_addr_of(dst, slot_vreg)
        emit(0x48, 0x8D)                # REX.W lea rax, [rbp+disp]
        emit_bytes(modrm_rbp_disp(EAX, slot_disp(slot_vreg)))
        store_reg(EAX, dst)
      end

      # "*p" read: load the pointer from its slot into rax, then read through
      # it. An 8-byte load moves a full pointer (mov rax, [rax]); a 4-byte load
      # reads an int (mov eax, [rax]), whose upper bits the store then zeroes.
      def emit_load(dst, ptr_vreg, size)
        load_reg(EAX, ptr_vreg)         # rax = pointer value
        if size == 8
          emit(0x48, 0x8B, 0x00)        # mov rax, [rax]
        else
          emit(0x8B, 0x00)              # mov eax, [rax]
        end
        store_reg(EAX, dst)
      end

      # "*p = v": rax holds the destination address, rcx the value, then rcx is
      # written through the address. An 8-byte store writes a full pointer
      # (mov [rax], rcx); a 4-byte store writes an int (mov [rax], ecx).
      def emit_store(ptr_vreg, value_vreg, size)
        load_reg(EAX, ptr_vreg)         # rax = destination address
        load_reg(ECX, value_vreg)       # rcx = value
        if size == 8
          emit(0x48, 0x89, 0x08)        # mov [rax], rcx
        else
          emit(0x89, 0x08)              # mov [rax], ecx
        end
      end

      def emit_comparison(dst, a, b, setcc_opcode)
        load_reg(EAX, a)
        load_reg(ECX, b)
        emit(0x39, 0xC8)                # cmp eax, ecx
        emit(0x0F, setcc_opcode, 0xC0)  # setcc al
        emit(0x0F, 0xB6, 0xC0)          # movzx eax, al
        store_reg(EAX, dst)
      end

      # Emits "jmp rel32" with a zero placeholder and records a fixup so the
      # displacement can be patched once the target label offset is known.
      def emit_jump(label_id)
        emit(0xE9)                      # jmp rel32
        record_fixup(label_id)
      end

      def emit_jump_if_zero(cond, label_id)
        load_reg(EAX, cond)
        emit(0x85, 0xC0)                # test eax, eax
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

      def emit_const(dst, value)
        emit(0xB8)                                            # mov eax, imm32
        emit_bytes([value & 0xFFFFFFFF].pack("L<"))
        store_reg(EAX, dst)
      end

      def emit_binary(dst, a, b, opcode_bytes)
        load_reg(EAX, a)
        load_reg(ECX, b)
        emit(*opcode_bytes)
        store_reg(EAX, dst)
      end

      def emit_divmod(dst, a, b, result_reg)
        load_reg(EAX, a)
        load_reg(ECX, b)
        emit(0x99)          # cdq: sign-extend eax into edx:eax
        emit(0xF7, 0xF9)    # idiv ecx
        store_reg(result_reg, dst)
      end

      # mov r64, [rbp + disp]: slots are always moved 64 bits at a time so a
      # pointer value is not truncated to 32 bits. This is safe for ints too:
      # every int is produced by a 32-bit write to eax, which x86-64 defines to
      # zero the upper 32 bits of rax, so the slot's high half is already zero.
      # The REX prefix carries W (64-bit operand) plus R for r8/r9 (>= 8), whose
      # low 3 bits go into the ModR/M reg field.
      def load_reg(reg, vreg)
        emit(0x48 | (reg >= 8 ? 0x04 : 0)) # REX.W (+ REX.R for r8/r9)
        emit(0x8B)
        emit_bytes(modrm_rbp_disp(reg & 7, slot_disp(vreg)))
      end

      # mov [rbp + disp], r64. See load_reg for the 64-bit and REX rationale.
      def store_reg(reg, vreg)
        emit(0x48 | (reg >= 8 ? 0x04 : 0)) # REX.W (+ REX.R for r8/r9)
        emit(0x89)
        emit_bytes(modrm_rbp_disp(reg & 7, slot_disp(vreg)))
      end

      def slot_disp(vreg)
        -8 * (vreg + 1)
      end

      # Builds the ModR/M byte (+ displacement bytes) for a memory operand of
      # the form [rbp + disp] with the given reg field. Uses an 8-bit
      # displacement form when it fits, otherwise 32-bit.
      def modrm_rbp_disp(reg, disp)
        rbp_rm = 0x05
        if disp >= -128 && disp <= 127
          modrm = 0x40 | (reg << 3) | rbp_rm  # mod=01 (disp8)
          [modrm].pack("C") + [disp].pack("c")
        else
          modrm = 0x80 | (reg << 3) | rbp_rm  # mod=10 (disp32)
          [modrm].pack("C") + [disp].pack("l<")
        end
      end

      def align16(value)
        (value + 15) & ~15
      end

      def emit(*bytes)
        bytes.each { |byte| @code << byte }
      end

      def emit_bytes(string)
        @code << string.b
      end
    end
  end
end
