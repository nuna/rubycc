# frozen_string_literal: true

require_relative "test_helper"
require "fiddle"
require "tmpdir"
require_relative "support/native_aarch64_helper"
require_relative "support/acceptance_result_reporter"

# Native integration smoke tests. These are deliberately small: the complete
# language and QEMU target suites already run elsewhere. The tests here prove
# properties that cannot be inferred from x86_64 Ruby or QEMU alone: the host
# Ruby process, native loader/libc and Fiddle must all consume AArch64 output.
class TestNativeAArch64Smoke < Minitest::Test
  include NativeAArch64Helper

  AGGREGATE_AND_VARIADIC = <<~C
    #include <stdarg.h>

    struct Pair { long left; long right; };

    struct Pair make_pair(long left, long right) {
      struct Pair pair = { left, right };
      return pair;
    }

    long consume_pair(struct Pair pair) {
      return pair.left + pair.right;
    }

    long sum_variadic(int count, ...) {
      va_list ap;
      long total = 0;
      va_start(ap, count);
      while (count-- > 0) total += va_arg(ap, long);
      va_end(ap);
      return total;
    }

    int main(void) {
      struct Pair pair = make_pair(11, 22);
      return (consume_pair(pair) + sum_variadic(2, 13L, 14L) == 60) ? 0 : 1;
    }
  C

  CROSS_ABI_CALLEE = <<~C
    struct Pair { long left; long right; };
    struct Pair cross_make_pair(long left, long right) {
      struct Pair pair = { left, right };
      return pair;
    }
  C

  CROSS_ABI_RUBYCC_CALLER = <<~C
    struct Pair { long left; long right; };
    struct Pair cross_make_pair(long left, long right);
    int main(void) {
      struct Pair pair = cross_make_pair(17, 25);
      return pair.left + pair.right == 42 ? 0 : 1;
    }
  C

  CROSS_ABI_GCC_CALLER = <<~C
    struct Pair { long left; long right; };
    struct Pair cross_make_pair(long left, long right);
    int main(void) {
      struct Pair pair = cross_make_pair(19, 23);
      return pair.left + pair.right == 42 ? 0 : 1;
    }
  C

  def test_native_aggregate_and_scalar_variadic_abi_matches_gcc
    AcceptanceResultReporter.with_result("native-aarch64-aggregate-variadic", **native_context) do
      skip_unless_native_aarch64

      Dir.mktmpdir("rubycc-native-aarch64") do |dir|
        rubycc_object = File.join(dir, "rubycc.o")
        gcc_object = File.join(dir, "gcc.o")
        compile_native_target(AGGREGATE_AND_VARIADIC, rubycc_object)
        compile_with_native_gcc(AGGREGATE_AND_VARIADIC, gcc_object)

        rubycc_status, rubycc_output = link_and_run_native(rubycc_object)
        gcc_status, gcc_output = link_and_run_native(gcc_object)
        assert_equal gcc_status, rubycc_status
        assert_equal gcc_output, rubycc_output
        assert_equal 0, rubycc_status

        rubycc_caller = File.join(dir, "rubycc-caller.o")
        gcc_callee = File.join(dir, "gcc-callee.o")
        compile_native_target(CROSS_ABI_RUBYCC_CALLER, rubycc_caller)
        compile_with_native_gcc(CROSS_ABI_CALLEE, gcc_callee)
        status, output = link_objects_and_run_native(
          [rubycc_caller, gcc_callee], File.join(dir, "rubycc-caller.out")
        )
        assert_equal 0, status, "rubycc caller + gcc callee failed: #{output}"

        gcc_caller = File.join(dir, "gcc-caller.o")
        rubycc_callee = File.join(dir, "rubycc-callee.o")
        compile_with_native_gcc(CROSS_ABI_GCC_CALLER, gcc_caller)
        compile_native_target(CROSS_ABI_CALLEE, rubycc_callee)
        status, output = link_objects_and_run_native(
          [gcc_caller, rubycc_callee], File.join(dir, "gcc-caller.out")
        )
        assert_equal 0, status, "gcc caller + rubycc callee failed: #{output}"
      end
    end
  end

  def test_native_loader_and_fiddle_load_rubycc_aarch64_shared_object
    AcceptanceResultReporter.with_result("native-aarch64-loader-fiddle", **native_context) do
      skip_unless_native_aarch64

      source = "long native_add(long left, long right) { return left + right; }\n"
      Dir.mktmpdir("rubycc-native-aarch64") do |dir|
        object = File.join(dir, "native.o")
        shared_object = File.join(dir, "libnative.so")
        compile_native_target(source, object, pic: true)
        Rubycc::Link::SharedLinker.link_to([object], shared_object)

        library = Fiddle.dlopen(shared_object)
        function = Fiddle::Function.new(
          library["native_add"], [Fiddle::TYPE_LONG, Fiddle::TYPE_LONG], Fiddle::TYPE_LONG
        )
        assert_equal 42, function.call(19, 23)
      ensure
        library&.close
      end
    end
  end
end
