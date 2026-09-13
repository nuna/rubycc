# frozen_string_literal: true

require_relative "test_helper"

# extern-initializer-file-scope: a file-scope "extern T x = init;" is an
# external *definition*, not a mere reference — the initializer is what makes
# it one (C11 6.9.2p1's own example: "extern int i3 = 3; // definition,
# external linkage"). rubycc formerly rejected the combination outright with
# "has both 'extern' and initializer"; real gems rely on the form (cool.io's
# bundled libev: "EV_API_DECL struct ev_loop *ev_default_loop_ptr = 0;" where
# EV_API_DECL expands to extern). Only at *block* scope does 6.7.9p5 make the
# combination a constraint violation.
class TestExternInitializerFileScope < Minitest::Test
  include ExecutionHelper

  # TU-A defines x via a file-scope "extern int x = 1;"; TU-B only ever sees an
  # ordinary "extern int x;" reference to it. Linking the two must produce the
  # same result whether both units are built by gcc or both by rubycc.
  DEFINING_UNIT = "extern int x = 1;\n"

  USING_UNIT = <<~C
    int printf(const char *, ...);
    extern int x;
    int main(void) {
      printf("%d\\n", x);
      return x;
    }
  C

  def test_file_scope_extern_with_initializer_matches_gcc_across_two_units
    oracle = link_units_and_run([[DEFINING_UNIT, :gcc], [USING_UNIT, :gcc]])
    actual = link_units_and_run([[DEFINING_UNIT, :rubycc], [USING_UNIT, :rubycc]])
    assert_equal oracle, actual
    assert_equal [1, "1\n"], actual # the oracle itself is meaningful
  end

  # The reference (rubycc) and the definition (gcc) must agree on the symbol
  # and its initial value even though only the definition carries "extern".
  def test_file_scope_extern_with_initializer_links_against_a_gcc_definition
    oracle = link_units_and_run([[DEFINING_UNIT, :gcc], [USING_UNIT, :gcc]])
    mixed = link_units_and_run([[DEFINING_UNIT, :gcc], [USING_UNIT, :rubycc]])
    assert_equal oracle, mixed
  end

  # The real-world shape from cool.io's bundled libev (ext/libev/ev.c:1845):
  # "EV_API_DECL struct ev_loop *ev_default_loop_ptr = 0;" where EV_API_DECL
  # (ev.h:203) expands to "extern". A pointer to an incomplete struct type
  # initialized to a null pointer constant.
  STRUCT_POINTER_DEFINING_UNIT = "struct s;\nextern struct s *p = 0;\n"

  STRUCT_POINTER_USING_UNIT = <<~C
    struct s;
    int printf(const char *, ...);
    extern struct s *p;
    int main(void) {
      printf("%d\\n", p == 0);
      return p == 0;
    }
  C

  def test_file_scope_extern_pointer_with_initializer_matches_gcc_across_two_units
    oracle = link_units_and_run([[STRUCT_POINTER_DEFINING_UNIT, :gcc], [STRUCT_POINTER_USING_UNIT, :gcc]])
    actual = link_units_and_run([[STRUCT_POINTER_DEFINING_UNIT, :rubycc], [STRUCT_POINTER_USING_UNIT, :rubycc]])
    assert_equal oracle, actual
    assert_equal [1, "1\n"], actual # the oracle itself is meaningful
  end

  def compile(source, filename: "foo.c")
    Rubycc::Compiler.new.compile(source, filename: filename, target: host_target)
  end

  # 6.7.9p5: at block scope, unlike file scope, "extern" with an initializer
  # is a constraint violation — the block cannot supply the storage the
  # initializer would fill.
  def test_block_scope_extern_with_initializer_is_still_rejected
    error = assert_raises(Rubycc::CompileError) do
      compile("void f(void) { extern int y = 1; }\nint main(void) { return 0; }")
    end
    assert_match(/'y' has both 'extern' and initializer/, error.description)
  end
end
