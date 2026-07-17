# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fiddle"
require "stringio"

# Step 50: rubycc's compiler-support runtime (the libgcc-equivalent). It is an
# `ar` archive the driver appends to the tail of every link so the linker pulls
# a definition in only when an input still references it. The one member of
# record is rb_gc_guarded_ptr_val, the symbol a gcc-built CRuby leaves for the C
# runtime when RB_GC_GUARD takes its non-__GNUC__ fallback (rubycc never defines
# __GNUC__ per DESIGN R7), and which rubycc must therefore supply itself.
#
# Three properties are asserted: the archive is well-formed and indexes the
# runtime symbol (unit); the definition is pulled into a .so only when something
# references it, staying absent otherwise (laziness); and, when pulled in, the
# function is real — dlopened through Fiddle it returns its pointer argument
# unchanged, which is the whole contract.
class TestCompatRuntime < Minitest::Test
  Runtime = Rubycc::Link::CompatRuntime
  ArReader = Rubycc::ObjFile::ArReader
  Reader = Rubycc::ObjFile::ELFReader
  Driver = Rubycc::Driver

  GUARD_SYMBOL = "rb_gc_guarded_ptr_val"

  # A translation unit that references the guard symbol through RB_GC_GUARD's
  # minimal non-__GNUC__ shape: it declares the fallback prototype and evaluates
  # `(*rb_gc_guarded_ptr_val(&v, v))`, so the object leaves the symbol UND and
  # the compat runtime must supply it at link time.
  GUARD_USER = <<~C
    typedef unsigned long VALUE;
    volatile VALUE *#{GUARD_SYMBOL}(volatile VALUE *ptr, VALUE val);
    VALUE keep_alive(VALUE v) { return (*#{GUARD_SYMBOL}(&v, v)); }
  C

  # A translation unit that references nothing from the runtime, so no member
  # may be extracted.
  PLAIN_USER = <<~C
    long twice(long x) { return x + x; }
  C

  # A translation unit that calls the guard function through a wrapper with a
  # simple ABI (pointer + long -> pointer) so Fiddle can drive it and confirm
  # the pointer is returned unchanged.
  GUARD_CALLER = <<~C
    typedef unsigned long VALUE;
    volatile VALUE *#{GUARD_SYMBOL}(volatile VALUE *ptr, VALUE val);
    unsigned long *call_guard(unsigned long *p, unsigned long v) {
      return (unsigned long *)#{GUARD_SYMBOL}((volatile VALUE *)p, v);
    }
  C

  # --- unit: the archive is a well-formed, indexed ar -----------------------

  def test_archive_bytes_is_a_valid_indexed_ar
    ar = ArReader.read(Runtime.archive_bytes)

    refute_empty ar.symbols, "the compat runtime must carry a ranlib symbol index"
    assert_equal Runtime.archive_bytes.object_id, Runtime.archive_bytes.object_id,
                 "archive_bytes must be memoized"
    member = ar.member_defining(GUARD_SYMBOL)
    refute_nil member, "the symbol index must map #{GUARD_SYMBOL} to a member"

    object = Reader.read(member.data)
    guard = object.symbols.find { |s| s.name.to_s == GUARD_SYMBOL }
    refute_nil guard, "the member must define #{GUARD_SYMBOL}"
    assert guard.defined?, "#{GUARD_SYMBOL} must be a defined symbol in the member"
  end

  # --- laziness: extracted only when referenced -----------------------------

  def test_guard_symbol_is_absent_when_not_referenced
    in_tmpdir do |dir|
      so = build_shared(dir, "plain.c", PLAIN_USER, "plain.so")
      refute exports_guard?(so),
             "a .so that never references #{GUARD_SYMBOL} must not carry the compat definition"
    end
  end

  def test_guard_symbol_is_defined_when_referenced
    in_tmpdir do |dir|
      so = build_shared(dir, "guard.c", GUARD_USER, "guard.so")
      assert exports_guard?(so),
             "a .so that references #{GUARD_SYMBOL} must pull the compat definition in"
    end
  end

  def test_nodefaultlibs_suppresses_the_runtime
    in_tmpdir do |dir|
      so = build_shared(dir, "guard.c", GUARD_USER, "guard.so", "-nodefaultlibs")
      refute exports_guard?(so),
             "-nodefaultlibs must keep the compat runtime out of the link"
    end
  end

  # --- contract: the pulled-in function returns its pointer unchanged --------

  def test_pulled_in_guard_returns_its_pointer_argument
    in_tmpdir do |dir|
      so = build_shared(dir, "caller.c", GUARD_CALLER, "caller.so")

      handle = Fiddle.dlopen(so)
      wrapper = Fiddle::Function.new(handle["call_guard"],
                                     [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
                                     Fiddle::TYPE_VOIDP)
      slot = Fiddle::Pointer.malloc(Fiddle::SIZEOF_LONG)
      returned = wrapper.call(slot, 0xABCDEF)
      assert_equal slot.to_i, returned.to_i,
                   "#{GUARD_SYMBOL} must hand its pointer argument back unchanged"

      direct = Fiddle::Function.new(handle[GUARD_SYMBOL],
                                    [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
                                    Fiddle::TYPE_VOIDP)
      assert_equal slot.to_i, direct.call(slot, 0).to_i,
                   "the exported #{GUARD_SYMBOL} must itself return its pointer unchanged"
    ensure
      handle&.close
    end
  end

  private

  def in_tmpdir(&block)
    Dir.mktmpdir("rubycc-compat-runtime", &block)
  end

  # Compiles `source` into a .so with the rubycc driver in-process and returns
  # the output path. Extra driver flags may be appended (e.g. -nodefaultlibs).
  def build_shared(dir, filename, source, output, *extra)
    source_path = File.join(dir, filename)
    so_path = File.join(dir, output)
    File.write(source_path, source)
    status = Driver.run(["-shared", "-fPIC", *extra, "-o", so_path, source_path],
                        stdout: StringIO.new, stderr: StringIO.new)
    assert_equal 0, status, "driver failed to build #{output}"
    so_path
  end

  # Whether a shared object defines and exports the guard symbol in its .dynsym.
  def exports_guard?(so_path)
    Reader.read_file(so_path).dynamic_symbols.any? do |sym|
      sym.name.to_s == GUARD_SYMBOL && sym.defined?
    end
  end
end
