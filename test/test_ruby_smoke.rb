# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "tmpdir"

# Step 28 Phase C5b: the M1 smoke-test criterion. A real C extension begins with
# "#include <ruby.h>", which drags in the whole CRuby public-header graph
# (ruby/ruby.h, ruby/intern.h, the arch config, and through them a good part of
# libc's headers). Compiling such a translation unit all the way to a
# relocatable object is the end-to-end proof that the M1 preprocessor + parser +
# generator subset survives the headers a working extension actually uses —
# a far larger and less curated input than the hand-written examples or the
# vendored conformance suite.
#
# The test compiles through Rubycc::Compiler (source straight to an ELF object
# in memory), so it needs no linker and produces no runnable program: an
# extension's real entry points are resolved by the Ruby runtime, which this
# harness does not stand up. Producing a non-empty object is the success signal.
class TestRubySmoke < Minitest::Test
  # CRuby's own public headers, discovered at runtime from the interpreter
  # running the suite (rather than pinned) so the test tracks whatever Ruby
  # built it: "rubyhdrdir" holds ruby.h and the ruby/ tree, "rubyarchhdrdir"
  # the per-arch "ruby/config.h" ruby.h includes.
  RUBY_HDR_DIR = RbConfig::CONFIG["rubyhdrdir"]
  RUBY_ARCH_HDR_DIR = RbConfig::CONFIG["rubyarchhdrdir"]

  # The libc header directories on this host. gcc's private include directory
  # (/usr/lib/gcc/.../include, where stdarg.h and kin live) is deliberately
  # absent: rubycc now ships those compiler-supplied headers itself and injects
  # them (with the libc directories) as its default system search path (Step 41),
  # so this test relies on nothing under /usr/lib/gcc.
  SYSTEM_INCLUDE_PATHS = [
    "/usr/local/include",
    "/usr/include/x86_64-linux-gnu",
    "/usr/include"
  ].freeze

  # The Ruby headers first (so <ruby.h> and its arch "ruby/config.h" resolve),
  # then the libc set; rubycc's bundled freestanding headers are appended
  # automatically as part of the default system search path.
  INCLUDE_PATHS = [RUBY_HDR_DIR, RUBY_ARCH_HDR_DIR, *SYSTEM_INCLUDE_PATHS].freeze

  # The bundled header directories, resolved from the gem checkout: the
  # freestanding layer, then the two bundled-libc layers (arch before common).
  BUNDLED_INCLUDE = File.expand_path("../include", __dir__)
  BUNDLED_LIBC_ARCH_INCLUDE = File.expand_path("../include/libc/glibc/x86_64", __dir__)
  BUNDLED_LIBC_INCLUDE = File.expand_path("../include/libc", __dir__)

  # The distroless include path (Step 63 acceptance 2): the bundled freestanding
  # and libc layers plus the CRuby header dirs, with NO host /usr/include on it.
  # Compiling <ruby.h> against this proves the bundled libc first batch carries
  # everything ruby.h reaches for -- without borrowing a single declaration from
  # the host libc's development headers.
  DISTROLESS_INCLUDE_PATHS = [
    BUNDLED_INCLUDE, BUNDLED_LIBC_ARCH_INCLUDE, BUNDLED_LIBC_INCLUDE,
    RUBY_ARCH_HDR_DIR, File.join(RUBY_HDR_DIR.to_s, "ruby/backward"), RUBY_HDR_DIR
  ].freeze

  # A minimal but real extension: define one module in the init entry point.
  SMOKE_SOURCE = <<~C
    #include <ruby.h>
    void Init_smoke(void) { rb_define_module("Smoke"); }
  C

  # A slightly richer extension: a C function using the LONG2NUM/NUM2LONG value
  # conversion macros, registered as a module function. This exercises more of
  # ruby.h's inline-function and macro machinery than the bare module define.
  RICHER_SOURCE = <<~C
    #include <ruby.h>
    static VALUE sum(VALUE self, VALUE a, VALUE b) {
      return LONG2NUM(NUM2LONG(a) + NUM2LONG(b));
    }
    void Init_smoke2(void) {
      VALUE m = rb_define_module("Smoke2");
      rb_define_module_function(m, "sum", sum, 2);
    }
  C

  def setup
    # Non-Linux or dev-header-less environments (no CRuby headers installed, or
    # no libc headers under /usr/include) cannot exercise this path; skip with a
    # clear reason rather than fail.
    unless RUBY_HDR_DIR && File.directory?(RUBY_HDR_DIR)
      skip "CRuby public headers (rubyhdrdir) not found: #{RUBY_HDR_DIR.inspect}"
    end
    unless File.exist?("/usr/include/stdio.h")
      skip "system libc headers not found (/usr/include/stdio.h missing)"
    end
  end

  def test_includes_ruby_h_and_compiles_a_module_init_to_an_object
    object = compile_extension(SMOKE_SOURCE, "smoke.c")
    refute_empty object, "expected a non-empty relocatable object from #include <ruby.h>"
  end

  def test_compiles_a_module_function_using_value_conversion_macros
    object = compile_extension(RICHER_SOURCE, "smoke2.c")
    refute_empty object, "expected a non-empty relocatable object for the richer extension"
  end

  # The distroless criterion (Step 63): <ruby.h> compiles to an object using only
  # the bundled headers and the CRuby dirs, with the host /usr/include suppressed
  # entirely (-nostdinc, i.e. system_includes: false, and no /usr/include on the
  # -I list). This is the M3 "no host libc dev headers" target. The bundled first
  # batch supplies the C library surface; the errno/sys-stat (c)-group headers it
  # transitively reaches are provided as measured minimal stubs brought forward
  # from the next step.
  def test_ruby_h_compiles_against_bundled_headers_only_no_host_libc
    [["smoke.c", SMOKE_SOURCE], ["smoke2.c", RICHER_SOURCE]].each do |filename, source|
      object = Dir.mktmpdir("rubycc-distroless") do |dir|
        obj = Rubycc::Compiler.new.compile(
          source, filename: filename,
          include_paths: DISTROLESS_INCLUDE_PATHS, system_includes: false
        )
        File.binwrite(File.join(dir, "#{File.basename(filename, ".c")}.o"), obj)
        obj
      end
      refute_empty object,
                   "expected #{filename} to compile against bundled headers with no host libc"
    end
  end

  private

  # Compiles `source` to a relocatable object, writing it into a fresh temp dir
  # (as an on-disk .o, the artifact a build would emit) and returning its bytes.
  # A CompileError surfaces the offending header line verbatim, so a future
  # regression names exactly which construct in the CRuby headers broke.
  def compile_extension(source, filename)
    Dir.mktmpdir("rubycc-ruby-smoke") do |dir|
      object = Rubycc::Compiler.new.compile(source, filename: filename, include_paths: INCLUDE_PATHS)
      object_path = File.join(dir, "#{File.basename(filename, ".c")}.o")
      File.binwrite(object_path, object)
      assert File.size?(object_path), "expected #{object_path} to be written and non-empty"
      object
    end
  end
end
