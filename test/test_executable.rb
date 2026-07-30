# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"

# Exercises the executable writer (Rubycc::Link::ExecutableLinker): it turns
# rubycc-compiled relocatable objects into a dynamically-linked, non-PIE ET_EXEC
# that the kernel and a runtime loader can map and run — the piece mkmf's
# conftest (try_link / try_run) needs.
#
# Three layers are covered. Structure: the emitted image is read back through
# the project's own ELFReader and asserted (ET_EXEC, e_entry at _start, the
# imports as UND .dynsym entries, the __libc_start_main JUMP_SLOT, DT_NEEDED
# libc.so.6, no R_X86_64_RELATIVE because a non-PIE image needs no base
# relocation), and the program headers are parsed directly for the load
# permissions and the PT_INTERP loader path. Determinism: identical inputs
# yield byte-identical executables, and the synthesized _start is a fixed byte
# sequence. Acceptance (the real point): compiled C is linked, made executable
# and actually run, its exit status and stdout checked — including a gcc-built
# counterpart for cross-verification. The run and gcc cases are skip-guarded.
class TestExecutable < Minitest::Test
  Reader = Rubycc::ObjFile::ELFReader
  Linker = Rubycc::Link::ExecutableLinker

  PAGE = 0x1000
  LOAD_BASE = 0x400000

  PT_LOAD   = 1
  PT_INTERP = 3
  PT_DYNAMIC = 2
  PT_GNU_STACK = 0x6474E551
  PF_X = 0x1
  PF_W = 0x2
  PF_R = 0x4

  R_X86_64_RELATIVE  = 8
  R_X86_64_JUMP_SLOT = 7
  R_X86_64_64        = 1
  DT_NEEDED = 1

  # The initializer/finalizer array section types, their flags, and the four
  # dynamic tags addressing them (sizes in bytes).
  SHT_INIT_ARRAY  = 14
  SHT_FINI_ARRAY  = 15
  SHF_WRITE       = 0x1
  SHF_ALLOC       = 0x2
  DT_INIT_ARRAY   = 25
  DT_FINI_ARRAY   = 26
  DT_INIT_ARRAYSZ = 27
  DT_FINI_ARRAYSZ = 28

  RETURN_42 = "int main(void){ return 42; }"

  # A conftest-style program that both links against libc (puts) and returns a
  # status, exercising libc initialization through __libc_start_main.
  USES_PUTS = <<~C
    int puts(const char *s);
    int main(void) { return puts("hi") >= 0 ? 0 : 1; }
  C

  # --- structure ----------------------------------------------------------

  def test_emits_et_exec_entered_at_start
    skip_unless_linkable

    r = Reader.read(build_exe([RETURN_42]))
    assert r.executable?, "output must be ET_EXEC"
    assert_equal LOAD_BASE, r.section(".text").addr & ~(PAGE - 1), "text loads within the fixed base page range"
    # _start leads .text, so the entry is the .text load address.
    assert_equal r.section(".text").addr, r.entry, "e_entry must point at _start (the head of .text)"
    assert_operator r.entry, :>=, LOAD_BASE
  end

  def test_libc_start_main_is_an_undefined_import
    skip_unless_linkable

    r = Reader.read(build_exe([RETURN_42]))
    sym = r.dynamic_symbol("__libc_start_main")
    refute_nil sym, "__libc_start_main must be imported into .dynsym"
    assert sym.undefined?, "__libc_start_main is imported, so its .dynsym entry is UND"
    assert_equal 0, sym.value
  end

  def test_executable_exports_nothing
    skip_unless_linkable

    r = Reader.read(build_exe([RETURN_42]))
    # main and _start are reached internally, never exported; only imports remain.
    defined_named = r.dynamic_symbols.select { |s| s.defined? && !s.name.to_s.empty? }
    assert_empty defined_named, "an executable exports no defined symbol"
    refute_nil r.dynamic_symbol("__libc_start_main")
  end

  def test_external_call_binds_through_a_jump_slot
    skip_unless_linkable

    r = Reader.read(build_exe([USES_PUTS]))
    plt = r.relocation_sections.find { |rs| rs.section.name == ".rela.plt" }
    refute_nil plt, ".rela.plt must hold the external-call bindings"
    names = plt.relocations.map { |x| x.symbol.name }.sort
    assert_equal %w[__libc_start_main puts], names
    plt.relocations.each do |reloc|
      assert_equal R_X86_64_JUMP_SLOT, reloc.type, "each external call binds through a JUMP_SLOT"
    end
  end

  def test_libc_is_a_default_needed
    skip_unless_linkable

    r = Reader.read(build_exe([RETURN_42]))
    assert_includes r.needed, "libc.so.6", "libc is a default dependency (it defines __libc_start_main)"
  end

  # A non-PIE executable is mapped at its exact link-time address, so no internal
  # absolute reference needs an R_X86_64_RELATIVE base relocation. A program that
  # only calls libc therefore has no .rela.dyn at all.
  def test_non_pie_emits_no_relative_relocations
    skip_unless_linkable

    r = Reader.read(build_exe([USES_PUTS]))
    dyn = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    if dyn
      refute_includes dyn.relocations.map(&:type), R_X86_64_RELATIVE,
                      "a non-PIE executable emits no RELATIVE relocation"
    end
  end

  # An internal absolute data pointer (R_X86_64_64) is written with its final
  # value at link time and, unlike in a shared object, carries no RELATIVE.
  def test_internal_data_pointer_is_resolved_without_a_relative
    skip_unless_linkable

    src = <<~C
      int puts(const char *s);
      char *msg = "table";
      int main(void) { return puts(msg) >= 0 ? 0 : 1; }
    C
    r = Reader.read(build_exe([src]))
    dyn = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    assert_nil dyn, "an internal data pointer needs no dynamic relocation in a non-PIE executable"
  end

  # --- __dso_handle synthesis --------------------------------------------

  # An executable link pulls glibc's libc_nonshared.a members in too, and they
  # reference __dso_handle; nothing else defines it, so the linker supplies the
  # same word here as in a shared object. A non-PIE image is mapped at its exact
  # link-time address, so the word holds its final address outright and carries
  # no RELATIVE — the one difference from the `.so` case.
  DSO_HANDLE_USER = <<~C
    extern void *__dso_handle;
    int main(void) { return __dso_handle == &__dso_handle ? 0 : 1; }
  C

  # pthread_atfork, the case that exposed the gap: glibc supplies it only from
  # libc_nonshared.a, whose member registers the handlers under __dso_handle.
  ATFORK = <<~C
    int pthread_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void));
    int printf(const char *, ...);
    int fork(void);
    int wait(int *status);
    void _exit(int status);
    static int seen;
    static void on_prepare(void) { seen |= 1; }
    static void on_parent(void) { seen |= 2; }
    static void on_child(void) { seen |= 4; }
    int main(void) {
      int status;
      if (pthread_atfork(on_prepare, on_parent, on_child) != 0) return 1;
      if (fork() == 0) _exit(seen);
      wait(&status);
      printf("%d\\n", seen);
      return 0;
    }
  C

  def test_dso_handle_is_synthesized_without_a_relative
    skip_unless_linkable

    r = Reader.read(build_exe([DSO_HANDLE_USER]))
    data = r.section(".data")
    refute_nil data, "the synthesized word lives in .data"
    assert_equal 8, data.size, "one 8-byte handle word and nothing else"
    assert_equal data.addr, data.data.unpack1("Q<"),
                 "a non-PIE image writes the word's final address directly"
    assert_nil r.dynamic_symbol("__dso_handle"), "__dso_handle must not enter .dynsym"

    dyn = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    assert_nil dyn, "the fixed load address needs no base relocation"
  end

  def test_running_reads_the_handle_as_its_own_address
    skip_unless_runnable

    with_exe([DSO_HANDLE_USER]) do |exe|
      _out, status = Open3.capture2(exe)
      assert_equal 0, status.exitstatus, "__dso_handle must read back as its own address"
    end
  end

  # End to end on the case that exposed the gap: pthread_atfork comes from
  # libc_nonshared.a, whose member references __dso_handle; the program must
  # link, run, and see its handlers run across a real fork.
  def test_pthread_atfork_from_libc_nonshared_links_and_runs
    skip_unless_runnable
    skip "libc_nonshared.a unavailable" unless libc_nonshared_path

    with_exe([ATFORK], inputs: [libc_nonshared_path]) do |exe|
      out, status = Open3.capture2(exe)
      assert_equal 0, status.exitstatus
      assert_equal "3\n", out, "the prepare and parent handlers must have run"
    end
  end

  # --- .init_array / .fini_array -----------------------------------------

  # An executable carries the same four array tags a shared object does — the
  # loader, not the crt, walks them (this _start passes init/fini as NULL to
  # __libc_start_main and the constructor still runs). The one difference is the
  # non-PIE image's slots: mapped at a fixed address, each holds its function's
  # final address outright and needs no RELATIVE.
  ARRAY_USER = <<~C
    int puts(const char *s);
    static int ran;
    void note_start(void) { ran = 1; }
    void note_end(void) { puts("fini"); }
    int main(void) { puts(ran ? "init" : "MISSING"); return ran ? 0 : 1; }
  C

  def test_executable_emits_the_array_tags_without_a_relative
    skip_unless_linkable

    r = Reader.read(build_exe([ARRAY_USER], inputs: [array_object(".init_array", "note_start"),
                                                     array_object(".fini_array", "note_end")]))
    by_tag = r.dynamic_entries.to_h { |e| [e.tag, e.value] }
    init = r.section(".init_array")
    assert_equal init.addr, by_tag[DT_INIT_ARRAY]
    assert_equal 8, by_tag[DT_INIT_ARRAYSZ]
    assert_equal r.section(".fini_array").addr, by_tag[DT_FINI_ARRAY]
    assert_equal 8, by_tag[DT_FINI_ARRAYSZ]

    # The executable keeps no symbol table, so the slot is checked by range: a
    # non-PIE image writes the final address, which must land inside .text.
    text = r.section(".text")
    slot = init.data.unpack1("Q<")
    assert_operator slot, :>=, text.addr, "the slot holds a final address, not zero"
    assert_operator slot, :<, text.addr + text.size, "which points into .text"
    dyn = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    assert_nil dyn, "the fixed load address needs no base relocation"
  end

  # The acceptance: the constructor must actually run before main and the
  # destructor after it.
  def test_running_executes_the_initializer_before_main_and_the_finalizer_after
    skip_unless_runnable

    with_exe([ARRAY_USER], inputs: [array_object(".init_array", "note_start"),
                                    array_object(".fini_array", "note_end")]) do |exe|
      out, status = Open3.capture2(exe)
      assert_equal 0, status.exitstatus, "the initializer must have run before main"
      assert_equal "init\nfini\n", out,
                   "the initializer runs before main and the finalizer at exit"
    end
  end

  def test_executable_without_arrays_gains_no_tag
    skip_unless_linkable

    tags = Reader.read(build_exe([USES_PUTS])).dynamic_entries.map(&:tag)
    [DT_INIT_ARRAY, DT_INIT_ARRAYSZ, DT_FINI_ARRAY, DT_FINI_ARRAYSZ].each do |tag|
      refute_includes tags, tag, "an array tag must not appear without an array section"
    end
  end

  # --- program headers ----------------------------------------------------

  def test_load_segments_and_interp
    skip_unless_linkable

    bytes = build_exe([RETURN_42])
    phdrs = program_headers(bytes)

    loads = phdrs.select { |p| p[:type] == PT_LOAD }
    assert_equal 3, loads.size
    assert_equal PF_R | PF_X, loads[0][:flags], "first segment (header + .interp + .text) is r-x"
    assert_equal PF_R,        loads[1][:flags], "second segment (rodata + dyn) is r--"
    assert_equal PF_R | PF_W, loads[2][:flags], "third segment (data/got/dynamic) is rw-"
    assert_equal LOAD_BASE, loads[0][:vaddr], "the first load maps the header at the fixed base"

    loads.each do |p|
      assert_equal p[:offset] % PAGE, p[:vaddr] % PAGE, "p_vaddr must be congruent to p_offset mod page"
    end

    interp = phdrs.find { |p| p[:type] == PT_INTERP }
    refute_nil interp, "an executable must name its dynamic loader in PT_INTERP"
    path = bytes.b.byteslice(interp[:offset], interp[:filesz]).sub(/\0\z/, "")
    assert File.exist?(path), "the PT_INTERP loader path must exist on the host: #{path}"

    stack = phdrs.find { |p| p[:type] == PT_GNU_STACK }
    assert_equal 0, stack[:flags] & PF_X, "the stack must be non-executable"
  end

  # The r-x segment maps from file offset 0, so its file size must span the whole
  # header/.interp/.text run (a load whose filesz stopped short would leave the
  # entry unmapped on a larger program).
  def test_first_load_covers_the_header_and_text
    skip_unless_linkable

    bytes = build_exe([RETURN_42])
    r = Reader.read(bytes)
    rx = program_headers(bytes).find { |p| p[:type] == PT_LOAD }
    text = r.section(".text")
    text_end = text.offset + text.size
    assert_operator rx[:filesz], :>=, text_end, "the r-x load must cover .text"
    assert_equal 0, rx[:offset], "the r-x load starts at file offset 0"
  end

  # --- determinism and the crt -------------------------------------------

  def test_output_is_byte_identical_for_identical_inputs
    skip_unless_linkable

    assert_equal build_exe([USES_PUTS]), build_exe([USES_PUTS]),
                 "identical inputs must yield byte-identical executables"
  end

  # _start's fixed opcodes: the xor of the frame pointer at the head, the
  # mov-immediate that receives main's address, the call to __libc_start_main,
  # and the trailing hlt. The two operands (the imm32 and the rel32) are the only
  # bytes the linker fills, so only the opcodes are asserted.
  def test_start_stub_encoding
    skip_unless_linkable

    r = Reader.read(build_exe([RETURN_42]))
    text = r.section(".text").data
    assert_equal "\x31\xED".b, text[0, 2], "_start begins by zeroing ebp (the outermost frame)"
    assert_equal 0xBF, text.getbyte(20), "mov edi, imm32 loads main's absolute address"
    assert_equal 0xE8, text.getbyte(25), "call rel32 invokes __libc_start_main"
    assert_equal 0xF4, text.getbyte(30), "_start ends in hlt (__libc_start_main never returns)"

    # The call's rel32 must reach into .plt (the __libc_start_main stub).
    rel = text[26, 4].unpack1("l<")
    call_site = r.section(".text").addr + 26
    target = call_site + 4 + rel
    plt = r.section(".plt")
    assert_operator target, :>=, plt.addr, "the call must target a .plt stub"
    assert_operator target, :<, plt.addr + plt.size
  end

  # --- run acceptance (the whole point) ----------------------------------

  def test_running_returns_mains_status
    skip_unless_runnable

    with_exe([RETURN_42]) do |exe|
      _out, status = Open3.capture2(exe)
      assert_equal 42, status.exitstatus, "the process exit code must be main's return value"
    end
  end

  def test_libc_initialized_puts_reaches_stdout
    skip_unless_runnable

    with_exe([USES_PUTS]) do |exe|
      out, status = Open3.capture2(exe)
      assert_equal "hi\n", out, "puts must reach stdout, proving libc's stdio was initialized"
      assert_equal 0, status.exitstatus
    end
  end

  def test_printf_and_return_status
    skip_unless_runnable

    src = <<~C
      int printf(const char *, ...);
      int main(void) { printf("n=%d s=%s\\n", 7, "ok"); return 3; }
    C
    with_exe([src]) do |exe|
      out, status = Open3.capture2(exe)
      assert_equal "n=7 s=ok\n", out
      assert_equal 3, status.exitstatus
    end
  end

  # argc/argv reach main through the crt marshalling, the way a try_run probe
  # that inspects its arguments would rely on.
  def test_argc_reaches_main
    skip_unless_runnable

    src = "int main(int argc, char **argv) { (void)argv; return argc; }"
    with_exe([src]) do |exe|
      _out, status = Open3.capture2(exe, "a", "b", "c")
      assert_equal 4, status.exitstatus, "argc must include the program name plus three arguments"
    end
  end

  # A conftest try_run pattern: a probe that computes something with libc and
  # signals success through the exit status.
  def test_conftest_style_try_run
    skip_unless_runnable

    src = <<~C
      unsigned long strlen(const char *s);
      int main(void) { return strlen("conftest") == 8 ? 0 : 1; }
    C
    with_exe([src]) do |exe|
      _out, status = Open3.capture2(exe)
      assert_equal 0, status.exitstatus, "the probe must run libc code and succeed"
    end
  end

  # A missing main is diagnosed rather than producing a broken executable.
  def test_missing_main_is_diagnosed
    skip_unless_linkable

    in_tmpdir do |dir|
      obj = objects_for(["int helper(void){ return 1; }"], dir).first
      err = assert_raises(Rubycc::Link::LinkError) { Linker.link([obj]) }
      assert_match(/main/, err.message)
    end
  end

  # --- gcc interop --------------------------------------------------------

  def test_matches_gcc_exit_code_and_stdout
    skip_unless_runnable
    skip "gcc unavailable" unless tool?("gcc")

    src = <<~C
      int puts(const char *s);
      int main(void) { return puts("interop") >= 0 ? 7 : 1; }
    C
    in_tmpdir do |dir|
      ours = File.join(dir, "ours")
      Linker.link_to(objects_for([src], dir), ours)
      File.chmod(0o755, ours)

      csrc = File.join(dir, "p.c")
      File.write(csrc, src)
      theirs = File.join(dir, "theirs")
      out, status = Open3.capture2e("gcc", "-no-pie", "-o", theirs, csrc)
      skip "gcc failed:\n#{out}" unless status.success?

      our_out, our_status = Open3.capture2(ours)
      gcc_out, gcc_status = Open3.capture2(theirs)
      assert_equal gcc_out, our_out, "stdout must match gcc's"
      assert_equal gcc_status.exitstatus, our_status.exitstatus, "exit code must match gcc's"
    end
  end

  private

  # Links `sources` (compiled here) into an executable. `inputs` appends further
  # link inputs — an archive path, say — after the compiled objects, in the
  # position a driver would place a library.
  def build_exe(sources, inputs: [])
    in_tmpdir { |dir| Linker.link(objects_for(sources, dir) + inputs) }
  end

  def with_exe(sources, inputs: [])
    in_tmpdir do |dir|
      exe = File.join(dir, "a.out")
      Linker.link_to(objects_for(sources, dir) + inputs, exe)
      File.chmod(0o755, exe)
      yield exe
    end
  end

  # glibc's libc_nonshared.a, the static half of the C library the linker script
  # names alongside libc.so.6; nil when the host has no such file. It is what
  # supplies pthread_atfork — and what references __dso_handle.
  def libc_nonshared_path
    return @libc_nonshared_path if defined?(@libc_nonshared_path)

    @libc_nonshared_path = ["/usr/lib/x86_64-linux-gnu/libc_nonshared.a",
                            "/usr/lib64/libc_nonshared.a",
                            "/usr/lib/libc_nonshared.a"].find { |p| File.exist?(p) }
  end

  def objects_for(sources, dir)
    sources.each_with_index.map do |src, i|
      path = File.join(dir, "u#{i}.o")
      File.binwrite(path, Rubycc::Compiler.new.compile(src, filename: "u#{i}.c"))
      path
    end
  end

  # A relocatable object holding one initializer-array slot pointing at `func`,
  # as a compiler emits one; built directly because rubycc's front end cannot yet
  # emit these sections. See TestSharedObject#array_object.
  def array_object(section, func)
    type = section.start_with?(".init_array") ? SHT_INIT_ARRAY : SHT_FINI_ARRAY
    w = Rubycc::ObjFile::RelocatableWriter.new
    slot = w.add_section(name: section, type: type, flags: SHF_ALLOC | SHF_WRITE,
                         addralign: 8, entsize: 8, data: "\0" * 8)
    sym = w.add_symbol(name: func, bind: :global, type: :notype)
    w.add_relocation(target: slot, offset: 0, symbol: sym, type: R_X86_64_64, addend: 0)
    w.to_binary
  end

  # The host must supply a dynamic loader and a libc for the writer to link at
  # all; without them the emitted executable could not run and the writer raises.
  def skip_unless_linkable
    skip "no dynamic loader / libc on host" unless linkable?
  end

  # Running additionally requires a Linux host (the ET_EXEC is Linux/x86_64).
  def skip_unless_runnable
    skip "not a Linux host" unless RUBY_PLATFORM.include?("linux")
    skip_unless_linkable
  end

  def linkable?
    interp = ["/lib64/ld-linux-x86-64.so.2", "/lib/ld-musl-x86_64.so.1"].any? { |p| File.exist?(p) }
    libc = Rubycc::Link::ExecutableLinker::DEFAULT_LIBC_PATHS.any? { |p| File.exist?(p) }
    interp && libc
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
        memsz: bytes[base + 40, 8].unpack1("Q<")
      }
    end
  end

  def in_tmpdir(&block)
    Dir.mktmpdir("rubycc-exe", &block)
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
