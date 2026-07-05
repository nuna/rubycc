# frozen_string_literal: true

require_relative "../ir/ir"

module Rubycc
  module Backend
    # x86_64 code generator using a spill-everything strategy: every virtual
    # register lives in its own stack slot at [rbp - 8*(n+1)], and each IR
    # instruction loads its operands into eax/ecx, computes, and stores the
    # result back. All arithmetic is 32-bit, which reproduces C `int`
    # wrap-around semantics for free.
    #
    # System V AMD64: the integer return value is passed in eax.
    class X86_64
      # Result of compiling one function: `bytes` is the machine code (an
      # ASCII-8BIT String), `symbols` is an array of
      # { name:, offset:, size: } describing the emitted function symbols.
      Result = Data.define(:bytes, :symbols)

      # Register numbers (low 3 bits of the ModR/M reg field).
      EAX = 0
      ECX = 1
      EDX = 2

      def compile(ir_func)
        @code = +"".b
        emit_prologue(ir_func.vreg_count)
        ir_func.insts.each { |inst| emit_instruction(inst) }

        Result.new(
          bytes: @code,
          symbols: [{ name: ir_func.name, offset: 0, size: @code.bytesize }]
        )
      end

      private

      def emit_prologue(vreg_count)
        frame_size = align16(vreg_count * 8)
        emit(0x55)                          # push rbp
        emit(0x48, 0x89, 0xE5)              # mov rbp, rsp
        emit(0x48, 0x81, 0xEC)              # sub rsp, imm32
        emit_bytes([frame_size].pack("L<"))
      end

      def emit_instruction(inst)
        case inst.op
        when :const
          emit_const(inst.dst, inst.a)
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
        when :neg
          load_reg(EAX, inst.a)
          emit(0xF7, 0xD8)                                    # neg eax
          store_reg(EAX, inst.dst)
        when :ret
          load_reg(EAX, inst.a)
          emit(0xC9)                                          # leave
          emit(0xC3)                                          # ret
        else
          raise "unsupported IR op: #{inst.op}"
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

      # mov <reg>, [rbp + disp]
      def load_reg(reg, vreg)
        emit(0x8B)
        emit_bytes(modrm_rbp_disp(reg, slot_disp(vreg)))
      end

      # mov [rbp + disp], <reg>
      def store_reg(reg, vreg)
        emit(0x89)
        emit_bytes(modrm_rbp_disp(reg, slot_disp(vreg)))
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
