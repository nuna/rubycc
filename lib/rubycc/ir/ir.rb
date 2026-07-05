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
    #   :sext   dst <- a            (a's 32-bit value sign-extended to 64 bits)
    #   :ret    return a
    #   :label        a = label id (a jump target; emits no code itself)
    #   :jump         a = label id (unconditional branch)
    #   :jump_if_zero a = condition vreg, b = label id (branch when a == 0)
    #   :call   dst <- f(args)  a = callee name (String),
    #                           b = array of argument vregs (left to right)
    #   :addr_of dst <- &slot(a)    dst gets the address of a's stack slot
    #   :object_addr dst <- &object(a)  dst gets the base address of stack
    #                                   object a (an array's first element)
    #   :load   dst <- *a           dst gets `size` bytes read through pointer a
    #   :store  *a <- b             `size` bytes of b are written through ptr a
    #
    # `dst`, `a`, `b` are virtual register numbers (Integers) unless noted;
    # unused fields are nil. `size` is an operand width in bytes. On :load /
    # :store it is the memory access width (4 for an int, 8 for a pointer). On a
    # binary op (:add/:sub/:mul/:div and the comparisons) size == 8 selects
    # 64-bit arithmetic for pointer values and pointer-offset scaling; a nil (or
    # 4) size means the default 32-bit `int` arithmetic.
    class Instruction
      attr_reader :op, :dst, :a, :b, :size

      def initialize(op, dst: nil, a: nil, b: nil, size: nil)
        @op = op
        @dst = dst
        @a = a
        @b = b
        @size = size
      end

      def inspect
        "#<IR #{op} dst=#{dst.inspect} a=#{a.inspect} b=#{b.inspect} size=#{size.inspect}>"
      end
    end

    # A function in IR form: a name, a flat list of instructions and the number
    # of virtual registers used (so the backend can size its stack frame).
    # `param_count` is the number of parameters; by convention they occupy the
    # first `param_count` virtual registers (0..param_count-1), so the backend
    # can spill the incoming argument registers into their slots.
    # `stack_objects` is an array indexed by object id whose entries are the
    # byte sizes of aggregate stack objects (arrays); the backend lays these
    # out below the virtual-register slots and resolves :object_addr against
    # them.
    class Function
      attr_reader :name, :insts, :vreg_count, :param_count, :stack_objects

      def initialize(name, insts, vreg_count, param_count, stack_objects)
        @name = name
        @insts = insts
        @vreg_count = vreg_count
        @param_count = param_count
        @stack_objects = stack_objects
      end
    end
  end
end
