# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Acceptance tests for the A5 self-linker: rubycc compiles a source for the
# aarch64 target AND links the resulting object into a runnable executable with
# its OWN linker (Rubycc::Link::ExecutableLinker) and crt — no cross gcc, no
# cross ld. The prior A2-A4 execution suites link with the cross gcc; here the
# whole toolchain is rubycc's.
#
# Two layers are covered. Execution (the point): each source is built two ways —
# rubycc-compiled-and-self-linked, and cross-gcc-compiled-and-linked as the
# language oracle — run under qemu-aarch64, and the two runs must agree on exit
# status and stdout. Structure: the emitted image is read back through the
# project's own ELFReader and asserted to be a well-formed aarch64 ET_EXEC (the
# crt's _start at e_entry, libc.so.6 a default NEEDED, external calls bound
# through JUMP_SLOTs, no RELATIVE in a non-PIE image). The aarch64 *shared*
# object counterpart is covered by TestAArch64SharedObject.
#
# The run cases are skip-guarded on the sysroot loader/libc being available.
class TestAArch64SelfLink < Minitest::Test
  include AArch64ExecutionHelper

  Reader = Rubycc::ObjFile::ELFReader
  Linker = Rubycc::Link::ExecutableLinker

  EM_AARCH64 = 183
  ET_EXEC = 2
  PT_INTERP = 3

  R_AARCH64_RELATIVE  = 1027
  R_AARCH64_JUMP_SLOT = 1026

  # --- execution: the whole point ----------------------------------------

  # main's return value reaches the exit status through the crt marshalling into
  # __libc_start_main.
  def test_main_return_status
    assert_aarch64_self_link_matches_gcc("int main(void) { return 42; }")
  end

  # putchar: a single libc call reaching stdout, proving libc's stdio was
  # initialized by the crt before main ran.
  def test_putchar_reaches_stdout
    assert_aarch64_self_link_matches_gcc(<<~C)
      int putchar(int c);
      int main(void) { putchar('A'); putchar('\\n'); return 0; }
    C
  end

  # puts: a libc call taking a string literal (a .rodata reference resolved
  # through the adrp/add pair at link time).
  def test_puts_string_literal
    assert_aarch64_self_link_matches_gcc(<<~C)
      int puts(const char *s);
      int main(void) { return puts("self-linked") >= 0 ? 0 : 1; }
    C
  end

  # printf with mixed integer/string arguments, plus a non-zero return.
  def test_printf_and_return
    assert_aarch64_self_link_matches_gcc(<<~C)
      int printf(const char *, ...);
      int main(void) { printf("n=%d s=%s\\n", 7, "ok"); return 3; }
    C
  end

  # A conftest try_run pattern: compute with libc and signal success through the
  # exit status.
  def test_conftest_style_try_run
    assert_aarch64_self_link_matches_gcc(<<~C)
      unsigned long strlen(const char *s);
      int main(void) { return strlen("conftest") == 8 ? 0 : 1; }
    C
  end

  # A global scalar, a global array and a global string pointer, each an internal
  # adrp/add (or ABS64 .data slot) the non-PIE image resolves to a fixed address.
  def test_global_variables
    assert_aarch64_self_link_matches_gcc(<<~C)
      int printf(const char *, ...);
      int counter = 41;
      int table[3] = { 10, 20, 30 };
      char *label = "globals";
      int main(void) {
        printf("%d %d %s\\n", counter + table[2], table[0], label);
        return 0;
      }
    C
  end

  # argc/argv reach main through the crt, exactly as A5's __libc_start_main call
  # marshals x1/x2.
  def test_argc_reaches_main
    skip_unless_aarch64_self_link

    in_tmpdir do |dir|
      obj = File.join(dir, "argc.o")
      compile_with_rubycc_aarch64("int main(int argc, char **argv) { (void)argv; return argc; }", obj)
      exe = File.join(dir, "argc.rubycc.out")
      Linker.link_to([obj], exe)
      File.chmod(0o755, exe)
      _out, status = Open3.capture2(
        { "QEMU_LD_PREFIX" => AArch64ExecutionHelper::SYSROOT },
        AArch64ExecutionHelper::QEMU, exe, "x", "y", "z"
      )
      assert_equal 4, status.exitstatus, "argc must count the program name plus three arguments"
    end
  end

  # --- constructors / destructors (Step 155) ------------------------------

  # The whole aarch64 line: rubycc compiles `__attribute__((constructor))` into
  # SHT_INIT_ARRAY slots filled by R_AARCH64_ABS64, rubycc links them into a run
  # the loader finds through DT_INIT_ARRAY, and qemu runs it. The cross gcc build
  # of the same source is the oracle for the resulting order — the section names
  # encode it, so a wrong spelling would show up here as a wrong order rather
  # than as a link failure.
  CONSTRUCTORS = <<~C
    int puts(const char *s);
    __attribute__((constructor(200))) static void ctor_second(void) { puts("c200"); }
    __attribute__((constructor))      static void ctor_plain(void)  { puts("cplain"); }
    __attribute__((constructor(101))) static void ctor_first(void)  { puts("c101"); }
    __attribute__((destructor))       static void dtor_plain(void)  { puts("dplain"); }
    int main(void) { puts("main"); return 0; }
  C

  def test_constructors_run_in_priority_order
    assert_aarch64_self_link_matches_gcc(CONSTRUCTORS)
  end

  # ... and the order is asserted outright, not only against gcc, so the test
  # still says something on a host without the cross compiler.
  def test_constructor_output_is_the_recorded_order
    skip_unless_aarch64_self_link

    _status, stdout = run_aarch64_self_linked(CONSTRUCTORS)
    assert_equal "c101\nc200\ncplain\nmain\ndplain\n", stdout,
                 "numbered constructors ascend, the unnumbered one runs last, " \
                 "and the destructor runs at exit"
  end

  # --- multiple translation units ----------------------------------------

  # Two objects rubycc compiles separately, self-linked together: the caller's
  # internal CALL26 to the callee must resolve across the merge.
  def test_multiple_translation_units
    skip_unless_aarch64_self_link

    tu_main = <<~C
      int printf(const char *, ...);
      int helper(int x);
      int main(void) { printf("h=%d\\n", helper(20)); return 0; }
    C
    tu_helper = "int helper(int x) { return x * 2 + 2; }"

    rubycc = build_and_run_self_linked([tu_main, tu_helper])
    gcc = build_and_run_cross_gcc([tu_main, tu_helper])
    assert_equal gcc, rubycc, "self-linked multi-TU run must match the cross gcc build"
  end

  # --- A4 features through the self-linker --------------------------------

  # Floating point through a self-linked binary: v-register argument passing and
  # a printf("%f") of the result.
  def test_floating_point
    assert_aarch64_self_link_matches_gcc(<<~C)
      int printf(const char *, ...);
      double addd(double a, double b) { return a + b; }
      int main(void) { printf("%.3f\\n", addd(1.5, 2.25)); return 0; }
    C
  end

  # struct-by-value across the ABI: an HFA of two floats (s0/s1) and a small
  # integer struct (packed into a register pair), both A4 features, exercised end
  # to end through rubycc's own link.
  def test_struct_by_value
    assert_aarch64_self_link_matches_gcc(<<~C)
      int printf(const char *, ...);
      struct Point { float x, y; };
      struct Pair { int a, b; };
      float hfa_sum(struct Point p) { return p.x + p.y; }
      int pair_sum(struct Pair p) { return p.a + p.b; }
      int main(void) {
        struct Point p = { 1.5f, 2.5f };
        struct Pair q = { 10, 32 };
        printf("%.1f %d\\n", (double)hfa_sum(p), pair_sum(q));
        return 0;
      }
    C
  end

  # --- structure of the emitted image ------------------------------------

  def test_emits_aarch64_et_exec_entered_at_start
    r = Reader.read(build_exe("int main(void) { return 0; }"))
    assert_equal EM_AARCH64, r.machine, "the image is an aarch64 object"
    assert r.executable?, "output must be ET_EXEC"
    # _start leads .text, so e_entry is the .text load address.
    assert_equal r.section(".text").addr, r.entry, "e_entry must point at _start (head of .text)"
  end

  def test_libc_is_a_default_needed
    r = Reader.read(build_exe("int main(void) { return 0; }"))
    assert_includes r.needed, "libc.so.6", "libc is a default dependency (it defines __libc_start_main)"
  end

  def test_external_calls_bind_through_jump_slots
    src = <<~C
      int puts(const char *s);
      int main(void) { return puts("x") >= 0 ? 0 : 1; }
    C
    r = Reader.read(build_exe(src))
    plt = r.relocation_sections.find { |rs| rs.section.name == ".rela.plt" }
    refute_nil plt, ".rela.plt must hold the external-call bindings"
    names = plt.relocations.map { |x| x.symbol.name }.sort
    assert_equal %w[__libc_start_main puts], names
    plt.relocations.each do |reloc|
      assert_equal R_AARCH64_JUMP_SLOT, reloc.type, "each external call binds through a JUMP_SLOT"
    end
  end

  # A non-PIE aarch64 executable writes internal absolute addresses directly, so
  # it emits no R_AARCH64_RELATIVE base relocation.
  def test_non_pie_emits_no_relative_relocations
    src = <<~C
      int puts(const char *s);
      char *msg = "table";
      int main(void) { return puts(msg) >= 0 ? 0 : 1; }
    C
    r = Reader.read(build_exe(src))
    dyn = r.relocation_sections.find { |rs| rs.section.name == ".rela.dyn" }
    if dyn
      refute_includes dyn.relocations.map(&:type), R_AARCH64_RELATIVE,
                      "a non-PIE aarch64 executable emits no RELATIVE relocation"
    end
  end

  def test_names_the_aarch64_loader_in_interp
    bytes = build_exe("int main(void) { return 0; }")
    phdrs = program_headers(bytes)
    interp = phdrs.find { |p| p[:type] == PT_INTERP }
    refute_nil interp, "an executable must name its dynamic loader in PT_INTERP"
    path = bytes.b.byteslice(interp[:offset], interp[:filesz]).sub(/\0\z/, "")
    assert_equal "/lib/ld-linux-aarch64.so.1", path
  end

  def test_output_is_byte_identical_for_identical_inputs
    a = build_exe("int puts(const char*s); int main(void){ return puts(\"d\"); }")
    b = build_exe("int puts(const char*s); int main(void){ return puts(\"d\"); }")
    assert_equal a, b, "identical inputs must yield byte-identical executables"
  end

  private

  # Builds an executable image (bytes) from a single source with the self-linker.
  # Structural tests do not run the binary, but the linker still resolves its
  # libc import against the sysroot's libc.so.6, so they guard on the same
  # sysroot the run tests need.
  def build_exe(source)
    skip_unless_aarch64_self_link
    in_tmpdir do |dir|
      obj = File.join(dir, "u.o")
      compile_with_rubycc_aarch64(source, obj)
      Linker.link([obj])
    end
  end

  def build_and_run_self_linked(sources)
    in_tmpdir do |dir|
      objs = compile_all(sources, dir)
      exe = File.join(dir, "multi.rubycc.out")
      Linker.link_to(objs, exe)
      File.chmod(0o755, exe)
      Open3.capture2({ "QEMU_LD_PREFIX" => AArch64ExecutionHelper::SYSROOT },
                     AArch64ExecutionHelper::QEMU, exe)
    end
  end

  def build_and_run_cross_gcc(sources)
    in_tmpdir do |dir|
      objs = sources.each_with_index.map do |src, i|
        compile_with_cross_gcc(src, File.join(dir, "g#{i}.o"))
      end
      exe = File.join(dir, "multi.gcc.out")
      _o, status = Open3.capture2e(AArch64ExecutionHelper::CROSS_GCC, "-static", "-o", exe, *objs)
      raise "cross gcc link failed" unless status.success?

      Open3.capture2(AArch64ExecutionHelper::QEMU, exe)
    end
  end

  def compile_all(sources, dir)
    sources.each_with_index.map do |src, i|
      obj = File.join(dir, "u#{i}.o")
      compile_with_rubycc_aarch64(src, obj)
      obj
    end
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
        offset: bytes[base + 8, 8].unpack1("Q<"),
        filesz: bytes[base + 32, 8].unpack1("Q<")
      }
    end
  end

  def in_tmpdir(&block)
    Dir.mktmpdir("rubycc-aa-selflink", &block)
  end
end
