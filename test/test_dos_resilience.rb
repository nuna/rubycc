# frozen_string_literal: true

require_relative "test_helper"

# Step 32: proves the toolchain fails safe on hostile input (a C source, a
# preprocessing directive, or an ELF/ar object crafted to exhaust CPU, memory
# or the Ruby machine stack). The contract under test is that each such input is
# rejected with an ordinary, located error — a Rubycc::CompileError or an
# ObjFile format error — rather than a bare SystemStackError, a runaway loop, or
# an out-of-memory crash. Because assert_raises requires the *specific* error
# class, a SystemStackError leaking through would fail the test rather than pass
# it, which is exactly the regression these tests guard against.
#
# Alongside the rejections, each section re-checks that an input which is deep
# but still within the limits (and every ordinary program) keeps compiling, so
# the guards cannot be blamed for a false positive on legitimate code.
class TestDosResilience < Minitest::Test
  Compiler = Rubycc::Compiler
  Preprocessor = Rubycc::Preprocess::Preprocessor
  CompileError = Rubycc::CompileError

  def compile(source, filename: "dos.c")
    Compiler.new.compile(source, filename: filename)
  end

  def preprocess(source, filename: "dos.c")
    Preprocessor.new.run(source, filename: filename)
  end

  # A depth comfortably past every parser limit, so the guard is certain to trip
  # regardless of a construct's per-level counter multiplier.
  DEEP = 40_000

  # --- parser recursion guard (front/parser.rb) --------------------------------

  def test_deeply_nested_parentheses_expression_is_rejected
    source = "int main(void) { return #{"(" * DEEP}1#{")" * DEEP}; }"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_unary_chain_is_rejected
    source = "int main(void) { return #{"!" * DEEP}1; }"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_ternary_chain_is_rejected
    source = "int main(void) { return #{"1?1:" * DEEP}1; }"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_assignment_chain_is_rejected
    source = "int main(void) { int a; #{"a=" * DEEP}1; }"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_sizeof_chain_is_rejected
    source = "int main(void) { return #{"sizeof " * DEEP}1; }"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_initializer_list_is_rejected
    source = "int a = #{"{" * DEEP}1#{"}" * DEEP};"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_compound_statements_are_rejected
    source = "int main(void) { #{"{" * DEEP}1;#{"}" * DEEP} }"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_statement_expressions_are_rejected
    source = "int main(void) { return #{"({" * DEEP}1;#{"})" * DEEP}; }"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_declarator_parentheses_are_rejected
    source = "int #{"(" * DEEP}x#{")" * DEEP};"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_struct_definitions_are_rejected
    source = "#{"struct{" * DEEP}int a;#{"}a;" * DEEP}"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  # The diagnostic still carries a real source location (N3), not a bare crash.
  def test_nesting_diagnostic_is_located
    source = "int main(void) { return #{"(" * DEEP}1#{")" * DEEP}; }"
    error = assert_raises(CompileError) { compile(source) }
    assert_equal "dos.c", error.filename
    assert_equal 1, error.line
    assert error.column.positive?
    refute_nil error.source_line
  end

  # A genuinely deep but in-limit program (63 nested parentheses — C11
  # §5.2.4.1's implementation minimum — and 100 nested blocks) still compiles,
  # proving the limit does not reject conforming input.
  def test_nesting_within_the_limit_still_compiles
    parens = "int main(void) { return #{"(" * 63}1#{")" * 63}; }"
    refute_empty compile(parens)

    blocks = "int main(void) { #{"{" * 100}1;#{"}" * 100} }"
    refute_empty compile(blocks)
  end

  # --- #if expression guard (preprocess/constant_expression.rb) ----------------

  def test_deeply_nested_if_expression_parentheses_are_rejected
    source = "#if #{"(" * DEEP}1#{")" * DEEP}\n#endif\n"
    error = assert_raises(CompileError) { preprocess(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_if_expression_unary_chain_is_rejected
    source = "#if #{"!" * DEEP}1\n#endif\n"
    error = assert_raises(CompileError) { preprocess(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_if_expression_within_the_limit_still_evaluates
    source = "#if #{"(" * 63}1#{")" * 63}\nint ok;\n#endif\n"
    refute_empty preprocess(source)
  end

  # --- macro expansion budget and nesting caps (preprocess/preprocessor.rb) ----

  # A doubling macro (B21 expands to 2^21 tokens) blows the expansion budget and
  # is cut off with a located error, quickly (the budget also caps the worst-case
  # work), instead of exhausting CPU and memory.
  def test_exponentially_expanding_macro_is_rejected
    defs = (1..21).map do |i|
      i == 1 ? "#define B1 B0 B0" : "#define B#{i} B#{i - 1} B#{i - 1}"
    end.join("\n")
    source = "#define B0 x\n#{defs}\nint a = B21;\n"

    started = Time.now
    error = assert_raises(CompileError) { preprocess(source) }
    assert_match(/macro expansion is too large/, error.description)
    # The cut-off must be prompt: the budget bounds the work, so this is seconds,
    # not the minutes an unbounded 2^21 expansion would take.
    assert_operator Time.now - started, :<, 20, "runaway macro was not cut off promptly"
  end

  def test_deeply_nested_conditional_directives_are_rejected
    source = ("#if 1\n" * 1000) + "int a;\n" + ("#endif\n" * 1000)
    error = assert_raises(CompileError) { preprocess(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_macro_argument_parentheses_are_rejected
    source = "#define M(x) x\nint a = M(#{"(" * DEEP}1#{")" * DEEP});\n"
    error = assert_raises(CompileError) { preprocess(source) }
    assert_match(/nested too deeply/, error.description)
  end

  # An ordinary macro and a modestly nested conditional tower are untouched.
  def test_ordinary_macros_still_expand
    source = "#define ADD(a, b) ((a) + (b))\n#define TWO ADD(1, 1)\nint x = TWO;\n"
    refute_empty preprocess(source)
  end

  # --- ELF / ar count sanity checks (objfile/*) --------------------------------

  Reader = Rubycc::ObjFile::ELFReader
  Writer = Rubycc::ObjFile::ELFWriter
  ELFFormatError = Rubycc::ObjFile::ELFFormatError

  # A minimal valid relocatable object to corrupt: a file symbol and a two-byte
  # .text section is enough to have a real section header table to overrun.
  def valid_object
    writer = Writer.new
    writer.add_file_symbol("dos.c")
    writer.add_text_section("\x90\xc3".b) # nop; ret
    writer.to_binary.dup
  end

  def test_huge_section_count_via_shnum_zero_escape_hatch_is_rejected
    bytes = valid_object
    shoff = bytes[40, 8].unpack1("Q<")
    # e_shnum == 0 makes the reader take the count from the zeroth section's
    # 64-bit sh_size; set that enormous so the count could not fit the file.
    bytes[60, 2] = [0].pack("S<")
    bytes[shoff + 32, 8] = [0xFFFF_FFFF_FFFF].pack("Q<")

    error = assert_raises(ELFFormatError) { Reader.read(bytes) }
    assert_match(/section header table/, error.message)
  end

  def test_huge_section_count_via_shnum_field_is_rejected
    bytes = valid_object
    bytes[60, 2] = [0xFF00].pack("S<") # e_shnum far beyond what the file holds
    assert_raises(ELFFormatError) { Reader.read(bytes) }
  end

  # The valid object still reads back cleanly (the guard is not over-eager).
  def test_valid_object_still_reads
    reader = Reader.read(valid_object)
    assert reader.relocatable?
    refute_empty reader.sections
  end
end
