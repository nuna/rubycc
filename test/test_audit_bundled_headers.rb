# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "../tools/audit_bundled_headers"

# bundled-headers-coverage-audit-1: tools/audit_bundled_headers.rb, which
# measures a bundled libc header's names against glibc's header of the same
# name. The scanner half is checked on hand-written C (no glibc text involved);
# the measuring half is run for real on one small header.
class TestAuditBundledHeaders < Minitest::Test
  A = AuditBundledHeaders

  def tokens(source)
    source.scan(A::TOKEN).map { |t| [t, "h.h", "/f/h.h"] }
  end

  def names(source)
    A.declared_names(tokens(source)).map { |(name, kind)| [name, kind] }
  end

  def test_declarator_scanner_reads_each_declaration_shape
    source = <<~C
      typedef unsigned long int my_size;
      typedef struct { int q; int r; } my_div;
      typedef void (*my_handler)(int);
      struct my_tag { int member; };
      enum { MY_A = 1, MY_B, MY_C = (1 << 3) };
      extern int my_fn (const char *__s) __attribute__ ((__nonnull__ (1)));
      extern int (*my_signal (int __sig, void (*__h)(int)))(int);
      extern char *my_env [];
      extern int my_x, my_y;
      static inline int my_inline (int a) { return a + 1; }
      extern long my_asm (long) __asm__ ("" "real_name");
    C
    assert_equal [["my_size", :typedef], ["my_div", :typedef], ["my_handler", :typedef],
                  ["struct my_tag", :tag], ["MY_A", :enumerator], ["MY_B", :enumerator],
                  ["MY_C", :enumerator], ["my_fn", :function], ["my_signal", :function],
                  ["my_env", :variable], ["my_x", :variable], ["my_y", :variable],
                  ["my_inline", :function], ["my_asm", :function]],
                 names(source)
  end

  def test_members_and_parameters_are_not_file_scope_names
    found = names("struct s { int inner; char *other; }; int f(int param, long (*cb)(int x));").map(&:first)
    assert_equal ["struct s", "f"], found
  end

  def test_omitted_lines_are_read_from_the_first_comment_only
    Dir.mktmpdir do |dir|
      path = File.join(dir, "h.h")
      File.write(path, <<~C)
        /* A header.
           omitted: foo bar_* struct baz -- no corpus user. omitted: <sys/types.h>
           -- pulled in by glibc only. omitted: qux_* -- a family pattern last
           before the separator.
           Trailing prose. */
        /* omitted: never -- not the first comment. */
      C
      patterns = A.omitted_patterns(path)
      assert_equal ["foo", "bar_*", "struct baz", "<sys/types.h>", "qux_*"], patterns.map(&:first)
      assert A.covered?("qux_zzz", patterns)
      assert A.covered?("bar_quux", patterns)
      assert A.covered?("struct baz", patterns)
      refute A.covered?("never", patterns)
    end
  end

  # audit-reserved-public-macros-1: the line the audit draws through the
  # reserved underscore space. A name a program is meant to write counts as a
  # public name (and so as missing when a bundled header lacks it); a name the
  # implementation keeps for itself does not.
  def test_the_reserved_space_is_split_into_what_a_program_writes_and_what_it_does_not
    public_names = %w[_POSIX_VDISABLE _POSIX_VERSION _POSIX2_C_BIND _XOPEN_UNIX
                      _XBS5_LP64_OFF64 _LFS_LARGEFILE _LFS64_STDIO
                      _SC_PAGESIZE _CS_PATH _PC_NAME_MAX _NL_TIME_FIRST_WEEKDAY
                      _DATE_FMT _IO _IOR _IOW _IOWR _IOR_BAD _IOC _IOC_SIZEBITS
                      _Exit _Fork]
    public_names.each do |name|
      assert A.public_reserved?(name), "#{name} is a spelling programs write"
      refute A.reserved?(name), "#{name} must not be skipped as reserved"
    end

    internal_names = %w[__caddr_t __have_pthread_attr_t _POSIX_C_SOURCE
                        _POSIX_SOURCE _XOPEN_SOURCE _UNISTD_H _BITS_TYPES_H
                        _RUBYCC_UNISTD_H _HAVE_STRUCT_TERMIOS_C_ISPEED
                        _STATBUF_ST_NSEC _DIRENT_HAVE_D_TYPE
                        _UTSNAME_NODENAME_LENGTH _IO_EOF_SEEN _IO_lock_t
                        _REG_NOMATCH
                        _ElfW _SIGSET_NWORDS _STRUCT_TIMESPEC]
    internal_names.each do |name|
      refute A.public_reserved?(name), "#{name} is the implementation's own"
      assert A.reserved?(name), "#{name} must be skipped as reserved"
    end

    # The struct/union/enum prefix is stripped before either test is applied.
    assert A.reserved?("struct _IO_FILE")
    refute A.reserved?("enum _POSIX_VDISABLE")
    # An unreserved name is never "reserved", whatever its shape.
    refute A.reserved?("tcgetpgrp")
  end

  # A whole measurement, on a header small enough to state the answer for:
  # glibc's <alloca.h> owns `alloca` (a function and a macro), and the bundled
  # one provides it, so nothing is missing on any arch whose oracle is here.
  def test_audits_alloca_h_on_every_installed_arch
    arches = A.available_arches
    skip "no glibc oracle compiler installed" if arches.empty?

    arches.each do |arch|
      result = A.audit("alloca.h", arch, guard_probe: false)
      assert_nil result.error, "<alloca.h> on #{arch}: #{result.error}"
      assert_includes result.glibc_own, "alloca"
      assert_empty result.missing, "<alloca.h> on #{arch}"
    end
  end
end
