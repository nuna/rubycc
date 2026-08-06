# frozen_string_literal: true

require_relative "test_helper"
require_relative "abi_harness/harness"

# Guards HeaderAbiHarness::BuildProfile: the abstraction #run_abi_case and
# #run_abi_case_aarch64 now read every side-by-side compile setting from,
# introduced so a change could no longer repeat the mistake Steps 194, 197
# and 206 each made independently -- one side of the differential quietly
# keeping its own default instead of matching the other.
#
# The struct-field checks below are the cheap half: they prove #host_build_profile
# and #aarch64_cross_build_profile fill in the fields Task item 1 specifies.
#
# The interesting half is #test_gcc_and_rubycc_access_external_data_the_same_way_from_one_profile.
# It does not re-derive an expected boolean and compare it to a literal --
# that would only ever check its own arithmetic, not the harness (the same
# reasoning #rubycc_build_options's own comment gives for not copying its
# keyword list). Instead it builds ONE BuildProfile, compiles the SAME probe
# with both toolchains through the SAME two harness methods #run_abi_case
# itself calls (#rubycc_build_options and #compile_with_gcc), and reads back
# the ACTUAL relocation each object carries for a reference to data this
# translation unit does not define, with Rubycc::ObjFile::ELFReader -- the
# same tool test_pic.rb's own gcc cross-check
# (test_gcc_uses_gotpcrel_for_extern_data) uses to pin rubycc's -fPIC choice
# to gcc's. Under pic: true that reference is GOT-relative
# (R_X86_64_(REX_)?GOTPCREL(X)); otherwise it is a direct PC32 reference. A
# harness that let one side ignore the profile's `pic` would show up here as
# the two objects disagreeing on which family they used, or as one of them
# not matching the profile at all -- which is exactly the shape Step 206's
# regression took, just observed on x86-64 instead of requiring aarch64
# hardware to see it.
class TestAbiHarnessBuildProfile < Minitest::Test
  include ExecutionHelper
  include HeaderAbiHarness

  Reader = Rubycc::ObjFile::ELFReader
  GOT_RELOCS = %i[R_X86_64_GOTPCREL R_X86_64_GOTPCRELX R_X86_64_REX_GOTPCRELX].freeze

  # A reference to data this translation unit does not define: the shape
  # test_pic.rb's own PIC-discrimination tests use, because a *call* is
  # always PLT32 regardless of PIC-ness and would not distinguish the two
  # profiles this test compares.
  PROBE = "extern int probe_external;\nint read_probe(void) { return probe_external; }\n"

  def test_host_build_profile_reads_this_hosts_target_and_libc
    profile = host_build_profile

    assert_equal host_target, profile.target
    assert_equal host_libc, profile.libc
    assert profile.pic
  end

  def test_aarch64_cross_build_profile_is_always_glibc
    profile = aarch64_cross_build_profile

    assert_equal "aarch64", profile.target
    assert_equal :glibc, profile.libc
  end

  def test_rubycc_build_options_reads_every_field_off_the_profile
    profile = BuildProfile.new(target: "aarch64", libc: :glibc, pic: true)

    assert_equal({ target: profile.target, libc: profile.libc.to_s, pic: profile.pic },
                 rubycc_build_options(profile))
  end

  def test_gcc_and_rubycc_access_external_data_the_same_way_from_one_profile
    skip_unless_host_target_supported

    [true, false].each do |pic|
      profile = BuildProfile.new(target: host_target, libc: host_libc, pic: pic)

      in_tmpdir do |dir|
        rubycc_obj = File.join(dir, "probe_rubycc.o")
        File.binwrite(rubycc_obj,
                      Rubycc::Compiler.new.compile(PROBE, filename: "probe.c",
                                                   **rubycc_build_options(profile)))
        gcc_obj = compile_with_gcc(PROBE, File.join(dir, "probe_gcc.o"), pic: profile.pic)

        rubycc_got = extern_access_is_got_relative?(rubycc_obj)
        gcc_got = extern_access_is_got_relative?(gcc_obj)

        assert_equal profile.pic, rubycc_got,
                     "rubycc built from BuildProfile(pic: #{profile.pic}) should access " \
                     "external data through the GOT only when pic is true"
        assert_equal profile.pic, gcc_got,
                     "gcc built from BuildProfile(pic: #{profile.pic}) should access " \
                     "external data through the GOT only when pic is true"
        assert_equal rubycc_got, gcc_got,
                     "gcc and rubycc built from the same BuildProfile disagree on how " \
                     "they access external data"
      end
    end
  end

  private

  def extern_access_is_got_relative?(object_path)
    reloc = Reader.read_file(object_path).relocations_for(".text").find do |r|
      r.symbol&.name == "probe_external"
    end
    refute_nil reloc, "expected a relocation against probe_external in #{object_path}"
    GOT_RELOCS.include?(reloc.type_name)
  end
end
