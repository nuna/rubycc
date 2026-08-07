# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"

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
#
# Step 120 adds the three algorithmic-complexity cases, where nothing is
# rejected and nothing crashes — the input is perfectly legal, it just used to
# cost quadratic or exponential work. Those are pinned by a wall-clock bound,
# chosen with a wide margin over the fixed implementation (and far under what
# the old one needed) so the assertion means "still not quadratic" rather than
# "this machine is fast".
class TestDosResilience < Minitest::Test
  Compiler = Rubycc::Compiler
  Preprocessor = Rubycc::Preprocess::Preprocessor
  CompileError = Rubycc::CompileError

  # The native AArch64 acceptance job runs this Ruby process under QEMU. Keep
  # the limits finite and meaningful there, but account for the measured
  # emulation overhead without weakening the default host-side checks.
  DOS_PERFORMANCE_FACTOR = Integer(ENV.fetch("RUBYCC_DOS_PERFORMANCE_FACTOR", "1"), 10)
  raise ArgumentError, "RUBYCC_DOS_PERFORMANCE_FACTOR must be positive" unless DOS_PERFORMANCE_FACTOR.positive?

  def dos_time_limit(seconds)
    seconds * DOS_PERFORMANCE_FACTOR
  end

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

  # An unbraced control-flow body ("if(1)if(1)...;" with no "{") recurses
  # straight back into #parse_statement rather than through any of the guarded
  # entry points above, so it needs its own coverage (Step 118): without a
  # guard on that path the chain would overflow the Ruby stack with a bare
  # SystemStackError rather than fail with a CompileError.
  def test_deeply_nested_unbraced_if_chain_is_rejected
    source = "int main(void) { #{"if(1)" * DEEP}return 1; }"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_unbraced_while_chain_is_rejected
    source = "int main(void) { #{"while(1)" * DEEP}return 1; }"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_deeply_nested_unbraced_for_chain_is_rejected
    source = "int main(void) { #{"for(;;)" * DEEP}return 1; }"
    error = assert_raises(CompileError) { compile(source) }
    assert_match(/nested too deeply/, error.description)
  end

  def test_unbraced_if_chain_within_the_limit_still_compiles
    source = "int main(void) { #{"if(1)" * 100}return 1; }"
    refute_empty compile(source)
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
    assert_operator Time.now - started, :<, dos_time_limit(20), "runaway macro was not cut off promptly"
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

  # --- rmake variable expansion budget (rmake/expander.rb) ---------------------

  Rmake = Rubycc::Rmake
  ExpansionError = Rmake::ExpansionError

  # A doubling chain `A0 = <leaf>` / `Ai = $(Ai-1)$(Ai-1)`: only `levels` deep,
  # so the 200-level depth cap never sees it, yet 2^levels wide. `op` picks the
  # assignment flavour — `=` defers the blow-up to the first reference, `:=`
  # detonates during the parse itself.
  def doubling_makefile(levels, op: "=", leaf: "x")
    lines = ["A0 #{op} #{leaf}"]
    (1..levels).each { |i| lines << "A#{i} #{op} $(A#{i - 1})$(A#{i - 1})" }
    "#{lines.join("\n")}\n"
  end

  # The text budget: a doubling chain over a kilobyte-sized leaf outruns the
  # character cap long before the reference cap — few dereferences, terabytes of
  # text — so this is the case only MAX_EXPANSION_OUTPUT can see.
  def test_exponentially_expanding_make_variable_is_rejected
    makefile = Rmake::Makefile.parse(doubling_makefile(30, leaf: "x" * 8192))
    started = Time.now
    error = assert_raises(ExpansionError) { makefile.variable_value("A30") }
    assert_match(/produced more than \d+ characters/, error.message)
    assert_operator Time.now - started, :<, dos_time_limit(5), "runaway variable expansion was not cut off promptly"
  end

  # The reference budget: the same chain over an EMPTY leaf produces no text at
  # all, so only the count of dereferences can see the 2^30 calls. The cut-off
  # has to be *fast*, not merely finite — one budget is spent per top-level
  # expansion, so a Makefile full of `:=` assignments pays this cost once each.
  # Reaching the 100_000-reference cap measures well under a second, so the
  # bound below leaves an order of magnitude of slack and still fails outright
  # if the budget stops bounding the work.
  def test_exponentially_expanding_make_variable_with_empty_leaf_is_rejected
    makefile = Rmake::Makefile.parse(doubling_makefile(30, leaf: ""))
    started = Time.now
    error = assert_raises(ExpansionError) { makefile.variable_value("A30") }
    assert_match(/resolved more than \d+ references/, error.message)
    assert_operator Time.now - started, :<, 5, "runaway variable expansion was not cut off promptly"
  end

  # A `:=` assignment expands as it is parsed, so this one never even reaches a
  # target: the parser itself has to stop.
  def test_exponentially_expanding_simple_assignment_is_rejected_at_parse_time
    started = Time.now
    assert_raises(ExpansionError) { Rmake::Makefile.parse(doubling_makefile(30, op: ":=")) }
    assert_operator Time.now - started, :<, 15, "runaway variable expansion was not cut off promptly"
  end

  # A cycle is still caught by the depth cap, which the work budgets do not
  # replace.
  def test_cyclic_make_variables_are_still_rejected
    makefile = Rmake::Makefile.parse("A = $(B)\nB = $(A)\n")
    error = assert_raises(ExpansionError) { makefile.variable_value("A") }
    assert_match(/levels/, error.message)
  end

  # Ordinary nesting — a chain of references, a substitution reference, and a
  # doubling chain that stays small — expands exactly as before.
  def test_nested_make_variables_within_the_budget_still_expand
    makefile = Rmake::Makefile.parse(doubling_makefile(10))
    assert_equal "x" * 1024, makefile.variable_value("A10")

    chained = Rmake::Makefile.parse(<<~MAKE)
      prefix = /usr
      includedir = $(prefix)/include
      hdrdir = $(includedir)/ruby
      srcs = a.c b.c
      objs = $(srcs:.c=.o)
    MAKE
    assert_equal "/usr/include/ruby", chained.variable_value("hdrdir")
    assert_equal "a.o b.o", chained.variable_value("objs")
  end

  # --- scanner column counting (preprocess/scanner.rb) -------------------------

  Scanner = Rubycc::Preprocess::Scanner

  # A single non-ASCII character anywhere in the file switches the scanner off
  # its byte-arithmetic column fast path for the WHOLE file; every column then
  # has to be counted in characters. Counting each one from the line start makes
  # one long line cost O(tokens x line length), so a file that is 1 MB on a
  # single line took over ten seconds for want of an incremental cursor.
  def test_long_line_in_a_non_ascii_file_scans_in_linear_time
    source = +"// あ\n"
    30_000.times { source << ("a" * 40) << " + " }
    source << "1;\n"

    started = Time.now
    tokens = Scanner.new(source, filename: "dos.c").scan
    elapsed = Time.now - started

    assert_equal 60_005, tokens.size
    assert_operator elapsed, :<, 5, "column counting is not linear in line length"
  end

  # ...and the columns it reports are the physical ones (N3): every token's
  # [line, column] must index that token's own spelling in the source line.
  # Multibyte characters count as one column each, before and after a block
  # comment, a spliced line and a multibyte string literal.
  def test_columns_stay_correct_in_a_non_ascii_file
    source = "// あ\nint éx = 1; /* あ\n */ int y; \\\nint z;\nchar *s = \"ああ\"; int w;\n"
    lines = source.split("\n", -1)
    tokens = Scanner.new(source, filename: "dos.c").scan
                    .reject { |t| t.type == :eof || t.type == :newline }

    refute_empty tokens
    tokens.each do |t|
      assert_equal t.text, lines[t.line - 1][t.column - 1, t.text.length],
                   "token #{t.text.inspect} is not at #{t.line}:#{t.column}"
    end
  end

  # --- archive extraction (link/partial_linker.rb) -----------------------------

  Linker = Rubycc::Link::PartialLinker
  RelWriter = Rubycc::ObjFile::RelocatableWriter

  SHT_PROGBITS  = 1
  SHF_ALLOC     = 0x2
  SHF_EXECINSTR = 0x4

  # A one-instruction object defining `defs` and referencing `refs`.
  def tiny_object(defs, refs)
    w = RelWriter.new
    text = w.add_section(name: ".text", type: SHT_PROGBITS, flags: SHF_ALLOC | SHF_EXECINSTR,
                         addralign: 1, data: "\xC3".b)
    refs.each { |name| w.add_symbol(name: name, bind: :global, type: :notype) }
    defs.each { |name| w.add_symbol(name: name, bind: :global, type: :func, section: text, size: 1) }
    w.to_binary
  end

  # An archive whose members form a chain — member i defines s<i> and needs
  # s<i-1> — laid out so each member's dependency sits BEFORE it. An archive is
  # scanned in member order, so a fixpoint that rescans every member after each
  # pull resolves exactly one member per pass: O(members^2), with the member
  # order (and therefore the cost) chosen by whoever built the archive.
  CHAIN_MEMBERS = 3000

  def test_reverse_ordered_archive_chain_links_in_linear_time
    w = Rubycc::ObjFile::ArWriter.new
    CHAIN_MEMBERS.times do |i|
      w.add_member("m#{i}.o", tiny_object(["s#{i}"], i.zero? ? [] : ["s#{i - 1}"]))
    end
    archive = w.to_binary
    main = tiny_object(["main"], ["s#{CHAIN_MEMBERS - 1}"])

    started = Time.now
    merged = Reader.read(Linker.link([main, archive]))
    elapsed = Time.now - started

    # The whole chain is pulled — the speed-up must not cost coverage.
    defined_names = merged.symbols.select { |s| s.bind == :global && s.defined? }.map(&:name)
    assert_equal CHAIN_MEMBERS + 1, defined_names.size
    assert_includes defined_names, "s0"
    assert_includes defined_names, "s#{CHAIN_MEMBERS - 1}"
    assert_operator elapsed, :<, dos_time_limit(5), "archive extraction is not linear in member count"
  end

  # The pull order is what fixes the merged section and symbol order, so N4
  # (identical inputs, byte-identical output) depends on it staying stable.
  def test_archive_extraction_stays_deterministic
    w = Rubycc::ObjFile::ArWriter.new
    10.times do |i|
      w.add_member("m#{i}.o", tiny_object(["s#{i}"], i.zero? ? [] : ["s#{i - 1}"]))
    end
    archive = w.to_binary
    main = tiny_object(["main"], ["s9"])

    assert_equal Linker.link([main, archive]), Linker.link([main, archive])
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
