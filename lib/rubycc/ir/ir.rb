# frozen_string_literal: true

module Rubycc
  module IR
    # A single three-address instruction over virtual registers.
    #
    #   :const  dst <- a            (a is an immediate Integer)
    #   :copy   dst <- a
    #   :add/:sub/:mul/:div/:mod    dst <- a op b
    #   :eq/:ne/:lt/:le/:gt/:ge     dst <- (a op b) ? 1 : 0
    #   :neg    dst <- -a
    #   :ret    return a
    #   :label        a = label id (a jump target; emits no code itself)
    #   :jump         a = label id (unconditional branch)
    #   :jump_if_zero a = condition vreg, b = label id (branch when a == 0)
    #
    # `dst`, `a`, `b` are virtual register numbers (Integers) unless noted;
    # unused fields are nil.
    class Instruction
      attr_reader :op, :dst, :a, :b

      def initialize(op, dst: nil, a: nil, b: nil)
        @op = op
        @dst = dst
        @a = a
        @b = b
      end

      def inspect
        "#<IR #{op} dst=#{dst.inspect} a=#{a.inspect} b=#{b.inspect}>"
      end
    end

    # A function in IR form: a name, a flat list of instructions and the number
    # of virtual registers used (so the backend can size its stack frame).
    class Function
      attr_reader :name, :insts, :vreg_count

      def initialize(name, insts, vreg_count)
        @name = name
        @insts = insts
        @vreg_count = vreg_count
      end
    end
  end
end
