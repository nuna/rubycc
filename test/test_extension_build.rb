# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "tmpdir"
require "open3"

# Step 39: the M2 acceptance criterion. A Ruby C extension built end to end
# with only the rubycc driver (no gcc anywhere in the build) is loadable by a
# stock Ruby with `require`, and its Init_* entry point resolves the rb_*
# symbols it leaves UND against the running interpreter — the exact contract
# `rb_define_module`, `INT2NUM`, `rb_str_new_cstr` and friends rely on. Unlike
# TestRubySmoke (which stops at a compiled .o, since it has no linker), this
# harness drives -shared -fPIC through the driver exe, produces a real .so,
# and hands it to a *separate* Ruby process's `require` so the resolution
# genuinely happens against a live interpreter rather than this test's own.
class TestExtensionBuild < Minitest::Test
  HOST_TARGET = HostTarget.name

  # CRuby's own public headers, discovered at runtime from the interpreter
  # running the suite (rather than pinned), matching TestRubySmoke.
  RUBY_HDR_DIR = RbConfig::CONFIG["rubyhdrdir"]
  RUBY_ARCH_HDR_DIR = RbConfig::CONFIG["rubyarchhdrdir"]

  # The libc header directories on this host, matching TestRubySmoke /
  # TestCSuite. gcc's private include directory is deliberately absent: rubycc
  # supplies the compiler-provided headers itself and injects them as its
  # default system search path (Step 41), so the build never reads /usr/lib/gcc.
  SYSTEM_INCLUDE_PATHS = [
    "/usr/local/include",
    (HOST_TARGET == "aarch64" ? "/usr/include/aarch64-linux-gnu" : "/usr/include/x86_64-linux-gnu"),
    "/usr/include"
  ].freeze

  BUNDLED_INCLUDE = File.expand_path("../include", __dir__)
  BUNDLED_LIBC_ARCH_INCLUDE = File.expand_path("../include/libc/glibc/#{HOST_TARGET}", __dir__)
  BUNDLED_LIBC_INCLUDE = File.expand_path("../include/libc", __dir__)
  INCLUDE_PATHS = [RUBY_HDR_DIR, RUBY_ARCH_HDR_DIR, BUNDLED_INCLUDE,
                   BUNDLED_LIBC_ARCH_INCLUDE, BUNDLED_LIBC_INCLUDE,
                   *SYSTEM_INCLUDE_PATHS].freeze
  INCLUDE_FLAGS = INCLUDE_PATHS.map { |p| "-I#{p}" }.freeze

  # For the freestanding-header acceptance (Step 41): only the CRuby header
  # directories are passed as -I. The compiler-supplied headers ruby.h pulls in
  # (stdarg.h, stddef.h, ...) and the libc headers must come entirely from
  # rubycc's own default system search path, so this list names nothing under
  # /usr/lib/gcc and nothing under /usr/include.
  RUBY_ONLY_INCLUDE_FLAGS = [RUBY_HDR_DIR, RUBY_ARCH_HDR_DIR].map { |p| "-I#{p}" }.freeze

  EXE_PATH = File.expand_path("../exe/rubycc", __dir__)
  LIB_DIR  = File.expand_path("../lib", __dir__)

  Reader = Rubycc::ObjFile::ELFReader

  # A minimal but real extension: an integer-arithmetic module function
  # exercising NUM2INT/INT2NUM, and a string-returning one exercising
  # rb_str_new_cstr, both registered on a module in the Init entry point.
  SMOKE_EXT_SOURCE = <<~C
    #include <ruby.h>
    static VALUE ext_add(VALUE self, VALUE a, VALUE b) {
      return INT2NUM(NUM2INT(a) + NUM2INT(b));
    }
    static VALUE ext_hello(VALUE self) {
      return rb_str_new_cstr("hello from rubycc");
    }
    void Init_smoke_ext(void) {
      VALUE m = rb_define_module("SmokeExt");
      rb_define_module_function(m, "add", ext_add, 2);
      rb_define_module_function(m, "hello", ext_hello, 0);
    }
  C

  # Two translation units for the multi-TU case: the Init unit calls a helper
  # defined in the other unit, so the .so must be linked from both objects in
  # one -shared command for Init_multi_ext to resolve.
  MULTI_EXT_INIT_SOURCE = <<~C
    #include <ruby.h>
    int helper_double(int x);
    static VALUE ext_double(VALUE self, VALUE a) {
      return INT2NUM(helper_double(NUM2INT(a)));
    }
    void Init_multi_ext(void) {
      VALUE m = rb_define_module("MultiExt");
      rb_define_module_function(m, "double", ext_double, 1);
    }
  C
  MULTI_EXT_HELPER_SOURCE = <<~C
    int helper_double(int x) { return x * 2; }
  C

  # A TypedData extension (Step 41 acceptance): it exercises the CRuby object
  # machinery a real gem uses — TypedData_Make_Struct / TypedData_Get_Struct,
  # rb_define_alloc_func and xfree — and drags in the compiler-supplied headers
  # (stdarg.h, stddef.h, ...) through ruby.h. Building it with only the CRuby
  # header directories on -I proves rubycc's own bundled freestanding headers
  # plus its default libc search path are sufficient, with no /usr/lib/gcc.
  # Mirrors tmp/step41_box_probe.c (kept as the manual probe of record).
  BOX_EXT_SOURCE = <<~C
    #include <ruby.h>

    typedef struct { long counter; char *name; } box_t;

    static void box_free(void *p) { box_t *b = p; if (b->name) xfree(b->name); xfree(b); }
    static size_t box_size(const void *p) { return sizeof(box_t); }

    static const rb_data_type_t box_type = {
      "Box",
      { 0, box_free, box_size, },
      0, 0, RUBY_TYPED_FREE_IMMEDIATELY,
    };

    static VALUE box_alloc(VALUE klass) {
      box_t *b;
      VALUE obj = TypedData_Make_Struct(klass, box_t, &box_type, b);
      b->counter = 0;
      b->name = 0;
      return obj;
    }

    static VALUE box_incr(VALUE self) {
      box_t *b;
      TypedData_Get_Struct(self, box_t, &box_type, b);
      b->counter++;
      return LONG2NUM(b->counter);
    }

    void Init_box(void) {
      VALUE cBox = rb_define_class("Box", rb_cObject);
      rb_define_alloc_func(cBox, box_alloc);
      rb_define_method(cBox, "incr", box_incr, 0);
    }
  C

  def setup
    skip "host CPU #{HOST_TARGET.inspect} is not a rubycc target" unless Rubycc::Compiler::TARGETS.key?(HOST_TARGET)
    unless RUBY_HDR_DIR && File.directory?(RUBY_HDR_DIR)
      skip "CRuby public headers (rubyhdrdir) not found: #{RUBY_HDR_DIR.inspect}"
    end
    unless File.exist?("/usr/include/stdio.h")
      skip "system libc headers not found (/usr/include/stdio.h missing)"
    end
  end

  # Building with the rubycc driver alone, and requiring the result in a
  # separate Ruby process, must resolve rb_* against the live interpreter and
  # produce the same results a gcc-built extension would.
  def test_rubycc_built_extension_loads_and_runs_under_require
    in_tmpdir do |dir|
      so_path = File.join(dir, "smoke_ext.so")
      write_and_build(dir, "smoke_ext.c", SMOKE_EXT_SOURCE, so_path)
      assert_valid_shared_object(so_path)

      result = require_and_probe(dir, "smoke_ext", <<~RUBY)
        [SmokeExt.add(40, 2), SmokeExt.hello]
      RUBY
      assert_equal [42, "hello from rubycc"], result
    end
  end

  # A gcc-built copy of the same extension must behave identically, cross
  # checking that the rubycc-built .so is not merely loadable but behaves like
  # a conventionally-built one.
  def test_rubycc_and_gcc_built_extensions_agree
    skip "gcc unavailable" unless tool?("gcc")

    in_tmpdir do |dir|
      rubycc_so = File.join(dir, "smoke_ext.so")
      write_and_build(dir, "smoke_ext.c", SMOKE_EXT_SOURCE, rubycc_so)

      gcc_dir = File.join(dir, "gcc_build")
      Dir.mkdir(gcc_dir)
      gcc_so = File.join(gcc_dir, "smoke_ext.so")
      source_path = File.join(gcc_dir, "smoke_ext.c")
      File.write(source_path, SMOKE_EXT_SOURCE)
      _out, err, status = Open3.capture3(
        "gcc", "-shared", "-fPIC", *INCLUDE_FLAGS, "-o", gcc_so, source_path
      )
      assert_equal 0, status.exitstatus, err

      rubycc_result = require_and_probe(dir, "smoke_ext", "[SmokeExt.add(40, 2), SmokeExt.hello]")
      gcc_result = require_and_probe(gcc_dir, "smoke_ext", "[SmokeExt.add(40, 2), SmokeExt.hello]")
      assert_equal [42, "hello from rubycc"], rubycc_result
      assert_equal rubycc_result, gcc_result, "rubycc-built and gcc-built extensions must agree"
    end
  end

  # Two translation units, one -shared invocation: the Init unit's call to a
  # helper defined in the other unit must resolve at rubycc link time, and the
  # combined extension must still load and run correctly.
  def test_multi_unit_extension_links_in_one_shared_command
    in_tmpdir do |dir|
      init_path = File.join(dir, "multi_ext_init.c")
      helper_path = File.join(dir, "multi_ext_helper.c")
      File.write(init_path, MULTI_EXT_INIT_SOURCE)
      File.write(helper_path, MULTI_EXT_HELPER_SOURCE)

      so_path = File.join(dir, "multi_ext.so")
      _out, err, status = rubycc(
        "-shared", "-fPIC", *INCLUDE_FLAGS, "-o", so_path, init_path, helper_path, dir: dir
      )
      assert_equal 0, status.exitstatus, err
      assert_valid_shared_object(so_path)

      result = require_and_probe(dir, "multi_ext", "MultiExt.double(21)")
      assert_equal 42, result
    end
  end

  # A TypedData extension built with rubycc's bundled freestanding headers and
  # default libc search path only (the CRuby headers are the sole -I), with no
  # /usr/lib/gcc anywhere, must load under require and return the counter's
  # successive values.
  def test_typeddata_extension_builds_with_bundled_headers_only
    in_tmpdir do |dir|
      source_path = File.join(dir, "box.c")
      File.write(source_path, BOX_EXT_SOURCE)

      so_path = File.join(dir, "box.so")
      _out, err, status = rubycc(
        "-shared", "-fPIC", *RUBY_ONLY_INCLUDE_FLAGS, "-o", so_path, source_path, dir: dir
      )
      assert_equal 0, status.exitstatus, err
      assert_valid_shared_object(so_path)

      result = require_and_probe(dir, "box", <<~RUBY)
        b = Box.new
        [b.incr, b.incr, b.incr]
      RUBY
      assert_equal [1, 2, 3], result
    end
  end

  private

  def in_tmpdir(&block)
    Dir.mktmpdir("rubycc-ext-build", &block)
  end

  def write_and_build(dir, filename, source, so_path)
    source_path = File.join(dir, filename)
    File.write(source_path, source)
    _out, err, status = rubycc("-shared", "-fPIC", *INCLUDE_FLAGS, "-o", so_path, source_path, dir: dir)
    assert_equal 0, status.exitstatus, err
  end

  # Runs the driver exe in `dir`, returning [stdout, stderr, status].
  def rubycc(*args, dir:)
    Open3.capture3("ruby", "-I#{LIB_DIR}", EXE_PATH, *args, chdir: dir)
  end

  def assert_valid_shared_object(so_path)
    assert File.exist?(so_path), "expected #{so_path} to be produced"
    refute_empty File.binread(so_path), "expected #{so_path} to be non-empty"
    reader = Reader.read_file(so_path)
    assert reader.shared_object?, "expected #{so_path} to be an ET_DYN shared object"
  end

  # The most time a child Ruby process (requiring the extension and evaluating
  # one expression) is given before it is killed as hung.
  CHILD_TIMEOUT = 10

  # Requires the .so under `dir` (as `require_name`) in a fresh Ruby process
  # and evaluates `ruby_expr` in that process, returning the Marshal-decoded
  # result. Isolates the require from this test's own process, so resolution
  # of the extension's rb_* imports against a live interpreter is genuine.
  def require_and_probe(dir, require_name, ruby_expr)
    script = <<~RUBY
      require "./#{require_name}"
      result = begin
        #{ruby_expr}
      end
      STDOUT.binmode
      STDOUT.write(Marshal.dump(result))
    RUBY

    out, status = nil, nil
    Open3.popen2(RbConfig.ruby, "-e", script, chdir: dir) do |stdin, stdout, wait_thr|
      stdin.close
      reader = Thread.new { stdout.read }
      unless reader.join(CHILD_TIMEOUT)
        Process.kill("KILL", wait_thr.pid)
        reader.kill
        flunk "child Ruby process requiring #{require_name} timed out after #{CHILD_TIMEOUT}s"
      end
      out = reader.value
      status = wait_thr.value
    end
    assert status.success?, "child Ruby process requiring #{require_name} failed"
    Marshal.load(out)
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
