# frozen_string_literal: true

require "rbconfig"
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
# The probe is parameterized on two axes: the machine (the host x86-64 path and
# the aarch64 cross path below) and, since Step 180, the libc. A probe written
# in glibc's own names -- __GLIBC__, __sigset_t, _ISupper, struct termios's
# c_ispeed -- does not compile on a musl host *for the oracle either*, and a
# case where gcc fails first proves nothing about rubycc: it reports as a
# failure that is the harness's, not the compiler's (measured on musl, Step
# 175: 13 cases in that state). So a Spec declares which of its checks only
# exist on glibc, and each run resolves them against the libc the toolchain of
# that run actually compiles against.
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
  #   defines  : feature-test macro names to #define ahead of every #include
  #              (even <stdio.h>), as bare names ("_GNU_SOURCE"). Needed when the
  #              header under test exposes a flat, always-on surface (as rubycc's
  #              bundled headers do -- see sys/stat.h's unconditional st_atim) but
  #              the host glibc gates the same names behind __USE_GNU and friends;
  #              defining the feature-test macro before the first system header
  #              (which is what fixes <features.h>'s __USE_* state) makes the
  #              oracle expose its full surface too, so the comparison is
  #              apples-to-apples. Unset for a Spec, this emits nothing, so every
  #              existing Spec's probe text is byte-identical to before.
  #   libc     : the one libc this Spec's *header* exists on (:glibc), or nil
  #              (the default) when the header is common to both. This is the
  #              whole-header case -- <features.h> is glibc's own version
  #              plumbing and <sys/cdefs.h> is not installed on musl at all --
  #              so there is nothing to probe anywhere else, not even an oracle.
  #   glibc    : a Hash, keyed by the check kinds above (:sizes, :ints, :floats,
  #              :offsets, :snippets, :defines, :also), of entries that exist
  #              only on glibc. They are merged into the corresponding kind when
  #              the effective libc is glibc and dropped otherwise; see
  #              #abi_checks for where they land. This is the per-check case:
  #              the header is common but some of the names it exposes are
  #              glibc's own (RTLD_DEEPBIND, __sigset_t, LC_PAPER, ...).
  Spec = Struct.new(:header, :also, :sizes, :ints, :floats, :offsets, :snippets,
                    :defines, :libc, :glibc, keyword_init: true)

  # Placeholder element for a check list, marking where that kind's `glibc:`
  # entries are spliced back in on a glibc host. A list without one takes them
  # at its tail instead, which is all a Spec needs when the glibc-only names
  # were already last (termios.h's c_ispeed/c_ospeed offsets, sys/statfs.h's
  # __fsid_t). The marker exists for the lists where they were *not* last: the
  # point of this parameterization is to make the musl host runnable, not to
  # perturb the glibc baseline, so moving a name out of the middle of a list
  # must still leave the glibc probe text byte-identical to what it was before
  # the move (see TestHeaderAbiLibcParameterization).
  GLIBC_ONLY = :glibc_only

  # The paired outcome of running one Spec both ways: each side's process exit
  # status and captured standard output. A passing case has both statuses 0 and
  # byte-identical output.
  Result = Struct.new(:gcc_status, :gcc_out, :rubycc_status, :rubycc_out)

  # The libc the C toolchain on this host compiles against. Read from RbConfig's
  # arch triplet, which is how MRI itself distinguishes a musl build
  # ("x86_64-linux-musl") from a glibc one ("x86_64-linux") -- the same source
  # tools/verify_gem_tests.rb's environment_string reads for the label it writes
  # into data/verified_gems.json, so the two agree on what "this environment" is.
  def host_libc
    RbConfig::CONFIG["arch"].to_s.include?("musl") ? :musl : :glibc
  end

  # Whether `spec` can be probed against `libc` at all. A Spec that names a
  # `libc:` covers a header only that libc has, so anywhere else there is
  # nothing to compare: the oracle does not compile either, and running the case
  # would report the harness's own glibc assumption as a rubycc failure.
  def spec_applies_to?(spec, libc = host_libc)
    spec.libc.nil? || spec.libc == libc
  end

  # The entries of one check kind for `libc`: the Spec's own list, with its
  # `glibc:` bundle for that kind spliced in at the GLIBC_ONLY marker (or
  # appended at the tail, when the list carries no marker) if the effective libc
  # is glibc, and with both the marker and the bundle dropped otherwise.
  #
  # A bundle may itself carry one GLIBC_ONLY, splitting it into the entries that
  # go at the base list's marker and the entries that go at its tail. One header
  # needs both at once: langinfo.h's DECIMAL_POINT sits third in a sixty-entry
  # list while its _NL_ITEM checks sit last, and neither may move if the glibc
  # probe text is to stay byte-identical (see GLIBC_ONLY).
  def abi_checks(spec, kind, libc)
    base = Array(spec[kind])
    bundle = libc == :glibc ? Array(spec.glibc && spec.glibc[kind]) : []
    split = bundle.index(GLIBC_ONLY)
    spliced, appended = split.nil? ? [bundle, []] : [bundle[0...split], bundle[(split + 1)..]]

    at = base.index(GLIBC_ONLY)
    return base + spliced + appended if at.nil?

    base[0...at] + spliced + base[(at + 1)..] + appended
  end

  # Builds the probe program for `spec` as compiled against `libc` (the host's
  # own by default): any `defines` come first (ahead of even <stdio.h>, so they
  # are in effect for <features.h>'s __USE_* resolution), then <stdio.h> (for
  # printf), <stddef.h> (for offsetof), the header under test and any `also`
  # headers, then every check as one labeled printf line inside main, with the
  # snippets placed at file scope ahead of it. The label text is part of the
  # compared output, so a check is self-identifying when a difference is
  # reported. Every kind goes through #abi_checks, so a Spec with no `glibc:`
  # bundle produces the same text for either libc.
  def abi_probe_source(spec, libc = host_libc)
    lines = []
    abi_checks(spec, :sizes, libc).each do |type|
      lines << "  printf(\"sizeof(#{type}) = %zu, _Alignof(#{type}) = %zu\\n\", " \
               "sizeof(#{type}), _Alignof(#{type}));"
    end
    abi_checks(spec, :ints, libc).each do |expr|
      lines << %(  printf("#{expr} = %lld\\n", (long long)(#{expr}));)
    end
    abi_checks(spec, :floats, libc).each do |expr|
      lines << %(  printf("#{expr} = %a\\n", (double)(#{expr}));)
    end
    abi_checks(spec, :offsets, libc).each do |(type, member)|
      lines << %(  printf("offsetof(#{type}, #{member}) = %zu\\n", offsetof(#{type}, #{member}));)
    end

    defines_block = abi_checks(spec, :defines, libc).map { |name| "#define #{name}" }.join("\n")
    includes = ["stdio.h", "stddef.h", spec.header, *abi_checks(spec, :also, libc)].uniq
    header_block = includes.map { |name| "#include <#{name}>" }.join("\n")
    preamble = defines_block.empty? ? header_block : "#{defines_block}\n#{header_block}"
    snippets = abi_checks(spec, :snippets, libc).join("\n")

    <<~C
      #{preamble}
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
  # bundled libc, ahead of the host libc), exactly as an end user gets them. The
  # effective libc is the host's, since both toolchains here compile against the
  # host's own libc headers.
  def run_abi_case(spec)
    source = abi_probe_source(spec, host_libc)
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
    # The effective libc is glibc no matter what this host runs: the cross
    # toolchain is aarch64-linux-gnu, so the oracle reads glibc's headers and
    # rubycc compiles against its bundled glibc/aarch64 layer. A musl host would
    # otherwise drop the glibc-only checks from a probe whose both sides are
    # glibc's.
    source = abi_probe_source(spec, :glibc)
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
