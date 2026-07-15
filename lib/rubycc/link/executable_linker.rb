# frozen_string_literal: true

module Rubycc
  module Link
    # The final-link core for a runnable program: it turns rubycc-compiled
    # relocatable objects into a dynamically-linked, non-PIE ET_EXEC that the
    # kernel and a runtime loader can map and run. Its purpose is narrow — passing
    # mkmf's conftest probes (try_link / try_run) — not producing a
    # general-quality executable, so it takes the simplest correct choices at
    # every fork: a fixed load address, no PIE, and a minimal crt.
    #
    # It reuses SharedLinker's machinery wholesale — the relocation scan, the
    # import resolution against dependency `.so`s, the three-segment page-aligned
    # layout, the byte-patching apply engine, and the .dynsym/.hash/.dynamic
    # tables — and only overrides the handful of decisions where an executable
    # differs from a shared object, expressed through SharedLinker's subclass
    # hooks. Those differences are:
    #
    #   * ET_EXEC at a fixed non-PIE base (0x400000). Because the program is mapped
    #     at exactly this address, every internal absolute reference (R_X86_64_64 /
    #     32 / 32S) is resolved to its final value at link time and needs no
    #     R_X86_64_RELATIVE base relocation — the single largest simplification a
    #     non-PIE image buys. External functions and data still bind through the
    #     PLT/GOT with JUMP_SLOT / GLOB_DAT, exactly as in a shared object.
    #
    #   * A PT_INTERP segment naming the dynamic loader, and a synthesized crt
    #     whose _start hands control to libc through __libc_start_main so the C
    #     runtime (TLS, atexit, stdio, the environment) is initialized before main
    #     runs. _start is entered at e_entry and lives at the front of .text.
    #
    #   * libc is a default dependency: _start's call to __libc_start_main makes
    #     the C library a necessary import, so it is added to `needed` unless the
    #     caller already supplied it (mirroring how a compiler driver links libc
    #     implicitly).
    #
    #   * The executable exports nothing — _start and main are reached internally,
    #     never looked up by a loader — so .dynsym holds only the imports.
    #
    # Output is deterministic (N4): the crt bytes are fixed, the layout and tables
    # inherit SharedLinker's deterministic order, and the recorded DT_NEEDED is the
    # dependency's SONAME string, independent of where libc was found on the host.
    class ExecutableLinker < SharedLinker
      # ELF type of a runnable program and the load base a non-PIE executable is
      # mapped at by convention (page-aligned, so the p_vaddr ≡ p_offset (mod page)
      # constraint holds trivially).
      ET_EXEC   = 2
      LOAD_BASE = 0x400000

      # Program header type naming the dynamic loader to run this executable.
      PT_INTERP = 3

      # The dynamic loaders this recognizes, tried in order; the first that exists
      # on the host is chosen unless the caller names one explicitly.
      GLIBC_INTERP = "/lib64/ld-linux-x86-64.so.2"
      MUSL_INTERP  = "/lib/ld-musl-x86_64.so.1"

      # The usual filesystem locations of the C library, consulted (in order) to
      # add libc as a default dependency. Only the SONAME the chosen file carries
      # affects the output, so which path matches does not disturb determinism.
      DEFAULT_LIBC_PATHS = [
        "/lib/x86_64-linux-gnu/libc.so.6",
        "/lib64/libc.so.6",
        "/usr/lib/x86_64-linux-gnu/libc.so.6",
        "/usr/lib/libc.so.6",
        "/lib/libc.so.6"
      ].freeze

      # The synthesized _start, assembled from the System V x86-64 process-startup
      # ABI (not copied from any crt implementation): the loader enters here with
      # argc/argv/envp on the stack and rdx = rtld_fini, and this marshals them
      # into the classic __libc_start_main(main, argc, argv, init, fini, rtld_fini,
      # stack_end) call that transfers control to libc — which initializes the C
      # runtime and eventually calls main. The two operands the linker fills in are
      # main's absolute address (non-PIE, R_X86_64_32) and the PC-relative call to
      # the imported __libc_start_main (R_X86_64_PLT32). Stack alignment tracks the
      # ABI: rsp is 16-byte aligned at entry, so after popping argc it is realigned
      # and re-padded so that %rsp is 16-byte aligned at the call site.
      START_CODE = [
        0x31, 0xED,             # xor  ebp, ebp          ; mark the outermost stack frame
        0x49, 0x89, 0xD1,       # mov  r9, rdx           ; r9 = rtld_fini (loader-supplied)
        0x5E,                   # pop  rsi               ; rsi = argc (top of the entry stack)
        0x48, 0x89, 0xE2,       # mov  rdx, rsp          ; rdx = argv (just above argc)
        0x48, 0x83, 0xE4, 0xF0, # and  rsp, -16          ; realign the stack down to 16 bytes
        0x50,                   # push rax               ; padding to preserve 16-byte alignment
        0x54,                   # push rsp               ; stack_end (7th arg, passed on the stack)
        0x45, 0x31, 0xC0,       # xor  r8d, r8d          ; fini = NULL
        0x31, 0xC9,             # xor  ecx, ecx          ; init = NULL
        0xBF, 0, 0, 0, 0,       # mov  edi, main         ; edi = main's absolute address (R_X86_64_32)
        0xE8, 0, 0, 0, 0,       # call __libc_start_main ; through the PLT (R_X86_64_PLT32)
        0xF4                    # hlt                    ; __libc_start_main does not return
      ].pack("C*").freeze

      # Byte offsets of the two operands the linker patches: the mov's imm32 and
      # the call's rel32, each four bytes wide.
      MAIN_IMM_OFFSET       = 21
      LIBC_START_REL_OFFSET = 26

      class << self
        # Links `inputs` (paths or raw ET_REL/ar bytes, as PartialLinker accepts)
        # into an executable, returned as an ASCII-8BIT String. `needed` lists
        # dependency shared objects to bind imports against; `interpreter` overrides
        # the dynamic-loader path; `libc` names the C library (`:auto` discovers it,
        # `nil` assumes the caller supplied it through `needed`, a path uses it).
        def link(inputs, needed: [], interpreter: nil, libc: :auto)
          new(inputs, needed: needed, interpreter: interpreter, libc: libc).link
        end

        # Convenience: link and write the executable to `path`.
        def link_to(inputs, path, needed: [], interpreter: nil, libc: :auto)
          File.binwrite(path, link(inputs, needed: needed, interpreter: interpreter, libc: libc))
        end
      end

      def initialize(inputs, needed: [], interpreter: nil, libc: :auto)
        super(inputs, needed: needed)
        @interpreter = choose_interpreter(interpreter)
        add_default_libc(libc)
      end

      private

      # --- SharedLinker hook overrides ---------------------------------------

      # An executable prepends the synthesized crt so _start (and its references
      # to main and __libc_start_main) take part in the merge and the shared
      # relocation pipeline handles them like any other input's relocations.
      def link_inputs
        [build_crt] + @inputs
      end

      # After the merge, require a defined main (a conftest without one cannot be
      # started) and capture _start for the entry point.
      def after_merge
        main = @reader.symbol("main")
        unless main&.defined?
          raise LinkError, "undefined reference to `main' (an executable needs a main to start)"
        end

        @start_symbol = @reader.symbol("_start") or
          raise LinkError, "the synthesized _start is missing from the merged object"
      end

      def load_base = LOAD_BASE
      def e_type = ET_EXEC
      def e_entry = symbol_address(@start_symbol)

      # A non-PIE executable is mapped at its exact link-time address, so internal
      # absolute references are already final — no R_X86_64_RELATIVE base
      # relocation is emitted for them.
      def rebase_internal? = false

      # An executable exports nothing: _start and main are reached through
      # link-time PC-relative and absolute relocations, never looked up by a
      # loader, so .dynsym carries only the imports.
      def plan_dynamic_symbols
        @exports = []
      end

      # .interp leads .text in the first (r-x) load segment so the loader path is
      # mapped with the ELF header and program headers.
      def leading_sections
        [placed_generated(".interp", SHT_PROGBITS, SHF_ALLOC, 1, 0, interp_bytes.bytesize)]
      end

      # .interp is synthesized (no input backs it), so supply its bytes here; every
      # other section falls through to the shared writer.
      def section_bytes(sec)
        return interp_bytes if sec.name == ".interp"

        super
      end

      # An executable adds one program header over a shared object's five: the
      # PT_INTERP naming the dynamic loader.
      def phnum = 6

      # The program header table: the three page-aligned load segments (r-x with
      # the header, .interp and .text; r-- with .rodata and the read-only dynamic
      # tables; rw- with .data/.got/.got.plt/.dynamic and .bss), then PT_INTERP,
      # PT_DYNAMIC and a non-executable PT_GNU_STACK. Load addresses come from the
      # placed sections' assigned vaddrs; the r-x segment maps from file offset 0
      # at the load base so its p_filesz spans the header as well as .text.
      def build_phdrs
        rx_last = @rx.reject { |s| s.type == SHT_NOBITS }.last
        rx_filesz = rx_last.offset + rx_last.size
        ro = segment_extent(@ro, base: @ro.first.offset)
        interp = named(".interp")
        dynamic = named(".dynamic")
        [
          phdr(PT_LOAD, PF_R | PF_X, 0, load_base, rx_filesz, rx_filesz, PAGE),
          phdr(PT_LOAD, PF_R, ro[:offset], @ro.first.vaddr, ro[:filesz], ro[:filesz], PAGE),
          phdr(PT_LOAD, PF_R | PF_W, @rw_start, @rw.first.vaddr,
               @file_end - @rw_start, @mem_end - @rw_start, PAGE),
          phdr(PT_INTERP, PF_R, interp.offset, interp.vaddr, interp.size, interp.size, 1),
          phdr(PT_DYNAMIC, PF_R | PF_W, dynamic.offset, dynamic.vaddr, dynamic.size, dynamic.size, 8),
          phdr(PT_GNU_STACK, PF_R | PF_W, 0, 0, 0, 0, 0x10)
        ].join
      end

      # --- crt synthesis -----------------------------------------------------

      # Builds the crt as a one-section ET_REL object: a .text holding _start with
      # a defined global _start symbol, an undefined main (resolved by the user's
      # object during the merge) and an undefined __libc_start_main (left as an
      # import bound against libc), plus the two relocations that fill _start's
      # operands.
      def build_crt
        writer = RelocatableWriter.new
        text = writer.add_section(name: ".text", type: SHT_PROGBITS,
                                  flags: SHF_ALLOC | SHF_EXECINSTR, addralign: 16,
                                  data: START_CODE)
        writer.add_symbol(name: "_start", bind: :global, type: :func,
                          section: text, value: 0, size: START_CODE.bytesize)
        main = writer.add_symbol(name: "main", bind: :global, type: :notype)
        libc_start = writer.add_symbol(name: "__libc_start_main", bind: :global, type: :notype)
        writer.add_relocation(target: text, offset: MAIN_IMM_OFFSET, symbol: main,
                              type: R_X86_64_32, addend: 0)
        writer.add_relocation(target: text, offset: LIBC_START_REL_OFFSET, symbol: libc_start,
                              type: R_X86_64_PLT32, addend: -4)
        writer.to_binary
      end

      # --- interpreter and libc ----------------------------------------------

      # The .interp contents: the NUL-terminated loader path.
      def interp_bytes
        @interp_bytes ||= (@interpreter.b + "\0".b)
      end

      # Chooses the dynamic loader: an explicit path wins, else the first known
      # loader that exists on the host. Neither present is a hard error rather than
      # a silent guess, since the resulting executable would not run.
      def choose_interpreter(explicit)
        return explicit if explicit
        return GLIBC_INTERP if File.exist?(GLIBC_INTERP)
        return MUSL_INTERP if File.exist?(MUSL_INTERP)

        raise LinkError,
              "no dynamic loader found (looked for #{GLIBC_INTERP} and #{MUSL_INTERP}); pass interpreter:"
      end

      # Adds libc to the dependency set so __libc_start_main (and any other libc
      # import) resolves. `:auto` discovers it on the host; a path uses it
      # directly; nil trusts the caller to have supplied it through `needed`.
      def add_default_libc(libc)
        case libc
        when :auto
          found = default_libc or
            raise LinkError, "cannot locate the C library; pass libc: with its path"
          @needed += [found] unless @needed.include?(found)
        when nil
          nil
        else
          @needed += [libc] unless @needed.include?(libc)
        end
      end

      def default_libc
        DEFAULT_LIBC_PATHS.find { |p| File.exist?(p) }
      end
    end
  end
end
