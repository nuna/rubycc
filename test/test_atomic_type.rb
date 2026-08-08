# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The C11 `_Atomic` type specifier and the <stdatomic.h> layer built on top of
# the __atomic_* builtins TestAtomicBuiltins already pins.
#
# rubycc compiles `_Atomic T` as plain `T`. That is a measurement, not a
# convenience: gcc gives `_Atomic(T)` the same sizeof and _Alignof as `T` for
# every integer, floating and pointer type, and test_header_abi.rb's STDATOMIC
# spec is where that is checked type by type against the gcc oracle. It stops
# being true for an aggregate (gcc raises a power-of-two-sized struct's
# alignment to its size, and routes the other sizes through libatomic) and it
# buys nothing for a 16-byte scalar (no single instruction accesses one on
# either baseline ISA rubycc emits for), so both are refused here rather than
# compiled to something that merely looks atomic.
#
# The semantics follow TestAtomicBuiltins' shape: an execution oracle. A
# single-threaded program's atomic operations have completely determined
# results, so running the same source under gcc and under rubycc and demanding
# identical output fixes both the value each macro yields and the state it
# leaves the object in. The few things gcc cannot be the oracle for -- the
# ATOMIC_*_LOCK_FREE answers rubycc deliberately gives differently, and the
# names the bundled header deliberately omits -- are asserted against stated
# expectations instead.
class TestAtomicType < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # Every spelling C11 gives `_Atomic`, in every declaration context this
  # subset admits one: the qualifier before and after the type, the
  # parenthesized atomic-type-specifier, a typedef of either, a pointer level
  # qualified with `_Atomic`, a struct member, a parameter and a return type.
  # The sizes are printed alongside the values so a spelling that parsed but
  # landed on the wrong type shows up as a width difference rather than only as
  # a wrong number.
  DECLARATION_SPELLINGS_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>

    _Atomic int qualified_first = 11;
    int _Atomic qualified_last = 22;
    _Atomic(size_t) parenthesized = 33;
    static _Atomic(unsigned int) internal = 44;
    typedef _Atomic long atomic_long_alias;
    typedef _Atomic(unsigned long) atomic_ulong_alias;

    struct holder {
      _Atomic int counter;
      _Atomic(void *) slot;
      int plain;
    };

    static _Atomic int doubled(_Atomic int value) { return value * 2; }
    static size_t through_pointer(_Atomic(size_t) *p) { return *p; }

    int main(void) {
      atomic_long_alias a = 55;
      atomic_ulong_alias b = 66;
      _Atomic int local = 77;
      int * _Atomic qualified_pointer = &local;
      const _Atomic int folded = 88;
      struct holder h;

      h.counter = 99;
      h.slot = &local;
      h.plain = 100;

      printf("%d %d %zu %u %ld %lu\\n", qualified_first, qualified_last,
             parenthesized, internal, a, b);
      printf("%d %d %d %d\\n", local, *qualified_pointer, folded, h.counter);
      printf("%d %d %d\\n", h.plain, *(int *)h.slot, doubled(local));
      printf("%zu\\n", through_pointer(&parenthesized));
      printf("%zu %zu %zu %zu\\n", sizeof(struct holder), offsetof(struct holder, counter),
             offsetof(struct holder, slot), offsetof(struct holder, plain));
      printf("%zu %zu %zu %zu\\n", sizeof(_Atomic int), sizeof(_Atomic(size_t)),
             sizeof(atomic_long_alias), sizeof(int * _Atomic));
      printf("%zu %zu %zu\\n", _Alignof(_Atomic int), _Alignof(_Atomic(double)),
             _Alignof(_Atomic(void *)));
      return 0;
    }
  C

  # `_Atomic` where a type-name is written rather than a declaration: the cast,
  # sizeof and _Alignof operands, and a compound literal. Each is the
  # parenthesized spelling nested inside the surrounding parentheses, which is
  # where a parser that guessed at the "(" would go wrong.
  TYPE_NAME_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    int main(void) {
      double d = 7.9;
      long value = (_Atomic long)d;
      unsigned int narrowed = (_Atomic(unsigned int))(-1L);
      int *p = (_Atomic(int *))0;
      printf("%ld %u %d\\n", value, narrowed, p == NULL);
      printf("%zu %zu %zu\\n", sizeof(_Atomic(int)), sizeof(_Atomic(long long)),
             sizeof(_Atomic(char)));
      printf("%zu %zu\\n", _Alignof(_Atomic(short)), _Alignof(_Atomic(int *)));
      printf("%d\\n", (int)sizeof((_Atomic(size_t)){ 5 }));
      return 0;
    }
  C

  # Every generic macro the bundled <stdatomic.h> provides, each in its own
  # statement so the returned value and the object's new state are read at
  # separate sequence points (a printf doing both would compare rubycc's
  # left-to-right argument evaluation against gcc's right-to-left, which C
  # leaves unspecified -- the same reason TestAtomicBuiltins splits its calls).
  GENERIC_MACROS_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    #include <stdatomic.h>

    static _Atomic(size_t) wide = 100;
    static int cells[8];
    static _Atomic(int *) slot;

    int main(void) {
      atomic_int object;
      int previous;
      int expected;
      int ok;
      size_t wide_previous;

      atomic_init(&object, 7);
      printf("%d\\n", atomic_load(&object));
      printf("%d\\n", atomic_load_explicit(&object, memory_order_acquire));

      atomic_store(&object, 11);                                    printf("%d\\n", object);
      atomic_store_explicit(&object, 12, memory_order_release);     printf("%d\\n", object);

      previous = atomic_exchange(&object, 20);                      printf("%d %d\\n", previous, object);
      previous = atomic_exchange_explicit(&object, 21, memory_order_acq_rel);
      printf("%d %d\\n", previous, object);

      previous = atomic_fetch_add(&object, 5);                      printf("%d %d\\n", previous, object);
      previous = atomic_fetch_sub(&object, 3);                      printf("%d %d\\n", previous, object);
      previous = atomic_fetch_add_explicit(&object, 2, memory_order_relaxed);
      printf("%d %d\\n", previous, object);
      previous = atomic_fetch_sub_explicit(&object, 1, memory_order_relaxed);
      printf("%d %d\\n", previous, object);

      expected = atomic_load(&object);
      ok = atomic_compare_exchange_strong(&object, &expected, 40);
      printf("%d %d %d\\n", ok, expected, object);
      expected = 999;
      ok = atomic_compare_exchange_weak(&object, &expected, 41);
      printf("%d %d %d\\n", ok, expected, object);
      expected = atomic_load(&object);
      ok = atomic_compare_exchange_strong_explicit(&object, &expected, 42,
                                                   memory_order_acq_rel, memory_order_relaxed);
      printf("%d %d %d\\n", ok, expected, object);
      expected = 5;
      ok = atomic_compare_exchange_weak_explicit(&object, &expected, 43,
                                                 memory_order_acq_rel, memory_order_relaxed);
      printf("%d %d %d\\n", ok, expected, object);

      wide_previous = atomic_fetch_add(&wide, 8);                   printf("%zu %zu\\n", wide_previous, wide);

      atomic_thread_fence(memory_order_seq_cst);
      atomic_signal_fence(memory_order_seq_cst);

      /* A pointer object: gcc's atomic add is *unscaled* on one (measured --
         atomic_fetch_add(&p, 1) on an "int *" advances p by a single byte), so
         the differential pins that too. */
      atomic_init(&slot, cells);
      printf("%ld\\n", (long)(atomic_load(&slot) - cells));
      printf("%ld\\n", (long)((char *)atomic_fetch_add(&slot, 4) - (char *)cells));
      printf("%ld\\n", (long)((char *)atomic_load(&slot) - (char *)cells));

      printf("%zu %d\\n", (size_t)ATOMIC_VAR_INIT(3), kill_dependency(9));
      return 0;
    }
  C

  # The exact shape google-protobuf's bundled upb reaches rubycc with: a
  # `#define UPB_ATOMIC(T) _Atomic(T)` wrapper used for a file-scope object, a
  # struct member and a pointer member, driven through the same
  # atomic_*_explicit macros upb's port_atomic layer wraps. This is the case the
  # whole feature exists for, so it is written out rather than inferred from the
  # cases above.
  UPB_SHAPED_SOURCE = <<~C
    #include <stdio.h>
    #include <stddef.h>
    #include <stdint.h>
    #include <stdatomic.h>

    #define UPB_ATOMIC(T) _Atomic(T)

    static UPB_ATOMIC(size_t) max_block_size = 4096;

    typedef struct arena_internal {
      UPB_ATOMIC(uintptr_t) parent_or_count;
      UPB_ATOMIC(struct arena_internal *) next;
      UPB_ATOMIC(int32_t) refs;
    } arena_internal;

    static arena_internal root;
    static arena_internal child;

    /* upb's upb_Atomic_Init maps to atomic_init, the run-time initialization
       C11 gives an atomic object. */
    static void upb_init(void) {
      atomic_init(&root.parent_or_count, 1);
      atomic_init(&root.next, NULL);
      atomic_init(&root.refs, 0);
    }

    int main(void) {
      uintptr_t poc;
      int32_t count;
      int ok;

      upb_init();
      printf("%zu\\n", atomic_load_explicit(&max_block_size, memory_order_relaxed));
      atomic_store_explicit(&max_block_size, 8192, memory_order_relaxed);
      printf("%zu\\n", atomic_load_explicit(&max_block_size, memory_order_relaxed));

      poc = atomic_load_explicit(&root.parent_or_count, memory_order_acquire);
      printf("%lu\\n", (unsigned long)poc);
      ok = atomic_compare_exchange_weak_explicit(&root.parent_or_count, &poc, 5,
                                                 memory_order_release, memory_order_acquire);
      printf("%d %lu\\n", ok, (unsigned long)atomic_load_explicit(&root.parent_or_count,
                                                                 memory_order_relaxed));

      poc = 12345;
      ok = atomic_compare_exchange_strong_explicit(&root.parent_or_count, &poc, 6,
                                                   memory_order_release, memory_order_acquire);
      printf("%d %lu\\n", ok, (unsigned long)poc);

      count = atomic_fetch_add_explicit(&root.refs, 1, memory_order_acq_rel);
      printf("%d\\n", (int)count);
      count = atomic_fetch_sub_explicit(&root.refs, 1, memory_order_acq_rel);
      printf("%d %d\\n", (int)count, (int)atomic_load_explicit(&root.refs, memory_order_relaxed));

      atomic_store_explicit(&root.next, &child, memory_order_release);
      printf("%d\\n", atomic_load_explicit(&root.next, memory_order_acquire) == &child);
      printf("%d\\n", atomic_exchange_explicit(&root.next, NULL, memory_order_acq_rel) == &child);
      return 0;
    }
  C

  # The names the bundled header deliberately does not define, each with the
  # builtin it would need. gcc's answer for all of them is "declared", so this
  # cannot be a differential: it reports rubycc's own behaviour and the test
  # names what is expected. A missing name is a compile error the caller sees;
  # a name that expanded to something non-atomic would not be.
  ABSENT_NAMES = {
    "atomic_fetch_or(&object, 1)" => "no __atomic_fetch_or builtin",
    "atomic_fetch_and(&object, 1)" => "no __atomic_fetch_and builtin",
    "atomic_fetch_xor(&object, 1)" => "no __atomic_fetch_xor builtin",
    "atomic_fetch_or_explicit(&object, 1, memory_order_seq_cst)" => "no __atomic_fetch_or builtin",
    "atomic_is_lock_free(&object)" => "no __atomic_is_lock_free builtin"
  }.freeze

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
  end

  def test_declaration_spellings_match_gcc
    assert_matches_gcc(DECLARATION_SPELLINGS_SOURCE, "atomic_declarations")
  end

  def test_type_names_match_gcc
    assert_matches_gcc(TYPE_NAME_SOURCE, "atomic_type_names")
  end

  def test_generic_macros_match_gcc
    assert_matches_gcc(GENERIC_MACROS_SOURCE, "atomic_generic_macros")
  end

  def test_upb_shaped_program_matches_gcc
    assert_matches_gcc(UPB_SHAPED_SOURCE, "atomic_upb_shaped")
  end

  # The ATOMIC_*_LOCK_FREE answers, which are rubycc's own rather than gcc's:
  # gcc says 2 (always lock-free) for all ten because it falls back to
  # libatomic for the widths its ISA cannot do inline, while rubycc lowers
  # atomic operations at 4 and 8 bytes only and refuses the rest, so 0 is the
  # honest answer there. A program branching on these therefore takes its
  # non-lock-free path for exactly the types whose operations rubycc would
  # reject.
  def test_lock_free_macros_report_the_widths_rubycc_actually_lowers
    source = <<~C
      #include <stdio.h>
      #include <stdatomic.h>
      int main(void) {
        printf("%d %d %d %d %d %d %d %d %d %d\\n",
               ATOMIC_BOOL_LOCK_FREE, ATOMIC_CHAR_LOCK_FREE, ATOMIC_CHAR16_T_LOCK_FREE,
               ATOMIC_SHORT_LOCK_FREE, ATOMIC_CHAR32_T_LOCK_FREE, ATOMIC_WCHAR_T_LOCK_FREE,
               ATOMIC_INT_LOCK_FREE, ATOMIC_LONG_LOCK_FREE, ATOMIC_LLONG_LOCK_FREE,
               ATOMIC_POINTER_LOCK_FREE);
        return 0;
      }
    C
    status, stdout = run_source(source, :rubycc)
    assert_equal 0, status
    assert_equal "0 0 0 0 2 2 2 2 2 2\n", stdout
  end

  def test_absent_atomic_names_are_refused_rather_than_mislowered
    ABSENT_NAMES.each do |call, reason|
      source = <<~C
        #include <stdatomic.h>
        int main(void) { atomic_int object; atomic_init(&object, 1); return (int)#{call}; }
      C
      error = assert_raises(Rubycc::CompileError, "expected '#{call}' to be refused (#{reason})") do
        compile(source)
      end
      assert_match(/undeclared|unknown function|implicit/i, error.message)
    end
  end

  # atomic_flag needs a 1-byte test-and-set, which rubycc has no builtin for, so
  # the type is absent too rather than typedef'd to something of the wrong
  # width (gcc's atomic_flag is one byte -- measured).
  def test_atomic_flag_is_absent
    error = assert_raises(Rubycc::CompileError) do
      compile("#include <stdatomic.h>\nint main(void) { atomic_flag f; return (int)sizeof(f); }\n")
    end
    assert_match(/atomic_flag/, error.message)
  end

  # An aggregate under _Atomic is where "same layout as T" stops holding: gcc
  # raises a power-of-two-sized struct's alignment to its size (measured: a
  # 2-byte struct goes from _Alignof 1 to 2, a 16-byte one from 8 to 16) and
  # uses libatomic's locked path for the rest, so compiling one as a plain
  # struct would drop both the layout and the atomicity without the caller
  # noticing.
  def test_aggregate_atomic_types_are_diagnosed
    ["struct pair { int a, b; }; _Atomic struct pair value;",
     "struct pair { int a, b; }; _Atomic(struct pair) value;",
     "union both { int i; float f; }; _Atomic union both value;",
     "_Atomic(struct { char a, b; }) value;"].each do |declaration|
      error = assert_raises(Rubycc::CompileError, "expected '#{declaration}' to be refused") do
        compile("#{declaration}\nint main(void) { return 0; }\n")
      end
      assert_match(/'_Atomic' is not supported on/, error.message)
      assert_match(/integer, floating and pointer types of 1, 2, 4, 8 bytes/, error.message)
    end
  end

  # A 16-byte scalar does share T's layout, but no single instruction accesses
  # one on either baseline ISA rubycc emits for (x86-64 without cmpxchg16b,
  # armv8-a without LSE), so it is refused for the same reason the builtins
  # refuse a 16-byte object.
  def test_wide_scalar_atomic_types_are_diagnosed
    ["_Atomic __int128 value;", "_Atomic(unsigned __int128) value;"].each do |declaration|
      error = assert_raises(Rubycc::CompileError, "expected '#{declaration}' to be refused") do
        compile("#{declaration}\nint main(void) { return 0; }\n")
      end
      assert_match(/'_Atomic' is not supported on/, error.message)
    end
  end

  # C11 6.7.2.4p3 forbids _Atomic on an array or a function type outright, and
  # gcc diagnoses the array form ("'_Atomic'-qualified array type", measured).
  def test_array_and_function_atomic_types_are_diagnosed
    error = assert_raises(Rubycc::CompileError) do
      compile("typedef int row[3];\n_Atomic row value;\nint main(void) { return 0; }\n")
    end
    assert_match(/'_Atomic' cannot be applied to an array type/, error.message)

    error = assert_raises(Rubycc::CompileError) do
      compile("typedef int fn(int);\n_Atomic fn *p;\nint main(void) { return 0; }\n")
    end
    assert_match(/'_Atomic' cannot be applied to a function type/, error.message)
  end

  # "_Atomic" is a type specifier, so it excludes the others exactly as a struct
  # or enum specifier does; and on its own it names no type at all.
  def test_ill_formed_atomic_specifier_runs_are_diagnosed
    error = assert_raises(Rubycc::CompileError) do
      compile("int _Atomic(long) value;\nint main(void) { return 0; }\n")
    end
    assert_match(/two or more data types in declaration specifiers/, error.message)

    error = assert_raises(Rubycc::CompileError) do
      compile("_Atomic value;\nint main(void) { return 0; }\n")
    end
    assert_match(/expected type specifier/, error.message)
  end

  # The generic macros are the builtins underneath, so an operation the builtins
  # refuse is refused through the macro too, with the builtin's own diagnostic
  # naming the width. A narrow _Atomic object is therefore usable as an object
  # while any atomic operation on it is rejected -- not silently non-atomic.
  def test_atomic_operations_on_narrow_objects_keep_the_builtin_diagnostic
    error = assert_raises(Rubycc::CompileError) do
      compile(<<~C)
        #include <stdatomic.h>
        int main(void) { atomic_char narrow = 0; return atomic_load(&narrow); }
      C
    end
    assert_match(/'__atomic_load_n' supports atomic objects of 4 or 8 bytes only/, error.message)
    assert_match(/has width 1/, error.message)
  end

  # The macros must reach the same locked instructions the raw builtins do --
  # the point of routing them through the builtins rather than through plain
  # loads and stores. Atomicity is invisible to the single-threaded oracle
  # above, so it is asserted on the instruction stream, as TestAtomicBuiltins
  # does.
  def test_x86_64_generic_macros_emit_locked_instructions
    skip "objdump unavailable" unless tool?("objdump")

    listing = in_tmpdir do |dir|
      object_path = File.join(dir, "macros.o")
      compile_with_rubycc(GENERIC_MACROS_SOURCE, object_path)
      stdout, _stderr, status = Open3.capture3("objdump", "-d", object_path)
      raise "objdump failed" unless status.success?

      stdout
    end

    assert_match(/lock xadd/, listing, "atomic_fetch_add/sub must be a lock xadd")
    assert_match(/lock cmpxchg/, listing, "atomic_compare_exchange_* must be a lock cmpxchg")
    assert_match(/xchg\s+%e\w\w,\(%rax\)/, listing,
                 "atomic_store/atomic_exchange must be an xchg, not a plain mov")
    assert_match(/mfence/, listing, "atomic_thread_fence/atomic_signal_fence must emit a fence")
  end

  def test_aarch64_declaration_spellings_match_gcc
    assert_aarch64_matches_gcc(DECLARATION_SPELLINGS_SOURCE)
  end

  def test_aarch64_generic_macros_match_gcc
    assert_aarch64_matches_gcc(GENERIC_MACROS_SOURCE)
  end

  def test_aarch64_upb_shaped_program_matches_gcc
    assert_aarch64_matches_gcc(UPB_SHAPED_SOURCE)
  end

  private

  def compile(source)
    Rubycc::Compiler.new.compile(source, filename: "atomic_type.c")
  end

  def run_source(source, compiler)
    in_tmpdir do |dir|
      object_path = File.join(dir, "atomic_type.o")
      compile_source(source, object_path, compiler)
      link_and_run(object_path)
    end
  end

  # Builds `source` with both compilers, runs both and demands identical exit
  # status and output -- the same differential shape TestAtomicBuiltins uses.
  def assert_matches_gcc(source, name)
    rubycc_status, rubycc_out = run_source(source, :rubycc)
    gcc_status, gcc_out = run_source(source, :gcc)

    assert_equal 0, rubycc_status, "rubycc-built #{name} exited #{rubycc_status}"
    assert_equal gcc_status, rubycc_status, "#{name}: exit status differs from gcc"
    assert_equal gcc_out, rubycc_out, "#{name}: output differs from gcc"
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
