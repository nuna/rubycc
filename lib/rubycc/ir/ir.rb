# frozen_string_literal: true

module Rubycc
  module IR
    # A single three-address instruction over virtual registers.
    #
    #   :const  dst <- a            (a is an immediate Integer; size == 8 loads a
    #                               full 64-bit immediate for a long/pointer
    #                               constant, otherwise a 32-bit one)
    #   :copy   dst <- a
    #   :add/:sub/:mul             dst <- a op b
    #   :div/:mod                  dst <- a op b   (signed division/remainder)
    #   :udiv/:umod                dst <- a op b   (unsigned division/remainder;
    #                               the backend zeroes edx and uses `div`)
    #   :and/:or/:xor              dst <- a op b   (bitwise)
    #   :shl    dst <- a << b       (logical left shift; b's low byte is the
    #                               shift count, taken from cl by the backend)
    #   :sar    dst <- a >> b       (arithmetic right shift; b's low byte is the
    #                               count. A signed left operand's ">>" lowers to
    #                               :sar so the sign bit is replicated)
    #   :shr    dst <- a >> b       (logical right shift; the unsigned counterpart
    #                               of :sar, chosen when the left operand is an
    #                               unsigned type — the split mirrors :div/:udiv,
    #                               since the machine opcodes differ by sign)
    #   :eq/:ne                    dst <- (a op b) ? 1 : 0   (sign-independent)
    #   :lt/:le/:gt/:ge            dst <- (a op b) ? 1 : 0   (signed compare)
    #   :ult/:ule/:ugt/:uge        dst <- (a op b) ? 1 : 0   (unsigned compare,
    #                               setb/setbe/seta/setae; also used for pointer
    #                               ordering, addresses being unsigned)
    #   :neg    dst <- -a
    #   :sext   dst <- a  (size: 1/2/4)  a's low `size` bytes sign-extended to
    #                               the register's full width. size 4 is a
    #                               movsxd; size 1/2 a movsx of the low byte/word
    #   :zext   dst <- a  (size: 1/2/4)  a's low `size` bytes zero-extended to
    #                               the register's full width. size 4 is a plain
    #                               32-bit mov (which zeroes the upper half);
    #                               size 1/2 a movzx
    #   :ret    return a           (a is nil for a void function's "return;"
    #                              or its implicit fall-off-the-end return,
    #                              which emits no value-loading code at all)
    #   :label        a = label id (a jump target; emits no code itself)
    #   :jump         a = label id (unconditional branch)
    #   :jump_if_zero a = condition vreg, b = label id (branch when a == 0)
    #   :call   dst <- f(args)  a = callee name (String),
    #                           b = array of argument vregs (left to right).
    #                           Arguments past the sixth are passed on the stack
    #                           (System V AMD64), pushed in reverse below the
    #                           first six in registers
    #   :call_indirect dst <- (*a)(args)  a = a vreg holding the function's
    #                           address (a function pointer value), b = the
    #                           argument vregs, passed exactly as for :call. The
    #                           backend calls through a scratch register
    #   :func_addr dst <- &func(a)  dst gets the address of the function named a
    #                           (a String symbol), the value a function
    #                           designator decays to (and "&f" yields); resolved
    #                           by a PC-relative relocation like :global_addr
    #   :addr_of dst <- &slot(a)    dst gets the address of a's stack slot
    #   :object_addr dst <- &object(a)  dst gets the base address of stack
    #                                   object a (an array's first element)
    #   :load   dst <- *a           dst gets `size` bytes read through pointer a,
    #                               sign-extended (a signed char/short read is a
    #                               movsx; size 4/8 a plain mov)
    #   :uload  dst <- *a           like :load but zero-extended (an unsigned
    #                               char/short read is a movzx), for unsigned
    #                               narrow types and _Bool
    #   :store  *a <- b             `size` bytes of b are written through ptr a
    #   :memcpy *a <- *b (size)     `size` bytes are copied from the address in
    #                               b to the address in a (a whole-struct
    #                               assignment "s = t"); both are pointer vregs,
    #                               `size` the struct's byte width
    #   :string_addr dst <- &string(a)  dst gets the address of read-only string
    #                                   a (an id into the translation unit's
    #                                   string pool), i.e. a decayed char *
    #   :global_addr dst <- &global(a)  dst gets the address of the file-scope
    #                                   variable named a (a String symbol name),
    #                                   the lvalue every global read/write and
    #                                   "&g"/array decay is lowered through
    #
    # `dst`, `a`, `b` are virtual register numbers (Integers) unless noted;
    # unused fields are nil. `size` is an operand width in bytes. On :load /
    # :uload / :store it is the memory access width (1 char, 2 short, 4 int,
    # 8 pointer/long). On a binary op (the arithmetic, shift and comparison ops)
    # size == 8 selects 64-bit arithmetic for `long`/`unsigned long`/pointer
    # values and pointer-offset scaling; a nil (or 4) size means the default
    # 32-bit arithmetic, whose natural wrap-around matches a 4-byte C type. On
    # :sext / :zext, `size` is instead the *source* width being extended from.
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
    # `linkage` is :external for an ordinary function (a global symbol the
    # linker can resolve across translation units) or :internal for a `static`
    # one (a file-local symbol, emitted STB_LOCAL so it stays private to this
    # object and never collides with a same-named function elsewhere).
    class Function
      attr_reader :name, :insts, :vreg_count, :param_count, :stack_objects, :linkage

      def initialize(name, insts, vreg_count, param_count, stack_objects, linkage)
        @name = name
        @insts = insts
        @vreg_count = vreg_count
        @param_count = param_count
        @stack_objects = stack_objects
        @linkage = linkage
      end
    end

    # A file-scope variable as laid out by the compiler. `name` is its symbol
    # name, `size` its storage width in bytes and `align` its required
    # alignment (its type size for a scalar/pointer, its element size for an
    # array, its widest member's for a struct). `init` is either nil — a
    # zero-initialized global that lives in .bss — or a GlobalInit: the
    # `size`-byte little-endian image to place in .data together with the
    # relocations that patch pointer slots at link time. `linkage` is :external
    # for an ordinary file-scope variable (a global symbol) or :internal for a
    # `static` one — a file-scope `static`, or a block-scope `static` lowered to
    # a uniquely named file-scope object — emitted STB_LOCAL so it stays private
    # to this object.
    Global = Data.define(:name, :size, :align, :init, :linkage)

    # The materialized initializer of a .data global: `bytes` is its full
    # `size`-byte image (a scalar packed little-endian, an aggregate laid out
    # member/element by member/element, a pointer slot left as eight zeros for a
    # relocation to fill), and `relocations` is the list of GlobalReloc that
    # patch the pointer slots. An all-zero image with no relocations is still a
    # GlobalInit (an explicitly zero-initialized global), distinct from a nil
    # `init` that reserves .bss space.
    GlobalInit = Data.define(:bytes, :relocations)

    # One relocation inside a global's .data image. `offset` is the byte offset
    # of the 8-byte pointer slot within that global. `kind` is :symbol for the
    # address of another file-scope object — `symbol` names it, resolved as an
    # absolute 64-bit address (a "&global" or a decayed global array) — or
    # :string for a string literal, where `string_id` indexes the translation
    # unit's string pool and the compiler resolves it to a .rodata offset. The
    # unused field is nil for each kind.
    GlobalReloc = Data.define(:offset, :kind, :symbol, :string_id)

    # A whole translation unit lowered to IR: its `functions` (an array of
    # Function), the shared read-only string pool `strings` (an array of
    # ASCII-8BIT byte strings, without their NUL terminators, indexed by the id
    # a :string_addr instruction carries) and its `globals` (an array of Global
    # in source order). Identical string contents are pooled once, so the
    # compiler can lay them out in .rodata in this order and resolve each
    # :string_addr to an offset.
    Program = Data.define(:functions, :strings, :globals)
  end
end
