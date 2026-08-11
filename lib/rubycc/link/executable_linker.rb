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

      # The aarch64 dynamic loader paths. When cross-linking on an x86_64 host the
      # target loader is not present locally, so — unlike the x86_64 case — the
      # glibc path is used as the canonical on-target location without a host
      # existence check (the emulator/target resolves it through its own sysroot).
      #
      # That reasoning stops holding the moment aarch64 is the *host*: on Alpine
      # arm64 the loader is musl's, and naming glibc's would produce an executable
      # nothing can start. So the musl loader is preferred when it is actually
      # present, which can only be true on a musl aarch64 host, and the glibc name
      # remains the answer everywhere else including every cross link.
      AARCH64_INTERP = "/lib/ld-linux-aarch64.so.1"
      AARCH64_MUSL_INTERP = "/lib/ld-musl-aarch64.so.1"

      # The usual filesystem locations of the C library, consulted (in order) to
      # add libc as a default dependency. Only the SONAME the chosen file carries
      # affects the output, so which path matches does not disturb determinism.
      #
      # The glibc spellings come first, so a glibc host resolves exactly as it did
      # before musl was added to the list. The musl entries are last and are a
      # different shape on purpose: musl ships its loader and its C library as one
      # file, so the path that answers here is the same MUSL_INTERP used as the
      # program interpreter (Alpine's /usr/lib/libc.so is a symlink to it). There
      # is no libc.so.6 on such a host, which is why every extconf probe that
      # links an executable failed there until this list learned the musl name
      # (measured on Alpine in CI, docs/STEPS.md Step 190).
      DEFAULT_LIBC_PATHS = [
        "/lib/x86_64-linux-gnu/libc.so.6",
        "/lib64/libc.so.6",
        "/usr/lib/x86_64-linux-gnu/libc.so.6",
        "/usr/lib/libc.so.6",
        "/lib/libc.so.6",
        "/lib/ld-musl-x86_64.so.1",
        "/usr/lib/libc.so"
      ].freeze

      # The aarch64 C library locations, including the cross-toolchain sysroot the
      # linker reads the dependency's exports (and SONAME) from when cross-linking.
      # The musl entries mirror what Step 190 added to the x86-64 list above, for
      # the same reason and one architecture later: musl ships its C library and
      # its program interpreter as one file, so there is no libc.so.6 to find and
      # every extconf probe that links an executable failed on Alpine arm64 with
      # "cannot locate the C library" until this list learned the names. That
      # only surfaced once an aarch64 musl suite could be run at all
      # (m4-aarch64-acceptance-4); the x86-64 list had carried its musl entry
      # since Step 190, and nothing copied it across.
      #
      # The libc.musl-* spelling comes before the loader's own name because it is
      # the stable library name in Alpine images, matching LibraryResolver's
      # preference; both resolve to the same ELF.
      AARCH64_LIBC_PATHS = [
        "/lib/aarch64-linux-gnu/libc.so.6",
        "/usr/lib/aarch64-linux-gnu/libc.so.6",
        "/usr/aarch64-linux-gnu/lib/libc.so.6",
        "/lib/libc.musl-aarch64.so.1",
        "/usr/lib/libc.musl-aarch64.so.1",
        "/lib/ld-musl-aarch64.so.1"
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

      # The synthesized aarch64 _start, assembled from the AArch64 process-startup
      # ABI (ARM DDI 0487 encodings; not copied from any crt). The loader enters
      # with argc/argv/envp on the stack and x0 = rtld_fini, and this marshals the
      # classic __libc_start_main(main, argc, argv, init, fini, rtld_fini,
      # stack_end) call in x0-x6: x5 saves rtld_fini before x0 is reloaded with
      # main's address, x1 = argc = [sp], x2 = argv = sp + 8, x6 = stack_end = sp,
      # x3/x4 = init/fini = 0. main's address is formed by an adrp/add pair (a
      # non-PIE image, so the page/lo12 relocations resolve to a fixed address) and
      # the call reaches __libc_start_main through the .plt (CALL26). sp is 16-byte
      # aligned at entry and nothing is pushed, so no realignment is needed.
      AARCH64_START_CODE = [
        0xAA0003E5, # mov  x5, x0            ; x5 = rtld_fini (saved before x0 is reused)
        0xD280001D, # mov  x29, #0           ; outermost frame pointer
        0xD280001E, # mov  x30, #0           ; outermost link register
        0xF94003E1, # ldr  x1, [sp]          ; x1 = argc
        0x910023E2, # add  x2, sp, #8        ; x2 = argv
        0x910003E6, # mov  x6, sp            ; x6 = stack_end
        0x90000000, # adrp x0, main          ; x0 = page(main)   (ADR_PREL_PG_HI21)
        0x91000000, # add  x0, x0, :lo12:main; x0 = &main         (ADD_ABS_LO12_NC)
        0xD2800003, # mov  x3, #0            ; init = NULL
        0xD2800004, # mov  x4, #0            ; fini = NULL
        0x94000000, # bl   __libc_start_main ; through the .plt   (CALL26)
        0xD4200000  # brk  #0                ; __libc_start_main does not return
      ].pack("L<*").freeze

      # Byte offsets of the three operands the linker patches in the aarch64 crt:
      # the adrp and add forming main's address, and the bl to __libc_start_main.
      AARCH64_MAIN_ADRP_OFFSET  = 24 # 0x18
      AARCH64_MAIN_ADD_OFFSET   = 28 # 0x1c
      AARCH64_LIBC_START_OFFSET = 40 # 0x28

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
        # SharedLinker#initialize settles the target machine off the first input
        # object before the merge; the crt and the interpreter/libc defaults
        # chosen here all read it.
        super(inputs, needed: needed)
        @interpreter = choose_interpreter(interpreter)
        add_default_libc(libc)
      end

      private

      # --- SharedLinker hook overrides ---------------------------------------

      # An executable prepends the synthesized crt so _start (and its references
      # to main and __libc_start_main) take part in the merge and the shared
      # relocation pipeline handles them like any other input's relocations. The
      # tail keeps the shared linker's __dso_handle supplier: glibc's
      # libc_nonshared.a members reference that symbol in an executable link too,
      # and here it is a hard "undefined reference" rather than a leftover
      # import, so the same lazily-extracted definition is what completes them.
      # Its word holds its own address as in a shared object — an executable is
      # never dlclosed, so the identity only has to be unique.
      def link_inputs
        [build_crt] + super
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

      # A shared object may be completed by the runtime scope, so an unresolved
      # import is left undefined there; an executable, by contrast, must have
      # every strong reference bound at link time — the loader will not invent a
      # missing symbol — so a non-weak import that no dependency supplies is a
      # hard "undefined reference", exactly as a real linker reports it (and as a
      # conftest probe such as mkmf's have_func relies on to tell a present
      # function from an absent one).
      def resolve_imports
        super
        unresolved = @import_order.reject do |sym|
          sym.bind == :weak || @deps.any? { |dep| dep.provides.key?(sym.name) }
        end
        return if unresolved.empty?

        names = unresolved.map(&:name).uniq
        raise LinkError, "undefined reference to #{names.map { |n| "`#{n}'" }.join(', ')}"
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
          phdr(PT_LOAD, PF_R | PF_X, 0, load_base, rx_filesz, rx_filesz, seg_align),
          phdr(PT_LOAD, PF_R, ro[:offset], @ro.first.vaddr, ro[:filesz], ro[:filesz], seg_align),
          phdr(PT_LOAD, PF_R | PF_W, @rw_start, @rw.first.vaddr,
               @file_end - @rw_start, @mem_end - @rw_start, seg_align),
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
        aarch64? ? build_crt_aarch64 : build_crt_x86_64
      end

      def build_crt_x86_64
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

      # The aarch64 crt: the same one-section ET_REL shape as the x86_64 crt, but
      # carrying AARCH64_START_CODE and its three aarch64 relocations — the
      # adrp/add pair forming main's address (page + within-page) and the CALL26
      # to the imported __libc_start_main. Emitted with EM_AARCH64 so the merged
      # object the final link reads back reports the right machine.
      def build_crt_aarch64
        writer = RelocatableWriter.new(machine: EM_AARCH64)
        text = writer.add_section(name: ".text", type: SHT_PROGBITS,
                                  flags: SHF_ALLOC | SHF_EXECINSTR, addralign: 16,
                                  data: AARCH64_START_CODE)
        writer.add_symbol(name: "_start", bind: :global, type: :func,
                          section: text, value: 0, size: AARCH64_START_CODE.bytesize)
        main = writer.add_symbol(name: "main", bind: :global, type: :notype)
        libc_start = writer.add_symbol(name: "__libc_start_main", bind: :global, type: :notype)
        writer.add_relocation(target: text, offset: AARCH64_MAIN_ADRP_OFFSET, symbol: main,
                              type: R_AARCH64_ADR_PREL_PG_HI21, addend: 0)
        writer.add_relocation(target: text, offset: AARCH64_MAIN_ADD_OFFSET, symbol: main,
                              type: R_AARCH64_ADD_ABS_LO12_NC, addend: 0)
        writer.add_relocation(target: text, offset: AARCH64_LIBC_START_OFFSET, symbol: libc_start,
                              type: R_AARCH64_CALL26, addend: 0)
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
        # aarch64 is usually cross-linked from an x86_64 host, where the target
        # loader is not present locally, so its canonical on-target path is used
        # without a host check. A musl aarch64 *host* is the exception: there the
        # musl loader is the one that exists, and it is the one that must be named.
        return AARCH64_MUSL_INTERP if aarch64? && File.exist?(AARCH64_MUSL_INTERP)
        return AARCH64_INTERP if aarch64?
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
        libc_paths.find { |p| File.exist?(p) }
      end

      def libc_paths
        aarch64? ? AARCH64_LIBC_PATHS : DEFAULT_LIBC_PATHS
      end
    end
  end
end
