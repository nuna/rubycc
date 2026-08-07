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
# Alongside these, the constructs the backend deliberately does not lower yet
# (structs by value, varargs) are asserted to raise rather than to produce
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

  # The outgoing argument area sits at the bottom of the frame, the saved record
  # just above it, and vreg n's slot above that. A test whose function makes a
  # call with stack arguments sets @outgoing to the area's size; every other one
  # leaves it nil, which is the ordinary zero-width case.
  SAVE_AREA_SIZE = 16
  def outgoing = @outgoing || 0
  def slot(vreg) = outgoing + SAVE_AREA_SIZE + 8 * vreg

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

  # UMULH Xd, Xn, Xm is the same "data-processing (3 source)" format with
  # op31(23:21) = 110 rather than 000 and Ra(14:10) fixed to xzr (31); it has
  # no sf = 0 form, so only the 64-bit encoding exists.
  def umulh(rd, rn, rm)
    (1 << 31) | (0b11011 << 24) | (0b110 << 21) | (rm << 16) | (0b11111 << 10) | (rn << 5) | rd
  end

  def rbit(sf, rd, rn)
    (sf == 1 ? 0xDAC00000 : 0x5AC00000) | (rn << 5) | rd
  end

  def clz(sf, rd, rn)
    (sf == 1 ? 0xDAC01000 : 0x5AC01000) | (rn << 5) | rd
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

  # The flag-setting subtract (S = 1), which is what lets a loop counter be
  # tested by the branch that follows it.
  def subs_imm(rd, rn, imm12) = addsub_imm(1, 1, rd, rn, imm12, false) | (1 << 29)

  # "Conditional branch (immediate)":
  #   0101010(31:25) o1(24)=0 imm19(23:5) o0(4)=0 cond(3:0)
  # The immediate is the signed word displacement from the branch itself.
  def b_cond(cond, words)
    (0b0101010 << 25) | ((words & 0x7FFFF) << 5) | cond
  end

  # "PC-rel. addressing", the ADRP form:
  #   op(31) immlo(30:29) 10000(28:24) immhi(23:5) Rd(4:0)
  # op = 1 selects ADRP, which forms the address of the 4 KiB page the target
  # lies in: the 21-bit immediate (immhi:immlo) is a page count relative to the
  # page of the instruction itself, and the low 12 bits of the result are zero.
  # Both immediate fields are left zero here because the linker fills them in
  # through R_AARCH64_ADR_PREL_PG_HI21 / R_AARCH64_ADR_GOT_PAGE.
  def adrp(rd, pages = 0)
    immlo = pages & 0b11
    immhi = (pages >> 2) & 0x7FFFF
    (1 << 31) | (immlo << 29) | (0b10000 << 24) | (immhi << 5) | rd
  end

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

  # "Unconditional branch (register)" again, this time BLR (opc = 0001), which
  # branches to Rn and leaves the return address in X30 — the register-operand
  # counterpart of BL.
  def blr(rn)
    (0b1101011 << 25) | (0b0001 << 21) | (0b11111 << 16) | (rn << 5)
  end

  # ------------------------------------------------------------------------
  # Floating-point expected-encoding builders.
  #
  # `ptype` is the two-bit type field every floating instruction carries: 00
  # selects the single-precision (S register) form, 01 the double-precision (D)
  # one. It is derived here from the IR operand size so the tests read in the
  # same terms the backend does.
  # ------------------------------------------------------------------------

  def ptype(size) = size == 8 ? 0b01 : 0b00

  # "Floating-point data-processing (2 source)":
  #   M(31)=0 S(30)=0 0(29) 11110(28:24) ptype(23:22) 1(21) Rm(20:16)
  #   opcode(15:12) 10(11:10) Rn(9:5) Rd(4:0)
  # opcode = 0000 FMUL, 0001 FDIV, 0010 FADD, 0011 FSUB.
  def fp_dp2(opcode, size, rd, rn, rm)
    (0b11110 << 24) | (ptype(size) << 22) | (1 << 21) | (rm << 16) |
      (opcode << 12) | (0b10 << 10) | (rn << 5) | rd
  end

  def fmul(size, rd, rn, rm) = fp_dp2(0b0000, size, rd, rn, rm)
  def fdiv(size, rd, rn, rm) = fp_dp2(0b0001, size, rd, rn, rm)
  def fadd(size, rd, rn, rm) = fp_dp2(0b0010, size, rd, rn, rm)
  def fsub(size, rd, rn, rm) = fp_dp2(0b0011, size, rd, rn, rm)

  # "Floating-point compare":
  #   M(31)=0 S(30)=0 0(29) 11110(28:24) ptype(23:22) 1(21) Rm(20:16)
  #   op(15:14)=00 1000(13:10) Rn(9:5) opcode2(4:0)
  # opcode2 = 00000 is FCMP against Rm; the result goes to NZCV, so the
  # instruction names no destination register.
  def fcmp(size, rn, rm)
    (0b11110 << 24) | (ptype(size) << 22) | (1 << 21) | (rm << 16) |
      (0b1000 << 10) | (rn << 5)
  end

  # "Floating-point data-processing (1 source)", the FCVT (precision change)
  # form:
  #   M(31)=0 S(30)=0 0(29) 11110(28:24) ptype(23:22) 1(21) opcode(20:15)
  #   10000(14:10) Rn(9:5) Rd(4:0)
  # opcode = 0001xx, where the low two bits are the *destination* type while
  # ptype names the source: 000101 converts to double, 000100 to single.
  def fcvt(from_size, rd, rn)
    opcode = from_size == 8 ? 0b000100 : 0b000101
    (0b11110 << 24) | (ptype(from_size) << 22) | (1 << 21) | (opcode << 15) |
      (0b10000 << 10) | (rn << 5) | rd
  end

  # "Conversion between floating-point and integer":
  #   sf(31) 0(30) S(29)=0 11110(28:24) ptype(23:22) 1(21) rmode(20:19)
  #   opcode(18:16) 000000(15:10) Rn(9:5) Rd(4:0)
  # rmode 00 with opcode 010/011 is SCVTF/UCVTF (integer -> floating, rounding
  # to nearest); rmode 11 with opcode 000/001 is FCVTZS/FCVTZU (floating ->
  # integer, rounding toward zero, which is the C cast's rule). sf selects the
  # X (1) or W (0) view of the integer side.
  def fp_int_cvt(sf, size, rmode, opcode, rd, rn)
    (sf << 31) | (0b11110 << 24) | (ptype(size) << 22) | (1 << 21) |
      (rmode << 19) | (opcode << 16) | (rn << 5) | rd
  end

  def scvtf(sf, size, rd, rn)  = fp_int_cvt(sf, size, 0b00, 0b010, rd, rn)
  def ucvtf(sf, size, rd, rn)  = fp_int_cvt(sf, size, 0b00, 0b011, rd, rn)
  def fcvtzs(sf, size, rd, rn) = fp_int_cvt(sf, size, 0b11, 0b000, rd, rn)
  def fcvtzu(sf, size, rd, rn) = fp_int_cvt(sf, size, 0b11, 0b001, rd, rn)

  # "Load/store register (unsigned immediate)" with V(26) = 1, which selects the
  # vector register file. The size field follows the access width — 10 for a
  # 32-bit S register, 11 for a 64-bit D — and scales imm12 by it, so a floating
  # slot access reaches only as far as its own width allows.
  def fp_ldst_uimm(size_field, opc, rt, rn, byte_offset)
    scaled = byte_offset / (1 << size_field)
    (size_field << 30) | (0b111 << 27) | (1 << 26) | (0b01 << 24) | (opc << 22) |
      (scaled << 10) | (rn << 5) | rt
  end

  def ldr_s(rt, rn, off = 0) = fp_ldst_uimm(0b10, 0b01, rt, rn, off)
  def str_s(rt, rn, off = 0) = fp_ldst_uimm(0b10, 0b00, rt, rn, off)
  def ldr_d(rt, rn, off = 0) = fp_ldst_uimm(0b11, 0b01, rt, rn, off)
  def str_d(rt, rn, off = 0) = fp_ldst_uimm(0b11, 0b00, rt, rn, off)

  # A floating vreg slot access, at the value's own width (see the backend's
  # #load_fp for why a float is not moved 64 bits at a time).
  def ldr_fp_slot(rt, vreg, size)
    size == 8 ? ldr_d(rt, SP, slot(vreg)) : ldr_s(rt, SP, slot(vreg))
  end

  def str_fp_slot(rt, vreg, size)
    size == 8 ? str_d(rt, SP, slot(vreg)) : str_s(rt, SP, slot(vreg))
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
  COND_MI = 0b0100

  # The vector scratch pair the backend evaluates one floating instruction in,
  # clear of the v0..v7 argument registers and of the callee-saved v8..v15.
  FA = 16
  FB = 17

  # ------------------------------------------------------------------------
  # IR construction and compilation helpers.
  # ------------------------------------------------------------------------

  def inst(op, **fields) = IR::Instruction.new(op, **fields)

  def func(insts, vregs:, params: 0, param_kinds: nil, objects: [], name: "f", linkage: :external,
           variadic: false)
    IR::Function.new(name, insts, vregs, params, objects, linkage, variadic,
                     param_kinds || Array.new(params, :gp))
  end

  def compile(fn) = Backend.new.compile(fn)

  # One piece of an aggregate as the generator hands it over: the byte offset it
  # is read from, the width of that access and the kind of register it rides.
  def piece(offset, size, kind) = IR::AbiPiece.new(offset: offset, size: size, kind: kind)

  # The instruction words of a compiled function.
  def words(fn) = compile(fn).bytes.unpack("L<*")

  # The words after the prologue. The prologue is one or two sp adjustments
  # followed by the frame-record store, so the body starts just past that stp.
  def body(fn)
    all = words(fn)
    all.drop(all.index(stp_x(FP, LR, SP, outgoing)) + 1)
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

  # :mulhi — the unsigned high 64 bits of a 64x64 product — is a single UMULH,
  # regardless of the IR size the instruction carries (there is no narrower
  # form to pick between).
  def test_mulhi_is_umulh
    assert_words [ldr_slot(A, 0), ldr_slot(B, 1), umulh(A, A, B), str_slot(A, 2)],
                 body_of(:mulhi, dst: 2, a: 0, b: 1, size: 8)
  end

  def test_bit_scan_uses_clz_and_rbit_for_both_widths
    assert_words [ldr_slot(A, 0), rbit(0, A, A), clz(0, A, A), str_slot(A, 2)],
                 body_of(:bit_scan, dst: 2, a: 0, b: :forward, size: 4)
    assert_words [ldr_slot(A, 0), clz(0, A, A), str_slot(A, 2)],
                 body_of(:bit_scan, dst: 2, a: 0, b: :reverse, size: 4)
    assert_words [ldr_slot(A, 0), rbit(1, A, A), clz(1, A, A), str_slot(A, 2)],
                 body_of(:bit_scan, dst: 2, a: 0, b: :forward, size: 8)
    assert_words [ldr_slot(A, 0), clz(1, A, A), str_slot(A, 2)],
                 body_of(:bit_scan, dst: 2, a: 0, b: :reverse, size: 8)
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

  # An indirect call places its arguments first and loads the callee's address
  # afterwards, into the A scratch — which is not an argument register, so the
  # target can never be one of the values just placed — then branches with BLR.
  def test_indirect_call_branches_through_a_scratch_register
    args = [[1, :gp], [2, :gp]]
    fn = func([inst(:call_indirect, dst: 3, a: 0, b: args)], vregs: 4)
    assert_words [ldr_slot(0, 1), ldr_slot(1, 2), ldr_slot(A, 0), blr(A), str_slot(0, 3)],
                 body(fn)
  end

  # BLR needs no relocation: unlike BL, its target is an ordinary run-time value
  # rather than a symbol the linker resolves.
  def test_indirect_call_records_no_relocation
    fn = func([inst(:call_indirect, dst: nil, a: 0, b: [])], vregs: 1)
    assert_empty compile(fn).relocations
  end

  # --- floating point ------------------------------------------------------

  # Each floating binary op loads its operands into the vector scratch pair at
  # the IR's operand width, combines them with the two-source form of that
  # width, and stores the result back — the floating mirror of the integer path.
  def test_floating_arithmetic_selects_the_single_and_double_forms
    { fadd: method(:fadd), fsub: method(:fsub),
      fmul: method(:fmul), fdiv: method(:fdiv) }.each do |op, expected|
      [4, 8].each do |size|
        assert_words [ldr_fp_slot(FA, 1, size), ldr_fp_slot(FB, 2, size),
                      expected.call(size, FA, FA, FB), str_fp_slot(FA, 0, size)],
                     body_of(op, dst: 0, a: 1, b: 2, size: size),
                     "#{op} size #{size}"
      end
    end
  end

  # A floating comparison is FCMP followed by a CSET, exactly as an integer one
  # is CMP followed by a CSET; the result is an int 0/1 in a general slot, so
  # the store is the ordinary 64-bit one.
  def test_floating_comparison_is_fcmp_then_cset
    assert_words [ldr_fp_slot(FA, 1, 8), ldr_fp_slot(FB, 2, 8),
                  fcmp(8, FA, FB), cset(0, A, COND_EQ), str_slot(A, 0)],
                 body_of(:feq, dst: 0, a: 1, b: 2, size: 8)
  end

  # The condition each floating comparison selects. FCMP reports an unordered
  # (NaN) compare as N=0 Z=0 C=1 V=1, and every condition below reads false
  # there, which is what C requires of <, <=, > and >= against a NaN — and of
  # "==", while "!=" must read true, which NE does since FCMP leaves Z clear.
  def test_every_floating_comparison_selects_its_condition_code
    {
      feq: COND_EQ, fne: COND_NE,
      flt: COND_MI, fle: COND_LS, fgt: COND_GT, fge: COND_GE
    }.each do |op, condition|
      words = body_of(op, dst: 0, a: 1, b: 2, size: 4)
      assert_equal cset(0, A, condition), words[3], op.to_s
    end
  end

  # :itof reads the integer side through the X view for a width-8 source and the
  # W view otherwise (where the value already sits sign- or zero-extended), and
  # picks SCVTF or UCVTF from the descriptor's signedness — the machine offering
  # both, so an unsigned source needs no widening trick.
  def test_integer_to_floating_selects_the_view_and_the_signedness
    {
      [4, true] => [0, method(:scvtf)],
      [8, true] => [1, method(:scvtf)],
      [1, false] => [0, method(:ucvtf)],
      [8, false] => [1, method(:ucvtf)]
    }.each do |desc, (sf, expected)|
      [4, 8].each do |float_size|
        assert_words [ldr_slot(A, 1), expected.call(sf, float_size, FA, A),
                      str_fp_slot(FA, 0, float_size)],
                     body_of(:itof, dst: 0, a: 1, b: desc, size: float_size),
                     "#{desc.inspect} -> float #{float_size}"
      end
    end
  end

  # :ftoi truncates toward zero (rmode 11), the C cast's rule, into the X view
  # for a width-8 destination and the W view otherwise. `size` names the source
  # float width, which selects the type field.
  def test_floating_to_integer_truncates_toward_zero
    {
      [4, true] => [0, method(:fcvtzs)],
      [8, true] => [1, method(:fcvtzs)],
      [8, false] => [1, method(:fcvtzu)]
    }.each do |desc, (sf, expected)|
      [4, 8].each do |float_size|
        assert_words [ldr_fp_slot(FA, 1, float_size), expected.call(sf, float_size, A, FA),
                      str_slot(A, 0)],
                     body_of(:ftoi, dst: 0, a: 1, b: desc, size: float_size),
                     "float #{float_size} -> #{desc.inspect}"
      end
    end
  end

  # :ftof is a single FCVT whose type field names the source and whose opc field
  # names the destination; the result is stored at the opposite width to the one
  # it was loaded at.
  def test_floating_width_change_is_one_fcvt
    assert_words [ldr_fp_slot(FA, 1, 4), fcvt(4, FA, FA), str_fp_slot(FA, 0, 8)],
                 body_of(:ftof, dst: 0, a: 1, size: 4)
    assert_words [ldr_fp_slot(FA, 1, 8), fcvt(8, FA, FA), str_fp_slot(FA, 0, 4)],
                 body_of(:ftof, dst: 0, a: 1, size: 8)
  end

  # A floating value moves between its slot and a vector register at its own
  # width, not always 64 bits: a float slot holds four meaningful bytes, so
  # reading it as a D register would feed the arithmetic a different number.
  def test_float_slots_are_moved_four_bytes_at_a_time
    words = body_of(:fadd, dst: 0, a: 1, b: 2, size: 4)
    assert_equal ldr_s(FA, SP, slot(1)), words[0]
    assert_equal str_s(FA, SP, slot(0)), words.last
  end

  # Floating parameters arrive in v0.., integer ones in x0.., each sequence
  # advancing its own counter — so a mixed list writes each register once and
  # the two files never collide.
  def test_floating_and_integer_parameters_use_independent_sequences
    kinds = [:gp, :sse8, :gp, :sse4]
    fn = func([inst(:ret)], vregs: 4, params: 4, param_kinds: kinds)
    assert_words [str_slot(0, 0), str_fp_slot(0, 1, 8), str_slot(1, 2), str_fp_slot(1, 3, 4)],
                 body(fn).first(4)
  end

  # The same independence at a call site, and the result of a floating call
  # comes back from v0 rather than x0.
  def test_floating_and_integer_call_arguments_use_independent_sequences
    args = [[0, :gp], [1, :sse8], [2, :gp], [3, :sse4]]
    fn = func([inst(:call, dst: 4, a: "g", b: args, size: [nil, :sse8])], vregs: 5)
    assert_words [ldr_slot(0, 0), ldr_fp_slot(0, 1, 8), ldr_slot(1, 2), ldr_fp_slot(1, 3, 4),
                  bl_imm(0), str_fp_slot(0, 4, 8)],
                 body(fn)
  end

  # Eight floating arguments fill v0..v7 while the integer sequence stays
  # untouched. A ninth :sse8 tag is a generator contract violation, not valid C
  # this backend has yet to grow: the generator classifies against this target's
  # eight vector registers and would have tagged that argument :mem. It raises
  # plainly, as the x86_64 backend does for the same overrun.
  def test_eight_floating_arguments_fill_the_vector_registers
    args = (0..7).map { |i| [i, :sse8] }
    fn = func([inst(:call, dst: nil, a: "g", b: args)], vregs: 9)
    assert_words (0..7).map { |i| ldr_fp_slot(i, i, 8) } + [bl_imm(0)], body(fn)

    ninth = func([inst(:call, dst: nil, a: "g", b: args + [[8, :sse8]])], vregs: 9)
    assert_match(/overruns the vector registers/,
                 assert_raises(RuntimeError) { compile(ninth) }.message)
  end

  # A ninth integer argument goes to the outgoing argument area at [sp + 0],
  # copied there through the A scratch as a whole eightbyte, while the first
  # eight still fill x0..x7. The area is written before any argument register is
  # loaded, so the copy's scratch can never hold a value already placed.
  def test_ninth_integer_argument_goes_to_the_outgoing_area
    @outgoing = 16
    args = (0..8).map { |i| [i, i < 8 ? :gp : :mem] }
    fn = func([inst(:call, dst: nil, a: "g", b: args)], vregs: 9)
    assert_words [ldr_slot(A, 8), str_x(A, SP, 0)] +
                 (0..7).map { |i| ldr_slot(i, i) } + [bl_imm(0)],
                 body(fn)
  end

  # Two stack arguments keep their left-to-right order as ascending addresses in
  # the area, eight bytes apart, which is the layout AAPCS64 6.4.2 gives them.
  def test_stack_arguments_ascend_in_left_to_right_order
    @outgoing = 16
    args = (0..9).map { |i| [i, i < 8 ? :gp : :mem] }
    fn = func([inst(:call, dst: nil, a: "g", b: args)], vregs: 10)
    assert_words [ldr_slot(A, 8), str_x(A, SP, 0), ldr_slot(A, 9), str_x(A, SP, 8)] +
                 (0..7).map { |i| ldr_slot(i, i) } + [bl_imm(0)],
                 body(fn)
  end

  # A stack argument past the vector registers travels the same way: the tag is
  # :mem whatever the value's type, and moving the whole eightbyte carries a
  # float's low four bytes intact.
  def test_ninth_floating_argument_uses_the_outgoing_area
    @outgoing = 16
    args = (0..8).map { |i| [i, i < 8 ? :sse8 : :mem] }
    fn = func([inst(:call, dst: nil, a: "g", b: args)], vregs: 9)
    assert_words [ldr_slot(A, 8), str_x(A, SP, 0)] +
                 (0..7).map { |i| ldr_fp_slot(i, i, 8) } + [bl_imm(0)],
                 body(fn)
  end

  # The area is reserved once by the prologue, sized for the widest call, and sp
  # does not move again: the frame record therefore sits above it and every slot
  # offset is shifted by its size. Reserving it up front is what lets a slot keep
  # a fixed sp-relative address across a call.
  def test_the_outgoing_area_is_reserved_by_the_prologue
    @outgoing = 16
    wide = (0..9).map { |i| [i, i < 8 ? :gp : :mem] }
    narrow = (0..8).map { |i| [i, i < 8 ? :gp : :mem] }
    fn = func([inst(:call, dst: nil, a: "g", b: narrow),
               inst(:call, dst: nil, a: "h", b: wide)], vregs: 10)
    # 16 outgoing + 16 record + align16(10*8) = 112.
    assert_words [sub_imm(SP, SP, 112), stp_x(FP, LR, SP, 16)], words(fn).first(2)
  end

  # A function making no call with stack arguments reserves no area at all, so
  # its frame and every slot offset are exactly what they were before the area
  # existed.
  def test_no_outgoing_area_without_stack_arguments
    fn = func([inst(:call, dst: nil, a: "g", b: [[0, :gp]])], vregs: 1)
    assert_words [sub_imm(SP, SP, 32), stp_x(FP, LR, SP, 0)], words(fn).first(2)
  end

  # A ninth integer parameter is read back from the caller's own argument area.
  # Nothing separates the two frames — AArch64 keeps the return address in x30
  # rather than pushing it — so the first stack argument sits at exactly
  # [sp + frame size] once the prologue has lowered sp.
  def test_ninth_integer_parameter_is_read_from_the_callers_area
    kinds = Array.new(8, :gp) + [:mem]
    fn = func([inst(:ret)], vregs: 9, params: 9, param_kinds: kinds)
    frame = SAVE_AREA_SIZE + 80 # 16 record + align16(9*8)
    assert_words (0..7).map { |i| str_slot(i, i) } +
                 [ldr_x(A, SP, frame), str_slot(A, 8)],
                 body(fn).first(10)
  end

  # A floating return loads v0 at the value's width and then runs the ordinary
  # epilogue; an integer return still loads x0.
  def test_floating_return_loads_v0
    assert_words [ldr_fp_slot(0, 0, 8), ldp_x(FP, LR, SP, 0), add_imm(SP, SP, 32), ret_x30],
                 body(func([inst(:ret, a: 0, size: 8)], vregs: 1))
    assert_words [ldr_fp_slot(0, 0, 4), ldp_x(FP, LR, SP, 0), add_imm(SP, SP, 32), ret_x30],
                 body(func([inst(:ret, a: 0, size: 4)], vregs: 1))
  end

  # --- symbol addresses ----------------------------------------------------

  # A global's address is formed by an adrp/add pair with both immediates left
  # zero for the linker, and the result parked in the destination slot.
  def test_global_address_is_an_adrp_add_pair
    fn = func([inst(:global_addr, dst: 0, a: "g")], vregs: 1)
    assert_words [adrp(A), add_imm(A, A, 0), str_slot(A, 0)], body(fn)
  end

  # A string literal's address uses the same pair; the interned string's id
  # travels on the relocation record rather than in the instruction.
  def test_string_address_is_an_adrp_add_pair
    fn = func([inst(:string_addr, dst: 0, a: 3)], vregs: 1)
    assert_words [adrp(A), add_imm(A, A, 0), str_slot(A, 0)], body(fn)
  end

  # A taken function address is an address like any other, not a branch.
  def test_function_address_is_an_adrp_add_pair
    fn = func([inst(:func_addr, dst: 0, a: "g")], vregs: 1)
    assert_words [adrp(A), add_imm(A, A, 0), str_slot(A, 0)], body(fn)
  end

  # A PIC reference instead *reads* the symbol's GOT slot: the second
  # instruction is a 64-bit load through the page register, not an add.
  def test_got_address_is_an_adrp_ldr_pair
    fn = func([inst(:got_addr, dst: 0, a: "g")], vregs: 1)
    assert_words [adrp(A), ldr_x(A, A, 0), str_slot(A, 0)], body(fn)
  end

  # Each address-forming op records exactly one relocation, whose offset is
  # that of the leading adrp. Splitting it into the machine's actual pair of
  # ELF entries is the object writer's job, so the backend's record stays a
  # single machine-independent item.
  def test_symbol_addresses_record_one_relocation_at_the_adrp
    {
      inst(:global_addr, dst: 0, a: "g") => { kind: :global, offset: 8, symbol: "g" },
      inst(:func_addr, dst: 0, a: "g") => { kind: :func, offset: 8, symbol: "g" },
      inst(:got_addr, dst: 0, a: "g") => { kind: :got, offset: 8, symbol: "g" },
      inst(:string_addr, dst: 0, a: 3) => { kind: :string, offset: 8, string_id: 3 }
    }.each do |instruction, expected|
      result = compile(func([instruction], vregs: 1))
      assert_equal [expected], result.relocations, instruction.op.to_s
    end
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

  # --- variadic functions --------------------------------------------------

  # A variadic function's prologue reserves a register-save area at the top of
  # the frame and spills all eight integer argument registers into its 8-byte
  # slots and all eight vector ones into the low half of their 16-byte slots, so
  # a later :va_start can point __gr_top / __vr_top at the areas' ends. The
  # frame here is 16 outgoing (none) + 16 record + align16(1*8) vreg = 32, then
  # 128 for the vector area and 64 for the integer one, so the vector slots
  # start at 32 and the integer ones at 160.
  def test_variadic_prologue_saves_the_argument_registers
    fn = func([inst(:va_start, a: 0, b: 0)], vregs: 1, variadic: true)
    gp_saves = (0..7).map { |i| str_x(i, SP, 160 + 8 * i) }
    vr_saves = (0..7).map { |i| str_d(i, SP, 32 + 16 * i) }
    saves = words(fn).drop(words(fn).index(stp_x(FP, LR, SP, 0)) + 1).first(16)
    assert_words gp_saves + vr_saves, saves
  end

  # :va_start writes the five AAPCS64 fields at the tag address. With no named
  # parameters __gr_offs seeds at -(8)*8 = -64 and __vr_offs at -(8)*16 = -128,
  # while __stack and __gr_top both address the top of the 224-byte frame and
  # __vr_top the end of the vector area at 160.
  def test_va_start_writes_the_five_fields
    fn = func([inst(:va_start, a: 0, b: 0)], vregs: 1, variadic: true)
    all = words(fn)
    start = all.index(ldr_x(A, SP, slot(0))) # ldr x9, [sp, &tag]
    expected = [
      ldr_x(A, SP, slot(0)),
      add_imm(B, SP, 224), str_x(B, A, 0),   # __stack  = sp + 224
      add_imm(B, SP, 224), str_x(B, A, 8),   # __gr_top = sp + 224
      add_imm(B, SP, 160), str_x(B, A, 16),  # __vr_top = sp + 160
      movz(0, B, 0xFFC0, 0), movk(0, B, 0xFFFF, 1), str_w(B, A, 24), # __gr_offs = -64
      movz(0, B, 0xFF80, 0), movk(0, B, 0xFFFF, 1), str_w(B, A, 28)  # __vr_offs = -128
    ]
    assert_words expected, all[start, expected.size]
  end

  # A named parameter that itself spilled onto the caller's stack pushes the
  # first variable argument one eightbyte higher, so __stack seeds past it while
  # __gr_top still marks the frame top. Nine :gp parameters put the ninth on the
  # stack (__gr_offs then seeds at zero, the integer file being spent by the
  # named part).
  def test_va_start_skips_a_stacked_named_parameter
    kinds = Array.new(8, :gp) + [:mem]
    fn = func([inst(:va_start, a: 9, b: 9)], vregs: 10, params: 9, param_kinds: kinds,
              variadic: true)
    all = words(fn)
    start = all.index(ldr_x(A, SP, slot(9)))
    # frame = 16 record + align16(10*8)=80 + 192 save area = 288; the stacked
    # named parameter sits at [sp + 288], so __stack seeds at sp + 296.
    assert_equal add_imm(B, SP, 296), all[start + 1] # __stack past the named slot
    assert_equal add_imm(B, SP, 288), all[start + 3] # __gr_top at the frame top
    assert_equal movz(0, B, 0, 0), all[start + 7]    # __gr_offs = 0 (file spent)
  end

  # --- refusals ------------------------------------------------------------

  # The IR ops that belong to A4 are refused by name rather than lowered to
  # something plausible-looking.
  def test_later_milestone_ops_are_refused
    {
      inst(:alloca, dst: 0, a: 1) => /alloca/
    }.each do |instruction, pattern|
      error = assert_raises(Rubycc::Backend::UnsupportedError, instruction.op.to_s) do
        compile(func([instruction], vregs: 4))
      end
      assert_match pattern, error.message
    end
  end

  # --- aggregates ----------------------------------------------------------

  # An aggregate result too large for registers is written through a buffer
  # whose address AAPCS64 6.4.1 puts in x8. The register is outside both
  # argument sequences, so the parameter spilling stores it without disturbing
  # the x0.. sequence a real argument would use — and it is spilled at all
  # because x8 is caller-saved and would not survive the function's first call.
  def test_indirect_result_pointer_is_spilled_from_x8
    fn = func([inst(:ret)], vregs: 3, params: 3, param_kinds: [:indirect_result, :gp, :gp])
    assert_words [str_slot(8, 0), str_slot(0, 1), str_slot(1, 2)], body(fn).first(3)
  end

  # The same register on the calling side: the buffer address goes to x8 while
  # the ordinary arguments keep x0 and x1, none of them displaced by it.
  def test_indirect_result_pointer_is_placed_in_x8_at_a_call
    args = [[0, :indirect_result], [1, :gp], [2, :gp]]
    fn = func([inst(:call, dst: nil, a: "g", b: args)], vregs: 3)
    assert_words [ldr_slot(8, 0), ldr_slot(0, 1), ldr_slot(1, 2)], body(fn).first(3)
  end

  # An aggregate returned in registers is gathered out of the buffer the
  # generator filled, each piece read at its own offset and width. A homogeneous
  # pair of floats is two single-precision loads four bytes apart into s0 and s1
  # — the AAPCS64 shape whose System V reading (one 8-byte load into d0) would
  # have been silently wrong rather than merely unsupported.
  def test_hfa_return_is_gathered_into_separate_vector_registers
    pieces = [piece(0, 4, :sse4), piece(4, 4, :sse4)]
    fn = func([inst(:ret, a: 0, size: pieces)], vregs: 1)
    assert_words [ldr_slot(A, 0), ldr_s(0, A, 0), ldr_s(1, A, 4)], body(fn).first(3)
  end

  # A non-homogeneous aggregate of 16 bytes takes the integer pair instead, one
  # whole eightbyte per register.
  def test_small_aggregate_return_is_gathered_into_the_integer_pair
    pieces = [piece(0, 8, :gp), piece(8, 8, :gp)]
    fn = func([inst(:ret, a: 0, size: pieces)], vregs: 1)
    assert_words [ldr_slot(A, 0), ldr_x(0, A, 0), ldr_x(1, A, 8)], body(fn).first(3)
  end

  # The caller side of the same return: each piece is scattered from its result
  # register into the scratch buffer at its own offset and width.
  def test_aggregate_call_result_is_scattered_into_the_buffer
    pieces = [piece(0, 8, :sse8), piece(8, 8, :sse8)]
    fn = func([inst(:call, dst: nil, a: "g", b: [], size: [nil, [1, pieces]])], vregs: 2)
    assert_words [ldr_slot(A, 1), str_d(0, A, 0), str_d(1, A, 8)], body(fn).drop(1).first(3)
  end

  # --- whole-object copies -------------------------------------------------

  # A copy of a whole number of eightbytes, few enough to unroll, is a run of
  # load/store pairs through the ADDR scratch — no loop, no counter.
  def test_small_memcpy_is_unrolled
    expected = [ldr_slot(A, 0), ldr_slot(B, 1)]
    2.times { |i| expected += [ldr_x(ADDR, B, 8 * i), str_x(ADDR, A, 8 * i)] }
    assert_words expected, body_of(:memcpy, a: 0, b: 1, size: 16)
  end

  # A size that is not a multiple of eight finishes with one access per
  # remaining 4/2/1 bytes, each naturally aligned against the block before it so
  # the scaled immediate names it exactly.
  def test_memcpy_tail_moves_the_odd_bytes
    expected = [ldr_slot(A, 0), ldr_slot(B, 1),
                ldr_x(ADDR, B, 0), str_x(ADDR, A, 0),
                ldr_w(ADDR, B, 8), str_w(ADDR, A, 8),
                ldrh(ADDR, B, 12), strh(ADDR, A, 12),
                ldrb(ADDR, B, 14), strb(ADDR, A, 14)]
    assert_words expected, body_of(:memcpy, a: 0, b: 1, size: 15)
  end

  # Past the unroll limit the eightbytes go through a counted loop instead, so
  # the code size stops growing with the object. The loop advances both
  # addresses, decrements the counter with a flag-setting subs and branches back
  # while it is non-zero; the branch needs no fixup, its target being behind it.
  def test_large_memcpy_uses_a_counted_loop
    emitted = body_of(:memcpy, a: 0, b: 1, size: 8 * 12)
    assert_words [ldr_slot(A, 0), ldr_slot(B, 1), movz(1, C, 12, 0)], emitted.first(3)
    assert_words [ldr_x(ADDR, B, 0), str_x(ADDR, A, 0),
                  add_imm(B, B, 8), add_imm(A, A, 8),
                  subs_imm(C, C, 1), b_cond(COND_NE, -5)],
                 emitted.drop(3)
  end

  # The same refusals seen from the front of the compiler: valid C that uses an
  # A4 feature stops with a clear error instead of producing an object.
  def test_unsupported_c_constructs_are_refused_end_to_end
    {
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
