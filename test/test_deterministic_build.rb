# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
require "tmpdir"
require "open3"
require "stringio"

# N4 ("decisions build": identical input must yield a byte-identical output,
# no timestamp/uid/pid/hash-order leaking into the binary) as a standing check
# (ROADMAP H6). Each case rebuilds the same input twice through a different
# path — in-process, across two Ruby processes, across a link/archive step, or
# through a full rmake build — and asserts the two outputs are byte-identical.
#
# The C source used for the compile/link cases is deliberately rich: static
# initializers, string literals, several functions (one `static`, so a local
# symbol is present too), global variables of several types, an undefined
# external reference and floating-point constants. This is meant to keep the
# symbol table and relocation list full enough that a nondeterministic
# ordering (symbol table, relocations, hash iteration) would show up as a
# mismatch rather than being masked by a nearly-empty object.
class TestDeterministicBuild < Minitest::Test
  include LibcHelper

  ArWriter = Rubycc::ObjFile::ArWriter
  ArReader = Rubycc::ObjFile::ArReader
  SharedLinker = Rubycc::Link::SharedLinker
  ExecutableLinker = Rubycc::Link::ExecutableLinker
  Rmake = Rubycc::Rmake
  Makefile = Rmake::Makefile

  EXE_PATH = File.expand_path("../exe/rubycc", __dir__)
  LIB_DIR = File.expand_path("../lib", __dir__)

  # A single translation unit exercising: a `static` (local) helper, several
  # global variables (int/double/float/pointer), a string literal, an actual
  # external reference resolved through libc (`printf`, left UND in the object
  # and later bound at link time) and floating-point constants that land in
  # .rodata.
  RICH_UNIT = <<~C
    static int helper(int x) { return x * 3 + 1; }
    int global_counter = 7;
    double pi_value = 3.14159;
    float ratio = 0.5f;
    const char *message = "deterministic build";
    int printf(const char *, ...);
    int add(int a, int b) { return a + b; }
    int use_helper(int x) { return helper(x) + global_counter; }
    double compute(double x) { return x * pi_value + ratio; }
    char *get_message(void) { return (char *)message; }
    int report(void) { return printf("%s\\n", message); }
  C

  MAIN_UNIT = <<~C
    int add(int, int);
    int use_helper(int);
    int report(void);
    int main(void) { return add(use_helper(1), report()) - report(); }
  C

  # --- (1) compilation, in-process, both targets --------------------------

  def test_compile_is_byte_identical_x86_64
    a = Rubycc::Compiler.new.compile(RICH_UNIT, filename: "u.c", target: "x86_64")
    b = Rubycc::Compiler.new.compile(RICH_UNIT, filename: "u.c", target: "x86_64")
    assert_bytes_equal a, b, "x86_64 compile of identical input must be byte-identical"
  end

  def test_compile_is_byte_identical_aarch64
    a = Rubycc::Compiler.new.compile(RICH_UNIT, filename: "u.c", target: "aarch64")
    b = Rubycc::Compiler.new.compile(RICH_UNIT, filename: "u.c", target: "aarch64")
    assert_bytes_equal a, b, "aarch64 compile of identical input must be byte-identical"
  end

  # A unit whose constructors and destructors spread over several priorities.
  # The array sections are grouped out of a Hash keyed by (kind, priority), and
  # a section's *name* is what fixes the run order, so a nondeterministic
  # grouping would reorder both the section table and the initializers.
  CONSTRUCTOR_UNIT = <<~C
    int puts(const char *s);
    __attribute__((constructor(500))) static void c500(void) { puts("500"); }
    __attribute__((constructor))      static void cdef(void) { puts("def"); }
    __attribute__((constructor(101))) static void c101(void) { puts("101"); }
    __attribute__((constructor))      static void cdef2(void) { puts("def2"); }
    __attribute__((destructor(101)))  static void d101(void) { puts("d101"); }
    __attribute__((destructor))       void ddef(void) { puts("ddef"); }
  C

  def test_compile_with_constructors_is_byte_identical
    %w[x86_64 aarch64].each do |target|
      a = Rubycc::Compiler.new.compile(CONSTRUCTOR_UNIT, filename: "c.c", target: target)
      b = Rubycc::Compiler.new.compile(CONSTRUCTOR_UNIT, filename: "c.c", target: target)
      assert_bytes_equal a, b, "#{target} compile of a unit with constructors must be byte-identical"
    end
  end

  # A unit whose atomic builtins reach every lowering shape at both widths. The
  # sequences these produce are the only ones a backend builds with interior
  # branches whose displacements it computes itself (a retry loop's backward
  # branch, a compare-exchange's forward one), so a byte-identical rebuild also
  # says those displacements come out of the emitted byte count rather than
  # anything ambient.
  ATOMIC_UNIT = <<~C
    typedef unsigned long size_t;
    unsigned int counter;
    size_t total;
    unsigned int churn(unsigned int by) {
      unsigned int expected = __atomic_load_n(&counter, __ATOMIC_SEQ_CST);
      __atomic_store_n(&counter, by, __ATOMIC_SEQ_CST);
      __atomic_fetch_add(&counter, by, __ATOMIC_SEQ_CST);
      __atomic_fetch_sub(&counter, by, __ATOMIC_ACQUIRE);
      __atomic_add_fetch(&counter, by, __ATOMIC_RELAXED);
      __atomic_sub_fetch(&counter, by, __ATOMIC_RELEASE);
      __atomic_or_fetch(&counter, by, __ATOMIC_SEQ_CST);
      __atomic_compare_exchange_n(&counter, &expected, by, 0,
                                  __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      return __atomic_exchange_n(&counter, expected, __ATOMIC_SEQ_CST);
    }
    size_t accumulate(size_t by) {
      size_t expected = __atomic_load_n(&total, __ATOMIC_SEQ_CST);
      __atomic_store_n(&total, by, __ATOMIC_SEQ_CST);
      __atomic_or_fetch(&total, by, __ATOMIC_SEQ_CST);
      __atomic_compare_exchange_n(&total, &expected, by, 1,
                                  __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
      return __atomic_add_fetch(&total, by, __ATOMIC_SEQ_CST);
    }
  C

  def test_compile_with_atomics_is_byte_identical
    %w[x86_64 aarch64].each do |target|
      a = Rubycc::Compiler.new.compile(ATOMIC_UNIT, filename: "a.c", target: target)
      b = Rubycc::Compiler.new.compile(ATOMIC_UNIT, filename: "a.c", target: target)
      assert_bytes_equal a, b, "#{target} compile of a unit with atomics must be byte-identical"
    end
  end

  def test_link_with_constructors_is_byte_identical
    obj = Rubycc::Compiler.new.compile(CONSTRUCTOR_UNIT, filename: "c.c")
    assert_bytes_equal SharedLinker.link([obj]), SharedLinker.link([obj]),
                       "a shared object with initializer arrays must be byte-identical"
  end

  # --- (2) compilation, across two separate Ruby processes ---------------

  # Catches anything that would depend on this process's hash seed, PID or
  # object_id (a per-process value that must never leak into the emitted
  # bytes) by driving the real CLI (exe/rubycc) twice, each in its own
  # freshly-spawned Ruby interpreter.
  def test_compile_in_separate_processes_is_byte_identical
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), RICH_UNIT)

      out1 = compile_via_cli(dir, "u.c", "u1.o")
      out2 = compile_via_cli(dir, "u.c", "u2.o")

      assert_bytes_equal File.binread(File.join(dir, out1)), File.binread(File.join(dir, out2)),
                          "two separate rubycc process invocations must produce byte-identical objects"
    end
  end

  # --- (6) environment independence: cwd and ambient env ------------------

  # The same absolute input path, compiled from two different current
  # directories (with no relative paths involved), must yield the same object:
  # only the file's basename is ever recorded (as the STT_FILE symbol), not its
  # directory or the process's cwd.
  def test_compile_from_different_cwd_is_byte_identical
    in_tmpdir do |dir_a|
      in_tmpdir do |dir_b|
        source_path = File.join(dir_a, "u.c")
        File.write(source_path, RICH_UNIT)

        out_a = File.join(dir_a, "from_a.o")
        out_b = File.join(dir_b, "from_b.o")
        run_cli("-c", source_path, "-o", out_a, chdir: dir_a)
        run_cli("-c", source_path, "-o", out_b, chdir: dir_b)

        assert_bytes_equal File.binread(out_a), File.binread(out_b),
                            "compiling the same absolute path from different cwds must be byte-identical"
      end
    end
  end

  def test_compile_is_independent_of_tz_and_lang
    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), RICH_UNIT)

      out1 = File.join(dir, "plain.o")
      out2 = File.join(dir, "envvar.o")
      run_cli("-c", "u.c", "-o", "plain.o", chdir: dir)
      run_cli("-c", "u.c", "-o", "envvar.o", chdir: dir,
              env: { "TZ" => "America/New_York", "LANG" => "fr_FR.UTF-8", "LC_ALL" => "fr_FR.UTF-8" })

      assert_bytes_equal File.binread(out1), File.binread(out2),
                          "TZ/LANG/LC_ALL must not affect compiled output"
    end
  end

  # --- (3) linking: shared object and executable --------------------------

  def test_link_shared_object_is_byte_identical
    skip "libc unavailable" unless libc_path

    a = build_so
    b = build_so
    assert_bytes_equal a, b, "linking the same objects into a .so twice must be byte-identical"
  end

  def test_link_executable_is_byte_identical
    skip "no dynamic loader / libc on host" unless executable_linkable?

    a = build_exe
    b = build_exe
    assert_bytes_equal a, b, "linking the same objects into an executable twice must be byte-identical"
  end

  # --- (4) archive: same members, and again after touching mtimes ---------

  def test_archive_is_byte_identical_for_identical_members
    a = ArWriter.new.add_member("a.o", "hello".b).add_member("b.o", "world!".b).to_binary
    b = ArWriter.new.add_member("a.o", "hello".b).add_member("b.o", "world!".b).to_binary
    assert_bytes_equal a, b, "an archive built twice from identical members must be byte-identical"
  end

  # Rebuilding an archive from member *files* whose mtimes differ must still be
  # byte-identical: ar headers must not embed the real mtime/uid/gid (the
  # classic reason GNU ar's `-D` "deterministic" mode exists).
  def test_archive_is_byte_identical_across_member_mtime_changes
    in_tmpdir do |dir|
      File.write(File.join(dir, "a.o"), "hello".b)
      File.write(File.join(dir, "b.o"), "world!".b)
      run_ar_cli(dir, "rcs", "lib1.a", "a.o", "b.o")
      first = File.binread(File.join(dir, "lib1.a"))

      # Touch the member files forward in time (and change their uid/gid view is
      # not controllable in-test, but mtime is): a deterministic writer must
      # ignore it entirely.
      future = Time.now + 3600
      File.utime(future, future, File.join(dir, "a.o"))
      File.utime(future, future, File.join(dir, "b.o"))

      run_ar_cli(dir, "rcs", "lib2.a", "a.o", "b.o")
      second = File.binread(File.join(dir, "lib2.a"))

      assert_bytes_equal first, second,
                          "an archive rebuilt after its member files' mtimes changed must stay byte-identical"

      # And directly: the header carries neither timestamp.
      member = ArReader.read(first).member("a.o")
      assert_equal 0, member.mtime, "ar member header mtime must be pinned, not the real file mtime"
      assert_equal 0, member.uid, "ar member header uid must be pinned, not the real uid"
      assert_equal 0, member.gid, "ar member header gid must be pinned, not the real gid"
    end
  end

  # --- (5) a full rmake build, clean rebuilt ------------------------------

  MKMF_LIKE = <<~MK
    CC = gcc
    LDSHARED = $(CC) -shared
    empty =
    COUTFLAG = -o $(empty)
    CSRCFLAG = $(empty)
    INCFLAGS =
    CPPFLAGS =
    CFLAGS = -fPIC
    OBJS = a.o b.o
    DLLIB = mylib.so
    Q = @
    ECHO = @ echo
    RM = rm -f
    srcdir = .
    VPATH = $(srcdir)

    all: $(DLLIB)

    .SUFFIXES: .c .o

    .c.o:
    \t$(ECHO) compiling $(<)
    \t$(Q) $(CC) $(INCFLAGS) $(CPPFLAGS) $(CFLAGS) $(COUTFLAG)$@ -c $(CSRCFLAG)$<

    $(DLLIB): $(OBJS)
    \t$(ECHO) linking $(DLLIB)
    \t-$(Q)$(RM) $@
    \t$(Q) $(LDSHARED) -o $@ $(OBJS)
  MK

  def write_mkmf_like_sources(dir)
    File.write(File.join(dir, "Makefile"), MKMF_LIKE)
    File.write(File.join(dir, "a.c"), "int a_val(void) { return 11; }\n")
    File.write(File.join(dir, "b.c"), "int b_val(void) { return 31; }\n")
  end

  def test_full_rmake_build_is_byte_identical_after_clean
    bytes = Array.new(2) do
      in_tmpdir do |dir|
        write_mkmf_like_sources(dir)
        mk = Makefile.parse(File.read(File.join(dir, "Makefile")), dir: dir)
        mk.run("all", out: StringIO.new, tools: :rubycc, jobs: 1)
        so = File.binread(File.join(dir, "mylib.so"))
        FileUtils_rm_rf(File.join(dir, "a.o"))
        FileUtils_rm_rf(File.join(dir, "b.o"))
        FileUtils_rm_rf(File.join(dir, "mylib.so"))
        so
      end
    end
    assert_bytes_equal bytes[0], bytes[1],
                        "a full rmake build, clean-rebuilt, must be byte-identical (N4)"
  end

  private

  # A dependency-free recursive delete so the test does not require 'fileutils'
  # to be loaded at file scope (mirrors test_ar_archive.rb's dependency-free
  # helper style).
  def FileUtils_rm_rf(path)
    require "fileutils"
    FileUtils.rm_f(path)
  end

  def in_tmpdir(&block)
    Dir.mktmpdir("rubycc-deterministic", &block)
  end

  def run_cli(*args, chdir:, env: {})
    Open3.capture3(env, "ruby", "-I#{LIB_DIR}", EXE_PATH, *args, chdir: chdir)
  end

  def run_ar_cli(dir, *args)
    ar_exe = File.expand_path("../exe/rubycc-ar", __dir__)
    _out, err, status = Open3.capture3("ruby", "-I#{LIB_DIR}", ar_exe, *args, chdir: dir)
    raise "rubycc-ar failed: #{err}" unless status.success?
  end

  # Compiles `source_name` to `object_name` (both relative to `dir`) by
  # spawning the real CLI in its own Ruby process, and returns `object_name`.
  def compile_via_cli(dir, source_name, object_name)
    _out, err, status = run_cli("-c", source_name, "-o", object_name, chdir: dir)
    raise "rubycc CLI failed: #{err}" unless status.success?

    object_name
  end

  def objects_for(sources, dir, pic: false, target: "x86_64")
    sources.each_with_index.map do |src, i|
      path = File.join(dir, "u#{i}.o")
      File.binwrite(path, Rubycc::Compiler.new.compile(src, filename: "u#{i}.c", pic: pic, target: target))
      path
    end
  end

  def build_so
    in_tmpdir do |dir|
      objects = objects_for([RICH_UNIT], dir, pic: true)
      SharedLinker.link(objects, needed: [libc_path])
    end
  end

  def build_exe
    in_tmpdir do |dir|
      objects = objects_for([RICH_UNIT, MAIN_UNIT], dir)
      ExecutableLinker.link(objects)
    end
  end

  # Delegates to LibcHelper so this search is written once for the whole suite.
  def libc_path
    host_libc_path
  end

  def executable_linkable?
    interp = ["/lib64/ld-linux-x86-64.so.2", "/lib/ld-musl-x86_64.so.1"].any? { |p| File.exist?(p) }
    interp && !!libc_path
  end

  # Asserts two byte strings are identical, and — unlike a bare `assert_equal`,
  # which would dump the whole binary — reports the offset and bytes of the
  # first mismatch (and any length difference) so a real regression is
  # actionable rather than an unreadable wall of bytes.
  def assert_bytes_equal(expected, actual, message = nil)
    expected = expected.b
    actual = actual.b
    return assert(true) if expected == actual

    detail =
      if expected.bytesize != actual.bytesize
        "length differs: expected #{expected.bytesize} bytes, got #{actual.bytesize} bytes"
      else
        offset = (0...expected.bytesize).find { |i| expected.getbyte(i) != actual.getbyte(i) }
        "first mismatch at byte offset #{offset}: " \
          "expected #{expected.byteslice(offset, 8).unpack1('H*')}, " \
          "got #{actual.byteslice(offset, 8).unpack1('H*')}"
      end

    flunk [message, detail].compact.join(" -- ")
  end
end
