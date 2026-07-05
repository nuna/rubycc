# frozen_string_literal: true

module Rubycc
  module IR
    # A single three-address instruction over virtual registers.
    #
    #   :const  dst <- a            (a is an immediate Integer)
    #   :copy   dst <- a
    #   :add/:sub/:mul/:div/:mod    dst <- a op b
    #   :neg    dst <- -a
    #   :ret    return a
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
