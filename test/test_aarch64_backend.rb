# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Exercises the AArch64 code generator (Rubycc::Backend::AArch64).
#
# No aarch64 execution environment exists on the development host — no qemu-user,
# no cross toolchain, no aarch64-aware objdump — so the generated code cannot be
# run or disassembled by an external oracle. Verification is therefore layered:
#
#   1. Encoding: each instruction's 32-bit word is compared against an expected
#      value assembled here field by field from the instruction's format in the
#      Arm Architecture Reference Manual (ARM DDI 0487, "A64 Base Instruction
#      Descriptions"). The expectations are built from the documented bit
#      positions, never copied from the backend's precomputed opcode constants,
#      so an encoding typo in either place shows up as a mismatch.
#   2. Structure: whole IR::Function bodies are compiled and the shape of the
#      result asserted — prologue/epilogue, branch displacements after
#      backpatching, relocation offsets, instruction alignment.
#   3. Integration: a C source compiled for the aarch64 target is read back with
#      the repository's own ELF reader and its machine and relocation types
#      checked.
#
# Alongside these, the constructs the A2 core deliberately does not lower yet
# (globals, string literals, floating point, structs by value, varargs, indirect
# calls, stack-passed arguments) are asserted to raise rather than to produce
# quietly wrong code.
class TestAArch64Backend < Minitest::Test
  Backend = Rubycc::Backend::AArch64
  IR = Rubycc::IR
  Reader = Rubycc::ObjFile::ELFReader

  # Register numbers the backend's contract fixes: the scratch registers it
  # evaluates one instruction in, and the architectural specials.
  A = 9
  B = 10
  C = 11
  ADDR = 12
  SP = 31
  XZR = 31
  FP = 29
  LR = 30

  # The saved frame record occupies [sp, #0..15]; vreg n's slot follows it.
  SAVE_AREA_SIZE = 16
  def slot(vreg) = SAVE_AREA_SIZE + 8 * vreg

  # ------------------------------------------------------------------------
  # Expected-encoding builders.
  #
  # Each is written from the field layout the ARM ARM gives for that
  # instruction, with the bit ranges named in the comment. `sf` is the operand
  # size field: 0 selects the 32-bit W registers, 1 the 64-bit X registers.
  # ------------------------------------------------------------------------

  # Data-processing (immediate), "Move wide (immediate)":
  #   sf(31) opc(30:29) 100101(28:23) hw(22:21) imm16(20:5) Rd(4:0)
  # opc = 10 is MOVZ (zero the rest of the register), 11 is MOVK (keep it).
  def move_wide(opc, sf, rd, imm16, hw)
    (sf << 31) | (opc << 29) | (0b100101 << 23) | (hw << 21) | (imm16 << 5) | rd
  end

  def movz(sf, rd, imm16, hw) = move_wide(0b10, sf, rd, imm16, hw)
  def movk(sf, rd, imm16, hw) = move_wide(0b11, sf, rd, imm16, hw)

  # Data-processing (register), "Add/subtract (shifted register)":
  #   sf(31) op(30) S(29) 01011(28:24) shift(23:22) 0(21) Rm(20:16)
  #   imm6(15:10) Rn(9:5) Rd(4:0)
  # op = 0 ADD, 1 SUB; S = 1 sets the flags (ADDS/SUBS). shift/imm6 are zero
  # here: a plain register operand, unshifted.
  def addsub_shifted(op, s, sf, rd, rn, rm)
    (sf << 31) | (op << 30) | (s << 29) | (0b01011 << 24) | (rm << 16) | (rn << 5) | rd
  end

  def add_reg(sf, rd, rn, rm)  = addsub_shifted(0, 0, sf, rd, rn, rm)
  def sub_reg(sf, rd, rn, rm)  = addsub_shifted(1, 0, sf, rd, rn, rm)
  def subs_reg(sf, rd, rn, rm) = addsub_shifted(1, 1, sf, rd, rn, rm)

  # Data-processing (register), "Logical (shifted register)":
  #   sf(31) opc(30:29) 01010(28:24) shift(23:22) N(21) Rm(20:16)
  #   imm6(15:10) Rn(9:5) Rd(4:0)
  # opc = 00 AND, 01 ORR, 10 EOR (with N = 0; N = 1 gives the "bic/orn/eon"
  # inverted forms, which are not used here).
  def logical_shifted(opc, sf, rd, rn, rm)
    (sf << 31) | (opc << 29) | (0b01010 << 24) | (rm << 16) | (rn << 5) | rd
  end

  def and_reg(sf, rd, rn, rm) = logical_shifted(0b00, sf, rd, rn, rm)
  def orr_reg(sf, rd, rn, rm) = logical_shifted(0b01, sf, rd, rn, rm)
  def eor_reg(sf, rd, rn, rm) = logical_shifted(0b10, sf, rd, rn, rm)

  # "Data-processing (3 source)":
  #   sf(31) op54(30:29)=00 11011(28:24) op31(23:21)=000 Rm(20:16) o0(15)
  #   Ra(14:10) Rn(9:5) Rd(4:0)
  # o0 = 0 is MADD (Rd = Ra + Rn*Rm), o0 = 1 is MSUB (Rd = Ra - Rn*Rm).
  def madd(sf, rd, rn, rm, ra)
    (sf << 31) | (0b11011 << 24) | (rm << 16) | (ra << 10) | (rn << 5) | rd
  end

  def msub(sf, rd, rn, rm, ra)
    madd(sf, rd, rn, rm, ra) | (1 << 15)
  end

  # "Data-processing (2 source)":
  #   sf(31) 0(30) S(29)=0 11010110(28:21) Rm(20:16) opcode(15:10)
  #   Rn(9:5) Rd(4:0)
  # opcode 000010 UDIV, 000011 SDIV, 001000 LSLV, 001001 LSRV, 001010 ASRV.
  def dp2(opcode, sf, rd, rn, rm)
    (sf << 31) | (0b11010110 << 21) | (rm << 16) | (opcode << 10) | (rn << 5) | rd
  end

  def udiv(sf, rd, rn, rm) = dp2(0b000010, sf, rd, rn, rm)
  def sdiv(sf, rd, rn, rm) = dp2(0b000011, sf, rd, rn, rm)
  def lslv(sf, rd, rn, rm) = dp2(0b001000, sf, rd, rn, rm)
  def lsrv(sf, rd, rn, rm) = dp2(0b001001, sf, rd, rn, rm)
  def asrv(sf, rd, rn, rm) = dp2(0b001010, sf, rd, rn, rm)

  # "Conditional select":
  #   sf(31) op(30) S(29) 11010100(28:21) Rm(20:16) cond(15:12) op2(11:10)
  #   Rn(9:5) Rd(4:0)
  # CSINC is op = 0, op2 = 01: Rd = Rn when cond holds, else Rm + 1. The alias
  # "cset Rd, cond" is CSINC Rd, ZR, ZR, invert(cond).
  def csinc(sf, rd, rn, rm, cond)
    (sf << 31) | (0b11010100 << 21) | (rm << 16) | (cond << 12) | (0b01 << 10) | (rn << 5) | rd
  end

  def cset(sf, rd, cond) = csinc(sf, rd, XZR, XZR, cond ^ 1)

  # "Bitfield": sf(31) opc(30:29) 100110(28:23) N(22) immr(21:16) imms(15:10)
  #   Rn(9:5) Rd(4:0)
  # opc = 00 SBFM (sign-extending), 10 UBFM (zero-extending). N must equal sf.
  def bfm(opc, sf, rd, rn, immr, imms)
    (sf << 31) | (opc << 29) | (0b100110 << 23) | (sf << 22) |
      (immr << 16) | (imms << 10) | (rn << 5) | rd
  end

  # SXTB/SXTH/SXTW Xd, Wn are SBFM Xd, Xn, #0, #{7,15,31}.
  def sxtb(rd, rn) = bfm(0b00, 1, rd, rn, 0, 7)
  def sxth(rd, rn) = bfm(0b00, 1, rd, rn, 0, 15)
  def sxtw(rd, rn) = bfm(0b00, 1, rd, rn, 0, 31)
  # UXTB/UXTH Wd, Wn are UBFM Wd, Wn, #0, #{7,15}; the 32-bit result also
  # zeroes the upper half of the X register.
  def uxtb(rd, rn) = bfm(0b10, 0, rd, rn, 0, 7)
  def uxth(rd, rn) = bfm(0b10, 0, rd, rn, 0, 15)
  # UBFX Xd, Xn, #0, #32 is UBFM Xd, Xn, #0, #31 — the low 32 bits, zeroed above.
  def ubfx_low32(rd, rn) = bfm(0b10, 1, rd, rn, 0, 31)

  # "Load/store register (unsigned immediate)":
  #   size(31:30) 111(29:27) V(26)=0 01(25:24) opc(23:22) imm12(21:10)
  #   Rn(9:5) Rt(4:0)
  # size selects the access width (00 byte, 01 halfword, 10 word, 11
  # doubleword) and imm12 is the offset scaled by that width. opc = 00 stores,
  # 01 loads (zero-extending), and for the byte/halfword widths 10/11 load
  # sign-extending into an X/W register respectively.
  def ldst_uimm(size, opc, rt, rn, byte_offset)
    scaled = byte_offset / (1 << size)
    (size << 30) | (0b111 << 27) | (0b01 << 24) | (opc << 22) |
      (scaled << 10) | (rn << 5) | rt
  end

  def ldr_x(rt, rn, off = 0)  = ldst_uimm(0b11, 0b01, rt, rn, off)
  def str_x(rt, rn, off = 0)  = ldst_uimm(0b11, 0b00, rt, rn, off)
  def ldr_w(rt, rn, off = 0)  = ldst_uimm(0b10, 0b01, rt, rn, off)
  def str_w(rt, rn, off = 0)  = ldst_uimm(0b10, 0b00, rt, rn, off)
  def ldrh(rt, rn, off = 0)   = ldst_uimm(0b01, 0b01, rt, rn, off)
  def ldrsh_w(rt, rn, off = 0) = ldst_uimm(0b01, 0b11, rt, rn, off)
  def strh(rt, rn, off = 0)   = ldst_uimm(0b01, 0b00, rt, rn, off)
  def ldrb(rt, rn, off = 0)   = ldst_uimm(0b00, 0b01, rt, rn, off)
  def ldrsb_w(rt, rn, off = 0) = ldst_uimm(0b00, 0b11, rt, rn, off)
  def strb(rt, rn, off = 0)   = ldst_uimm(0b00, 0b00, rt, rn, off)

  # A vreg slot access: always the 64-bit form, sp-relative.
  def ldr_slot(rt, vreg) = ldr_x(rt, SP, slot(vreg))
  def str_slot(rt, vreg) = str_x(rt, SP, slot(vreg))

  # "Load/store register pair (signed offset)":
  #   opc(31:30) 101(29:27) V(26)=0 010(25:23) L(22) imm7(21:15) Rt2(14:10)
  #   Rn(9:5) Rt(4:0)
  # opc = 10 is the 64-bit variant, whose imm7 is the offset scaled by 8;
  # L = 0 stores (STP), L = 1 loads (LDP).
  def ldst_pair(load, rt, rt2, rn, byte_offset)
    (0b10 << 30) | (0b101 << 27) | (0b010 << 23) | (load << 22) |
      (((byte_offset / 8) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt
  end

  def stp_x(rt, rt2, rn, off) = ldst_pair(0, rt, rt2, rn, off)
  def ldp_x(rt, rt2, rn, off) = ldst_pair(1, rt, rt2, rn, off)

  # "Add/subtract (immediate)":
  #   sf(31) op(30) S(29) 100010(28:23) sh(22) imm12(21:10) Rn(9:5) Rd(4:0)
  # sh = 1 shifts the immediate left by 12. In this encoding a register field
  # of 31 names the stack pointer (not the zero register).
  def addsub_imm(op, sf, rd, rn, imm12, shift12)
    (sf << 31) | (op << 30) | (0b100010 << 23) | ((shift12 ? 1 : 0) << 22) |
      (imm12 << 10) | (rn << 5) | rd
  end

  def add_imm(rd, rn, imm12, shift12: false) = addsub_imm(0, 1, rd, rn, imm12, shift12)
  def sub_imm(rd, rn, imm12, shift12: false) = addsub_imm(1, 1, rd, rn, imm12, shift12)

  # "Unconditional branch (immediate)": op(31) 00101(30:26) imm26(25:0).
  # op = 0 is B, 1 is BL (which also sets X30 to the return address). The
  # immediate is the signed word (4-byte) displacement from the branch itself.
  def b_imm(words)  = (0b000101 << 26) | (words & 0x03FFFFFF)
  def bl_imm(words) = (0b100101 << 26) | (words & 0x03FFFFFF)

  # "Compare and branch (immediate)":
  #   sf(31) 011010(30:25) op(24) imm19(23:5) Rt(4:0)
  # op = 0 is CBZ (branch when Rt is zero); the immediate is again a signed
  # word displacement. sf = 0 tests the 32-bit W view of Rt.
  def cbz_w(rt, words)
    (0b011010 << 25) | ((words & 0x7FFFF) << 5) | rt
  end

  # "Unconditional branch (register)":
  #   1101011(31:25) opc(24:21) op2(20:16)=11111 op3(15:10)=000000 Rn(9:5)
  #   op4(4:0)=00000
  # RET is opc = 0010; "ret" with no operand means Rn = X30.
  def ret_x30
    (0b1101011 << 25) | (0b0010 << 21) | (0b11111 << 16) | (LR << 5)
  end

  # Condition codes (ARM ARM, "Condition codes"): the 4-bit field a CSINC or a
  # conditional branch tests. Only the ones the backend maps IR comparisons to
  # are listed.
  COND_EQ = 0b0000
  COND_NE = 0b0001
  COND_HS = 0b0010
  COND_LO = 0b0011
  COND_HI = 0b1000
  COND_LS = 0b1001
  COND_GE = 0b1010
  COND_LT = 0b1011
  COND_GT = 0b1100
  COND_LE = 0b1101

  # ------------------------------------------------------------------------
  # IR construction and compilation helpers.
  # ------------------------------------------------------------------------

  def inst(op, **fields) = IR::Instruction.new(op, **fields)

  def func(insts, vregs:, params: 0, param_kinds: nil, objects: [], name: "f", linkage: :external)
    IR::Function.new(name, insts, vregs, params, objects, linkage, false,
                     param_kinds || Array.new(params, :gp))
  end

  def compile(fn) = Backend.new.compile(fn)

  # The instruction words of a compiled function.
  def words(fn) = compile(fn).bytes.unpack("L<*")

  # The words after the prologue. The prologue is one or two sp adjustments
  # followed by the frame-record store, so the body starts just past that stp.
  def body(fn)
    all = words(fn)
    all.drop(all.index(stp_x(FP, LR, SP, 0)) + 1)
  end

  # Compiles a single instruction between `vregs` slots and returns the body.
  def body_of(op, vregs: 3, **fields)
    body(func([inst(op, **fields)], vregs: vregs))
  end

  def assert_words(expected, actual, message = nil)
    formatted = ->(list) { list.map { |w| format("%08X", w) } }
    assert_equal formatted.call(expected), formatted.call(actual), message
  end

  # --- prologue / epilogue ------------------------------------------------

  # The prologue lowers sp by the frame size and saves the frame record at
  # [sp, #0]; the epilogue reloads it, raises sp back and returns through x30.
  # The frame is 16 (the saved record) + the vreg slots rounded to 16.
  def test_prologue_and_epilogue_frame_record
    fn = func([inst(:ret, a: 0)], vregs: 3)
    # 3 vregs -> 24 bytes rounded to 32; 16 + 32 = 48.
    assert_words [sub_imm(SP, SP, 48), stp_x(FP, LR, SP, 0),
                  ldr_slot(0, 0), ldp_x(FP, LR, SP, 0), add_imm(SP, SP, 48), ret_x30],
                 words(fn)
  end

  # A void return loads nothing into x0; it is the bare epilogue.
  def test_void_return_emits_only_the_epilogue
    assert_words [ldp_x(FP, LR, SP, 0), add_imm(SP, SP, 32), ret_x30],
                 body(func([inst(:ret)], vregs: 1))
  end

  # Incoming integer arguments are spilled to the slots of vregs 0..n-1, in
  # AAPCS64 order (x0 first), so they read back like any other value.
  def test_parameters_are_spilled_from_the_aapcs64_registers
    fn = func([inst(:ret, a: 0)], vregs: 3, params: 3)
    assert_words [str_slot(0, 0), str_slot(1, 1), str_slot(2, 2)], body(fn).first(3)
  end

  # A frame wider than the 12-bit add/sub immediate is adjusted in two steps:
  # the high part shifted left by 12, then the remaining low part.
  def test_large_frame_is_adjusted_in_two_steps
    # 600 vregs -> 4800 bytes; 16 + 4800 = 4816 = 0x12D0.
    fn = func([inst(:ret)], vregs: 600)
    frame = 4816
    assert_words [sub_imm(SP, SP, frame >> 12, shift12: true),
                  sub_imm(SP, SP, frame & 0xFFF)],
                 words(fn).first(2)
    # And unwound in the same two steps on the way out.
    assert_words [add_imm(SP, SP, frame >> 12, shift12: true),
                  add_imm(SP, SP, frame & 0xFFF), ret_x30],
                 words(fn).last(3)
  end

  # --- immediates ---------------------------------------------------------

  # A 32-bit constant that fits one halfword is a single movz to the W view,
  # which zeroes the upper 32 bits of the register (and so of the slot).
  def test_const_small_int_is_one_movz
    assert_words [movz(0, A, 42, 0), str_slot(A, 0)],
                 body_of(:const, dst: 0, a: 42, size: 4)
  end

  # A negative int is materialized as its 32-bit two's-complement pattern:
  # movz of the low halfword plus movk of the high one.
  def test_const_negative_int_uses_movz_and_movk
    assert_words [movz(0, A, 0xFFFF, 0), movk(0, A, 0xFFFF, 1), str_slot(A, 0)],
                 body_of(:const, dst: 0, a: -1, size: 4)
  end

  # A 64-bit constant needs one movz and a movk per non-zero halfword above it,
  # each naming its halfword position in hw.
  def test_const_long_uses_movz_then_movk_per_halfword
    assert_words [movz(1, A, 0xDEF0, 0), movk(1, A, 0x9ABC, 1),
                  movk(1, A, 0x5678, 2), movk(1, A, 0x1234, 3), str_slot(A, 0)],
                 body_of(:const, dst: 0, a: 0x1234_5678_9ABC_DEF0, size: 8)
  end

  # Zero halfwords are skipped: only the movz and the halfwords that carry bits
  # are emitted.
  def test_const_long_skips_zero_halfwords
    assert_words [movz(1, A, 0, 0), movk(1, A, 1, 2), str_slot(A, 0)],
                 body_of(:const, dst: 0, a: 1 << 32, size: 8)
  end

  # --- arithmetic and logic ------------------------------------------------

  # Each binary op loads its operands into the scratch pair, combines them with
  # the shifted-register form of the right width, and stores the result back.
  def test_int_arithmetic_and_logic_use_the_w_forms
    {
      add: add_reg(0, A, A, B), sub: sub_reg(0, A, A, B),
      and: and_reg(0, A, A, B), or: orr_reg(0, A, A, B), xor: eor_reg(0, A, A, B)
    }.each do |op, expected|
      assert_words [ldr_slot(A, 0), ldr_slot(B, 1), expected, str_slot(A, 2)],
                   body_of(op, dst: 2, a: 0, b: 1, size: 4), "op #{op}"
    end
  end

  # A size-8 (long/pointer) op selects the X form of the same instruction.
  def test_long_arithmetic_and_logic_use_the_x_forms
    {
      add: add_reg(1, A, A, B), sub: sub_reg(1, A, A, B),
      and: and_reg(1, A, A, B), or: orr_reg(1, A, A, B), xor: eor_reg(1, A, A, B)
    }.each do |op, expected|
      assert_words [ldr_slot(A, 0), ldr_slot(B, 1), expected, str_slot(A, 2)],
                   body_of(op, dst: 2, a: 0, b: 1, size: 8), "op #{op}"
    end
  end

  # Multiplication is MADD with the zero register as the addend.
  def test_multiply_is_madd_with_the_zero_register
    assert_words [ldr_slot(A, 0), ldr_slot(B, 1), madd(0, A, A, B, XZR), str_slot(A, 2)],
                 body_of(:mul, dst: 2, a: 0, b: 1, size: 4)
    assert_words [ldr_slot(A, 0), ldr_slot(B, 1), madd(1, A, A, B, XZR), str_slot(A, 2)],
                 body_of(:mul, dst: 2, a: 0, b: 1, size: 8)
  end

  # Negation is a subtraction from the zero register.
  def test_negate_is_subtraction_from_the_zero_register
    assert_words [ldr_slot(A, 0), sub_reg(0, A, XZR, A), str_slot(A, 1)],
                 body_of(:neg, dst: 1, a: 0, size: 4)
  end

  # Division is a single SDIV/UDIV into the extra scratch register, which is
  # then stored to the destination.
  def test_division_is_a_single_divide
    assert_words [ldr_slot(A, 0), ldr_slot(B, 1), sdiv(0, C, A, B), str_slot(C, 2)],
                 body_of(:div, dst: 2, a: 0, b: 1, size: 4)
    assert_words [ldr_slot(A, 0), ldr_slot(B, 1), udiv(1, C, A, B), str_slot(C, 2)],
                 body_of(:udiv, dst: 2, a: 0, b: 1, size: 8)
  end

  # A remainder has no instruction of its own: it is the quotient multiplied
  # back out and subtracted, "a - (a/b)*b", which is exactly MSUB's
  # Rd = Ra - Rn*Rm with Ra the dividend, Rn the quotient and Rm the divisor.
  def test_remainder_is_divide_then_msub
    assert_words [ldr_slot(A, 0), ldr_slot(B, 1),
                  sdiv(0, C, A, B), msub(0, A, C, B, A), str_slot(A, 2)],
                 body_of(:mod, dst: 2, a: 0, b: 1, size: 4)
    assert_words [ldr_slot(A, 0), ldr_slot(B, 1),
                  udiv(1, C, A, B), msub(1, A, C, B, A), str_slot(A, 2)],
                 body_of(:umod, dst: 2, a: 0, b: 1, size: 8)
  end

  # The three C shifts map to the three variable-shift instructions; the shift
  # amount comes from a register, as the operand may be any expression.
  def test_shifts_use_the_variable_shift_instructions
    { shl: lslv(0, A, A, B), shr: lsrv(0, A, A, B), sar: asrv(0, A, A, B) }.each do |op, expected|
      assert_words [ldr_slot(A, 0), ldr_slot(B, 1), expected, str_slot(A, 2)],
                   body_of(op, dst: 2, a: 0, b: 1, size: 4), "op #{op}"
    end
    assert_words [ldr_slot(A, 0), ldr_slot(B, 1), asrv(1, A, A, B), str_slot(A, 2)],
                 body_of(:sar, dst: 2, a: 0, b: 1, size: 8)
  end

  # --- comparisons ---------------------------------------------------------

  # A comparison is SUBS into the zero register (the "cmp" alias) followed by
  # CSET, which materializes the 0/1 an int result needs.
  def test_comparison_is_cmp_then_cset
    assert_words [ldr_slot(A, 0), ldr_slot(B, 1), subs_reg(0, XZR, A, B),
                  cset(0, A, COND_LT), str_slot(A, 2)],
                 body_of(:lt, dst: 2, a: 0, b: 1, size: 4)
  end

  # Every IR comparison maps to the condition its C semantics call for: the
  # signed relations to the N/V-based codes and the unsigned ones to the
  # carry-based codes, which is what an unsigned or pointer compare needs.
  def test_every_comparison_selects_its_condition_code
    {
      eq: COND_EQ, ne: COND_NE,
      lt: COND_LT, le: COND_LE, gt: COND_GT, ge: COND_GE,
      ult: COND_LO, ule: COND_LS, ugt: COND_HI, uge: COND_HS
    }.each do |op, cond|
      assert_words [cset(0, A, cond)], [body_of(op, dst: 2, a: 0, b: 1, size: 4)[3]], "op #{op}"
    end
  end

  # A pointer or long comparison sets the flags from the full 64-bit values;
  # the 0/1 result is still an int, so the CSET stays 32-bit.
  def test_long_comparison_compares_the_x_registers
    body = body_of(:ult, dst: 2, a: 0, b: 1, size: 8)
    assert_words [subs_reg(1, XZR, A, B), cset(0, A, COND_LO)], body[2, 2]
  end

  # --- extensions ----------------------------------------------------------

  # Sign extension widens to the full 64-bit register, so a later pointer-offset
  # scaling sees a correctly negative value.
  def test_sign_extension_uses_the_sbfm_aliases
    { 1 => sxtb(A, A), 2 => sxth(A, A), 4 => sxtw(A, A) }.each do |size, expected|
      assert_words [ldr_slot(A, 0), expected, str_slot(A, 1)],
                   body_of(:sext, dst: 1, a: 0, size: size), "size #{size}"
    end
  end

  # Zero extension of a byte/halfword is a 32-bit UBFM, whose W-register write
  # clears the upper half for free; the 32-bit case is a 64-bit UBFM of the low
  # word.
  def test_zero_extension_uses_the_ubfm_aliases
    { 1 => uxtb(A, A), 2 => uxth(A, A), 4 => ubfx_low32(A, A) }.each do |size, expected|
      assert_words [ldr_slot(A, 0), expected, str_slot(A, 1)],
                   body_of(:zext, dst: 1, a: 0, size: size), "size #{size}"
    end
  end

  # --- memory --------------------------------------------------------------

  # A load reads through the pointer with the width the access asks for; the
  # narrow signed forms sign-extend and the unsigned ones zero-extend, which is
  # the whole difference between :load and :uload.
  def test_loads_select_the_width_and_signedness
    {
      [1, :load] => ldrsb_w(A, A), [1, :uload] => ldrb(A, A),
      [2, :load] => ldrsh_w(A, A), [2, :uload] => ldrh(A, A),
      [4, :load] => ldr_w(A, A), [4, :uload] => ldr_w(A, A),
      [8, :load] => ldr_x(A, A), [8, :uload] => ldr_x(A, A)
    }.each do |(size, op), expected|
      assert_words [ldr_slot(A, 0), expected, str_slot(A, 1)],
                   body_of(op, dst: 1, a: 0, size: size), "#{op} size #{size}"
    end
  end

  # A store writes the value's low bytes through the pointer; the narrow forms
  # are exactly the truncation a narrow lvalue needs. The address is the first
  # operand and the value the second.
  def test_stores_select_the_width
    { 1 => strb(B, A), 2 => strh(B, A), 4 => str_w(B, A), 8 => str_x(B, A) }.each do |size, expected|
      assert_words [ldr_slot(A, 0), ldr_slot(B, 1), expected],
                   body_of(:store, a: 0, b: 1, size: size), "size #{size}"
    end
  end

  # Taking a local's address is an add of its frame offset to sp.
  def test_address_of_a_slot_is_an_add_immediate
    assert_words [add_imm(A, SP, slot(1)), str_slot(A, 0)],
                 body_of(:addr_of, dst: 0, a: 1)
  end

  # A stack object (an array) sits above the vreg slots, and its base address
  # is formed the same way.
  def test_object_address_is_an_add_immediate_above_the_slots
    fn = func([inst(:object_addr, dst: 0, a: 0)], vregs: 2, objects: [64])
    # 2 vregs -> 16 bytes; the object base is 16 (record) + 16 (slots) = 32.
    assert_words [add_imm(A, SP, 32), str_slot(A, 0)], body(fn)
  end

  # An offset past the 12-bit immediate is composed in two adds — the high part
  # shifted by 12, then the low part — rather than silently truncated.
  def test_large_object_offset_is_composed_from_two_adds
    fn = func([inst(:object_addr, dst: 0, a: 1)], vregs: 2, objects: [8192, 8])
    base = 32 + 8192
    assert_words [add_imm(A, SP, base >> 12, shift12: true), add_imm(A, A, base & 0xFFF),
                  str_slot(A, 0)],
                 body(fn)
  end

  # A slot beyond the reach of the scaled load/store immediate (4095 * 8) is
  # addressed through a composed address in the dedicated address scratch, so a
  # very wide frame stays correct instead of wrapping.
  def test_slot_beyond_the_scaled_immediate_goes_through_a_composed_address
    far = 4200 # slot offset 16 + 8*4200 = 33616 > 4095*8
    fn = func([inst(:copy, dst: far, a: 0)], vregs: far + 1)
    offset = slot(far)
    assert_words [ldr_slot(A, 0),
                  add_imm(ADDR, SP, offset >> 12, shift12: true),
                  add_imm(ADDR, ADDR, offset & 0xFFF),
                  str_x(A, ADDR, 0)],
                 body(fn)
  end

  # --- control flow --------------------------------------------------------

  # A forward branch is patched with the word distance from the branch to its
  # label; a label itself emits nothing.
  def test_forward_branch_displacement_is_a_word_count
    fn = func([inst(:jump, a: 1), inst(:const, dst: 0, a: 7, size: 4), inst(:label, a: 1),
               inst(:ret)], vregs: 1)
    body = body(fn)
    # b ; movz ; str ; ldp ; add sp ; ret — the label is 3 words past the b.
    assert_words [b_imm(3)], [body[0]]
    assert_equal ret_x30, body.last
  end

  # A backward branch (the loop edge) gets a negative displacement.
  def test_backward_branch_displacement_is_negative
    fn = func([inst(:label, a: 1), inst(:const, dst: 0, a: 7, size: 4), inst(:jump, a: 1),
               inst(:ret)], vregs: 1)
    body = body(fn)
    # movz ; str ; b — the label is 2 words back from the b.
    assert_words [b_imm(-2)], [body[2]]
  end

  # A conditional branch tests the 32-bit view of the condition value and
  # carries its displacement in the 19-bit imm19 field, which sits five bits up.
  def test_conditional_branch_tests_the_w_view
    fn = func([inst(:jump_if_zero, a: 0, b: 1), inst(:const, dst: 0, a: 7, size: 4),
               inst(:label, a: 1), inst(:ret)], vregs: 1)
    body = body(fn)
    assert_words [ldr_slot(A, 0), cbz_w(A, 3)], body.first(2)
  end

  # A label that no instruction defines is a generator bug, not something to
  # emit a zero displacement for.
  def test_unresolved_label_is_rejected
    fn = func([inst(:jump, a: 9), inst(:ret)], vregs: 1)
    error = assert_raises(RuntimeError) { compile(fn) }
    assert_match(/unresolved label 9/, error.message)
  end

  # --- calls ---------------------------------------------------------------

  # A direct call loads its arguments into x0.. in order, branches with a BL
  # whose immediate is left for the linker, and takes the result from x0.
  def test_direct_call_places_arguments_and_takes_the_result_from_x0
    args = [[0, :gp], [1, :gp]]
    fn = func([inst(:call, dst: 2, a: "g", b: args)], vregs: 3)
    assert_words [ldr_slot(0, 0), ldr_slot(1, 1), bl_imm(0), str_slot(0, 2)], body(fn)
  end

  # The call site is recorded as a :call relocation at the BL's own offset, so
  # the object writer can turn it into an R_AARCH64_CALL26 against the callee.
  def test_direct_call_records_a_relocation_at_the_branch
    fn = func([inst(:call, dst: 1, a: "g", b: [[0, :gp]])], vregs: 2)
    result = compile(fn)
    # sub sp ; stp ; ldr x0 ; bl -> the branch is the fourth word.
    assert_equal [{ kind: :call, offset: 12, symbol: "g" }], result.relocations
    assert_equal bl_imm(0), result.bytes.unpack("L<*")[3]
  end

  # A call with no result stores nothing after the branch.
  def test_void_call_stores_no_result
    fn = func([inst(:call, dst: nil, a: "g", b: [])], vregs: 1)
    assert_words [bl_imm(0)], body(fn)
  end

  # Eight arguments fill x0..x7; each load names its own destination and reads
  # sp, so placing a later argument cannot disturb an earlier one.
  def test_eight_arguments_fill_the_argument_registers
    args = (0..7).map { |i| [i, :gp] }
    fn = func([inst(:call, dst: nil, a: "g", b: args)], vregs: 8)
    assert_words (0..7).map { |i| ldr_slot(i, i) } + [bl_imm(0)], body(fn)
  end

  # --- whole functions -----------------------------------------------------

  # A complete function — parameters, arithmetic, a compare, a conditional
  # branch, a call and two returns — compiles to a well-formed instruction
  # stream: a whole number of 4-byte instructions, one symbol covering it all,
  # and every branch resolved within it.
  def test_whole_function_is_well_formed
    insts = [
      inst(:add, dst: 2, a: 0, b: 1, size: 4),
      inst(:const, dst: 3, a: 0, size: 4),
      inst(:gt, dst: 4, a: 2, b: 3, size: 4),
      inst(:jump_if_zero, a: 4, b: 1),
      inst(:call, dst: 5, a: "g", b: [[2, :gp]]),
      inst(:ret, a: 5),
      inst(:label, a: 1),
      inst(:ret, a: 3)
    ]
    fn = func(insts, vregs: 6, params: 2)
    result = compile(fn)

    assert_equal 0, result.bytes.bytesize % 4, "every instruction is four bytes"
    assert_equal [{ name: "f", offset: 0, size: result.bytes.bytesize }], result.symbols
    assert_equal 1, result.relocations.size

    code = result.bytes.unpack("L<*")
    # The cbz's target, decoded back out of imm19 (a signed 19-bit field),
    # lands on the second epilogue: the return value's load followed by the
    # three-word epilogue, i.e. four words from the end.
    cbz_index = code.index { |w| (w >> 24) == 0b00110100 }
    imm19 = (code[cbz_index] >> 5) & 0x7FFFF
    imm19 -= (1 << 19) if imm19 >= (1 << 18)
    assert_equal code.size - 4, cbz_index + imm19
    assert_equal ldr_slot(0, 3), code[code.size - 4]
    assert_equal ret_x30, code.last
  end

  # Two returns produce two epilogues, each restoring the frame record and
  # unwinding sp by the same amount.
  def test_every_return_emits_a_full_epilogue
    fn = func([inst(:ret, a: 0), inst(:ret, a: 0)], vregs: 1)
    assert_equal 2, words(fn).count(ret_x30)
    assert_equal 2, words(fn).count(ldp_x(FP, LR, SP, 0))
  end

  # --- refusals ------------------------------------------------------------

  # The IR ops that belong to A3/A4 are refused by name rather than lowered to
  # something plausible-looking.
  def test_later_milestone_ops_are_refused
    {
      inst(:global_addr, dst: 0, a: "g") => /global-variable references/,
      inst(:string_addr, dst: 0, a: 0) => /string-literal references/,
      inst(:got_addr, dst: 0, a: "g") => /PIC\/GOT references/,
      inst(:func_addr, dst: 0, a: "g") => /function-address values/,
      inst(:call_indirect, dst: 0, a: 1, b: []) => /indirect calls/,
      inst(:memcpy, a: 0, b: 1, size: 16) => /struct copies/,
      inst(:va_start, a: 0, b: 0) => /variadic functions/,
      inst(:alloca, dst: 0, a: 1) => /alloca/,
      inst(:mulhi, dst: 0, a: 0, b: 1, size: 8) => /128-bit multiply/,
      inst(:bit_scan, dst: 0, a: 1, b: :forward, size: 4) => /bit-scan builtins/,
      inst(:fadd, dst: 0, a: 1, b: 2, size: 8) => /floating-point arithmetic/,
      inst(:itof, dst: 0, a: 1, b: [4, true], size: 8) => /floating-point arithmetic/
    }.each do |instruction, pattern|
      error = assert_raises(Rubycc::Backend::UnsupportedError, instruction.op.to_s) do
        compile(func([instruction], vregs: 4))
      end
      assert_match pattern, error.message
    end
  end

  # An argument or parameter the IR has classified onto the stack, or into a
  # vector register, is refused: its placement is not something this core can
  # infer, so guessing would miscompile silently.
  def test_stack_and_floating_argument_placement_is_refused
    mem_call = func([inst(:call, dst: nil, a: "g", b: [[0, :mem]])], vregs: 1)
    assert_match(/stack-passed call arguments/,
                 assert_raises(Rubycc::Backend::UnsupportedError) { compile(mem_call) }.message)

    sse_call = func([inst(:call, dst: nil, a: "g", b: [[0, :sse8]])], vregs: 1)
    assert_match(/floating-point call arguments/,
                 assert_raises(Rubycc::Backend::UnsupportedError) { compile(sse_call) }.message)

    mem_param = func([inst(:ret)], vregs: 1, params: 1, param_kinds: [:mem])
    assert_match(/stack-passed parameters/,
                 assert_raises(Rubycc::Backend::UnsupportedError) { compile(mem_param) }.message)

    sse_param = func([inst(:ret)], vregs: 1, params: 1, param_kinds: [:sse4])
    assert_match(/floating-point parameters/,
                 assert_raises(Rubycc::Backend::UnsupportedError) { compile(sse_param) }.message)
  end

  # A floating or aggregate result — of a call or of the function itself — is
  # refused for the same reason: it arrives somewhere this core does not read.
  def test_floating_and_aggregate_results_are_refused
    float_ret = func([inst(:ret, a: 0, size: 8)], vregs: 1)
    assert_match(/floating-point return values/,
                 assert_raises(Rubycc::Backend::UnsupportedError) { compile(float_ret) }.message)

    struct_ret = func([inst(:ret, a: 0, size: [:gp, :gp])], vregs: 1)
    assert_match(/aggregate \(struct\) return values/,
                 assert_raises(Rubycc::Backend::UnsupportedError) { compile(struct_ret) }.message)

    float_call = func([inst(:call, dst: 0, a: "g", b: [], size: [nil, :sse8])], vregs: 1)
    assert_match(/floating-point return values/,
                 assert_raises(Rubycc::Backend::UnsupportedError) { compile(float_call) }.message)

    struct_call = func([inst(:call, dst: nil, a: "g", b: [], size: [nil, [1, [:gp]]])], vregs: 2)
    assert_match(/aggregate \(struct\) return values/,
                 assert_raises(Rubycc::Backend::UnsupportedError) { compile(struct_call) }.message)
  end

  # The same refusals seen from the front of the compiler: valid C that uses an
  # A3/A4 feature stops with a clear error instead of producing an object.
  def test_unsupported_c_constructs_are_refused_end_to_end
    {
      "int g; int f(void){ return g; }" => /global-variable references/,
      "char *f(void){ return \"hi\"; }" => /string-literal references/,
      "double f(double a){ return a * 2; }" => /floating-point/,
      "struct S { int a[8]; }; void f(struct S *a, struct S *b){ *a = *b; }" => /struct copies/,
      "int f(int (*p)(int)){ return p(1); }" => /indirect calls/,
      "int g(int,int,int,int,int,int,int); int f(void){ return g(1,2,3,4,5,6,7); }" =>
        /stack-passed call arguments/,
      "void *f(int n){ return __builtin_alloca(n); }" => /alloca/
    }.each do |source, pattern|
      error = assert_raises(Rubycc::Backend::UnsupportedError, source) { compile_c(source) }
      assert_match pattern, error.message, source
    end
  end

  # --- object-file integration --------------------------------------------

  # A C source compiled for aarch64 produces an EM_AARCH64 relocatable whose
  # .text holds whole instruction words and whose call sites are recorded as
  # R_AARCH64_CALL26 against the callee.
  def test_compiled_object_is_aarch64_with_call26_relocations
    obj = Reader.read(compile_c("int g(int); int f(int x){ return g(x) + 1; }"))

    assert obj.relocatable?
    assert_equal Reader::EM_AARCH64, obj.machine
    assert_equal 0, obj.section(".text").data.bytesize % 4

    relocations = obj.relocations_for(".text")
    assert_equal 1, relocations.size
    reloc = relocations.first
    assert_equal 283, reloc.type
    assert_equal :R_AARCH64_CALL26, reloc.type_name
    assert_equal "g", reloc.symbol.name
    # A plain "bl sym" names its target with no displacement, so the addend is 0
    # (unlike x86_64's call rel32, whose field is biased by -4).
    assert_equal 0, reloc.addend
    # The relocation addresses the BL itself, which must be a whole word in.
    assert_equal 0, reloc.offset % 4
    assert_equal bl_imm(0), obj.section(".text").data.unpack("L<*")[reloc.offset / 4]
  end

  # Functions are 16-byte aligned in .text, and the gap between them is filled
  # with the aarch64 NOP word rather than x86's 0x90 byte.
  def test_functions_are_padded_with_the_aarch64_nop
    obj = Reader.read(compile_c("int a(int x){ return x; } int b(int x){ return x + 1; }"))
    text = obj.section(".text").data
    second = obj.symbol("b").value

    assert_equal 0, second % 16, "each function starts 16-byte aligned"
    first_end = obj.symbol("a").value + obj.symbol("a").size
    padding = text.byteslice(first_end, second - first_end)
    refute_empty padding, "this pair needs a gap for the test to mean anything"
    assert_equal [0xD503201F] * (padding.bytesize / 4), padding.unpack("L<*"),
                 "the gap is filled with NOP (ARM ARM: hint #0)"
  end

  private

  def compile_c(source)
    Rubycc::Compiler.new.compile(source, filename: "u.c", target: "aarch64")
  end
end
