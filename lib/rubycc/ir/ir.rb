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
    #   :call   dst <- f(args)  a = callee name (String),
    #                           b = array of argument vregs (left to right)
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
    # `param_count` is the number of parameters; by convention they occupy the
    # first `param_count` virtual registers (0..param_count-1), so the backend
    # can spill the incoming argument registers into their slots.
    class Function
      attr_reader :name, :insts, :vreg_count, :param_count

      def initialize(name, insts, vreg_count, param_count)
        @name = name
        @insts = insts
        @vreg_count = vreg_count
        @param_count = param_count
      end
    end
  end
end
