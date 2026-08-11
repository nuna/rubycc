# frozen_string_literal: true

require_relative "test_helper"

# Block-scope function declarations (C11 6.2.2p5): a declarator that builds a
# function type inside a block declares a *function*, not a local object. With
# no storage-class specifier or with `extern` the identifier has external
# linkage, so it names the same entity a file-scope declaration of that name
# would name, reserves no storage, and its calls resolve to an external symbol.
#
# CRuby's <ruby/ractor.h> writes exactly that -- rb_ractor_shareable_p()
# forward-declares rb_ractor_shareable_p_continue() from inside its own body --
# so a translation unit that reaches the header could not be compiled until this
# was modeled (Step 168). <ruby/ractor.h> itself is covered by TestRubySmoke;
# what is pinned here is the language rule, on both targets:
#
#   * the call is the same external call a file-scope prototype's would be,
#     whether the definition is in another translation unit or further down this
#     one (checked against gcc by running the linked program);
#   * the declaration costs no storage -- the emitted machine code for a
#     function is byte-for-byte what it is when the declaration sits at file
#     scope instead, so no stack slot is laid out for it;
#   * `static` on such a declaration is the 6.7.1p7 constraint violation, and a
#     function *definition* in a block (a GNU nested function) stays rejected.
class TestBlockScopeFunctionDecl < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # The definition lives in another translation unit, so nothing but the
  # block-scope declaration tells this unit that remote_add/remote_label exist.
  # Each call gets its own statement: two calls in one argument list would
  # compare rubycc's left-to-right evaluation order against gcc's right-to-left,
  # which C leaves unspecified.
  CROSS_UNIT_MAIN = <<~C
    #include <stdio.h>
    int main(void) {
      long remote_add(long, long);
      long total = 0;
      int i;
      const char *name;

      for (i = 0; i < 5; i++) {
        total = remote_add(total, i);
      }
      printf("total=%ld\\n", total);
      {
        extern const char *remote_label(void);
        name = remote_label();
        printf("label=%s\\n", name);
      }
      return (int)total;
    }
  C

  CROSS_UNIT_HELPER = <<~C
    long remote_add(long a, long b) { return a + b; }
    const char *remote_label(void) { return "remote"; }
  C

  # The definition is in this very file, *below* the block that declares it, so
  # the declaration is the only thing that makes the call compile at all.
  SAME_UNIT_SOURCE = <<~C
    #include <stdio.h>
    static int calls;

    int main(void) {
      int scale(int, int);
      int total = 0;
      int i;
      int indirect;

      for (i = 1; i <= 4; i++) {
        total += scale(i, 3);
      }
      printf("total=%d calls=%d\\n", total, calls);
      {
        /* Visible in the nested block too, and it decays to a pointer like any
           other function designator. */
        int (*through)(int, int) = scale;
        indirect = through(7, 6);
        printf("indirect=%d calls=%d\\n", indirect, calls);
      }
      return total - 30;
    }

    int scale(int value, int factor) { calls++; return value * factor; }
  C

  # The storage pair: two spellings of one program that must compile to the same
  # code for `probe`. The only difference is where `consume` is declared.
  FILE_SCOPE_PROTOTYPE_SOURCE = <<~C
    int consume(int);
    int probe(int x) {
      int a = x + 1;
      int b = a * 3;
      int c = a - b;
      return consume(a) + b + c;
    }
  C

  BLOCK_SCOPE_PROTOTYPE_SOURCE = <<~C
    int probe(int x) {
      int consume(int);
      int a = x + 1;
      int b = a * 3;
      int c = a - b;
      return consume(a) + b + c;
    }
  C

  # --- x86-64 execution ---------------------------------------------------

  def test_calls_a_definition_in_another_translation_unit
    skip_unless_x86_64_host

    rubycc = link_units_and_run([[CROSS_UNIT_MAIN, :rubycc], [CROSS_UNIT_HELPER, :gcc]])
    gcc = link_units_and_run([[CROSS_UNIT_MAIN, :gcc], [CROSS_UNIT_HELPER, :gcc]])

    assert_equal [10, "total=10\nlabel=remote\n"], gcc, "the gcc oracle itself must agree"
    assert_equal gcc, rubycc, "rubycc and gcc disagree on the cross-unit program"
  end

  def test_calls_a_definition_further_down_the_same_translation_unit
    skip_unless_x86_64_host

    rubycc = run_source(SAME_UNIT_SOURCE, :rubycc)
    gcc = run_source(SAME_UNIT_SOURCE, :gcc)

    assert_equal [0, "total=30 calls=4\nindirect=42 calls=5\n"], gcc,
                 "the gcc oracle itself must agree"
    assert_equal gcc, rubycc, "rubycc and gcc disagree on the same-unit program"
  end

  # --- no storage is consumed --------------------------------------------

  # The declaration must not be laid out as if it were a local: with it moved
  # from file scope into the block, `probe` has to keep exactly the frame (and
  # the rest of the code) it had, so the two objects' `probe` bytes are compared
  # directly. That is strictly stronger than reading the prologue's frame size
  # out of a disassembly, and it needs no external tool.
  def test_block_scope_declaration_costs_no_stack_slot_on_x86_64
    skip_unless_x86_64_host

    assert_equal function_code(FILE_SCOPE_PROTOTYPE_SOURCE, "probe"),
                 function_code(BLOCK_SCOPE_PROTOTYPE_SOURCE, "probe"),
                 "moving the prototype into the block changed probe's code"
  end

  def test_block_scope_declaration_costs_no_stack_slot_on_aarch64
    assert_equal function_code(FILE_SCOPE_PROTOTYPE_SOURCE, "probe", target: "aarch64"),
                 function_code(BLOCK_SCOPE_PROTOTYPE_SOURCE, "probe", target: "aarch64"),
                 "moving the prototype into the block changed probe's aarch64 code"
  end

  # The call is an external one: `consume` is an undefined symbol the linker
  # resolves, not something this unit defines or reserves space for.
  def test_the_declared_function_becomes_an_undefined_symbol
    object = Rubycc::ObjFile::ELFReader.read(compile(BLOCK_SCOPE_PROTOTYPE_SOURCE))
    consume = object.symbol("consume")

    refute_nil consume, "expected a symbol table entry for the block-declared function"
    assert consume.undefined?, "a block-scope declaration must not define the function"
    assert_equal :global, consume.bind, "external linkage means a global binding"
  end

  # --- diagnostics --------------------------------------------------------

  # 6.7.1p7: the only storage-class specifier a block-scope function declaration
  # may carry is `extern`.
  def test_static_on_a_block_scope_function_declaration_is_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("int main(void) { static int f(int); return 0; }")
    end
    assert_match(/invalid storage class for function 'f'/, error.description)
  end

  # A function type has no object to initialize (6.7.9p3).
  def test_an_initializer_on_a_block_scope_function_declaration_is_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("int main(void) { int f(int) = 3; return 0; }")
    end
    assert_match(/function 'f' is initialized like a variable/, error.description)
  end

  # A nested function *definition* is a GNU extension (it needs a trampoline to
  # reach the enclosing frame) and stays out of scope -- the regression guard
  # that supporting the declaration did not quietly admit the definition.
  def test_a_nested_function_definition_is_still_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("int main(void) { int f(int) { return 1; } return f(1); }")
    end
    assert_match(/nested function definitions are not supported/, error.description)
  end

  # The name is one external entity, so a file-scope declaration disagreeing
  # with the block-scope one is the ordinary redeclaration conflict -- caught by
  # the same check a pair of file-scope prototypes would meet.
  def test_a_conflicting_file_scope_declaration_is_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("int f(long); int main(void) { int f(int); return 0; }")
    end
    assert_match(/conflicting types for 'f'/, error.description)
  end

  def test_a_matching_file_scope_declaration_merges
    compile("int f(int); int main(void) { int f(int); return f(1); }")
    compile("int main(void) { int f(int); int f(int); return f(1); }")
  end

  # A local object of the same name in the same block is still the redeclaration
  # error it always was (gcc: "'f' redeclared as different kind of symbol").
  def test_a_local_object_of_the_same_name_is_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("int main(void) { int f; int f(int); return 0; }")
    end
    assert_match(/redeclaration of 'f'/, error.description)
  end

  # --- aarch64 execution --------------------------------------------------

  def test_aarch64_calls_a_definition_in_another_translation_unit
    skip_unless_aarch64_toolchain

    rubycc = link_units_and_run_aarch64([[CROSS_UNIT_MAIN, :rubycc], [CROSS_UNIT_HELPER, :gcc]])
    gcc = link_units_and_run_aarch64([[CROSS_UNIT_MAIN, :gcc], [CROSS_UNIT_HELPER, :gcc]])

    assert_equal [10, "total=10\nlabel=remote\n"], gcc, "the cross-gcc oracle itself must agree"
    assert_equal gcc, rubycc, "rubycc and the cross gcc disagree on the cross-unit program"
  end

  def test_aarch64_calls_a_definition_further_down_the_same_translation_unit
    assert_aarch64_matches_gcc(SAME_UNIT_SOURCE)
  end

  private

  def compile(source, target: nil)
    Rubycc::Compiler.new.compile(source, filename: "block_scope.c", **(target ? { target: target } : {}))
  end

  # The machine-code bytes of the named function in `source`, read out of the
  # emitted object's .text through rubycc's own ELF reader.
  def function_code(source, name, target: nil)
    object = Rubycc::ObjFile::ELFReader.read(compile(source, target: target))
    symbol = object.symbol(name)
    refute_nil symbol, "expected #{name} in the object's symbol table"
    symbol.section.data[symbol.value, symbol.size]
  end

  def run_source(source, compiler)
    in_tmpdir do |dir|
      object_path = File.join(dir, "block_scope.o")
      compile_source(source, object_path, compiler)
      link_and_run(object_path)
    end
  end
end
