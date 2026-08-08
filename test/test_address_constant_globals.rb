# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "fiddle"
require "tmpdir"

# Exercises the address-constant subset of ISO C 6.6 that a global (static)
# pointer initializer may fold to: a pointer cast of a string literal, "&arr[i]",
# "arr + n"/"n + arr"/"arr - n", "&rec.member" and nested designators, all
# carried into the object file as an R_X86_64_64 relocation whose r_addend is the
# folded byte displacement. Also a pointer cast of a plain integer constant
# (e.g. "(void *)0x1000" or "(dfree_t)-1", the latter CRuby's
# RUBY_TYPED_DEFAULT_FREE), which has no object to relocate against and so is
# stored as a raw bit pattern with no relocation at all.
#
# The runtime cases compile with rubycc and, as an oracle, link and run with the
# system gcc (proving the emitted addend is right against a real linker). Two
# further cases drive rubycc's own ExecutableLinker and SharedLinker so the
# addend is exercised end to end through the Almost Pure Ruby toolchain too.
class TestAddressConstantGlobals < Minitest::Test
  include ExecutionHelper

  ExecLinker = Rubycc::Link::ExecutableLinker
  SharedLinker = Rubycc::Link::SharedLinker

  # --- runtime, gcc-linked (differential against gcc) ---------------------

  # The jeaiii-ltoa form that first exposed the gap: a string literal cast to a
  # struct pointer, then subscripted at run time.
  def test_string_literal_cast_to_struct_pointer
    src = <<~C
      struct pair { char dd[2]; };
      static const struct pair *digits = (const struct pair *)("00" "01" "02" "03" "04");
      int main(void) {
        return (digits[3].dd[0] - '0') * 10 + (digits[3].dd[1] - '0');
      }
    C
    assert_matches_gcc(3, src)
  end

  def test_address_of_array_element
    src = <<~C
      static int table[5] = {10, 20, 30, 40, 50};
      static int *q = &table[2];
      int main(void) { return *q; }
    C
    assert_matches_gcc(30, src)
  end

  def test_array_plus_integer_decays
    src = <<~C
      static int table[5] = {10, 20, 30, 40, 50};
      static int *q = table + 3;
      int main(void) { return *q; }
    C
    assert_matches_gcc(40, src)
  end

  def test_integer_plus_array_is_commutative
    src = <<~C
      static int table[5] = {10, 20, 30, 40, 50};
      static int *q = 2 + table;
      int main(void) { return *q; }
    C
    assert_matches_gcc(30, src)
  end

  def test_pointer_minus_integer
    src = <<~C
      static int table[5] = {10, 20, 30, 40, 50};
      static int *q = &table[4] - 1;
      int main(void) { return *q; }
    C
    assert_matches_gcc(40, src)
  end

  def test_address_of_struct_member
    src = <<~C
      struct rec { int a; int b; int c; };
      static struct rec r = {1, 2, 3};
      static int *p = &r.b;
      int main(void) { return *p; }
    C
    assert_matches_gcc(2, src)
  end

  def test_nested_designator_address
    src = <<~C
      struct inner { int x; int y; };
      struct outer { int tag; struct inner inner; };
      static struct outer recs[4] = {
        {0, {0, 0}}, {0, {0, 0}}, {7, {42, 9}}, {0, {0, 0}}
      };
      static int *p = &recs[2].inner.x;
      int main(void) { return *p; }
    C
    assert_matches_gcc(42, src)
  end

  def test_void_pointer_cast_of_address_constant
    src = <<~C
      static int table[5] = {10, 20, 30, 40, 50};
      static void *vp = (void *)&table[4];
      int main(void) { return *(int *)vp; }
    C
    assert_matches_gcc(50, src)
  end

  # An address constant folded inside an aggregate initializer's pointer member,
  # not just a bare scalar global.
  def test_address_constant_inside_aggregate_member
    src = <<~C
      static int table[5] = {10, 20, 30, 40, 50};
      struct view { int *lo; int *hi; };
      static struct view v = { &table[1], table + 4 };
      int main(void) { return *v.lo + *v.hi; }
    C
    assert_matches_gcc(70, src)
  end

  # --- absolute (integer) address constants -------------------------------

  # The msgpack buffer_class.c shape that motivated this: a function-pointer
  # struct member set to CRuby's RUBY_TYPED_DEFAULT_FREE, "(RUBY_DATA_FUNC)-1".
  def test_pointer_cast_of_negative_integer_constant
    src = <<~C
      typedef void (*dfree_t)(void *);
      struct dtype { const char *name; dfree_t dfree; };
      static const struct dtype t = { "box", (dfree_t)-1 };
      int main(void) { return t.dfree == (dfree_t)-1; }
    C
    assert_matches_gcc(1, src)
  end

  def test_void_pointer_cast_of_integer_literal
    src = <<~C
      static void *p = (void *)0x1000;
      int main(void) { return p == (void *)0x1000; }
    C
    assert_matches_gcc(1, src)
  end

  # An absolute pointer cast still accepts further constant pointer arithmetic.
  def test_absolute_pointer_plus_integer
    src = <<~C
      static char *q = (char *)16 + 2;
      int main(void) { return (long)q == 18; }
    C
    assert_matches_gcc(1, src)
  end

  def test_pointer_cast_of_variable_is_rejected
    src = <<~C
      int n;
      void *p = (void *)n;
    C
    assert_unsupported_initializer(src)
  end

  # --- rubycc's own linkers (addend applied by our toolchain) -------------

  # Drives Rubycc::Link::ExecutableLinker on an "&arr[i]" global, then runs the
  # ET_EXEC, so the R_X86_64_64 addend is resolved by our own executable linker.
  def test_executable_linker_applies_the_addend
    skip_unless_runnable

    src = <<~C
      static int table[5] = {2, 4, 8, 16, 32};
      static int *q = &table[3];
      int main(void) { return *q; }
    C
    Dir.mktmpdir("rubycc-addr-exe") do |dir|
      obj = File.join(dir, "u.o")
      File.binwrite(obj, Rubycc::Compiler.new.compile(src, filename: "u.c"))
      exe = File.join(dir, "a.out")
      ExecLinker.link_to([obj], exe)
      File.chmod(0o755, exe)
      _out, status = Open3.capture2(exe)
      assert_equal 16, status.exitstatus, "our executable linker must apply the &table[3] addend"
    end
  end

  # Drives Rubycc::Link::SharedLinker on a computed-address global, dlopens the
  # result and reads it back, so the addend rides through our shared-object path
  # (and its R_X86_64_RELATIVE rebasing) too.
  def test_shared_linker_applies_the_addend
    skip_unless_x86_execution
    skip "not a Linux host" unless RUBY_PLATFORM.include?("linux")

    src = <<~C
      static int table[5] = {2, 4, 8, 16, 32};
      static int *q = &table[3];
      int pick(void) { return *q; }
    C
    Dir.mktmpdir("rubycc-addr-so") do |dir|
      obj = File.join(dir, "u.o")
      File.binwrite(obj, Rubycc::Compiler.new.compile(src, filename: "u.c"))
      so = File.join(dir, "libaddr.so")
      SharedLinker.link_to([obj], so)
      lib = Fiddle.dlopen(so)
      pick = Fiddle::Function.new(lib["pick"], [], Fiddle::TYPE_INT)
      assert_equal 16, pick.call, "our shared linker must rebase the &table[3] initializer"
    ensure
      lib&.close
    end
  end

  # --- diagnostics: still-unfoldable forms --------------------------------

  def test_non_constant_index_is_rejected
    src = <<~C
      int n;
      int table[5];
      int *q = &table[n];
    C
    assert_unsupported_initializer(src)
  end

  def test_function_call_result_is_rejected
    src = <<~C
      int *f(void);
      int *q = f();
    C
    assert_unsupported_initializer(src)
  end

  # A run-time pointer value (another pointer object's contents) is not an
  # address constant.
  def test_pointer_variable_value_is_rejected
    src = <<~C
      int table[5];
      int *base = table;
      int *q = base + 1;
    C
    assert_unsupported_initializer(src)
  end

  private

  # Compiles `src` with both rubycc and gcc, links and runs each, asserting both
  # exit with `expected` — so the folded addend matches gcc's own layout.
  def assert_matches_gcc(expected, src)
    assert_c_exit_status(expected, src, compiler: :rubycc)
    assert_c_exit_status(expected, src, compiler: :gcc)
  end

  def assert_unsupported_initializer(src)
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(src, filename: "foo.c")
    end
    assert_match(/unsupported initializer for global variable/, error.message)
  end

  def skip_unless_runnable
    skip "not a Linux host" unless RUBY_PLATFORM.include?("linux")
    skip "x86_64 linker runtime checks are not active (current target: #{ExecutionHelper::EXECUTION_TARGET})" \
      unless ExecutionHelper::EXECUTION_TARGET == "x86_64"
    interp = ["/lib64/ld-linux-x86-64.so.2", "/lib/ld-musl-x86_64.so.1"].any? { |p| File.exist?(p) }
    libc = ExecLinker::DEFAULT_LIBC_PATHS.any? { |p| File.exist?(p) }
    skip "no dynamic loader / libc on host" unless interp && libc
  end
end
