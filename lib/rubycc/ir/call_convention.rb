# frozen_string_literal: true

module Rubycc
  module IR
    # The part of a target's calling convention the IR generator has to know
    # about, so that where every argument lands is decided once — where the
    # argument's C type is still in hand — rather than guessed at by a backend
    # that only sees a tag.
    #
    # The generator classifies each argument into a candidate kind (:gp, :sse4,
    # :sse8) and then walks the argument list handing out registers until a
    # class runs out, at which point the rest spill to the stack (:mem). Only
    # two things about that walk are target-specific for scalars, and they are
    # the two numbers below: how many integer registers the convention offers
    # (System V AMD64 has six — rdi, rsi, rdx, rcx, r8, r9 — while AAPCS64 has
    # eight, x0..x7) and how many vector ones (eight on both). Getting them from
    # the target rather than hard-coding System V is what lets a seventh integer
    # argument reach x6 on aarch64 instead of arriving tagged for the stack.
    #
    # Aggregates are *not* abstracted here. The generator classifies a struct by
    # the System V eightbyte rules whatever the target, which AAPCS64 agrees
    # with for the cases it currently reaches (an aggregate of 16 bytes or less
    # takes consecutive registers, and spills whole to the stack in 8-byte units
    # when they run out). Where the two conventions genuinely part ways is a
    # struct too large for registers: System V copies it into the stack argument
    # area, AAPCS64 passes a pointer to a caller-made copy and returns one
    # through the dedicated x8. Those slots are therefore tagged with kinds of
    # their own — `memory_aggregate_kind` for each eightbyte of such an
    # argument, `hidden_result_kind` for the implicit result-buffer pointer — so
    # a target that has not implemented its own rule refuses them by name
    # instead of silently laying them out by the other convention's.
    class CallConvention
      # `gp_registers` / `fp_registers` are the counts of integer and vector
      # argument registers. `memory_aggregate_kind` tags the eightbytes of an
      # aggregate the convention passes in memory and `hidden_result_kind` the
      # implicit pointer to a caller-provided result buffer; on System V both
      # are ordinary placements (a stack eightbyte and an integer register), on
      # AAPCS64 both are their own mechanism.
      attr_reader :gp_registers, :fp_registers, :memory_aggregate_kind, :hidden_result_kind

      def initialize(gp_registers:, fp_registers:, memory_aggregate_kind: :mem, hidden_result_kind: :gp)
        @gp_registers = gp_registers
        @fp_registers = fp_registers
        @memory_aggregate_kind = memory_aggregate_kind
        @hidden_result_kind = hidden_result_kind
        freeze
      end

      # System V AMD64 (psABI 3.2.3): six integer registers and eight SSE ones,
      # a MEMORY-classified aggregate laid into the stack argument area, and a
      # MEMORY result reached through a hidden pointer passed as an ordinary
      # leading integer argument.
      SYSTEM_V_AMD64 = new(gp_registers: 6, fp_registers: 8)

      # AAPCS64: eight integer registers (x0..x7) and eight vector ones
      # (v0..v7). A large aggregate travels by reference and a large result
      # through the indirect result register x8, neither of which the aarch64
      # backend lowers yet, so both get a kind it can refuse.
      AAPCS64 = new(gp_registers: 8, fp_registers: 8,
                    memory_aggregate_kind: :indirect, hidden_result_kind: :indirect_result)
    end
  end
end
