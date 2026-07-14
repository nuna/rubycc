# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"
require "fiddle"
require "set"

# Exercises the shared-object writer (Rubycc::Link::SharedLinker), the first
# stage of the final-link core: it turns rubycc-compiled -fPIC relocatable
# objects into a self-contained ET_DYN (.so) that a runtime loader can dlopen.
#
# Four layers are covered: the emitted image is read back through the project's
# own ELFReader and its structure asserted (ET_DYN, the exported .dynsym, a
# valid SysV .hash, the .dynamic array, the R_X86_64_RELATIVE entries), the
# program headers are parsed directly and their load permissions and the
# p_vaddr ≡ p_offset (mod page) invariant checked; output is asserted
# deterministic; and — the real acceptance — self-contained C is compiled,
# linked into a .so and dlopened through Fiddle so each exported function is
# actually called and its return value compared. The external-tool cases
# (readelf, eu-elflint, gcc -shared interop) are skip-guarded.
class TestSharedObject < Minitest::Test
  Reader = Rubycc::ObjFile::ELFReader
  Linker = Rubycc::Link::SharedLinker

  PAGE = 0x1000
  EM_X86_64_MACHINE = 62

  # Program header types / permission flags and the .so section constants the
  # assertions below reference by name.
  PT_LOAD      = 1
  PT_DYNAMIC   = 2
  PT_GNU_STACK = 0x6474E551
  PF_X = 0x1
  PF_W = 0x2
  PF_R = 0x4

  R_X86_64_RELATIVE = 8
  STN_UNDEF = 0

  # A self-contained translation unit exercising every relocation the first
  # stage applies within one object: an internal call (PLT32), an internal
  # static helper (PLT32), an internal global read/write (PC32), and a string
  # literal returned by address (PC32 into .rodata).
  SELF_CONTAINED = <<~C
    int add3(int a, int b, int c) { return a + b + c; }
    static int dbl(int x) { return x * 2; }
    int quad(int x) { return dbl(dbl(x)); }
    int counter = 41;
    int get_counter(void) { return counter; }
    void set_counter(int v) { counter = v; }
    char *greeting(void) { return "hello"; }
  C

  # Two units whose merge keeps GOT-relative relocations against symbols that
  # become internal (access.c reaches shared_counter and bump through the GOT
  # because they are extern at compile time) and whose defining unit adds a
  # file-scope pointer initializer that lands an R_X86_64_64 in .data.
  ACCESS = <<~C
    extern int shared_counter;
    extern int bump(int by);
    typedef int (*fn)(int);
    int read_counter(void) { return shared_counter; }
    void write_counter(int v) { shared_counter = v; }
    int call_via_ptr(int x) { fn f = bump; return f(x); }
  C
  DEFINE = <<~C
    int shared_counter = 100;
    int bump(int by) { return by + 1; }
    char *stored = "world";
    char *stored_message(void) { return stored; }
  C

  # --- structural round-trip ---------------------------------------------

  def test_emits_et_dyn_read_by_our_reader
    r = Reader.read(build_so([SELF_CONTAINED]))
    assert r.shared_object?, "output must be ET_DYN"
    assert_equal EM_X86_64_MACHINE, r.machine
    assert_equal 0, r.entry, "a shared object has no entry point"
  end

  def test_exports_every_defined_global_in_dynsym
    r = Reader.read(build_so([SELF_CONTAINED]))
    exported = r.dynamic_symbols.reject { |s| s.name.to_s.empty? }.map(&:name).sort
    assert_equal %w[add3 counter get_counter greeting quad set_counter], exported

    add3 = r.dynamic_symbol("add3")
    assert_equal :func, add3.type
    assert add3.defined?, "add3 must resolve to its defining section"
    assert_equal :object, r.dynamic_symbol("counter").type
    # st_value is the load-time virtual address, matching the section it lives in.
    counter = r.dynamic_symbol("counter")
    assert_equal r.section(".data").addr, counter.value
  end

  def test_hidden_static_helper_is_not_exported
    r = Reader.read(build_so([SELF_CONTAINED]))
    assert_nil r.dynamic_symbol("dbl"), "a static function must not be exported"
  end

  # The SysV hash must locate every exported symbol: hashing its name, indexing
  # the bucket, and walking the chain must arrive at its own .dynsym entry.
  def test_sysv_hash_locates_every_export
    r = Reader.read(build_so([SELF_CONTAINED]))
    nbucket, nchain, buckets, chain = parse_hash(r.section(".hash").data)
    assert_equal r.dynamic_symbols.size, nchain, "nchain must equal the dynsym count"

    r.dynamic_symbols.each_with_index do |sym, idx|
      next if idx.zero?

      i = buckets[elf_hash(sym.name) % nbucket]
      i = chain[i] while i != STN_UNDEF && r.dynamic_symbols[i].name != sym.name
      assert_equal idx, i, "hash lookup of #{sym.name} must land on its own dynsym index"
    end
  end

  def test_dynamic_array_carries_the_required_tags
    r = Reader.read(build_so([SELF_CONTAINED]))
    tags = r.dynamic_entries.map(&:tag)
    # DT_HASH, DT_STRTAB, DT_SYMTAB, DT_STRSZ, DT_SYMENT (DT_NULL is the reader's
    # terminator and not retained).
    assert_equal [4, 5, 6, 10, 11], tags
    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal r.section(".hash").addr, by_tag[4]
    assert_equal r.section(".dynstr").addr, by_tag[5]
    assert_equal r.section(".dynsym").addr, by_tag[6]
    assert_equal 24, by_tag[11], "DT_SYMENT is the symbol entry size"
  end

  # The cross-unit merge must produce a GOT slot per GOT-referenced symbol plus
  # a data pointer initializer, each backed by an R_X86_64_RELATIVE in .rela.dyn.
  def test_relative_relocations_for_got_and_data_pointer
    r = Reader.read(build_so([ACCESS, DEFINE]))
    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    refute_nil rela, ".rela.dyn must be present for GOT slots and data pointers"

    # Two GOT slots (shared_counter, bump) and one data-pointer initializer.
    assert_equal 3, rela.relocations.size
    rela.relocations.each do |reloc|
      assert_equal R_X86_64_RELATIVE, reloc.type, "every dynamic relocation is RELATIVE"
      # A RELATIVE relocation names no symbol; r_info's symbol field is 0, which
      # the reader resolves to the reserved null (undefined) entry.
      assert_equal STN_UNDEF, reloc.symbol.index, "a RELATIVE relocation carries no symbol"
    end

    # DT_RELA/DT_RELASZ/DT_RELAENT/DT_RELACOUNT describe the table.
    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal r.section(".rela.dyn").addr, by_tag[7]      # DT_RELA
    assert_equal 3 * 24, by_tag[8]                           # DT_RELASZ
    assert_equal 24, by_tag[9]                               # DT_RELAENT
    assert_equal 3, by_tag[0x6FFFFFF9]                       # DT_RELACOUNT
  end

  # --- program headers ----------------------------------------------------

  def test_three_load_segments_with_expected_permissions
    phdrs = program_headers(build_so([SELF_CONTAINED]))
    loads = phdrs.select { |p| p[:type] == PT_LOAD }
    assert_equal 3, loads.size, "expected r-x, r--, rw- load segments"
    assert_equal PF_R | PF_X, loads[0][:flags], "first segment (text) is r-x"
    assert_equal PF_R,        loads[1][:flags], "second segment (rodata + dyn) is r--"
    assert_equal PF_R | PF_W, loads[2][:flags], "third segment (data/got/dynamic) is rw-"
  end

  def test_load_segments_honor_the_page_congruence
    phdrs = program_headers(build_so([SELF_CONTAINED]))
    phdrs.select { |p| p[:type] == PT_LOAD }.each do |p|
      assert_equal p[:offset] % PAGE, p[:vaddr] % PAGE,
                   "p_vaddr must be congruent to p_offset modulo the page size"
    end
  end

  def test_bss_extends_memsz_beyond_filesz
    # A zero-initialized global lands in .bss (NOBITS), so the rw- segment's
    # memory size must exceed its file size while file bytes stop at .dynamic.
    src = "int table[64]; int first(void) { return table[0]; }"
    phdrs = program_headers(build_so([src]))
    rw = phdrs.select { |p| p[:type] == PT_LOAD }.last
    assert_operator rw[:memsz], :>, rw[:filesz], "the .bss reservation must grow memsz past filesz"
  end

  def test_pt_dynamic_and_non_executable_stack
    phdrs = program_headers(build_so([SELF_CONTAINED]))
    dynamic = phdrs.find { |p| p[:type] == PT_DYNAMIC }
    refute_nil dynamic
    r = Reader.read(build_so([SELF_CONTAINED]))
    assert_equal r.section(".dynamic").addr, dynamic[:vaddr]

    stack = phdrs.find { |p| p[:type] == PT_GNU_STACK }
    refute_nil stack, "a GNU_STACK header must mark the stack"
    assert_equal 0, stack[:flags] & PF_X, "the stack must be non-executable"
    assert_equal 0, stack[:memsz]
  end

  # --- determinism --------------------------------------------------------

  def test_output_is_byte_identical_for_identical_inputs
    assert_equal build_so([ACCESS, DEFINE]), build_so([ACCESS, DEFINE]),
                 "identical inputs must yield byte-identical shared objects"
  end

  # --- undefined-symbol rejection ----------------------------------------

  def test_undefined_external_symbol_is_rejected
    src = <<~C
      int printf(const char *, ...);
      int shout(void) { return printf("x"); }
    C
    error = assert_raises(Rubycc::Link::LinkError) { build_so([src]) }
    assert_match(/printf/, error.message)
    assert_match(/undefined/, error.message)
    assert_match(/L5b/, error.message, "the message must point at the stage that will resolve imports")
  end

  # --- dlopen acceptance (the first stage's whole point) ------------------

  def test_dlopen_calls_self_contained_exports
    with_so([SELF_CONTAINED]) do |so|
      lib = Fiddle.dlopen(so)
      assert_equal 6, call(lib, "add3", [Fiddle::TYPE_INT] * 3, Fiddle::TYPE_INT).call(1, 2, 3)
      assert_equal 20, call(lib, "quad", [Fiddle::TYPE_INT], Fiddle::TYPE_INT).call(5)

      get = call(lib, "get_counter", [], Fiddle::TYPE_INT)
      set = call(lib, "set_counter", [Fiddle::TYPE_INT], Fiddle::TYPE_VOID)
      assert_equal 41, get.call, "initial internal-global read"
      set.call(99)
      assert_equal 99, get.call, "internal-global write then read"

      ptr = call(lib, "greeting", [], Fiddle::TYPE_VOIDP).call
      assert_equal "hello", ptr.to_s, "a returned string literal must read back through .rodata"
    ensure
      lib&.close
    end
  end

  def test_dlopen_calls_cross_unit_got_and_data_pointer_exports
    with_so([ACCESS, DEFINE]) do |so|
      lib = Fiddle.dlopen(so)
      read = call(lib, "read_counter", [], Fiddle::TYPE_INT)
      write = call(lib, "write_counter", [Fiddle::TYPE_INT], Fiddle::TYPE_VOID)
      via = call(lib, "call_via_ptr", [Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      msg = call(lib, "stored_message", [], Fiddle::TYPE_VOIDP)

      assert_equal 100, read.call, "GOT-relative read of a now-internal global"
      write.call(55)
      assert_equal 55, read.call, "GOT-relative write then read"
      assert_equal 43, via.call(42), "call through a GOT-loaded function pointer"
      assert_equal "world", msg.call.to_s, "R_X86_64_64 data pointer rebased at load time"
    ensure
      lib&.close
    end
  end

  # --- external-tool validation ------------------------------------------

  def test_readelf_accepts_the_shared_object
    skip "readelf unavailable" unless tool?("readelf")

    with_so([ACCESS, DEFINE]) do |so|
      out, status = Open3.capture2e("readelf", "-a", so)
      assert status.success?, "readelf rejected the shared object:\n#{out}"
      refute_match(/\b[Ee]rror\b|malformed|Warning/, out, "readelf complained:\n#{out}")

      # eu-elflint (elfutils) is a stricter conformance checker; run it when
      # present as an extra guard. Its check rides on this test rather than a
      # standalone one so a host without it does not register a skip. Warnings
      # are tolerated (some, like a missing .gnu.hash, are expected in this
      # first stage); a fatal error is not.
      if tool?("eu-elflint")
        lint, = Open3.capture2e("eu-elflint", "--gnu-ld", so)
        refute_match(/\berror\b/i, lint, "eu-elflint reported a fatal error:\n#{lint}")
      end
    end
  end

  # rubycc's -fPIC reaches a *defined* global through R_X86_64_PC32 (not the
  # GOT), which our loader-free link resolves directly but GNU ld refuses for a
  # shared object (a default-visibility global may be interposed). The interop
  # comparison therefore uses an input free of defined-global access — internal
  # calls, a static helper and a string literal — all of which both linkers
  # accept, so the two shared objects can be compared.
  GCC_COMPATIBLE = <<~C
    static int dbl(int x) { return x * 2; }
    int quad(int x) { return dbl(dbl(x)); }
    int add3(int a, int b, int c) { return a + b + c; }
    char *greeting(void) { return "hello"; }
  C

  def test_matches_gcc_shared_object_exports_and_behavior
    skip "gcc unavailable" unless tool?("gcc")

    in_tmpdir do |dir|
      objects = objects_for([GCC_COMPATIBLE], dir)
      ours = File.join(dir, "ours.so")
      Linker.link_to(objects, ours)

      theirs = File.join(dir, "theirs.so")
      out, status = Open3.capture2e("gcc", "-shared", "-o", theirs, *objects)
      skip "gcc -shared failed:\n#{out}" unless status.success?

      # Every symbol we export must also be an export of gcc's shared object
      # (gcc additionally emits its own linker-defined symbols).
      ours_exports = defined_exports(Reader.read_file(ours))
      theirs_exports = defined_exports(Reader.read_file(theirs))
      assert_operator ours_exports, :<=, theirs_exports,
                      "our exports must be a subset of gcc's"

      assert_equal run_add3(theirs), run_add3(ours),
                   "both shared objects must compute the same result"
    end
  end

  private

  def build_so(sources)
    in_tmpdir { |dir| Linker.link(objects_for(sources, dir)) }
  end

  def with_so(sources)
    in_tmpdir do |dir|
      so = File.join(dir, "libtest.so")
      Linker.link_to(objects_for(sources, dir), so)
      yield so
    end
  end

  # Compiles each source with rubycc under -fPIC into its own object file and
  # returns the ordered object paths.
  def objects_for(sources, dir)
    sources.each_with_index.map do |src, i|
      path = File.join(dir, "u#{i}.o")
      File.binwrite(path, Rubycc::Compiler.new.compile(src, filename: "u#{i}.c", pic: true))
      path
    end
  end

  def call(lib, name, args, ret)
    Fiddle::Function.new(lib[name], args, ret)
  end

  # The set of names a shared object defines and exports through .dynsym.
  def defined_exports(reader)
    reader.dynamic_symbols.select { |s| s.defined? && !s.name.to_s.empty? }.map(&:name).to_set
  end

  def run_add3(so)
    lib = Fiddle.dlopen(so)
    call(lib, "add3", [Fiddle::TYPE_INT] * 3, Fiddle::TYPE_INT).call(4, 5, 6)
  ensure
    lib&.close
  end

  # Parses the ELF program header table straight from the image bytes; the
  # project's ELFReader is a section-oriented linker reader and does not expose
  # program headers, so the load-segment assertions read them here.
  def program_headers(bytes)
    bytes = bytes.b
    phoff = bytes[32, 8].unpack1("Q<")
    phentsize = bytes[54, 2].unpack1("S<")
    phnum = bytes[56, 2].unpack1("S<")
    (0...phnum).map do |i|
      base = phoff + i * phentsize
      {
        type: bytes[base, 4].unpack1("L<"),
        flags: bytes[base + 4, 4].unpack1("L<"),
        offset: bytes[base + 8, 8].unpack1("Q<"),
        vaddr: bytes[base + 16, 8].unpack1("Q<"),
        filesz: bytes[base + 32, 8].unpack1("Q<"),
        memsz: bytes[base + 40, 8].unpack1("Q<"),
        align: bytes[base + 48, 8].unpack1("Q<")
      }
    end
  end

  # Splits a SysV .hash section into nbucket, nchain, and the bucket/chain arrays.
  def parse_hash(bytes)
    nbucket, nchain = bytes[0, 8].unpack("L<L<")
    words = bytes[8, (nbucket + nchain) * 4].unpack("L<*")
    [nbucket, nchain, words[0, nbucket], words[nbucket, nchain]]
  end

  # The ELF gABI symbol hash, mirrored in the test so the .hash contents are
  # checked against an independent implementation rather than the writer's own.
  def elf_hash(name)
    h = 0
    name.each_byte do |c|
      h = (h << 4) + c
      g = h & 0xF0000000
      h ^= g >> 24 if g != 0
      h &= ~g & 0xFFFFFFFF
    end
    h
  end

  def in_tmpdir(&block)
    Dir.mktmpdir("rubycc-so", &block)
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
