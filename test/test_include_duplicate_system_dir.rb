# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"

# include-duplicate-system-dir-1: `-I/usr/include` used to make rubycc read
# glibc's own <stdio.h> ahead of the bundled compatibility headers, because
# rubycc's default search path puts the bundled headers *after* the caller's
# -I directories (issues/include-duplicate-system-dir.md, GAPS gap AV). glibc's
# stdio.h then hit __fortified_attr_access, a macro the bundled sys/cdefs.h
# does not define, and preprocessing failed.
#
# gcc does not have this problem because it drops a -I/-isystem/-idirafter
# directory that names the same directory as one already on its system search
# path ("ignoring duplicate directory", `gcc -v -E`) and keeps the system
# directory's own position instead. Measured 2026-09-13 on this host (WSL2,
# gcc 13.3):
#
#   * `-I/usr/include`, `-isystem /usr/include` and `-idirafter /usr/include`
#     are all reported as a duplicate and dropped.
#   * The duplicate check follows the real directory, not the literal
#     spelling: a trailing slash (`/usr/include/`), a ".." segment
#     (`/usr/include/x86_64-linux-gnu/..`) and a symlink to a system directory
#     were all reported as duplicates too.
#   * A directory that does *not* duplicate a system directory is unaffected
#     and keeps its position ahead of the system path, in the order it was
#     given relative to the other surviving -I directories.
#   * A duplicate of the multiarch directory itself
#     (`/usr/include/x86_64-linux-gnu`) is dropped the same way.
#
# rubycc implements the same rule in
# Rubycc::Preprocess::Preprocessor#reject_system_duplicate_paths.
class TestIncludeDuplicateSystemDir < Minitest::Test
  include ExecutionHelper

  EXE_PATH = File.expand_path("../exe/rubycc", __dir__)
  LIB_DIR  = File.expand_path("../lib", __dir__)

  def rubycc(*args, dir:)
    Open3.capture3("ruby", "-I#{LIB_DIR}", EXE_PATH, *args, chdir: dir)
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end

  def usr_include_stdio_available?
    File.exist?("/usr/include/stdio.h")
  end

  # --- end-to-end: the driver, the reported reproduction -----------------

  def test_dash_i_usr_include_with_stdio_compiles
    skip "system libc headers not found (/usr/include/stdio.h missing)" unless usr_include_stdio_available?

    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "#include <stdio.h>\nint main(void){ return 0; }\n")
      _out, err, status = rubycc("-I/usr/include", "-c", "u.c", dir: dir)
      assert_equal 0, status.exitstatus, err
    end
  end

  def test_isystem_usr_include_with_stdio_compiles
    skip "system libc headers not found (/usr/include/stdio.h missing)" unless usr_include_stdio_available?

    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "#include <stdio.h>\nint main(void){ return 0; }\n")
      _out, err, status = rubycc("-isystem", "/usr/include", "-c", "u.c", dir: dir)
      assert_equal 0, status.exitstatus, err
    end
  end

  def test_idirafter_usr_include_with_stdio_compiles
    skip "system libc headers not found (/usr/include/stdio.h missing)" unless usr_include_stdio_available?

    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "#include <stdio.h>\nint main(void){ return 0; }\n")
      _out, err, status = rubycc("-idirafter", "/usr/include", "-c", "u.c", dir: dir)
      assert_equal 0, status.exitstatus, err
    end
  end

  def test_dash_i_multiarch_dir_with_stdio_compiles
    multiarch = Rubycc::Preprocess::Preprocessor::LIBC_MULTIARCH_INCLUDE_DIRS.fetch(HostTarget.name) { nil }
    skip "no known multiarch directory for host CPU #{HostTarget.name.inspect}" unless multiarch
    skip "multiarch directory not found (#{multiarch} missing)" unless File.directory?(multiarch)
    skip "system libc headers not found (/usr/include/stdio.h missing)" unless usr_include_stdio_available?

    in_tmpdir do |dir|
      File.write(File.join(dir, "u.c"), "#include <stdio.h>\nint main(void){ return 0; }\n")
      _out, err, status = rubycc("-I#{multiarch}", "-c", "u.c", dir: dir)
      assert_equal 0, status.exitstatus, err
    end
  end

  # A gcc-differential check for the reported reproduction: the object rubycc
  # produces with -I/usr/include runs the same as the one gcc produces from
  # the same source and flags.
  def test_dash_i_usr_include_matches_gcc
    skip "gcc unavailable (needed to cross-check)" unless tool?("gcc")
    skip "system libc headers not found (/usr/include/stdio.h missing)" unless usr_include_stdio_available?

    source = <<~C
      #include <stdio.h>
      int main(void) {
        printf("%d\\n", 42);
        return 0;
      }
    C
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "dup_rubycc.o")
      binary = Rubycc::Compiler.new.compile(source, filename: "dup.c", target: host_target,
                                                     include_paths: ["/usr/include"])
      File.binwrite(rubycc_obj, binary)
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = File.join(dir, "dup_gcc.o")
      source_path = File.join(dir, "dup.c")
      File.write(source_path, source)
      args = ["gcc", "-c", ExecutionHelper::REFERENCE_STD_FLAG, "-fno-pie", "-I/usr/include"]
      out, status = Open3.capture2e(*args, "-o", gcc_obj, source_path)
      raise "gcc failed to compile source (exit #{status.exitstatus}):\n#{out}" unless status.success?

      gcc_status, gcc_out = link_and_run(gcc_obj)

      assert_equal 0, rubycc_status, "rubycc-built dup exited #{rubycc_status}"
      assert_equal gcc_status, rubycc_status, "dup: exit status differs from gcc"
      assert_equal gcc_out, rubycc_out, "dup: output differs from gcc"
    end
  end

  # --- a non-system -I still wins over the bundled headers ----------------

  def test_non_system_dash_i_still_shadows_bundled_headers
    in_tmpdir do |dir|
      File.write(File.join(dir, "stddef.h"), "#define CUSTOM_STDDEF_MARKER 42\n")
      source = <<~C
        #include <stddef.h>
        #ifndef CUSTOM_STDDEF_MARKER
        #error "custom header was not used"
        #endif
        int main(void){ return 0; }
      C
      File.write(File.join(dir, "u.c"), source)
      _out, err, status = rubycc("-I.", "-c", "u.c", dir: dir)
      assert_equal 0, status.exitstatus, err
    end
  end

  # --- unit-level coverage of the dedup rule itself ------------------------

  def preprocessor
    Rubycc::Preprocess::Preprocessor.new
  end

  # The reject helper follows the real directory rather than the literal
  # spelling: a symlink, a ".." segment and a trailing slash all name
  # BUNDLED_INCLUDE_DIR here, matching what gcc reported for /usr/include
  # (see the class comment). BUNDLED_INCLUDE_DIR is used as the "system"
  # directory instead of /usr/include so this test does not depend on the
  # host actually having glibc headers installed.
  def test_reject_system_duplicate_paths_follows_symlinks_and_dotdot_and_trailing_slash
    bundled = Rubycc::Preprocess::Preprocessor::BUNDLED_INCLUDE_DIR
    Dir.mktmpdir do |dir|
      symlink = File.join(dir, "link_to_bundled")
      File.symlink(bundled, symlink)
      dotdot = File.join(bundled, "..", File.basename(bundled))
      trailing_slash = "#{bundled}/"

      deduped = preprocessor.send(:reject_system_duplicate_paths,
                                   [symlink, dotdot, trailing_slash, dir],
                                   [bundled])
      assert_equal [dir], deduped
    end
  end

  # A directory that does not duplicate a system directory keeps its position,
  # and the order of the surviving directories relative to each other is
  # unchanged (gcc's own behavior, see the class comment).
  def test_reject_system_duplicate_paths_keeps_order_of_survivors
    system_paths = ["/sys/a-nonexistent-for-this-test", "/sys/b-nonexistent-for-this-test"]
    result = preprocessor.send(:reject_system_duplicate_paths,
                                ["/keep/1", system_paths[0], "/keep/2", system_paths[1], "/keep/3"],
                                system_paths)
    assert_equal ["/keep/1", "/keep/2", "/keep/3"], result
  end

  # A nonexistent caller directory that happens to share its (nonexistent)
  # system counterpart's spelling is still recognized: with nothing to
  # resolve via realpath, the comparison falls back to the lexically
  # expanded path.
  def test_reject_system_duplicate_paths_matches_nonexistent_directories_lexically
    result = preprocessor.send(:reject_system_duplicate_paths,
                                ["/sys/nonexistent-for-this-test"],
                                ["/sys/nonexistent-for-this-test"])
    assert_equal [], result
  end

  def test_reject_system_duplicate_paths_is_a_no_op_with_no_caller_directories
    assert_equal [], preprocessor.send(:reject_system_duplicate_paths, [], ["/sys/a"])
  end
end
