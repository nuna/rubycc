# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"

# Exercises the shared-object writer (Rubycc::Link::SharedLinker) for the aarch64
# target, the counterpart of TestSharedObject's x86_64 coverage. rubycc compiles
# -fPIC relocatable objects for aarch64 AND links them into an ET_DYN (.so) with
# its OWN linker — no cross gcc, no cross ld — and the result is checked two ways.
#
# Structure: the emitted image is read back through the project's own ELFReader
# and its shape asserted (ET_DYN, the aarch64 machine, the exported .dynsym, a
# valid SysV .hash, the .dynamic array, R_AARCH64_RELATIVE rebasing of internal
# absolute addresses, R_AARCH64_JUMP_SLOT / R_AARCH64_GLOB_DAT for imports, and
# the four-instruction PLT stub); output is asserted deterministic. These run
# wherever rubycc runs.
#
# Execution (the point): because the host is x86_64 and cannot dlopen an aarch64
# object, the `.so` is loaded by the real on-target dynamic loader under qemu — a
# small consumer executable built by the cross gcc links against the rubycc `.so`
# and calls its exports; the loaded object's results are compared to expectation.
# Those cases are skip-guarded on the cross toolchain and sysroot being present.
class TestAArch64SharedObject < Minitest::Test
  include AArch64ExecutionHelper

  Reader = Rubycc::ObjFile::ELFReader
  Linker = Rubycc::Link::SharedLinker

  EM_AARCH64 = 183

  R_AARCH64_RELATIVE  = 1027
  R_AARCH64_GLOB_DAT  = 1025
  R_AARCH64_JUMP_SLOT = 1026
  R_AARCH64_ABS64     = 257
  STN_UNDEF = 0

  # The initializer/finalizer array section types, their flags, and the dynamic
  # tags addressing them (sizes in bytes) — target-independent, as is the whole
  # section/table layer above the relocation apply.
  SHT_INIT_ARRAY  = 14
  SHT_FINI_ARRAY  = 15
  SHF_WRITE       = 0x1
  SHF_ALLOC       = 0x2
  DT_INIT_ARRAY   = 25
  DT_FINI_ARRAY   = 26
  DT_INIT_ARRAYSZ = 27
  DT_FINI_ARRAYSZ = 28

  DT_NEEDED   = 1
  DT_PLTGOT   = 3
  DT_JMPREL   = 23
  DT_FLAGS    = 30
  DT_FLAGS_1  = 0x6FFFFFFB
  DF_BIND_NOW = 0x8
  DF_1_NOW    = 0x1

  # A self-contained translation unit exercising the relocations the writer
  # applies within one aarch64 object: internal calls (CALL26), a static helper,
  # internal global read/write (adrp/add), and a string literal returned by
  # address (adrp/add into .rodata).
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
  # because they are extern at compile time), plus a file-scope pointer
  # initializer that lands an R_AARCH64_ABS64 in .data.
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

  # A translation unit that imports from libc: an external function call (strlen,
  # puts -> CALL26, resolved through a .plt stub and a JUMP_SLOT) and an external
  # data reference (environ -> GOT pair, resolved through a GOT slot and a
  # GLOB_DAT).
  EXTERNAL = <<~C
    unsigned long strlen(const char *s);
    int puts(const char *s);
    extern char **environ;
    unsigned long my_len(const char *s) { return strlen(s); }
    int emit(const char *s) { return puts(s); }
    int env_present(void) { return environ != 0; }
  C

  # --- structural round-trip (no toolchain needed) -----------------------

  def test_emits_et_dyn_for_aarch64
    r = Reader.read(build_so([SELF_CONTAINED]))
    assert r.shared_object?, "output must be ET_DYN"
    assert_equal EM_AARCH64, r.machine, "the image is an aarch64 object"
    assert_equal 0, r.entry, "a shared object has no entry point"
  end

  def test_exports_every_defined_global_in_dynsym
    r = Reader.read(build_so([SELF_CONTAINED]))
    exported = r.dynamic_symbols.reject { |s| s.name.to_s.empty? }.map(&:name).sort
    assert_equal %w[add3 counter get_counter greeting quad set_counter], exported
    assert_nil r.dynamic_symbol("dbl"), "a static function must not be exported"

    add3 = r.dynamic_symbol("add3")
    assert_equal :func, add3.type
    assert add3.defined?, "add3 must resolve to its defining section"
    counter = r.dynamic_symbol("counter")
    assert_equal :object, counter.type
    assert_equal r.section(".data").addr, counter.value
  end

  # The SysV hash must locate every exported symbol.
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

  # The cross-unit merge must produce a GOT slot per GOT-referenced symbol plus a
  # data pointer initializer, each rebased by an R_AARCH64_RELATIVE (the aarch64
  # spelling of the base relocation a PIC image needs).
  def test_relative_relocations_for_got_and_data_pointer
    r = Reader.read(build_so([ACCESS, DEFINE]))
    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    refute_nil rela, ".rela.dyn must be present for GOT slots and data pointers"

    # Two GOT slots (shared_counter, bump) and one data-pointer initializer.
    assert_equal 3, rela.relocations.size
    rela.relocations.each do |reloc|
      assert_equal R_AARCH64_RELATIVE, reloc.type, "every dynamic relocation is RELATIVE"
      assert_equal STN_UNDEF, reloc.symbol.index, "a RELATIVE relocation carries no symbol"
    end

    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal r.section(".rela.dyn").addr, by_tag[7] # DT_RELA
    assert_equal 3 * 24, by_tag[8]                       # DT_RELASZ
    assert_equal 3, by_tag[0x6FFFFFF9]                   # DT_RELACOUNT
  end

  def test_load_segments_honor_the_page_congruence
    phdrs = program_headers(build_so([SELF_CONTAINED]))
    loads = phdrs.select { |p| p[:type] == 1 } # PT_LOAD
    assert_equal 3, loads.size, "expected r-x, r--, rw- load segments"
    loads.each do |p|
      # aarch64 stamps a 64 KiB max page; the p_vaddr ≡ p_offset (mod page)
      # congruence must hold for the loader to map the segment.
      assert_equal p[:offset] % p[:align], p[:vaddr] % p[:align],
                   "p_vaddr must be congruent to p_offset modulo p_align"
      assert_equal 0x10000, p[:align], "aarch64 load segments align to 64 KiB"
    end
  end

  # A loader maps only p_filesz bytes of a PT_LOAD segment (rounded up to the
  # next page), so any allocatable, file-backed section placed in a segment
  # but lying outside its [p_offset, p_offset + p_filesz) window risks landing
  # on a page the loader never mapped. This must hold for every segment
  # regardless of how large any one section happens to be — a size-dependent
  # fixture would only catch the bug when the shortfall crosses a page
  # boundary, exactly the way it hid for every gem this linker had verified
  # before io-nonblock 0.3.2 exposed it on x86_64 (Step 163). SharedLinker's
  # build_phdrs is target-independent, so the same fixture applies here.
  def test_every_allocatable_section_fits_within_its_load_segments_file_extent
    assert_sections_fit_their_load_segments(build_so([SELF_CONTAINED]))
  end

  # The concrete shape of the reported failure: an external call routes
  # through .plt, the last section placed in the r-x segment, so a short
  # r-x p_filesz clips .plt first.
  def test_plt_fits_within_the_rx_load_segments_file_extent
    skip "libc unavailable" unless libc_available?

    assert_sections_fit_their_load_segments(build_so([EXTERNAL], needed: [SYSROOT_LIBC]))
  end

  def test_output_is_byte_identical_for_identical_inputs
    assert_equal build_so([ACCESS, DEFINE]), build_so([ACCESS, DEFINE]),
                 "identical inputs must yield byte-identical shared objects"
  end

  # --- __dso_handle synthesis --------------------------------------------

  # A unit that only references __dso_handle (as glibc's libc_nonshared.a
  # members do), so the linker has to supply the word itself. On aarch64 the
  # reference is a two-instruction pair — adrp/add for the address, or the GOT
  # pair under -fPIC — and every form must resolve internally rather than turn
  # into a text relocation against an import.
  DSO_HANDLE_USER = <<~C
    extern void *__dso_handle;
    void *handle_value(void) { return __dso_handle; }
    void *handle_address(void) { return &__dso_handle; }
  C

  # The aarch64 counterpart of TestSharedObject's x86_64 case: the same 8-byte
  # self-referencing .data word, rebased by one R_AARCH64_RELATIVE (the aarch64
  # spelling of the base relocation), and kept out of .dynsym.
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
    assert_equal R_AARCH64_RELATIVE, self_rebase.first.type
    assert_equal data.addr, self_rebase.first.addend,
                 "the RELATIVE addend must be the word's own address"

    assert_nil r.dynamic_symbol("__dso_handle"), "__dso_handle must not enter .dynsym"
  end

  def test_dso_handle_is_not_synthesized_when_unreferenced
    r = Reader.read(build_so([SELF_CONTAINED]))
    assert_equal 4, r.section(".data").size, "only the input's own `counter` is in .data"
    assert_nil r.section(".rela.dyn"), "a self-contained object needs no dynamic relocation"
  end

  # The execution oracle: the on-target loader rebases the word, and the object's
  # own code — an adrp/add or GOT pair against a now-internal symbol — reads back
  # exactly the word's own run-time address.
  def test_dso_handle_points_at_itself_under_qemu
    skip_unless_aarch64_self_link

    consumer = <<~C
      #include <stdio.h>
      void *handle_value(void); void *handle_address(void);
      int main(void) {
        printf("%d\\n", handle_address() != 0);
        printf("%d\\n", handle_value() == handle_address());
        return 0;
      }
    C
    status, stdout = build_and_run_consumer([DSO_HANDLE_USER], "libdso.so", consumer)
    assert_equal 0, status
    assert_equal "1\n1\n", stdout
  end

  # --- the finalizer half of the __dso_handle member -----------------------
  #
  # The aarch64 counterpart of TestSharedObject's coverage: the supplier member
  # also carries a priority-0 .fini_array slot calling __cxa_finalize with the
  # handle's value, so a dlclosed object surrenders the handlers it registered.
  # The measured shape is the same; only the encodings differ — aarch64 has no
  # memory-operand compare, so the GOT slot is loaded and tested with `cbz`.

  # Registers an exit handler under this object's handle (the way glibc's atexit
  # does), plus a destructor, so both the fact that the handler runs at dlclose
  # and the order of the two are observable. Both report through stdout, which
  # is safe: they run while the image is still mapped.
  CXA_ATEXIT_USER = <<~C
    int __cxa_atexit(void (*f)(void *), void *arg, void *dso);
    extern void *__dso_handle;
    int puts(const char *s);
    static void on_finalize(void *arg) { puts("C"); }
    __attribute__((destructor)) static void on_destroy(void) { puts("D"); }
    int arm(void) { return __cxa_atexit(on_finalize, 0, __dso_handle); }
  C

  def test_synthesized_finalizer_slot_and_weak_import_on_aarch64
    skip "aarch64 sysroot libc unavailable" unless libc_available?

    r = Reader.read(build_so([DSO_HANDLE_USER], needed: [SYSROOT_LIBC]))

    slot = r.section(".fini_array.00000")
    refute_nil slot, "the supplier member contributes one finalizer slot"
    assert_equal SHT_FINI_ARRAY, slot.type
    assert_equal 8, slot.size
    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal slot.addr, by_tag[DT_FINI_ARRAY]
    assert_equal 8, by_tag[DT_FINI_ARRAYSZ]

    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    reloc = rela.relocations.find { |x| x.offset == slot.addr }
    refute_nil reloc, "a PIC image rebases the slot at load time"
    assert_equal R_AARCH64_RELATIVE, reloc.type
    text = r.section(".text")
    assert_operator reloc.addend, :>=, text.addr, "the addend is the routine's address"
    assert_operator reloc.addend, :<, text.addr + text.size

    sym = r.dynamic_symbol("__cxa_finalize")
    assert_equal :weak, sym.bind, "a C library without __cxa_finalize must not fail the link"
    assert sym.undefined?
    assert_equal ["__cxa_finalize"],
                 rela.relocations.select { |x| x.type == R_AARCH64_GLOB_DAT }.map { |x| x.symbol.name },
                 "the NULL test reads a GOT slot bound by a GLOB_DAT"
    plt = r.relocation_sections.find { |rs| rs.section.name == ".rela.plt" }
    assert_includes plt.relocations.map { |x| x.symbol.name }, "__cxa_finalize",
                    "the call goes through a .plt stub bound by a JUMP_SLOT"
  end

  # Decodes the ten emitted instruction words and re-derives what each operand
  # points at. The NULL test cannot be triggered on a host whose libc always has
  # __cxa_finalize, so this is where the `cbz` is asserted to exist.
  def test_synthesized_finalizer_encoding_on_aarch64
    skip "aarch64 sysroot libc unavailable" unless libc_available?

    r = Reader.read(build_so([DSO_HANDLE_USER], needed: [SYSROOT_LIBC]))
    text = r.section(".text")
    slot = r.section(".fini_array.00000")
    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    routine = rela.relocations.find { |x| x.offset == slot.addr }.addend
    words = text.data[routine - text.addr, 40].unpack("L<10")

    assert_equal 0xA9BF7BFD, words[0], "stp x29, x30, [sp, #-16]!"
    got_slot = rela.relocations.find { |x| x.type == R_AARCH64_GLOB_DAT }.offset
    got_addr = ((routine + 4) & ~0xFFF) + adrp_page_delta(words[1]) + (((words[2] >> 10) & 0xFFF) << 3)
    assert_equal got_slot, got_addr, "the adrp/ldr pair reaches __cxa_finalize's GOT slot"
    assert_equal 0xB40000A0, words[3], "cbz x0 over the call when the slot is NULL"

    handle = ((routine + 16) & ~0xFFF) + adrp_page_delta(words[4]) + ((words[5] >> 10) & 0xFFF)
    assert_equal r.section(".data").addr, handle, "the adrp/add pair reaches the handle word"
    assert_equal 0xF9400020, words[6], "ldr x0, [x1]: the word's contents, not its address"

    disp = (words[7] & 0x03FFFFFF) << 2
    assert_equal r.section(".plt").addr, routine + 28 + disp, "the bl reaches the .plt stub"
    assert_equal 0xA8C17BFD, words[8], "ldp x29, x30, [sp], #16"
    assert_equal 0xD65F03C0, words[9], "ret"
  end

  # The execution oracle: the real aarch64 loader under qemu must run the
  # object's destructor and then the registered handler, both at the dlclose and
  # neither before it.
  def test_dlclose_runs_the_registered_handler_under_qemu
    skip_unless_aarch64_self_link

    consumer = <<~C
      #include <stdio.h>
      #include <dlfcn.h>
      int main(int argc, char **argv) {
        void *h = dlopen(argv[1], RTLD_NOW);
        int (*arm)(void);
        if (!h) { printf("dlopen failed: %s\\n", dlerror()); return 1; }
        arm = (int (*)(void)) dlsym(h, "arm");
        if (!arm) { printf("dlsym failed\\n"); return 1; }
        printf("armed=%d\\n", arm());
        printf("before\\n");
        dlclose(h);
        printf("after\\n");
        return 0;
      }
    C
    status, stdout = run_dlopen_consumer([CXA_ATEXIT_USER], "libhandler.so", consumer)
    assert_equal 0, status
    assert_equal "armed=0\nbefore\nD\nC\nafter\n", stdout,
                 "nothing ran before the dlclose; the dlclose ran the destructor " \
                 "and then the handler registered under the handle"
  end

  # --- .init_array / .fini_array -----------------------------------------

  # The aarch64 markers: each initializer appends its letter to a buffer the
  # consumer reads back after the on-target loader has run the array.
  MARKERS = <<~C
    char trace[16];
    int marked;
    void mark_a(void) { trace[marked] = 'A'; marked = marked + 1; }
    void mark_b(void) { trace[marked] = 'B'; marked = marked + 1; }
    char *trace_of(void) { return trace; }
  C

  # The slots are ABS64 initializers, so a PIC image rebases each with an
  # R_AARCH64_RELATIVE whose addend is the target function — aarch64's spelling
  # of the x86_64 case, through the same machine-independent array placement.
  def test_array_sections_and_tags_on_aarch64
    r = Reader.read(build_so([MARKERS], inputs: [array_object(".init_array", "mark_a"),
                                                 array_object(".fini_array", "mark_b")]))
    init = r.section(".init_array")
    fini = r.section(".fini_array")
    assert_equal SHT_INIT_ARRAY, init.type
    assert_equal SHT_FINI_ARRAY, fini.type
    assert_equal 8, init.entsize
    assert_equal 8, init.addralign

    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal init.addr, by_tag[DT_INIT_ARRAY]
    assert_equal 8, by_tag[DT_INIT_ARRAYSZ]
    assert_equal fini.addr, by_tag[DT_FINI_ARRAY]
    assert_equal 8, by_tag[DT_FINI_ARRAYSZ]

    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    slot = rela.relocations.find { |x| x.offset == init.addr }
    refute_nil slot, "the init slot must be rebased at load time"
    assert_equal R_AARCH64_RELATIVE, slot.type
    assert_equal r.dynamic_symbol("mark_a").value, slot.addend,
                 "the RELATIVE addend must be mark_a's address"
  end

  # The execution oracle: the real aarch64 loader under qemu must call the
  # initializers, in input order, before the consumer's main runs.
  def test_initializers_run_in_input_order_under_qemu
    skip_unless_aarch64_self_link

    consumer = <<~C
      #include <stdio.h>
      char *trace_of(void);
      int main(void) { printf("%s\\n", trace_of()); return 0; }
    C
    status, stdout = build_and_run_consumer(
      [MARKERS], "libinit.so", consumer,
      inputs: [array_object(".init_array", "mark_a"), array_object(".init_array", "mark_b")]
    )
    assert_equal 0, status
    assert_equal "AB\n", stdout, "both initializers ran, in the order they were linked"
  end

  # --- external imports (structure; needs the sysroot libc) --------------

  def test_external_function_gets_a_jump_slot_and_data_gets_a_glob_dat
    skip "aarch64 sysroot libc unavailable" unless libc_available?

    r = Reader.read(build_so([EXTERNAL], needed: [SYSROOT_LIBC]))

    plt = r.relocation_sections.find { |rs| rs.section.name == ".rela.plt" }
    refute_nil plt, ".rela.plt must hold the external-call bindings"
    assert_equal %w[puts strlen], plt.relocations.map { |x| x.symbol.name }.sort
    plt.relocations.each do |reloc|
      assert_equal R_AARCH64_JUMP_SLOT, reloc.type, "each external call binds through a JUMP_SLOT"
    end

    dyn = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    glob = dyn.relocations.select { |x| x.type == R_AARCH64_GLOB_DAT }
    assert_equal ["environ"], glob.map { |x| x.symbol.name }, "external data binds through a GLOB_DAT"
  end

  def test_resolved_import_pulls_in_dt_needed_and_bind_now
    skip "aarch64 sysroot libc unavailable" unless libc_available?

    r = Reader.read(build_so([EXTERNAL], needed: [SYSROOT_LIBC], soname: "libext.so"))
    # The aarch64-linux-gnu cross toolchain's sysroot is always glibc, so its
    # SONAME (SYSROOT_LIBC's basename) is the correct expectation here rather
    # than a hard-coded assumption about a host that could vary.
    assert_equal [File.basename(SYSROOT_LIBC)], r.needed, "the resolving dependency is a DT_NEEDED by SONAME"
    assert_equal "libext.so", r.soname

    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal DF_BIND_NOW, by_tag[DT_FLAGS] & DF_BIND_NOW, "DT_FLAGS must request BIND_NOW"
    assert_equal DF_1_NOW, by_tag[DT_FLAGS_1] & DF_1_NOW, "DT_FLAGS_1 must request DF_1_NOW"
  end

  # Each aarch64 .plt stub is the four-instruction sequence `adrp x16, page(slot)`
  # / `ldr x17, [x16, #lo12]` / `add x16, x16, #lo12` / `br x17`; the reconstructed
  # address must reach the stub's own .got.plt slot (the JUMP_SLOT offset).
  def test_plt_stub_encoding_reaches_its_got_plt_slot
    skip "aarch64 sysroot libc unavailable" unless libc_available?

    r = Reader.read(build_so([EXTERNAL], needed: [SYSROOT_LIBC]))
    plt = r.section(".plt")
    refute_nil plt
    assert_equal 2 * 16, plt.size, "one 16-byte stub per external function"

    rela = r.relocation_sections.find { |rs| rs.section.name == ".rela.plt" }
    rela.relocations.each_with_index do |reloc, i|
      words = plt.data[i * 16, 16].unpack("L<4")
      stub_vaddr = plt.addr + i * 16
      assert_equal 0xD61F0220, words[3], "stub #{i} ends in `br x17`"

      page_delta = adrp_page_delta(words[0])
      lo12 = (words[2] >> 10) & 0xFFF
      slot = (stub_vaddr & ~0xFFF) + page_delta + lo12
      assert_equal reloc.offset, slot, "stub #{i}'s adrp/add must reach its .got.plt slot"
    end
  end

  # The first reserved .got.plt slot holds &_DYNAMIC (spec convention).
  def test_got_plt_reserves_dynamic_pointer
    skip "aarch64 sysroot libc unavailable" unless libc_available?

    r = Reader.read(build_so([EXTERNAL], needed: [SYSROOT_LIBC]))
    gotplt = r.section(".got.plt")
    refute_nil gotplt
    assert_equal (3 + 2) * 8, gotplt.size, "three reserved slots then one per external function"
    assert_equal r.section(".dynamic").addr, gotplt.data[0, 8].unpack1("Q<"),
                 ".got.plt[0] is the &_DYNAMIC pointer"

    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    assert_equal gotplt.addr, by_tag[DT_PLTGOT], "DT_PLTGOT points at .got.plt"
    assert_equal r.section(".rela.plt").addr, by_tag[DT_JMPREL], "DT_JMPREL points at .rela.plt"
  end

  # --- execution: the loaded object is called under qemu ------------------

  # A self-contained object, loaded by the on-target loader, whose internal
  # calls, global read/write and returned string literal all compute as expected.
  def test_self_contained_exports_run_under_qemu
    skip_unless_aarch64_self_link

    consumer = <<~C
      #include <stdio.h>
      int add3(int,int,int); int quad(int);
      int get_counter(void); void set_counter(int); char *greeting(void);
      int main(void) {
        printf("%d\\n", add3(1, 2, 3));
        printf("%d\\n", quad(5));
        printf("%d\\n", get_counter());
        set_counter(99);
        printf("%d\\n", get_counter());
        printf("%s\\n", greeting());
        return 0;
      }
    C
    status, stdout = build_and_run_consumer([SELF_CONTAINED], "libself.so", consumer)
    assert_equal 0, status
    assert_equal "6\n20\n41\n99\nhello\n", stdout
  end

  # The cross-unit case: GOT-relative access to now-internal symbols, a call
  # through a GOT-loaded function pointer, and an ABS64 data pointer — all rebased
  # by R_AARCH64_RELATIVE at load time.
  def test_cross_unit_relative_rebasing_runs_under_qemu
    skip_unless_aarch64_self_link

    consumer = <<~C
      #include <stdio.h>
      int read_counter(void); void write_counter(int);
      int call_via_ptr(int); char *stored_message(void);
      int main(void) {
        printf("%d\\n", read_counter());
        write_counter(55);
        printf("%d\\n", read_counter());
        printf("%d\\n", call_via_ptr(42));
        printf("%s\\n", stored_message());
        return 0;
      }
    C
    status, stdout = build_and_run_consumer([ACCESS, DEFINE], "libmix.so", consumer)
    assert_equal 0, status
    assert_equal "100\n55\n43\nworld\n", stdout
  end

  # External imports: a libc call bound through a JUMP_SLOT (strlen, puts) and an
  # external data read bound through a GLOB_DAT (environ), all resolved eagerly by
  # the loader and reached through the rubycc-built .plt/.got.
  def test_external_imports_run_under_qemu
    skip_unless_aarch64_self_link

    consumer = <<~C
      #include <stdio.h>
      unsigned long my_len(const char *); int emit(const char *); int env_present(void);
      int main(void) {
        printf("%lu\\n", my_len("hello"));
        printf("%d\\n", emit("via imported puts") >= 0);
        printf("%d\\n", env_present());
        return 0;
      }
    C
    status, stdout = build_and_run_consumer([EXTERNAL], "libext.so", consumer,
                                            needed: [SYSROOT_LIBC])
    assert_equal 0, status
    assert_equal "5\nvia imported puts\n1\n1\n", stdout
  end

  private

  # Compiles each source for aarch64 under -fPIC, links them into a .so with
  # rubycc, and returns the .so bytes.
  def build_so(sources, needed: [], soname: nil, inputs: [])
    in_tmpdir do |dir|
      Linker.link(objects_for(sources, dir) + inputs, needed: needed, soname: soname)
    end
  end

  # The aarch64 counterpart of TestSharedObject#array_object: one array slot
  # bound to `func` by an ABS64, in an EM_AARCH64 object so the merge and the
  # final link keep the target's identity.
  def array_object(section, func)
    type = section.start_with?(".init_array") ? SHT_INIT_ARRAY : SHT_FINI_ARRAY
    w = Rubycc::ObjFile::RelocatableWriter.new(machine: EM_AARCH64)
    slot = w.add_section(name: section, type: type, flags: SHF_ALLOC | SHF_WRITE,
                         addralign: 8, entsize: 8, data: "\0" * 8)
    sym = w.add_symbol(name: func, bind: :global, type: :notype)
    w.add_relocation(target: slot, offset: 0, symbol: sym, type: R_AARCH64_ABS64, addend: 0)
    w.to_binary
  end

  # Compiles the sources, links them into a named .so with rubycc, builds a
  # consumer executable against it with the cross gcc and runs it under qemu.
  def build_and_run_consumer(sources, so_name, consumer_source, needed: [], inputs: [])
    in_tmpdir do |dir|
      objects = objects_for(sources, dir) + inputs
      so = File.join(dir, so_name)
      link_shared_aarch64_rubycc(objects, so, soname: so_name, needed: needed)
      run_against_aarch64_so(consumer_source, so)
    end
  end

  def objects_for(sources, dir)
    sources.each_with_index.map do |src, i|
      path = File.join(dir, "u#{i}.o")
      compile_with_rubycc_aarch64(src, path, pic: true)
      path
    end
  end

  # The dlopen counterpart of #build_and_run_consumer: the consumer is NOT
  # linked against the `.so` (it receives the path as argv[1] and loads it
  # itself), which is the only way to observe a real dlclose — the point of the
  # synthesized finalizer. Returns [exit_status, stdout].
  def run_dlopen_consumer(sources, so_name, consumer_source, needed: [SYSROOT_LIBC])
    in_tmpdir do |dir|
      so = File.join(dir, so_name)
      link_shared_aarch64_rubycc(objects_for(sources, dir), so, soname: so_name, needed: needed)

      consumer_c = File.join(dir, "consumer.c")
      File.write(consumer_c, consumer_source)
      exe = File.join(dir, "consumer")
      out, status = Open3.capture2e(
        AArch64ExecutionHelper::CROSS_GCC, consumer_c, "-o", exe, "-ldl",
        "-Wl,--dynamic-linker=#{AArch64ExecutionHelper::TARGET_INTERP}"
      )
      raise "#{AArch64ExecutionHelper::CROSS_GCC} failed to link the consumer:\n#{out}" unless status.success?

      stdout, run_status = Open3.capture2(
        { "QEMU_LD_PREFIX" => AArch64ExecutionHelper::SYSROOT },
        AArch64ExecutionHelper::QEMU, exe, so
      )
      [run_status.exitstatus, stdout]
    end
  end

  def libc_available?
    File.exist?(SYSROOT_LIBC)
  end

  # Decodes an `adrp`'s signed 21-bit page immediate into a byte page distance.
  def adrp_page_delta(word)
    imm = (((word >> 5) & 0x7FFFF) << 2) | ((word >> 29) & 0x3)
    imm -= (1 << 21) if imm & (1 << 20) != 0 # sign-extend the 21-bit field
    imm << 12
  end

  # Parses the ELF program header table straight from the image bytes.
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

  # Checks the PT_LOAD invariant every segment must uphold no matter what it
  # happens to contain: each allocatable section placed in it fits entirely
  # within its [p_vaddr, p_vaddr + p_memsz) memory extent and — unless it is
  # SHT_NOBITS and so carries no file bytes at all — within its
  # [p_offset, p_offset + p_filesz) file extent too. A section is matched to
  # the one segment whose memory extent contains its address; every
  # allocatable section must land in exactly one.
  def assert_sections_fit_their_load_segments(bytes)
    r = Reader.read(bytes)
    loads = program_headers(bytes).select { |p| p[:type] == 1 } # PT_LOAD

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

  def parse_hash(bytes)
    nbucket, nchain = bytes[0, 8].unpack("L<L<")
    words = bytes[8, (nbucket + nchain) * 4].unpack("L<*")
    [nbucket, nchain, words[0, nbucket], words[nbucket, nchain]]
  end

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
    Dir.mktmpdir("rubycc-aa-so", &block)
  end
end
