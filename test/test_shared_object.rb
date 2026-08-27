# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"
require "fiddle"
require "rbconfig"
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
  include LibcHelper

  def setup
    host_target = HostTarget.name
    return if host_target == "x86_64"

    skip "x86_64 shared-object coverage is not valid on #{host_target.inspect}"
  end

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

  R_X86_64_RELATIVE  = 8
  R_X86_64_GLOB_DAT  = 6
  R_X86_64_JUMP_SLOT = 7
  STN_UNDEF = 0

  # Dynamic tags and flag bits the external-import assertions reference by name.
  DT_NEEDED   = 1
  DT_PLTRELSZ = 2
  DT_PLTGOT   = 3
  DT_SONAME   = 14
  DT_PLTREL   = 20
  DT_JMPREL   = 23
  DT_FLAGS    = 30
  DT_FLAGS_1  = 0x6FFFFFFB
  DF_BIND_NOW = 0x8
  DF_1_NOW    = 0x1
  SHN_UNDEF   = 0

  # The initializer/finalizer array section types, their section flags, and the
  # four dynamic tags the loader reaches them through (the sizes are in bytes).
  SHT_INIT_ARRAY  = 14
  SHT_FINI_ARRAY  = 15
  SHF_WRITE       = 0x1
  SHF_ALLOC       = 0x2
  DT_INIT_ARRAY   = 25
  DT_FINI_ARRAY   = 26
  DT_INIT_ARRAYSZ = 27
  DT_FINI_ARRAYSZ = 28
  R_X86_64_64     = 1

  # The relocation types the synthesized finalizer's three operands carry: the
  # PC-relative reference to __cxa_finalize's GOT slot (the NULL test), the
  # PC-relative reference to the internal __dso_handle, and the call routed
  # through the .plt.
  R_X86_64_PC32     = 2
  R_X86_64_PLT32    = 4
  R_X86_64_GOTPCREL = 9

  # A translation unit that imports from libc: an external function call
  # (strlen, puts -> R_X86_64_PLT32, resolved through a .plt stub and a
  # JUMP_SLOT) and an external data reference (environ -> R_X86_64_GOTPCREL,
  # resolved through a GOT slot and a GLOB_DAT).
  EXTERNAL = <<~C
    unsigned long strlen(const char *s);
    int puts(const char *s);
    extern char **environ;
    unsigned long my_len(const char *s) { return strlen(s); }
    int emit(const char *s) { return puts(s); }
    int env_present(void) { return environ != 0; }
  C

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

  def test_retains_regular_symbol_table_for_elf_tools
    skip "nm unavailable" unless tool?("nm")

    with_so([SELF_CONTAINED]) do |so|
      r = Reader.read(File.binread(so))
      symtab = r.section(".symtab")
      strtab = r.section(".strtab")
      refute_nil symtab, "a linked shared object should retain .symtab"
      refute_nil strtab, "a linked shared object should retain .strtab"
      assert_equal 2, symtab.type
      assert_equal strtab.index, symtab.link

      output, status = Open3.capture2e("nm", so)
      assert status.success?, "nm could not inspect the shared object:\n#{output}"
      global_text = output.lines.filter_map do |line|
        fields = line.split
        fields.last if fields.length >= 3 && fields[-2] == "T"
      end
      assert_includes global_text, "add3"
    end
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

  # A loader maps only p_filesz bytes of a PT_LOAD segment (rounded up to the
  # next page), so any allocatable, file-backed section placed in a segment
  # but lying outside its [p_offset, p_offset + p_filesz) window risks landing
  # on a page the loader never mapped. This must hold for every segment
  # regardless of how large any one section happens to be — a size-dependent
  # fixture would only catch the bug when the shortfall crosses a page
  # boundary, exactly the way it hid for every gem this linker had verified
  # before io-nonblock 0.3.2 exposed it (Step 163).
  def test_every_allocatable_section_fits_within_its_load_segments_file_extent
    assert_sections_fit_their_load_segments(build_so([SELF_CONTAINED]))
  end

  # The concrete shape of the reported failure: an external call routes
  # through .plt, the last section placed in the r-x segment, so a short
  # r-x p_filesz clips .plt first.
  def test_plt_fits_within_the_rx_load_segments_file_extent
    skip "libc unavailable" unless libc_path

    assert_sections_fit_their_load_segments(build_so([EXTERNAL], needed: [libc_path]))
  end

  # --- determinism --------------------------------------------------------

  def test_output_is_byte_identical_for_identical_inputs
    assert_equal build_so([ACCESS, DEFINE]), build_so([ACCESS, DEFINE]),
                 "identical inputs must yield byte-identical shared objects"
  end

  # --- external imports (structure) --------------------------------------

  # An imported symbol with no supplying dependency is left undefined rather
  # than rejected: a shared object may be completed by the runtime scope. It
  # enters .dynsym as a UND entry and pulls in no DT_NEEDED.
  def test_unresolved_import_is_left_undefined_without_a_needed
    src = <<~C
      int printf(const char *, ...);
      int shout(void) { return printf("x"); }
    C
    r = Reader.read(build_so([src]))
    printf = r.dynamic_symbol("printf")
    refute_nil printf, "an imported symbol must enter .dynsym"
    assert printf.undefined?, "with no supplying dependency the import stays undefined"
    assert_empty r.needed, "an unresolved import records no DT_NEEDED"
  end

  # A referenced external symbol resolved against a dependency stays a UND
  # .dynsym entry (its definition lives in the dependency) while the dependency
  # is recorded as DT_NEEDED under its SONAME.
  def test_resolved_imports_enter_dynsym_and_pull_in_dt_needed
    skip "libc unavailable" unless libc_path

    r = Reader.read(build_so([EXTERNAL], needed: [libc_path], soname: "libext.so"))
    %w[strlen puts environ].each do |name|
      sym = r.dynamic_symbol(name)
      refute_nil sym, "#{name} must be imported into .dynsym"
      assert sym.undefined?, "#{name} is imported, so its .dynsym entry is UND"
      assert_equal 0, sym.value
    end
    assert_equal [host_libc_soname], r.needed, "the resolving dependency is a DT_NEEDED by SONAME"
    assert_equal "libext.so", r.soname, "DT_SONAME is the given name"
  end

  # A dependency that supplies nothing must not be recorded (--as-needed).
  def test_unused_dependency_is_not_recorded_as_needed
    skip "libc unavailable" unless libc_path

    r = Reader.read(build_so([SELF_CONTAINED], needed: [libc_path]))
    assert_empty r.needed, "a dependency supplying no symbol earns no DT_NEEDED"
  end

  def test_external_function_gets_a_jump_slot_and_data_gets_a_glob_dat
    skip "libc unavailable" unless libc_path

    r = Reader.read(build_so([EXTERNAL], needed: [libc_path]))

    plt = r.relocation_sections.find { |rs| rs.section.name == ".rela.plt" }
    refute_nil plt, ".rela.plt must hold the external-call bindings"
    assert_equal %w[puts strlen],
                 plt.relocations.map { |x| x.symbol.name }.sort
    plt.relocations.each do |reloc|
      assert_equal R_X86_64_JUMP_SLOT, reloc.type, "each external call binds through a JUMP_SLOT"
      assert_equal 0, reloc.addend
    end

    dyn = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    glob = dyn.relocations.select { |x| x.type == R_X86_64_GLOB_DAT }
    assert_equal ["environ"], glob.map { |x| x.symbol.name }, "external data binds through a GLOB_DAT"
  end

  # The .rela.plt JUMP_SLOT offsets must land on the per-function .got.plt slots
  # (past the three reserved entries), which DT_PLTGOT points at.
  def test_got_plt_layout_and_dynamic_plt_tags
    skip "libc unavailable" unless libc_path

    r = Reader.read(build_so([EXTERNAL], needed: [libc_path]))
    gotplt = r.section(".got.plt")
    refute_nil gotplt
    # Three reserved slots then one per external function (strlen, puts).
    assert_equal (3 + 2) * 8, gotplt.size

    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal gotplt.addr, by_tag[DT_PLTGOT], "DT_PLTGOT points at .got.plt"
    assert_equal r.section(".rela.plt").addr, by_tag[DT_JMPREL], "DT_JMPREL points at .rela.plt"
    assert_equal r.section(".rela.plt").size, by_tag[DT_PLTRELSZ]
    assert_equal 7, by_tag[DT_PLTREL], "DT_PLTREL is DT_RELA"

    first_slot = gotplt.addr + 3 * 8
    offsets = r.relocation_sections.find { |rs| rs.section.name == ".rela.plt" }
                .relocations.map(&:offset).sort
    assert_equal [first_slot, first_slot + 8], offsets,
                 "the JUMP_SLOTs target the per-function .got.plt slots"

    # The first reserved .got.plt slot holds &_DYNAMIC (spec convention).
    reserved0 = gotplt.data[0, 8].unpack1("Q<")
    assert_equal r.section(".dynamic").addr, reserved0, ".got.plt[0] is the &_DYNAMIC pointer"
  end

  # BIND_NOW is requested so the loader resolves every JUMP_SLOT / GLOB_DAT at
  # load time, which is why the .plt stub needs no lazy-resolver trampoline.
  def test_bind_now_flags_are_set_when_there_are_imports
    skip "libc unavailable" unless libc_path

    r = Reader.read(build_so([EXTERNAL], needed: [libc_path]))
    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal DF_BIND_NOW, by_tag[DT_FLAGS] & DF_BIND_NOW, "DT_FLAGS must request BIND_NOW"
    assert_equal DF_1_NOW, by_tag[DT_FLAGS_1] & DF_1_NOW, "DT_FLAGS_1 must request DF_1_NOW"

    # A self-contained object needs no eager binding, so it carries neither flag.
    self_contained = Reader.read(build_so([SELF_CONTAINED]))
    self_tags = self_contained.dynamic_entries.map(&:tag)
    refute_includes self_tags, DT_FLAGS
    refute_includes self_tags, DT_FLAGS_1
  end

  # Each .plt stub is `jmp *slot(%rip)` — FF 25 followed by a PC-relative disp32
  # to its .got.plt slot — padded with single-byte NOPs to the 16-byte entry.
  def test_plt_stub_encoding_jumps_to_its_got_plt_slot
    skip "libc unavailable" unless libc_path

    r = Reader.read(build_so([EXTERNAL], needed: [libc_path]))
    plt = r.section(".plt")
    refute_nil plt
    assert_equal 2 * 16, plt.size, "one 16-byte stub per external function"

    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.plt" }
    # The stubs are laid in .plt in the same first-seen order the JUMP_SLOTs are,
    # so stub i drives .got.plt slot named by rela entry i.
    rela.relocations.each_with_index do |reloc, i|
      stub_off = i * 16
      assert_equal "\xFF\x25".b, plt.data[stub_off, 2], "stub #{i} is an indirect jmp (FF 25)"
      disp = plt.data[stub_off + 2, 4].unpack1("l<")
      stub_vaddr = plt.addr + stub_off
      assert_equal reloc.offset, stub_vaddr + 6 + disp,
                   "the disp32 must reach the stub's .got.plt slot"
      assert_equal ("\x90".b * 10), plt.data[stub_off + 6, 10], "the stub pads to 16 bytes with NOPs"
    end
  end

  # --- external imports (dlopen acceptance, the second stage's whole point) ---

  def test_dlopen_calls_libc_through_plt_and_got
    skip "libc unavailable" unless libc_path

    with_so([EXTERNAL], needed: [libc_path], soname: "libext.so") do |so|
      lib = Fiddle.dlopen(so)
      my_len = call(lib, "my_len", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG)
      assert_equal 5, my_len.call("hello"), "an external strlen call must run through the PLT"

      # puts returns a non-negative count on success; a successful return proves
      # the imported call was bound and ran (its buffered stdout output, which
      # bypasses Ruby's $stdout, is not asserted).
      emit = call(lib, "emit", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      assert_operator emit.call("printed via an imported puts"), :>=, 0,
                      "an external puts call must run through the PLT and return"

      env = call(lib, "env_present", [], Fiddle::TYPE_INT)
      assert_equal 1, env.call, "an external data (environ) read must run through the GOT"
    ensure
      lib&.close
    end
  end

  def test_external_import_output_is_deterministic
    skip "libc unavailable" unless libc_path

    a = build_so([EXTERNAL], needed: [libc_path], soname: "libext.so")
    b = build_so([EXTERNAL], needed: [libc_path], soname: "libext.so")
    assert_equal a, b, "identical inputs and dependencies must yield byte-identical shared objects"
  end

  # gcc's own shared object built from the same objects must import the same
  # libc dependency and compute the same result, cross-checking our binding.
  def test_matches_gcc_external_shared_object
    skip "gcc unavailable" unless tool?("gcc")
    skip "libc unavailable" unless libc_path

    in_tmpdir do |dir|
      objects = objects_for([EXTERNAL], dir)
      ours = File.join(dir, "ours.so")
      Linker.link_to(objects, ours, needed: [libc_path])

      theirs = File.join(dir, "theirs.so")
      out, status = Open3.capture2e("gcc", "-shared", "-o", theirs, *objects, "-lc")
      skip "gcc -shared failed:\n#{out}" unless status.success?

      assert_includes Reader.read_file(ours).needed, host_libc_soname
      assert_includes Reader.read_file(theirs).needed, host_libc_soname

      assert_equal run_my_len(theirs), run_my_len(ours),
                   "both shared objects must compute the same imported result"
    end
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

  # --- __dso_handle synthesis --------------------------------------------

  # A unit that only *references* __dso_handle, the way glibc's
  # libc_nonshared.a members do: nothing in the link defines it, so the linker
  # has to supply it. Both spellings are exercised — the value of the word and
  # its address — because the whole contract is that the two are equal.
  DSO_HANDLE_USER = <<~C
    extern void *__dso_handle;
    void *handle_value(void) { return __dso_handle; }
    void *handle_address(void) { return &__dso_handle; }
  C

  # A unit supplying its own __dso_handle, plus one referencing it: the link
  # must keep the input's definition and synthesize nothing.
  DSO_HANDLE_OWN = <<~C
    void *__dso_handle = 0;
  C

  # pthread_atfork, the case that exposed the gap: glibc keeps it out of the
  # shared libc and supplies it only from libc_nonshared.a, whose member
  # registers the handlers with __dso_handle as the owning-object cookie.
  ATFORK = <<~C
    int pthread_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void));
    static int seen;
    static void on_prepare(void) { seen |= 1; }
    static void on_parent(void) { seen |= 2; }
    static void on_child(void) { seen |= 4; }
    int register_hooks(void) { return pthread_atfork(on_prepare, on_parent, on_child); }
    int seen_bits(void) { return seen; }
  C

  # The supplied word is an 8-byte .data object holding its own load-time
  # address, rebased by exactly one R_X86_64_RELATIVE whose offset and addend
  # are both that address — the shape measured from `gcc -shared -fPIC` output.
  def test_dso_handle_is_synthesized_when_no_input_defines_it
    r = Reader.read(build_so([DSO_HANDLE_USER]))

    data = r.section(".data")
    refute_nil data, "the synthesized word lives in .data"
    assert_equal 8, data.size, "one 8-byte handle word and nothing else"
    assert_equal data.addr, data.data.unpack1("Q<"),
                 "the word must hold its own address (a unique per-DSO cookie)"

    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    refute_nil rela, "the self-reference is rebased at load time"
    self_rebase = rela.relocations.select { |x| x.offset == data.addr }
    assert_equal 1, self_rebase.size, "exactly one dynamic relocation covers the word"
    assert_equal R_X86_64_RELATIVE, self_rebase.first.type
    assert_equal data.addr, self_rebase.first.addend,
                 "the RELATIVE addend must be the word's own address"
    assert_equal STN_UNDEF, self_rebase.first.symbol.index,
                 "a RELATIVE relocation carries no symbol"
  end

  # The definition must stay invisible to the dynamic linker: it is not an
  # export, so no other object in the runtime scope can interpose it and hand
  # this object a foreign identity. Nor is the routine that consumes it — a
  # local symbol reached only from this object's own array slot.
  def test_synthesized_dso_handle_is_not_exported
    r = Reader.read(build_so([DSO_HANDLE_USER]))
    assert_nil r.dynamic_symbol("__dso_handle"), "__dso_handle must not enter .dynsym"
    assert_nil r.dynamic_symbol("__rubycc_dso_finalize"),
               "the synthesized finalizer must not enter .dynsym either"
    assert_equal %w[handle_address handle_value],
                 defined_exports(r).to_a.sort,
                 "only the input's own functions are exported"
  end

  def test_synthesized_dso_handle_output_is_deterministic
    assert_equal build_so([DSO_HANDLE_USER]), build_so([DSO_HANDLE_USER]),
                 "identical inputs must yield byte-identical shared objects"
  end

  # The supplier is an archive member, so a link that never mentions the symbol
  # must come out exactly as it did before it existed: no .data word, no
  # relocation.
  def test_dso_handle_is_not_synthesized_when_unreferenced
    r = Reader.read(build_so([SELF_CONTAINED]))
    assert_equal 4, r.section(".data").size, "only the input's own `counter` is in .data"
    assert_nil r.section(".rela.dyn"), "a self-contained object needs no dynamic relocation"
    assert_nil r.dynamic_symbol("__dso_handle")
  end

  # An input that defines __dso_handle itself keeps its definition: the member
  # is never extracted, so there is no multiple definition and no second word.
  def test_input_definition_of_dso_handle_is_kept
    r = Reader.read(build_so([DSO_HANDLE_USER, DSO_HANDLE_OWN]))

    data = r.section(".data")
    assert_equal 8, data.size, "only the input's own definition is in .data"
    assert_equal 0, data.data.unpack1("Q<"), "the input's initializer is untouched"
    refute_nil r.dynamic_symbol("__dso_handle"),
               "the input's own definition is an ordinary default-visibility export"

    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    assert_empty rela.relocations.select { |x| x.offset == data.addr },
                 "no synthesized self-rebase is added on top of the input's definition"
  end

  # The supplier object itself: one hidden global OBJECT symbol over an 8-byte
  # .data word, self-referenced through an absolute-64 relocation. Hidden is the
  # binding that keeps it out of .dynsym while still resolving another object's
  # undefined reference during the merge (a local symbol could not).
  def test_dso_handle_supplier_member_shape
    r = Reader.read(dso_handle_member.data)
    sym = r.symbol("__dso_handle")
    assert_equal :object, sym.type
    assert_equal :hidden, sym.visibility, "hidden keeps the definition out of .dynsym"
    assert_equal ".data", sym.section.name
    assert_equal 0, sym.value
    assert_equal 8, sym.size

    relocs = r.relocation_sections.find { |rs| rs.target.name == ".data" }.relocations
    assert_equal 1, relocs.size
    assert_equal 0, relocs.first.offset
    assert_equal R_X86_64_64, relocs.first.type, "R_X86_64_64: the word points at itself"
    assert_equal "__dso_handle", relocs.first.symbol.name
    assert_equal 0, relocs.first.addend
  end

  # The run-time contract, checked by loading the object: the value read out of
  # __dso_handle is its own address, and it is not zero (zero would name the
  # main program).
  def test_dlopen_sees_a_handle_pointing_at_itself
    with_so([DSO_HANDLE_USER]) do |so|
      lib = Fiddle.dlopen(so)
      value = call(lib, "handle_value", [], Fiddle::TYPE_VOIDP).call
      address = call(lib, "handle_address", [], Fiddle::TYPE_VOIDP).call
      refute_equal 0, address.to_i, "the handle must be a real address"
      assert_equal address.to_i, value.to_i,
                   "the loaded word must hold its own run-time address"
    ensure
      lib&.close
    end
  end

  # End to end on the case that exposed the gap: pthread_atfork comes from
  # libc_nonshared.a, whose member references __dso_handle; the object must link,
  # dlopen, register its handlers with glibc and see them run across a real fork.
  #
  # The probe runs in a child interpreter rather than here: registering fork
  # handlers changes the *process* for as long as the object stays loaded, and
  # every later test that shells out forks, so the effect must not leak into the
  # rest of the suite. The child keeps the object loaded (`disable_close`) for
  # the same reason a real program would — glibc drops the registration only
  # when the object finalizes.
  def test_pthread_atfork_from_libc_nonshared_links_and_runs
    skip "libc unavailable" unless libc_path
    skip "libc_nonshared.a unavailable" unless libc_nonshared_path

    probe = <<~RUBY
      require "fiddle"
      lib = Fiddle.dlopen(ARGV[0])
      lib.disable_close
      register = Fiddle::Function.new(lib["register_hooks"], [], Fiddle::TYPE_INT)
      seen = Fiddle::Function.new(lib["seen_bits"], [], Fiddle::TYPE_INT)
      abort "pthread_atfork refused the registration" unless register.call.zero?
      abort "a handler ran before any fork" unless seen.call.zero?
      Process.wait(fork { exit!(0) })
      print seen.call
    RUBY

    with_so([ATFORK], needed: [libc_path], inputs: [libc_nonshared_path]) do |so|
      out, status = Open3.capture2e(RbConfig.ruby, "-e", probe, so)
      assert status.success?, "the atfork probe failed:\n#{out}"
      assert_equal "3", out,
                   "the prepare and parent handlers registered by the .so must have run"
    end
  end

  # --- the finalizer half of the __dso_handle member -----------------------
  #
  # The handle alone only tells the C runtime *who* registered a handler; the
  # object still has to say *when* it is going away. That is the finalizer the
  # supplier member now carries: a .fini_array slot pointing at a routine that
  # calls __cxa_finalize(__dso_handle), which is what makes glibc run and
  # unregister everything registered under this handle before the image is
  # unmapped. The shape is measured from a `gcc -shared -fPIC` output (its
  # __do_global_dtors_aux), not copied from any crt source.

  # A unit that registers an exit handler the way glibc's own atexit does —
  # __cxa_atexit(function, argument, owning DSO) — so only __cxa_finalize on
  # this handle can run it. A destructor is registered alongside so the *order*
  # of the two is observable. Neither can report through the object's own
  # memory (unmapped moments later), so both append to a file.
  def handler_source(marker)
    <<~C
      int __cxa_atexit(void (*f)(void *), void *arg, void *dso);
      extern void *__dso_handle;
      void *fopen(const char *path, const char *mode);
      int fputs(const char *s, void *stream);
      int fclose(void *stream);
      static void note(const char *s) {
        void *f = fopen("#{marker}", "a");
        if (f) { fputs(s, f); fclose(f); }
      }
      static void on_finalize(void *arg) { note("C"); }
      __attribute__((destructor)) static void on_destroy(void) { note("D"); }
      int arm(void) { return __cxa_atexit(on_finalize, 0, __dso_handle); }
    C
  end

  # The supplier member's second half: the routine in .text, the local symbol
  # naming it, the priority-0 array section, and the five relocations that bind
  # the routine's operands. Priority 0 is the implementation-reserved range, and
  # it is what puts the slot at the front of the array.
  def test_dso_handle_supplier_member_carries_the_finalizer
    r = Reader.read(dso_handle_member.data)

    text = r.section(".text")
    refute_nil text, "the finalizer's code travels in the same member as the word"
    sym = r.symbol("__rubycc_dso_finalize")
    assert_equal :local, sym.bind, "nothing outside this object may reach the routine"
    assert_equal :func, sym.type
    assert_equal ".text", sym.section.name
    assert_equal text.size, sym.size

    slot = r.section(".fini_array.00000")
    refute_nil slot, "the routine is reached through a priority-numbered array section"
    assert_equal SHT_FINI_ARRAY, slot.type
    assert_equal SHF_ALLOC | SHF_WRITE, slot.flags
    assert_equal 8, slot.entsize
    assert_equal 8, slot.size, "exactly one slot"

    text_relocs = r.relocation_sections.find { |rs| rs.target.name == ".text" }.relocations
    assert_equal [[4, R_X86_64_GOTPCREL, "__cxa_finalize", -5],
                  [14, R_X86_64_PC32, "__dso_handle", -4],
                  [19, R_X86_64_PLT32, "__cxa_finalize", -4]],
                 text_relocs.map { |x| [x.offset, x.type, x.symbol.name, x.addend] },
                 "the GOT test, the handle load and the call, in code order"

    slot_relocs = r.relocation_sections.find { |rs| rs.target.name == ".fini_array.00000" }.relocations
    assert_equal [[0, R_X86_64_64, "__rubycc_dso_finalize", 0]],
                 slot_relocs.map { |x| [x.offset, x.type, x.symbol.name, x.addend] }

    assert_equal :weak, r.symbol("__cxa_finalize").bind,
                 "a C library without __cxa_finalize must not fail the link"
    assert r.symbol("__cxa_finalize").undefined?
  end

  # In the linked object: one extra finalizer slot, addressed by DT_FINI_ARRAY,
  # rebased like any other internal absolute initializer.
  def test_synthesized_finalizer_slot_is_in_the_fini_array
    r = Reader.read(build_so([DSO_HANDLE_USER], needed: [libc_path].compact))

    slot = r.section(".fini_array.00000")
    refute_nil slot, "the supplier member contributes one finalizer slot"
    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal slot.addr, by_tag[DT_FINI_ARRAY], "DT_FINI_ARRAY points at the run's start"
    assert_equal 8, by_tag[DT_FINI_ARRAYSZ]

    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    reloc = rela.relocations.find { |x| x.offset == slot.addr }
    refute_nil reloc, "the slot is an internal absolute initializer"
    assert_equal R_X86_64_RELATIVE, reloc.type
    text = r.section(".text")
    assert_operator reloc.addend, :>=, text.addr, "the addend is the routine's address"
    assert_operator reloc.addend, :<, text.addr + text.size
  end

  # The runtime walks .fini_array backwards, so the front of the array runs
  # last: the object's own destructors must finish before the handle is
  # surrendered. The priority-0 section is what puts the synthesized slot there.
  def test_synthesized_finalizer_slot_leads_the_array
    r = Reader.read(build_so([DSO_HANDLE_USER], needed: [libc_path].compact,
                             inputs: [array_object(".fini_array", "handle_value")]))
    run = r.sections.select { |s| s.type == SHT_FINI_ARRAY }
    assert_equal %w[.fini_array.00000 .fini_array], run.map(&:name),
                 "priority 0 sorts ahead of the unnumbered input section"
    assert_equal run.first.addr + run.first.size, run.last.addr, "and runs straight into it"
    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal run.first.addr, by_tag[DT_FINI_ARRAY]
    assert_equal 16, by_tag[DT_FINI_ARRAYSZ], "both slots are in one range"
  end

  # __cxa_finalize is referenced twice and in two different ways, which is the
  # measured gcc shape: a GOT slot (GLOB_DAT) the NULL test reads directly, and
  # a .plt stub (JUMP_SLOT) the call goes through. WEAK is what lets a C library
  # that lacks the symbol leave the reference unresolved instead of failing.
  def test_cxa_finalize_is_a_weak_undefined_import_bound_through_got_and_plt
    r = Reader.read(build_so([DSO_HANDLE_USER], needed: [libc_path].compact))

    sym = r.dynamic_symbol("__cxa_finalize")
    refute_nil sym, "the finalizer's callee is a dynamic import"
    assert_equal :weak, sym.bind
    assert_equal SHN_UNDEF, sym.shndx

    dyn = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    glob = dyn.relocations.select { |x| x.type == R_X86_64_GLOB_DAT }
    assert_equal ["__cxa_finalize"], glob.map { |x| x.symbol.name },
                 "the NULL test reads a GOT slot the loader fills with a GLOB_DAT"

    plt = r.relocation_sections.find { |rs| rs.section.name == ".rela.plt" }
    refute_nil plt
    assert_equal ["__cxa_finalize"], plt.relocations.map { |x| x.symbol.name }
    assert_equal R_X86_64_JUMP_SLOT, plt.relocations.first.type
  end

  # Decodes the emitted routine byte by byte and re-derives each of its three
  # operand addresses, which pins both the instruction encodings and what they
  # point at. The NULL test cannot be triggered on a glibc host (it always has
  # __cxa_finalize), so this is where its presence is asserted.
  def test_synthesized_finalizer_tests_the_got_slot_before_calling
    r = Reader.read(build_so([DSO_HANDLE_USER], needed: [libc_path].compact))
    text = r.section(".text")
    slot = r.section(".fini_array.00000")
    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    routine = rela.relocations.find { |x| x.offset == slot.addr }.addend
    code = text.data[routine - text.addr, 25]

    assert_equal "\x55".b, code[0], "push %rbp realigns the stack for the call"
    assert_equal "\x48\x83\x3d".b, code[1, 3], "cmpq $0, disp32(%rip)"
    assert_equal 0, code[8].ord, "compared against zero"
    got_slot = rela.relocations.find { |x| x.type == R_X86_64_GLOB_DAT }.offset
    assert_equal got_slot, routine + 9 + code[4, 4].unpack1("l<"),
                 "the test reads __cxa_finalize's GOT slot, not its .plt stub"

    assert_equal "\x74\x0c".b, code[9, 2], "je over the call when the slot is NULL"
    assert_equal routine + 23, routine + 11 + 0x0c, "the branch lands on the epilogue"

    assert_equal "\x48\x8b\x3d".b, code[11, 3], "mov disp32(%rip), %rdi"
    assert_equal r.section(".data").addr, routine + 18 + code[14, 4].unpack1("l<"),
                 "the argument is the handle word's contents, not its address"

    assert_equal "\xe8".b, code[18], "call rel32"
    assert_equal r.section(".plt").addr, routine + 23 + code[19, 4].unpack1("l<"),
                 "the call goes through the .plt stub"
    assert_equal "\x5d\xc3".b, code[23, 2], "pop %rbp; ret"
  end

  # The acceptance: a handler registered under this object's handle must be run
  # and unregistered by the dlclose itself, with nothing done by hand. Step 152
  # could only show that calling __cxa_finalize manually cleared the
  # registration; the point here is that nobody calls it.
  #
  # The probe runs in a child interpreter: the file the handler leaves behind is
  # the only channel out of an image that is unmapped moments later, and the
  # checks on both sides of the dlclose pin the handler to the dlclose rather
  # than to the child's exit.
  def test_dlclose_runs_a_handler_registered_under_the_handle
    skip "libc unavailable" unless libc_path

    in_tmpdir do |dir|
      marker = File.join(dir, "trace.txt")
      so = File.join(dir, "libhandler.so")
      Linker.link_to(objects_for([handler_source(marker)], dir), so,
                     needed: [libc_path], soname: "libhandler.so")

      probe = <<~RUBY
        require "fiddle"
        lib = Fiddle.dlopen(ARGV[0])
        armed = Fiddle::Function.new(lib["arm"], [], Fiddle::TYPE_INT).call
        before = File.exist?(ARGV[1]) ? File.read(ARGV[1]) : ""
        lib.close
        after = File.exist?(ARGV[1]) ? File.read(ARGV[1]) : ""
        print [armed, before, after].join(",")
      RUBY
      out, status = Open3.capture2e(RbConfig.ruby, "-e", probe, so, marker)
      assert status.success?, "the finalizer probe failed:\n#{out}"
      assert_equal "0,,DC", out,
                   "__cxa_atexit accepted the registration, nothing ran before the dlclose, " \
                   "and the dlclose ran the destructor then the registered handler"
    end
  end

  # The other half of that result, stated on its own: the synthesized finalizer
  # is the *last* thing to run. Surrendering the handle first would unregister a
  # handler the object's own destructors might still be about to use.
  def test_synthesized_finalizer_runs_after_the_objects_own_destructors
    skip "libc unavailable" unless libc_path

    in_tmpdir do |dir|
      marker = File.join(dir, "order.txt")
      so = File.join(dir, "liborder.so")
      Linker.link_to(objects_for([handler_source(marker)], dir), so,
                     needed: [libc_path], soname: "liborder.so")

      probe = <<~RUBY
        require "fiddle"
        lib = Fiddle.dlopen(ARGV[0])
        Fiddle::Function.new(lib["arm"], [], Fiddle::TYPE_INT).call
        lib.close
        print File.read(ARGV[1])
      RUBY
      out, status = Open3.capture2e(RbConfig.ruby, "-e", probe, so, marker)
      assert status.success?, "the ordering probe failed:\n#{out}"
      assert_equal "DC", out, "the destructor runs first, the handle is surrendered last"
    end
  end

  # The invariant the whole supplier rests on: a link that never mentions
  # __dso_handle extracts no member, so it gains neither the word nor the
  # finalizer — no array section, no import, no .plt, not one byte.
  def test_a_link_without_dso_handle_gains_no_finalizer
    r = Reader.read(build_so([SELF_CONTAINED]))
    assert_nil r.section(".fini_array.00000")
    assert_nil r.section(".text.__rubycc_dso_finalize")
    assert_nil r.dynamic_symbol("__cxa_finalize")
    assert_nil r.section(".plt"), "no external call was introduced"
    assert_nil r.section(".got"), "no GOT slot was introduced"
    tags = r.dynamic_entries.map(&:tag)
    refute_includes tags, DT_FINI_ARRAY
    refute_includes tags, DT_FINI_ARRAYSZ
  end

  # An input that defines __dso_handle itself keeps the member unextracted, so
  # it opts out of the finalizer too — the object owns its handle and whatever
  # it does with it.
  def test_input_definition_of_dso_handle_also_suppresses_the_finalizer
    r = Reader.read(build_so([DSO_HANDLE_USER, DSO_HANDLE_OWN]))
    assert_nil r.section(".fini_array.00000")
    assert_nil r.dynamic_symbol("__cxa_finalize")
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

  # --- .init_array / .fini_array -----------------------------------------

  # The unit the array slots point into: each marker appends its own letter to a
  # buffer an exported function hands back, so the order the runtime called them
  # in is directly observable after dlopen.
  #
  # trace/marked stay `static`: this fixture shares the names with
  # RUBYCC_CONSTRUCTORS and GCC_CONSTRUCTORS below, and musl's dlclose is
  # effectively a no-op, so a library loaded earlier in the process stays
  # resident even after the test that loaded it calls `lib.close`. If these
  # globals were exported, a later gcc-built .so of the same name would resolve
  # `trace` to the first library loaded (ELF's default symbol interposition),
  # and one test's "CBA" could show up ahead of another test's "123L". Internal
  # linkage gives every library its own copy, leaving only what the test
  # actually wants to measure: constructor execution order.
  MARKERS = <<~C
    static char trace[16];
    static int marked;
    void mark_a(void) { trace[marked] = 'A'; marked = marked + 1; }
    void mark_b(void) { trace[marked] = 'B'; marked = marked + 1; }
    void mark_c(void) { trace[marked] = 'C'; marked = marked + 1; }
    char *trace_of(void) { return trace; }
    int marked_count(void) { return marked; }
  C

  def test_init_and_fini_array_sections_keep_their_type_and_shape
    r = Reader.read(build_so([MARKERS], inputs: [array_object(".init_array", "mark_a"),
                                                 array_object(".fini_array", "mark_b")]))
    { ".init_array" => SHT_INIT_ARRAY, ".fini_array" => SHT_FINI_ARRAY }.each do |name, type|
      sec = r.section(name)
      refute_nil sec, "#{name} must survive the link"
      assert_equal type, sec.type, "#{name} keeps its array section type"
      assert_equal SHF_ALLOC | SHF_WRITE, sec.flags, "#{name} is allocated and writable"
      assert_equal 8, sec.entsize, "#{name} holds 8-byte function pointers"
      assert_equal 8, sec.addralign, "#{name} is pointer-aligned"
      assert_equal 8, sec.size, "one slot was contributed"
    end
  end

  # The loader reaches the arrays only through these four tags; the sizes are
  # byte counts, not element counts.
  def test_init_and_fini_array_dynamic_tags
    r = Reader.read(build_so([MARKERS], inputs: [array_object(".init_array", "mark_a"),
                                                 array_object(".init_array", "mark_b"),
                                                 array_object(".fini_array", "mark_c")]))
    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal r.section(".init_array").addr, by_tag[DT_INIT_ARRAY]
    assert_equal 16, by_tag[DT_INIT_ARRAYSZ], "two slots is sixteen bytes, not two"
    assert_equal r.section(".fini_array").addr, by_tag[DT_FINI_ARRAY]
    assert_equal 8, by_tag[DT_FINI_ARRAYSZ]
  end

  # Each slot holds an internal absolute address, so a shared object rebases it
  # at load time exactly like any other absolute-64 initializer: one RELATIVE per
  # slot whose addend is the target function's address.
  def test_every_array_slot_gets_a_relative_whose_addend_is_the_function
    r = Reader.read(build_so([MARKERS], inputs: [array_object(".init_array", "mark_a"),
                                                 array_object(".fini_array", "mark_b")]))
    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    by_offset = rela.relocations.to_h { |rel| [rel.offset, rel] }

    { ".init_array" => "mark_a", ".fini_array" => "mark_b" }.each do |name, func|
      slot = r.section(name).addr
      reloc = by_offset[slot]
      refute_nil reloc, "#{name}'s slot must carry a dynamic relocation"
      assert_equal R_X86_64_RELATIVE, reloc.type, "an internal initializer rebases through RELATIVE"
      assert_equal r.dynamic_symbol(func).value, reloc.addend,
                   "the addend must be #{func}'s address"
    end
  end

  # The whole point: dlopen must actually call the initializers, in input order.
  def test_dlopen_runs_the_initializers_in_input_order
    with_so([MARKERS], inputs: [array_object(".init_array", "mark_a"),
                                array_object(".init_array", "mark_b"),
                                array_object(".init_array", "mark_c")]) do |so|
      lib = Fiddle.dlopen(so)
      assert_equal 3, call(lib, "marked_count", [], Fiddle::TYPE_INT).call,
                   "every initializer must have run before dlopen returned"
      assert_equal "ABC", call(lib, "trace_of", [], Fiddle::TYPE_VOIDP).call.to_s,
                   "the initializers run in the order their objects were linked"
    ensure
      lib&.close
    end
  end

  # The finalizer side needs a real dlclose, and a finalizer cannot report
  # through the object's own memory (it is unmapped moments later), so it leaves
  # a file behind. The probe runs in a child interpreter and checks for that file
  # both before and after the dlclose, which pins the finalizer to the dlclose
  # itself rather than to the child's exit.
  def test_dlclose_runs_the_finalizers
    skip "libc unavailable" unless libc_path

    in_tmpdir do |dir|
      marker = File.join(dir, "fini.marker")
      source = <<~C
        void *fopen(const char *path, const char *mode);
        int fputs(const char *s, void *stream);
        int fclose(void *stream);
        int inited;
        void note_init(void) { inited = 1; }
        void note_fini(void) {
          void *f = fopen("#{marker}", "w");
          if (f) { fputs("fini", f); fclose(f); }
        }
        int was_inited(void) { return inited; }
      C
      so = File.join(dir, "libfini.so")
      Linker.link_to(objects_for([source], dir) +
                     [array_object(".init_array", "note_init"),
                      array_object(".fini_array", "note_fini")],
                     so, needed: [libc_path], soname: "libfini.so")

      probe = <<~RUBY
        require "fiddle"
        lib = Fiddle.dlopen(ARGV[0])
        inited = Fiddle::Function.new(lib["was_inited"], [], Fiddle::TYPE_INT).call
        before = File.exist?(ARGV[1])
        lib.close
        print [inited, before, File.exist?(ARGV[1])].join(",")
      RUBY
      out, status = Open3.capture2e(RbConfig.ruby, "-e", probe, so, marker)
      assert status.success?, "the finalizer probe failed:\n#{out}"
      assert_equal "1,false,true", out,
                   "the initializer ran at dlopen and the finalizer at dlclose"
    end
  end

  # A priority (gcc's `.init_array.NNNNN`) orders the numbered sections ahead of
  # the unnumbered ones, by ascending priority and across inputs. Measured
  # against gcc: linking the same four markers with gcc -shared and reading the
  # array back yields this same order.
  def test_priority_numbered_array_sections_run_before_and_in_numeric_order
    with_so([MARKERS], inputs: [array_object(".init_array", "mark_a"),
                                array_object(".init_array.00500", "mark_b"),
                                array_object(".init_array.00101", "mark_c")]) do |so|
      lib = Fiddle.dlopen(so)
      assert_equal "CBA", call(lib, "trace_of", [], Fiddle::TYPE_VOIDP).call.to_s,
                   "priority 101, then 500, then the unnumbered section"
    ensure
      lib&.close
    end
  end

  # The array is addressed as one range, so its sections must be laid adjacently
  # with no hole a loader would read as a null function pointer.
  def test_priority_sections_are_laid_as_one_contiguous_run
    r = Reader.read(build_so([MARKERS], inputs: [array_object(".init_array", "mark_a"),
                                                 array_object(".init_array.00101", "mark_b")]))
    numbered = r.section(".init_array.00101")
    plain    = r.section(".init_array")
    assert_equal plain.addr, numbered.addr + numbered.size,
                 "the numbered section runs straight into the unnumbered one"
    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal numbered.addr, by_tag[DT_INIT_ARRAY], "DT_INIT_ARRAY points at the run's start"
    assert_equal 16, by_tag[DT_INIT_ARRAYSZ], "and spans both sections"
  end

  # A name this linker has not been shown would otherwise be placed by guesswork,
  # silently running the initializers in the wrong order.
  def test_unrecognized_array_section_name_is_refused
    err = assert_raises(Rubycc::Link::LinkError) do
      build_so([MARKERS], inputs: [array_object(".init_array.late", "mark_a")])
    end
    assert_match(/unsupported initializer array section/, err.message)
  end

  # The invariant guarding every existing link: an input without an array must
  # produce exactly the bytes it produced before, tags included.
  def test_a_link_without_arrays_gains_no_tag
    r = Reader.read(build_so([SELF_CONTAINED]))
    tags = r.dynamic_entries.map(&:tag)
    [DT_INIT_ARRAY, DT_INIT_ARRAYSZ, DT_FINI_ARRAY, DT_FINI_ARRAYSZ].each do |tag|
      refute_includes tags, tag, "an array tag must not appear without an array section"
    end
    assert_nil r.section(".init_array")
    assert_nil r.section(".fini_array")
  end

  def test_array_link_is_deterministic
    inputs = [array_object(".init_array", "mark_a"), array_object(".fini_array", "mark_b")]
    assert_equal build_so([MARKERS], inputs: inputs), build_so([MARKERS], inputs: inputs),
                 "identical inputs must yield byte-identical output"
  end

  # --- constructors compiled from C (Step 155) -----------------------------
  #
  # Every case above feeds the linker hand-built array objects, because the
  # front end could not emit them. These start from C instead: rubycc compiles
  # `__attribute__((constructor))`, rubycc links the result, and the loader runs
  # what comes out — compile, link and load on one line.
  #
  # trace/marked are `static` for the same reason as in MARKERS above: musl's
  # dlclose does not actually unload, so exported globals of the same name
  # would leak from one loaded .so into the next and let one test's trace
  # bleed into another's.
  RUBYCC_CONSTRUCTORS = <<~C
    static char trace[16];
    static int marked;
    static void rec(char c) { trace[marked] = c; marked = marked + 1; }
    __attribute__((constructor(101))) static void first(void)  { rec('1'); }
    __attribute__((constructor(500))) static void third(void)  { rec('3'); }
    __attribute__((constructor))      static void last(void)   { rec('L'); }
    __attribute__((constructor(200))) static void second(void) { rec('2'); }
    char *trace_of(void) { return trace; }
  C

  def test_compiled_constructors_form_one_contiguous_run
    r = Reader.read(build_so([RUBYCC_CONSTRUCTORS]))
    run = r.sections.select { |s| s.type == SHT_INIT_ARRAY }
    assert_equal %w[.init_array.00101 .init_array.00200 .init_array.00500 .init_array],
                 run.map(&:name), "a priority is its own section, ordered ascending"
    run.each_cons(2) do |a, b|
      assert_equal a.addr + a.size, b.addr, "#{a.name} must run straight into #{b.name}"
    end
    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal run.first.addr, by_tag[DT_INIT_ARRAY]
    assert_equal 4 * 8, by_tag[DT_INIT_ARRAYSZ], "all four constructors in one range"
  end

  # A `static` constructor's slot names a file-local symbol, which a shared
  # object rebases at load time like any other internal absolute address.
  def test_compiled_constructor_slots_rebase_through_relative
    r = Reader.read(build_so([RUBYCC_CONSTRUCTORS]))
    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    slots = r.sections.select { |s| s.type == SHT_INIT_ARRAY }
             .flat_map { |s| (0...(s.size / 8)).map { |i| s.addr + i * 8 } }
    by_offset = rela.relocations.to_h { |rel| [rel.offset, rel] }
    text = r.section(".text")
    slots.each do |slot|
      reloc = by_offset[slot]
      refute_nil reloc, "slot at #{format('%#x', slot)} must carry a dynamic relocation"
      assert_equal R_X86_64_RELATIVE, reloc.type
      assert_operator reloc.addend, :>=, text.addr, "the addend is a constructor's address"
      assert_operator reloc.addend, :<, text.addr + text.size
    end
  end

  # The acceptance for the shared-object half: dlopen must call what rubycc
  # compiled, in the order the priorities asked for.
  def test_dlopen_runs_compiled_constructors_in_priority_order
    with_so([RUBYCC_CONSTRUCTORS], needed: [libc_path].compact, soname: "libctors.so") do |so|
      lib = Fiddle.dlopen(so)
      assert_equal "123L", call(lib, "trace_of", [], Fiddle::TYPE_VOIDP).call.to_s,
                   "priorities 101, 200, 500, then the unnumbered constructor"
    ensure
      lib&.close
    end
  end

  # ... and gcc, given the same source, must produce the same order. This is the
  # same program GCC_CONSTRUCTORS below feeds through gcc's compiler, so the two
  # tests together pin both halves of the toolchain against it.
  def test_compiled_constructor_order_matches_gcc
    skip "gcc unavailable" unless tool?("gcc")

    order = ->(so) do
      lib = Fiddle.dlopen(so)
      call(lib, "trace_of", [], Fiddle::TYPE_VOIDP).call.to_s
    ensure
      lib&.close
    end

    in_tmpdir do |dir|
      src = File.join(dir, "ctors.c")
      File.write(src, RUBYCC_CONSTRUCTORS)
      theirs = File.join(dir, "theirs.so")
      out, status = Open3.capture2e("gcc", "-shared", "-fPIC", "-o", theirs, src)
      skip "gcc -shared failed:\n#{out}" unless status.success?

      ours = File.join(dir, "ours.so")
      Linker.link_to(objects_for([RUBYCC_CONSTRUCTORS], dir), ours,
                     needed: [libc_path].compact, soname: "libours.so")
      assert_equal order.call(theirs), order.call(ours),
                   "rubycc's own compile-and-link must match gcc's for the same source"
    end
  end

  # A destructor compiled from C, checked where it actually runs: at dlclose.
  # The finalizer cannot report through the object's own memory (unmapped moments
  # later), so it leaves a file behind and a child interpreter looks for it on
  # both sides of the dlclose.
  def test_dlclose_runs_a_compiled_destructor
    skip "libc unavailable" unless libc_path

    in_tmpdir do |dir|
      marker = File.join(dir, "compiled-fini.marker")
      source = <<~C
        void *fopen(const char *path, const char *mode);
        int fputs(const char *s, void *stream);
        int fclose(void *stream);
        int inited;
        __attribute__((constructor)) static void note_init(void) { inited = 1; }
        __attribute__((destructor)) static void note_fini(void) {
          void *f = fopen("#{marker}", "w");
          if (f) { fputs("fini", f); fclose(f); }
        }
        int was_inited(void) { return inited; }
      C
      so = File.join(dir, "libfini.so")
      Linker.link_to(objects_for([source], dir), so, needed: [libc_path], soname: "libfini.so")

      probe = <<~RUBY
        require "fiddle"
        lib = Fiddle.dlopen(ARGV[0])
        inited = Fiddle::Function.new(lib["was_inited"], [], Fiddle::TYPE_INT).call
        before = File.exist?(ARGV[1])
        lib.close
        print [inited, before, File.exist?(ARGV[1])].join(",")
      RUBY
      out, status = Open3.capture2e(RbConfig.ruby, "-e", probe, so, marker)
      assert status.success?, "the finalizer probe failed:\n#{out}"
      assert_equal "1,false,true", out,
                   "the compiled constructor ran at dlopen and the destructor at dlclose"
    end
  end

  # The real compiler's shape, which the hand-built objects above do not cover:
  # gcc points an array slot at a *section* symbol (`.text + 0x1a`) rather than
  # at a named function, and spells a priority as `.init_array.NNNNN`. Linking
  # gcc's own object proves both forms are handled, and gcc's own `.so` from the
  # same source is the oracle for the resulting order.
  #
  # Again, trace/marked stay `static`: musl's dlclose leaves earlier libraries
  # resident, so an exported trace/marked here would resolve to whichever
  # same-named library loaded first instead of this one.
  GCC_CONSTRUCTORS = <<~C
    static char trace[16];
    static int marked;
    static void rec(char c) { trace[marked++] = c; }
    __attribute__((constructor(101))) static void first(void)  { rec('1'); }
    __attribute__((constructor(500))) static void third(void)  { rec('3'); }
    __attribute__((constructor))      static void last(void)   { rec('L'); }
    __attribute__((constructor(200))) static void second(void) { rec('2'); }
    char *trace_of(void) { return trace; }
  C

  def test_links_gcc_constructors_and_matches_gcc_ordering
    skip "gcc unavailable" unless tool?("gcc")

    in_tmpdir do |dir|
      src = File.join(dir, "ctors.c")
      File.write(src, GCC_CONSTRUCTORS)
      object = File.join(dir, "ctors.o")
      out, status = Open3.capture2e("gcc", "-c", "-fPIC", "-o", object, src)
      skip "gcc -c failed:\n#{out}" unless status.success?

      ours = File.join(dir, "ours.so")
      Linker.link_to([object], ours, needed: [libc_path].compact, soname: "libours.so")

      # Structure: one contiguous array covering all four slots.
      r = Reader.read_file(ours)
      by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
      assert_equal 4 * 8, by_tag[DT_INIT_ARRAYSZ], "all four constructors are in the array"

      order = ->(so) do
        lib = Fiddle.dlopen(so)
        call(lib, "trace_of", [], Fiddle::TYPE_VOIDP).call.to_s
      ensure
        lib&.close
      end
      assert_equal "123L", order.call(ours),
                   "priorities 101, 200, 500, then the unnumbered constructor"

      theirs = File.join(dir, "theirs.so")
      out, status = Open3.capture2e("gcc", "-shared", "-o", theirs, object)
      skip "gcc -shared failed:\n#{out}" unless status.success?
      assert_equal order.call(theirs), order.call(ours),
                   "our initializer order must match gcc's for the same object"
    end
  end

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

  # Links `sources` (compiled here) into a shared object. `inputs` appends
  # further link inputs — an archive path, say — after the compiled objects, in
  # the position a driver would place a library.
  def build_so(sources, needed: [], soname: nil, inputs: [])
    in_tmpdir do |dir|
      Linker.link(objects_for(sources, dir) + inputs, needed: needed, soname: soname)
    end
  end

  def with_so(sources, needed: [], soname: nil, inputs: [])
    in_tmpdir do |dir|
      so = File.join(dir, "libtest.so")
      Linker.link_to(objects_for(sources, dir) + inputs, so, needed: needed, soname: soname)
      yield so
    end
  end

  # The host's libc shared object, located at the usual multiarch path or via
  # `ldconfig`, or nil when neither turns it up (the external-import cases
  # skip). Delegates to LibcHelper so this search is written once for the
  # whole suite.
  def libc_path
    host_libc_path
  end

  # glibc's libc_nonshared.a, the static half of the C library the linker script
  # names alongside the shared libc image; nil when the host has no such file
  # (the pthread_atfork case skips). It is what supplies pthread_atfork — and
  # what references __dso_handle.
  def libc_nonshared_path
    return @libc_nonshared_path if defined?(@libc_nonshared_path)

    @libc_nonshared_path = ["/usr/lib/x86_64-linux-gnu/libc_nonshared.a",
                            "/usr/lib64/libc_nonshared.a",
                            "/usr/lib/libc_nonshared.a"].find { |p| File.exist?(p) }
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

  # The one archive member that supplies __dso_handle (and, with it, the
  # finalizer that surrenders the handle), as the merge finds it.
  def dso_handle_member
    archive = Rubycc::ObjFile::ArReader.read(Linker.dso_handle_archive(EM_X86_64_MACHINE))
    member = archive.member_defining("__dso_handle")
    refute_nil member, "the archive must export __dso_handle so the merge can pull it in lazily"
    member
  end

  # A relocatable object holding nothing but one initializer-array slot pointing
  # at `func`, built the way a compiler emits one: an SHT_INIT_ARRAY /
  # SHT_FINI_ARRAY section of a single 8-byte zero slot, plus an absolute-64
  # relocation against the (here undefined, resolved by the merge) function. The
  # object is built directly rather than compiled because rubycc's front end
  # cannot yet emit these sections.
  def array_object(section, func)
    type = section.start_with?(".init_array") ? SHT_INIT_ARRAY : SHT_FINI_ARRAY
    w = Rubycc::ObjFile::RelocatableWriter.new
    slot = w.add_section(name: section, type: type, flags: SHF_ALLOC | SHF_WRITE,
                         addralign: 8, entsize: 8, data: "\0" * 8)
    sym = w.add_symbol(name: func, bind: :global, type: :notype)
    w.add_relocation(target: slot, offset: 0, symbol: sym, type: R_X86_64_64, addend: 0)
    w.to_binary
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

  def run_my_len(so)
    lib = Fiddle.dlopen(so)
    call(lib, "my_len", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG).call("acceptance")
  ensure
    lib&.close
  end

  # Checks the PT_LOAD invariant every segment must uphold no matter what it
  # happens to contain: each allocatable section placed in it fits entirely
  # within its [p_vaddr, p_vaddr + p_memsz) memory extent and — unless it is
  # SHT_NOBITS and so carries no file bytes at all — within its
  # [p_offset, p_offset + p_filesz) file extent too. A section is matched to
  # the one segment whose memory extent contains its address; every
  # allocatable section must land in exactly one.
  def assert_sections_fit_their_load_segments(bytes)
    r = Reader.read(bytes)
    loads = program_headers(bytes).select { |p| p[:type] == PT_LOAD }

    r.sections.each do |sec|
      next if sec.flags & SHF_ALLOC == 0

      seg = loads.find { |p| sec.addr >= p[:vaddr] && sec.addr < p[:vaddr] + p[:memsz] }
      refute_nil seg, "#{sec.name} at #{format('%#x', sec.addr)} must fall inside a PT_LOAD segment"
      assert_operator sec.addr + sec.size, :<=, seg[:vaddr] + seg[:memsz],
                       "#{sec.name} must fit within its segment's memory extent (p_vaddr + p_memsz)"
      next if sec.nobits?

      assert_operator sec.offset + sec.size, :<=, seg[:offset] + seg[:filesz],
                       "#{sec.name} (file [#{format('%#x', sec.offset)}, " \
                       "#{format('%#x', sec.offset + sec.size)})) must fit within its segment's " \
                       "file extent [#{format('%#x', seg[:offset])}, " \
                       "#{format('%#x', seg[:offset] + seg[:filesz])})"
    end
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
