# frozen_string_literal: true

require_relative "test_helper"
require_relative "abi_harness/harness"
require_relative "support/aarch64_execution_helper"

# Step 207 (M5 H6): a standing guard against the ABI harness regressing the way
# Step 206 found it broken. HeaderAbiHarness#run_abi_case must build its rubycc
# side with the same PIC-ness gcc, its oracle, defaults to; if it does not, the
# object it hands to the aarch64 cross gcc fails a PIE link with "unresolvable
# R_AARCH64_ADR_PREL_PG_HI21" against any symbol the object references as
# external data (docs/STEPS.md Step 206). That defect is invisible on x86-64
# (the linker absorbs a non-PIC reference to external data with a copy
# relocation) and invisible through HeaderAbiHarness#run_abi_case_aarch64
# (that path links -static, which a PIE link never needs), so it can only be
# caught by actually linking a rubycc-built aarch64 object into a dynamic PIE
# -- which this test does, on the development host, with no aarch64 hardware
# or CI run required.
#
# The probe references stdout, an external *data* symbol, which is the shape
# Step 206's failure needed (a function call goes through the PLT either way
# and would not have reproduced it).
#
# The compile options come from HeaderAbiHarness#rubycc_build_options, the
# very method #run_abi_case itself calls to build its rubycc side. This test
# does not copy that keyword list: a copy would only ever check itself, not
# the harness. Sharing the method is what makes "someone drops `pic: true`
# from the harness" a failure here too.
#
# The profile passed in is built here, not taken from
# #aarch64_cross_build_profile: that BuildProfile's `pic` is false (it drives
# #run_abi_case_aarch64, which links -static and so is immune to the PIE
# defect this test exists to catch -- see that method's own comment), so
# reusing it here would make this test assert nothing.
class TestAbiHarnessPieLink < Minitest::Test
  include ExecutionHelper
  include HeaderAbiHarness
  include AArch64ExecutionHelper

  PROBE = <<~C
    #include <stdio.h>
    int main(void) {
      fputs("pie-ok", stdout);
      return 0;
    }
  C

  def test_rubycc_aarch64_object_links_into_a_pie_with_the_cross_gcc
    skip_unless_aarch64_self_link

    in_tmpdir do |dir|
      object_path = File.join(dir, "probe.o")
      profile = HeaderAbiHarness::BuildProfile.new(target: "aarch64", libc: :glibc, pic: true)
      File.binwrite(object_path,
                    Rubycc::Compiler.new.compile(PROBE, filename: "probe.c",
                                                 **rubycc_build_options(profile)))

      exe_path = File.join(dir, "probe.out")
      link_out, link_status = Open3.capture2e(
        AArch64ExecutionHelper::CROSS_GCC, "-pie", "-o", exe_path, object_path
      )
      assert link_status.success?,
             "#{AArch64ExecutionHelper::CROSS_GCC} -pie failed to link rubycc's " \
             "aarch64 object (exit #{link_status.exitstatus}):\n#{link_out}"

      stdout, run_status = Open3.capture2(
        { "QEMU_LD_PREFIX" => AArch64ExecutionHelper::SYSROOT },
        AArch64ExecutionHelper::QEMU, exe_path
      )
      assert run_status.success?,
             "#{AArch64ExecutionHelper::QEMU} exited #{run_status.exitstatus} running the PIE"
      assert_equal "pie-ok", stdout
    end
  end
end
