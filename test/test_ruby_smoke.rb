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

  # The system header search path gcc (13, on this host) uses by default
  # (`gcc -xc -E -v /dev/null`, "#include <...> search starts here"). rubycc
  # has no header-discovery logic of its own yet (ROADMAP), so the harness pins
  # the paths this environment's gcc reports rather than shelling out to
  # rediscover them on every run; if the host toolchain moves (gcc version,
  # distro layout), these need updating alongside it. Kept identical to
  # TestCSuite::SYSTEM_INCLUDE_PATHS so both harnesses see the same libc headers.
  SYSTEM_INCLUDE_PATHS = [
    "/usr/lib/gcc/x86_64-linux-gnu/13/include",
    "/usr/local/include",
    "/usr/include/x86_64-linux-gnu",
    "/usr/include"
  ].freeze

  # The Ruby headers first (so <ruby.h> and its arch "ruby/config.h" resolve),
  # then the system set for the libc headers they pull in.
  INCLUDE_PATHS = [RUBY_HDR_DIR, RUBY_ARCH_HDR_DIR, *SYSTEM_INCLUDE_PATHS].freeze

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
