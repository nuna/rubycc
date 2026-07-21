# frozen_string_literal: true

require "rubycc"

# The ABI-verification harness (M5 H1, built ahead of the bundled libc headers).
#
# A header is "ABI compatible" only if code compiled against rubycc's bundled
# copy of it lays memory out, and evaluates its macros, exactly as code compiled
# against the host's real header does. Reading the two headers side by side does
# not prove that; running the same probe program compiled both ways does. This
# module is that differential engine: from a declarative Spec of what to check
# for one header it generates a single probe program, compiles and runs it twice
# -- once with the system gcc against the real headers, once with rubycc against
# the bundled headers (its default search path already prefers them) -- and hands
# both programs' output back for a byte comparison. Every header the bundled libc
# gains is meant to arrive together with a Spec here, so its correctness is
# machine-checked rather than eyeballed.
#
# The mixing is deliberate the same way the cross-ABI struct tests are: gcc's run
# is the oracle, and rubycc must reproduce it to the byte. A probe that gcc and
# rubycc disagree on has found a real layout or macro-value discrepancy.
#
# The instance methods assume the host ExecutionHelper is also mixed in
# (compile_with_gcc, link_and_run, in_tmpdir) and that Rubycc is loaded; the test
# case includes both.
module HeaderAbiHarness
  # One header's ABI surface to probe. Every field is optional so a Spec can
  # carry only the kinds of check a header actually warrants:
  #   header   : the <name.h> the probe #includes and is checking (String).
  #   also     : extra headers to #include first (e.g. a header the checks lean
  #              on that is not the one under test), as bare names.
  #   sizes    : type names whose sizeof and _Alignof must agree. A type is any
  #              type-name spelling ("size_t", "struct tm", "va_list").
  #   ints     : integer-valued macros or constant expressions, printed widened
  #              to (long long) so an integer macro's value is compared exactly.
  #   floats   : floating-valued macros, printed with "%a" (an exact hexadecimal
  #              float) widened to double, so a float/double macro's bit pattern
  #              is compared exactly rather than through lossy decimal rounding.
  #   offsets  : [type, member] pairs whose offsetof must agree -- the direct
  #              probe of a struct's field layout.
  #   snippets : file-scope C fragments that must merely compile. This is the
  #              "declaration exists / is usable" check (a function prototype the
  #              header must provide, a macro that must expand to usable code);
  #              its presence is proven by the probe compiling at all.
  Spec = Struct.new(:header, :also, :sizes, :ints, :floats, :offsets, :snippets,
                    keyword_init: true)

  # The paired outcome of running one Spec both ways: each side's process exit
  # status and captured standard output. A passing case has both statuses 0 and
  # byte-identical output.
  Result = Struct.new(:gcc_status, :gcc_out, :rubycc_status, :rubycc_out)

  # Builds the probe program for `spec`: it pulls in <stdio.h> (for printf),
  # <stddef.h> (for offsetof), the header under test and any `also` headers, then
  # emits every check as one labeled printf line inside main, with the snippets
  # placed at file scope ahead of it. The label text is part of the compared
  # output, so a check is self-identifying when a difference is reported.
  def abi_probe_source(spec)
    lines = []
    Array(spec.sizes).each do |type|
      lines << "  printf(\"sizeof(#{type}) = %zu, _Alignof(#{type}) = %zu\\n\", " \
               "sizeof(#{type}), _Alignof(#{type}));"
    end
    Array(spec.ints).each do |expr|
      lines << %(  printf("#{expr} = %lld\\n", (long long)(#{expr}));)
    end
    Array(spec.floats).each do |expr|
      lines << %(  printf("#{expr} = %a\\n", (double)(#{expr}));)
    end
    Array(spec.offsets).each do |(type, member)|
      lines << %(  printf("offsetof(#{type}, #{member}) = %zu\\n", offsetof(#{type}, #{member}));)
    end

    includes = ["stdio.h", "stddef.h", spec.header, *Array(spec.also)].uniq
    header_block = includes.map { |name| "#include <#{name}>" }.join("\n")
    snippets = Array(spec.snippets).join("\n")

    <<~C
      #{header_block}
      #{snippets}
      int main(void) {
      #{lines.join("\n")}
        return 0;
      }
    C
  end

  # Compiles the probe for `spec` with both toolchains, runs each, and returns a
  # Result. The rubycc side passes no -I: the point is that the bundled headers
  # are found on rubycc's own default search path (bundled freestanding, then
  # bundled libc, ahead of the host libc), exactly as an end user gets them.
  def run_abi_case(spec)
    source = abi_probe_source(spec)
    name = spec.header.gsub(/[^A-Za-z0-9]+/, "_")
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      File.binwrite(rubycc_obj, Rubycc::Compiler.new.compile(source, filename: "#{name}.c"))
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = compile_with_gcc(source, File.join(dir, "#{name}_gcc.o"))
      gcc_status, gcc_out = link_and_run(gcc_obj)

      Result.new(gcc_status, gcc_out, rubycc_status, rubycc_out)
    end
  end

  # The aarch64 counterpart of #run_abi_case, machine-parameterized so the same
  # declarative Spec is verified against the cross ABI. The probe source is
  # identical (the check text is architecture-independent); only the toolchains
  # differ. The rubycc side compiles for the aarch64 target -- so its bundled
  # glibc/aarch64 header layer is on the search path -- links the object
  # statically with the cross gcc and runs it under qemu; the oracle side builds
  # and runs the same source with the cross gcc against the target's real headers.
  # Both stdouts are handed back for the byte comparison, exactly as the host
  # path does. Requires AArch64ExecutionHelper (compile_with_rubycc_aarch64,
  # compile_with_cross_gcc, link_and_run_aarch64) and the host ExecutionHelper's
  # in_tmpdir to be mixed in alongside this module.
  def run_abi_case_aarch64(spec)
    source = abi_probe_source(spec)
    name = spec.header.gsub(/[^A-Za-z0-9]+/, "_")
    in_tmpdir do |dir|
      rubycc_obj = compile_with_rubycc_aarch64(source, File.join(dir, "#{name}_rubycc.o"))
      rubycc_status, rubycc_out = link_and_run_aarch64(rubycc_obj)

      gcc_obj = compile_with_cross_gcc(source, File.join(dir, "#{name}_gcc.o"))
      gcc_status, gcc_out = link_and_run_aarch64(gcc_obj)

      Result.new(gcc_status, gcc_out, rubycc_status, rubycc_out)
    end
  end
end
