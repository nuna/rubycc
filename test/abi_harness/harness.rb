# frozen_string_literal: true

require "rbconfig"
require "rubycc"
require_relative "../support/host_target"

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
# in glibc's own names -- its version-test macros, __sigset_t, _ISupper, struct
# termios's c_ispeed -- does not compile on a musl host *for the oracle either*, and a
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

  # The one build configuration a differential run applies to BOTH compiled
  # sides: the CPU the object targets, the libc whose ABI the headers (and,
  # for rubycc, its bundled header layer) describe, and whether the code is
  # position-independent. #run_abi_case and #run_abi_case_aarch64 each build
  # exactly one BuildProfile and read every setting that must agree between
  # the two toolchains -- the probe's libc branch (#abi_probe_source), rubycc's
  # compile options (#rubycc_build_options), and the oracle's compiler flags --
  # off it, so there is one place that decides "what are the two sides
  # supposed to agree on" instead of each call site picking its own default.
  # That "each side picks its own default" is the mistake this harness made
  # four separate times (docs/development/STEPS.md Steps 194, 197, 206): a BuildProfile
  # cannot be half-applied the way two independent keyword lists can.
  BuildProfile = Struct.new(:target, :libc, :pic, keyword_init: true)

  # The libc the C toolchain on this host compiles against. Read from RbConfig's
  # arch triplet, which is how MRI itself distinguishes a musl build
  # ("x86_64-linux-musl") from a glibc one ("x86_64-linux") -- the same source
  # tools/verify_gem_tests.rb's environment_string reads for the label it writes
  # into data/verified_gems.json, so the two agree on what "this environment" is.
  def host_libc
    RbConfig::CONFIG["arch"].to_s.include?("musl") ? :musl : :glibc
  end

  # The machine this host runs, as a Rubycc::Compiler::TARGETS name. Read from
  # RbConfig's host_cpu, which is where exe/rubycc's driver takes its own
  # default target from (Driver#target), so the harness compiles for the same
  # machine a plain `rubycc` invocation on this host would. Without it the host
  # path would inherit Compiler#compile's "x86_64" default and emit x86-64
  # objects on an aarch64 host, which the host gcc cannot link, let alone run.
  # On x86-64 this is "x86_64" -- the default -- so nothing about the existing
  # runs changes.
  #
  # HostTarget folds the common MRI aliases to TARGETS names; a host_cpu
  # spelling that is not a TARGETS key is a machine this harness has never run
  # on, and
  # #skip_unless_host_target_supported says so rather than guessing at one.
  def host_target
    HostTarget.name
  end

  # Skips the calling test on a machine rubycc has no backend for. Compiling
  # for some other machine and reporting the result would be measuring a
  # different CPU's ABI and calling it this host's, so the case is not run at
  # all; the skip names the CPU so the reason is visible in the log rather than
  # silently green.
  def skip_unless_host_target_supported
    return if Rubycc::Compiler::TARGETS.key?(host_target)

    skip "host CPU #{host_target.inspect} is not a rubycc target " \
         "(#{Rubycc::Compiler::TARGETS.keys.join(", ")})"
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

  # The BuildProfile #run_abi_case runs under: this host's own CPU and libc
  # (#host_target, #host_libc), and `pic: true` so the two sides are built the
  # same way. The oracle is compiled by gcc, and on a modern toolchain gcc's
  # own default means -fPIE; leaving rubycc's side non-PIC therefore compared
  # a PIE build against a non-PIE one. On x86-64 that difference is invisible
  # (the linker resolves a non-PIC reference to external data with a copy
  # relocation), but on aarch64 it is fatal: ADRP+ADD to a preemptible symbol
  # has no such fixup, so the link fails with "unresolvable
  # R_AARCH64_ADR_PREL_PG_HI21". That is not a rubycc defect -- gcc's own
  # -fno-pie object fails the same link with the same message (both measured
  # locally) -- it is this harness handing the two sides different flags.
  # Found on aarch64 musl, reproduced on glibc (docs/development/STEPS.md Step 206).
  def host_build_profile
    BuildProfile.new(target: host_target, libc: host_libc, pic: true)
  end

  # The BuildProfile #run_abi_case_aarch64 runs under: the aarch64 target, and
  # glibc no matter what this dev host runs, because the cross toolchain is
  # aarch64-linux-gnu -- there is no musl variant of that Debian cross package
  # -- so the oracle always reads glibc's headers, and rubycc must be told to
  # compile against its bundled glibc/aarch64 header layer to match it. A musl
  # dev host would otherwise both mis-probe (the probe would drop the
  # glibc-only checks meant for a run whose both sides are glibc's) and
  # mis-compile rubycc's side against its own musl default.
  def aarch64_cross_build_profile
    BuildProfile.new(target: "aarch64", libc: :glibc, pic: false)
  end

  # The keyword arguments #run_abi_case and #run_abi_case_aarch64 pass to
  # Rubycc::Compiler#compile for `profile`. Kept in one place so a test that
  # wants to prove "the harness still builds its rubycc side the same way it
  # links against the oracle" asks this method rather than copying the keyword
  # list -- a copy would only ever check itself, not the harness (docs/development/STEPS.md
  # Step 206).
  #
  # `libc: profile.libc.to_s`: BuildProfile (like #host_libc and the rest of
  # this harness) names the libc as a Symbol, but Rubycc::Compiler#compile's
  # own `libc:` keyword takes the String Preprocess::Preprocessor validates
  # against LIBCS ("glibc"/"musl") -- the same split #abi_probe_source's
  # callers already navigate with an explicit `.to_sym`/`.to_s` at the
  # boundary between the two conventions.
  def rubycc_build_options(profile)
    { target: profile.target, libc: profile.libc.to_s, pic: profile.pic }
  end

  # Compiles the probe for `spec` with both toolchains, runs each, and returns a
  # Result. Every setting either side needs -- the probe's libc branch, rubycc's
  # compile options, and (since both sides must be built the same way, not just
  # rubycc's -- see BuildProfile) the oracle's own flags -- comes from one
  # #host_build_profile, so nothing here can pick its own default the way Steps
  # 194, 197 and 206 each independently did. The rubycc side passes no -I: the
  # point is that the bundled headers are found on rubycc's own default search
  # path (bundled freestanding, then bundled libc, ahead of the host libc),
  # exactly as an end user gets them.
  def run_abi_case(spec)
    profile = host_build_profile
    source = abi_probe_source(spec, profile.libc)
    name = spec.header.gsub(/[^A-Za-z0-9]+/, "_")
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      File.binwrite(rubycc_obj,
                    Rubycc::Compiler.new.compile(source, filename: "#{name}.c",
                                                 **rubycc_build_options(profile)))
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = compile_with_gcc(source, File.join(dir, "#{name}_gcc.o"), pic: profile.pic)
      gcc_status, gcc_out = link_and_run(gcc_obj)

      Result.new(gcc_status, gcc_out, rubycc_status, rubycc_out)
    end
  end

  # The aarch64 counterpart of #run_abi_case, machine-parameterized so the same
  # declarative Spec is verified against the cross ABI. The probe source is
  # identical (the check text is architecture-independent); only the toolchains
  # differ. As in #run_abi_case, every setting either side needs comes from one
  # #aarch64_cross_build_profile (see that method for why its libc is always
  # glibc). The rubycc side compiles for the aarch64 target -- so its bundled
  # glibc/aarch64 header layer is on the search path -- links the object
  # statically with the cross gcc and runs it under qemu; the oracle side builds
  # and runs the same source with the cross gcc against the target's real
  # headers. Both stdouts are handed back for the byte comparison, exactly as
  # the host path does. Requires AArch64ExecutionHelper (compile_with_cross_gcc,
  # link_and_run_aarch64) and the host ExecutionHelper's in_tmpdir to be mixed
  # in alongside this module.
  def run_abi_case_aarch64(spec)
    profile = aarch64_cross_build_profile
    source = abi_probe_source(spec, profile.libc)
    name = spec.header.gsub(/[^A-Za-z0-9]+/, "_")
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "#{name}_rubycc.o")
      File.binwrite(rubycc_obj,
                    Rubycc::Compiler.new.compile(source, filename: "#{name}.c",
                                                 **rubycc_build_options(profile)))
      rubycc_status, rubycc_out = link_and_run_aarch64(rubycc_obj)

      gcc_obj = compile_with_cross_gcc(source, File.join(dir, "#{name}_gcc.o"), pic: profile.pic)
      gcc_status, gcc_out = link_and_run_aarch64(gcc_obj)

      Result.new(gcc_status, gcc_out, rubycc_status, rubycc_out)
    end
  end
end
