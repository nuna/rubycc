# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/pkgconf/pkgconf"
require "tmpdir"
require "fileutils"
require "open3"

# Step 59 (M3 / ROADMAP §6 B4): the pkg-config shim — a pure-Ruby .pc parser
# plus the narrow CLI mkmf's mkmf.rb#pkg_config actually invokes $PKGCONFIG
# with (tallied against this environment's mkmf.rb, 3.4.5):
#   --exists pkg
#   --#{option} ... pkg     for each of pkg_config's own *options, and for
#                            the built-in default path's own option names:
#                            libs / cflags-only-I / cflags-only-other /
#                            cflags / libs-only-l
# `--modversion` is not literally invoked by mkmf.rb's own source but is part
# of the documented CLI surface (ROADMAP §6 B4) since callers commonly do
# `pkg_config(pkg, "modversion")`.
#
# test/fixtures/pkgconfig/{zlib,libffi,openssl,libssl,libcrypto}.pc are
# byte-for-byte copies of this environment's real .pc files, taken from
# /usr/lib/x86_64-linux-gnu/pkgconfig/ (Ubuntu/Debian package pkgconf), so the
# parser and Requires-chain golden values below are the real-world shapes
# mkmf's pkg_config() has to cope with, not hand-written toy fixtures.
class TestPkgconf < Minitest::Test
  Pkgconf = Rubycc::Pkgconf

  FIXTURES = File.expand_path("fixtures/pkgconfig", __dir__)
  EXE_PATH = File.expand_path("../exe/rubycc-pkgconf", __dir__)
  LIB_DIR = File.expand_path("../lib", __dir__)

  def resolver(dirs = [FIXTURES])
    Pkgconf::Resolver.new(directories: dirs)
  end

  def run_cli(*args, pkg_config_path: FIXTURES, env: {})
    full_env = env.merge("PKG_CONFIG_PATH" => pkg_config_path)
    Open3.capture3(full_env, "ruby", "-I#{LIB_DIR}", EXE_PATH, *args)
  end

  # --- .pc parser ------------------------------------------------------------

  def test_parses_variables_fields_comments_and_blank_lines
    text = <<~PC
      # a leading comment
      prefix=/opt/thing

      Name: thing
      Description: a thing
      Version: 2.0
    PC
    pkg = Pkgconf::Parser.parse(text, path: "thing.pc")
    assert_equal "thing", pkg.name
    assert_equal "a thing", pkg.description
    assert_equal "2.0", pkg.version
  end

  def test_expands_nested_variable_chain
    # prefix -> exec_prefix -> libdir, exactly the chain the real zlib.pc uses.
    text = <<~PC
      prefix=/opt
      exec_prefix=${prefix}
      libdir=${exec_prefix}/lib
      includedir=${prefix}/include

      Name: nested
      Version: 1.0
      Libs: -L${libdir} -lnested
      Cflags: -I${includedir}
    PC
    pkg = Pkgconf::Parser.parse(text, path: "nested.pc")
    assert_equal "-L/opt/lib -lnested", pkg.libs
    assert_equal "-I/opt/include", pkg.cflags
  end

  def test_undefined_variable_reference_raises_parse_error
    text = "Cflags: -I${missing}\n"
    err = assert_raises(Pkgconf::ParseError) { Pkgconf::Parser.parse(text, path: "bad.pc") }
    assert_match(/undefined variable 'missing'/, err.message)
  end

  def test_unrecognized_line_raises_parse_error
    err = assert_raises(Pkgconf::ParseError) { Pkgconf::Parser.parse("this is not a pc line\n", path: "bad.pc") }
    assert_match(/unrecognized line/, err.message)
  end

  def test_requires_splits_on_whitespace_and_commas
    text = "Requires: libssl, libcrypto\n"
    pkg = Pkgconf::Parser.parse(text, path: "r.pc")
    assert_equal %w[libssl libcrypto], pkg.requires
  end

  def test_requires_private_is_kept_separate_from_requires
    text = "Requires: a\nRequires.private: b\n"
    pkg = Pkgconf::Parser.parse(text, path: "r.pc")
    assert_equal %w[a], pkg.requires
    assert_equal %w[b], pkg.requires_private
  end

  def test_version_constrained_requires_is_diagnosed_not_evaluated
    ["Requires: zlib >= 1.2\n", "Requires: zlib>=1.2\n"].each do |text|
      err = assert_raises(Pkgconf::UnsupportedError) { Pkgconf::Parser.parse(text, path: "v.pc") }
      assert_match(/version-constrained Requires/, err.message)
    end
  end

  # --- real fixtures: parsing ------------------------------------------------

  def test_zlib_fixture_parses_expected_fields
    pkg = resolver.load("zlib")
    assert_equal "zlib", pkg.name
    assert_equal "1.3", pkg.version
    assert_equal "-I/usr/include", pkg.cflags
    assert_includes pkg.libs, "-lz"
    assert_includes pkg.libs, "-L/usr/lib/x86_64-linux-gnu"
  end

  def test_libffi_fixture_parses_expected_fields
    pkg = resolver.load("libffi")
    assert_equal "3.4.6", pkg.version
    assert_equal "-lffi", pkg.libs
    assert_equal "-I/usr/include", pkg.cflags
  end

  # --- Resolver: search path --------------------------------------------------

  def test_search_path_prefers_pkg_config_path_over_defaults
    Dir.mktmpdir do |dir|
      dirs = Pkgconf::SearchPath.directories({ "PKG_CONFIG_PATH" => dir })
      assert_equal dir, dirs.first
      assert_equal Pkgconf::SearchPath::DEFAULT_DIRECTORIES, dirs.drop(1)
    end
  end

  def test_pkg_config_path_first_entry_wins_over_second
    Dir.mktmpdir do |first|
      Dir.mktmpdir do |second|
        File.write(File.join(first, "dup.pc"), "Name: dup\nVersion: 1.0\n")
        File.write(File.join(second, "dup.pc"), "Name: dup\nVersion: 2.0\n")
        found = resolver([first, second]).load("dup")
        assert_equal "1.0", found.version
      end
    end
  end

  def test_missing_module_raises_not_found_error
    err = assert_raises(Pkgconf::NotFoundError) { resolver.load("does-not-exist") }
    assert_match(/not found/, err.message)
  end

  # --- Resolver: Requires recursion -------------------------------------------

  def test_openssl_requires_chain_pulls_in_libssl_and_libcrypto_libs
    libs = resolver.libs_tokens("openssl")
    assert_includes libs, "-lssl"
    assert_includes libs, "-lcrypto"
    assert_operator libs.index("-lssl"), :<, libs.index("-lcrypto")
  end

  def test_openssl_requires_chain_pulls_in_cflags_via_public_and_private
    # openssl.pc: Requires: libssl libcrypto (public). libssl.pc additionally
    # has Requires.private: libcrypto, which only matters for --cflags.
    cflags = resolver.cflags_tokens("openssl")
    assert_includes cflags, "-I/usr/include"
  end

  def test_requires_private_does_not_leak_into_libs
    # libcrypto.pc has "Libs.private: -ldl -pthread"; the non-static --libs
    # path must never surface it.
    libs = resolver.libs_tokens("libcrypto")
    refute_includes libs, "-ldl"
    refute_includes libs, "-pthread"
  end

  def test_exists_true_for_resolvable_chain_false_otherwise
    assert resolver.exists?("openssl")
    refute resolver.exists?("does-not-exist")
  end

  # --- CLI: exe/rubycc-pkgconf -------------------------------------------------

  def test_cli_modversion_zlib
    out, _err, status = run_cli("--modversion", "zlib")
    assert status.success?
    assert_equal "1.3", out.chomp
  end

  # zlib.pc's whole Cflags is `-I${includedir}` = -I/usr/include, a system
  # include directory, so pkg-config prints nothing at all here; the token only
  # reappears when PKG_CONFIG_ALLOW_SYSTEM_CFLAGS turns the filter off. (This
  # is the disagreement the CI run against the real pkg-config caught — see the
  # "system include/library path filtering" section below.)
  def test_cli_cflags_zlib
    out, _err, status = run_cli("--cflags", "zlib")
    assert status.success?
    assert_equal "", out.chomp

    kept, _kept_err, kept_status = run_cli("--cflags", "zlib", env: { "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS" => "1" })
    assert kept_status.success?
    assert_equal "-I/usr/include", kept.chomp
  end

  def test_cli_libs_zlib_has_dash_l_and_dash_capital_l
    out, _err, status = run_cli("--libs", "zlib")
    assert status.success?
    tokens = out.chomp.split
    assert_includes tokens, "-lz"
    assert_includes tokens, "-L/usr/lib/x86_64-linux-gnu"
  end

  def test_cli_libs_only_l_zlib
    out, _err, status = run_cli("--libs-only-l", "zlib")
    assert status.success?
    assert_equal "-lz", out.chomp
  end

  def test_cli_cflags_only_i_and_only_other
    # zlib.pc has only the (filtered) system -I, so both halves come out empty;
    # sysfilter.pc below is what exercises a non-empty split.
    out_i, _err, status_i = run_cli("--cflags-only-I", "zlib")
    assert status_i.success?
    assert_equal "", out_i.chomp

    out_other, _err, status_other = run_cli("--cflags-only-other", "zlib")
    assert status_other.success?
    assert_equal "", out_other.chomp
  end

  def test_cli_libs_openssl_pulls_requires_chain
    out, _err, status = run_cli("--libs", "openssl")
    assert status.success?
    tokens = out.chomp.split
    assert_includes tokens, "-lssl"
    assert_includes tokens, "-lcrypto"
  end

  def test_cli_exists_success_no_output
    out, _err, status = run_cli("--exists", "zlib")
    assert status.success?
    assert_equal "", out
  end

  def test_cli_exists_missing_module_is_failure_with_no_output
    out, err, status = run_cli("--exists", "does-not-exist")
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_equal "", err
  end

  def test_cli_missing_module_error_message
    _out, err, status = run_cli("--cflags", "does-not-exist")
    refute status.success?
    assert_match(/rubycc-pkgconf/, err)
    assert_match(/not found/, err)
  end

  def test_cli_multiple_modules_are_concatenated
    out, _err, status = run_cli("--libs", "zlib", "libffi")
    assert status.success?
    tokens = out.chomp.split
    assert_includes tokens, "-lz"
    assert_includes tokens, "-lffi"
    assert_operator tokens.index("-lz"), :<, tokens.index("-lffi")
  end

  def test_cli_pkg_config_path_search_order
    Dir.mktmpdir do |first|
      Dir.mktmpdir do |second|
        File.write(File.join(first, "dup.pc"), "Name: dup\nVersion: from-first\n")
        File.write(File.join(second, "dup.pc"), "Name: dup\nVersion: from-second\n")
        path = [first, second].join(File::PATH_SEPARATOR)
        out, _err, status = run_cli("--modversion", "dup", pkg_config_path: path)
        assert status.success?
        assert_equal "from-first", out.chomp
      end
    end
  end

  # --- system include/library path filtering -----------------------------------
  #
  # pkg-config drops the -I/-L tokens naming a directory the toolchain already
  # searches by itself (Rubycc::Pkgconf::SystemPathFilter). Missing that filter
  # was the one real incompatibility the CI comparison against the installed
  # pkg-config found: `--cflags zlib` printed -I/usr/include where the real tool
  # prints nothing. These tests are deliberately environment-independent — no
  # pkg-config binary and no mutation of the suite's own ENV — because the
  # comparison test below only ever runs where pkg-config is installed.
  #
  # fixtures/pkgconfig/sysfilter.pc is the only synthetic .pc in the fixture
  # directory: unlike the copied-from-this-machine ones it carries a system and
  # a non-system directory of each kind, a trailing-slash spelling, and a
  # non -I/-L flag, so one module covers every branch of the filter.

  def cli_tokens(*args, env: {})
    out, err, status = run_cli(*args, env: env)
    assert status.success?, "rubycc-pkgconf #{args.join(' ')} failed: #{err}"
    out.chomp.split
  end

  def test_cflags_drops_system_include_dir_including_trailing_slash
    tokens = cli_tokens("--cflags", "sysfilter")
    refute_includes tokens, "-I/usr/include"
    refute_includes tokens, "-I/usr/include/"
    assert_equal ["-I/opt/foo/include", "-DFOO=1"], tokens
  end

  def test_cflags_only_i_drops_system_include_dir
    assert_equal ["-I/opt/foo/include"], cli_tokens("--cflags-only-I", "sysfilter")
  end

  # --cflags-only-other keeps exactly the tokens the filter never looks at, so
  # it must be unchanged by any of this.
  def test_cflags_only_other_is_unaffected_by_the_filter
    assert_equal ["-DFOO=1"], cli_tokens("--cflags-only-other", "sysfilter")
    assert_equal ["-DFOO=1"], cli_tokens("--cflags-only-other", "sysfilter",
                                         env: { "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS" => "1" })
  end

  def test_libs_drops_system_library_dir_but_keeps_dash_l_and_other_dirs
    tokens = cli_tokens("--libs", "sysfilter")
    refute_includes tokens, "-L/usr/lib"
    assert_equal ["-L/opt/foo/lib", "-lfoo"], tokens
    assert_equal ["-lfoo"], cli_tokens("--libs-only-l", "sysfilter")
  end

  def test_allow_system_cflags_keeps_system_include_dir
    env = { "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS" => "1" }
    assert_equal ["-I/usr/include", "-I/usr/include/", "-I/opt/foo/include", "-DFOO=1"],
                 cli_tokens("--cflags", "sysfilter", env: env)
    assert_equal ["-I/usr/include", "-I/usr/include/", "-I/opt/foo/include"],
                 cli_tokens("--cflags-only-I", "sysfilter", env: env)
  end

  def test_allow_system_libs_keeps_system_library_dir
    env = { "PKG_CONFIG_ALLOW_SYSTEM_LIBS" => "1" }
    assert_equal ["-L/usr/lib", "-L/opt/foo/lib", "-lfoo"], cli_tokens("--libs", "sysfilter", env: env)
  end

  # Each ALLOW_* variable governs only its own half of the output.
  def test_allow_system_cflags_does_not_unfilter_libs
    env = { "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS" => "1" }
    assert_equal ["-L/opt/foo/lib", "-lfoo"], cli_tokens("--libs", "sysfilter", env: env)
  end

  def test_system_include_path_env_replaces_the_default_directory
    env = { "PKG_CONFIG_SYSTEM_INCLUDE_PATH" => "/opt/foo/include" }
    # /opt/foo/include is now the system directory, /usr/include no longer is.
    assert_equal ["-I/usr/include", "-I/usr/include/", "-DFOO=1"],
                 cli_tokens("--cflags", "sysfilter", env: env)
  end

  def test_system_library_path_env_replaces_the_default_directory
    env = { "PKG_CONFIG_SYSTEM_LIBRARY_PATH" => "/opt/foo/lib" }
    assert_equal ["-L/usr/lib", "-lfoo"], cli_tokens("--libs", "sysfilter", env: env)
  end

  def test_system_include_path_env_takes_a_colon_separated_list
    env = { "PKG_CONFIG_SYSTEM_INCLUDE_PATH" => ["/opt/foo/include", "/usr/include"].join(File::PATH_SEPARATOR) }
    assert_equal ["-DFOO=1"], cli_tokens("--cflags", "sysfilter", env: env)
  end

  # --- SystemPathFilter unit level ----------------------------------------------
  #
  # The environment is read through an injected +env+ hash (the same shape
  # SearchPath.directories takes), so these need no subprocess and never touch
  # the suite's own ENV.

  def filter(env = {})
    Pkgconf::SystemPathFilter.new(env)
  end

  def test_filter_defaults_cover_usr_include_and_usr_lib_and_usr_lib64
    assert_equal [], filter.cflags(["-I/usr/include"])
    assert_equal [], filter.libs(["-L/usr/lib", "-L/usr/lib64"])
  end

  def test_filter_normalizes_trailing_and_repeated_separators
    assert_equal [], filter.cflags(["-I/usr/include/", "-I/usr/include//", "-I//usr//include"])
    assert_equal [], filter.libs(["-L/usr/lib/"])
  end

  def test_filter_keeps_non_system_and_non_path_tokens
    tokens = ["-I/opt/foo/include", "-I/usr/include/foo", "-DFOO=1", "-I", "-lz", "-L/opt/foo/lib"]
    assert_equal tokens, filter.cflags(tokens)
    assert_equal tokens, filter.libs(tokens)
  end

  def test_filter_does_not_cross_between_cflags_and_libs
    # -L is not an include path and -I is not a library path, whichever list a
    # token happens to be travelling in.
    assert_equal ["-L/usr/lib"], filter.cflags(["-L/usr/lib"])
    assert_equal ["-I/usr/include"], filter.libs(["-I/usr/include"])
  end

  def test_filter_treats_an_empty_allow_variable_as_unset
    env = { "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS" => "", "PKG_CONFIG_ALLOW_SYSTEM_LIBS" => "" }
    assert_equal [], filter(env).cflags(["-I/usr/include"])
    assert_equal [], filter(env).libs(["-L/usr/lib"])
  end

  def test_filter_treats_an_empty_system_path_variable_as_an_empty_list
    # Set-but-empty is an explicit override, not a fallback to the defaults:
    # nothing is a system directory any more.
    env = { "PKG_CONFIG_SYSTEM_INCLUDE_PATH" => "", "PKG_CONFIG_SYSTEM_LIBRARY_PATH" => "" }
    assert_equal ["-I/usr/include"], filter(env).cflags(["-I/usr/include"])
    assert_equal ["-L/usr/lib"], filter(env).libs(["-L/usr/lib"])
  end

  # --- real pkg-config (skip-guarded) -----------------------------------------
  #
  # This environment has no `pkg-config` binary (ROADMAP §6 B4 notes it
  # explicitly), so this comparison is expected to skip here; it exists so the
  # suite still checks byte-for-byte agreement wherever it does run.

  def pkg_config_available?
    return @pkg_config_available if defined?(@pkg_config_available)

    @pkg_config_available = system("pkg-config", "--version", out: File::NULL, err: File::NULL) ? true : false
  end

  def test_matches_real_pkg_config_for_zlib
    skip "pkg-config is not installed in this environment (ROADMAP §6 B4)" unless pkg_config_available?

    # This test is skipped on developer machines that lack a real pkg-config
    # binary, so it only ever runs in CI. To make every CI run worth its
    # cost, run all three flags first and collect their results before
    # asserting anything, then fail (at most) once with a report covering
    # all of them. That way a single CI run tells us whether *all* flags
    # match, instead of stopping at the first mismatch and leaving the rest
    # unknown.
    env = { "PKG_CONFIG_PATH" => FIXTURES }
    results = %w[--modversion --cflags --libs].map do |flag|
      ours, _err, ours_status = run_cli(flag, "zlib")
      real, _rerr, real_status = Open3.capture3(env, "pkg-config", flag, "zlib")
      {
        flag: flag,
        real: real.strip,
        ours: ours.strip,
        real_success: real_status.success?,
        ours_success: ours_status.success?,
      }
    end

    mismatches = results.reject { |r| r[:real_success] == r[:ours_success] && r[:real] == r[:ours] }

    report = results.map do |r|
      status = r[:real_success] == r[:ours_success] ? "match" : "STATUS MISMATCH (real success=#{r[:real_success]}, ours success=#{r[:ours_success]})"
      status = "MISMATCH" if r[:real] != r[:ours] && status == "match"
      <<~ENTRY
        #{r[:flag]}: #{status}
          real:  "#{r[:real]}"
          ours:  "#{r[:ours]}"
      ENTRY
    end.join("\n")

    flunk("pkg-config output mismatch for zlib:\n\n#{report}") unless mismatches.empty?
  end
end
