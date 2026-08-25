# frozen_string_literal: true

require "rbconfig"

require_relative "test_helper"

# rubycc does not bundle every glibc header; anything it does not ship (e.g.
# <malloc.h>) is read straight from the host's /usr/include. The bundled
# include/libc/sys/cdefs.h sets glibc's own _SYS_CDEFS_H guard first, so the
# host's real <sys/cdefs.h> becomes a no-op once reached that way -- any
# glibc compiler-abstraction macro a host header leans on that the bundled
# cdefs.h does not also define is left as a bare, undefined identifier, which
# is a syntax error rather than a missing declaration. This file guards that
# path: an unbundled header pulled in from the host must compile and run with
# the same behavior gcc gives it (issues/bundled-cdefs-attr-macros.md).
class TestHostHeaderShim < Minitest::Test
  include ExecutionHelper

  def setup
    skip "gcc unavailable (needed to link and cross-check)" unless tool?("gcc")
    skip "host <malloc.h> not found (/usr/include/malloc.h missing)" unless File.exist?("/usr/include/malloc.h")
    unless Rubycc::Compiler::TARGETS.key?(HOST_TARGET)
      skip "host CPU #{HOST_TARGET.inspect} is not a rubycc target " \
           "(#{Rubycc::Compiler::TARGETS.keys.join(", ")})"
    end
  end

  HOST_TARGET = HostTarget.name

  # <malloc.h> is not among rubycc's bundled headers, so this is read from the
  # host. Its declarations reach __attr_dealloc_free (malloc.h:61 on this
  # host's glibc 2.39) through the bundled sys/cdefs.h before glibc's own
  # cdefs.h. malloc_usable_size is declared only in <malloc.h> (not in the
  # bundled <stdlib.h>), so calling it proves the #include actually resolved
  # to the host header rather than silently finding nothing to include.
  # sz >= 64 rather than a fixed size, since the exact usable size an
  # allocator hands back for a given request is an implementation detail that
  # can differ across environments; whether it honors its own contract
  # (never less than what was requested) is not.
  #
  # <malloc.h> only exercises one of the five annotation macros the bundled
  # cdefs.h added (__attr_dealloc_free); the other four never appear on this
  # header's declarations, so a wrong spelling or argument count in any of
  # them would go undetected here. The probe_* declarations below use each of
  # the five directly: on gcc they expand to real attributes glibc's cdefs.h
  # defines, so a mismatch is a compile error on the gcc side of the
  # differential; on rubycc they expand to nothing, so they place no
  # requirement beyond parsing. They are declarations only -- never defined
  # or called -- since exercising the macros is the whole point.
  MALLOC_H_SOURCE = <<~C
    #include <malloc.h>
    #include <stdio.h>

    extern void *probe_alloc(size_t n) __attr_dealloc_free;
    extern void *probe_dealloc(size_t n) __attr_dealloc(free, 1);
    extern FILE *probe_fopen(void) __attr_dealloc_fclose;
    extern void probe_read(const void *buf, size_t n) __attr_access((__read_only__, 1, 2));
    extern void probe_none(void *buf) __attr_access_none(1);

    int main(void) {
      void *p = malloc(64);
      size_t usable = malloc_usable_size(p);
      printf("%d\\n", usable >= 64);
      free(p);
      return 0;
    }
  C

  def test_unbundled_host_header_compiles_and_runs_like_gcc
    in_tmpdir do |dir|
      rubycc_obj = File.join(dir, "malloc_h_rubycc.o")
      binary = Rubycc::Compiler.new.compile(MALLOC_H_SOURCE, filename: "malloc_h.c", target: HOST_TARGET)
      File.binwrite(rubycc_obj, binary)
      rubycc_status, rubycc_out = link_and_run(rubycc_obj)

      gcc_obj = compile_with_gcc(MALLOC_H_SOURCE, File.join(dir, "malloc_h_gcc.o"))
      gcc_status, gcc_out = link_and_run(gcc_obj)

      assert_equal 0, rubycc_status, "rubycc-built malloc_h exited #{rubycc_status}"
      assert_equal gcc_status, rubycc_status, "malloc_h: exit status differs from gcc"
      assert_equal gcc_out, rubycc_out, "malloc_h: output differs from gcc"
    end
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
