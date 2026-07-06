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
    # Value representation: a scalar value in a slot is always held already
    # sign-extended to at least 32 bits. A char is no exception — it lives in
    # its slot as a full sign-extended int, and the narrowing to 8 bits happens
    # only at the memory boundary: a size-1 :load sign-extends the byte it reads
    # (movsx), a size-1 :store writes just the low byte (cl), and the :sext8 op
    # narrows an int down to a char value in a register.
    #
    # System V AMD64: the return value is passed in eax/rax; a void function's
    # ":ret" (a nil operand) leaves eax/rax unset since there is no value.
    class X86_64
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
      #     against that symbol).
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
        # Each `call` and each string-literal reference records a kind-tagged
        # relocation here (see Result) so the object writer can emit a
        # .rela.text entry once this function's base in .text is known.
        @relocations = []
        emit_prologue(ir_func.vreg_count, ir_func.param_count, ir_func.stack_objects)
        ir_func.insts.each { |inst| emit_instruction(inst) }
        resolve_fixups

        Result.new(
          bytes: @code,
          symbols: [{ name: ir_func.name, offset: 0, size: @code.bytesize }],
          relocations: @relocations
        )
      end

      private

      # Frame layout, from rbp downward: first the virtual-register slots
      # (8 bytes each, rounded up to a 16-byte region), then the stack objects.
      # Each object is placed at a 16-byte-aligned size below the previous one,
      # and @object_offsets[id] records the rbp-relative displacement of the
      # object's base (its lowest address, i.e. element 0).
      def emit_prologue(vreg_count, param_count, stack_objects)
        vreg_region = align16(vreg_count * 8)
        @object_offsets = []
        running = vreg_region
        stack_objects.each do |object_size|
          running += align16(object_size)
          @object_offsets << -running
        end
        frame_size = align16(running)
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
          emit_binary(inst.dst, inst.a, inst.b, [0x01, 0xC8], inst.size) # add eax, ecx
        when :sub
          emit_binary(inst.dst, inst.a, inst.b, [0x29, 0xC8], inst.size) # sub eax, ecx
        when :mul
          emit_binary(inst.dst, inst.a, inst.b, [0x0F, 0xAF, 0xC1], inst.size) # imul eax, ecx
        when :div
          emit_divmod(inst.dst, inst.a, inst.b, EAX, inst.size) # quotient in eax
        when :mod
          emit_divmod(inst.dst, inst.a, inst.b, EDX, inst.size) # remainder in edx
        when :eq, :ne, :lt, :le, :gt, :ge
          emit_comparison(inst.dst, inst.a, inst.b, SETCC_OPCODES.fetch(inst.op), inst.size)
        when :neg
          load_reg(EAX, inst.a)
          emit(0xF7, 0xD8)                                    # neg eax
          store_reg(EAX, inst.dst)
        when :sext
          emit_sext(inst.dst, inst.a)
        when :sext8
          emit_sext8(inst.dst, inst.a)
        when :string_addr
          emit_string_addr(inst.dst, inst.a)
        when :global_addr
          emit_global_addr(inst.dst, inst.a)
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
        when :object_addr
          emit_object_addr(inst.dst, inst.a)
        when :load
          emit_load(inst.dst, inst.a, inst.size)
        when :store
          emit_store(inst.a, inst.b, inst.size)
        when :ret
          load_reg(EAX, inst.a) unless inst.a.nil?
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
        @relocations << { kind: :call, offset: @code.bytesize, symbol: name }
        emit_bytes([0].pack("l<"))          # linker patches this via R_X86_64_PLT32
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

      # "&x": lea rax, [rbp+disp] computes the absolute address of the operand's
      # slot, which a 64-bit store then parks in the destination slot.
      def emit_addr_of(dst, slot_vreg)
        emit(0x48, 0x8D)                # REX.W lea rax, [rbp+disp]
        emit_bytes(modrm_rbp_disp(EAX, slot_disp(slot_vreg)))
        store_reg(EAX, dst)
      end

      # :object_addr — lea rax, [rbp+disp] loads a stack object's base address
      # (an array's first element) into rax, then a 64-bit store parks it in the
      # destination slot, giving the decayed pointer value.
      def emit_object_addr(dst, object_id)
        emit(0x48, 0x8D)                # REX.W lea rax, [rbp+disp]
        emit_bytes(modrm_rbp_disp(EAX, @object_offsets[object_id]))
        store_reg(EAX, dst)
      end

      # :sext — movsxd rax, dword [rbp+disp] sign-extends the 32-bit value in
      # a's slot to 64 bits in rax; the 64-bit store then writes the widened
      # value so pointer-offset scaling sees a correct (possibly negative) index.
      def emit_sext(dst, src_vreg)
        emit(0x48, 0x63)                # REX.W movsxd rax, r/m32
        emit_bytes(modrm_rbp_disp(EAX, slot_disp(src_vreg)))
        store_reg(EAX, dst)
      end

      # :sext8 — load a's slot, then movsx eax, al sign-extends its low byte to
      # 32 bits (the 32-bit write also zeroing the upper half of rax); the
      # store writes it back. This is the int -> char narrowing: only the low
      # byte survives, re-widened with its sign.
      def emit_sext8(dst, src_vreg)
        load_reg(EAX, src_vreg)         # rax = value
        emit(0x0F, 0xBE, 0xC0)          # movsx eax, al
        store_reg(EAX, dst)
      end

      # "*p" read: load the pointer from its slot into rax, then read through
      # it. An 8-byte load moves a full pointer (mov rax, [rax]); a 4-byte load
      # reads an int (mov eax, [rax]), whose upper bits the store then zeroes;
      # a 1-byte load reads a char and sign-extends it to 32 bits
      # (movsx eax, byte [rax]) so the slot holds a promoted int value.
      def emit_load(dst, ptr_vreg, size)
        load_reg(EAX, ptr_vreg)         # rax = pointer value
        case size
        when 8
          emit(0x48, 0x8B, 0x00)        # mov rax, [rax]
        when 1
          emit(0x0F, 0xBE, 0x00)        # movsx eax, byte [rax]
        else
          emit(0x8B, 0x00)              # mov eax, [rax]
        end
        store_reg(EAX, dst)
      end

      # "*p = v": rax holds the destination address, rcx the value, then rcx is
      # written through the address. An 8-byte store writes a full pointer
      # (mov [rax], rcx); a 4-byte store writes an int (mov [rax], ecx); a
      # 1-byte store writes just the low byte (mov [rax], cl), which is exactly
      # the int -> char truncation a char lvalue needs.
      def emit_store(ptr_vreg, value_vreg, size)
        load_reg(EAX, ptr_vreg)         # rax = destination address
        load_reg(ECX, value_vreg)       # rcx = value
        case size
        when 8
          emit(0x48, 0x89, 0x08)        # mov [rax], rcx
        when 1
          emit(0x88, 0x08)              # mov [rax], cl
        else
          emit(0x89, 0x08)              # mov [rax], ecx
        end
      end

      # A size of 8 compares full 64-bit pointer values (REX.W cmp rax, rcx);
      # otherwise the 32-bit int compare is used. The signed setcc still suits
      # pointer ordering here, since stack addresses stay within the positive
      # half of the 64-bit range.
      def emit_comparison(dst, a, b, setcc_opcode, size = nil)
        load_reg(EAX, a)
        load_reg(ECX, b)
        emit(0x48) if size == 8         # REX.W widens the following cmp
        emit(0x39, 0xC8)                # cmp eax, ecx  (rax, rcx when REX.W)
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

      # A size of 8 prefixes REX.W so the operation runs on the full 64-bit
      # rax/rcx (pointer arithmetic and index scaling); otherwise it stays a
      # 32-bit int operation. The opcode bytes are identical either way.
      def emit_binary(dst, a, b, opcode_bytes, size = nil)
        load_reg(EAX, a)
        load_reg(ECX, b)
        emit(0x48) if size == 8
        emit(*opcode_bytes)
        store_reg(EAX, dst)
      end

      # A size of 8 does a 64-bit signed division (REX.W cqo + REX.W idiv rcx),
      # used for pointer differences; otherwise the 32-bit int division.
      def emit_divmod(dst, a, b, result_reg, size = nil)
        load_reg(EAX, a)
        load_reg(ECX, b)
        if size == 8
          emit(0x48, 0x99)          # cqo: sign-extend rax into rdx:rax
          emit(0x48, 0xF7, 0xF9)    # idiv rcx
        else
          emit(0x99)                # cdq: sign-extend eax into edx:eax
          emit(0xF7, 0xF9)          # idiv ecx
        end
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
