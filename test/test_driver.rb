# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"
require "stringio"
require "fiddle"

# Exercises the gcc-compatible command-line driver (Rubycc::Driver): the piece
# that turns a compiler-driver invocation into calls on the compiler and linker
# components. The driver is run through the installed exe (a subprocess, the way
# a build actually invokes it) so argument handling, mode selection and the
# one-shot compile+link path are checked end to end. Host-dependent cases (a
# runnable executable, real -lz) are skip-guarded.
class TestDriver < Minitest::Test
  include ExecutionHelper

  EXE_PATH = File.expand_path("../exe/rubycc", __dir__)
  LIB_DIR  = File.expand_path("../lib", __dir__)

  Reader = Rubycc::ObjFile::ELFReader

  # Runs the driver exe in `dir`, returning [stdout, stderr, status].
  def rubycc(*args, dir:)
    Open3.capture3("ruby", "-I#{LIB_DIR}", EXE_PATH, *args, chdir: dir)
  end

  # --- compile-only (-c) --------------------------------------------------

  # A single source with -c and -o produces exactly that object (the existing
  # slice's behavior, preserved).
  def test_compile_single_source_to_named_object
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "int answer(void){ return 42; }")
      _out, err, status = rubycc("-c", "u.c", "-o", "u.o", dir: dir)
      assert_equal 0, status.exitstatus, err
      assert_equal "\x7FELF".b, File.binread(File.join(dir, "u.o"), 4)
    end
  end

  # Without -o each compiled source lands in the current directory under its
  # basename with a .o suffix.
  def test_compile_defaults_object_name_to_basename
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "int main(void){ return 0; }")
      _out, err, status = rubycc("-c", "u.c", dir: dir)
      assert_equal 0, status.exitstatus, err
      assert File.exist?(File.join(dir, "u.o"))
    end
  end

  # gcc rejects one -o naming several compilations; the driver diagnoses it.
  def test_compile_multiple_sources_with_o_is_an_error
    in_tmpdir do |dir|
      File.write(File.join(dir, "a.c"), "int a(void){ return 1; }")
      File.write(File.join(dir, "b.c"), "int b(void){ return 2; }")
      _out, err, status = rubycc("-c", "-o", "out.o", "a.c", "b.c", dir: dir)
      assert_equal 1, status.exitstatus
      assert_match(/cannot specify '-o' with '-c'/, err)
    end
  end

  # C++ is outside rubycc's language scope. Diagnose every C++ source/header
  # suffix at input classification time, before compile-only can turn it into a
  # misleading "linker input unused" warning.
  def test_cpp_inputs_are_rejected_with_a_diagnostic
    in_tmpdir do |dir|
      %w[.cpp .cc .cxx .c++ .hpp .hxx .hh].each do |extension|
        path = "input#{extension}"
        File.write(File.join(dir, path), "int main(void){ return 0; }")
        _out, err, status = rubycc("-c", path, "-o", "input.o", dir: dir)

        assert_equal 1, status.exitstatus, "#{path}: #{err}"
        assert_match(/C\+\+ input 'input#{Regexp.escape(extension)}' is not supported/, err)
        refute File.exist?(File.join(dir, "input.o")), "#{path} must not produce an object"
      end
    end
  end

  # The same classification must protect the link path, where the old behavior
  # eventually failed with a missing object rather than identifying C++ input.
  def test_cpp_input_is_rejected_before_linking
    in_tmpdir do |dir|
      File.write(File.join(dir, "em.cpp"), "int main(void){ return 0; }")
      _out, err, status = rubycc("-o", "prog", "em.cpp", dir: dir)

      assert_equal 1, status.exitstatus
      assert_match(/C\+\+ input 'em\.cpp' is not supported/, err)
      refute File.exist?(File.join(dir, "prog")), "a refused input must not produce an executable"
    end
  end

  # Non-C++ unknown suffixes remain linker inputs, preserving gcc-compatible
  # fallback behavior for build systems that use a custom object suffix.
  def test_unknown_suffix_remains_a_linker_input
    skip_unless_runnable

    in_tmpdir do |dir|
      File.write(File.join(dir, "lib.c"), "int twice(int x){ return x * 2; }")
      _out, err, status = rubycc("-c", "lib.c", "-o", "lib.o", dir: dir)
      assert_equal 0, status.exitstatus, err
      File.rename(File.join(dir, "lib.o"), File.join(dir, "lib.custom"))

      File.write(File.join(dir, "main.c"), "int twice(int); int main(void){ return twice(21); }")
      _out, err, status = rubycc("-o", "prog", "main.c", "lib.custom", dir: dir)
      assert_equal 0, status.exitstatus, err

      _out, run = Open3.capture2(File.join(dir, "prog"))
      assert_equal 42, run.exitstatus
    end
  end

  # Ordinary link inputs still keep gcc's compile-only warning behavior; the
  # C++ rejection must not broaden into a rejection of `.o` inputs.
  def test_object_input_still_warns_in_compile_only_mode
    in_tmpdir do |dir|
      _out, err, status = rubycc("-c", "input.o", dir: dir)

      assert_equal 0, status.exitstatus
      assert_match(/input\.o: linker input file unused because linking not done/, err)
    end
  end

  # --- one-shot compile + link (executable) -------------------------------

  # Two translation units that reference each other's functions/globals compile
  # and link in one command, and the executable runs with the expected status
  # and stdout — matching a gcc-built counterpart.
  def test_multi_unit_one_shot_executable_matches_gcc
    skip_unless_runnable

    a = <<~C
      int helper(int x);
      extern int base;
      int printf(const char *, ...);
      int main(void) { printf("r=%d\\n", helper(base)); return helper(base); }
    C
    b = <<~C
      int base = 20;
      int helper(int x) { return x + 22; }
    C
    in_tmpdir do |dir|
      File.write(File.join(dir, "a.c"), a)
      File.write(File.join(dir, "b.c"), b)
      _out, err, status = rubycc("-o", "prog", "a.c", "b.c", dir: dir)
      assert_equal 0, status.exitstatus, err

      exe = File.join(dir, "prog")
      out, run = Open3.capture2(exe)
      assert_equal "r=42\n", out
      assert_equal 42, run.exitstatus

      gout, gstatus = gcc_reference([["a.c", a], ["b.c", b]], dir)
      skip "gcc unavailable" unless gout
      assert_equal gout, out
      assert_equal gstatus, run.exitstatus
    end
  end

  # A .c and a separately compiled .o link together in one command.
  def test_mixes_source_and_object_inputs
    skip_unless_runnable

    in_tmpdir do |dir|
      File.write(File.join(dir, "lib.c"), "int twice(int x){ return x*2; }")
      _out, err, status = rubycc("-c", "lib.c", "-o", "lib.o", dir: dir)
      assert_equal 0, status.exitstatus, err

      File.write(File.join(dir, "main.c"),
                 "int twice(int); int main(void){ return twice(9); }")
      _out, err, status = rubycc("-o", "prog", "main.c", "lib.o", dir: dir)
      assert_equal 0, status.exitstatus, err

      _out, run = Open3.capture2(File.join(dir, "prog"))
      assert_equal 18, run.exitstatus
    end
  end

  # --- shared objects (-shared) -------------------------------------------

  # -shared produces a loadable .so whose function runs when dlopened, and
  # -Wl,-soname sets its DT_SONAME.
  def test_shared_object_is_dlopenable_and_takes_a_soname
    skip_unless_linux

    src = "int add(int a, int b){ return a + b; }"
    in_tmpdir do |dir|
      File.write(File.join(dir, "m.c"), src)
      _out, err, status = rubycc("-shared", "-fPIC", "-Wl,-soname,libadd.so.1",
                                 "-o", "libadd.so", "m.c", dir: dir)
      assert_equal 0, status.exitstatus, err

      so = File.join(dir, "libadd.so")
      assert_equal "libadd.so.1", Reader.read_file(so).soname
      lib = Fiddle.dlopen(so)
      fn = Fiddle::Function.new(lib["add"], [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      assert_equal 30, fn.call(12, 18)
    ensure
      lib&.close
    end
  end

  # --- -D / -U wiring -----------------------------------------------------

  # -DNAME=VALUE reaches the preprocessor: the #if selects the guarded branch.
  def test_dash_d_defines_a_macro_visible_to_if
    skip_unless_runnable

    src = <<~C
      #if FOO == 7
      int main(void) { return 7; }
      #else
      int main(void) { return 1; }
      #endif
    C
    in_tmpdir do |dir|
      File.write(File.join(dir, "d.c"), src)
      _out, err, status = rubycc("-DFOO=7", "-o", "d", "d.c", dir: dir)
      assert_equal 0, status.exitstatus, err
      _out, run = Open3.capture2(File.join(dir, "d"))
      assert_equal 7, run.exitstatus
    end
  end

  # -DNAME with no value defaults to 1, and a later -U undoes an earlier -D.
  def test_dash_d_defaults_to_one_and_dash_u_undefines
    skip_unless_runnable

    src = <<~C
      #ifdef ON
      int main(void) { return ON + 4; }
      #else
      int main(void) { return 9; }
      #endif
    C
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), src)
      _out, err, status = rubycc("-DON", "-o", "on", "u.c", dir: dir)
      assert_equal 0, status.exitstatus, err
      _out, run = Open3.capture2(File.join(dir, "on"))
      assert_equal 5, run.exitstatus, "-DON defaults to 1, so ON+4 == 5"

      _out, err, status = rubycc("-DON", "-UON", "-o", "off", "u.c", dir: dir)
      assert_equal 0, status.exitstatus, err
      _out, run = Open3.capture2(File.join(dir, "off"))
      assert_equal 9, run.exitstatus, "-UON undoes the earlier -DON"
    end
  end

  # --- -E preprocess-only -------------------------------------------------

  # -E runs the preprocessor and writes the expanded tokens (here to stdout).
  def test_dash_e_expands_macros_to_stdout
    in_tmpdir do |dir|
      File.write(File.join(dir, "e.c"), "#define ANSWER 42\nint x = ANSWER;\n")
      out, err, status = rubycc("-E", "e.c", dir: dir)
      assert_equal 0, status.exitstatus, err
      assert_match(/int x = 42\s*;/, out)
      refute_match(/ANSWER/, out, "the macro must be expanded, not passed through")
    end
  end

  # -E honors -D as well, and can write to -o.
  def test_dash_e_with_define_writes_to_output_file
    in_tmpdir do |dir|
      File.write(File.join(dir, "e.c"), "int v = VAL;\n")
      _out, err, status = rubycc("-E", "-DVAL=99", "-o", "e.i", "e.c", dir: dir)
      assert_equal 0, status.exitstatus, err
      assert_match(/int v = 99\s*;/, File.read(File.join(dir, "e.i")))
    end
  end

  # --- #warning and the warning channel ------------------------------------

  # A translation unit with a #warning compiles: the message goes to standard
  # error in the usual diagnostic format, the object is written, and the exit
  # status is 0 -- the whole point of the directive (C23 6.10.2p2). gcc 13.3.0
  # measured the same on the same input (2026-08-19).
  def test_warning_directive_compiles_and_reports_on_stderr
    in_tmpdir do |dir|
      File.write(File.join(dir, "w.c"), %(#warning "unrecognized compiler"\nint main(void){ return 0; }\n))
      out, err, status = rubycc("-c", "w.c", "-o", "w.o", dir: dir)

      assert_equal 0, status.exitstatus, err
      assert File.exist?(File.join(dir, "w.o"))
      assert_equal ['w.c:1:1: warning: "unrecognized compiler"',
                    '#warning "unrecognized compiler"',
                    "^"], err.split("\n")
      assert_empty out, "the warning must not reach standard output"
    end
  end

  # The message needs no quotes; whatever the rest of the line spells is what
  # is reported.
  def test_warning_directive_accepts_an_unquoted_message
    in_tmpdir do |dir|
      File.write(File.join(dir, "w.c"), "#warning unrecognized compiler\nint main(void){ return 0; }\n")
      _out, err, status = rubycc("-c", "w.c", "-o", "w.o", dir: dir)

      assert_equal 0, status.exitstatus, err
      assert_match(/w\.c:1:1: warning: unrecognized compiler/, err)
    end
  end

  # -E writes preprocessed text to standard output; a warning raised while
  # preprocessing must not be mixed into it.
  def test_warning_during_dash_e_keeps_stdout_clean
    in_tmpdir do |dir|
      File.write(File.join(dir, "w.c"), "#warning noisy\nint x = 1;\n")
      out, err, status = rubycc("-E", "w.c", dir: dir)

      assert_equal 0, status.exitstatus, err
      assert_match(/int x = 1\s*;/, out)
      refute_match(/warning/, out)
      assert_match(/warning: noisy/, err)
    end
  end

  # "-w" is honored: it silences the compiler's warnings (and is no longer
  # reported as an unknown option, which it was before this channel existed).
  def test_suppress_warnings_flag_silences_the_warning
    in_tmpdir do |dir|
      File.write(File.join(dir, "w.c"), "#warning noisy\nint main(void){ return 0; }\n")
      _out, err, status = rubycc("-c", "-w", "w.c", "-o", "w.o", dir: dir)

      assert_equal 0, status.exitstatus, err
      assert File.exist?(File.join(dir, "w.o"))
      assert_empty err.strip
    end
  end

  # "-Werror" is deliberately *not* honored (see Driver#silently_ignored?):
  # promoting the single warning rubycc implements, while staying silent about
  # everything else gcc would warn on, would only bring back the build failure
  # #warning support exists to end. The flag stays accepted and ignored.
  def test_werror_does_not_promote_the_warning
    in_tmpdir do |dir|
      File.write(File.join(dir, "w.c"), "#warning noisy\nint main(void){ return 0; }\n")
      _out, err, status = rubycc("-c", "-Werror", "w.c", "-o", "w.o", dir: dir)

      assert_equal 0, status.exitstatus, err
      assert File.exist?(File.join(dir, "w.o"))
      assert_match(/warning: noisy/, err)
      refute_match(/error:/, err)
    end
  end

  # #error is untouched by any of this: it still ends the compile.
  def test_error_directive_still_fails_the_build
    in_tmpdir do |dir|
      File.write(File.join(dir, "e.c"), "#warning first\n#error stop right here\nint main(void){ return 0; }\n")
      _out, err, status = rubycc("-c", "e.c", "-o", "e.o", dir: dir)

      assert_equal 1, status.exitstatus
      assert_match(/e\.c:2:1: error: stop right here/, err)
      assert_match(/warning: first/, err)
      refute File.exist?(File.join(dir, "e.o"))
    end
  end

  # --- unknown / tolerated flags ------------------------------------------

  # An unknown option is warned about and ignored; a build with a valid input
  # alongside it still succeeds.
  def test_unknown_flag_warns_but_build_succeeds
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "int main(void){ return 0; }")
      _out, err, status = rubycc("-c", "-mavx2", "u.c", "-o", "u.o", dir: dir)
      assert_equal 0, status.exitstatus, err
      assert File.exist?(File.join(dir, "u.o"))
      assert_match(/warning: unknown option '-mavx2' ignored/, err)
    end
  end

  # A documented optimization/warning flag family is accepted with no warning.
  def test_optimization_and_warning_flags_are_silently_accepted
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "int main(void){ return 0; }")
      _out, err, status = rubycc("-c", "-O2", "-g", "-Wall", "-std=c11",
                                 "u.c", "-o", "u.o", dir: dir)
      assert_equal 0, status.exitstatus, err
      assert_empty err.strip, "documented flags must be accepted silently"
    end
  end

  # --- error handling -----------------------------------------------------

  def test_missing_output_operand_is_an_error
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "int main(void){ return 0; }")
      _out, err, status = rubycc("-c", "u.c", "-o", dir: dir)
      assert_equal 1, status.exitstatus
      assert_match(/missing filename after '-o'/, err)
    end
  end

  def test_no_input_is_an_error
    in_tmpdir do |dir|
      _out, err, status = rubycc("-c", dir: dir)
      assert_equal 1, status.exitstatus
      assert_match(/no input file/, err)
    end
  end

  # A compile error is reported with its diagnostic and a non-zero exit.
  def test_compile_error_is_reported
    in_tmpdir do |dir|
      File.write(File.join(dir, "bad.c"), "int main(void){ return }")
      _out, err, status = rubycc("-c", "bad.c", "-o", "bad.o", dir: dir)
      assert_equal 1, status.exitstatus
      assert_match(/error:/, err)
    end
  end

  # --- real library resolution (-lz) --------------------------------------

  # A one-shot -shared build that resolves the host's real zlib (-lz) and calls
  # crc32 through it, checking the standard CRC and the recorded DT_NEEDED.
  def test_links_real_libz_end_to_end
    skip_unless_linux
    skip "libz unavailable" unless libz_available?

    src = <<~C
      unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len);
      unsigned long my_crc(const unsigned char *s, unsigned int n) { return crc32(0, s, n); }
    C
    in_tmpdir do |dir|
      File.write(File.join(dir, "z.c"), src)
      _out, err, status = rubycc("-shared", "-fPIC", "-o", "libztest.so",
                                 "z.c", "-lz", dir: dir)
      assert_equal 0, status.exitstatus, err

      so = File.join(dir, "libztest.so")
      assert_includes Reader.read_file(so).needed, "libz.so.1",
                      "the DT_NEEDED is zlib's SONAME"
      lib = Fiddle.dlopen(so)
      fn = Fiddle::Function.new(lib["my_crc"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
                                Fiddle::TYPE_LONG)
      assert_equal 0xCBF43926, fn.call("123456789", 9) & 0xFFFFFFFF
    ensure
      lib&.close
    end
  end

  # --- target selection (-target / --target) ------------------------------

  # The default target is the host CPU, so an ordinary -c without -target
  # produces an object the host linker can consume. This must be checked on
  # every native backend rather than asserting the historical x86_64 default.
  def test_default_target_compiles_on_host
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "int main(void){ return 0; }")
      _out, err, status = rubycc("-c", "u.c", "-o", "u.o", dir: dir)
      assert_equal 0, status.exitstatus, err
      machine = Reader.read_file(File.join(dir, "u.o")).machine
      expected = host_target == "aarch64" ? Reader::EM_AARCH64 : Reader::EM_X86_64
      assert_equal expected, machine
    end
  end

  # An explicit -target x86_64 is accepted and produces the same object.
  def test_explicit_x86_64_target_is_accepted
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "int main(void){ return 0; }")
      _out, err, status = rubycc("-c", "u.c", "-target", "x86_64", "-o", "u.o", dir: dir)
      assert_equal 0, status.exitstatus, err
      assert_equal "\x7FELF".b, File.binread(File.join(dir, "u.o"), 4)
    end
  end

  # -target aarch64 is accepted under every spelling the target normalizer
  # recognizes, and each produces an EM_AARCH64 (183) object — cross-compiling
  # on an x86_64 host, so this asserts on the object's header rather than
  # running it.
  def test_aarch64_target_produces_an_aarch64_object
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "int main(void){ return 0; }")
      ["aarch64", "arm64", "aarch64-linux-gnu"].each do |spelling|
        _out, err, status = rubycc("-c", "u.c", "--target=#{spelling}", "-o", "u.o", dir: dir)
        assert_equal 0, status.exitstatus, err
        obj = Reader.read_file(File.join(dir, "u.o"))
        assert_equal Reader::EM_AARCH64, obj.machine, "#{spelling} selects the aarch64 backend"
        assert obj.relocatable?
      end
    end
  end

  # A backend that cannot lower some construct reports it as a driver
  # diagnostic with a non-zero exit, never as a Ruby crash and never as a
  # silently wrong object.
  #
  # This used to be driven by naming a construct the aarch64 backend had not
  # reached yet, and the example moved four times as the backend grew: string
  # literals and globals before A3 (Step 72) added the memory-access layer, then
  # indirect calls until A4's first half lowered them, then whole-struct
  # assignment until aggregates by value arrived, then alloca until
  # m4/aarch64-alloca-bitscan-2. There is no fifth example — both backends now
  # lower everything the generator emits — so the failure is injected instead.
  #
  # Injecting the refusal is against this suite's grain (everything else here
  # runs the real driver end to end, and a test that fakes what it is checking
  # checks nothing). It is the right tool for exactly this case: the subject is
  # the driver's *handling* of a backend refusal, the backend is not under test
  # at all, and the alternative is to delete the coverage of a rescue clause the
  # next target will depend on. The driver runs for real, in-process so its
  # streams can be captured; only the refusal is manufactured.
  def test_backend_unsupported_construct_is_diagnosed
    in_tmpdir do |dir|
      source = File.join(dir, "u.c")
      object = File.join(dir, "u.o")
      File.write(source, "int f(int n){ return n + 1; }")
      err = StringIO.new

      status = with_refusing_backend("aarch64: not yet supported: widgets") do
        Rubycc::Driver.run(["-c", source, "-target", "aarch64", "-o", object], stderr: err)
      end

      assert_equal 1, status
      assert_match(/rubycc: error: aarch64: not yet supported: widgets/, err.string)
      refute File.exist?(object), "no object is written for a refused compilation"
    end
  end

  # Runs the block with the aarch64 backend refusing every function, then puts
  # the class back. Done by hand rather than with a mocking library because
  # minitest 6 no longer ships one, and a gem dependency for a single injection
  # point is not worth it. Removing the singleton method restores Class#new,
  # which is where the class inherited it from to begin with.
  def with_refusing_backend(message)
    backend = Rubycc::Backend::AArch64
    backend.define_singleton_method(:new) do |*|
      raise Rubycc::Backend::UnsupportedError, message
    end
    yield
  ensure
    backend.singleton_class.send(:remove_method, :new)
  end

  # An entirely unknown target is rejected as unsupported.
  def test_unknown_target_is_unsupported
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "int main(void){ return 0; }")
      _out, err, status = rubycc("-c", "u.c", "-target", "riscv64", "-o", "u.o", dir: dir)
      assert_equal 1, status.exitstatus
      assert_match(/unsupported target 'riscv64'/, err)
    end
  end

  private

  def in_tmpdir(&block)
    Dir.mktmpdir("rubycc-driver", &block)
  end

  # Builds the same units with gcc for a differential comparison; returns
  # [stdout, exit_status] or [nil, nil] when gcc is unavailable/fails.
  def gcc_reference(units, dir)
    return [nil, nil] unless tool?("gcc")

    paths = units.map { |name, src| File.write(File.join(dir, name), src); File.join(dir, name) }
    exe = File.join(dir, "gcc-ref")
    _out, status = Open3.capture2e("gcc", "-no-pie", "-o", exe, *paths)
    return [nil, nil] unless status.success?

    out, run = Open3.capture2(exe)
    [out, run.exitstatus]
  end

  def libz_available?
    Rubycc::Link::LibraryResolver.resolve(["z"])
    true
  rescue Rubycc::Link::LinkError
    false
  end

  def linkable?
    host_linkable?
  end

  def skip_unless_linux
    skip "not a Linux host" unless RUBY_PLATFORM.include?("linux")
  end

  def skip_unless_runnable
    skip_unless_linux
    skip "no dynamic loader / libc on host" unless linkable?
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
