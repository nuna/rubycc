# frozen_string_literal: true

require_relative "ir"
require_relative "call_convention"
require_relative "../front/ast"
require_relative "../front/constant_evaluator"
require_relative "../front/initializer_resolver"
require_relative "../type"
require_relative "../compile_error"

module Rubycc
  module IR
    # Lowers the AST into IR. A straightforward post-order walk that allocates a
    # fresh virtual register for every computed value, tracking each
    # expression's static type so pointer operations can be type-checked and
    # lowered. No optimization.
    class Generator
      # A declared variable's binding and its declared Rubycc::Type. When
      # `global` is false it is a local: `storage` is a virtual-register number
      # for a scalar (int or pointer) and a stack object id for an array, which
      # one following from `type.array?`. When `global` is true it is a
      # file-scope variable and `storage` is its symbol name (a String), whose
      # address :global_addr materializes. `const` records whether the object is
      # top-level const-qualified, so a write to it (a plain assignment, a
      # compound assignment or "++"/"--") is diagnosed as writing a read-only
      # variable; reads and "&" are unaffected.
      Local = Data.define(:type, :storage, :global, :const)

      # The merged state of a file-scope object's tentative/real definitions
      # (6.9.2), one per name in @object_records. `type` and `linkage` are the
      # agreed type and linkage of the run, `initialized` records whether any
      # declaration has supplied an initializer (so a second one is a
      # redefinition), and `index` locates the object's single IR::Global entry in
      # @globals, which an initializer arriving after a tentative .bss definition
      # rewrites in place to .data. Mutable, since a later declaration in the run
      # updates it.
      ObjectRecord = Struct.new(:type, :linkage, :initialized, :index)

      # A folded address constant (ISO C 6.6): a base object plus a constant byte
      # displacement, the form a pointer global's initializer must reduce to.
      # `base_kind` is :symbol (a file-scope object named by `symbol`), :string
      # (an interned string literal indexed by `string_id`), or :absolute (no
      # object at all — `symbol` and `string_id` are nil and `offset` is the raw
      # bit pattern, from a pointer cast of an integer constant such as
      # "(dfree_t)-1"); `offset` is the byte displacement past that base for
      # :symbol/:string (accumulated from subscripts, member accesses and
      # pointer arithmetic), or the absolute value itself for :absolute;
      # `pointee` is the type of the object presently at base+offset, so a
      # further subscript or "+ n" knows how many bytes one step spans (and a
      # cast overrides it without moving the address).
      AddressConstant = Data.define(:base_kind, :symbol, :string_id, :offset, :pointee)

      # Raised while folding an initializer that is not an address constant this
      # subset admits (a run-time value, a non-constant index, an unsupported
      # form). Caught at #pack_global_pointer, which turns it into the same
      # "unsupported initializer" diagnostic a scalar global gives.
      class NotAddressConstant < StandardError; end

      # `plain_char` is the Rubycc::Type of a plain `char` on the target being
      # generated for, matching what the parser resolved the `char` specifier to.
      # The generator needs it because a string literal's type is written here
      # rather than by the parser: its element type is plain `char` (6.4.5p6), so
      # a byte read out of one sign- or zero-extends following the target's
      # plain-char signedness. It defaults to the signed instance, the x86-64
      # System V choice, for a caller with no target in hand.
      #
      # `convention` is the target's CallConvention, which fixes how many
      # registers an argument list may draw on before it spills to the stack.
      # It defaults to System V AMD64 for the same reason `plain_char` does.
      def initialize(plain_char: Type::Char, convention: CallConvention::SYSTEM_V_AMD64)
        @plain_char = plain_char
        @convention = convention
      end

      # Returns an IR::Program: an IR::Function per AST::FunctionDef plus the
      # translation unit's read-only string pool. Prototypes
      # (AST::FunctionDecl) contribute only a signature-table entry and emit no
      # code. The table is filled in source order so a definition can reference
      # itself (recursion) or an earlier prototype (mutual recursion), while a
      # call to a still-unknown name is diagnosed as an implicit declaration.
      def generate(program, pic: false)
        # Position-independent code mode (-fPIC): when set, a reference that takes
        # the address of a file-scope object or function this translation unit
        # does not itself define is lowered through the Global Offset Table
        # (:got_addr) instead of a PC-relative :global_addr / :func_addr, so a
        # definition in another shared object can interpose on it. A symbol
        # defined here, a `static`, and a string literal keep the PC-relative
        # form. When false the lowering is byte-for-byte the non-PIC one.
        @pic = pic
        # name -> { param_types:, return_type:, variadic:, defined: }.
        # `param_types` is the array of parameter Rubycc::Types (its length being
        # the fixed arity — for a variadic function, only the named parameters);
        # `return_type` is the declared Rubycc::Type of a call to this function;
        # `variadic` is true for a "..."-terminated prototype (its calls admit
        # extra, promoted arguments past the fixed ones); `defined` distinguishes
        # a prototype from a completed definition so redefinitions can be
        # rejected.
        @signatures = {}
        # gcc provides memcpy as a builtin, and the parser rewrites
        # __builtin_memcpy(...) into a plain call to "memcpy". Seed its prototype
        # up front — void *memcpy(void *, const void *, unsigned long) — so such a
        # call compiles even when the translation unit never declares memcpy (no
        # <string.h>); a later, identical string.h prototype merges in without
        # conflict, and the reference resolves to libc's memcpy at link time.
        @signatures["memcpy"] = {
          param_types: [Type::Pointer.new(Type::Void), Type::Pointer.new(Type::Void), Type::ULong],
          return_type: Type::Pointer.new(Type::Void),
          variadic: false,
          defined: false
        }
        # The translation-unit-wide string pool: `@strings` holds each interned
        # byte string in id order, `@string_ids` maps content back to its id so
        # identical literals collapse to one entry (and one .rodata address).
        @strings = []
        @string_ids = {}
        # File-scope variables: `@global_bindings` maps each name to its Local
        # binding (the outermost scope every function shares), while `@globals`
        # holds the IR::Global descriptors in source order for the compiler to
        # lay out into .data/.bss.
        @global_bindings = {}
        @globals = []
        # File-scope objects that reserve storage, keyed by name: each ObjectRecord
        # tracks the merged state of a run of tentative/real definitions (6.9.2) —
        # its type, linkage, whether any declaration has initialized it, and the
        # index of its single IR::Global entry. A bare `extern` reference reserves
        # nothing and gets no record. A repeated declaration merges into the
        # record (types must agree); a second *initialized* definition is the real
        # redefinition error, and an object emitted tentatively in .bss is upgraded
        # in place to .data when a later declaration supplies an initializer.
        @object_records = {}
        # A monotonic counter that names each block-scope `static` uniquely as
        # "<var>.<n>". A '.' cannot appear in a C identifier, so these names
        # never collide with a real symbol; the counter runs over the whole
        # translation unit in source order, keeping the output deterministic (N4).
        @static_local_count = 0
        ir_functions = []
        # Declarations are processed in source order, so a function may only
        # reference a global or callee already declared above it (C's
        # declaration-before-use rule), and a name reused across the global and
        # function namespaces is rejected as a redefinition.
        program.functions.each do |decl|
          case decl
          when Front::AST::GlobalDecl
            declare_global(decl)
          when Front::AST::FunctionDecl
            # A prototype's storage class (`static`/`extern`) is recorded on the
            # AST but drives no behavior here: a declaration reserves nothing and
            # M1 does not diagnose a static/extern mismatch against the eventual
            # definition, so a prototype only contributes a signature.
            declare_function(decl.name, decl.return_type, decl.params.map(&:type),
                             variadic: decl.variadic, defined: false, token: decl.token)
          when Front::AST::FunctionDef
            declare_function(decl.name, decl.return_type, decl.params.map(&:type),
                             variadic: decl.variadic, defined: true, token: decl.token)
            # `static` gives the definition internal linkage (an STB_LOCAL text
            # symbol); an absent or `extern` specifier leaves it external.
            linkage = decl.storage == :static ? :internal : :external
            ir_functions << gen_function(decl, linkage)
          end
        end
        Program.new(ir_functions, @strings, @globals)
      end

      private

      # Records a file-scope variable. A name already taken by a function is a
      # redefinition. The storage class then steers the outcome:
      #   * `extern` is a reference declaration — it registers the binding (so
      #     later code sees the name and its type) but reserves no storage, and
      #     any number may coexist with each other and with one real definition;
      #   * an absent or `static` specifier is a *definition*, tentative when it
      #     has no initializer (6.9.2): a run of such declarations of one name
      #     merges into a single object, at most one of them initializing it.
      # Whenever a binding already exists (from an earlier reference or
      # definition), the two must agree on type.
      def declare_global(decl)
        if @signatures.key?(decl.name)
          error_at(decl.token, "redefinition of '#{decl.name}'")
        end
        # Resolve the initializer first: a "[]" array bound is only known once
        # its initializer has been walked, so the final type (and thus the
        # storage size) may differ from the declared one. An uninitialized global
        # keeps its declared type and lands in .bss (a nil init).
        type = decl.type
        init = nil
        has_init = false
        if decl.initializer_node
          type, init = build_global_init(type, decl.initializer_node, decl.token)
          has_init = true
        elsif !decl.initializer_value.nil?
          init = GlobalInit.new(bytes: pack_integer(decl.initializer_value, type.size), relocations: [])
          has_init = true
        end
        # A global needs a known storage width and boundary, so an incomplete
        # struct/enum (a tag never defined) cannot be laid out in .bss/.data —
        # and an `extern` reference likewise needs a concrete type to bind here.
        require_complete(type, decl.token)

        if decl.storage == :extern
          declare_extern_global(decl, type)
        else
          merge_object_definition(decl, type, init, has_init)
        end
      end

      # An `extern` reference declaration: it binds the name (once) with no
      # storage, agreeing in type with any binding already present. A real
      # definition, before or after, supplies the object; if none does, a use of
      # the name becomes an undefined symbol for the linker.
      def declare_extern_global(decl, type)
        existing = @global_bindings[decl.name]
        if existing && existing.type != type
          error_at(decl.token, "conflicting types for '#{decl.name}'")
        end
        @global_bindings[decl.name] ||=
          Local.new(type: type, storage: decl.name, global: true, const: decl.const)
      end

      # Merges one non-extern (tentative or real) file-scope definition into the
      # object's record (6.9.2). The first such declaration reserves the object —
      # .data if it initializes, else a tentative .bss object; a later declaration
      # of the same name must agree in type and linkage, may add the one allowed
      # initializer (upgrading a tentative .bss object to .data in place), and a
      # second initializer is the redefinition error.
      def merge_object_definition(decl, type, init, has_init)
        linkage = decl.storage == :static ? :internal : :external
        existing = @global_bindings[decl.name]
        if existing && existing.type != type
          error_at(decl.token, "conflicting types for '#{decl.name}'")
        end

        record = @object_records[decl.name]
        if record
          reject_linkage_mismatch(decl, record.linkage, linkage)
          upgrade_tentative_global(decl, type, init, linkage, record) if has_init
          return
        end

        index = @globals.length
        @globals << Global.new(name: decl.name, size: type.size, align: type.alignment,
                               init: init, linkage: linkage)
        @object_records[decl.name] = ObjectRecord.new(type, linkage, has_init, index)
        @global_bindings[decl.name] = Local.new(type: type, storage: decl.name, global: true, const: decl.const)
      end

      # Applies the initializer of a real definition arriving after one or more
      # tentative ones: a second initialized definition is a redefinition, and the
      # first rewrites the tentative .bss IR::Global in place to the initialized
      # .data form (and refreshes the binding, since an initializer may have
      # completed an inferred array bound).
      def upgrade_tentative_global(decl, type, init, linkage, record)
        error_at(decl.token, "redefinition of '#{decl.name}'") if record.initialized

        record.initialized = true
        record.type = type
        @globals[record.index] = Global.new(name: decl.name, size: type.size,
                                             align: type.alignment, init: init, linkage: linkage)
        @global_bindings[decl.name] = Local.new(type: type, storage: decl.name, global: true, const: decl.const)
      end

      # Diagnoses a static/non-static disagreement across the declarations of one
      # file-scope object (6.2.2): the run must settle on a single linkage.
      def reject_linkage_mismatch(decl, prior, current)
        return if prior == current

        if current == :internal
          error_at(decl.token, "static declaration of '#{decl.name}' follows non-static declaration")
        else
          error_at(decl.token, "non-static declaration of '#{decl.name}' follows static declaration")
        end
      end

      # Materializes a global's deferred initializer into [final_type,
      # GlobalInit]. A structural initializer (a brace list, or a string for a
      # char array) is resolved and each placement packed into the byte image; a
      # bare pointer initializer is an address constant. The image starts all
      # zeros, so any byte the initializer leaves unset — struct padding, an
      # array's tail, a string's NUL — is already zero (6.7.9p10/p21).
      def build_global_init(type, node, token)
        if Front::InitializerResolver.structural?(type, node)
          resolved = Front::InitializerResolver.resolve(type, node)
          final_type = resolved.type
          require_complete(final_type, token)
          image = "\0".b * final_type.size
          relocations = []
          resolved.entries.each { |entry| pack_global_entry(entry, image, relocations) }
          [final_type, GlobalInit.new(bytes: image, relocations: relocations)]
        else
          require_complete(type, token)
          image = "\0".b * type.size
          relocations = []
          pack_global_scalar(0, type, node, image, relocations)
          [type, GlobalInit.new(bytes: image, relocations: relocations)]
        end
      end

      # Writes one resolved placement into a global's image: a scalar folded (or
      # relocated, for a pointer) into its slot, or a string literal's bytes
      # copied verbatim (the surrounding zeros supply its NUL and any padding).
      def pack_global_entry(entry, image, relocations)
        case entry
        when Front::ScalarInit
          pack_global_scalar(entry.offset, entry.type, entry.value, image, relocations)
        when Front::StringInit
          image[entry.offset, entry.bytes.bytesize] = entry.bytes.b
        end
      end

      # Packs one scalar slot of a global. An integer/_Bool slot is folded to a
      # constant and stored little-endian; a pointer slot is an address constant
      # (see #pack_global_pointer). Any other slot type has no constant form.
      def pack_global_scalar(offset, type, value, image, relocations)
        reject_file_scope_compound_literal(value)
        if type.integer?
          # A floating constant assigned to an integer global truncates toward
          # zero (6.3.1.4); every other integer initializer folds as an integer
          # constant expression.
          folded = floating_constant?(value) ? fold_global_float(value).to_i : fold_global_constant(value)
          image[offset, type.size] = pack_integer(folded, type.size)
        elsif type.pointer?
          pack_global_pointer(offset, type, value, image, relocations)
        elsif type.float?
          # A floating global folds to its IEEE754 image (single for float,
          # double for double). A block-scope `static` reaches here through the
          # same global-initializer path, so it is covered too.
          image[offset, type.size] = pack_float(fold_global_float(value), type.size)
        else
          error_at(value.token, "unsupported initializer for global variable")
        end
      end

      # A compound literal in a static-storage-duration initializer (a file-scope
      # object, or a block-scope `static`) is not supported yet: the unnamed
      # object would itself need static storage and a constant image, which this
      # subset does not lay out. It is diagnosed rather than silently mishandled,
      # whether the literal is used directly ("T g = (T){...};"), decayed
      # ("int *p = (int[]){1,2,3};") or addressed ("int *p = &(int){5};"). The
      # walk peels the address-of and pointer-cast wrappers a constant pointer
      # initializer may carry to reach the literal underneath.
      def reject_file_scope_compound_literal(node)
        while (node.is_a?(Front::AST::Unary) && node.op == :addr) || node.is_a?(Front::AST::Cast)
          node = node.operand
        end
        return unless node.is_a?(Front::AST::CompoundLiteral)

        error_at(node.token, "compound literal at file scope is not supported yet")
      end

      # Folds a global's floating initializer to a Ruby Float: a floating literal
      # is its value, a unary minus negates its operand, and an integer constant
      # expression converts to its floating value (int -> float/double). Anything
      # else is not a constant a floating global admits.
      def fold_global_float(node)
        case node
        when Front::AST::FloatLit
          node.value
        when Front::AST::Unary
          error_at(node.token, "initializer element is not a constant") unless node.op == :neg

          -fold_global_float(node.operand)
        else
          Float(fold_global_constant(node))
        end
      end

      # Whether `node` is a floating constant (a floating literal, possibly under
      # a unary minus), so an integer global can tell a truncating float
      # initializer from an integer constant expression.
      def floating_constant?(node)
        node.is_a?(Front::AST::FloatLit) ||
          (node.is_a?(Front::AST::Unary) && node.op == :neg && floating_constant?(node.operand))
      end

      # Converts a Ruby Float (binary64) to its correctly-rounded IEEE754
      # binary32 bit pattern, returned as an unsigned 32-bit Integer. Ruby's
      # own `Array#pack("e")` does not round: a magnitude past FLT_MAX
      # saturates straight to infinity even when the true binary32 result is
      # FLT_MAX (round-to-nearest, ties-to-even, keeps some of that range).
      # This walks the binary64 bit fields (sign, exponent, mantissa) and
      # narrows the 52-bit fraction to 23 bits itself, so overflow to
      # infinity, underflow to a subnormal or zero, and the FLT_MAX boundary
      # all fall out of one rounding step rather than special-cased ranges.
      def double_to_binary32_bits(value)
        bits64 = [value].pack("E").unpack1("Q<")
        sign = (bits64 >> 63) & 1
        exp64 = (bits64 >> 52) & 0x7FF
        frac64 = bits64 & 0xF_FFFF_FFFF_FFFF

        return (sign << 31) | 0x7F800000 if exp64 == 0x7FF && frac64.zero? # +-infinity
        return (sign << 31) | 0x7FC00000 if exp64 == 0x7FF # NaN: a quiet NaN, payload not preserved

        # A zero and every double subnormal (magnitude < 2**-1022) are far
        # below binary32's smallest subnormal (2**-149), so both round to a
        # signed zero.
        return sign << 31 if exp64.zero?

        unbiased_exp = exp64 - 1023
        mantissa53 = (1 << 52) | frac64 # the implicit leading 1 restored: 2**52..2**53-1

        # binary32 subnormals all share one fixed exponent, -126; an unbiased
        # exponent below that must give up that many extra mantissa bits to
        # land on the same exponent, the same as widening a right shift.
        extra_shift = unbiased_exp < -126 ? -126 - unbiased_exp : 0
        rounded = round_shift_ties_to_even(mantissa53, 29 + extra_shift) # 52 - 23 = 29 fraction bits narrowed away

        if unbiased_exp >= -126
          if rounded == (1 << 24) # rounding carried the mantissa out of range
            rounded >>= 1
            unbiased_exp += 1
          end
          return (sign << 31) | 0x7F800000 if unbiased_exp > 127 # overflow: rounds past FLT_MAX to infinity

          (sign << 31) | ((unbiased_exp + 127) << 23) | (rounded - (1 << 23))
        elsif rounded == (1 << 23) # rounded up into the smallest normal value
          (sign << 31) | (1 << 23)
        else
          (sign << 31) | rounded
        end
      end

      # Shifts `value` right by `shift` bits (shift > 0), rounding to the
      # nearest integer with ties broken to the even result, using Ruby's
      # unbounded Integer so an oversized shift (deep underflow) is exact
      # rather than depending on any fixed-width rounding primitive.
      def round_shift_ties_to_even(value, shift)
        half = 1 << (shift - 1)
        remainder = value & ((half << 1) - 1)
        shifted = value >> shift
        remainder > half || (remainder == half && shifted.odd?) ? shifted + 1 : shifted
      end

      # Packs a Ruby Float into `size` little-endian IEEE754 bytes: a double to
      # eight ("E"), matching how a floating value is stored in a slot so a
      # load reads exactly these bits. A float is narrowed through
      # #double_to_binary32_bits rather than pack("e"): that directive
      # saturates a magnitude past FLT_MAX to infinity instead of rounding it
      # to FLT_MAX, which is wrong for a value within half an ULP of FLT_MAX.
      def pack_float(value, size)
        size == 8 ? [value].pack("E") : [double_to_binary32_bits(value)].pack("L<")
      end

      # Packs a global pointer slot. The address constants this subset admits
      # (6.6p7/p9): a null pointer constant (the eight zero bytes already in
      # place); a function name "f" or "&f" (an absolute relocation against the
      # function's symbol, its signature checked against the pointer's target);
      # and any base-plus-offset address a #fold_address_constant walk reduces to
      # — a string literal, a "&global" or decayed array, and now a computed
      # constant such as "&arr[i]", "arr + n", "&rec.member" or a pointer cast of
      # any of these. The displacement rides along as the relocation's addend.
      # A form that does not fold (a run-time value, a non-constant index) draws
      # the "unsupported initializer" diagnostic.
      def pack_global_pointer(offset, type, value, image, relocations)
        if Front::AST.null_pointer_constant?(value)
          nil # eight zero bytes are already in the image
        elsif (name = function_address_constant(type, value))
          relocations << GlobalReloc.new(offset: offset, kind: :symbol, symbol: name, string_id: nil)
        else
          addr = fold_address_constant(value)
          if addr.base_kind == :absolute
            # No object to relocate against: the bit pattern goes straight into
            # the slot, exactly like a scalar integer initializer.
            image[offset, 8] = pack_integer(addr.offset, 8)
          else
            relocations << address_relocation(offset, addr)
          end
        end
      rescue NotAddressConstant
        error_at(value.token, "unsupported initializer for global variable")
      end

      # Builds the GlobalReloc for a folded AddressConstant: a :string base
      # relocates against .rodata (the string id resolved to its offset later),
      # a :symbol base against that object's own symbol, either carrying the
      # folded byte displacement as its addend.
      def address_relocation(offset, addr)
        case addr.base_kind
        when :string
          GlobalReloc.new(offset: offset, kind: :string, symbol: nil,
                          string_id: addr.string_id, addend: addr.offset)
        when :symbol
          GlobalReloc.new(offset: offset, kind: :symbol, symbol: addr.symbol,
                          string_id: nil, addend: addr.offset)
        end
      end

      # The function symbol a pointer initializer takes the address of — "f" or
      # "&f" — or nil when `value` is not a function reference. The function's
      # signature must match the pointer's target type, exactly as a local
      # function-pointer assignment requires. A name shadowed by a file-scope
      # variable is left to #address_constant_symbol.
      def function_address_constant(type, value)
        name =
          if value.is_a?(Front::AST::Unary) && value.op == :addr &&
             value.operand.is_a?(Front::AST::VariableRef)
            value.operand.name
          elsif value.is_a?(Front::AST::VariableRef)
            value.name
          end
        return nil if name.nil? || @global_bindings.key?(name)

        sig = @signatures[name]
        return nil unless sig

        unless type.pointer? && type.target == function_type_of(sig)
          error_at(value.token, "incompatible types in initialization")
        end
        name
      end

      # Folds a pointer global's initializer to an AddressConstant, or raises
      # NotAddressConstant when it is not one. This is the entry point; it just
      # asks for the initializer's pointer value.
      def fold_address_constant(value)
        pointer_value(value)
      end

      # Folds a pointer-valued constant expression to an AddressConstant whose
      # `pointee` is the type the pointer points at. A string literal decays to a
      # char pointer at the interned bytes; a pointer cast reinterprets the
      # pointee without moving the address when its operand itself folds as a
      # pointer, or — when it does not (e.g. an integer constant such as
      # "(dfree_t)-1") — takes the operand's integer constant value as the
      # pointer's raw bit pattern instead; "&lvalue" is the lvalue's own address;
      # "pointer +/- n" (either operand order for "+") shifts by n elements; and
      # any other lvalue of array type decays to a pointer to its first element.
      def pointer_value(node)
        case node
        when Front::AST::StringLit
          AddressConstant.new(base_kind: :string, symbol: nil,
                              string_id: intern_string(node.value), offset: 0, pointee: @plain_char)
        when Front::AST::Cast
          raise NotAddressConstant unless node.type.pointer?

          if (inner = maybe_pointer_value(node.operand))
            inner.with(pointee: node.type.target)
          else
            AddressConstant.new(base_kind: :absolute, symbol: nil, string_id: nil,
                                offset: fold_absolute_constant(node.operand), pointee: node.type.target)
          end
        when Front::AST::Unary
          raise NotAddressConstant unless node.op == :addr

          object_address(node.operand)
        when Front::AST::Binary
          pointer_arithmetic(node)
        else
          decayed = object_address(node)
          raise NotAddressConstant unless decayed.pointee.array?

          decayed.with(offset: decayed.offset, pointee: decayed.pointee.element)
        end
      end

      # Folds an lvalue expression to the AddressConstant of the object it
      # designates, its `pointee` the object's own type. A file-scope variable is
      # its symbol; a subscript adds index times element size; a member access
      # adds the member's offset (through StructType#member, so an anonymous
      # member is traversed transparently); "*p" is the address p holds. Anything
      # else — a local, an unknown name, a run-time value — is not an address
      # constant.
      def object_address(node)
        case node
        when Front::AST::VariableRef
          binding = @global_bindings[node.name]
          raise NotAddressConstant unless binding&.global

          AddressConstant.new(base_kind: :symbol, symbol: binding.storage,
                              string_id: nil, offset: 0, pointee: binding.type)
        when Front::AST::Subscript
          subscript_address(node)
        when Front::AST::MemberAccess
          member_address(node)
        when Front::AST::Unary
          raise NotAddressConstant unless node.op == :deref

          pointer_value(node.operand)
        else
          raise NotAddressConstant
        end
      end

      # The address of "target[index]": the target's pointer value shifted by the
      # constant index times the element size.
      def subscript_address(node)
        base = pointer_value(node.target)
        element = base.pointee
        raise NotAddressConstant unless element&.size

        base.with(offset: base.offset + fold_constant_index(node.index) * element.size)
      end

      # The address of "base.member" (a struct lvalue) or "base->member" (a struct
      # pointer): the base's address plus the member's byte offset. A bit-field has
      # no addressable offset, so it is not an address constant.
      def member_address(node)
        base = node.arrow ? pointer_value(node.base) : object_address(node.base)
        struct = base.pointee
        raise NotAddressConstant unless struct.respond_to?(:member) && struct.struct?

        member = struct.member(node.member)
        raise NotAddressConstant if member.nil? || member.bitfield?

        base.with(offset: base.offset + member.offset, pointee: member.type)
      end

      # Folds "pointer +/- n" (or "n + pointer" for "+"): the pointer operand's
      # address shifted by n elements. A pointer minus a pointer, or a non-constant
      # count, is not an address constant.
      def pointer_arithmetic(node)
        raise NotAddressConstant unless node.op == :add || node.op == :sub

        base, count_node = pointer_operand(node)
        step = base.pointee
        raise NotAddressConstant unless step&.size

        delta = fold_constant_index(count_node) * step.size
        base.with(offset: node.op == :sub ? base.offset - delta : base.offset + delta)
      end

      # Splits an additive node into [pointer AddressConstant, integer operand].
      # For "+", either operand may be the pointer; for "-", only the left one is.
      def pointer_operand(node)
        if (base = maybe_pointer_value(node.lhs))
          [base, node.rhs]
        elsif node.op == :add && (base = maybe_pointer_value(node.rhs))
          [base, node.lhs]
        else
          raise NotAddressConstant
        end
      end

      # Attempts #pointer_value, returning nil instead of raising when `node` is
      # not a pointer constant — so #pointer_operand can probe each side.
      def maybe_pointer_value(node)
        pointer_value(node)
      rescue NotAddressConstant
        nil
      end

      # Evaluates a subscript or pointer-arithmetic count to a constant integer,
      # rejecting a non-constant one (a variable, a call) as breaking the address
      # constant rather than surfacing the evaluator's own diagnostic.
      def fold_constant_index(node)
        Front::ConstantEvaluator.evaluate(node)
      rescue Front::ConstantEvaluator::NotConstant, Front::ConstantEvaluator::DivisionByZero
        raise NotAddressConstant
      end

      # Evaluates a pointer cast's operand as a constant integer — the pointer's
      # absolute bit pattern when it is not itself an address constant — rejecting
      # a non-constant operand (a variable, a call) the same way #fold_constant_index
      # does.
      def fold_absolute_constant(node)
        Front::ConstantEvaluator.evaluate(node)
      rescue Front::ConstantEvaluator::NotConstant, Front::ConstantEvaluator::DivisionByZero
        raise NotAddressConstant
      end

      # Folds a global's scalar-integer initializer element to a constant, the
      # rule (6.6) a global requires; a non-constant element (a call, a variable)
      # or a division by zero is diagnosed at its own token.
      def fold_global_constant(node)
        Front::ConstantEvaluator.evaluate(node, sizeof_expr: sizeof_expr_resolver)
      rescue Front::ConstantEvaluator::NotConstant => e
        error_at(e.token, "initializer element is not a constant")
      rescue Front::ConstantEvaluator::DivisionByZero => e
        error_at(e.token, "division by zero in constant expression")
      end

      # A resolver the constant evaluator calls to fold a "sizeof <expression>"
      # operand in a static initializer: it infers the operand's type (the same
      # code-free inference sizeof of an operand uses at run time) and returns
      # its byte size, applying gen_sizeof's identical rejections for an operand
      # with no size (void, function or incomplete type). Type inference needs
      # the symbol table the generator holds, which the evaluator lacks, so it is
      # supplied as a callback rather than duplicated inside the evaluator.
      def sizeof_expr_resolver
        lambda do |node|
          type = sizeof_operand_type(node.operand)
          token = node.token
          error_at(token, "invalid application of 'sizeof' to void type") if type.void?
          error_at(token, "invalid application of 'sizeof' to a function type") if type.function?
          require_complete(type, token)
          type.size
        end
      end

      # Packs an integer into `size` little-endian two's-complement bytes. The
      # value is masked to the slot width first — the constant evaluator works in
      # unbounded Ruby Integers, so an expression like "1L << 100" would
      # otherwise overflow pack's fixed-width directives with a RangeError
      # instead of storing the low bytes the way a C store to that width does.
      def pack_integer(value, size)
        masked = value & ((1 << (size * 8)) - 1)
        case size
        when 1 then [masked].pack("C")
        when 2 then [masked].pack("S<")
        when 4 then [masked].pack("L<")
        when 16 then [masked & 0xFFFF_FFFF_FFFF_FFFF, masked >> 64].pack("Q<Q<")
        else [masked].pack("Q<")
        end
      end

      # Interns `bytes` (an ASCII-8BIT String) into the string pool, returning
      # its id. Identical contents share one id, deduplicating string literals
      # across the whole translation unit.
      def intern_string(bytes)
        @string_ids.fetch(bytes) do
          id = @strings.size
          @strings << bytes
          @string_ids[bytes] = id
          id
        end
      end

      # Records or updates a function's signature, enforcing that repeated
      # declarations agree on their return type and parameter types (which
      # also covers arity) and that a body is defined at most once.
      def declare_function(name, return_type, param_types, variadic:, defined:, token:)
        error_at(token, "redefinition of '#{name}'") if @global_bindings.key?(name)
        # A struct passed or returned by value must have a known layout for its
        # System V eightbyte classification, so an incomplete struct is rejected
        # here. C would permit an incomplete type in a never-called prototype, but
        # this subset diagnoses it at the declaration for simplicity (a struct
        # argument or result whose tag is never completed is a program error).
        if return_type.struct? && !return_type.complete?
          error_at(token, "return type is an incomplete type")
        end
        # Passing or returning a 128-bit integer by value would use two System V
        # registers (a psABI detail out of this phase's scope), so it is diagnosed
        # here — the one place both a prototype and a definition pass through.
        if wide128?(return_type)
          error_at(token, "returning a 128-bit integer by value is not supported yet")
        end
        param_types.each do |param_type|
          if param_type.struct? && !param_type.complete?
            error_at(token, "parameter has incomplete type")
          end
          if wide128?(param_type)
            error_at(token, "passing a 128-bit integer by value is not supported yet")
          end
        end
        existing = @signatures[name]
        if existing
          if existing[:param_types] != param_types || existing[:return_type] != return_type ||
             existing[:variadic] != variadic
            error_at(token, "conflicting types for '#{name}'")
          elsif defined && existing[:defined]
            error_at(token, "redefinition of '#{name}'")
          end
        end
        @signatures[name] = {
          param_types: param_types,
          return_type: return_type,
          variadic: variadic,
          defined: defined || existing&.fetch(:defined) || false
        }
      end

      def gen_function(func, linkage)
        @insts = []
        @vreg_count = 0
        @label_count = 0
        # The enclosing function's declared return type, consulted by
        # #gen_return to type-check "return ...;" and by the implicit-return
        # fallback below.
        @current_return_type = func.return_type
        # The enclosing function's "..." flag and its ordered named parameters,
        # consulted by #gen_va_start to reject va_start in a fixed-arity function
        # and to check its second argument against the last named parameter.
        @current_variadic = func.variadic
        @current_named_params = func.params
        # Aggregate stack objects (arrays), indexed by object id; each entry is
        # the object's byte size. The backend lays them out below the vreg
        # slots and resolves :object_addr against this table.
        @stack_objects = []
        # Symbol tables form a scope stack (innermost last), each mapping a
        # variable name to its Local binding. The shared file-scope globals sit
        # at the bottom so a local of the same name shadows a global; the
        # function body owns the next scope, and every compound-statement pushes
        # a fresh one on top.
        @scopes = [@global_bindings, {}]
        # Innermost-last stack of enclosing loops and switches, each frame a
        # { break_label:, continue_label: }. `break` jumps to the top frame's
        # break_label (a loop's end or a switch's end); `continue` jumps to the
        # top frame's continue_label. A switch frame carries the enclosing
        # loop's continue_label unchanged, so `continue` inside a switch passes
        # through to the loop, and a nil continue_label (a switch with no
        # enclosing loop) makes `continue` a diagnostic.
        @control_stack = []
        # Function-scoped goto label table: name -> { id:, defined:, token: }.
        # A label id is allocated the first time a name is seen (by a goto or by
        # its definition), so a forward goto needs no backpatching — it emits a
        # jump to the id the label will later mark. `defined` catches a duplicate
        # definition and, at the function's end, a goto to a never-defined label.
        @goto_labels = {}
        # Innermost-last stack of the current switches' case/default label maps
        # (each a node -> label id, keyed by object identity), so a Case/Default
        # statement encountered while walking a switch body can find the label
        # the comparison chain already assigned to it.
        @case_label_stack = []

        setup_parameters(func)

        func.body.each { |stmt| gen_statement(stmt) }

        # Every label a goto referenced must have been defined somewhere in the
        # function; a goto to a label that never appears is diagnosed here, once
        # the whole body has been seen (so a forward reference is not mistaken
        # for an undefined one). The stored token locates the offending goto.
        @goto_labels.each do |name, entry|
          next if entry[:defined]

          error_at(entry[:token], "label '#{name}' used but not defined")
        end

        # Falling off the end of the body needs an explicit return, unless one
        # was already emitted. A void function returns no value; every other
        # return type (including char and pointer, where falling off the end
        # is technically undefined behavior, just like a non-void, non-main
        # function in C99) returns 0, matching main's C99 fallback and keeping
        # this single case simple.
        unless @insts.last&.op == :ret
          if @current_return_type.void?
            emit(:ret, a: nil)
          elsif @current_return_type.struct?
            # Falling off a struct-returning function is undefined; keep the
            # caller safe rather than model a value. A MEMORY return hands back
            # its hidden result pointer (so the caller's rax is a valid address);
            # a register return hands back a 0 in rax with a nil size, and the
            # caller merely stores whatever the return registers hold into its
            # scratch buffer, never dereferencing anything invalid.
            if @struct_return_class == :memory
              emit(:ret, a: @struct_return_ptr, size: nil)
            else
              zero = new_vreg
              emit(:const, dst: zero, a: 0)
              emit(:ret, a: zero, size: nil)
            end
          else
            # A zero-bit slot reads as an integer 0, a +0.0f or a +0.0 alike, so
            # a floating function's fall-off return still hands back a valid
            # value; :ret's float width just routes it through xmm0.
            zero = new_vreg
            emit(:const, dst: zero, a: 0)
            emit(:ret, a: zero, size: (@current_return_type.size if @current_return_type.float?))
          end
        end

        Function.new(func.name, @insts, @vreg_count, @param_count, @stack_objects, linkage,
                     func.variadic, @param_kinds)
      end

      # Binds the function's parameters and records its ABI slot layout. Each C
      # parameter maps to one or more System V eightbyte slots — a scalar to one,
      # a struct to its classified eightbytes (a MEMORY struct to ceil(size/8)
      # stack eightbytes) — and a MEMORY-returning function prepends a hidden
      # pointer slot for the caller's result buffer. Those slots occupy the first
      # vregs (0..param_count-1) in flattened order, so the backend spills each
      # incoming argument register straight into its slot; a struct parameter is
      # then reassembled into a stack object from its slots, and a scalar
      # parameter's slot is its storage directly. @param_kinds records where every
      # slot arrives (from the shared placement simulation) and @param_count the
      # total, both handed to the IR::Function.
      def setup_parameters(func)
        return_type = func.return_type
        # A MEMORY-classified result is written through a hidden pointer the caller
        # supplies as an implicit first integer argument; @struct_return_ptr holds
        # its slot for #gen_return, and @struct_return_class steers the return.
        @struct_return_class = return_type.struct? ? classify_struct(return_type) : nil
        @struct_return_ptr = nil
        hidden_return = @struct_return_class == :memory

        # One candidate-kind list per ABI entity, in slot order: the hidden return
        # pointer (if any) first, then each parameter's eightbyte classes.
        slot_lists = []
        slot_lists << [@convention.hidden_result_kind] if hidden_return
        param_lists = func.params.map { |param| parameter_slot_kinds(param.type) }
        slot_lists.concat(param_lists)

        # Allocate the slot vregs first (0..param_count-1) so they align with the
        # flattened param_kinds the backend spills into.
        slot_vregs = slot_lists.map { |list| list.map { new_vreg } }
        @param_count = slot_vregs.sum(&:size)
        @param_kinds = place_argument_kinds(slot_lists).flatten

        index = 0
        if hidden_return
          @struct_return_ptr = slot_vregs[index].first
          index += 1
        end
        func.params.each do |param|
          vregs = slot_vregs[index]
          index += 1
          if param.type.struct?
            bind_struct_parameter(param, vregs)
          else
            @scopes.last[param.name] =
              Local.new(type: param.type, storage: vregs.first, global: false, const: param.const)
          end
        end

        # A narrow integer parameter (char/short and their unsigned forms, _Bool)
        # arrives in a register with an unspecified high half; re-derive its value
        # from the low bytes in place, by the type's signedness, so its slot holds
        # the properly extended value like any other narrow lvalue. Wider scalars
        # and structs need no fix-up.
        func.params.each do |param|
          type = param.type
          next unless type.integer? && (type.size == 1 || type.size == 2)

          slot = @scopes.last[param.name].storage
          emit(type.signed? ? :sext : :zext, dst: slot, a: slot, size: type.size)
        end
      end

      # The candidate eightbyte-kind list a parameter of `type` contributes to the
      # ABI slot layout: a scalar is a single register-class eightbyte, a
      # register-classified struct its INTEGER/SSE eightbytes, and a MEMORY struct
      # ceil(size/8) eightbytes tagged with the convention's memory-aggregate kind
      # (which #place_argument_kinds passes through untouched).
      def parameter_slot_kinds(type)
        return [argument_kind(type)] unless type.struct?

        classes = classify_struct(type)
        return classes unless classes == :memory

        Array.new((type.size + 7) / 8, @convention.memory_aggregate_kind)
      end

      # Reassembles a struct parameter from its incoming ABI slots into a fresh
      # stack object the parameter name is bound to (the same by-address form every
      # struct lvalue uses). Each slot vreg holds one eightbyte of the argument;
      # storing it at base + 8*i writes the struct back into contiguous memory. The
      # final eightbyte's full 8-byte store stays within the 16-byte-aligned,
      # rounded-up stack object even when the struct's size is not a multiple of 8.
      def bind_struct_parameter(param, slot_vregs)
        type = param.type
        object_id = new_object(type.size)
        @scopes.last[param.name] = Local.new(type: type, storage: object_id, global: false, const: param.const)
        base = new_vreg
        emit(:object_addr, dst: base, a: object_id)
        slot_vregs.each_with_index do |vreg, i|
          emit(:store, a: eightbyte_address(base, i), b: vreg, size: 8)
        end
      end

      # The address of eightbyte `i` within an aggregate whose base address is in
      # `base_vreg`: the base itself for the first eightbyte, or base + 8*i
      # otherwise. Shared by the struct-parameter reassembly and struct-argument
      # lowering, both of which read or write a struct one eightbyte at a time.
      def eightbyte_address(base_vreg, i)
        return base_vreg if i.zero?

        offset = new_vreg
        emit(:const, dst: offset, a: 8 * i)
        addr = new_vreg
        emit(:add, dst: addr, a: base_vreg, b: offset, size: 8)
        addr
      end

      # Classifies a type for the System V AMD64 argument/return convention: a
      # `float` is an :sse4 (a scalar single in an xmm register), a `double` an
      # :sse8 (a scalar double), and every integer, pointer or other scalar a
      # :gp (an integer register). This is only the *candidate* class an argument
      # would take with registers available; #place_argument_kinds then decides,
      # over the whole list, which candidates actually land in a register and
      # which spill to the stack (:mem). The kind is also used unqualified to mark
      # a float/double return.
      def argument_kind(type)
        return :sse4 if type.float? && type.size == 4
        return :sse8 if type.float? && type.size == 8

        :gp
      end

      # Fixes the register/stack placement of an argument list ahead of the
      # backend, so the classification the backend follows is decided where every
      # argument's type is known. `arguments` is one entry per argument, each a
      # list of that argument's eightbyte candidate kinds (:gp / :sse4 / :sse8 for
      # an in-register class, or the convention's memory-aggregate kind for an
      # aggregate it never puts in registers). A scalar argument is a single
      # eightbyte, so its list has length one; a struct's list holds one entry per
      # eightbyte, which is what lets the psABI 3.2.3 all-or-nothing rule act on a
      # whole argument at once.
      #
      # Each argument is placed as a unit: its required integer and vector
      # registers are counted first, and only if *both* fit in what remains do its
      # eightbytes take those registers (consuming them); otherwise the entire
      # argument spills, every eightbyte becoming :mem, and no register is used —
      # the psABI rule that an argument whose parts do not all fit in registers
      # passes wholly in memory. AAPCS64 6.4.2 stage C reaches the same layout for
      # the arguments this generator classifies, differing only in how many
      # registers there are to run out of, which is what @convention supplies. A
      # candidate list already all memory-aggregate passes straight through,
      # consuming no register. The :mem eightbytes keep their left-to-right order,
      # which the backend lays out as ascending stack addresses. The result mirrors
      # `arguments`: one placed kind list per argument.
      def place_argument_kinds(arguments)
        next_gp = 0
        next_sse = 0
        aggregate = @convention.memory_aggregate_kind
        arguments.map do |candidates|
          if candidates.all?(aggregate)
            candidates
          else
            need_gp = candidates.count(:gp)
            need_sse = candidates.count { |k| k == :sse4 || k == :sse8 }
            if next_gp + need_gp <= @convention.gp_registers && next_sse + need_sse <= @convention.fp_registers
              next_gp += need_gp
              next_sse += need_sse
              candidates
            else
              Array.new(candidates.size, :mem)
            end
          end
        end
      end

      # Classifies an aggregate for the System V AMD64 argument/return convention
      # (psABI 3.2.3). A struct or union larger than two eightbytes — or one with
      # any unaligned field — is passed in memory; otherwise each of its one or
      # two eightbytes gets a class from the scalar fields that fall in it.
      # Returns :memory, or an array (one entry per eightbyte) of :gp (an INTEGER
      # eightbyte, taken in an integer register) or :sse8 (an SSE eightbyte, moved
      # as a full 8-byte double even when it holds two packed floats, since a
      # single movsd carries the whole eightbyte).
      #
      # The unaligned-field test is what a GNU __attribute__((packed)) demands
      # (Step 28): the psABI gives an aggregate "containing unaligned fields"
      # class MEMORY, and gcc follows it — a packed struct whose field would
      # straddle an eightbyte boundary is passed on the stack, not in registers.
      # Every non-packed layout here is naturally aligned, so this only ever
      # fires for a packed struct.
      def classify_struct(struct_type)
        size = struct_type.size
        return :memory if size > 16
        return :memory if unaligned_field?(struct_type, 0)

        eightbytes = Array.new((size + 7) / 8, nil)
        classify_eightbytes(eightbytes, struct_type, 0)
        # A NO_CLASS eightbyte (only padding fell in it) defaults to SSE, the
        # psABI's benign choice; INTEGER otherwise wins over SSE per #merge_class.
        eightbytes.map { |cls| cls == :integer ? :gp : :sse8 }
      end

      # Whether any scalar field of `type`, placed at absolute byte offset `base`,
      # sits on an offset that does not satisfy its own alignment — the mark of a
      # packed layout. A nested aggregate recurses at its members' offsets (a
      # union's members all at 0) and an array at its element's; a scalar checks
      # base against its alignment directly.
      def unaligned_field?(type, base)
        if type.struct?
          # A bit-field is packed into a storage unit by design, so it is never an
          # "unaligned field" in the psABI sense; only its plain neighbours are
          # tested. gcc likewise passes a small bit-field struct in registers.
          type.members.reject(&:bitfield?).any? { |m| unaligned_field?(m.type, base + m.offset) }
        elsif type.array?
          unaligned_field?(type.element, base)
        else
          (base % type.alignment) != 0
        end
      end

      # Walks `type` at byte offset `base` and folds each scalar field's class
      # into the eightbyte (offset / 8) it lands in. A nested struct or union
      # recurses at its member offsets (a union overlays every member at the same
      # offset, which the members' zero offsets already encode), and an array
      # recurses element by element. A struct reaching here has already passed the
      # unaligned-field test in #classify_struct, so no scalar straddles an
      # eightbyte boundary and each falls wholly in the eightbyte at offset / 8.
      def classify_eightbytes(eightbytes, type, base)
        if type.struct?
          type.members.each do |m|
            if m.bitfield?
              classify_bitfield(eightbytes, base, m)
            else
              classify_eightbytes(eightbytes, m.type, base + m.offset)
            end
          end
        elsif type.array?
          type.length.times { |i| classify_eightbytes(eightbytes, type.element, base + i * type.element.size) }
        else
          # A scalar folds its class into every eightbyte it spans. All scalars but
          # a 128-bit integer fit in one (they are naturally aligned); a 16-byte
          # __int128 spans two, both INTEGER, so a struct wrapping one passes by
          # value in two integer registers, as gcc does.
          cls = type.float? ? :sse : :integer
          (base / 8..(base + type.size - 1) / 8).each do |index|
            eightbytes[index] = merge_class(eightbytes[index], cls)
          end
        end
      end

      # Folds a bit-field member into the eightbytes its bits span. Every
      # bit-field type in this subset is an integer type, so the field
      # contributes INTEGER to each eightbyte it touches (a field wide enough, or
      # placed so, that it straddles an eightbyte boundary marks both). `base` is
      # the enclosing aggregate's byte offset and the member's `bit_offset` its
      # bit position within that aggregate.
      def classify_bitfield(eightbytes, base, member)
        first_bit = base * 8 + member.bit_offset
        last_bit = first_bit + member.bit_width - 1
        (first_bit / 64..last_bit / 64).each do |index|
          eightbytes[index] = merge_class(eightbytes[index], :integer)
        end
      end

      # Combines two field classes sharing an eightbyte: NO_CLASS (nil) yields to
      # the other, and INTEGER dominates SSE (a mixed integer/float eightbyte is
      # passed in an integer register), matching the psABI merge rule this subset
      # needs.
      def merge_class(current, incoming)
        return incoming if current.nil?
        return current if incoming.nil?
        return :integer if current == :integer || incoming == :integer

        :sse
      end

      def gen_statement(stmt)
        case stmt
        when Front::AST::Return
          gen_return(stmt)
        when Front::AST::VariableDecl
          gen_variable_decl(stmt)
        when Front::AST::ExpressionStmt
          gen_expr(stmt.expr)
        when Front::AST::EmptyStmt
          # no-op
        when Front::AST::InlineAsm
          # An empty asm barrier lowers to nothing: rubycc performs no
          # reordering, so a "memory" clobber already constrains nothing.
        when Front::AST::If
          gen_if(stmt)
        when Front::AST::Block
          gen_block(stmt)
        when Front::AST::While
          gen_while(stmt)
        when Front::AST::DoWhile
          gen_do_while(stmt)
        when Front::AST::For
          gen_for(stmt)
        when Front::AST::Break
          gen_break(stmt)
        when Front::AST::Continue
          gen_continue(stmt)
        when Front::AST::Switch
          gen_switch(stmt)
        when Front::AST::Case
          gen_case(stmt)
        when Front::AST::Default
          gen_default(stmt)
        when Front::AST::Goto
          gen_goto(stmt)
        when Front::AST::Label
          gen_label(stmt)
        else
          raise "unsupported statement: #{stmt.class}"
        end
      end

      def gen_block(block)
        @scopes.push({})
        block.items.each { |item| gen_statement(item) }
        @scopes.pop
      end

      def gen_if(node)
        cond = gen_condition(node.condition)
        if node.else_stmt
          else_label = new_label
          end_label = new_label
          emit(:jump_if_zero, a: cond, b: else_label)
          gen_statement(node.then_stmt)
          emit(:jump, a: end_label)
          emit(:label, a: else_label)
          gen_statement(node.else_stmt)
          emit(:label, a: end_label)
        else
          end_label = new_label
          emit(:jump_if_zero, a: cond, b: end_label)
          gen_statement(node.then_stmt)
          emit(:label, a: end_label)
        end
      end

      def gen_while(node)
        cond_label = new_label
        end_label = new_label
        emit(:label, a: cond_label)
        cond = gen_condition(node.condition)
        emit(:jump_if_zero, a: cond, b: end_label)
        gen_loop_body(node.body, continue_label: cond_label, break_label: end_label)
        emit(:jump, a: cond_label)
        emit(:label, a: end_label)
      end

      def gen_do_while(node)
        body_label = new_label
        cond_label = new_label
        end_label = new_label
        emit(:label, a: body_label)
        gen_loop_body(node.body, continue_label: cond_label, break_label: end_label)
        emit(:label, a: cond_label)
        cond = gen_condition(node.condition)
        emit(:jump_if_zero, a: cond, b: end_label)
        emit(:jump, a: body_label)
        emit(:label, a: end_label)
      end

      # C99: the for-loop's own parentheses introduce a scope, so a
      # declaration in clause-1 is only visible to the condition, step and
      # body (not to code after the loop).
      def gen_for(node)
        @scopes.push({})
        gen_for_init(node.init)

        cond_label = new_label
        step_label = new_label
        end_label = new_label

        emit(:label, a: cond_label)
        if node.condition
          cond = gen_condition(node.condition)
          emit(:jump_if_zero, a: cond, b: end_label)
        end
        gen_loop_body(node.body, continue_label: step_label, break_label: end_label)
        emit(:label, a: step_label)
        gen_expr(node.step) if node.step
        emit(:jump, a: cond_label)
        emit(:label, a: end_label)

        @scopes.pop
      end

      def gen_for_init(init)
        case init
        when Array
          init.each { |decl| gen_variable_decl(decl) }
        when nil
          # no-op: clause-1 was omitted
        else
          gen_expr(init)
        end
      end

      # Runs a loop's body with break/continue targets visible to any nested
      # Break/Continue node, restoring the enclosing loop's targets (if any)
      # once the body has been generated. Both targets are the loop's own, so
      # break leaves the loop and continue restarts it.
      def gen_loop_body(body, continue_label:, break_label:)
        @control_stack.push(break_label: break_label, continue_label: continue_label)
        gen_statement(body)
      ensure
        @control_stack.pop
      end

      # break jumps to the innermost enclosing loop's or switch's end. It is a
      # diagnostic only when no such construct is open at all.
      def gen_break(node)
        if @control_stack.empty?
          error_at(node.token, "break statement not within a loop or switch")
        end
        emit(:jump, a: @control_stack.last[:break_label])
      end

      # continue jumps to the innermost enclosing loop's continue target. A
      # switch frame carries the loop's target through unchanged, so a continue
      # inside a switch reaches the loop; a nil target (no enclosing loop at all,
      # even if a switch is open) is the diagnostic case.
      def gen_continue(node)
        target = @control_stack.last && @control_stack.last[:continue_label]
        error_at(node.token, "continue statement not within a loop") unless target
        emit(:jump, a: target)
      end

      # A switch is desugared to a comparison chain (no jump table — that is a
      # later optimization): the controlling expression is evaluated once, then
      # each case constant is compared against it and, on a match, control jumps
      # to that case's label; failing every case it jumps to default (or, absent
      # one, past the switch). The case/default labels themselves are placed
      # while the body is generated, so fall-through between cases (a case
      # without a break) just runs into the next label's code.
      def gen_switch(node)
        control, control_type = gen_value(node.control)
        # The controlling expression must be an integer type; a pointer, struct
        # or other non-integer has no case constants to match against. It
        # undergoes integer promotion (6.8.4.2), and the case constants are
        # compared against it in that promoted type.
        unless control_type.integer?
          error_at(node.token, "switch quantity is not an integer")
        end
        promoted_type = integer_promote(control_type)
        control = convert(control, from: control_type, to: promoted_type)

        # Collect every case/default that belongs to this switch — those not
        # sealed off inside a nested switch — assigning each a label and checking
        # for duplicate values and a second default.
        collected = []
        collect_switch_labels(node.body, collected)
        labels, default_node = resolve_switch_labels(collected)

        end_label = new_label
        emit_switch_dispatch(control, promoted_type, collected, labels, default_node, end_label)

        # Generate the body with the labels in scope so each Case/Default marks
        # its position, and with break routed to the switch's end.
        gen_switch_body(node.body, labels, end_label)
        emit(:label, a: end_label)
      end

      # Emits the comparison chain: for each case, "control != value" and a
      # jump-if-zero (i.e. jump when equal) to the case's label; then an
      # unconditional jump to default (or the switch's end when there is none).
      # ">> jump when equal" is spelled with the existing :ne + :jump_if_zero
      # because the IR has no jump-if-nonzero.
      def emit_switch_dispatch(control, control_type, collected, labels, default_node, end_label)
        # A size-8 controlling type compares (and loads its case constants) at
        # 64 bits, so a long case value and the high half of the control both
        # participate.
        size = control_type.size == 8 ? 8 : nil
        collected.each do |node|
          next if node.is_a?(Front::AST::Default)

          value_reg = new_vreg
          emit(:const, dst: value_reg, a: node.value, size: size)
          cmp = new_vreg
          emit(:ne, dst: cmp, a: control, b: value_reg, size: size)
          emit(:jump_if_zero, a: cmp, b: labels[node])
        end
        emit(:jump, a: default_node ? labels[default_node] : end_label)
      end

      # Assigns a fresh label to each collected case/default and diagnoses a
      # duplicate case value or a second default. Returns [labels, default_node]
      # where `labels` maps each node (by identity) to its label id.
      def resolve_switch_labels(collected)
        labels = {}.compare_by_identity
        seen_values = {}
        default_node = nil
        collected.each do |node|
          if node.is_a?(Front::AST::Default)
            error_at(node.token, "multiple default labels in one switch") if default_node
            default_node = node
          elsif seen_values.key?(node.value)
            error_at(node.token, "duplicate case value '#{node.value}'")
          else
            seen_values[node.value] = true
          end
          labels[node] = new_label
        end
        [labels, default_node]
      end

      # Recursively gathers the Case/Default nodes that belong to one switch,
      # appending them to `collected` in source order. It descends through every
      # statement that can textually enclose a label (blocks, if arms, loops,
      # labeled statements and the case/default bodies themselves) but stops at a
      # nested switch, whose own cases belong to it, not this one.
      def collect_switch_labels(stmt, collected)
        case stmt
        when Front::AST::Case, Front::AST::Default
          collected << stmt
          collect_switch_labels(stmt.body, collected)
        when Front::AST::Label
          collect_switch_labels(stmt.body, collected)
        when Front::AST::Block
          stmt.items.each { |item| collect_switch_labels(item, collected) }
        when Front::AST::If
          collect_switch_labels(stmt.then_stmt, collected)
          collect_switch_labels(stmt.else_stmt, collected) if stmt.else_stmt
        when Front::AST::While, Front::AST::DoWhile, Front::AST::For
          collect_switch_labels(stmt.body, collected)
        end
        # Every other statement (a return, an expression, a declaration, a break,
        # a goto, or a nested switch) either holds no statement or, in the
        # switch's case, seals off its own labels, so recursion stops here.
      end

      # Generates a switch body with its case labels in scope (so Case/Default
      # nodes resolve to the labels the dispatch chain assigned) and break routed
      # to the switch's end. The continue target is inherited from the enclosing
      # loop unchanged, so a continue inside the switch still restarts that loop.
      def gen_switch_body(body, labels, break_label)
        inherited_continue = @control_stack.last && @control_stack.last[:continue_label]
        @case_label_stack.push(labels)
        @control_stack.push(break_label: break_label, continue_label: inherited_continue)
        gen_statement(body)
      ensure
        @control_stack.pop
        @case_label_stack.pop
      end

      # A case label: place the label the dispatch chain assigned, then generate
      # the labeled statement so control flows into it on a match (or falls
      # through from the case above). A Case reached with no switch open, or one
      # that belongs to an outer switch, has no label and is diagnosed.
      def gen_case(node)
        label = current_case_label(node)
        error_at(node.token, "case label not within a switch statement") unless label
        emit(:label, a: label)
        gen_statement(node.body)
      end

      # A default label, lowered exactly like a case: mark its position and
      # generate the labeled statement. Diagnosed when reached outside a switch.
      def gen_default(node)
        label = current_case_label(node)
        error_at(node.token, "'default' label not within a switch statement") unless label
        emit(:label, a: label)
        gen_statement(node.body)
      end

      # Looks up the label the innermost switch's dispatch assigned to this
      # Case/Default node. The node is matched by identity, so a label is found
      # only while generating the very switch body that collected it.
      def current_case_label(node)
        map = @case_label_stack.last
        map && map[node]
      end

      # goto: an unconditional jump to the named label. The label id is allocated
      # on first sight (here for a forward jump, or at the definition for a
      # backward one), so the jump can be emitted immediately with no
      # backpatching; the token is kept to locate the goto if the label turns out
      # to be undefined at the function's end.
      def gen_goto(node)
        entry = @goto_labels[node.label] ||= { id: new_label, defined: false, token: node.token }
        emit(:jump, a: entry[:id])
      end

      # A labeled statement "name: stmt": define the label (allocating its id if
      # a forward goto has not already) and place it, then generate the prefixed
      # statement. A name defined twice in one function is a diagnostic.
      def gen_label(node)
        entry = @goto_labels[node.name]
        if entry
          error_at(node.token, "duplicate label '#{node.name}'") if entry[:defined]
          entry[:defined] = true
        else
          entry = @goto_labels[node.name] = { id: new_label, defined: true, token: node.token }
        end
        emit(:label, a: entry[:id])
        gen_statement(node.body)
      end

      # "return;" or "return expr;", checked against the enclosing function's
      # declared return type (@current_return_type): a void function accepts
      # only the valueless form ("return with a value in void function"
      # otherwise), every other return type requires a value ("return without
      # a value" otherwise) that is return-type-compatible (#compatible_assignment?,
      # the same rule assignment and arguments use, so "return 0;" from a pointer
      # function is a null pointer) and is narrowed to that type exactly like a
      # variable's initializer.
      def gen_return(node)
        if @current_return_type.void?
          error_at(node.token, "return with a value in void function") if node.expr
          emit(:ret, a: nil)
          return
        end

        error_at(node.token, "return without a value") unless node.expr

        return gen_struct_return(node) if @current_return_type.struct?

        value, value_type = gen_value(node.expr)
        unless compatible_assignment?(@current_return_type, node.expr, value_type)
          error_at(node.token, "incompatible return type")
        end
        converted = convert_for_assignment(value, value_type, @current_return_type, token: node.token)
        # A floating return travels in xmm0, so :ret carries the float width
        # (4/8) to select movss/movsd; every other return goes back in rax
        # (size nil).
        emit(:ret, a: converted, size: (@current_return_type.size if @current_return_type.float?))
      end

      # "return expr;" from a struct-returning function. The returned value is a
      # struct address (the struct's own by-value representation), which must have
      # the function's exact struct type (identity). A MEMORY result is copied
      # through the hidden result pointer and that pointer returned in rax, per the
      # psABI; a register result is copied into a scratch stack object first (so
      # the eightbyte loads never read past a struct whose size is not a multiple
      # of 8), whose address and eightbyte classes ride on :ret for the backend to
      # load into the return registers.
      def gen_struct_return(node)
        src, src_type = gen_value(node.expr)
        error_at(node.token, "incompatible return type") unless src_type == @current_return_type

        size = @current_return_type.size
        if @struct_return_class == :memory
          emit(:memcpy, a: @struct_return_ptr, b: src, size: size)
          emit(:ret, a: @struct_return_ptr, size: nil)
        else
          scratch = new_object(size)
          base = new_vreg
          emit(:object_addr, dst: base, a: scratch)
          emit(:memcpy, a: base, b: src, size: size)
          emit(:ret, a: base, size: @struct_return_class)
        end
      end

      def gen_variable_decl(decl)
        scope = @scopes.last
        if scope.key?(decl.name)
          error_at(decl.token, "redeclaration of '#{decl.name}'")
        end

        # A block-scope declarator that builds a function type ("int f(int);"
        # inside a body) declares an external function, not a local object. This
        # subset does not model that, so it is rejected here rather than laid out
        # as if it were a variable. A function *pointer* local (Pointer with a
        # FunctionType target) is an ordinary 8-byte scalar and falls through.
        if decl.type.function?
          error_at(decl.token, "block-scope function declarations are not supported")
        end

        # A block-scope storage class changes where the object lives, not its
        # visibility beyond this block: `static` gives it a private file-scope
        # object (see #gen_block_static_decl) and `extern` merely references a
        # file-scope one (see #gen_block_extern_decl). Only an automatic object
        # takes an ordinary local slot.
        case decl.storage
        when :static
          gen_block_static_decl(decl, scope)
        when :extern
          gen_block_extern_decl(decl)
        # An array or a struct is an aggregate lowered onto a stack object; a
        # scalar (int, pointer) takes a vreg slot.
        else
          if decl.type.array? || decl.type.struct?
            gen_aggregate_decl(decl, scope)
          elsif wide128?(decl.type)
            gen_int128_decl(decl, scope)
          else
            gen_scalar_decl(decl, scope)
          end
        end
      end

      # A 128-bit local. Like a struct, it lives in a stack object (16 bytes here)
      # whose address is its value, not in a single vreg. A brace-wrapped scalar
      # initializer ("__int128 x = {5};") is unwrapped first; every initializer is
      # then converted to the 128-bit type (widening a narrower source with sign or
      # zero fill) and copied into the object with #store_int128.
      def gen_int128_decl(decl, scope)
        base = bind_stack_object(scope, decl.name, decl.type, decl.const)
        return unless decl.initializer

        value_node = decl.initializer
        if value_node.is_a?(Front::AST::InitializerList)
          value_node = Front::InitializerResolver.resolve(decl.type, value_node).entries.first.value
        end
        value, value_type = gen_value(value_node)
        unless compatible_assignment?(decl.type, value_node, value_type)
          error_at(decl.token, "incompatible types in assignment")
        end
        store_int128(base, value, value_type, decl.type, decl.token)
      end

      # A block-scope `static` object. It has automatic-storage *scope* (visible
      # only in this block, named in `scope`) but static *storage*: it is lowered
      # to a uniquely named file-scope IR::Global with internal linkage, so it
      # persists across calls and is initialized once, at load time, with no
      # runtime initialization code. The unique name "<var>.<n>" cannot clash
      # with a real symbol, so two same-named block statics (in different
      # functions or blocks) get distinct objects. The binding is a global one,
      # so every access flows through the ordinary :global_addr path.
      def gen_block_static_decl(decl, scope)
        name = "#{decl.name}.#{@static_local_count}"
        @static_local_count += 1
        type = decl.type
        init = nil
        # The initializer must be a constant expression (6.7.8p4), folded through
        # the same global-initializer path that a file-scope object uses; a
        # non-constant element reaches "initializer element is not a constant"
        # there. Without an initializer the object is zero-filled in .bss.
        type, init = build_global_init(type, decl.initializer, decl.token) if decl.initializer
        require_complete(type, decl.token)
        scope[decl.name] = Local.new(type: type, storage: name, global: true, const: decl.const)
        @globals << Global.new(name: name, size: type.size, align: type.alignment,
                               init: init, linkage: :internal)
      end

      # A block-scope `extern` declaration references a file-scope object defined
      # elsewhere (this unit or another). It reserves no storage; it registers a
      # file-scope binding if the name is not already bound, so references resolve
      # to that external symbol (an undefined one if nothing defines it here).
      # M1 lets this binding outlive the block, a deliberate simplification.
      def gen_block_extern_decl(decl)
        require_complete(decl.type, decl.token)
        existing = @global_bindings[decl.name]
        if existing && existing.type != decl.type
          error_at(decl.token, "conflicting types for '#{decl.name}'")
        end
        @global_bindings[decl.name] ||=
          Local.new(type: decl.type, storage: decl.name, global: true, const: decl.const)
      end

      # A scalar local. A brace-wrapped initializer ("int x = {5};", 6.7.9p11) is
      # resolved to its single scalar value first; every other initializer is a
      # plain expression. The binding is created before the initializer runs, so
      # a (pathological) self-reference resolves to this very variable.
      def gen_scalar_decl(decl, scope)
        # A scalar's type is always complete for the built-in scalars, but a
        # forward-referenced enum ("enum E x;" with E undefined) reaches here as
        # an incomplete type that has no storage to reserve, so it is rejected.
        require_complete(decl.type, decl.token)
        vreg = new_vreg
        scope[decl.name] = Local.new(type: decl.type, storage: vreg, global: false, const: decl.const)
        return unless decl.initializer

        value_node = decl.initializer
        if value_node.is_a?(Front::AST::InitializerList)
          value_node = Front::InitializerResolver.resolve(decl.type, value_node).entries.first.value
        end
        value, value_type = gen_value(value_node)
        unless compatible_assignment?(decl.type, value_node, value_type)
          error_at(decl.token, "incompatible types in assignment")
        end
        emit(:copy, dst: vreg, a: convert_for_assignment(value, value_type, decl.type, token: decl.token))
      end

      # An aggregate local (array or struct). A structural initializer (a brace
      # list, or a string for a char array) is resolved — completing an inferred
      # "[]" bound — and lowered onto the stack object; a struct may also be
      # copy-initialized from a whole-struct expression ("struct s a = b;"). The
      # binding is created before the initializer is lowered so a member's
      # initializer could refer back to the object.
      def gen_aggregate_decl(decl, scope)
        type = decl.type
        init = decl.initializer

        if init && Front::InitializerResolver.structural?(type, init)
          resolved = Front::InitializerResolver.resolve(type, init)
          type = resolved.type
          require_complete(type, decl.token)
          base = bind_stack_object(scope, decl.name, type, decl.const)
          lower_resolved_init(base, type, resolved.entries)
          return
        end

        require_complete(type, decl.token)
        base = bind_stack_object(scope, decl.name, type, decl.const)
        return unless init

        # The only non-structural aggregate initializer is a whole-struct copy;
        # an array cannot be initialized from a scalar or another array here.
        if type.struct?
          src, src_type = gen_value(init)
          unless src_type == type
            error_at(decl.token, "incompatible types in initialization")
          end
          gen_struct_copy(base, src, type)
        else
          error_at(decl.token, "invalid initializer for array (expected '{' or a string)")
        end
      end

      # Reserves a stack object for `type`, binds `name` to it, and returns a
      # vreg holding the object's base address (the destination every placement
      # is written through).
      def bind_stack_object(scope, name, type, const)
        object_id = new_object(type.size)
        scope[name] = Local.new(type: type, storage: object_id, global: false, const: const)
        base = new_vreg
        emit(:object_addr, dst: base, a: object_id)
        base
      end

      # Lowers a resolved aggregate initializer onto the object at `base`. The
      # object is zeroed whole first, then each explicit placement overwrites its
      # slot, so any unspecified byte (struct padding, an array's tail, a
      # string's NUL) reads as 0 with no bookkeeping over which ranges stay
      # untouched. Each scalar is converted to its slot's type like an ordinary
      # assignment; a string is written as immediate bytes.
      def lower_resolved_init(base, type, entries)
        zero_fill(base, type.size)
        entries.each do |entry|
          case entry
          when Front::ScalarInit
            addr = offset_address(base, entry.offset)
            value, value_type = gen_value(entry.value)
            unless compatible_assignment?(entry.type, entry.value, value_type)
              error_at(entry.value.token, "incompatible types in initialization")
            end
            converted = convert_for_assignment(value, value_type, entry.type, token: entry.value.token)
            emit(:store, a: addr, b: converted, size: entry.type.size)
          when Front::StringInit
            write_string_bytes(base, entry.offset, entry.bytes)
          end
        end
      end

      # Zeroes `size` bytes at `base`, using the widest store that still fits at
      # each step (8, then 4/2/1 for the tail) so any object size is covered by a
      # handful of stores from a single zero register.
      def zero_fill(base, size)
        zero = new_vreg
        emit(:const, dst: zero, a: 0, size: 8)
        offset = 0
        [8, 4, 2, 1].each do |chunk|
          while size - offset >= chunk
            emit(:store, a: offset_address(base, offset), b: zero, size: chunk)
            offset += chunk
          end
        end
      end

      # Writes a char array's string initializer as a run of 1-byte immediate
      # stores. Immediate bytes (rather than a memcpy from an interned .rodata
      # copy) keep a char-array initializer out of the string pool; the earlier
      # whole-object zeroing already supplied the terminating NUL and any tail.
      def write_string_bytes(base, offset, bytes)
        bytes.each_byte.with_index do |byte, i|
          value = new_vreg
          emit(:const, dst: value, a: byte)
          emit(:store, a: offset_address(base, offset + i), b: value, size: 1)
        end
      end

      # A vreg holding `base + offset`, or `base` itself when the offset is zero
      # (the object's first byte needs no arithmetic).
      def offset_address(base, offset)
        return base if offset.zero?

        off = new_vreg
        emit(:const, dst: off, a: offset)
        addr = new_vreg
        emit(:add, dst: addr, a: base, b: off, size: 8)
        addr
      end

      # Lowers an expression, returning [result_vreg, Rubycc::Type]. The type
      # travels alongside the value so every caller can type-check its operands
      # and pick the right access width for pointer loads and stores.
      def gen_expr(node)
        case node
        when Front::AST::IntLit
          dst = new_vreg
          # The literal's type is fixed by the parser (6.4.4.1); a long/unsigned
          # long constant loads a full 64-bit immediate so its high half is
          # valid, a narrower one a 32-bit immediate.
          emit(:const, dst: dst, a: node.value, size: (8 if node.type.size == 8))
          [dst, node.type]
        when Front::AST::FloatLit
          gen_float_literal(node)
        when Front::AST::StringLit
          gen_string_literal(node)
        when Front::AST::Unary
          gen_unary(node)
        when Front::AST::Binary
          gen_binary(node)
        when Front::AST::VariableRef
          gen_variable_ref(node)
        when Front::AST::Subscript
          gen_subscript(node)
        when Front::AST::MemberAccess
          gen_member_access(node)
        when Front::AST::SizeofExpr
          gen_sizeof(sizeof_operand_type(node.operand), node.token)
        when Front::AST::SizeofType
          gen_sizeof(node.type, node.token)
        when Front::AST::AlignofType
          gen_alignof(node.type, node.token)
        when Front::AST::BuiltinOffsetof
          gen_offsetof(node)
        when Front::AST::Cast
          gen_cast(node)
        when Front::AST::CompoundLiteral
          gen_compound_literal(node)
        when Front::AST::Assignment
          gen_assignment(node)
        when Front::AST::Call
          gen_call(node)
        when Front::AST::LogicalAnd
          gen_logical_and(node)
        when Front::AST::LogicalOr
          gen_logical_or(node)
        when Front::AST::Conditional
          gen_conditional(node)
        when Front::AST::CompoundAssignment
          gen_compound_assignment(node)
        when Front::AST::IncDec
          gen_inc_dec(node)
        when Front::AST::Comma
          gen_comma(node)
        when Front::AST::StatementExpr
          gen_statement_expr(node)
        when Front::AST::VaStart
          gen_va_start(node)
        when Front::AST::VaArg
          gen_va_arg(node)
        when Front::AST::VaEnd
          gen_va_end(node)
        when Front::AST::BuiltinExpect
          gen_builtin_expect(node)
        when Front::AST::BuiltinAlloca
          gen_builtin_alloca(node)
        when Front::AST::BuiltinConstantP
          gen_builtin_constant_p(node)
        when Front::AST::BuiltinBitScan
          gen_builtin_bit_scan(node)
        when Front::AST::BuiltinUnreachable
          gen_builtin_unreachable(node)
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      # "left, right": evaluate `left` for its side effects and throw its value
      # away, then evaluate `right`, whose value and type are the comma
      # expression's. `left` is lowered with #gen_expr rather than #gen_value so
      # a void-typed left operand (a call to a void function) is allowed in the
      # discarded position, matching an expression-statement.
      def gen_comma(node)
        gen_expr(node.left)
        gen_expr(node.right)
      end

      # A GNU statement expression "( { block-item* } )". The braces are a
      # compound-statement, so a fresh scope is pushed for the block's locals
      # and popped at its end, exactly as #gen_block does. Every block-item but
      # the last is lowered as an ordinary statement (for its side effects);
      # when the last item is an expression-statement, its expression is lowered
      # with #gen_expr and its value and type become the whole construct's.
      # Otherwise (an empty block, or a last item that is not an
      # expression-statement) the construct is void — a placeholder value the
      # discarding contexts (an expression-statement, a comma operand) ignore,
      # and #gen_value rejects wherever a value is actually required.
      def gen_statement_expr(node)
        items = node.body.items
        @scopes.push({})
        begin
          result = [nil, Type::Void]
          items.each_with_index do |item, index|
            if index == items.size - 1 && item.is_a?(Front::AST::ExpressionStmt)
              result = gen_expr(item.expr)
            else
              gen_statement(item)
            end
          end
          result
        ensure
          @scopes.pop
        end
      end

      # "__builtin_va_start(ap, last)": initializes `ap` so a following
      # __builtin_va_arg can walk the variable arguments. It is only valid inside
      # a variadic function (a fixed-arity one has no variable part to point at),
      # and `last` must name that function's last fixed parameter (6.7.6.3 anchors
      # the variable part just past it). The single :va_start op carries the
      # va_list address and the fixed parameter count, from which the backend
      # fills the four System V fields against its register-save area. The value
      # is void — va_start is only ever an expression-statement.
      def gen_va_start(node)
        unless @current_variadic
          error_at(node.token, "'va_start' used in function with fixed arguments")
        end
        ap = gen_va_list_address(node.ap, node.token, "va_start")
        last = @current_named_params.last
        if last.nil? || last.name != node.last_name
          error_at(node.token, "second argument to 'va_start' is not the last named parameter")
        end
        emit(:va_start, a: ap, b: @current_named_params.size)
        [ap, Type::Void]
      end

      # "__builtin_va_arg(ap, type)": fetches the next variable argument as
      # `type` and advances `ap`, lowered entirely to existing IR (no dedicated
      # op). Following the System V register-save-area convention it reads
      # gp_offset: while it is below 48 the argument still sits in a saved
      # register (reg_save_area + gp_offset, then gp_offset += 8); once it reaches
      # 48 the argument has spilled onto the stack (overflow_arg_area, then that
      # pointer += 8). Both arms deposit the argument's address into one slot the
      # merge point loads through, the load width and signedness following `type`.
      # Only an int/long/unsigned/pointer-sized object type is admissible (see
      # #require_va_arg_type); a promotable or aggregate type is diagnosed.
      def gen_va_arg(node)
        ap = gen_va_list_address(node.ap, node.token, "va_arg")
        type = node.type
        require_va_arg_type(type, node.token)

        result_addr = new_vreg
        overflow_label = new_label
        end_label = new_label

        # A double walks the SSE side of the register-save area (fp_offset), an
        # integer/pointer the GP side (gp_offset); the two counters advance
        # independently, so a mixed argument list reaches each argument's slot.
        if type.float?
          fp_field = offset_address(ap, Type::VaListTag.member("fp_offset").offset)
          emit_va_arg_fp_dispatch(ap, fp_field, result_addr, overflow_label, end_label)
        else
          gp_field = offset_address(ap, Type::VaListTag.member("gp_offset").offset)
          emit_va_arg_dispatch(ap, gp_field, result_addr, overflow_label, end_label)
        end

        dst = new_vreg
        emit_scalar_load(dst, result_addr, type)
        [dst, type]
      end

      # Emits the register-vs-overflow branch of a va_arg. `gp_field` addresses
      # the va_list's gp_offset; `result_addr` is the slot both arms leave the
      # argument's address in.
      def emit_va_arg_dispatch(ap, gp_field, result_addr, overflow_label, end_label)
        # gp = gp_offset; if gp >= 48 the argument is on the stack.
        gp = new_vreg
        emit(:uload, dst: gp, a: gp_field, size: 4)
        limit = new_vreg
        emit(:const, dst: limit, a: 48)
        below = new_vreg
        emit(:ult, dst: below, a: gp, b: limit)
        emit(:jump_if_zero, a: below, b: overflow_label)

        # Register arm: addr = reg_save_area + gp; gp_offset += 8.
        reg_save = new_vreg
        emit(:load, dst: reg_save, a: offset_address(ap, Type::VaListTag.member("reg_save_area").offset), size: 8)
        gp_wide = convert(gp, from: Type::UInt, to: Type::Long)
        reg_addr = new_vreg
        emit(:add, dst: reg_addr, a: reg_save, b: gp_wide, size: 8)
        emit(:copy, dst: result_addr, a: reg_addr)
        emit(:store, a: gp_field, b: bump(gp, 8), size: 4)
        emit(:jump, a: end_label)

        # Overflow arm: addr = overflow_arg_area; overflow_arg_area += 8.
        emit(:label, a: overflow_label)
        overflow_field = offset_address(ap, Type::VaListTag.member("overflow_arg_area").offset)
        overflow = new_vreg
        emit(:load, dst: overflow, a: overflow_field, size: 8)
        emit(:copy, dst: result_addr, a: overflow)
        emit(:store, a: overflow_field, b: bump(overflow, 8, size: 8), size: 8)
        emit(:label, a: end_label)
      end

      # The SSE counterpart of #emit_va_arg_dispatch, for a va_arg(double). It
      # reads fp_offset, which the register-save area seeds at 48 (past the six
      # GP slots) and steps by 16 (an xmm slot is 16 bytes wide) per double: while
      # it is below 176 (48 + 8*16, the end of the eight saved xmm registers) the
      # argument still sits in a saved register (reg_save_area + fp_offset), and
      # once it reaches 176 the argument has spilled onto the stack
      # (overflow_arg_area, advanced by 8 like a GP overflow, a double occupying
      # one eightbyte there). Both arms leave the argument's address in
      # `result_addr` for the size-8 load the merge point performs.
      def emit_va_arg_fp_dispatch(ap, fp_field, result_addr, overflow_label, end_label)
        fp = new_vreg
        emit(:uload, dst: fp, a: fp_field, size: 4)
        limit = new_vreg
        emit(:const, dst: limit, a: 176)
        below = new_vreg
        emit(:ult, dst: below, a: fp, b: limit)
        emit(:jump_if_zero, a: below, b: overflow_label)

        # Register arm: addr = reg_save_area + fp; fp_offset += 16.
        reg_save = new_vreg
        emit(:load, dst: reg_save, a: offset_address(ap, Type::VaListTag.member("reg_save_area").offset), size: 8)
        fp_wide = convert(fp, from: Type::UInt, to: Type::Long)
        reg_addr = new_vreg
        emit(:add, dst: reg_addr, a: reg_save, b: fp_wide, size: 8)
        emit(:copy, dst: result_addr, a: reg_addr)
        emit(:store, a: fp_field, b: bump(fp, 16), size: 4)
        emit(:jump, a: end_label)

        # Overflow arm: addr = overflow_arg_area; overflow_arg_area += 8.
        emit(:label, a: overflow_label)
        overflow_field = offset_address(ap, Type::VaListTag.member("overflow_arg_area").offset)
        overflow = new_vreg
        emit(:load, dst: overflow, a: overflow_field, size: 8)
        emit(:copy, dst: result_addr, a: overflow)
        emit(:store, a: overflow_field, b: bump(overflow, 8, size: 8), size: 8)
        emit(:label, a: end_label)
      end

      # A vreg holding `value + amount`. `size` selects 32- or 64-bit addition
      # (8 for a pointer bump, the default 4 for the gp_offset counter).
      def bump(value, amount, size: nil)
        addend = new_vreg
        emit(:const, dst: addend, a: amount)
        dst = new_vreg
        emit(:add, dst: dst, a: value, b: addend, size: size)
        dst
      end

      # "__builtin_va_end(ap)": ends traversal of `ap`. System V keeps no state
      # to tear down, so beyond type-checking the operand this emits nothing; its
      # value is void, like va_start.
      def gen_va_end(node)
        ap = gen_va_list_address(node.ap, node.token, "va_end")
        [ap, Type::Void]
      end

      # "__builtin_expect(exp, c)": gcc's branch-prediction hint, typed
      # `long(long, long)`. rubycc has no optimizer, so the hint carries no
      # weight — it evaluates both operands left to right, converting each to the
      # `long` parameter type, and its value is the converted `exp`. `c` is
      # evaluated for its side effects (it is an ordinary argument) and discarded.
      def gen_builtin_expect(node)
        exp = convert_builtin_argument_to_long(node.exp, "__builtin_expect")
        convert_builtin_argument_to_long(node.c, "__builtin_expect") # evaluated, discarded
        [exp, Type::Long]
      end

      # Evaluates a __builtin_expect operand and converts it to `long`, the
      # parameter type. Any scalar (integer, pointer or floating value) converts
      # the way an argument bound to a `long` parameter would; a non-scalar has
      # no such conversion and is diagnosed.
      def convert_builtin_argument_to_long(expr, name)
        value, type = gen_value(expr)
        unless type.integer? || type.pointer? || type.float?
          error_at(expr.token, "argument to '#{name}' is not of scalar type")
        end
        convert(value, from: type, to: Type::Long, token: expr.token)
      end

      # "__builtin_alloca(n)": reserves `n` bytes of automatic storage on the
      # stack, freed when the enclosing *function* returns. The count is
      # converted to `unsigned long` (the size_t parameter) and passed to the
      # :alloca op, which rounds it up to a 16-byte multiple and lowers rsp; the
      # value is the block's base address, a `void *` the ABI keeps 16-aligned.
      def gen_builtin_alloca(node)
        size, type = gen_value(node.size)
        unless type.integer?
          error_at(node.size.token, "argument to '__builtin_alloca' is not of integer type")
        end
        size = convert(size, from: type, to: Type::ULong)
        dst = new_vreg
        emit(:alloca, dst: dst, a: size)
        [dst, Type::Pointer.new(Type::Void)]
      end

      # "__builtin_constant_p(expr)": folds to the int 1 when `expr` reduces to a
      # compile-time constant and 0 otherwise. The whole node is handed to the
      # constant evaluator, which never raises for this form (it swallows a
      # non-constant operand to 0), so the result is always a plain :const. The
      # operand is never evaluated for value, so it produces no code or side
      # effects — matching gcc.
      def gen_builtin_constant_p(node)
        dst = new_vreg
        emit(:const, dst: dst, a: Front::ConstantEvaluator.evaluate(node))
        [dst, Type::Int]
      end

      # "__builtin_ctz/ctzll/clz/clzll(x)": counts x's trailing (ctz) or leading
      # (clz) zero bits, as an int. The operand is converted to the unsigned
      # integer of the builtin's width (4 or 8 bytes), then a single :bit_scan op
      # lowers to bsf (forward/ctz) or bsr-based (reverse/clz) hardware. A
      # zero operand is undefined behavior (gcc), so no zero handling is emitted.
      def gen_builtin_bit_scan(node)
        value, type = gen_value(node.operand)
        unless type.integer?
          error_at(node.operand.token, "argument to a bit-scan builtin is not of integer type")
        end
        value = convert(value, from: type, to: node.width == 8 ? Type::ULong : Type::UInt,
                               token: node.token)
        dst = new_vreg
        emit(:bit_scan, dst: dst, a: value, b: node.direction, size: node.width)
        [dst, Type::Int]
      end

      # "__builtin_unreachable()": an optimization hint that control never reaches
      # this point. rubycc does no optimization, so it lowers to no code and its
      # value is void — a placeholder the discarding contexts (a comma operand, an
      # expression-statement, a "?:" void arm) ignore. This is what lets CRuby's
      # UNREACHABLE_RETURN ("(__builtin_unreachable(), value)") compile.
      def gen_builtin_unreachable(_node)
        [nil, Type::Void]
      end

      # Evaluates a va_* builtin's first operand and returns the vreg holding the
      # address of its __va_list_tag. Both a local `__builtin_va_list` (a one-tag
      # array that decays to a __va_list_tag *) and a forwarded parameter (a
      # __va_list_tag * after the 6.7.6.3 adjustment) yield exactly that pointer,
      # so the one type check — a pointer to the shared VaListTag — covers both
      # and rejects anything else (`builtin` names the site in the diagnostic).
      def gen_va_list_address(node, token, builtin)
        ap, ap_type = gen_value(node)
        unless ap_type.pointer? && ap_type.target == Type::VaListTag
          error_at(token, "first argument to '#{builtin}' is not of type '__builtin_va_list'")
        end
        ap
      end

      # Rejects a va_arg type-name that cannot be fetched. A char/short/_Bool (or
      # their unsigned forms) is of promotable type: it was widened to int by the
      # default argument promotions at the call, so va_arg(char) would read the
      # wrong width — the caller must use the promoted type. A struct/union, void,
      # function or array has no scalar argument slot to read here at all. Only an
      # int/unsigned/long/unsigned long (enum being int already) or a pointer is
      # admissible.
      def require_va_arg_type(type, token)
        if type.integer? && type.size < 4
          error_at(token, "second argument to 'va_arg' is of promotable type '#{type}'")
        end
        # `float` is of promotable type too: the default argument promotions
        # widened it to `double` at the call, so va_arg(float) would read the
        # wrong width — the caller must use `double`. (double itself is fine.)
        if type.float? && type.size == 4
          error_at(token, "second argument to 'va_arg' is of promotable type '#{type}'")
        end
        return if (type.integer? && type.size >= 4) || type.pointer? || (type.float? && type.size == 8)

        error_at(token, "second argument to 'va_arg' has type '#{type}', which va_arg cannot yield")
      end

      # Lowers `node` for its value like #gen_expr, but rejects a void result:
      # the only expression a void type can have is a call to a void function,
      # and C only allows that call's (non-)value to be discarded as a whole
      # expression-statement, never consumed as an operand. Every context that
      # actually uses the value it gets back (an operand, an argument, an
      # initializer, a condition, ...) goes through this instead of #gen_expr.
      def gen_value(node)
        value, type = gen_expr(node)
        error_at(node.token, "void value not ignored as it ought to be") if type.void?
        [value, type]
      end

      # A variable reference. A local scalar yields its slot directly; an array
      # "decays" to a pointer to its first element (its base address), which is
      # the value every expression context except sizeof and unary "&" sees. A
      # global is read through its address (see #gen_global_ref). A name that
      # binds no variable but names a function is a function designator, which
      # decays to a pointer to that function (see #gen_function_designator).
      def gen_variable_ref(node)
        local = lookup_variable(node.name)
        return gen_function_designator(node.name, node.token) unless local
        return gen_global_ref(local) if local.global

        if local.type.array?
          dst = new_vreg
          emit(:object_addr, dst: dst, a: local.storage)
          [dst, Type::Pointer.new(local.type.element)]
        elsif local.type.struct? || wide128?(local.type)
          # Neither a struct nor a 128-bit integer decays or lives in a single
          # vreg: like a struct, a 128-bit local's "value" is its object's base
          # address, which member/half access, "&" and assignment build on.
          # Nothing is loaded here.
          dst = new_vreg
          emit(:object_addr, dst: dst, a: local.storage)
          [dst, local.type]
        else
          [read_local_scalar(local), local.type]
        end
      end

      # A file-scope variable reference. Its address is materialized with
      # :global_addr; an array decays to that base address (a pointer to its
      # first element), while a scalar is loaded through it, the width following
      # its type (a size-1 char load already re-extends the byte, so no aliasing
      # fix like a local's is needed).
      def gen_global_ref(local)
        addr = new_vreg
        emit_global_addr(addr, local.storage)
        if local.type.array?
          [addr, Type::Pointer.new(local.type.element)]
        elsif local.type.struct? || wide128?(local.type)
          # Like a local struct or 128-bit integer (and unlike a scalar global),
          # its value is its base address, not a load: it keeps its own type.
          [addr, local.type]
        else
          dst = new_vreg
          emit_scalar_load(dst, addr, local.type)
          [dst, local.type]
        end
      end

      # A function designator that appears anywhere but the callee of a call
      # (or under sizeof) decays to a pointer to the function (6.3.2.1p4), so
      # "fp = f", "&f", passing "f" as an argument and comparing two function
      # names all see the same Pointer(FunctionType) value. Its value is the
      # function's own address, materialized by :func_addr — or, under -fPIC for
      # a function this unit does not define, loaded from the GOT (:got_addr); a
      # name that is neither a visible variable nor a declared function is
      # undeclared.
      def gen_function_designator(name, token)
        sig = @signatures[name]
        error_at(token, "undeclared variable '#{name}'") unless sig

        dst = new_vreg
        emit(pic_extern_func?(name) ? :got_addr : :func_addr, dst: dst, a: name)
        [dst, Type::Pointer.new(function_type_of(sig))]
      end

      # Materializes the address of the file-scope object named `symbol` into
      # `dst`: a PC-relative :global_addr normally, or a GOT load (:got_addr)
      # under -fPIC for an object this unit does not define (see #pic_extern?).
      # Every :global_addr site of a file-scope *object* routes through here so
      # the PIC choice is made in one place.
      def emit_global_addr(dst, symbol)
        emit(pic_extern_object?(symbol) ? :got_addr : :global_addr, dst: dst, a: symbol)
      end

      # Whether a reference to the file-scope object `name` must go through the
      # GOT: only under -fPIC, and only when this translation unit does not
      # define the object itself. @object_records holds every name given a
      # (tentative or real) definition here — a `static` or ordinary global —
      # while a bare `extern` reference reserves no storage and gets no record,
      # so it is the external case. (An object defined later in the unit than the
      # reference is not yet recorded and so is treated as external: still
      # correct, since its GOT slot resolves to the local definition, only a slot
      # slower — the L4 trade-off that favors correctness over that one case.)
      def pic_extern_object?(name)
        @pic && !@object_records.key?(name)
      end

      # Whether a reference to the function `name` must go through the GOT: only
      # under -fPIC, and only when this translation unit does not define the
      # function (its signature is present but not yet `defined`). A function
      # defined here keeps the PC-relative :func_addr, being resolved within this
      # DSO; its call sites stay PLT32 regardless, PLT stubs being the linker's.
      def pic_extern_func?(name)
        @pic && !@signatures.dig(name, :defined)
      end

      # A floating literal. No dedicated IR op exists: the constant is lowered to
      # its IEEE754 bit pattern (single for float, double for double) loaded as
      # an ordinary 64-bit integer immediate, which the value representation
      # keeps intact in the slot's low bytes until a floating op reads it back
      # through movss/movsd. The whole slot is loaded (size 8) even for a float,
      # whose pattern occupies only the low 32 bits with the high half zero.
      def gen_float_literal(node)
        dst = new_vreg
        emit(:const, dst: dst, a: float_bit_pattern(node.value, node.type), size: 8)
        [dst, node.type]
      end

      # The IEEE754 bit pattern of a Ruby Float as an unsigned Integer, in the
      # width `type` calls for: a double packs to 8 bytes ("E" little-endian
      # double) and reads back as a little-endian unsigned integer, while a
      # float goes through #double_to_binary32_bits (not pack("e"), which
      # saturates to infinity instead of rounding to FLT_MAX near the top of
      # binary32's range) so :const materializes exactly those bits.
      def float_bit_pattern(value, type)
        if type.size == 8
          [value].pack("E").unpack1("Q<")
        else
          double_to_binary32_bits(value)
        end
      end

      # Materializes a floating constant of `type` into a fresh vreg, used by the
      # truth/zero tests that compare a floating value against 0.0.
      def emit_float_const(value, type)
        dst = new_vreg
        emit(:const, dst: dst, a: float_bit_pattern(value, type), size: 8)
        dst
      end

      # A string literal decays, in every expression context, to a char *
      # pointing at its bytes in the read-only pool. The bytes are interned
      # (deduplicated) and :string_addr loads the resulting address.
      def gen_string_literal(node)
        id = intern_string(node.value)
        dst = new_vreg
        emit(:string_addr, dst: dst, a: id)
        [dst, Type::Pointer.new(@plain_char)]
      end

      # "e[i]" read: compute the element address (see #gen_element_address) and,
      # for a scalar element, load through it. A struct element does not load —
      # like a struct variable its value is its (element) address — so indexing
      # an array of structs yields the addressed struct.
      def gen_subscript(node)
        addr, element_type = gen_element_address(node)
        return [addr, element_type] if element_type.struct? || wide128?(element_type)

        dst = new_vreg
        emit_scalar_load(dst, addr, element_type)
        [dst, element_type]
      end

      # "s.m" / "p->m" read: resolve the member (see #resolve_member) and yield
      # its value. A bit-field is extracted with a shift and mask (see
      # #gen_bitfield_load); a whole-byte scalar is loaded through its address; a
      # struct member yields its own address (a nested struct lvalue) and an array
      # member decays to a pointer to its first element, matching how a struct
      # variable and an array variable each behave.
      def gen_member_access(node)
        base_addr, member = resolve_member(node)
        return gen_bitfield_load(base_addr, member) if member.bitfield?

        member_type = member.type
        addr = member_field_address(base_addr, member)
        if member_type.struct? || wide128?(member_type)
          [addr, member_type]
        elsif member_type.array?
          [addr, Type::Pointer.new(member_type.element)]
        else
          dst = new_vreg
          emit_scalar_load(dst, addr, member_type)
          [dst, member_type]
        end
      end

      # Resolves a "." / "->" selection to [base_struct_address, Member],
      # evaluating the selected-from object exactly once (see #gen_struct_base).
      # Every member read, write, compound assignment and "&" shares it, then
      # branches on whether the member is a bit-field or occupies whole bytes.
      def resolve_member(node)
        base_addr, struct_type = gen_struct_base(node)
        member = struct_type.member(node.member)
        unless member
          error_at(node.token, "no member named '#{node.member}' in '#{struct_type}'")
        end
        [base_addr, member]
      end

      # The address of a struct member — the lvalue shared by member reads and
      # writes and by "&s.m". It is the base struct's address (see
      # #gen_member_address) plus the member's constant byte offset; a zero offset
      # (the first member) needs no arithmetic. A bit-field has no byte address,
      # so this is only reached for a whole-byte member.
      def gen_member_address(node)
        base_addr, member = resolve_member(node)
        # A bit-field occupies a fraction of a storage unit, so "&s.field" would
        # not name a whole-byte object (6.5.3.2p1 forbids "&" on it).
        if member.bitfield?
          error_at(node.token, "cannot take address of bit-field '#{node.member}'")
        end
        [member_field_address(base_addr, member), member.type]
      end

      # The address of a whole-byte member: the base struct's address plus the
      # member's constant byte offset (no arithmetic for a zero-offset member).
      def member_field_address(base_addr, member)
        offset_address(base_addr, member.offset)
      end

      # `base_addr` displaced by a constant `byte_offset`; the base is returned
      # unchanged for a zero displacement. Used both for a member's byte offset
      # and for a bit-field's storage-unit offset.
      def offset_address(base_addr, byte_offset)
        return base_addr if byte_offset.zero?

        offset = new_vreg
        emit(:const, dst: offset, a: byte_offset)
        addr = new_vreg
        emit(:add, dst: addr, a: base_addr, b: offset, size: 8)
        addr
      end

      # A bit-field's storage unit: its byte address (base + the unit's byte
      # offset within the struct) and the field's shift (its low bit's position
      # inside that unit). The layout guarantees a field never straddles a unit,
      # so one aligned load/store of the declared type's width covers it. Returns
      # [unit_address, shift].
      def bitfield_unit(base_addr, member)
        unit_bytes = member.type.size
        unit_bits = unit_bytes * 8
        unit_offset = (member.bit_offset / unit_bits) * unit_bytes
        shift = member.bit_offset % unit_bits
        [offset_address(base_addr, unit_offset), shift]
      end

      # The rvalue type a bit-field read produces (6.3.1.1): a field narrower
      # than int, or as wide as int but signed, promotes to int; an unsigned
      # field as wide as int stays unsigned int (its top value would not fit a
      # signed int); a long-based field keeps its own 64-bit type (it does not
      # promote). A _Bool field promotes to int, its value being 0 or 1.
      def bitfield_promoted_type(member)
        type = member.type
        return type if type.size >= 8
        return Type::UInt if type.unsigned? && member.bit_width >= 32

        Type::Int
      end

      # Reads a bit-field: load its storage unit, bring the field down to bit 0
      # with a logical right shift, then sign- or zero-extend its `width` bits
      # (see #extract_bitfield_bits). The result is the promoted rvalue type.
      def gen_bitfield_load(base_addr, member)
        unit_addr, shift = bitfield_unit(base_addr, member)
        raw = new_vreg
        emit(:uload, dst: raw, a: unit_addr, size: member.type.size)
        raw = emit_shift(:shr, raw, shift, bitfield_op_size(member)) if shift.positive?
        extract_bitfield_bits(raw, member)
      end

      # Extends the low `width` bits of `raw` to the bit-field's promoted rvalue
      # value: a signed field left-justifies then arithmetically shifts back so
      # its sign bit replicates; an unsigned field masks off the higher bits (or,
      # when the field already fills the register, is left as loaded). Returns
      # [value_vreg, promoted_type].
      def extract_bitfield_bits(raw, member)
        result_type = bitfield_promoted_type(member)
        width = member.bit_width
        reg_bits = result_type.size * 8
        size = bitfield_op_size(member)
        if member.type.signed?
          top = reg_bits - width
          value = top.positive? ? emit_shift(:sar, emit_shift(:shl, raw, top, size), top, size) : raw
        elsif width < reg_bits
          value = emit_and_const(raw, (1 << width) - 1, size)
        else
          value = raw
        end
        [value, result_type]
      end

      # Writes `value` (of `value_type`) into a bit-field by read-modify-write:
      # convert the value to the field's declared type (normalizing a _Bool to
      # 0/1), load the storage unit, clear the field's bits, splice the value's
      # low `width` bits in at the field's shift, and store the unit back so the
      # neighbouring fields sharing it are untouched. The expression's value is
      # the truncated field read back — the same bits #gen_bitfield_load would
      # yield — which for a signed field is sign-extended (gcc's rule).
      def store_bitfield(base_addr, member, value, value_type, token)
        unit_addr, shift = bitfield_unit(base_addr, member)
        size = bitfield_op_size(member)
        width = member.bit_width
        mask = (1 << width) - 1
        converted = convert_for_assignment(value, value_type, member.type, token: token)

        old = new_vreg
        emit(:uload, dst: old, a: unit_addr, size: member.type.size)
        cleared = emit_and_const(old, ~(mask << shift), size)
        field = emit_and_const(converted, mask, size)
        field = emit_shift(:shl, field, shift, size) if shift.positive?
        merged = new_vreg
        emit(:or, dst: merged, a: cleared, b: field, size: size)
        emit(:store, a: unit_addr, b: merged, size: member.type.size)

        extract_bitfield_bits(converted, member)
      end

      # The IR operand size for a bit-field's storage-unit arithmetic: 8 (64-bit)
      # for a long-based unit, otherwise the default 32-bit width (nil), which
      # covers every unit up to four bytes and the int/unsigned int promoted type.
      def bitfield_op_size(member)
        8 if member.type.size == 8
      end

      # Emits "value op count" for a shift op (:shl/:sar/:shr) with a constant
      # count, materializing the count into a fresh vreg the backend reads from
      # cl. Returns the result vreg.
      def emit_shift(op, value, count, size)
        count_reg = new_vreg
        emit(:const, dst: count_reg, a: count)
        dst = new_vreg
        emit(op, dst: dst, a: value, b: count_reg, size: size)
        dst
      end

      # Emits "value & mask" with a constant mask, materializing the mask into a
      # fresh vreg (a full 64-bit immediate when size is 8). A negative Ruby mask
      # (a "~" clear mask) is packed by #emit_const to the operand width. Returns
      # the result vreg.
      def emit_and_const(value, mask, size)
        mask_reg = new_vreg
        emit(:const, dst: mask_reg, a: mask, size: size)
        dst = new_vreg
        emit(:and, dst: dst, a: value, b: mask_reg, size: size)
        dst
      end

      # Evaluates the object a "." or "->" selects from, returning
      # [struct_address_vreg, complete_struct_type]. For "->" the base is a
      # pointer to a struct (its value is the address directly); for "." the
      # base is a struct lvalue (its value is already an address). Either way an
      # incomplete struct is rejected, since its members are unknown.
      def gen_struct_base(node)
        base, base_type = gen_value(node.base)
        if node.arrow
          require_pointer_to_struct(base_type, node)
          struct_type = base_type.target
        else
          unless base_type.struct?
            error_at(node.token, "request for member '#{node.member}' in something not a structure")
          end
          struct_type = base_type
        end
        require_complete(struct_type, node.token)
        [base, struct_type]
      end

      # Guards the "->" form: its base must be a pointer, and that pointer's
      # target must be a struct. A non-pointer base (e.g. "s->m" on a struct
      # value, where "s.m" was meant) and a pointer to a non-struct are both
      # rejected with the same "not a structure" wording "." uses.
      def require_pointer_to_struct(base_type, node)
        unless base_type.pointer? && base_type.target.struct?
          error_at(node.token, "request for member '#{node.member}' in something not a structure")
        end
      end

      # sizeof folds to a compile-time constant of type size_t (unsigned long
      # here): the resolved type's byte size. The operand (for the expression
      # form) is never evaluated, so no code other than the constant is emitted.
      # void (an incomplete type with no size) is rejected, whether written
      # directly ("sizeof(void)") or reached through a void-returning call's
      # result type ("sizeof f()").
      def gen_sizeof(type, token)
        error_at(token, "invalid application of 'sizeof' to void type") if type.void?
        # A function type has no size (only a pointer to it does), whether
        # written directly ("sizeof(int (int))") or reached through an operand.
        error_at(token, "invalid application of 'sizeof' to a function type") if type.function?
        # An incomplete struct has no known size to fold, whether written
        # directly ("sizeof(struct node)" before it is defined) or reached
        # through an operand of that type.
        require_complete(type, token)

        dst = new_vreg
        # The size is small and non-negative, so a 32-bit mov (which zeroes the
        # upper half of rax) already leaves a valid 8-byte unsigned long value.
        emit(:const, dst: dst, a: type.size)
        [dst, Type::ULong]
      end

      # _Alignof folds to a size_t (unsigned long) constant, the resolved type's
      # alignment, mirroring #gen_sizeof: a void, function or incomplete type has
      # no alignment and is rejected the same way sizeof rejects a missing size.
      def gen_alignof(type, token)
        error_at(token, "invalid application of '_Alignof' to void type") if type.void?
        error_at(token, "invalid application of '_Alignof' to a function type") if type.function?
        require_complete(type, token)

        dst = new_vreg
        # An alignment is a small power of two, so a 32-bit mov already leaves a
        # valid unsigned long value (its upper half zeroed).
        emit(:const, dst: dst, a: type.alignment)
        [dst, Type::ULong]
      end

      # __builtin_offsetof folds to a size_t (unsigned long) constant, the byte
      # offset of the designated member, mirroring #gen_sizeof: the offset comes
      # straight from type information (via the constant evaluator, the same
      # fold a static initializer or array bound uses), so no code beyond the
      # constant is emitted and the aggregate is never materialized. A designator
      # that cannot name an offset — a non-aggregate or incomplete type, a
      # missing member, a subscript of a non-array, or a bit-field target — is
      # reported at the token the evaluator flags, with its specific wording.
      def gen_offsetof(node)
        offset = Front::ConstantEvaluator.evaluate(node)
        dst = new_vreg
        emit(:const, dst: dst, a: offset)
        [dst, Type::ULong]
      rescue Front::ConstantEvaluator::OffsetofError => e
        error_at(e.token, e.detail)
      end

      # A cast "( type-name ) operand". The destination type steers the whole
      # conversion, since the type-name grammar only ever yields an integer
      # type, void, a pointer or a bare struct:
      #   * "(void)e" evaluates e for its side effects and discards the value;
      #   * a pointer destination retags a pointer source (no code), turns a
      #     null pointer constant into a null pointer, and widens any other
      #     integer to a 64-bit address value, but rejects a struct;
      #   * an arithmetic destination converts an integer or pointer source to
      #     the destination type (#convert), and rejects a struct source;
      #   * a struct destination is never a valid cast target here.
      def gen_cast(node)
        target = node.type
        return gen_cast_to_void(node) if target.void?
        if target.struct?
          error_at(node.token, "conversion to non-scalar type requested")
        end

        value, value_type = gen_value(node.operand)
        if target.pointer?
          gen_cast_to_pointer(node, target, value, value_type)
        else
          gen_cast_to_arithmetic(node, target, value, value_type)
        end
      end

      # A compound literal "( type-name ) { ... }" (6.5.2.5). The unnamed object
      # is laid out on a stack object of the enclosing block and initialized in
      # place (see #gen_compound_literal_object); the whole expression is its
      # value, taken exactly as a variable of the same type would be — a struct
      # (or 128-bit integer) as its base address, an array decayed to a pointer
      # to its first element, and a scalar as a load through the object. The
      # object is a genuine lvalue, so "&(T){...}" reaches #gen_address_of
      # instead and takes its address there without loading.
      def gen_compound_literal(node)
        base, type = gen_compound_literal_object(node)
        if type.struct? || wide128?(type)
          [base, type]
        elsif type.array?
          [base, Type::Pointer.new(type.element)]
        else
          dst = new_vreg
          emit_scalar_load(dst, base, type)
          [dst, type]
        end
      end

      # Reserves and initializes a compound literal's unnamed object, returning
      # [base_address_vreg, object_type] with no rvalue conversion applied — the
      # non-decayed lvalue both #gen_compound_literal (which then converts) and
      # #gen_address_of (which takes the address) build on. Every scalar/string
      # placement the resolver produces is lowered onto the object exactly like a
      # local aggregate declaration, so a partially designated literal has its
      # unspecified members zero-filled and a fresh initialization runs on each
      # evaluation (e.g. once per loop iteration). A scalar or array literal is
      # supported too, not only aggregates, so it also carries the whole-object
      # zeroing and placement path rather than a single store.
      def gen_compound_literal_object(node)
        type = node.type
        require_complete(type, node.token)
        object_id = new_object(type.size)
        base = new_vreg
        emit(:object_addr, dst: base, a: object_id)
        resolved = Front::InitializerResolver.resolve(type, node.initializer)
        lower_resolved_init(base, resolved.type, resolved.entries)
        [base, resolved.type]
      end

      # "(void)e": e is evaluated (with #gen_expr, not #gen_value, so a void
      # operand such as a call to a void function is allowed) and its value is
      # thrown away. The result is a void value, which nothing may consume —
      # #gen_value rejects it everywhere a value is actually needed, leaving
      # "(void)f();" as an expression-statement the one legal use.
      def gen_cast_to_void(node)
        value, = gen_expr(node.operand)
        [value, Type::Void]
      end

      # A cast to a pointer type. A pointer source is reinterpreted in place
      # (the value is the same 64-bit address, only its static type changes), a
      # null pointer constant becomes a 64-bit null pointer (its literal 0
      # already occupies the whole slot), and any other integer is widened to a
      # 64-bit address value by its own signedness (a signed int extends its
      # sign, an unsigned one zero-fills). A struct source has no pointer value
      # to take.
      def gen_cast_to_pointer(node, target, value, value_type)
        return [value, target] if value_type.pointer?
        return [value, target] if Front::AST.null_pointer_constant?(node.operand)
        if value_type.integer?
          # Widen to the pointer's 8-byte width. convert(to: Long) triggers the
          # size-8 path, extending by the source signedness; a source that is
          # already 8 bytes passes through.
          return [convert(value, from: value_type, to: Type::Long), target]
        end
        error_at(node.token, "cannot cast '#{value_type}' to '#{target}'")
      end

      # A cast to an arithmetic type. When a floating type is on either side the
      # source must itself be arithmetic and #convert lowers the int<->float or
      # float<->float change — unless the source is a floating-point constant
      # cast to an integer type, which #gen_folded_float_cast folds away at
      # compile time (6.3.1.4p1) before any conversion instruction is emitted,
      # sidestepping the run-time float<->`unsigned long` gap #convert still
      # diagnoses for a non-constant operand. Otherwise an integer source is
      # converted to the destination type (narrowing, widening or a sign
      # change, per #convert), and a pointer source is reinterpreted as an
      # unsigned 64-bit value and then converted to the destination width; a
      # struct source has no arithmetic value.
      def gen_cast_to_arithmetic(node, target, value, value_type)
        if target.float? || value_type.float?
          # A pointer has no floating value and a struct no arithmetic one; only
          # an arithmetic source converts to (or from) a floating type.
          unless value_type.arithmetic?
            error_at(node.token, "cannot cast '#{value_type}' to '#{target}'")
          end
          if value_type.float? && target.integer?
            folded = gen_folded_float_cast(node, target)
            return folded if folded
          end
          return [convert(value, from: value_type, to: target, token: node.token), target]
        end
        source_type = value_type.pointer? ? Type::ULong : value_type
        unless source_type.integer?
          error_at(node.token, "cannot cast '#{value_type}' to '#{target}'")
        end
        [convert(value, from: source_type, to: target), target]
      end

      # Folds "(int-type)floating-constant" to a plain :const, the same
      # truncating wrap ConstantEvaluator::evaluate_cast applies in a
      # constant-expression context, reused here by handing it the whole Cast
      # node. Returns nil (rather than raising) when the operand is not itself
      # a floating-point constant, so the caller falls back to the ordinary
      # run-time conversion.
      def gen_folded_float_cast(node, target)
        value = Front::ConstantEvaluator.evaluate(node)
        dst = new_vreg
        emit(:const, dst: dst, a: value, size: (8 if target.size == 8))
        [dst, target]
      rescue Front::ConstantEvaluator::NotConstant
        nil
      end

      # A binary operation. Its result type (and the legality of its operands)
      # is settled by #binary_result_type; the lowering then branches on the
      # operand kinds:
      #   * comparisons stay a single compare, widened to 64 bits when the
      #     operands are pointers;
      #   * pointer +/- int scales the int by the element size (64-bit);
      #   * pointer - pointer subtracts, then divides by the element size to
      #     yield an int element count;
      #   * everything else is ordinary 32-bit int arithmetic.
      def gen_binary(node)
        lhs, lhs_type = gen_value(node.lhs)
        rhs, rhs_type = gen_value(node.rhs)
        # "p == 0" / "0 != p": a null pointer constant compares equal or unequal
        # against any pointer. The bare operand types (pointer vs int) would
        # otherwise look mismatched, so recognize it here and compare at 64 bits
        # so the whole address participates. Only "==" and "!=" admit it; the
        # relational operators keep rejecting a pointer against 0.
        if EQUALITY_OPS.include?(node.op)
          if lhs_type.pointer? && Front::AST.null_pointer_constant?(node.rhs)
            return gen_pointer_null_comparison(node.op, lhs, rhs)
          elsif rhs_type.pointer? && Front::AST.null_pointer_constant?(node.lhs)
            return gen_pointer_null_comparison(node.op, lhs, rhs)
          end
        end
        gen_binary_op(node.op, lhs, lhs_type, rhs, rhs_type, node.token)
      end

      # "==" / "!=" between a pointer and a null pointer constant, compared at
      # 64 bits (the null constant's slot already holds a full-width 0). The
      # result is an int 0/1 like any other comparison.
      def gen_pointer_null_comparison(op, lhs, rhs)
        dst = new_vreg
        emit(op, dst: dst, a: lhs, b: rhs, size: 8)
        [dst, Type::Int]
      end

      # The value-level core of #gen_binary, factored out so compound
      # assignment and "++"/"--" (see #gen_compound_assignment, #gen_inc_dec)
      # can reuse the exact same lowering and type rules on operands they have
      # already evaluated into vregs, without re-walking an AST::Binary node.
      def gen_binary_op(op, lhs, lhs_type, rhs, rhs_type, token)
        result_type = binary_result_type(op, lhs_type, rhs_type, token)

        if comparison_op?(op)
          gen_comparison(op, lhs, lhs_type, rhs, rhs_type, token)
        elsif SHIFT_OPS.include?(op)
          gen_shift(op, lhs, lhs_type, rhs, result_type, token)
        elsif lhs_type.pointer? && rhs_type.pointer?
          gen_pointer_difference(lhs, rhs, lhs_type)
        elsif lhs_type.pointer?
          gen_pointer_int_arith(op, lhs, rhs, rhs_type, lhs_type)
        elsif rhs_type.pointer?
          # int + pointer (subtraction in this order was already rejected).
          gen_pointer_int_arith(op, rhs, lhs, lhs_type, rhs_type)
        elsif result_type.float?
          gen_float_arithmetic(op, lhs, lhs_type, rhs, rhs_type, result_type, token)
        else
          gen_integer_arithmetic(op, lhs, lhs_type, rhs, rhs_type, result_type, token)
        end
      end

      # A comparison, yielding int 0/1. Two pointers compare as full 64-bit
      # values: equality with the sign-independent :eq/:ne, ordering with the
      # unsigned :ult family, since an address is unsigned. Two arithmetic
      # operands are first brought to their common type (6.3.1.8); a floating
      # common type compares with the NaN-aware f-prefixed op (:feq..:fge), an
      # integer one with the signed or unsigned setcc its signedness selects
      # (64-bit only when the common type is 8 bytes). `token` locates an
      # unsupported-floating-conversion diagnostic a mixed unsigned-long/floating
      # comparison would raise.
      def gen_comparison(op, lhs, lhs_type, rhs, rhs_type, token)
        dst = new_vreg
        if lhs_type.pointer? && rhs_type.pointer?
          cmp = EQUALITY_OPS.include?(op) ? op : UNSIGNED_COMPARISONS.fetch(op)
          emit(cmp, dst: dst, a: lhs, b: rhs, size: 8)
        else
          common = common_arithmetic_type(lhs_type, rhs_type)
          l = convert(lhs, from: lhs_type, to: common, token: token)
          r = convert(rhs, from: rhs_type, to: common, token: token)
          # A 128-bit common type compares its two eightbytes (l and r are the
          # operands' addresses), signed or unsigned per the type's signedness.
          return gen_int128_comparison(op, l, r, common.signed?) if wide128?(common)

          if common.float?
            emit(FLOAT_COMPARISONS.fetch(op), dst: dst, a: l, b: r, size: common.size)
          else
            cmp = op
            cmp = UNSIGNED_COMPARISONS.fetch(op) if common.unsigned? && !EQUALITY_OPS.include?(op)
            emit(cmp, dst: dst, a: l, b: r, size: (8 if common.size == 8))
          end
        end
        [dst, Type::Int]
      end

      # Floating arithmetic (+ - * /). Both operands are converted to the common
      # floating type (the result type), then combined with the width-selecting
      # f-prefixed op. Reached only for :add/:sub/:mul/:div; % and the bitwise
      # operators reject a floating operand in #binary_result_type. `token`
      # locates an unsupported-conversion diagnostic.
      def gen_float_arithmetic(op, lhs, lhs_type, rhs, rhs_type, result_type, token)
        l = convert(lhs, from: lhs_type, to: result_type, token: token)
        r = convert(rhs, from: rhs_type, to: result_type, token: token)
        dst = new_vreg
        emit(FLOAT_ARITHMETIC.fetch(op), dst: dst, a: l, b: r, size: result_type.size)
        [dst, result_type]
      end

      # A shift promotes each operand on its own — never the usual arithmetic
      # conversion — and takes the promoted left operand's type as its result
      # (6.5.7), which #binary_result_type has already computed. "<<" is the
      # logical :shl; ">>" is the arithmetic :sar for a signed left operand and
      # the logical :shr for an unsigned one. The count rides in b (its low byte,
      # read from cl by the backend); a size-8 left operand shifts 64-bit.
      def gen_shift(op, lhs, lhs_type, rhs, result_type, token)
        # A 128-bit shift would need a multi-word shift-with-count lowering this
        # phase does not emit, so it is diagnosed (the count operand is untouched).
        if wide128?(result_type)
          spelling = op == :shl ? "<<" : ">>"
          error_at(token, "'#{spelling}' on 128-bit integers is not supported yet")
        end
        value = convert(lhs, from: lhs_type, to: result_type)
        opcode = if op == :shl
                   :shl
                 else
                   result_type.unsigned? ? :shr : :sar
                 end
        dst = new_vreg
        emit(opcode, dst: dst, a: value, b: rhs, size: (8 if result_type.size == 8))
        [dst, result_type]
      end

      # Ordinary integer arithmetic (+ - * / % and the bitwise & | ^). Both
      # operands are converted to their common type (which is the result type),
      # then combined; the additive, multiplicative and bitwise opcodes are
      # shared across signedness (their bit patterns coincide, wrap-around
      # included), while division and remainder pick the signed or unsigned
      # opcode. A common type of 8 bytes runs the operation 64-bit.
      def gen_integer_arithmetic(op, lhs, lhs_type, rhs, rhs_type, result_type, token)
        l = convert(lhs, from: lhs_type, to: result_type)
        r = convert(rhs, from: rhs_type, to: result_type)
        # A 128-bit result is synthesized from 64-bit ops on the halves (l and r
        # are the operands' addresses); only *, +, - are implemented, the rest
        # diagnosed by #gen_int128_arith.
        return [gen_int128_arith(op, l, r, token), result_type] if wide128?(result_type)

        opcode = case op
                 when :div then result_type.unsigned? ? :udiv : :div
                 when :mod then result_type.unsigned? ? :umod : :mod
                 else op
                 end
        dst = new_vreg
        emit(opcode, dst: dst, a: l, b: r, size: (8 if result_type.size == 8))
        [dst, result_type]
      end

      # pointer +/- int: scale the int index by the element size (as a 64-bit
      # byte offset) and add or subtract it from the pointer. The result has the
      # pointer's type.
      def gen_pointer_int_arith(op, ptr_vreg, int_vreg, int_type, ptr_type)
        offset = scale_index(int_vreg, int_type, ptr_type.target.size)
        dst = new_vreg
        emit(op, dst: dst, a: ptr_vreg, b: offset, size: 8)
        [dst, ptr_type]
      end

      # pointer - pointer (same type): the byte distance divided by the element
      # size, giving the number of elements between them as an int.
      def gen_pointer_difference(lhs_vreg, rhs_vreg, ptr_type)
        diff = new_vreg
        emit(:sub, dst: diff, a: lhs_vreg, b: rhs_vreg, size: 8)
        size_reg = new_vreg
        emit(:const, dst: size_reg, a: ptr_type.target.size)
        dst = new_vreg
        emit(:div, dst: dst, a: diff, b: size_reg, size: 8)
        [dst, Type::Int]
      end

      # Widens an index to a 64-bit byte offset and multiplies it by the element
      # size, yielding the offset used to index a pointer or array. The widening
      # follows the index's own signedness (a signed index sign-extends, so
      # p[-1] addresses the element below the pointer; an unsigned one
      # zero-extends), and an already-64-bit index passes through.
      def scale_index(index_vreg, index_type, element_size)
        wide = convert(index_vreg, from: index_type, to: Type::Long)
        size_reg = new_vreg
        emit(:const, dst: size_reg, a: element_size)
        scaled = new_vreg
        emit(:mul, dst: scaled, a: wide, b: size_reg, size: 8)
        scaled
      end

      # Computes the address of "e[i]" — the lvalue shared by subscript reads
      # and writes and by "&e[i]". The target decays to a pointer (an array
      # becomes a pointer to its first element); the int index is scaled by the
      # element size and added, exactly like "*(e + i)" (rejected up front when
      # the element type is void, since there is no size to scale by). Returns
      # [address_vreg, element_type].
      def gen_element_address(node)
        base, base_type = gen_value(node.target)
        element_type = subscript_element_type(base_type, node.token)
        error_at(node.token, "invalid use of void pointer") if element_type.void?
        # The element's size scales the index, so an incomplete struct element
        # (its width unknown) is rejected before it reaches #scale_index.
        require_complete(element_type, node.token)
        index, index_type = gen_value(node.index)
        unless index_type.integer?
          error_at(node.token, "array subscript is not an integer")
        end
        offset = scale_index(index, index_type, element_type.size)
        addr = new_vreg
        emit(:add, dst: addr, a: base, b: offset, size: 8)
        [addr, element_type]
      end

      def gen_unary(node)
        case node.op
        when :not
          gen_logical_not(node)
        when :neg
          operand, operand_type = gen_value(node.operand)
          unless operand_type.arithmetic?
            error_at(node.token, "wrong type argument to unary minus")
          end
          if wide128?(operand_type)
            error_at(node.token, "unary minus on a 128-bit integer is not supported yet")
          end
          return gen_float_negate(operand, operand_type) if operand_type.float?

          # Unary minus promotes its operand and negates in the promoted type,
          # so "-x" of a long is long (negated 64-bit) and of a char is int.
          result_type = integer_promote(operand_type)
          value = convert(operand, from: operand_type, to: result_type)
          dst = new_vreg
          emit(:neg, dst: dst, a: value, size: (8 if result_type.size == 8))
          [dst, result_type]
        when :addr
          gen_address_of(node)
        when :deref
          gen_deref(node)
        end
      end

      # Floating unary minus "-x": no floating negate op exists, so the sign bit
      # is flipped with an integer :xor of the format's sign mask (bit 31 of a
      # float, bit 63 of a double), operating on the whole 64-bit slot. This is
      # exact for every value, ±0.0 and NaN included, since only the sign bit
      # changes. The result keeps the operand's floating type (no promotion).
      def gen_float_negate(operand, type)
        mask = type.size == 8 ? 0x8000_0000_0000_0000 : 0x8000_0000
        mask_reg = new_vreg
        emit(:const, dst: mask_reg, a: mask, size: 8)
        dst = new_vreg
        emit(:xor, dst: dst, a: operand, b: mask_reg, size: 8)
        [dst, type]
      end

      # Logical negation "!x" is lowered to the comparison "x == 0", reusing
      # the :eq path rather than introducing a dedicated IR opcode. Its operand
      # is a truth value, so a pointer is allowed too ("!p" is "p is null"),
      # compared at 64 bits so the whole address decides the result.
      def gen_logical_not(node)
        operand, operand_type = gen_value(node.operand)
        require_scalar_for_truth(operand_type, node.operand.token)
        # A 128-bit "!x" is "(lo | hi) == 0", the negation of its truth value.
        if wide128?(operand_type)
          merged = int128_or_halves(operand)
          zero = new_vreg
          emit(:const, dst: zero, a: 0, size: 8)
          dst = new_vreg
          emit(:eq, dst: dst, a: merged, b: zero, size: 8)
          return [dst, Type::Int]
        end
        # A floating "!x" is "x == 0.0" with the NaN-aware :feq (a NaN is not
        # equal to 0.0, so "!NaN" is 0), mirroring the integer "x == 0".
        if operand_type.float?
          zero = emit_float_const(0.0, operand_type)
          dst = new_vreg
          emit(:feq, dst: dst, a: operand, b: zero, size: operand_type.size)
          return [dst, Type::Int]
        end
        zero = new_vreg
        emit(:const, dst: zero, a: 0)
        dst = new_vreg
        emit(:eq, dst: dst, a: operand, b: zero, size: (8 if wide_scalar?(operand_type)))
        [dst, Type::Int]
      end

      # "&x" yields the address of an lvalue. A variable reference, a subscript
      # "e[i]" or a dereference "*p" is an lvalue here: "&x" is a pointer to x's
      # type, "&a" a pointer to a whole array, "&e[i]" a pointer to the element
      # (its already-computed address) and "&*p" collapses to p itself. "&f" of
      # a function designator is a pointer to the function, the same value the
      # bare name decays to.
      def gen_address_of(node)
        operand = node.operand
        if operand.is_a?(Front::AST::VariableRef)
          local = lookup_variable(operand.name)
          # A bare function name: "&f" is a pointer to the function, identical
          # to the decayed designator "f" (6.3.2.1p4), so reuse it.
          return gen_function_designator(operand.name, operand.token) unless local

          # A struct or array variable already evaluates to its object's base
          # address (a stack object or a global symbol), so "&s"/"&a" reuse that
          # and just retag it as a pointer to the whole object. A scalar's
          # address is its symbol (:global_addr) or the absolute address of its
          # stack slot (:addr_of).
          if local.type.struct? || local.type.array? || wide128?(local.type)
            addr, = gen_variable_ref(operand)
            return [addr, Type::Pointer.new(local.type)]
          end
          dst = new_vreg
          if local.global
            emit_global_addr(dst, local.storage)
          else
            emit(:addr_of, dst: dst, a: local.storage)
          end
          [dst, Type::Pointer.new(local.type)]
        elsif operand.is_a?(Front::AST::Subscript)
          addr, element_type = gen_element_address(operand)
          [addr, Type::Pointer.new(element_type)]
        elsif operand.is_a?(Front::AST::MemberAccess)
          # "&s.arr" of an array member is a pointer to the whole array (the
          # member's own address); every other member address retags likewise.
          addr, member_type = gen_member_address(operand)
          [addr, Type::Pointer.new(member_type)]
        elsif operand.is_a?(Front::AST::Unary) && operand.op == :deref
          addr, ptr_type = gen_expr(operand.operand)
          require_pointer(ptr_type, operand.token)
          [addr, ptr_type]
        elsif operand.is_a?(Front::AST::CompoundLiteral)
          # "&(T){...}": a compound literal is an lvalue with the enclosing
          # block's lifetime, so its address is the base of the object laid out
          # for it — taken without the rvalue conversion (no decay, no load) that
          # #gen_compound_literal applies. A pointer to the whole object results,
          # even for an array literal ("&(int[]){...}" is int(*)[N]).
          addr, type = gen_compound_literal_object(operand)
          [addr, Type::Pointer.new(type)]
        else
          error_at(node.token, "lvalue required as unary '&' operand")
        end
      end

      # "*p" read: evaluate p to an address, then load through it. The result
      # type is p's pointed-to type, which also fixes the load width (a pointer
      # target is 8 bytes wide, an int 4).
      def gen_deref(node)
        addr, ptr_type = gen_value(node.operand)
        require_dereferenceable_pointer(ptr_type, node.token)
        result_type = ptr_type.target
        # "*p" of a struct pointer is a struct lvalue: its value is the pointer
        # itself (the struct's address), so nothing is loaded, just as a struct
        # variable yields its address. A pointer to a 128-bit integer behaves the
        # same — its value is that object's address.
        return [addr, result_type] if result_type.struct? || wide128?(result_type)
        # "*fp" of a function pointer is a function designator, which decays
        # right back to the same pointer value (its code address), so it is
        # returned unchanged — this is what lets "(*fp)(x)" and "(**fp)(x)"
        # reach the call as an ordinary Pointer(FunctionType).
        return [addr, ptr_type] if result_type.function?
        # "*p" of a pointer-to-array is an array lvalue, which decays to a
        # pointer to its first element (the same address), so "(*p)[i]" and
        # pointer-to-array arithmetic work; nothing is loaded.
        return [addr, Type::Pointer.new(result_type.element)] if result_type.array?

        dst = new_vreg
        emit_scalar_load(dst, addr, result_type)
        [dst, result_type]
      end

      # Two forms of assignment share the same "=": a plain variable copy and a
      # store through a dereferenced pointer ("*p = v"). Both yield the assigned
      # value; the parser has already guaranteed the target is assignable.
      def gen_assignment(node)
        target = node.target
        if target.is_a?(Front::AST::Unary) && target.op == :deref
          gen_store_through_pointer(node, target)
        elsif target.is_a?(Front::AST::Subscript)
          gen_store_through_subscript(node, target)
        elsif target.is_a?(Front::AST::MemberAccess)
          gen_store_through_member(node, target)
        else
          gen_variable_assignment(node, target)
        end
      end

      # A whole-struct assignment "dst = src" (same struct type), lowered to a
      # :memcpy of the struct's byte width from the source object's address to
      # the destination's. Both sides evaluate to addresses (that is a struct
      # value here), so this works uniformly for a variable, a member, an
      # array element or a "*p" on either side. Returns [dest_addr, struct_type]
      # so a chained "a = b = c" copies into each in turn.
      def gen_struct_copy(dest_addr, src_addr, struct_type)
        emit(:memcpy, a: dest_addr, b: src_addr, size: struct_type.size)
        [dest_addr, struct_type]
      end

      def gen_variable_assignment(node, target)
        local = lookup_local(target.name, target.token)
        reject_readonly_write(local, target, node.token)
        if local.type.array?
          error_at(node.token, "array type is not assignable")
        end
        value, value_type = gen_value(node.value)
        unless compatible_assignment?(local.type, node.value, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        # A struct variable is copied whole (both sides are addresses); a scalar
        # is narrowed and written into its slot or global.
        if local.type.struct?
          dest, = gen_variable_ref(target)
          return gen_struct_copy(dest, value, local.type)
        end
        # A 128-bit variable converts the value to its type (widening a narrower
        # source) and copies both eightbytes into its object; its value is that
        # object's address.
        if wide128?(local.type)
          dest, = gen_variable_ref(target)
          store_int128(dest, value, value_type, local.type, node.token)
          return [dest, local.type]
        end
        stored = store_scalar_variable(local, value, value_type, token: node.token)
        [stored, local.type]
      end

      # Reads a scalar variable's current value into a usable vreg. A local
      # scalar comes from its slot (re-derived from the low bytes for a narrow
      # type, see #read_local_scalar); a global is loaded through its address
      # (:global_addr then a width- and sign-appropriate load).
      def load_scalar_variable(local)
        return read_local_scalar(local) unless local.global

        addr = new_vreg
        emit_global_addr(addr, local.storage)
        dst = new_vreg
        emit_scalar_load(dst, addr, local.type)
        dst
      end

      # Writes `value_vreg` (of type `value_type`) into a scalar variable,
      # converting it to the variable's type first (the usual assignment
      # conversion — a narrowing, widening, sign change or integer<->floating
      # format change). A local is a plain :copy into its slot; a global is a
      # :store through its address, the store width following its type. Returns
      # the vreg holding the stored (converted) value, which is the assignment
      # expression's value. `token` locates a diagnostic for an unsupported
      # floating conversion.
      def store_scalar_variable(local, value_vreg, value_type, token: nil)
        converted = convert_for_assignment(value_vreg, value_type, local.type, token: token)
        if local.global
          addr = new_vreg
          emit_global_addr(addr, local.storage)
          emit(:store, a: addr, b: converted, size: local.type.size)
        else
          emit(:copy, dst: local.storage, a: converted)
        end
        converted
      end

      # "e[i] = v": compute the element address (see #gen_element_address) and
      # write v through it, the store width following the element type. The
      # expression's value is v.
      def gen_store_through_subscript(node, target)
        addr, element_type = gen_element_address(target)
        value, value_type = gen_value(node.value)
        unless compatible_assignment?(element_type, node.value, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        return gen_struct_copy(addr, value, element_type) if element_type.struct?
        if wide128?(element_type)
          store_int128(addr, value, value_type, element_type, node.token)
          return [addr, element_type]
        end

        # v is only assignment-compatible with the element type, not
        # necessarily identical to it (e.g. an int assigned into a long
        # element), so it needs the same conversion as a variable assignment
        # before its bytes are stored.
        converted = convert_for_assignment(value, value_type, element_type, token: node.token)
        emit(:store, a: addr, b: converted, size: element_type.size)
        [converted, element_type]
      end

      # "s.m = v" / "p->m = v": resolve the member (see #resolve_member) and write
      # v into it. A bit-field is spliced into its storage unit by read-modify-write
      # (see #store_bitfield); a struct member is copied whole; an array member is
      # not assignable, like an array variable; every other member is a scalar
      # store the member's width wide.
      def gen_store_through_member(node, target)
        base_addr, member = resolve_member(target)
        member_type = member.type
        if member.bitfield?
          value, value_type = gen_value(node.value)
          unless compatible_assignment?(member_type, node.value, value_type)
            error_at(node.token, "incompatible types in assignment")
          end
          return store_bitfield(base_addr, member, value, value_type, node.token)
        end
        addr = member_field_address(base_addr, member)
        if member_type.array?
          error_at(node.token, "array type is not assignable")
        end
        value, value_type = gen_value(node.value)
        unless compatible_assignment?(member_type, node.value, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        return gen_struct_copy(addr, value, member_type) if member_type.struct?
        if wide128?(member_type)
          store_int128(addr, value, value_type, member_type, node.token)
          return [addr, member_type]
        end

        # v is only assignment-compatible with the member type, not
        # necessarily identical to it, so convert before storing.
        converted = convert_for_assignment(value, value_type, member_type, token: node.token)
        emit(:store, a: addr, b: converted, size: member_type.size)
        [converted, member_type]
      end

      # "*p = v": evaluate p (an address) and v, then write v through the
      # address. The store width follows p's target type. The expression's
      # value is v.
      def gen_store_through_pointer(node, target)
        addr, ptr_type = gen_value(target.operand)
        require_dereferenceable_pointer(ptr_type, target.token)
        target_type = ptr_type.target
        value, value_type = gen_value(node.value)
        unless compatible_assignment?(target_type, node.value, value_type)
          error_at(node.token, "incompatible types in assignment")
        end
        return gen_struct_copy(addr, value, target_type) if target_type.struct?
        if wide128?(target_type)
          store_int128(addr, value, value_type, target_type, node.token)
          return [addr, target_type]
        end

        # v is only assignment-compatible with the pointee type, not
        # necessarily identical to it, so convert before storing.
        converted = convert_for_assignment(value, value_type, target_type, token: node.token)
        emit(:store, a: addr, b: converted, size: target_type.size)
        [converted, target_type]
      end

      # Lowers a call. A callee that is a bare function name not shadowed by a
      # variable is a direct call to that symbol; any other callee (a function
      # pointer variable, "(*fp)(x)", "s.fp(x)", "table[i](x)") is evaluated to
      # a Pointer(FunctionType) value and called indirectly. Arguments are
      # evaluated left to right, each landing in its own vreg; the result's type
      # is the callee's return type (a void one is only valid when the whole
      # call is an expression-statement, enforced by #gen_value at every other
      # site).
      def gen_call(node)
        callee = node.callee
        # A bare identifier callee that binds no variable is a direct call to a
        # function of that name; an unknown one is an implicit declaration.
        if callee.is_a?(Front::AST::VariableRef) && lookup_variable(callee.name).nil?
          unless @signatures.key?(callee.name)
            error_at(node.token, "implicit declaration of function '#{callee.name}'")
          end
          gen_direct_call(node, callee.name)
        else
          gen_indirect_call(node)
        end
      end

      # A direct call to the named function, its signature already known.
      def gen_direct_call(node, name)
        sig = @signatures[name]
        plumb = struct_return_plumbing(sig[:return_type])
        args = lower_call_arguments(node, sig[:param_types], sig[:variadic], name, plumb[:hidden])
        fixed = sig[:variadic] ? sig[:param_types].size : nil
        emit_call_result(plumb, sig[:return_type]) do |dst|
          emit(:call, dst: dst, a: name, b: args,
                      size: call_size(fixed, call_ret_descriptor(sig[:return_type], plumb)))
        end
      end

      # An indirect call through a function-pointer value. The callee is
      # evaluated (a function designator having already decayed to a pointer);
      # its type must be a pointer to a function, whose signature drives the
      # argument checks and supplies the result type. The target address rides
      # in the a-field and the argument vregs in b, exactly like a direct call.
      def gen_indirect_call(node)
        target, callee_type = gen_value(node.callee)
        func_type = called_function_type(callee_type, node.token)
        plumb = struct_return_plumbing(func_type.return_type)
        args = lower_call_arguments(node, func_type.param_types, func_type.variadic, nil, plumb[:hidden])
        fixed = func_type.variadic ? func_type.param_types.size : nil
        emit_call_result(plumb, func_type.return_type) do |dst|
          emit(:call_indirect, dst: dst, a: target, b: args,
                               size: call_size(fixed, call_ret_descriptor(func_type.return_type, plumb)))
        end
      end

      # Prepares a call's struct-return handling. Returns a descriptor with:
      #   :mode     — :normal (scalar/void result), :memory (a MEMORY struct
      #               returned through a hidden pointer) or :register (a struct
      #               small enough to come back in registers);
      #   :hidden   — the [buffer_addr, :gp] pair to prepend to the argument list
      #               for a MEMORY result, else nil;
      #   :ret      — the [buffer_addr, classes] descriptor a register result
      #               rides on the call's `size`, else nil;
      #   :buf_addr — the scratch buffer's address for either struct mode.
      # For a struct result a scratch stack object holds the value: a MEMORY
      # callee writes it through the hidden pointer and returns that pointer in
      # rax, while a register callee's eightbytes are stored into the buffer by
      # the backend.
      def struct_return_plumbing(return_type)
        return { mode: :normal, hidden: nil, ret: nil, buf_addr: nil } unless return_type.struct?

        classes = classify_struct(return_type)
        buf = new_object(return_type.size)
        addr = new_vreg
        emit(:object_addr, dst: addr, a: buf)
        if classes == :memory
          { mode: :memory, hidden: [addr, @convention.hidden_result_kind], ret: nil, buf_addr: addr }
        else
          { mode: :register, hidden: nil, ret: [addr, classes], buf_addr: addr }
        end
      end

      # Emits a call (via the block, which receives the destination vreg) and
      # yields its [value, type] result. A register-returned struct writes nothing
      # to a call dst (its eightbytes land in the scratch buffer), so the block
      # gets a nil dst and the value is the buffer address; every other call takes
      # a fresh dst holding rax — the scalar/pointer result, or, for a MEMORY
      # struct, the hidden pointer the callee returns, which is the buffer address
      # too.
      def emit_call_result(plumb, return_type)
        if plumb[:mode] == :register
          yield nil
          [plumb[:buf_addr], return_type]
        else
          dst = new_vreg
          yield dst
          value = plumb[:mode] == :memory ? plumb[:buf_addr] : dst
          [value, return_type]
        end
      end

      # The `ret` half of a call's `size` descriptor: :sse4/:sse8 for a
      # float/double result the backend reads from xmm0, a [buffer_addr, classes]
      # descriptor for an in-register struct result the backend scatters into the
      # buffer, or nil for an integer/pointer/void/MEMORY-struct result read from
      # rax.
      def call_ret_descriptor(return_type, plumb)
        return argument_kind(return_type) if return_type.float?

        plumb[:ret]
      end

      # Builds a call's `size` descriptor: a [fixed, ret] pair, or nil when both
      # halves are. `fixed` is the callee's fixed parameter count for a variadic
      # call (nil otherwise), which the backend turns into the al = xmm-count the
      # ABI wants; `ret` is the return descriptor from #call_ret_descriptor.
      def call_size(fixed, ret)
        return nil if fixed.nil? && ret.nil?

        [fixed, ret]
      end

      # The FunctionType a call's callee names, or a diagnostic when the callee
      # is neither a function nor a pointer to one. A function designator would
      # already have decayed to Pointer(FunctionType), but a bare function type
      # is accepted too for completeness.
      def called_function_type(callee_type, token)
        return callee_type.target if callee_type.pointer? && callee_type.target.function?
        return callee_type if callee_type.function?

        error_at(token, "called object is not a function or function pointer")
      end

      # Evaluates a call's arguments against `param_types` (the fixed, named
      # parameters), checking the count and converting each. A fixed argument
      # (index below the parameter count) is checked against its parameter type
      # and converted like an assignment (an arithmetic widening/narrowing/sign
      # change; a pointer or null pointer constant passes through). When
      # `variadic` is set, any extra arguments past the fixed ones are allowed
      # (only a shortfall below the fixed count is an error, never a surplus) and
      # each takes the default argument promotions (see #promote_variadic_argument)
      # instead of an assignment conversion. `name` names the callee in the
      # diagnostics of a direct call, or is nil for an indirect one. `hidden` is
      # the [vreg, :gp] hidden result pointer to pass as the implicit first
      # argument of a MEMORY-returning call, or nil.
      def lower_call_arguments(node, param_types, variadic, name, hidden)
        callee_desc = name ? "function '#{name}'" : "function pointer"
        fixed = param_types.size
        if node.args.size < fixed
          error_at(node.token, "too few arguments to #{callee_desc}")
        elsif !variadic && node.args.size > fixed
          error_at(node.token, "too many arguments to #{callee_desc}")
        end

        # One candidate group per argument (a list of [vreg, kind] eightbyte
        # pairs), the hidden result pointer prepended so it shares the placement.
        groups = []
        groups << [hidden] if hidden
        node.args.each_with_index do |arg, i|
          vreg, arg_type = gen_value(arg)
          groups << if i < fixed
                      lower_fixed_argument(node, i, arg, vreg, arg_type, param_types[i], name)
                    else
                      [promote_variadic_argument(vreg, arg_type, node.token)]
                    end
        end
        place_call_groups(groups)
      end

      # Lowers a fixed (named-parameter) argument to its candidate eightbyte
      # group. A struct argument is checked for type identity and expanded into
      # its eightbytes (see #lower_struct_argument); a scalar is assignment-checked,
      # converted to the parameter's type and passed as a single eightbyte.
      def lower_fixed_argument(node, index, arg, vreg, arg_type, param_type, name)
        unless compatible_assignment?(param_type, arg, arg_type)
          suffix = name ? " of '#{name}'" : ""
          error_at(node.token, "incompatible type for argument #{index + 1}#{suffix}")
        end
        return lower_struct_argument(vreg, param_type) if param_type.struct?

        converted = convert_for_assignment(vreg, arg_type, param_type, token: node.token)
        [[converted, argument_kind(param_type)]]
      end

      # Expands a by-value struct argument (whose value is its address in `addr`)
      # into its System V eightbyte [vreg, kind] pairs. The struct is copied into
      # a scratch stack object first, so reading whole 8-byte eightbytes never
      # reads past a struct whose size is not a multiple of 8 (a stack object is
      # 16-byte aligned and rounded up, so the final eightbyte's 8-byte load stays
      # in bounds). Each eightbyte is loaded from base + 8*i; its kind is the
      # classification's (:gp/:sse8 for a register struct, all the convention's
      # memory-aggregate kind for a MEMORY one).
      def lower_struct_argument(addr, struct_type)
        classes = classify_struct(struct_type)
        size = struct_type.size
        scratch = new_object(size)
        base = new_vreg
        emit(:object_addr, dst: base, a: scratch)
        emit(:memcpy, a: base, b: addr, size: size)

        count = (size + 7) / 8
        kinds = classes == :memory ? Array.new(count, @convention.memory_aggregate_kind) : classes
        (0...count).map do |i|
          value = new_vreg
          emit(:load, dst: value, a: eightbyte_address(base, i), size: 8)
          [value, kinds[i]]
        end
      end

      # Runs the shared placement simulation over the argument groups (each a list
      # of [vreg, candidate_kind] eightbyte pairs) and flattens the result to the
      # [vreg, placed_kind] pairs a :call/:call_indirect carries. Placement acts on
      # a whole group at once (the all-or-nothing rule), so a struct's eightbytes
      # all land in registers or all spill together; the left-to-right vreg order
      # is preserved.
      def place_call_groups(groups)
        placed = place_argument_kinds(groups.map { |group| group.map { |_vreg, kind| kind } })
        groups.each_with_index.flat_map do |group, gi|
          group.each_with_index.map { |(vreg, _candidate), ei| [vreg, placed[gi][ei]] }
        end
      end

      # The default argument promotions applied to an argument in a variadic
      # call's variable part (6.5.2.2p6), returning the [vreg, kind] pair the
      # call lowering wants: an integer narrower than int (char, short and their
      # unsigned forms, and _Bool) widens to int, a `float` widens to `double`
      # (so it travels as an :sse8 in an xmm register, which al then counts),
      # while int, long, their unsigned forms, double and any pointer pass
      # through unchanged. A struct has no promoted form the callee could recover
      # through va_arg in a register/stack layout this step models, so passing
      # one is rejected.
      def promote_variadic_argument(vreg, arg_type, token)
        if arg_type.struct?
          error_at(token, "passing a struct to a variadic function is not supported yet")
        end
        # A 128-bit integer has no default-promoted form this step can hand a
        # variadic callee to recover through va_arg, so passing one is diagnosed.
        if wide128?(arg_type)
          error_at(token, "passing a 128-bit integer to a variadic function is not supported yet")
        end
        # A float promotes to double; a double passes through. Either lands in an
        # xmm register as an :sse8.
        return [convert(vreg, from: arg_type, to: Type::Double, token: token), :sse8] if arg_type.float?
        return [vreg, :gp] unless arg_type.integer?

        [convert(vreg, from: arg_type, to: integer_promote(arg_type)), :gp]
      end

      # "lhs && rhs": short-circuit, so rhs is only evaluated when lhs is
      # non-zero. Both operands are conditions (int required). Lowered with a
      # single result vreg written from one of two "const 1"/"const 0" arms,
      # since the IR has no boolean value beyond an int 0/1:
      #   lhs -> jump_if_zero(false) -> rhs -> jump_if_zero(false)
      #     -> result = 1 -> jump(end)
      #   false: result = 0
      #   end:
      def gen_logical_and(node)
        lhs = gen_condition(node.lhs)
        false_label = new_label
        end_label = new_label
        result = new_vreg
        emit(:jump_if_zero, a: lhs, b: false_label)

        rhs = gen_condition(node.rhs)
        emit(:jump_if_zero, a: rhs, b: false_label)
        emit_const_copy(result, 1)
        emit(:jump, a: end_label)

        emit(:label, a: false_label)
        emit_const_copy(result, 0)
        emit(:label, a: end_label)
        [result, Type::Int]
      end

      # "lhs || rhs": short-circuit, so rhs is only evaluated when lhs is
      # zero. Symmetric to #gen_logical_and: a false (zero) lhs falls through
      # to evaluate rhs, while a true lhs settles the result at 1 immediately.
      #   lhs -> jump_if_zero(rhs) -> result = 1 -> jump(end)
      #   rhs: rhs -> jump_if_zero(false) -> result = 1 -> jump(end)
      #   false: result = 0
      #   end:
      def gen_logical_or(node)
        lhs = gen_condition(node.lhs)
        rhs_label = new_label
        false_label = new_label
        end_label = new_label
        result = new_vreg
        emit(:jump_if_zero, a: lhs, b: rhs_label)

        emit_const_copy(result, 1)
        emit(:jump, a: end_label)

        emit(:label, a: rhs_label)
        rhs = gen_condition(node.rhs)
        emit(:jump_if_zero, a: rhs, b: false_label)
        emit_const_copy(result, 1)
        emit(:jump, a: end_label)

        emit(:label, a: false_label)
        emit_const_copy(result, 0)
        emit(:label, a: end_label)
        [result, Type::Int]
      end

      # "condition ? then_expr : else_expr": the condition must be int-typed;
      # only one of the two arms is evaluated, and both must settle on the
      # same result type (which becomes the expression's type).
      def gen_conditional(node)
        # The result type is settled up front from the arms' static types (the
        # same code-free inference sizeof uses), so each arm's value can be
        # converted to it inside its own branch before the shared result slot is
        # written — needed when the arms differ (e.g. int and long).
        result_type = conditional_result_type(node.then_expr, static_type(node.then_expr),
                                               node.else_expr, static_type(node.else_expr), node.token)
        cond = gen_condition(node.condition)
        else_label = new_label
        end_label = new_label
        result = new_vreg
        emit(:jump_if_zero, a: cond, b: else_label)

        # A void conditional (one arm void, the GCC extension) yields no value:
        # each arm is lowered with #gen_expr for its side effects only — no
        # convert-and-store into the result slot, which #gen_value would reject
        # for the void arm and there is no value to keep anyway.
        if result_type.void?
          gen_expr(node.then_expr)
          emit(:jump, a: end_label)
          emit(:label, a: else_label)
          gen_expr(node.else_expr)
          emit(:label, a: end_label)
          return [nil, Type::Void]
        end

        then_value, then_type = gen_value(node.then_expr)
        emit(:copy, dst: result, a: convert_for_assignment(then_value, then_type, result_type, token: node.token))
        emit(:jump, a: end_label)

        emit(:label, a: else_label)
        else_value, else_type = gen_value(node.else_expr)
        emit(:copy, dst: result, a: convert_for_assignment(else_value, else_type, result_type, token: node.token))
        emit(:label, a: end_label)

        [result, result_type]
      end

      # The type of "condition ? then : else": identical types are kept as is,
      # a mixed arithmetic pair (int/char) promotes to int, and a pointer arm
      # paired with a null pointer constant (in either position) takes the
      # pointer type, so "cond ? p : 0" is a pointer. A pointer to an object type
      # paired with a "void *" (in either position) yields "void *" (6.5.15p6),
      # so "cond ? (char *)s : v" is well-typed. Anything else (a pointer vs a
      # non-null int, or two unrelated pointer types) is rejected. When either
      # arm is void the whole conditional is void, which ISO C only admits when
      # both arms are void but GCC extends to a single void arm — the shape a
      # statement expression ending in a jump takes ("1 ? printf(...) : ({ ...;
      # goto L; })"), so the two features work together. Both arms are passed as
      # AST nodes so the null-pointer-constant check can look at the literal, not
      # just its int type.
      def conditional_result_type(then_node, then_type, else_node, else_type, token)
        return then_type if then_type == else_type
        if then_type.pointer? && Front::AST.null_pointer_constant?(else_node)
          then_type
        elsif else_type.pointer? && Front::AST.null_pointer_constant?(then_node)
          else_type
        elsif void_pointer_composite?(then_type, else_type)
          Type::Pointer.new(Type::Void)
        elsif then_type.void? || else_type.void?
          Type::Void
        elsif then_type.arithmetic? && else_type.arithmetic?
          common_arithmetic_type(then_type, else_type)
        else
          error_at(token, "type mismatch in conditional expression")
        end
      end

      # Whether one arm is a pointer to an object type and the other a "void *"
      # (6.5.15p6): the composite of that pair is "void *". Qualifiers on the
      # pointed-to type are not modeled in this subset, so the composite is a
      # plain "void *" and the pointer stays unqualified. Two "void *" arms are
      # already handled by the identical-type case above; a function pointer is
      # not a pointer to an object type, so it is excluded here.
      def void_pointer_composite?(one, other)
        return false unless one.pointer? && other.pointer?

        (one.target.void? && object_pointee?(other.target)) ||
          (other.target.void? && object_pointee?(one.target))
      end

      def object_pointee?(target)
        !target.void? && !target.function?
      end

      # A compound assignment "target op= value" reads through the target's
      # address (or its vreg, for a plain variable) exactly once, combines it
      # with value via the same operator/type rules as "target = target op
      # value" (#gen_binary_op), and writes the result back. The expression's
      # value is the result.
      def gen_compound_assignment(node)
        target = node.target
        if target.is_a?(Front::AST::Unary) && target.op == :deref
          gen_compound_assignment_through_pointer(node, target)
        elsif target.is_a?(Front::AST::Subscript)
          gen_compound_assignment_through_subscript(node, target)
        elsif target.is_a?(Front::AST::MemberAccess)
          gen_compound_assignment_through_member(node, target)
        else
          gen_compound_assignment_to_variable(node, target)
        end
      end

      # "s.m op= v": read the member once through its address, combine it with v
      # under #gen_binary_op's rules, and write it back. An aggregate member (a
      # struct or an array) has no arithmetic, so it is rejected before the read.
      def gen_compound_assignment_through_member(node, target)
        base_addr, member = resolve_member(target)
        # A bit-field reads and writes through the shift/mask lowering rather than
        # a plain load/store, but the "op=" arithmetic is otherwise identical: read
        # once, combine, splice back.
        if member.bitfield?
          current, current_type = gen_bitfield_load(base_addr, member)
          value, value_type = gen_value(node.value)
          result, result_type = gen_binary_op(node.op, current, current_type, value, value_type, node.token)
          unless compatible_types?(member.type, result_type)
            error_at(node.token, "incompatible types in assignment")
          end
          return store_bitfield(base_addr, member, result, result_type, node.token)
        end
        member_type = member.type
        addr = member_field_address(base_addr, member)
        require_scalar_target(member_type, node.token)
        current = new_vreg
        emit_scalar_load(current, addr, member_type)

        value, value_type = gen_value(node.value)
        result, result_type = gen_binary_op(node.op, current, member_type, value, value_type, node.token)
        unless compatible_types?(member_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        # gen_binary_op's usual arithmetic conversions may widen the result
        # past the member's type (e.g. a float member combined with a double
        # value), so narrow it back before storing.
        converted = convert_for_assignment(result, result_type, member_type, token: node.token)
        emit(:store, a: addr, b: converted, size: member_type.size)
        [converted, member_type]
      end

      def gen_compound_assignment_to_variable(node, target)
        local = lookup_local(target.name, target.token)
        reject_readonly_write(local, target, node.token)
        error_at(node.token, "array type is not assignable") if local.type.array?
        error_at(node.token, "invalid operands to binary expression") if local.type.struct?
        require_scalar_target(local.type, node.token)

        value, value_type = gen_value(node.value)
        current = load_scalar_variable(local)
        result, result_type = gen_binary_op(node.op, current, local.type, value, value_type, node.token)
        unless compatible_types?(local.type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        stored = store_scalar_variable(local, result, result_type, token: node.token)
        [stored, local.type]
      end

      def gen_compound_assignment_through_subscript(node, target)
        addr, element_type = gen_element_address(target)
        require_scalar_target(element_type, node.token)
        current = new_vreg
        emit_scalar_load(current, addr, element_type)

        value, value_type = gen_value(node.value)
        result, result_type = gen_binary_op(node.op, current, element_type, value, value_type, node.token)
        unless compatible_types?(element_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        # gen_binary_op's usual arithmetic conversions may widen the result
        # past the element's type, so narrow it back before storing.
        converted = convert_for_assignment(result, result_type, element_type, token: node.token)
        emit(:store, a: addr, b: converted, size: element_type.size)
        [converted, element_type]
      end

      def gen_compound_assignment_through_pointer(node, target)
        addr, ptr_type = gen_value(target.operand)
        require_dereferenceable_pointer(ptr_type, target.token)
        target_type = ptr_type.target
        require_scalar_target(target_type, node.token)
        current = new_vreg
        emit_scalar_load(current, addr, target_type)

        value, value_type = gen_value(node.value)
        result, result_type = gen_binary_op(node.op, current, target_type, value, value_type, node.token)
        unless compatible_types?(target_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        # gen_binary_op's usual arithmetic conversions may widen the result
        # past the pointee's type, so narrow it back before storing.
        converted = convert_for_assignment(result, result_type, target_type, token: node.token)
        emit(:store, a: addr, b: converted, size: target_type.size)
        [converted, target_type]
      end

      # Prefix/postfix "++"/"--" is a compound assignment by the constant 1,
      # sharing #gen_binary_op's type rules (an int step scaled for a pointer
      # target, same as "p += 1"). Only the reported value differs: a prefix
      # form yields the updated value, a postfix form yields the value read
      # before the update.
      def gen_inc_dec(node)
        target = node.target
        if target.is_a?(Front::AST::Unary) && target.op == :deref
          gen_inc_dec_through_pointer(node, target)
        elsif target.is_a?(Front::AST::Subscript)
          gen_inc_dec_through_subscript(node, target)
        elsif target.is_a?(Front::AST::MemberAccess)
          gen_inc_dec_through_member(node, target)
        else
          gen_inc_dec_variable(node, target)
        end
      end

      # "s.m++"/"++s.m": the member is read once through its address, stepped by
      # one, and written back; an aggregate member (a struct or array) has no
      # arithmetic and is rejected first. Prefix yields the new value, postfix
      # the value read before the step.
      def gen_inc_dec_through_member(node, target)
        base_addr, member = resolve_member(target)
        # A bit-field steps through the same shift/mask read-modify-write as a
        # compound assignment: prefix yields the new (truncated) field, postfix
        # the value read before the step.
        if member.bitfield?
          current, current_type = gen_bitfield_load(base_addr, member)
          one = new_vreg
          emit(:const, dst: one, a: 1)
          result, result_type = gen_binary_op(node.op, current, current_type, one, Type::Int, node.token)
          unless compatible_types?(member.type, result_type)
            error_at(node.token, "incompatible types in assignment")
          end
          stored = store_bitfield(base_addr, member, result, result_type, node.token)
          return node.prefix ? stored : [current, current_type]
        end
        member_type = member.type
        addr = member_field_address(base_addr, member)
        require_scalar_target(member_type, node.token)
        current = new_vreg
        emit_scalar_load(current, addr, member_type)

        one = new_vreg
        emit(:const, dst: one, a: 1)
        result, result_type = gen_binary_op(node.op, current, member_type, one, Type::Int, node.token)
        unless compatible_types?(member_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: result, size: member_type.size)
        node.prefix ? [result, member_type] : [current, member_type]
      end

      def gen_inc_dec_variable(node, target)
        local = lookup_local(target.name, target.token)
        reject_readonly_write(local, target, node.token)
        error_at(node.token, "array type is not assignable") if local.type.array?
        error_at(node.token, "invalid operands to binary expression") if local.type.struct?
        require_scalar_target(local.type, node.token)

        current = load_scalar_variable(local)
        old_value = nil
        unless node.prefix
          old_value = new_vreg
          emit(:copy, dst: old_value, a: current)
        end

        one = new_vreg
        emit(:const, dst: one, a: 1)
        result, result_type = gen_binary_op(node.op, current, local.type, one, Type::Int, node.token)
        unless compatible_types?(local.type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        stored = store_scalar_variable(local, result, result_type, token: node.token)
        node.prefix ? [stored, local.type] : [old_value, local.type]
      end

      def gen_inc_dec_through_subscript(node, target)
        addr, element_type = gen_element_address(target)
        require_scalar_target(element_type, node.token)
        current = new_vreg
        emit_scalar_load(current, addr, element_type)

        one = new_vreg
        emit(:const, dst: one, a: 1)
        result, result_type = gen_binary_op(node.op, current, element_type, one, Type::Int, node.token)
        unless compatible_types?(element_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: result, size: element_type.size)
        node.prefix ? [result, element_type] : [current, element_type]
      end

      def gen_inc_dec_through_pointer(node, target)
        addr, ptr_type = gen_value(target.operand)
        require_dereferenceable_pointer(ptr_type, target.token)
        target_type = ptr_type.target
        require_scalar_target(target_type, node.token)
        current = new_vreg
        emit_scalar_load(current, addr, target_type)

        one = new_vreg
        emit(:const, dst: one, a: 1)
        result, result_type = gen_binary_op(node.op, current, target_type, one, Type::Int, node.token)
        unless compatible_types?(target_type, result_type)
          error_at(node.token, "incompatible types in assignment")
        end
        emit(:store, a: addr, b: result, size: target_type.size)
        node.prefix ? [result, target_type] : [current, target_type]
      end

      # Materializes an immediate into `dst` via a fresh const vreg; shared by
      # the short-circuit lowerings (#gen_logical_and, #gen_logical_or) which
      # need to write a fixed 0/1 into the same result vreg from more than one
      # control-flow arm.
      def emit_const_copy(dst, value)
        src = new_vreg
        emit(:const, dst: src, a: value)
        emit(:copy, dst: dst, a: src)
      end

      # Assignment/initialization/argument/return compatibility. The arithmetic
      # types (the integer types and the floating types) convert to one another
      # implicitly — a narrowing, widening, sign change or integer<->floating
      # format change — so any arithmetic pair is compatible.
      # Two pointers are compatible when they share the same target type or
      # either side is void * (void * converts to and from any pointer type,
      # both directions); mixing an arithmetic type with a pointer (either
      # direction) is rejected.
      def compatible_types?(expected, actual)
        # Any two arithmetic types (integer or floating, in any mix) convert to
        # one another implicitly, so any arithmetic pair is compatible.
        return true if expected.arithmetic? && actual.arithmetic?
        # Any scalar converts to _Bool (the "!= 0" rule), pointers included.
        return true if expected.bool? && actual.pointer?
        return true if expected.pointer? && actual.pointer? &&
                        (expected == actual || expected.target.void? || actual.target.void?)

        expected == actual
      end

      # Whether `value_node` (whose rvalue type is `actual`) may initialize, be
      # assigned to, be passed as, or be returned as `expected`. It is
      # #compatible_types? extended with the null-pointer-constant rule: a
      # literal 0 (an integer or a '\0') converts to any pointer type, so
      # "int *p = 0;", "p = 0;", "f(0)" against a pointer parameter and
      # "return 0;" from a pointer function are all well-typed. The node is
      # needed (not just the type) so the check sees the literal 0 rather than
      # merely its int type.
      def compatible_assignment?(expected, value_node, actual)
        return true if expected.pointer? && Front::AST.null_pointer_constant?(value_node)

        compatible_types?(expected, actual)
      end

      # Integer promotion (6.3.1.1): a type whose rank is below int (char, short
      # and their unsigned forms, and _Bool) promotes to int, which holds every
      # one of their values; int, unsigned int, long and unsigned long are
      # unchanged. Only an integer type is promoted; anything else passes
      # through.
      def integer_promote(type)
        return type unless type.integer?

        type.size < 4 ? Type::Int : type
      end

      # The common type of two arithmetic operands (6.3.1.8). A floating operand
      # dominates: if either side is a floating type the result is `double` when
      # either floating operand is `double`, otherwise `float` (so "int + double"
      # is double, "long + float" is float). With no floating operand the two
      # integers are integer-promoted, then the same-signedness case picks the
      # wider rank; mixed signedness gives the unsigned type when its rank is at
      # least the signed type's, otherwise the signed type — which under LP64
      # always represents every value of a strictly narrower unsigned type (e.g.
      # long covers unsigned int, so "long + unsigned int" is long).
      def common_arithmetic_type(lhs_type, rhs_type)
        if lhs_type.float? || rhs_type.float?
          double = (lhs_type.float? && lhs_type.size == 8) || (rhs_type.float? && rhs_type.size == 8)
          return double ? Type::Double : Type::Float
        end
        a = integer_promote(lhs_type)
        b = integer_promote(rhs_type)
        return a if a == b
        return (a.size >= b.size ? a : b) if a.signed? == b.signed?

        unsigned, signed = a.unsigned? ? [a, b] : [b, a]
        unsigned.size >= signed.size ? unsigned : signed
      end

      # Converts `vreg` (a value of arithmetic type `from`) to arithmetic type
      # `to`, emitting the width/sign/format change the value representation
      # calls for and returning the vreg holding the result. A conversion to
      # _Bool is the truth test "value != 0". A conversion touching a floating
      # type (either side) is delegated to #convert_floating (:itof / :ftoi /
      # :ftof). For two integers: widening to 8 bytes extends by the *source*
      # signedness (preserving the numeric value); a 1/2-byte destination
      # re-derives its low bytes by the *destination* signedness; a 4-byte
      # destination, and same-bit-pattern reinterpretations (int <-> unsigned
      # int, long <-> unsigned long), need no code at all. `token` locates the
      # diagnostic an unsupported floating conversion raises; it is nil on the
      # integer-only call sites that never reach one.
      # Whether `type` is a 128-bit integer (`__int128` / `unsigned __int128`).
      # Its width alone tells it apart from every other integer type, and the
      # generator uses that to route it through the address-carried, two-eightbyte
      # value model rather than the single-slot scalar machinery.
      def wide128?(type)
        type.integer? && type.size == 16
      end

      # Reserves a fresh 16-byte stack object for a 128-bit temporary and returns
      # a vreg holding its base address — the "value" of a 128-bit result, mirroring
      # how a small struct's value is its object's address. The low eightbyte lives
      # at +0, the high at +8 (little endian).
      def new_int128_temp
        object_id = new_object(16)
        base = new_vreg
        emit(:object_addr, dst: base, a: object_id)
        base
      end

      # Loads one 8-byte half of a 128-bit value at `offset` (0 low, 8 high) from
      # the object `base` addresses.
      def load_int128_half(base, offset)
        dst = new_vreg
        emit(:load, dst: dst, a: offset_address(base, offset), size: 8)
        dst
      end

      # Stores an 8-byte half into a 128-bit object at `offset` (0 low, 8 high).
      def store_int128_half(base, offset, value)
        emit(:store, a: offset_address(base, offset), b: value, size: 8)
      end

      # (lo | hi) of the 128-bit value at `addr`: nonzero exactly when the whole
      # value is nonzero, which the truth tests and _Bool conversion reduce to.
      def int128_or_halves(addr)
        merged = new_vreg
        emit(:or, dst: merged, a: load_int128_half(addr, 0), b: load_int128_half(addr, 8), size: 8)
        merged
      end

      # "value != 0" for a 128-bit value: (lo | hi) != 0, an int 0/1. Shared by the
      # _Bool conversion and the truth tests (conditions, "!").
      def int128_to_bool(addr)
        zero = new_vreg
        emit(:const, dst: zero, a: 0, size: 8)
        dst = new_vreg
        emit(:ne, dst: dst, a: int128_or_halves(addr), b: zero, size: 8)
        dst
      end

      # A conversion with a 128-bit integer on at least one side. int128<->int128
      # is only a signedness reinterpretation (identical bits), so the address
      # passes through. Widening a narrower value fills the low eightbyte with its
      # (sign- or zero-extended) 64-bit value and the high eightbyte with the sign
      # fill (arithmetic shift of the low half by 63) for a signed source or zero
      # for an unsigned one. Narrowing from 128-bit takes the low eightbyte and
      # truncates it like any narrowing conversion; a _Bool destination is the
      # "!= 0" test over both halves. A conversion to or from a floating type is
      # not lowered (out of scope) and diagnosed here.
      def convert_int128(vreg, from, to, token)
        return vreg if wide128?(from) && wide128?(to)

        if wide128?(to)
          if from.float?
            error_at(token, "conversion between a floating type and '#{to}' is not supported yet")
          end
          lo = convert(vreg, from: from, to: from.signed? ? Type::Long : Type::ULong, token: token)
          base = new_int128_temp
          store_int128_half(base, 0, lo)
          store_int128_half(base, 8, int128_high_fill(lo, from.signed?))
          base
        else
          if to.float?
            error_at(token, "conversion between '#{from}' and a floating type is not supported yet")
          end
          return int128_to_bool(vreg) if to.bool?

          # The low eightbyte holds the low-order value; treat it as a 64-bit
          # integer that the ordinary narrowing conversion truncates. Its own
          # signedness does not affect a narrowing, so Type::Long stands in.
          convert(load_int128_half(vreg, 0), from: Type::Long, to: to, token: token)
        end
      end

      # The high eightbyte of a 128-bit value widened from a 64-bit low half: the
      # sign fill (low >> 63, arithmetic) for a signed source so a negative value
      # sign-extends, or zero for an unsigned source (zero-extension).
      def int128_high_fill(lo, signed)
        if signed
          count = new_vreg
          emit(:const, dst: count, a: 63)
          hi = new_vreg
          emit(:sar, dst: hi, a: lo, b: count, size: 8)
          hi
        else
          hi = new_vreg
          emit(:const, dst: hi, a: 0, size: 8)
          hi
        end
      end

      # Stores a value into the 128-bit object at `dest_addr`, converting it to the
      # object's 128-bit type first (a narrower source widens with sign/zero fill,
      # another 128-bit value copies as-is), then copying both eightbytes with a
      # 16-byte :memcpy. Shared by every 128-bit assignment, initialization and
      # store-through-lvalue path, mirroring #gen_struct_copy for a struct.
      def store_int128(dest_addr, value_vreg, value_type, target_type, token)
        src = convert(value_vreg, from: value_type, to: target_type, token: token)
        emit(:memcpy, a: dest_addr, b: src, size: 16)
      end

      # The spelling of a binary operator for the "not supported yet" diagnostics
      # a 128-bit operand raises on an unimplemented operation.
      INT128_OP_SPELLINGS = {
        add: "+", sub: "-", mul: "*", div: "/", mod: "%",
        and: "&", or: "|", xor: "^", shl: "<<", shr: ">>"
      }.freeze

      # Dispatches a 128-bit binary arithmetic operation on two 128-bit operand
      # addresses. Multiplication, addition and subtraction are synthesized from
      # 64-bit halves; every other operator (division, remainder, the bitwise ops)
      # is out of scope and diagnosed with the shared message.
      def gen_int128_arith(op, l_addr, r_addr, token)
        case op
        when :mul then gen_int128_mul(l_addr, r_addr)
        when :add then gen_int128_add(l_addr, r_addr)
        when :sub then gen_int128_sub(l_addr, r_addr)
        else
          error_at(token, "'#{INT128_OP_SPELLINGS.fetch(op, op)}' on 128-bit integers is not supported yet")
        end
      end

      # 128-bit multiply: the low 64 bits are the 64-bit product of the low halves
      # (:mul), and the high 64 bits are the unsigned high product of the low
      # halves (:mulhi) plus the two cross products lo_a*hi_b and hi_a*lo_b — the
      # standard schoolbook expansion truncated to 128 bits, so the result is
      # correct for both signednesses (their low 128 bits coincide). Returns the
      # temporary's address.
      def gen_int128_mul(l_addr, r_addr)
        lo_a = load_int128_half(l_addr, 0)
        hi_a = load_int128_half(l_addr, 8)
        lo_b = load_int128_half(r_addr, 0)
        hi_b = load_int128_half(r_addr, 8)
        lo = new_vreg
        emit(:mul, dst: lo, a: lo_a, b: lo_b, size: 8)
        hi = new_vreg
        emit(:mulhi, dst: hi, a: lo_a, b: lo_b)
        hi = int128_add64(hi, int128_mul64(lo_a, hi_b))
        hi = int128_add64(hi, int128_mul64(hi_a, lo_b))
        int128_pack(lo, hi)
      end

      # 128-bit addition with carry: the low halves add, and the high halves add
      # together with the carry out of the low add, detected as "the low sum wrapped
      # below its first addend" (an unsigned compare). Returns the temp's address.
      def gen_int128_add(l_addr, r_addr)
        lo_a = load_int128_half(l_addr, 0)
        hi_a = load_int128_half(l_addr, 8)
        lo_b = load_int128_half(r_addr, 0)
        hi_b = load_int128_half(r_addr, 8)
        lo = int128_add64(lo_a, lo_b)
        carry = new_vreg
        emit(:ult, dst: carry, a: lo, b: lo_a, size: 8) # lo < lo_a => wrapped
        hi = int128_add64(int128_add64(hi_a, hi_b), carry)
        int128_pack(lo, hi)
      end

      # 128-bit subtraction with borrow: the low halves subtract, and the high
      # halves subtract together with the borrow (the low minuend was smaller than
      # the subtrahend, an unsigned compare). Returns the temp's address.
      def gen_int128_sub(l_addr, r_addr)
        lo_a = load_int128_half(l_addr, 0)
        hi_a = load_int128_half(l_addr, 8)
        lo_b = load_int128_half(r_addr, 0)
        hi_b = load_int128_half(r_addr, 8)
        lo = new_vreg
        emit(:sub, dst: lo, a: lo_a, b: lo_b, size: 8)
        borrow = new_vreg
        emit(:ult, dst: borrow, a: lo_a, b: lo_b, size: 8) # lo_a < lo_b => borrow
        hi = new_vreg
        emit(:sub, dst: hi, a: hi_a, b: hi_b, size: 8)
        hi2 = new_vreg
        emit(:sub, dst: hi2, a: hi, b: borrow, size: 8)
        int128_pack(lo, hi2)
      end

      # A 64-bit a + b into a fresh vreg (a building block for the 128-bit adds).
      def int128_add64(a, b)
        dst = new_vreg
        emit(:add, dst: dst, a: a, b: b, size: 8)
        dst
      end

      # A 64-bit a * b (low 64 of the product) into a fresh vreg.
      def int128_mul64(a, b)
        dst = new_vreg
        emit(:mul, dst: dst, a: a, b: b, size: 8)
        dst
      end

      # Packs a low and high 64-bit half into a fresh 128-bit temporary and returns
      # its address.
      def int128_pack(lo, hi)
        base = new_int128_temp
        store_int128_half(base, 0, lo)
        store_int128_half(base, 8, hi)
        base
      end

      # A 128-bit comparison, yielding an int 0/1, lowered branchlessly from 64-bit
      # compares of the halves. Equality is "both halves equal"; inequality "either
      # half differs". An ordering compares the high halves first — signed for a
      # signed __int128, unsigned for an unsigned one — and falls back to an
      # unsigned low compare when the highs are equal. When the highs differ the
      # *strict* high compare decides regardless of the operator's strictness (if
      # hi_a < hi_b then a < b, so "<=" too), so the result is
      # "hi != hi ? strict_hi_cmp : lo_cmp", assembled from 0/1 values with and/or/
      # xor (a select without a dedicated instruction).
      def gen_int128_comparison(op, l_addr, r_addr, signed)
        lo_a = load_int128_half(l_addr, 0)
        hi_a = load_int128_half(l_addr, 8)
        lo_b = load_int128_half(r_addr, 0)
        hi_b = load_int128_half(r_addr, 8)
        result =
          case op
          when :eq
            int128_bool_and(int128_cmp64(:eq, hi_a, hi_b), int128_cmp64(:eq, lo_a, lo_b))
          when :ne
            int128_bool_or(int128_cmp64(:ne, hi_a, hi_b), int128_cmp64(:ne, lo_a, lo_b))
          else
            strict_hi = if %i[lt le].include?(op) then (signed ? :lt : :ult) else (signed ? :gt : :ugt) end
            hi_cmp = int128_cmp64(strict_hi, hi_a, hi_b)
            lo_cmp = int128_cmp64(UNSIGNED_COMPARISONS.fetch(op), lo_a, lo_b)
            hi_ne = int128_cmp64(:ne, hi_a, hi_b)
            # result = hi_ne ? hi_cmp : lo_cmp, over 0/1 values.
            int128_bool_or(int128_bool_and(hi_ne, hi_cmp),
                           int128_bool_and(int128_bool_not(hi_ne), lo_cmp))
          end
        [result, Type::Int]
      end

      # A 64-bit compare `op` of a and b into a fresh int 0/1 vreg.
      def int128_cmp64(op, a, b)
        dst = new_vreg
        emit(op, dst: dst, a: a, b: b, size: 8)
        dst
      end

      # AND / OR / logical-NOT over 0/1 int values, used to assemble a 128-bit
      # comparison from its 64-bit pieces.
      def int128_bool_and(a, b)
        dst = new_vreg
        emit(:and, dst: dst, a: a, b: b)
        dst
      end

      def int128_bool_or(a, b)
        dst = new_vreg
        emit(:or, dst: dst, a: a, b: b)
        dst
      end

      def int128_bool_not(a)
        one = new_vreg
        emit(:const, dst: one, a: 1)
        dst = new_vreg
        emit(:xor, dst: dst, a: a, b: one)
        dst
      end

      def convert(vreg, from:, to:, token: nil)
        return vreg if from == to
        # A conversion touching a 128-bit integer (either side) needs the
        # two-eightbyte handling of #convert_int128, not the single-slot
        # width/sign changes below.
        return convert_int128(vreg, from, to, token) if wide128?(from) || wide128?(to)
        return to_bool(vreg, from) if to.bool?
        return convert_floating(vreg, from, to, token) if to.float? || from.float?

        if to.size == 8
          return vreg if from.size == 8 # long <-> unsigned long: same 64 bits

          dst = new_vreg
          emit(from.signed? ? :sext : :zext, dst: dst, a: vreg, size: 4)
          dst
        elsif to.size == 4
          vreg # the low 32 bits already hold the converted value
        else # to.size 1 or 2
          dst = new_vreg
          emit(to.signed? ? :sext : :zext, dst: dst, a: vreg, size: to.size)
          dst
        end
      end

      # A conversion where a floating type is on at least one side, lowered to
      # the format-changing IR (no integer widen/narrow reaches here). float<->
      # double is a single :ftof; a floating-to-integer conversion truncates
      # toward zero with :ftoi (then narrows to a <4-byte destination just as an
      # integer conversion would, so the slot holds a correctly ranged value);
      # an integer-to-floating conversion is :itof. Because cvtsi2s*/cvttss2si
      # are signed-only, a 64-bit *unsigned* integer on either side cannot ride
      # the plain :itof/:ftoi (whose top bit the hardware reads as a sign), so it
      # is synthesized branchwise from the signed primitives by
      # #u64_to_floating / #floating_to_u64. An `unsigned int` (32-bit) source is
      # already handled by :itof/:ftoi, whose 64-bit form covers its full range.
      def convert_floating(vreg, from, to, token)
        if from.float? && to.float?
          dst = new_vreg
          emit(:ftof, dst: dst, a: vreg, size: from.size)
          dst
        elsif from.float?
          return floating_to_u64(vreg, from) if unsigned_long?(to)

          # cvttss2si/cvttsd2si is signed, so a 32-bit *unsigned* destination
          # whose value falls in (INT_MAX, UINT_MAX] would overflow a 32-bit
          # truncation. Truncating at 64 bits is exact across the whole 0..2^32-1
          # range, and the destination keeps only its low bytes.
          width = to.unsigned? && to.size < 8 ? 8 : to.size
          dst = new_vreg
          emit(:ftoi, dst: dst, a: vreg, b: [width, to.signed?], size: from.size)
          return dst if to.size >= 4

          narrowed = new_vreg
          emit(to.signed? ? :sext : :zext, dst: narrowed, a: dst, size: to.size)
          narrowed
        else
          return u64_to_floating(vreg, to) if unsigned_long?(from)

          dst = new_vreg
          emit(:itof, dst: dst, a: vreg, b: [from.size, from.signed?], size: to.size)
          dst
        end
      end

      # Whether `type` is a 64-bit unsigned integer (`unsigned long` / `unsigned
      # long long`) — the one integer width whose top bit the signed float
      # conversion instructions would misread, so it takes the synthesized path.
      def unsigned_long?(type)
        type.integer? && type.unsigned? && type.size == 8
      end

      # `unsigned long` -> `to` (float or double), synthesized from the signed
      # :itof because cvtsi2s* reads a 64-bit source's top bit as a sign. When
      # that bit is clear the value fits a non-negative signed long and converts
      # directly. When it is set, the value is halved before the signed
      # conversion and the float result doubled back: `half = (x >> 1) | (x & 1)`
      # keeps a "sticky" low bit so a value dropped by the shift still rounds to
      # nearest-even, then `2 * (float)half` restores the magnitude with only the
      # single rounding the target width would apply directly. The result vreg is
      # written by both arms and read at the merge, mirroring the branch-and-join
      # slot pattern the va_arg lowering uses.
      def u64_to_floating(vreg, to)
        result = new_vreg
        small_label = new_label
        end_label = new_label

        top = emit_shift(:shr, vreg, 63, 8) # 1 when the top bit is set
        emit(:jump_if_zero, a: top, b: small_label)

        # Top bit set: convert x/2 (with a preserved sticky bit) and double it.
        lsb = emit_and_const(vreg, 1, 8)
        shifted = emit_shift(:shr, vreg, 1, 8)
        half = new_vreg
        emit(:or, dst: half, a: shifted, b: lsb, size: 8)
        halved = new_vreg
        emit(:itof, dst: halved, a: half, b: [8, true], size: to.size)
        doubled = new_vreg
        emit(:fadd, dst: doubled, a: halved, b: halved, size: to.size)
        emit(:copy, dst: result, a: doubled)
        emit(:jump, a: end_label)

        # Top bit clear: the value is a non-negative signed long, converted directly.
        emit(:label, a: small_label)
        direct = new_vreg
        emit(:itof, dst: direct, a: vreg, b: [8, true], size: to.size)
        emit(:copy, dst: result, a: direct)
        emit(:label, a: end_label)
        result
      end

      # `from` (float or double) -> `unsigned long`, synthesized from the signed
      # truncating :ftoi because cvttss2si yields a signed 64-bit result. A float
      # source widens to double first (an exact :ftof) so one double-width path
      # serves both. When the value is below 2^63 it fits a signed long and
      # truncates directly. Otherwise 2^63 is subtracted first so the remainder
      # fits the signed range, truncated, then the top bit is set back with an OR
      # — reconstructing `truncate(x)` for x in [2^63, 2^64). Out-of-range and NaN
      # inputs are undefined behavior in C, so the natural cvttsd2si result stands.
      def floating_to_u64(vreg, from)
        if from.size == 4
          widened = new_vreg
          emit(:ftof, dst: widened, a: vreg, size: 4) # float -> double, exact
          vreg = widened
        end

        result = new_vreg
        big_label = new_label
        end_label = new_label

        threshold = emit_float_const(9223372036854775808.0, Type::Double) # 2^63
        below = new_vreg
        emit(:flt, dst: below, a: vreg, b: threshold, size: 8) # x < 2^63 ? 1 : 0
        emit(:jump_if_zero, a: below, b: big_label)

        # Below 2^63: a plain signed truncation already yields the right bits.
        small = new_vreg
        emit(:ftoi, dst: small, a: vreg, b: [8, true], size: 8)
        emit(:copy, dst: result, a: small)
        emit(:jump, a: end_label)

        # 2^63 and up: truncate x - 2^63 (now in signed range) and set the top bit.
        emit(:label, a: big_label)
        reduced = new_vreg
        emit(:fsub, dst: reduced, a: vreg, b: threshold, size: 8)
        truncated = new_vreg
        emit(:ftoi, dst: truncated, a: reduced, b: [8, true], size: 8)
        top_bit = new_vreg
        emit(:const, dst: top_bit, a: 1 << 63, size: 8)
        restored = new_vreg
        emit(:or, dst: restored, a: truncated, b: top_bit, size: 8)
        emit(:copy, dst: result, a: restored)
        emit(:label, a: end_label)
        result
      end

      # The implicit conversion an assignment context (=, initialization, an
      # argument, a return, a "?:" arm) applies to a value of type `from_type`
      # bound to a `to_type` target. An arithmetic-to-arithmetic conversion
      # (integer, floating, or a mix) goes through #convert; a conversion of any
      # scalar to _Bool is "value != 0"; a pointer (or null pointer constant,
      # already full-width) otherwise passes through unchanged. `token` locates
      # an unsupported-floating-conversion diagnostic.
      def convert_for_assignment(value_vreg, from_type, to_type, token: nil)
        if to_type.bool? && (from_type.integer? || from_type.pointer? || from_type.float?)
          return to_bool(value_vreg, from_type)
        end
        return value_vreg unless to_type.arithmetic? && from_type.arithmetic?

        convert(value_vreg, from: from_type, to: to_type, token: token)
      end

      # "value != 0", the conversion of a scalar to _Bool: a nonzero source
      # becomes 1, zero becomes 0. A floating source compares against 0.0 with
      # the NaN-aware :fne (a NaN is nonzero, so becomes 1); a pointer or 8-byte
      # integer source compares at 64 bits so its whole value decides. The int
      # 0/1 result is already a valid _Bool representation.
      def to_bool(value_vreg, from_type)
        return int128_to_bool(value_vreg) if wide128?(from_type)

        if from_type.float?
          zero = emit_float_const(0.0, from_type)
          dst = new_vreg
          emit(:fne, dst: dst, a: value_vreg, b: zero, size: from_type.size)
          return dst
        end
        zero = new_vreg
        emit(:const, dst: zero, a: 0)
        dst = new_vreg
        emit(:ne, dst: dst, a: value_vreg, b: zero, size: (8 if wide_scalar?(from_type)))
        dst
      end

      # Whether a scalar's truth/zero test must run 64-bit: a pointer or an
      # 8-byte integer, whose high half would otherwise be ignored by a 32-bit
      # test.
      def wide_scalar?(type)
        type.pointer? || (type.integer? && type.size == 8)
      end

      # Reads a non-global scalar local's value into a usable vreg. A 1/2-byte
      # integer is re-derived from the slot's low bytes by its signedness
      # (:sext / :zext), guarding against a stale upper half after an aliased
      # pointer write through "&x" (the trap first seen for char in Step 11,
      # now general to every narrow type); a wider local's slot already holds a
      # usable value, so its slot vreg is returned directly.
      def read_local_scalar(local)
        type = local.type
        return local.storage unless type.integer? && (type.size == 1 || type.size == 2)

        dst = new_vreg
        emit(type.signed? ? :sext : :zext, dst: dst, a: local.storage, size: type.size)
        dst
      end

      # Emits a scalar load through `addr`, choosing the zero-extending :uload
      # for an unsigned narrow type (and _Bool) and the sign-extending :load
      # otherwise; the two coincide at width 4 and 8.
      def emit_scalar_load(dst, addr, type)
        op = type.integer? && type.unsigned? ? :uload : :load
        emit(op, dst: dst, a: addr, size: type.size)
      end

      # Guards a unary "*": its operand must be a pointer.
      def require_pointer(type, token)
        error_at(token, "invalid type argument of unary '*'") unless type.pointer?
      end

      # Guards an actual load/store through a pointer ("*p", "*p = v",
      # "p += 1", "e[i]", ...): beyond #require_pointer's plain pointer check,
      # a void pointer is rejected too, since its pointed-to type has no size
      # to load, store or scale by ("&*p", which never touches memory, is the
      # one place a void pointer's target may go unexamined). A pointer to an
      # incomplete struct is rejected for the same reason: its target has no
      # known size (member access checks completeness separately).
      def require_dereferenceable_pointer(type, token)
        require_pointer(type, token)
        error_at(token, "invalid use of void pointer") if type.target.void?
        require_complete(type.target, token)
      end

      # Rejects an incomplete type (a struct tag never defined, or a
      # forward-referenced enum tag with no visible enumerators) wherever a
      # complete object type is required — a variable or global, a sizeof, a
      # member's base struct, an array/pointer element being sized. A pointer to
      # either stays complete, so "enum E *p;" / "struct S *p;" pass this guard.
      def require_complete(type, token)
        return unless incomplete_type?(type)

        error_at(token, "invalid use of incomplete type '#{type}'")
      end

      # Whether `type` is an incomplete object type: an undefined struct/union, an
      # incomplete (forward-referenced) enum, or an incomplete array — an
      # unbounded "[]", the shape a struct's flexible array member has, which has
      # no size so "sizeof s.fam" / "_Alignof(int[])" are rejected here. Every
      # other type is complete.
      def incomplete_type?(type)
        (type.struct? && !type.complete?) ||
          type.is_a?(Type::EnumType) ||
          (type.array? && type.incomplete?)
      end

      # Guards a compound-assignment or "++"/"--" target that must be a scalar
      # the arithmetic can read and write: an aggregate (a struct or an array
      # member) has no arithmetic, so it is rejected with the same wording a
      # bad binary operand gets.
      def require_scalar_target(type, token)
        # A read-modify-write of a 128-bit integer (op= or ++/--) would need the
        # multi-word load/store this phase does not emit for such a target, so it
        # is diagnosed before the (invalid) narrow load would be produced.
        if wide128?(type)
          error_at(token, "compound assignment or increment on a 128-bit integer is not supported yet")
        end
        return unless type.struct? || type.array?

        error_at(token, "invalid operands to binary expression")
      end

      # Evaluates an expression used as a truth value (an if/while/do-while/for
      # condition, a "&&"/"||" operand, a "?:" condition) and returns the vreg
      # the branch instructions test against zero. An arithmetic value is used
      # directly. A pointer is a valid scalar condition too — its truth is "is
      # not null" — so it is desugared to a 64-bit "pointer != 0", yielding an
      # int 0/1 the 32-bit :jump_if_zero test then reads without ever truncating
      # the address (the concern that made Step 9 reject pointer conditions
      # outright). A struct has no truth value and is rejected; a void one is
      # already caught by #gen_value.
      def gen_condition(node)
        value, type = gen_value(node)
        require_scalar_for_truth(type, node.token)
        # A 128-bit condition tests both eightbytes (value is its address).
        return int128_to_bool(value) if wide128?(type)

        # A floating condition is its NaN-aware truth "value != 0.0" (:fne),
        # lowered to an int 0/1 the branch then reads.
        if type.float?
          zero = emit_float_const(0.0, type)
          dst = new_vreg
          emit(:fne, dst: dst, a: value, b: zero, size: type.size)
          return dst
        end
        # A 4-byte-or-narrower integer's low 32 bits already hold its value, so
        # the 32-bit :jump_if_zero test reads it directly. A pointer or an
        # 8-byte integer must be tested at 64 bits so its whole value decides,
        # so it is desugared to "value != 0" (an int 0/1) up front.
        return value if type.integer? && type.size <= 4

        zero = new_vreg
        emit(:const, dst: zero, a: 0)
        dst = new_vreg
        emit(:ne, dst: dst, a: value, b: zero, size: 8)
        dst
      end

      # Guards a value used for its truth (a condition or a "!" operand): an
      # arithmetic value or a pointer is a scalar with a well-defined truth
      # value, but a struct is not (void is already rejected by #gen_value
      # before it reaches here).
      def require_scalar_for_truth(type, token)
        return if type.arithmetic? || type.pointer?

        error_at(token, "used struct type value where scalar is required")
      end

      COMPARISON_OPS = %i[eq ne lt le gt ge].freeze

      def comparison_op?(op)
        COMPARISON_OPS.include?(op)
      end

      # The two shift operators, whose operand order matters (the count is the
      # right operand, never commuted) and whose lowering is special (the count
      # rides in cl and each operand promotes on its own), so #gen_binary_op
      # handles them apart from the ordinary arithmetic ops.
      SHIFT_OPS = %i[shl shr].freeze

      # The relational operators' unsigned counterparts, chosen when the common
      # operand type is unsigned (and always for pointer ordering). Equality
      # (:eq/:ne) is sign-independent and so absent here.
      UNSIGNED_COMPARISONS = { lt: :ult, le: :ule, gt: :ugt, ge: :uge }.freeze

      # The source arithmetic operators that have a floating lowering, mapped to
      # their f-prefixed IR ops; % and the bitwise operators have no floating
      # form (a floating operand is rejected as a constraint violation).
      FLOAT_ARITHMETIC = { add: :fadd, sub: :fsub, mul: :fmul, div: :fdiv }.freeze

      # The comparison operators mapped to their NaN-aware floating IR ops,
      # chosen when the operands' common type is a floating one.
      FLOAT_COMPARISONS = { eq: :feq, ne: :fne, lt: :flt, le: :fle, gt: :fgt, ge: :fge }.freeze

      # "==" and "!=" alone let a void * mix with any other pointer type (as
      # in an assignment); every other pointer comparison ("<", "<=", ">",
      # ">=") requires the exact same pointer type on both sides, void *
      # included.
      EQUALITY_OPS = %i[eq ne].freeze

      def pointer_comparable?(op, lhs_type, rhs_type)
        return lhs_type == rhs_type || lhs_type.target.void? || rhs_type.target.void? if EQUALITY_OPS.include?(op)

        lhs_type == rhs_type
      end

      # Pointer arithmetic (p + n, p - n, p - q) scales by the pointed-to
      # type's size, which void has none of; rejected up front with "invalid
      # use of void pointer" rather than let #size raise deep in the lowering.
      # Returns `type` so it can sit directly in #binary_result_type's
      # if/elsif chain.
      def require_non_void_pointer(type, token)
        error_at(token, "invalid use of void pointer") if type.target.void?
        # Pointer arithmetic scales by the target's size, which an incomplete
        # struct target has none of, so it is rejected here alongside void.
        require_complete(type.target, token)
        type
      end

      # Settles a binary operation's result type and rejects any illegal
      # operand combination with "invalid operands to binary expression".
      # Integer operands mix per the usual arithmetic conversions
      # (#common_arithmetic_type), except a shift, whose result is its promoted
      # left operand's type alone (6.5.7). Shared by the lowering path
      # (#gen_binary) and the code-free type inference used by sizeof
      # (#static_type):
      #   * comparisons: integer/integer, or pointer/pointer per
      #     #pointer_comparable? -> int;
      #   * shifts "<<" ">>": integer/integer -> the promoted left type;
      #   * "+": integer/integer -> their common type, and pointer/integer or
      #     integer/pointer -> that (non-void) pointer;
      #   * "-": integer/integer -> their common type, pointer/integer -> that
      #     (non-void) pointer, and same-type (non-void) pointer/pointer -> int;
      #   * "*" "/" "%", the bitwise "&" "|" "^": integer/integer -> their
      #     common type only (any pointer operand is invalid), which is the
      #     fall-through "else" case below.
      def binary_result_type(op, lhs_type, rhs_type, token)
        result =
          if comparison_op?(op)
            if lhs_type.arithmetic? && rhs_type.arithmetic? then Type::Int
            elsif lhs_type.pointer? && rhs_type.pointer? && pointer_comparable?(op, lhs_type, rhs_type) then Type::Int
            end
          elsif SHIFT_OPS.include?(op)
            # A shift's operands are integers only; a floating operand is a
            # constraint violation, so the promoted-left result is withheld.
            integer_promote(lhs_type) if lhs_type.integer? && rhs_type.integer?
          else
            case op
            when :add
              if lhs_type.arithmetic? && rhs_type.arithmetic? then common_arithmetic_type(lhs_type, rhs_type)
              elsif lhs_type.pointer? && rhs_type.integer? then require_non_void_pointer(lhs_type, token)
              elsif lhs_type.integer? && rhs_type.pointer? then require_non_void_pointer(rhs_type, token)
              end
            when :sub
              if lhs_type.arithmetic? && rhs_type.arithmetic? then common_arithmetic_type(lhs_type, rhs_type)
              elsif lhs_type.pointer? && rhs_type.integer? then require_non_void_pointer(lhs_type, token)
              elsif lhs_type.pointer? && rhs_type.pointer? && lhs_type == rhs_type
                require_non_void_pointer(lhs_type, token)
                Type::Int
              end
            when :mul, :div
              # Multiplication and division admit a floating operand (unlike %
              # and the bitwise operators below); their common type is the result.
              common_arithmetic_type(lhs_type, rhs_type) if lhs_type.arithmetic? && rhs_type.arithmetic?
            else # :mod, :and, :or, :xor — integer operands only
              common_arithmetic_type(lhs_type, rhs_type) if lhs_type.integer? && rhs_type.integer?
            end
          end
        result || error_at(token, "invalid operands to binary expression")
      end

      # A subscripted value must be a pointer (an array has already decayed to
      # one); the result is the pointed-to element type.
      def subscript_element_type(base_type, token)
        unless base_type.pointer?
          error_at(token, "subscripted value is neither array nor pointer")
        end
        base_type.target
      end

      # sizeof measures the operand's type without evaluating it. A bare array
      # variable keeps its array type (no decay), so "sizeof a" is the whole
      # array; a string literal is likewise measured as its char[N+1] array
      # (NUL included) rather than the char * it would decay to; every other
      # operand takes its ordinary (decayed) expression type.
      def sizeof_operand_type(node)
        if node.is_a?(Front::AST::VariableRef)
          local = lookup_variable(node.name)
          # A bare function name under sizeof keeps its function type, which
          # gen_sizeof then rejects ("sizeof f" has no size); a variable keeps
          # its declared type with no array-to-pointer decay.
          return local.type if local

          sig = @signatures[node.name] ||
                error_at(node.token, "undeclared variable '#{node.name}'")
          function_type_of(sig)
        elsif node.is_a?(Front::AST::StringLit)
          Type::Array.new(@plain_char, node.value.bytesize + 1)
        elsif node.is_a?(Front::AST::MemberAccess)
          # A member keeps its declared type here (no array-to-pointer decay),
          # so "sizeof s.arr" measures the whole member array, like "sizeof a"
          # for a bare array variable.
          static_member(node).type
        elsif node.is_a?(Front::AST::CompoundLiteral)
          # "sizeof (T){...}" measures the whole object, with no array-to-pointer
          # decay, exactly as "sizeof a" does for a variable of that type.
          node.type
        else
          static_type(node)
        end
      end

      # Infers an expression's rvalue type without emitting any code, applying
      # the same rules (and array-to-pointer decay) as #gen_expr. Used only to
      # resolve a sizeof operand's type.
      def static_type(node)
        case node
        when Front::AST::IntLit
          node.type
        when Front::AST::FloatLit
          node.type
        when Front::AST::SizeofExpr, Front::AST::SizeofType, Front::AST::AlignofType,
             Front::AST::BuiltinOffsetof
          Type::ULong
        when Front::AST::Call
          call_return_type(node)
        when Front::AST::StringLit
          Type::Pointer.new(@plain_char)
        when Front::AST::VariableRef
          local = lookup_variable(node.name)
          if local
            local.type.array? ? Type::Pointer.new(local.type.element) : local.type
          else
            sig = @signatures[node.name] ||
                  error_at(node.token, "undeclared variable '#{node.name}'")
            Type::Pointer.new(function_type_of(sig))
          end
        when Front::AST::Subscript
          subscript_element_type(static_type(node.target), node.token)
        when Front::AST::MemberAccess
          member = static_member(node)
          decay(member.type)
        when Front::AST::Binary
          static_binary_type(node)
        when Front::AST::Cast
          # A cast's rvalue type is simply the type named, mirroring #gen_cast.
          # sizeof rejects a "(void)e" operand through gen_sizeof's void guard,
          # just as it would a bare void.
          node.type
        when Front::AST::CompoundLiteral
          # A compound literal's rvalue type mirrors #gen_compound_literal: an
          # array decays to a pointer to its element, every other object type
          # (struct, scalar) is itself.
          decay(node.type)
        when Front::AST::Unary
          static_unary_type(node)
        when Front::AST::Assignment, Front::AST::CompoundAssignment, Front::AST::IncDec
          static_type(node.target)
        when Front::AST::Comma
          # The comma operator's type is its right operand's, mirroring #gen_comma
          # (the left operand is evaluated only for effect), so "sizeof(a, b)"
          # measures b's type.
          static_type(node.right)
        when Front::AST::LogicalAnd, Front::AST::LogicalOr,
             Front::AST::BuiltinConstantP, Front::AST::BuiltinBitScan
          Type::Int
        when Front::AST::BuiltinUnreachable
          Type::Void
        when Front::AST::BuiltinAlloca
          # "__builtin_alloca(n)" yields a "void *" (see #gen_builtin_alloca), the
          # type CRuby's RB_ALLOCV macro relies on when it picks between the
          # alloca and heap arms of a "?:" — a context that reaches type inference.
          Type::Pointer.new(Type::Void)
        when Front::AST::Conditional
          static_conditional_type(node)
        when Front::AST::StatementExpr
          static_statement_expr_type(node)
        else
          raise "unsupported expression: #{node.class}"
        end
      end

      # The type of a GNU statement expression without emitting code, mirroring
      # #gen_statement_expr: a block whose last item is not an
      # expression-statement is void; otherwise the type is that last
      # expression's. The last expression may reference a variable the block
      # declares, so a scope is pushed and every top-level declaration's declared
      # type is bound into it (storage is irrelevant to type inference) before
      # the last expression's type is inferred, then the scope is popped.
      def static_statement_expr_type(node)
        items = node.body.items
        last = items.last
        return Type::Void unless last.is_a?(Front::AST::ExpressionStmt)

        @scopes.push({})
        begin
          items.each do |item|
            next unless item.is_a?(Front::AST::VariableDecl)

            @scopes.last[item.name] =
              Local.new(type: item.type, storage: nil, global: false, const: item.const)
          end
          static_type(last.expr)
        ensure
          @scopes.pop
        end
      end

      # The array-to-pointer decay applied to an rvalue type: an array becomes a
      # pointer to its element, everything else (a struct included, since it
      # does not decay) is left as is. Used by the code-free type inference.
      def decay(type)
        type.array? ? Type::Pointer.new(type.element) : type
      end

      # Resolves the member a "." / "->" selects, using only static types (no
      # code emitted), for sizeof and address-of. It mirrors #gen_struct_base +
      # #gen_member_address: the base's struct type is inferred, an incomplete
      # struct or a base that is not a structure is rejected, and a missing
      # member is diagnosed. Returns the Type::Member.
      def static_member(node)
        base_type = static_type(node.base)
        struct_type =
          if node.arrow
            unless base_type.pointer? && base_type.target.struct?
              error_at(node.token, "request for member '#{node.member}' in something not a structure")
            end
            base_type.target
          else
            unless base_type.struct?
              error_at(node.token, "request for member '#{node.member}' in something not a structure")
            end
            base_type
          end
        require_complete(struct_type, node.token)
        struct_type.member(node.member) ||
          error_at(node.token, "no member named '#{node.member}' in '#{struct_type}'")
      end

      # A call's rvalue type without emitting code: the callee's return type,
      # resolved the same way #gen_call splits a direct call from an indirect
      # one.
      def call_return_type(node)
        callee = node.callee
        if callee.is_a?(Front::AST::VariableRef) && lookup_variable(callee.name).nil?
          sig = @signatures[callee.name]
          error_at(node.token, "implicit declaration of function '#{callee.name}'") unless sig
          sig[:return_type]
        else
          called_function_type(static_type(callee), node.token).return_type
        end
      end

      # The type of "condition ? then_expr : else_expr" without emitting code,
      # mirroring #gen_conditional: both arms must agree, and that shared type
      # is the result.
      def static_conditional_type(node)
        conditional_result_type(node.then_expr, static_type(node.then_expr),
                                node.else_expr, static_type(node.else_expr), node.token)
      end

      # A binary operation's rvalue type without emitting code, mirroring
      # #gen_binary: an "=="/"!=" between a pointer and a null pointer constant
      # is an int comparison (the bare operand types would look mismatched),
      # everything else defers to #binary_result_type.
      def static_binary_type(node)
        lhs_type = static_type(node.lhs)
        rhs_type = static_type(node.rhs)
        if EQUALITY_OPS.include?(node.op) &&
           ((lhs_type.pointer? && Front::AST.null_pointer_constant?(node.rhs)) ||
            (rhs_type.pointer? && Front::AST.null_pointer_constant?(node.lhs)))
          return Type::Int
        end
        binary_result_type(node.op, lhs_type, rhs_type, node.token)
      end

      def static_unary_type(node)
        case node.op
        when :not
          Type::Int
        when :neg
          integer_promote(static_type(node.operand))
        when :deref
          type = static_type(node.operand)
          require_pointer(type, node.token)
          type.target
        when :addr
          static_address_of_type(node)
        end
      end

      # The type of "&operand" without emitting code, mirroring #gen_address_of.
      def static_address_of_type(node)
        operand = node.operand
        if operand.is_a?(Front::AST::VariableRef)
          local = lookup_variable(operand.name)
          # "&f" of a function name is a pointer to the function, like the
          # decayed designator itself; "&a" is a pointer to the whole array.
          return static_type(operand) unless local

          Type::Pointer.new(local.type)
        elsif operand.is_a?(Front::AST::Subscript)
          Type::Pointer.new(subscript_element_type(static_type(operand.target), operand.token))
        elsif operand.is_a?(Front::AST::MemberAccess)
          Type::Pointer.new(static_member(operand).type)
        elsif operand.is_a?(Front::AST::Unary) && operand.op == :deref
          type = static_type(operand.operand)
          require_pointer(type, operand.token)
          type
        elsif operand.is_a?(Front::AST::CompoundLiteral)
          # "&(T){...}" is a pointer to the unnamed object of type T (no decay),
          # mirroring the CompoundLiteral branch of #gen_address_of.
          Type::Pointer.new(operand.type)
        else
          error_at(node.token, "lvalue required as unary '&' operand")
        end
      end

      # Resolves a variable by walking scopes from innermost to outermost, so
      # an inner declaration shadows an outer one with the same name. Returns
      # nil when no variable binds the name — the caller decides whether the
      # name might instead be a function designator or is simply undeclared.
      def lookup_variable(name)
        # Before any function body is entered @scopes is unset; a file-scope
        # initializer folded in that phase (a "sizeof <expression>" whose operand
        # names a global) still needs to resolve names, so fall back to the
        # file-scope bindings alone.
        scopes = @scopes || [@global_bindings]
        scopes.reverse_each do |scope|
          local = scope[name]
          return local if local
        end
        nil
      end

      # Like #lookup_variable but for the contexts that require an object (an
      # assignment target, a "++"/"--"): a name that binds no variable is
      # undeclared here (a function name never reaches these, the parser having
      # made it a call or a decayed pointer instead).
      def lookup_local(name, token)
        lookup_variable(name) || error_at(token, "undeclared variable '#{name}'")
      end

      # Rejects a write to a top-level const-qualified variable or parameter — a
      # plain assignment, a compound assignment or "++"/"--". Only the variable's
      # own const-ness is tracked (M1 carries no qualified types), so a write
      # through a pointer, a subscript or a struct member is not caught here.
      def reject_readonly_write(local, target, token)
        return unless local.const

        error_at(token, "assignment of read-only variable '#{target.name}'")
      end

      # The Type::FunctionType a function's recorded signature describes, used
      # both to build the pointer a function designator decays to and to check
      # an indirect call or a function-pointer assignment against it.
      def function_type_of(sig)
        Type::FunctionType.new(sig[:return_type], sig[:param_types], sig[:variadic])
      end

      def new_vreg
        vreg = @vreg_count
        @vreg_count += 1
        vreg
      end

      # Reserves a stack object of `byte_size` bytes, returning its id (an index
      # into @stack_objects the backend lays out below the vreg slots).
      def new_object(byte_size)
        id = @stack_objects.size
        @stack_objects << byte_size
        id
      end

      def new_label
        label = @label_count
        @label_count += 1
        label
      end

      def emit(op, dst: nil, a: nil, b: nil, size: nil)
        @insts << Instruction.new(op, dst: dst, a: a, b: b, size: size)
      end

      def error_at(token, description)
        raise CompileError.new(
          description,
          filename: token.filename,
          line: token.line,
          column: token.column,
          source_line: token.source_line
        )
      end
    end
  end
end
