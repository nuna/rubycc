# frozen_string_literal: true

require_relative "test_helper"

# Encoding contracts of the x86-64 code generator that an end-to-end GCC
# comparison cannot pin down, because several different instruction sequences
# compute the same answer and only one of them is the one intended.
#
# Two groups live here. The first is a genuine correctness contract the machine
# forces (the conversion instruction's width). The rest are the spill-traffic
# rules: which loads and stores the backend is expected *not* to emit. A
# differential test cannot see those at all — code that reloads every value is
# perfectly correct, merely slow — so the byte sequences are asserted directly,
# each written out from the Intel SDM's encoding of the instruction meant.
class TestX86_64Backend < Minitest::Test
  Backend = Rubycc::Backend::X86_64
  IR = Rubycc::IR

  # The fixed prologue: push rbp (1) + mov rbp, rsp (3) + sub rsp, imm32 (7).
  PROLOGUE_BYTES = 11

  # What one address pin costs (see #pin_instructions): lea rax, [rbp+disp]
  # (2 opcode bytes + a disp8 ModR/M) and the 4-byte store that parks it.
  PIN_BYTES = 8

  # A vreg's rbp-relative displacement, as a byte in a disp8 ModR/M.
  def slot(vreg) = (-8 * (vreg + 1)) & 0xFF

  def test_float_to_integer_selects_rex_w_only_when_the_signed_primitive_needs_it
    assert_equal [0xF2, 0x0F, 0x2C, 0xC0], conversion_bytes([4, true])
    assert_equal [0xF2, 0x48, 0x0F, 0x2C, 0xC0], conversion_bytes([4, false])
    assert_equal [0xF2, 0x48, 0x0F, 0x2C, 0xC0], conversion_bytes([8, true])
    assert_equal [0xF2, 0x0F, 0x2C, 0xC0], conversion_bytes([2, false])
  end

  # --- spill traffic --------------------------------------------------------

  # Two rules at once, on a body whose values all have a second reader so that
  # none of them is a transient (see below) and every store stays:
  #
  #   * a binary op's second operand is read out of its slot rather than staged
  #     through ecx — "add r32, r/m32" (03 /r) is the same addition as "add
  #     r/m32, r32" (01 /r) with the operands the other way round;
  #   * the subtraction that follows does not re-read vreg 2, the value being
  #     still in eax where the store took it from.
  def test_an_operand_is_read_from_its_slot_and_a_just_stored_value_is_not
    body = body_bytes([IR::Instruction.new(:add, dst: 2, a: 0, b: 1),
                       IR::Instruction.new(:sub, dst: 3, a: 2, b: 0),
                       IR::Instruction.new(:store, a: 3, b: 2, size: 8),
                       IR::Instruction.new(:store, a: 3, b: 2, size: 8)],
                      vregs: 4, pinned: [0, 1, 2, 3])
    assert_equal [0x48, 0x8B, 0x45, slot(0),  # mov rax, [rbp-8]      (vreg 0)
                  0x03, 0x45, slot(1),        # add eax, [rbp-16]     (vreg 1)
                  0x48, 0x89, 0x45, slot(2),  # mov [rbp-24], rax
                  0x2B, 0x45, slot(0),        # sub eax, [rbp-8]      (no reload of vreg 2)
                  0x48, 0x89, 0x45, slot(3)], # mov [rbp-32], rax
                 body.first(18)
  end

  # A value produced by one instruction and read by the next, with no other
  # reader, is never written to its slot at all. Here vreg 2's only reader is
  # the :store behind it, so the add's result stays in eax — and the store's
  # value operand has to be rescued into rcx before eax is refilled with the
  # destination address, which is the only way it can still be reached.
  def test_a_single_use_temporary_is_never_written_to_its_slot
    body = body_bytes([IR::Instruction.new(:add, dst: 2, a: 0, b: 1),
                       IR::Instruction.new(:store, a: 3, b: 2, size: 8)],
                      vregs: 4, pinned: [0, 1, 3])
    assert_equal [0x48, 0x8B, 0x45, slot(0),  # mov rax, [rbp-8]
                  0x03, 0x45, slot(1),        # add eax, [rbp-16]   (vreg 2, unstored)
                  0x48, 0x89, 0xC1,           # mov rcx, rax
                  0x48, 0x8B, 0x45, slot(3),  # mov rax, [rbp-32]
                  0x48, 0x89, 0x08],          # mov [rax], rcx
                 body
  end

  # A subscript's "index * element size" plus the add to the base is one `lea`,
  # whose SIB byte carries the element size as a two-bit scale. The IR pass
  # hands the backend a single :scaled_add whose `size` is that width
  # (IR::Simplify); mod = 00 with rm = 100 selects the SIB form with no
  # displacement.
  def test_a_scaled_add_is_one_lea
    body = body_bytes([IR::Instruction.new(:scaled_add, dst: 2, a: 0, b: 1, size: 4),
                       IR::Instruction.new(:store, a: 2, b: 2, size: 8)],
                      vregs: 3, pinned: [0, 1, 2])
    assert_equal [0x48, 0x8B, 0x45, slot(0),  # mov rax, [rbp-8]    (base)
                  0x48, 0x8B, 0x4D, slot(1),  # mov rcx, [rbp-16]   (index)
                  0x48, 0x8D, 0x04, 0x88],    # lea rax, [rax + rcx*4]
                 body.first(12)
  end

  # An eight-byte element scales by 8, the largest the SIB field can name.
  def test_a_scaled_add_scales_an_eightbyte_element_by_eight
    body = body_bytes([IR::Instruction.new(:scaled_add, dst: 2, a: 0, b: 1, size: 8),
                       IR::Instruction.new(:store, a: 2, b: 2, size: 8)],
                      vregs: 3, pinned: [0, 1, 2])
    assert_equal [0x48, 0x8D, 0x04, 0xC8], body[8, 4] # lea rax, [rax + rcx*8]
  end

  # A branch on a condition that is not already in eax compares the slot
  # against zero in place (83 /7 with a sign-extended imm8) instead of loading
  # it to test it. Both read the same low four bytes.
  def test_a_branch_tests_its_condition_in_place
    body = body_bytes([IR::Instruction.new(:jump_if_zero, a: 0, b: 0),
                       IR::Instruction.new(:label, a: 0)],
                      vregs: 1, pinned: [0])
    assert_equal [0x83, 0x7D, slot(0), 0x00,  # cmp dword [rbp-8], 0
                  0x0F, 0x84],                # je rel32
                 body.first(6)
  end

  # A floating op reads its second operand out of its slot too: all four scalar
  # arithmetic opcodes take an "xmm, xmm/m" pair, so the memory form is the same
  # instruction with a different ModR/M. No pin is needed here: a value the
  # vector register file touches is refused promotion outright.
  def test_a_floating_op_reads_its_second_operand_from_its_slot
    body = body_bytes([IR::Instruction.new(:fmul, dst: 2, a: 0, b: 1, size: 8),
                       IR::Instruction.new(:store, a: 2, b: 2, size: 8)],
                      vregs: 3)
    assert_equal [0xF2, 0x0F, 0x10, 0x45, slot(0),  # movsd xmm0, [rbp-8]
                  0xF2, 0x0F, 0x59, 0x45, slot(1)], # mulsd xmm0, [rbp-16]
                 body.first(10)
  end

  # --- whole-function promotion ---------------------------------------------

  # A promoted value has no slot at all: it is read out of the callee-saved
  # register it lives in and written back into that same register, and nothing
  # ever names [rbp + its slot]. Here vreg 2 is the hottest value (three
  # occurrences) and takes rbx, vreg 0 (two) r12 and vreg 1 (one) r13; vreg 3 is
  # a transient, which promotion leaves alone because its value never reaches a
  # slot to begin with.
  #
  # The first add is the in-place form: its destination and its first operand
  # are the same value, so 03 /r ("add r32, r/m32") is aimed straight at rbx and
  # no move follows. The subtraction cannot be — its destination is a transient
  # — so it loads rbx into eax and names r12 in the r/m field instead.
  def test_a_promoted_value_is_computed_in_its_register_and_never_named_in_a_slot
    body = body_bytes([IR::Instruction.new(:add, dst: 2, a: 0, b: 1),
                       IR::Instruction.new(:sub, dst: 3, a: 2, b: 0),
                       IR::Instruction.new(:store, a: 3, b: 2, size: 8)],
                      vregs: 4)
    assert_equal [0x48, 0x89, 0x5D, 0xD8, # mov [rbp-40], rbx   (saved: three registers
                  0x4C, 0x89, 0x65, 0xD0, # mov [rbp-48], r12    used, three slots below
                  0x4C, 0x89, 0x6D, 0xC8, # mov [rbp-56], r13    the four vreg slots)
                  0x4C, 0x89, 0xE3,   # mov rbx, r12       (vreg 2 <- vreg 0)
                  0x41, 0x03, 0xDD,   # add ebx, r13d      (vreg 2 += vreg 1)
                  0x48, 0x89, 0xD8,   # mov rax, rbx
                  0x41, 0x2B, 0xC4,   # sub eax, r12d      (vreg 3, a transient: no store)
                  0x48, 0x89, 0xD9,   # mov rcx, rbx       (the store's value operand)
                  0x48, 0x89, 0x08],  # mov [rax], rcx
                 body
  end

  # The two ends of a promotion. The prologue saves each register it is about to
  # take over into a slot of its own — a mov into the frame rather than a push,
  # so rsp's 16-byte alignment stays a property of the frame size — and then
  # writes a promoted parameter straight from the argument register it arrived
  # in, never through the parameter's slot. Every ret restores what was saved,
  # after the return value is loaded (it may itself come out of a promoted
  # register) and before "leave" gives up the frame.
  def test_a_promoted_parameter_is_taken_from_its_argument_register_and_given_back
    insts = [IR::Instruction.new(:add, dst: 2, a: 0, b: 1),
             IR::Instruction.new(:add, dst: 3, a: 2, b: 0),
             IR::Instruction.new(:ret, a: 3)]
    bytes = Backend.new.compile(function(insts, vregs: 4, params: 2))
                   .bytes.byteslice(PROLOGUE_BYTES..).bytes
    # The save slots sit just below the four vreg slots (a 32-byte region), so
    # at -40 and -48; the frame size accounts for them.
    assert_equal [0x48, 0x89, 0x5D, 0xD8,     # mov [rbp-40], rbx   (save)
                  0x4C, 0x89, 0x65, 0xD0,     # mov [rbp-48], r12   (save)
                  0x48, 0x89, 0xFB,           # mov rbx, rdi        (vreg 0)
                  0x49, 0x89, 0xF4,           # mov r12, rsi        (vreg 1)
                  0x48, 0x89, 0xD8,           # mov rax, rbx
                  0x41, 0x03, 0xC4,           # add eax, r12d       (vreg 2, transient)
                  0x03, 0xC3,                 # add eax, ebx        (vreg 3, transient)
                  0x48, 0x8B, 0x5D, 0xD8,     # mov rbx, [rbp-40]   (restore)
                  0x4C, 0x8B, 0x65, 0xD0,     # mov r12, [rbp-48]   (restore)
                  0xC9, 0xC3],                # leave; ret
                 bytes
  end

  # A promoted second operand is named in the r/m field register-direct (mod =
  # 11) rather than staged through ecx, exactly as a slot operand is named
  # [rbp+disp]. The two subtractions differ only in which register that is:
  # rbx is register 3 and fits the field's three bits, while r12's fourth bit
  # has to arrive in REX.B — the 0x41 prefix, and the whole cost of using one
  # of the four extended registers here.
  def test_a_promoted_operand_takes_rex_b_only_when_its_number_needs_a_fourth_bit
    body = promoted_body([IR::Instruction.new(:sub, dst: 4, a: 2, b: 0),
                          IR::Instruction.new(:sub, dst: 5, a: 4, b: 1),
                          IR::Instruction.new(:store, a: 3, b: 5, size: 8)],
                         vregs: 6, promoted: [0, 1, 2, 3])
    assert_equal [0x4C, 0x89, 0xE8,   # mov rax, r13     (vreg 2)
                  0x2B, 0xC3,         # sub eax, ebx     (vreg 0: no REX at all)
                  0x41, 0x2B, 0xC4,   # sub eax, r12d    (vreg 1: REX.B)
                  0x48, 0x89, 0xC1,   # mov rcx, rax
                  0x4C, 0x89, 0xF0,   # mov rax, r14     (vreg 3)
                  0x48, 0x89, 0x08],  # mov [rax], rcx
                 body
  end

  # `lea`'s base and index are named independently in the SIB byte, so both may
  # be promoted registers and the address is formed without a move. REX.X
  # carries the index's fourth bit and REX.B the base's — here 0x4A is REX.W
  # plus X alone, r12 being the index and rbx (register 3) the base.
  #
  # An index of r12 is the case worth pinning: the SIB index field 100 means
  # "no index" at REX.X = 0, and names r12 only because REX.X is set.
  def test_a_lea_names_a_promoted_base_and_a_promoted_r12_index
    body = promoted_body([IR::Instruction.new(:scaled_add, dst: 3, a: 0, b: 1, size: 4),
                          IR::Instruction.new(:store, a: 3, b: 2, size: 8)],
                         vregs: 4, promoted: [0, 1, 2])
    assert_equal [0x4A, 0x8D, 0x04, 0xA3], # REX.W+X lea rax, [rbx + r12*4]
                 body.first(4)             # mod=00 rm=100; SIB scale=2 index=100 base=011
  end

  # r12 as a *base* needs nothing beyond its REX.B: the SIB base field 100 does
  # name rsp/r12 (it is the ModR/M rm field where 100 means "a SIB byte
  # follows"), so mod stays 00 and no displacement is emitted.
  def test_a_lea_gives_an_r12_base_no_displacement
    body = promoted_body([IR::Instruction.new(:scaled_add, dst: 3, a: 1, b: 0, size: 4),
                          IR::Instruction.new(:store, a: 3, b: 2, size: 8)],
                         vregs: 4, promoted: [0, 1, 2])
    assert_equal [0x49, 0x8D, 0x04, 0x9C], # REX.W+B lea rax, [r12 + rbx*4]
                 body.first(4)             # mod=00 rm=100; SIB scale=2 index=011 base=100
  end

  # r13 as a base is the one arrangement the encoding refuses: a SIB base field
  # of 101 with mod = 00 means "no base register, disp32 follows" (Intel SDM
  # Vol. 2A, Table 2-3), the same reservation that makes rbp unaddressable
  # without a displacement. mod = 01 with a zero disp8 names the register for
  # one extra byte.
  #
  # The destination is promoted too here (vreg 3 is the hottest value and takes
  # rbx), so the lea writes its result where it lives and no store follows: the
  # reg field is rbx rather than eax.
  def test_a_lea_gives_an_r13_base_the_zero_displacement_the_encoding_reserves
    body = promoted_body([IR::Instruction.new(:scaled_add, dst: 3, a: 0, b: 1, size: 4),
                          IR::Instruction.new(:store, a: 3, b: 2, size: 8),
                          IR::Instruction.new(:store, a: 3, b: 2, size: 8)],
                         vregs: 4, promoted: [3, 2, 0, 1])
    assert_equal [0x4B, 0x8D, 0x5C, 0xB5, 0x00], # REX.W+X+B lea rbx, [r13 + r14*4 + 0]
                 body.first(5)                   # mod=01 rm=100; SIB scale=2 index=110 base=101
  end

  # The shape the first pass's single-use copy forwarding leaves behind for
  # "i = i + 1" and "sum += x": a destination that is also the first operand.
  # When it is promoted, the addition runs in its register — one instruction,
  # no load and no store — and a commutative op whose *second* operand is the
  # destination is exchanged first so it takes the same path ("sum = x + sum"
  # being the same addition as "sum = sum + x").
  def test_a_promoted_destination_that_is_also_an_operand_is_updated_in_place
    in_place = [0x41, 0x03, 0xDC]   # add ebx, r12d   (03 /r, mod=11 reg=011 rm=100+REX.B)
    forward = promoted_body([IR::Instruction.new(:add, dst: 0, a: 0, b: 1),
                             IR::Instruction.new(:store, a: 2, b: 0, size: 8)],
                            vregs: 3, promoted: [0, 1, 2])
    swapped = promoted_body([IR::Instruction.new(:add, dst: 0, a: 1, b: 0),
                             IR::Instruction.new(:store, a: 2, b: 0, size: 8)],
                            vregs: 3, promoted: [0, 1, 2])
    assert_equal in_place, forward.first(3)
    assert_equal in_place, swapped.first(3)
  end

  # --- frame boundaries -------------------------------------------------------

  # All five PROMOTION_REGISTERS at once: five save instructions in the
  # prologue and five restore instructions in the epilogue, in assignment
  # order (rbx, r12, r13, r14, r15). REX.R — the 0x4C high nibble rather than
  # 0x48 — appears only once the source/target reaches r12, the first
  # register whose number needs a fourth bit.
  #
  # vreg 5..8 are each read once by the instruction right behind their
  # producer, so IR::Simplify makes every one of them a transient and
  # IR::Promotion's occurrence count never sees them; vreg 0..4 are each
  # touched once, so the tie is broken by register number and all five are
  # promoted in order.
  def test_all_five_promotion_registers_are_saved_and_restored
    insts = [IR::Instruction.new(:add, dst: 5, a: 0, b: 1),
             IR::Instruction.new(:add, dst: 6, a: 5, b: 2),
             IR::Instruction.new(:add, dst: 7, a: 6, b: 3),
             IR::Instruction.new(:add, dst: 8, a: 7, b: 4),
             IR::Instruction.new(:ret, a: 8)]
    ir_func = function(insts, vregs: 9)
    assert_equal [0, 1, 2, 3, 4], IR::Promotion.candidates(ir_func)
    bytes = Backend.new.compile(ir_func).bytes.bytes
    # The save slots sit just below the nine vreg slots (a 72-byte region
    # rounded up to 80), at -88, -96, -104, -112 and -120.
    assert_equal [0x48, 0x89, 0x5D, 0xA8, # mov [rbp-88], rbx    (save)
                  0x4C, 0x89, 0x65, 0xA0, # mov [rbp-96], r12    (save)
                  0x4C, 0x89, 0x6D, 0x98, # mov [rbp-104], r13   (save)
                  0x4C, 0x89, 0x75, 0x90, # mov [rbp-112], r14   (save)
                  0x4C, 0x89, 0x7D, 0x88], # mov [rbp-120], r15  (save)
                 bytes[PROLOGUE_BYTES, 20]
    assert_equal [0x48, 0x8B, 0x5D, 0xA8, # mov rbx, [rbp-88]    (restore)
                  0x4C, 0x8B, 0x65, 0xA0, # mov r12, [rbp-96]    (restore)
                  0x4C, 0x8B, 0x6D, 0x98, # mov r13, [rbp-104]   (restore)
                  0x4C, 0x8B, 0x75, 0x90, # mov r14, [rbp-112]   (restore)
                  0x4C, 0x8B, 0x7D, 0x88, # mov r15, [rbp-120]   (restore)
                  0xC9, 0xC3], # leave; ret
                 bytes.last(22)
  end

  # A promoted register's save slot goes below a function's stack objects,
  # never inside them: the frame is laid out vreg slots, then stack objects,
  # then save slots (#emit_prologue), so the two regions cannot alias however
  # the object is sized. Here a 24-byte object rounds up to 32 and sits at
  # [rbp-64..rbp-33]; the two save slots at -72 and -80 fall entirely below
  # it.
  def test_promoted_save_slots_sit_below_a_functions_stack_objects
    insts = [IR::Instruction.new(:add, dst: 2, a: 0, b: 1),
             IR::Instruction.new(:add, dst: 3, a: 2, b: 0),
             IR::Instruction.new(:ret, a: 3)]
    ir_func = IR::Function.new("f", insts, 4, 0, [24], :external, false, [])
    assert_equal [0, 1], IR::Promotion.candidates(ir_func)
    bytes = Backend.new.compile(ir_func).bytes.bytes
    assert_equal [0x48, 0x89, 0x5D, 0xB8, # mov [rbp-72], rbx   (save, below the object)
                  0x4C, 0x89, 0x65, 0xB0], # mov [rbp-80], r12  (save, below the object)
                 bytes[PROLOGUE_BYTES, 8]
  end

  # An odd number of promoted registers (one, here, and three below) still
  # leaves a 16-aligned frame: the save-slot region is rounded to 16 with
  # #align16 the same as the vreg-slot region is, regardless of the register
  # count's own parity.
  def test_an_odd_promoted_register_count_still_leaves_a_16aligned_frame
    one = IR::Function.new("f", [IR::Instruction.new(:ret, a: 0)], 1, 1, [], :external, false, [:gp])
    assert_equal [0], IR::Promotion.candidates(one)
    assert_equal 0, sub_rsp_bytes(one) % 16

    three = IR::Function.new("f", [IR::Instruction.new(:add, dst: 3, a: 0, b: 1),
                                    IR::Instruction.new(:store, a: 3, b: 2, size: 8)],
                              4, 0, [], :external, false, [])
    assert_equal [0, 1, 2], IR::Promotion.candidates(three)
    assert_equal 0, sub_rsp_bytes(three) % 16
  end

  # A stack-passed parameter (`param_kinds` naming :mem) arrives above the
  # return address at [rbp+16+8*k], the same place #spill_parameters always
  # reads it from; when its vreg is promoted, the value is read into rax
  # exactly as for any other parameter and then moved straight into the
  # promoted register instead of being stored to a slot. The second :mem
  # parameter shows the "+8n" indexing (k=1, so [rbp+24]).
  def test_a_promoted_stack_parameter_is_read_from_the_incoming_stack_slot
    insts = [IR::Instruction.new(:add, dst: 2, a: 0, b: 1),
             IR::Instruction.new(:ret, a: 2)]
    ir_func = IR::Function.new("f", insts, 3, 2, [], :external, false, %i[mem mem])
    assert_equal [0, 1], IR::Promotion.candidates(ir_func)
    bytes = Backend.new.compile(ir_func).bytes.bytes
    assert_equal [0x48, 0x89, 0x5D, 0xD8, # mov [rbp-40], rbx   (save)
                  0x4C, 0x89, 0x65, 0xD0, # mov [rbp-48], r12   (save)
                  0x48, 0x8B, 0x45, 0x10, # mov rax, [rbp+16]   (param 0, k=0)
                  0x48, 0x89, 0xC3, # mov rbx, rax        (into the promoted register)
                  0x48, 0x8B, 0x45, 0x18, # mov rax, [rbp+24]   (param 1, k=1)
                  0x49, 0x89, 0xC4], # mov r12, rax        (into the promoted register)
                 bytes[PROLOGUE_BYTES, 22]
  end

  # A function that also uses `alloca` still restores every promoted register
  # immediately before "leave", the one thing #emit_ret always does last: the
  # dynamic allocation lowers rsp, but every slot and every save is
  # rbp-relative, so nothing about it moves where the restore has to happen.
  def test_promoted_registers_are_restored_immediately_before_leave_with_alloca
    insts = [IR::Instruction.new(:add, dst: 2, a: 0, b: 1),
             IR::Instruction.new(:alloca, dst: 3, a: 2),
             IR::Instruction.new(:store, a: 3, b: 2, size: 8),
             IR::Instruction.new(:ret, a: 2)]
    ir_func = IR::Function.new("f", insts, 4, 2, [], :external, false, %i[gp gp])
    assert_equal [2, 0, 1], IR::Promotion.candidates(ir_func)
    bytes = Backend.new.compile(ir_func).bytes.bytes
    assert_equal [0x48, 0x8B, 0x5D, 0xD8, # mov rbx, [rbp-40]   (restore)
                  0x4C, 0x8B, 0x65, 0xD0, # mov r12, [rbp-48]   (restore)
                  0x4C, 0x8B, 0x6D, 0xC8, # mov r13, [rbp-56]   (restore)
                  0xC9, 0xC3], # leave; ret
                 bytes.last(14)
  end

  # --- residency contract ------------------------------------------------------

  # SlotResidency's rule is that a residency stays believed only across an
  # instruction that writes nothing the table names — and #note_register_clobbered
  # / #note_slots_undisturbed are trusted to mean that. A move between two
  # promoted registers is exactly such an instruction (PROMOTION_REGISTERS is
  # disjoint from every scratch/argument/return register the table ever
  # keys), so it must leave a transient's residency in eax untouched.
  #
  # vreg 2 is produced by the add and read only by the sub right behind it, so
  # IR::Simplify makes it a transient: it stays in eax, never reaching a slot.
  # The sub's destination (vreg 4) and first operand (vreg 3) are both
  # promoted and distinct, so #emit_promoted_binary loads vreg 3 into vreg 4's
  # register first — a register-register move that writes only r14 — before
  # reading vreg 2. If that move had been made to look like it disturbed eax,
  # the transient would be reloaded from [rbp+disp] (and read garbage, its
  # slot never having been written); instead it is read directly out of eax.
  def test_a_transient_survives_a_move_between_two_promoted_registers
    body = promoted_body([IR::Instruction.new(:add, dst: 2, a: 0, b: 1),
                          IR::Instruction.new(:sub, dst: 4, a: 3, b: 2)],
                         vregs: 5, promoted: [0, 1, 3, 4])
    assert_equal [0x48, 0x89, 0xD8, # mov rax, rbx        (vreg 0)
                  0x41, 0x03, 0xC4, # add eax, r12d       (vreg 1: vreg 2 now transient in eax)
                  0x4D, 0x89, 0xEE, # mov r14, r13        (vreg 4 <- vreg 3: writes only r14)
                  0x44, 0x2B, 0xF0], # sub r14d, eax       (vreg 2 read straight out of eax,
                                     #   not reloaded from its slot)
                 body
  end

  private

  def function(insts, vregs:, params: 0)
    IR::Function.new("f", insts, vregs, params, [], :external, false, Array.new(params, :gp))
  end

  # The prologue's "sub rsp, imm32" operand: the frame size, decoded from its
  # fixed position (byte 7, right after "push rbp; mov rbp, rsp; sub rsp,").
  def sub_rsp_bytes(ir_func)
    Backend.new.compile(ir_func).bytes.bytes[7, 4].pack("C*").unpack1("L<")
  end

  # The emitted bytes past the fixed prologue and past the block that saves the
  # promoted registers — one "mov [rbp+disp8], r64" each, four bytes apiece —
  # leaving only the body under test.
  #
  # `promoted` is the expected candidate order, asserted rather than assumed:
  # which value takes which register is IR::Promotion's ranking, and a test
  # that reads "r13 is the base" has to say where that came from. The registers
  # are handed out in that order (rbx, r12, r13, r14, r15).
  def promoted_body(insts, vregs:, params: 0, promoted:)
    ir_func = function(insts, vregs: vregs, params: params)
    assert_equal promoted, IR::Promotion.candidates(ir_func)
    Backend.new.compile(ir_func)
           .bytes.byteslice((PROLOGUE_BYTES + 4 * promoted.size)..).bytes
  end

  # The emitted bytes past the fixed prologue and past whatever `pinned` cost.
  def body_bytes(insts, vregs:, params: 0, pinned: [])
    pins = pin_instructions(pinned, sink: vregs)
    compiled = Backend.new.compile(function(pins + insts, vregs: vregs + (pins.empty? ? 0 : 1),
                                            params: params))
    compiled.bytes.byteslice((PROLOGUE_BYTES + PIN_BYTES * pins.size)..).bytes
  end

  # Instructions that pin `vregs` in their stack slots by taking the address of
  # each. A value whose address is taken must be in memory, which is also what
  # makes it ineligible for whole-function promotion (IR::Promotion) — and every
  # spill rule below is about a value that lives in a slot, which in a function
  # this small nothing otherwise would: five callee-saved registers are more
  # than enough to promote every value these bodies have.
  #
  # The addresses are all parked in one extra sink vreg past the ones under
  # test, and the sink's own address is taken first so it is not promoted
  # either. Nothing reads any of them: what a pin is here is a use that the
  # eligibility rule refuses, not a computation.
  def pin_instructions(vregs, sink:)
    return [] if vregs.empty?

    [IR::Instruction.new(:addr_of, dst: sink, a: sink)] +
      vregs.map { |vreg| IR::Instruction.new(:addr_of, dst: sink, a: vreg) }
  end

  def conversion_bytes(int_desc)
    # The fixed prologue is 16 bytes before the floating conversion's prefix:
    # push/mov/sub (11 bytes), then movsd xmm0,[rbp-8] (5 bytes). A REX.W
    # conversion is one byte longer than the 32-bit form.
    length = int_desc[0] == 8 || (int_desc == [4, false]) ? 5 : 4
    function = function([IR::Instruction.new(:ftoi, dst: 2, a: 0, b: int_desc, size: 8)], vregs: 3)
    Backend.new.compile(function).bytes.byteslice(16, length).bytes
  end
end
