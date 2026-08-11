# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"

# Exercises the static-link core (Rubycc::Link::PartialLinker), an `ld -r`
# equivalent, and the general relocatable writer it emits through
# (Rubycc::ObjFile::RelocatableWriter).
#
# Four layers are covered: the writer round-trips through ELFReader (every
# piece it emits is read back and asserted); the merge is checked at the unit
# level on synthetic objects with known section sizes and relocations (offset
# padding, symbol shifting, the section-symbol addend fix-up, duplicate/weak
# resolution, archive lazy extraction, determinism); and the strong end-to-end
# path compiles real C, merges the objects, and hands the single result to gcc
# to link and run — asserting the same behavior as linking the originals. The
# external-tool cases (readelf, system ld) are skip-guarded so a bare host still
# runs the suite.
class TestLink < Minitest::Test
  include ExecutionHelper

  # The synthetic writer/linker fixtures below pin x86_64 ELF machine and
  # relocation numbers. They are an x86_64 target contract, not host-generic
  # language tests; the AArch64 linker/backend has its own target suite.
  def setup
    skip_unless_x86_64_host
  end

  Reader = Rubycc::ObjFile::ELFReader
  Writer = Rubycc::ObjFile::RelocatableWriter
  Linker = Rubycc::Link::PartialLinker

  # x86_64 relocation type numbers used by the synthetic objects below.
  R_X86_64_64    = 1
  R_X86_64_PC32  = 2
  R_X86_64_PLT32 = 4

  SHT_PROGBITS = 1
  SHT_NOBITS   = 8
  SHF_ALLOC     = 0x2
  SHF_WRITE     = 0x1
  SHF_EXECINSTR = 0x4

  # --- writer round-trip -------------------------------------------------

  def test_writer_round_trips_sections_symbols_and_relocations
    w = Writer.new
    text = w.add_section(name: ".text", type: SHT_PROGBITS, flags: SHF_ALLOC | SHF_EXECINSTR,
                         addralign: 16, data: ("\x90".b * 8))
    rodata = w.add_section(name: ".rodata", type: SHT_PROGBITS, flags: SHF_ALLOC,
                           addralign: 4, data: "hi\0".b)
    w.add_section(name: ".bss", type: SHT_NOBITS, flags: SHF_ALLOC | SHF_WRITE,
                  addralign: 8, size: 32)
    rodata_sym = w.add_symbol(name: nil, bind: :local, type: :section, section: rodata)
    w.add_symbol(name: "helper", bind: :local, type: :func, section: text, value: 4, size: 4)
    w.add_symbol(name: "main", bind: :global, type: :func, section: text, value: 0, size: 8)
    w.add_symbol(name: "printf", bind: :global, type: :notype)
    w.add_relocation(target: text, offset: 1, symbol: rodata_sym, type: R_X86_64_PC32, addend: -4)

    obj = w.to_binary
    r = Reader.read(obj)

    assert r.relocatable?
    assert_equal EM_X86_64_MACHINE, r.machine
    # Sections present with their attributes preserved.
    assert_equal 32, r.section(".bss").size
    assert r.section(".bss").nobits?
    assert_equal 16, r.section(".text").addralign
    assert_equal "hi\0".b, r.section(".rodata").data

    # Symbols: all locals precede globals (sh_info respected), values kept.
    helper = r.symbol("helper")
    assert_equal :local, helper.bind
    assert_equal 4, helper.value
    assert_equal :func, helper.type
    assert_equal :global, r.symbol("main").bind
    assert r.symbol("printf").undefined?

    # The single relocation reads back against the .rodata section symbol.
    reloc = r.relocations_for(".text").fetch(0)
    assert_equal 1, reloc.offset
    assert_equal :R_X86_64_PC32, reloc.type_name
    assert_equal(-4, reloc.addend)
    assert_equal :section, reloc.symbol.type
    assert_equal ".rodata", reloc.symbol.section.name
  end

  EM_X86_64_MACHINE = 62

  # --- section merging, symbol shifting, section-symbol addend -----------

  # Builds an object whose .text lands at a known offset in the merged .text,
  # exercising alignment padding, a shifted defined symbol, and the subtle
  # section-symbol addend fix-up all at once. Object one contributes a 5-byte
  # .text and a 4-byte .rodata; object two's 16-aligned .text therefore starts
  # at offset 16 and its .rodata piece at offset 4.
  def test_merge_pads_shifts_symbols_and_fixes_section_symbol_addend
    first = Writer.new
    first.add_section(name: ".text", type: SHT_PROGBITS, flags: SHF_ALLOC | SHF_EXECINSTR,
                      addralign: 1, data: ("\xCC".b * 5))
    first.add_section(name: ".rodata", type: SHT_PROGBITS, flags: SHF_ALLOC,
                      addralign: 1, data: "AAAA".b)

    second = Writer.new
    text2 = second.add_section(name: ".text", type: SHT_PROGBITS, flags: SHF_ALLOC | SHF_EXECINSTR,
                               addralign: 16, data: ("\x90".b * 8))
    rodata2 = second.add_section(name: ".rodata", type: SHT_PROGBITS, flags: SHF_ALLOC,
                                 addralign: 1, data: "hello\0".b)
    rodata2_sym = second.add_symbol(name: nil, bind: :local, type: :section, section: rodata2)
    second.add_symbol(name: "f", bind: :global, type: :func, section: text2, value: 2, size: 4)
    # A PC32 reference to the .rodata section symbol with addend 0 (points at
    # "hello", at offset 0 of *this* object's .rodata piece).
    second.add_relocation(target: text2, offset: 0, symbol: rodata2_sym,
                          type: R_X86_64_PC32, addend: 0)

    merged = Reader.read(Linker.link([first.to_binary, second.to_binary]))

    # .text: object one at 0 (5 bytes), padded to 16, object two 8 bytes => 24.
    assert_equal 16, merged.section(".text").addralign
    assert_equal 24, merged.section(".text").size
    # .rodata: "AAAA" then "hello\0" contiguously (align 1).
    assert_equal "AAAAhello\0".b, merged.section(".rodata").data

    # The defined symbol f shifted by object two's .text placement (16) + 2.
    assert_equal 18, merged.symbol("f").value

    # The section-symbol relocation: offset shifted by 16, and — the subtle part
    # — addend bumped from 0 to 4 (object one's .rodata occupies the first 4
    # bytes, so "hello" now lives at merged .rodata offset 4).
    reloc = merged.relocations_for(".text").fetch(0)
    assert_equal 16, reloc.offset
    assert_equal :section, reloc.symbol.type
    assert_equal ".rodata", reloc.symbol.section.name
    assert_equal 4, reloc.addend
  end

  def test_merge_combines_bss_by_size_and_alignment
    a = Writer.new
    a.add_section(name: ".bss", type: SHT_NOBITS, flags: SHF_ALLOC | SHF_WRITE,
                  addralign: 4, size: 6)
    b = Writer.new
    b.add_section(name: ".bss", type: SHT_NOBITS, flags: SHF_ALLOC | SHF_WRITE,
                  addralign: 16, size: 8)

    merged = Reader.read(Linker.link([a.to_binary, b.to_binary]))
    bss = merged.section(".bss")
    assert bss.nobits?
    assert_equal 16, bss.addralign
    # 6, padded up to the 16-aligned start of b's piece, then + 8 => 24.
    assert_equal 24, bss.size
  end

  # --- symbol resolution rules -------------------------------------------

  # A minimal object defining a single global symbol in .text, optionally weak.
  def object_defining(name, weak: false)
    w = Writer.new
    text = w.add_section(name: ".text", type: SHT_PROGBITS, flags: SHF_ALLOC | SHF_EXECINSTR,
                         addralign: 1, data: ("\xC3".b))
    w.add_symbol(name: name, bind: weak ? :weak : :global, type: :func, section: text, size: 1)
    w.to_binary
  end

  def test_duplicate_strong_definition_is_an_error
    error = assert_raises(Rubycc::Link::LinkError) do
      Linker.link([object_defining("dup"), object_defining("dup")])
    end
    assert_match(/multiple definition of 'dup'/, error.message)
  end

  def test_strong_definition_beats_weak_regardless_of_order
    # weak then strong, and strong then weak, both resolve to the strong entry
    # without error.
    [[object_defining("x", weak: true), object_defining("x")],
     [object_defining("x"), object_defining("x", weak: true)]].each do |inputs|
      merged = Reader.read(Linker.link(inputs))
      sym = merged.symbol("x")
      assert_equal :global, sym.bind
      assert sym.defined?
    end
  end

  def test_two_weak_definitions_keep_the_first
    merged = Reader.read(Linker.link([object_defining("w", weak: true),
                                      object_defining("w", weak: true)]))
    assert_equal :weak, merged.symbol("w").bind
  end

  def test_undefined_reference_stays_und_in_partial_output
    w = Writer.new
    text = w.add_section(name: ".text", type: SHT_PROGBITS, flags: SHF_ALLOC | SHF_EXECINSTR,
                         addralign: 1, data: ("\xE8\x00\x00\x00\x00".b))
    ext = w.add_symbol(name: "external", bind: :global, type: :notype)
    w.add_symbol(name: "caller", bind: :global, type: :func, section: text, size: 5)
    w.add_relocation(target: text, offset: 1, symbol: ext, type: R_X86_64_PLT32, addend: -4)

    merged = Reader.read(Linker.link([w.to_binary]))
    # An unresolved symbol is legal for ld -r output — it stays undefined.
    assert merged.symbol("external").undefined?
    assert_equal :R_X86_64_PLT32, merged.relocations_for(".text").fetch(0).type_name
  end

  # --- archive lazy extraction -------------------------------------------

  def compile(src, name)
    Rubycc::Compiler.new.compile(src, filename: name, target: host_target)
  end

  # Builds an ar archive from [name, bytes] members.
  def archive_of(members)
    w = Rubycc::ObjFile::ArWriter.new
    members.each { |name, bytes| w.add_member(name, bytes) }
    w.to_binary
  end

  def test_archive_pulls_only_needed_members_to_a_fixpoint
    # foo() calls bar(); bar() is a leaf; baz() is unreferenced. main references
    # only foo, so the linker must pull foo (for main) then bar (for foo) and
    # leave baz out entirely.
    main = compile("int foo(void); int main(void) { return foo(); }", "main.c")
    foo  = compile("int bar(void); int foo(void) { return bar(); }", "foo.c")
    bar  = compile("int bar(void) { return 7; }", "bar.c")
    baz  = compile("int baz(void) { return 9; }", "baz.c")
    archive = archive_of([["foo.o", foo], ["bar.o", bar], ["baz.o", baz]])

    merged = Reader.read(Linker.link([main, archive]))
    names = merged.symbols.select { |s| s.bind == :global && s.defined? }.map(&:name)

    assert_includes names, "foo"
    assert_includes names, "bar" # pulled transitively through foo (fixpoint)
    refute_includes names, "baz" # never referenced, so never extracted
  end

  def test_archive_member_absent_when_symbol_already_defined
    # main defines its own `dup`; the archive's `dup` must not be pulled, and no
    # multiple-definition error must fire (the member is simply never loaded).
    main = compile("int dup(void) { return 1; } int main(void) { return dup(); }", "main.c")
    other = compile("int dup(void) { return 2; }", "other.c")
    archive = archive_of([["other.o", other]])

    merged = Reader.read(Linker.link([main, archive]))
    dups = merged.symbols.select { |s| s.name == "dup" }
    assert_equal 1, dups.size
  end

  # --- determinism -------------------------------------------------------

  def test_output_is_byte_identical_for_identical_inputs
    a = compile("int shared; int add(int x, int y) { return x + y; }", "a.c")
    b = compile("int add(int, int); int use(int n) { return add(n, 1); }", "b.c")
    assert_equal Linker.link([a, b]), Linker.link([a, b])
  end

  # --- end-to-end: merge with rubycc, link with gcc, run -----------------

  # Compiles each source with the given compiler, merges the objects with the
  # ld -r core, links the single result with gcc, and returns [exit, stdout].
  def merge_compile_link_run(sources, compiler: :rubycc)
    in_tmpdir do |dir|
      objects = sources.each_with_index.map do |src, i|
        path = File.join(dir, "u#{i}.o")
        compile_source(src, path, compiler)
        path
      end
      merged = File.join(dir, "merged.o")
      Linker.link_to(objects, merged)
      run_linked(dir, merged)
    end
  end

  # gcc-links a single object and runs it, returning [exit, stdout].
  def run_linked(dir, object_path)
    exe = File.join(dir, "exe.out")
    # compile_with_gcc uses -fno-pie for its non-PIC oracle object. Keep the
    # final link in the same ordinary non-PIE mode; otherwise Debian gcc's
    # default PIE link rejects the merged R_X86_64_32 relocations.
    out, status = Open3.capture2e("gcc", "-no-pie", "-o", exe, object_path)
    raise "gcc failed to link merged object:\n#{out}" unless status.success?

    stdout, run_status = Open3.capture2(exe)
    [run_status.exitstatus, stdout]
  end

  # Cross-TU function call (PLT32), cross-TU global read (PC32), a string
  # literal (section-symbol reloc) and a .bss global, all in one program.
  MAIN_SRC = <<~C
    int printf(const char *, ...);
    extern int counter;
    extern char scratch[8];
    int add(int, int);
    int main(void) {
      scratch[0] = 65;
      printf("%d %d %c\\n", add(2, 3), counter, scratch[0]);
      return add(counter, 10);
    }
  C
  LIB_SRC = <<~C
    int counter = 30;
    char scratch[8];
    int add(int x, int y) { return x + y; }
  C

  def test_end_to_end_cross_tu_calls_globals_rodata_and_bss
    status, stdout = merge_compile_link_run([MAIN_SRC, LIB_SRC])
    assert_equal 40, status # add(counter=30, 10)
    assert_equal "5 30 A\n", stdout
  end

  def test_end_to_end_matches_linking_originals_separately
    # The whole point of ld -r: the merged object must behave identically to
    # linking the two objects straight into the executable.
    merged_status, merged_stdout = merge_compile_link_run([MAIN_SRC, LIB_SRC])
    direct_status, direct_stdout = link_units_and_run([[MAIN_SRC, :rubycc], [LIB_SRC, :rubycc]])
    assert_equal direct_status, merged_status
    assert_equal direct_stdout, merged_stdout
  end

  def test_end_to_end_three_translation_units
    a = "int b(void); int c(void); int main(void) { return b() + c(); }"
    b = "int c(void); int b(void) { return 10 + c(); }"
    c = "int c(void) { return 5; }"
    status, = merge_compile_link_run([a, b, c])
    assert_equal 20, status # b()=15, c()=5
  end

  def test_end_to_end_merges_gcc_compiled_objects
    skip "gcc unavailable" unless gcc_available?

    status, stdout = merge_compile_link_run([MAIN_SRC, LIB_SRC], compiler: :gcc)
    assert_equal 40, status
    assert_equal "5 30 A\n", stdout
  end

  # --- external-tool validation ------------------------------------------

  def test_readelf_parses_the_merged_object
    skip "readelf unavailable" unless readelf_available?

    a = compile(MAIN_SRC, "a.c")
    b = compile(LIB_SRC, "b.c")
    in_tmpdir do |dir|
      merged = File.join(dir, "merged.o")
      Linker.link_to([make_object_file(dir, "a.o", a), make_object_file(dir, "b.o", b)], merged)
      %w[-r -s -S].each do |flag|
        out, status = Open3.capture2e("readelf", flag, merged)
        assert status.success?, "readelf #{flag} rejected the merged object:\n#{out}"
        refute_match(/Error|Warning/, out, "readelf #{flag} complained:\n#{out}")
      end
    end
  end

  def test_matches_system_ld_r_symbol_resolution
    skip "ld unavailable" unless ld_available?

    a = compile(MAIN_SRC, "a.c")
    b = compile(LIB_SRC, "b.c")
    in_tmpdir do |dir|
      pa = make_object_file(dir, "a.o", a)
      pb = make_object_file(dir, "b.o", b)
      ours = File.join(dir, "ours.o")
      Linker.link_to([pa, pb], ours)

      theirs = File.join(dir, "theirs.o")
      out, status = Open3.capture2e("ld", "-r", "-o", theirs, pa, pb)
      skip "system ld -r failed:\n#{out}" unless status.success?

      # Compare symbol resolution outcomes (name -> defined?), not bytes.
      assert_equal global_resolution(Reader.read_file(theirs)),
                   global_resolution(Reader.read_file(ours))
    end
  end

  private

  def make_object_file(dir, name, bytes)
    path = File.join(dir, name)
    File.binwrite(path, bytes)
    path
  end

  # name -> defined? for every named global/weak symbol, the outcome an ld -r
  # link must agree on regardless of byte layout.
  def global_resolution(reader)
    reader.symbols.each_with_object({}) do |sym, map|
      next unless sym.bind == :global || sym.bind == :weak
      next if sym.name.to_s.empty?

      map[sym.name] = sym.defined?
    end
  end

  def gcc_available?
    @gcc_available ||= tool_available?("gcc")
  end

  def readelf_available?
    @readelf_available ||= tool_available?("readelf")
  end

  def ld_available?
    @ld_available ||= tool_available?("ld")
  end

  def tool_available?(tool)
    system(tool, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
