# frozen_string_literal: true

module Rubycc
  module Backend
    # Tracks, while one function is being emitted, which scratch registers still
    # hold the value of which virtual-register slot — so a backend can drop a
    # load of a value it has just written out.
    #
    # Both backends spill everything: each IR instruction loads its operands out
    # of their slots, computes, and stores the result back. That makes the
    # commonest adjacent pair in the stream a store followed immediately by a
    # load of the same slot, the value never having left the register the store
    # read from. This module is what lets the load go.
    #
    # The safety argument is deliberately crude, because a precise one would need
    # exactly the liveness/aliasing machinery this layer is meant to do without:
    #
    #   **A residency is believed only while not one byte has been emitted since
    #   it was recorded.**
    #
    # No register changes and no slot is written without an instruction, and
    # every instruction reaches the code buffer through the backend's single
    # emit primitive; so "the buffer has not grown" means "nothing has happened
    # to either the registers or memory". That is what makes the aliasing case
    # Step 11 recorded a non-issue here: a store through a pointer may land in
    # any slot whose address was taken, but the store's *own bytes* end every
    # residency in flight, so no reader can be told the slot still matches a
    # register. The same covers calls, atomics and inline stack traffic without
    # any of them being enumerated.
    #
    # Exactly one thing changes the machine state while emitting nothing: an IR
    # :label, where control may arrive from a predecessor whose registers hold
    # something else entirely. A label emits no code, so the buffer-length test
    # cannot see the join, and both backends drop every residency there by hand
    # (#forget_slot_residency). That single exception is the whole of the
    # correctness burden this module places on its includers.
    #
    # The includer must provide `@code` (the ASCII-8BIT buffer being appended
    # to) and must call #reset_slot_residency once per function.
    #
    # Two tables are kept, one per register file, because the files number their
    # registers independently (xmm0 and rax are both register 0). The vector
    # side records the *width* a value was moved at as well: movss and movsd do
    # not leave the same register contents, so a 4-byte residency cannot answer
    # an 8-byte question. The two tables are not independent, though — a slot
    # written from either file invalidates claims on it in both — so every store
    # goes through one method that cleans them together.
    module SlotResidency
      # Begins a function with nothing resident. The code buffer is empty here
      # and no register describes a slot yet.
      def reset_slot_residency
        @resident = {}
        @vector_resident = {}
        @resident_at = nil
      end

      # Drops every residency unconditionally, for the one state change that
      # emits no bytes: a control-flow join (an IR :label).
      def forget_slot_residency
        @resident_at = nil
      end

      # Discards the table when anything has been emitted since it was recorded.
      # Every query below is only meaningful after this has run, and every
      # backend entry point calls it before consulting the table — which is also
      # what stops a later #note_slot_loaded from silently re-validating entries
      # that an intervening instruction invalidated.
      def refresh_slot_residency
        return if @resident_at == @code.bytesize

        @resident.clear
        @vector_resident.clear
        @resident_at = nil
      end

      # Whether `reg` already holds the value of `vreg`'s slot.
      def slot_resident_in?(reg, vreg)
        @resident[reg] == vreg
      end

      # A register already holding `vreg`'s slot value, or nil. Several
      # registers may hold the same slot (a call passing one value twice); any
      # of them will do, and the first found is chosen so the answer stays a
      # function of the instruction stream alone (N4: same input, same bytes).
      def register_holding_slot(vreg)
        @resident.key(vreg)
      end

      # Records that `reg` now holds `vreg`'s slot value, having just been read
      # from that slot (or moved out of another register holding it). Only `reg`
      # was written, so every other entry the table still carries stays true.
      def note_slot_loaded(reg, vreg)
        @resident[reg] = vreg
        @resident_at = @code.bytesize
      end

      # Records that `vreg`'s slot has just been written from `reg`. Any other
      # register that claimed the slot was describing its *old* contents and is
      # now stale, so those claims go first — in the vector file too, since the
      # slot the two files name is the same eight bytes; `reg`'s claim is the
      # one the new contents match.
      def note_slot_stored(reg, vreg)
        drop_claims_on(vreg)
        @resident[reg] = vreg
        @resident_at = @code.bytesize
      end

      # Whether vector register `reg` holds `vreg`'s slot, moved at `size`
      # bytes. The width is part of the question: a movss left the register's
      # upper half zeroed rather than carrying the slot's other four bytes.
      def slot_resident_in_vector?(reg, vreg, size)
        held = @vector_resident[reg]
        held && held[0] == vreg && held[1] == size
      end

      # A vector register holding `vreg`'s slot at `size` bytes, or nil.
      def vector_register_holding_slot(vreg, size)
        @vector_resident.each { |reg, held| return reg if held[0] == vreg && held[1] == size }
        nil
      end

      # The vector-file counterpart of #note_slot_loaded.
      def note_slot_loaded_to_vector(reg, vreg, size)
        @vector_resident[reg] = [vreg, size]
        @resident_at = @code.bytesize
      end

      # The vector-file counterpart of #note_slot_stored.
      def note_slot_stored_from_vector(reg, vreg, size)
        drop_claims_on(vreg)
        @vector_resident[reg] = [vreg, size]
        @resident_at = @code.bytesize
      end

      # Records that the bytes just emitted wrote `reg`, and no slot and no
      # other register. Two shapes take it: a move out of a promoted register
      # (whose value lives in a register of its own rather than in a slot, so no
      # residency ever names it), and an instruction that computes its result
      # straight into a promoted one — where the delete is what drops any claim
      # the staging load recorded against that same register a moment earlier.
      #
      # This and #note_slots_undisturbed are the two ways of keeping a residency
      # alive across an emission without claiming anything new. Both are sound
      # under one condition, in two parts: the table must have been true
      # immediately before those bytes — which #refresh_slot_residency
      # establishes, and so does any note that ran with nothing emitted since —
      # and those bytes must have written nothing the table names beyond what is
      # being dropped here.
      def note_register_clobbered(reg)
        @resident.delete(reg)
        @resident_at = @code.bytesize
      end

      # Records that the bytes just emitted disturbed nothing the table
      # describes at all — a move *into* a promoted register, which no residency
      # can name (see #note_register_clobbered for when this is sound).
      def note_slots_undisturbed
        @resident_at = @code.bytesize
      end

      # Forgets every claim on `vreg`'s slot in both files, for a store about to
      # replace what that slot holds.
      def drop_claims_on(vreg)
        @resident.delete_if { |_reg, held| held == vreg } unless @resident.empty?
        @vector_resident.delete_if { |_reg, held| held[0] == vreg } unless @vector_resident.empty?
      end
    end
  end
end
