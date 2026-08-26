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
    #   :scaled_add dst <- a + b*size   the address a subscript forms: the
    #                               pointer in a offset by the index in b, that
    #                               index scaled by `size` — the element width,
    #                               which is 1, 2, 4 or 8 and nothing else. The
    #                               computation is always 64-bit, a pointer
    #                               being what it produces, so `size` here names
    #                               the scale rather than the operand width (the
    #                               same reading it has on :load/:store, where
    #                               it is the access width rather than the
    #                               register's). No generator emits it: it is
    #                               what IR::Simplify folds a ":mul index by a
    #                               constant element size" plus the ":add" of
    #                               that to a base into, and both targets have a
    #                               single instruction for it (x86-64's `lea`
    #                               with a SIB scale, AArch64's add with a
    #                               shifted register operand)
    #   :div/:mod                  dst <- a op b   (signed division/remainder)
    #   :udiv/:umod                dst <- a op b   (unsigned division/remainder;
    #                               the backend zeroes edx and uses `div`)
    #   :mulhi  dst <- hi64(a * b)  the unsigned high 64 bits of the 128-bit
    #                               product of two 64-bit values (x86 `mul r64`,
    #                               REX.W F7 /4: rax*b -> rdx:rax, result taken
    #                               from rdx). Used only to synthesize a 128-bit
    #                               (`__int128`) multiply from 64-bit halves; the
    #                               generator pairs it with ordinary :mul (the low
    #                               64) and :add. size is always 8
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
    #   :fadd/:fsub/:fmul/:fdiv    dst <- a op b   (floating arithmetic; size is
    #                               the operand width, 4 for float / 8 for
    #                               double, selecting the ss/sd form). A floating
    #                               "-a" has no op of its own: the generator
    #                               flips the sign bit with an integer :xor
    #                               (0x80000000 / 0x8000000000000000, size 8)
    #   :feq/:fne                   dst <- (a op b) ? 1 : 0   (floating equality;
    #                               size 4/8. NaN-aware: :feq is false and :fne
    #                               true when either operand is NaN)
    #   :flt/:fle/:fgt/:fge         dst <- (a op b) ? 1 : 0   (floating ordering;
    #                               size 4/8. Every one is false when either
    #                               operand is NaN, the backend reversing the
    #                               ucomis operands for :flt/:fle so an unordered
    #                               compare clears the flag)
    #   :itof   dst <- (float)a     integer a converted to a floating value.
    #                               size is the destination float width (4/8);
    #                               b is the [width, signed?] descriptor of the
    #                               integer *source* (an unsigned long source is
    #                               rejected by the generator, so never reaches
    #                               here)
    #   :ftoi   dst <- (int)a       floating a truncated toward zero to an
    #                               integer. size is the float *source* width
    #                               (4/8); b is the [width, signed?] descriptor
    #                               of the integer destination (an unsigned long
    #                               destination is likewise rejected upstream)
    #   :ftof   dst <- a            float<->double width change. size is the
    #                               *source* float width (4 widening to double,
    #                               8 narrowing to float)
    #   :sext   dst <- a  (size: 1/2/4)  a's low `size` bytes sign-extended to
    #                               the register's full width. size 4 is a
    #                               movsxd; size 1/2 a movsx of the low byte/word
    #   :zext   dst <- a  (size: 1/2/4)  a's low `size` bytes zero-extended to
    #                               the register's full width. size 4 is a plain
    #                               32-bit mov (which zeroes the upper half);
    #                               size 1/2 a movzx
    #   :ret    return a           (a is nil for a void function's "return;"
    #                              or its implicit fall-off-the-end return,
    #                              which emits no value-loading code at all).
    #                              `size` is nil for an integer/pointer return
    #                              (the value goes in rax/eax) or 4/8 for a
    #                              floating one, which the backend loads from a's
    #                              slot into xmm0 with movss/movsd, the System V
    #                              register a float/double result is returned in.
    #                              For an in-register struct return `size` is
    #                              instead an IR::AbiPiece array, one per piece
    #                              the target's convention cuts the aggregate
    #                              into (offset, width and kind): a is the address
    #                              of the struct's buffer, and the backend gathers
    #                              each piece into its return register — under
    #                              System V an eightbyte at a time into rax/rdx
    #                              (:gp) or xmm0/xmm1 (:sse8), under AAPCS64 an
    #                              HFA member at a time into v0..v3. A struct the
    #                              convention does not return in registers is not
    #                              returned this way — its callee copies the
    #                              result through the hidden pointer parameter and
    #                              returns that pointer too (a plain size-nil :ret)
    #   :label        a = label id (a jump target; emits no code itself)
    #   :jump         a = label id (unconditional branch)
    #   :jump_if_zero a = condition vreg, b = label id (branch when a == 0)
    #   :call   dst <- f(args)  a = callee name (String),
    #                           b = array of [arg_vreg, kind] pairs (left to
    #                           right). `kind` gives each argument's System V
    #                           AMD64 placement, which the generator has already
    #                           fixed over the whole argument list (so a Phase B
    #                           struct can apply the all-or-nothing overflow rule
    #                           where every argument's type is known): :gp takes
    #                           the next integer register (edi,esi,edx,ecx,r8d,r9d),
    #                           :sse4 (float) / :sse8 (double) the next xmm
    #                           (xmm0..7, loaded from the slot with movss/movsd),
    #                           and :mem a stack eightbyte. The backend follows the
    #                           kind verbatim — it assigns registers in order and
    #                           pushes the :mem arguments in reverse so the first
    #                           lands at the lowest address (an eightbyte each, the
    #                           slot's low bits carrying its value). A by-value
    #                           struct argument fans out into one [vreg, kind] pair
    #                           per piece its convention cuts it into (a System V
    #                           eightbyte's class :gp/:sse8, an AAPCS64 HFA
    #                           member's :sse4/:sse8, or :mem per eightbyte when it
    #                           spills whole), all placed together so the argument
    #                           stays in registers or spills as a unit; an
    #                           aggregate AAPCS64 passes by reference is reduced by
    #                           the generator to a single :gp pointer to a
    #                           caller-made copy, so no backend needs a rule of its
    #                           own for it. One further kind appears only in a
    #                           variadic call's variable part: :sse16 takes the next
    #                           vector register as a whole 16-byte value (AAPCS64's
    #                           quad-precision `long double`), and its pair's vreg
    #                           carries the *address* of that value rather than the
    #                           value, no 8-byte slot being able to hold one — the
    #                           backend loads the register from there. The same
    #                           argument on System V is X87/X87UP-classed and so
    #                           travels as two ordinary :mem eightbytes instead, and
    #                           :sse16 never reaches that backend. A call whose struct result comes back
    #                           through a hidden pointer also prepends that
    #                           [vreg, kind] pointer as the first argument. `size` is nil, or a
    #                           [fixed, ret] pair when either half is non-nil:
    #                           `fixed` is the callee's fixed parameter count for a
    #                           variadic call (else nil), which makes the backend
    #                           set al to the count of xmm registers it used before
    #                           the call, as the ABI requires; `ret` is :sse4/:sse8
    #                           when the result is a float/double (loaded from xmm0
    #                           with movss/movsd into dst's slot), a
    #                           [buffer_vreg, pieces] pair when the result is a
    #                           struct returned in registers (dst is nil and the
    #                           backend scatters each IR::AbiPiece from its return
    #                           register — rax/rdx or xmm0/xmm1 under System V,
    #                           x0/x1 or v0..v3 under AAPCS64 — into the buffer
    #                           buffer_vreg points at), else nil (the result comes
    #                           back in the integer result register as usual)
    #   :call_indirect dst <- (*a)(args)  a = a vreg holding the function's
    #                           address (a function pointer value), b = the
    #                           [arg_vreg, kind] pairs (the same generator-fixed
    #                           :gp/:sse4/:sse8/:mem placement as :call); `size`
    #                           carries the same [fixed, ret] pair.
    #                           The backend calls through a scratch register
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
    #   :got_addr dst <- &symbol(a) via GOT  dst gets the address of the
    #                               file-scope object or function named a (a
    #                               String symbol), loaded from its Global Offset
    #                               Table slot rather than formed PC-relatively.
    #                               The generator emits it in place of
    #                               :global_addr / :func_addr only under -fPIC,
    #                               and only for a symbol this translation unit
    #                               does not define, so a definition in another
    #                               shared object may interpose; the backend reads
    #                               the slot with "mov rax, [rip+disp32]" and the
    #                               linker fills the disp with an
    #                               R_X86_64_REX_GOTPCRELX relocation against the
    #                               symbol. A symbol defined here keeps the
    #                               PC-relative :global_addr / :func_addr form,
    #                               being always resolved within this DSO
    #   :va_start                   a = a vreg holding the address of a
    #                               __va_list_tag, b = the enclosing function's
    #                               fixed (named) parameter count. Initializes the
    #                               target's va_list fields (the four System V ones
    #                               gp_offset/fp_offset/overflow_arg_area/reg_save_area,
    #                               or the five AAPCS64 ones __stack/__gr_top/
    #                               __vr_top/__gr_offs/__vr_offs) so a later
    #                               __builtin_va_arg reads the variable arguments;
    #                               the backend fills them from the register-save
    #                               area its variadic prologue set up, deriving the
    #                               named GP and SSE counts (which seed the offsets
    #                               and the overflow/stack start) from
    #                               Function.param_kinds rather than from b.
    #                               va_arg/va_end/va_copy need no IR op of their
    #                               own — the generator lowers them to ordinary
    #                               load/store/branch (and, for va_copy, :memcpy)
    #                               instructions
    #   :alloca dst <- alloca(a)    a = a vreg holding a byte count; dst gets the
    #                               base address of that many bytes of automatic
    #                               storage carved from the stack (__builtin_alloca).
    #                               The backend rounds the count up to a 16-byte
    #                               multiple and subtracts it from the stack pointer,
    #                               so that stays 16-aligned and the block is 16-byte
    #                               aligned; the storage is reclaimed wholesale when
    #                               the function returns, not at end of scope. What
    #                               makes the moving stack pointer safe differs by
    #                               target: x86-64 addresses every other value from
    #                               rbp already, while aarch64 is sp-relative and so
    #                               anchors the frame of an alloca-using function in
    #                               x29 for the duration (see backend/aarch64.rb)
    #   :bit_scan dst <- scan(a)    counts the zero bits of the integer in vreg a,
    #                               for __builtin_ctz/clz (and their "ll" forms).
    #                               b is the direction — :forward for a trailing
    #                               count (ctz), :reverse for a leading count
    #                               (clz) — and `size` the operand width (4 or 8).
    #                               x86-64 lowers :forward to `bsf` and :reverse
    #                               to `bsr` followed by `xor` with (size*8 - 1),
    #                               so clz = (width-1) - bsr; a size-8 scan takes
    #                               a REX.W prefix. AArch64 lowers :reverse to a
    #                               bare `clz` and :forward to `rbit` ahead of
    #                               one, at the W or X width `size` names. A zero
    #                               operand is undefined (as in gcc), so no zero
    #                               case is emitted. The result is an int
    #   :popcount dst <- ones(a)    counts the set bits of the integer in vreg a,
    #                               for __builtin_popcount (and its "l"/"ll"
    #                               forms); `size` is the operand width (4 or 8)
    #                               and b is unused. Every operand value is
    #                               defined, zero included. Neither backend uses
    #                               a hardware population count — x86-64's
    #                               `popcnt` is an SSE4.2 instruction the
    #                               baseline does not have, and aarch64's `cnt`
    #                               is an AdvSIMD one over a vector register —
    #                               so both expand the same divide-and-conquer
    #                               (SWAR) sum of bit fields, described in
    #                               backend/x86_64.rb#emit_popcount. The result
    #                               is an int
    #
    # The five atomic ops below lower gcc's __atomic_* builtins. Every one is
    # sequentially consistent — the IR carries no memory order at all, because
    # the generator lowers every order the source asked for at the strongest one
    # (strengthening an order is always sound; see #gen_builtin_atomic). `size`
    # is the access width and is only ever 4 or 8: the generator diagnoses every
    # other width, so no backend needs a narrower or wider case.
    #
    #   :atomic_fence                  a sequentially-consistent memory fence
    #   :atomic_load dst <- atomic *a   dst gets `size` bytes read atomically
    #                               through pointer a, with sequentially
    #                               consistent ordering. Distinct from :load
    #                               because the two targets differ: on x86-64 an
    #                               aligned mov already is a seq_cst load, while
    #                               aarch64 needs the acquire form (ldar)
    #   :atomic_store *a <- b       `size` bytes of b are written atomically
    #                               through pointer a, sequentially consistently.
    #                               x86-64 uses `xchg` (whose implicit lock
    #                               supplies the trailing fence a seq_cst store
    #                               needs), aarch64 `stlr`
    #   :atomic_rmw dst <- rmw(a, b)  an atomic read-modify-write through pointer
    #                               a. b is a [value_vreg, kind] pair; `kind` is
    #                               :exchange, :fetch_add, :fetch_sub,
    #                               :add_fetch, :sub_fetch or :or_fetch. dst gets
    #                               the value the corresponding builtin returns —
    #                               the value read for :exchange and the
    #                               :fetch_* forms, the value stored for the
    #                               :*_fetch ones — and may be nil when the
    #                               result is discarded
    #   :atomic_cas dst <- cas(a, b)  an atomic compare-and-exchange through
    #                               pointer a, for __atomic_compare_exchange_n.
    #                               b is an [expected_ptr_vreg, desired_vreg]
    #                               pair. If *a equals *expected_ptr, *a becomes
    #                               desired and dst gets 1; otherwise *a is
    #                               untouched, the value actually read is stored
    #                               back through expected_ptr — a side effect
    #                               callers depend on — and dst gets 0. The
    #                               write-back happens only on the failing path,
    #                               so a caller whose expected_ptr aliases a sees
    #                               the exchanged value rather than a stale one.
    #                               dst is a _Bool (0/1) and is never nil
    #
    # `dst`, `a`, `b` are virtual register numbers (Integers) unless noted;
    # unused fields are nil. `size` is an operand width in bytes. On :load /
    # :uload / :store it is the memory access width (1 char, 2 short, 4 int,
    # 8 pointer/long). On a binary op (the arithmetic, shift and comparison ops)
    # size == 8 selects 64-bit arithmetic for `long`/`unsigned long`/pointer
    # values and pointer-offset scaling; a nil (or 4) size means the default
    # 32-bit arithmetic, whose natural wrap-around matches a 4-byte C type. On
    # :sext / :zext, `size` is instead the *source* width being extended from.
    # On the floating ops (:fadd..:fge) `size` is the floating operand width
    # (4 float / 8 double); on :itof it is the destination float width, on :ftoi
    # and :ftof the *source* float width, with the paired integer width carried
    # in `b` as a [width, signed?] descriptor for :itof / :ftoi.
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
    # `param_count` is the number of ABI argument slots, not the number of C
    # parameters: a scalar parameter is one slot, a by-value struct parameter one
    # per piece its convention cuts it into, and the hidden result pointer of a
    # function whose result does not come back in registers an extra leading
    # slot. Those slots occupy
    # the first `param_count` virtual registers (0..param_count-1) in that order,
    # so the backend can spill the incoming argument registers into them; the
    # generator then reassembles a struct parameter's slots into a stack object.
    # `param_kinds` is an array of length `param_count` giving each slot's arrival
    # under the *target's* calling convention (IR::CallConvention), in that
    # flattened order, which the generator has fixed by the same placement
    # simulation a call's arguments use: :gp (integer register), :sse4 (float
    # vector register), :sse8 (double vector register — also each eightbyte of a
    # struct arriving in one, and each member of an AAPCS64 HFA of doubles) or
    # :mem (the stack overflow area). How many registers there are to hand out
    # before a scalar spills to :mem, and how an aggregate is cut into slots at
    # all, are the target's business — which is why the tags are fixed here and
    # not by a backend: System V AMD64 offers six integer registers and AAPCS64
    # eight, and struct { float a, b; } is one :sse8 slot on the first and two
    # :sse4 slots on the second, so the same C call classifies differently on the
    # two. One further kind names a mechanism only some conventions have: an
    # :indirect_result slot is the implicit pointer to a caller-provided result
    # buffer when the convention reserves a register of its own for it (AAPCS64's
    # x8). An aggregate passed by reference needs no kind of its own — the
    # generator reduces it to an ordinary :gp pointer to a caller-made copy. The
    # prologue
    # spills each slot straight from its location, and a variadic function derives
    # its gp_offset / fp_offset / overflow start for :va_start from the counts of
    # each kind.
    # `stack_objects` is an array indexed by object id whose entries are the
    # byte sizes of aggregate stack objects (arrays); the backend lays these
    # out below the virtual-register slots and resolves :object_addr against
    # them.
    # `linkage` is :external for an ordinary function (a global symbol the
    # linker can resolve across translation units) or :internal for a `static`
    # one (a file-local symbol, emitted STB_LOCAL so it stays private to this
    # object and never collides with a same-named function elsewhere).
    # `variadic` is true for a "..."-terminated definition, which makes the
    # backend emit a register-save-area prologue so :va_start / __builtin_va_arg
    # can reach the variable arguments; a fixed-arity function leaves it false.
    class Function
      attr_reader :name, :insts, :vreg_count, :param_count, :stack_objects, :linkage, :variadic, :param_kinds

      def initialize(name, insts, vreg_count, param_count, stack_objects, linkage, variadic, param_kinds)
        @name = name
        @insts = insts
        @vreg_count = vreg_count
        @param_count = param_count
        @stack_objects = stack_objects
        @linkage = linkage
        @variadic = variadic
        @param_kinds = param_kinds
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
    # unused field is nil for each kind. `addend` is a constant byte displacement
    # added to the base address (0 for a bare "&global" or string, non-zero for a
    # computed address constant such as "&arr[i]", "arr + n" or "&rec.member");
    # it becomes the R_X86_64_64 relocation's r_addend.
    GlobalReloc = Data.define(:offset, :kind, :symbol, :string_id, :addend) do
      def initialize(offset:, kind:, symbol:, string_id:, addend: 0)
        super
      end
    end

    # One entry this translation unit contributes to an initializer/finalizer
    # array. `symbol` names a function *defined here* that the runtime is to
    # call: `kind` is :init for a constructor (the loader calls it before main,
    # or at dlopen) or :fini for a destructor (at exit, or at dlclose), and
    # `priority` is its run-order number, the compiler's
    # ELFWriter::DEFAULT_ARRAY_PRIORITY standing for the unnumbered form. The
    # compiler turns each entry into an 8-byte slot in the matching
    # SHT_INIT_ARRAY / SHT_FINI_ARRAY section plus an absolute 64-bit relocation
    # against `symbol`.
    ArrayEntry = Data.define(:kind, :priority, :symbol)

    # A whole translation unit lowered to IR: its `functions` (an array of
    # Function), the shared read-only string pool `strings` (an array of
    # ASCII-8BIT byte strings, without their NUL terminators, indexed by the id
    # a :string_addr instruction carries), its `globals` (an array of Global
    # in source order) and its `array_entries` (an array of ArrayEntry, empty for
    # a unit with no constructor/destructor). Identical string contents are
    # pooled once, so the compiler can lay them out in .rodata in this order and
    # resolve each :string_addr to an offset.
    Program = Data.define(:functions, :strings, :globals, :array_entries, :visibility) do
      def initialize(functions:, strings:, globals:, array_entries: [], visibility: {})
        super
      end
    end
  end
end
