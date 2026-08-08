#!/usr/bin/env ruby
# frozen_string_literal: true

# Run a corpus gem's *own* test suite against the .so a `RUBYCC=1 gem install`
# built, and (with --update) record the outcome in data/verified_gems.json.
#
# This is the procedure docs/STEPS.md Steps 93-104 performed by hand, made
# repeatable. None of the corpus gems ships its tests inside the .gem, so a run
# is always the same seven moves:
#
#   1. prepare a scratch GEM_HOME that has *this checkout's* rubycc installed
#      (its rubygems_plugin is what routes the extension build to rubycc);
#   2. `RUBYCC=1 gem install <gem> --version <v>` into that GEM_HOME;
#   3. prove the build really went through rubycc, from the transcripts
#      RubyGems leaves behind (gem_make.out's $(MAKE) is rubycc's exe/rmake,
#      and the generated Makefile / mkmf.log name exe/rubycc as CC);
#   4. fetch and unpack the matching upstream tag (that is where the tests are);
#   5. copy the installed .so (and any generated file the gem's rakelib would
#      normally produce) into the upstream tree;
#   6. run a sanity expression proving the C extension is what got loaded;
#   7. run the suite and parse its own summary line.
#
# Step 6 is the reason this tool exists rather than a shell loop. Several of
# these gems have a pure-Ruby or stock-Ruby fallback that makes the suite pass
# without the rubycc-built .so ever being loaded (racc falls back to its Ruby
# runtime; date/json/bigdecimal would happily test the interpreter's own bundled
# copy if the load path were one entry off). A tool that skipped the sanity check
# would write "verified" records that are simply false, so a recipe without a
# `sanity` expression is refused outright (see verify_recipe!).
#
# Network (rubygems.org, GitHub) and external gems are required, so this is a
# manual/CI tool like tools/m2_acceptance.rb -- never part of `rake test`.
#
# Usage (spell out `ruby`: tools/ is not tracked with the executable bit, and
# `bundle exec tools/...` would refuse it with "not executable"):
#   ruby tools/verify_gem_tests.rb <gem>...                      # run and report only
#   ruby tools/verify_gem_tests.rb --all                         # every gem with a recipe
#   ruby tools/verify_gem_tests.rb --update --step ID <gem>...   # ...and record the passes
#   ruby tools/verify_gem_tests.rb --update --step ID --notes TEXT <gem>
#   ruby tools/verify_gem_tests.rb --data /tmp/copy.json --update --step ID <gem>
#   ruby tools/verify_gem_tests.rb --control <gem>...             # same suite, host cc
#   VERIFY_WORK=/path/to/work ruby tools/verify_gem_tests.rb ...
#
# Options:
#   --all              run every gem in RECIPES
#   --update           write the PASSing gems into the database (default: read only)
#   --step ID          the step ID quoted in the generated evidence (--update only)
#   --notes TEXT       notes for a *new* entry (existing entries keep their notes)
#   --data PATH        database file to read/update (default: data/verified_gems.json)
#   --list             print the recipe table and exit
#   --control          run the same recipe against the host cc instead of rubycc,
#                      in a separate scratch GEM_HOME (refuses --update: a control
#                      run must never be recorded as "verified")
#
# The work directory (VERIFY_WORK, default <tmpdir>/rubycc_verify_gem_tests) is
# always kept: the tarballs and the scratch GEM_HOME are reused by later runs,
# which is what makes a re-run cheap. Delete it by hand to start clean.

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

RUBYCC_ROOT = File.expand_path("..", __dir__)

# The database schema and its default location live with the doctor code; this
# tool must not carry a second copy of either.
require File.join(RUBYCC_ROOT, "lib/rubycc/doctor/verified_gems")

WORK_DIR = File.expand_path(ENV["VERIFY_WORK"] || File.join(Dir.tmpdir, "rubycc_verify_gem_tests"))

# Generous ceilings: the slowest suite here (bigdecimal) takes about 25s and the
# slowest build about 30s, so these only catch a genuine hang.
TEST_TIMEOUT = 900
BUILD_TIMEOUT = 900

# Environment variables that must not leak from *this* process into the children.
# The tool normally runs under `bundle exec` inside the rubycc checkout, whose
# RUBYOPT/BUNDLE_* would otherwise pull the repo's Gemfile into every scratch
# GEM_HOME child and defeat the isolation. Passing nil to spawn unsets a variable.
#
# BUNDLER_SETUP is the one that does not announce itself. `bundle exec` sets it
# to bundler/setup's absolute path, and rubygems.rb requires whatever it names
# from gem_prelude -- so it re-enters bundler even with RUBYOPT and every
# BUNDLE_* cleared, and bundler then resolves the checkout's Gemfile against the
# scratch GEM_HOME and dies with "Could not find rake-... in locally installed
# gems". Measured on bundler 2.6.9 / ruby 3.4.5.
CLEARED_ENV = {
  "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil,
  "BUNDLE_BIN_PATH" => nil, "BUNDLE_PATH" => nil, "BUNDLER_VERSION" => nil,
  "BUNDLER_SETUP" => nil, "RUBYGEMS_GEMDEPS" => nil
}.freeze

# --- recipes ----------------------------------------------------------------
#
# There is no universal way to run "a gem's own test suite": the load paths, the
# runner, the generated files and the proof-of-C-extension differ per gem, and
# every one of the values below was read out of that gem's own Rakefile at the
# pinned tag and then measured. So the knowledge is explicit here rather than
# guessed at run time.
#
# Fields:
#   version       the version to verify (must match the database entry)
#   tarball       upstream tag tarball (the .gem has no tests)
#   sos           installed-gem .so path => destination inside the upstream tree
#   extra_copies  non-.so files to copy the same way (generated sources that the
#                 gem's rakelib would build; the upstream tarball lacks them)
#   generate      external commands to run against the just-fetched upstream
#                 tree, before the .so is injected: { chdir:, argv: } steps run
#                 in order (see run_generate_steps). Used for a gem whose
#                 rakelib generates sources with a tool this repository does
#                 not carry (protoc, for google-protobuf) -- the upstream
#                 *source* tarball never contains what that tool would have
#                 produced at release time, unlike extra_copies' generated
#                 files, which the packaged .gem already carries. A step may
#                 give `glob:` instead of a literal argv, for a command that
#                 must run once per file matched inside `chdir` (protoc across
#                 every .proto in a directory); one of the `argv` entries must
#                 then be the symbol :file, substituted with each match in turn
#                 -- this is what stands in for a shell `for` loop.
#   generated_copies  extra_copies' counterpart for files a `generate` step
#                 wrote: same { from => to } shape, but from is relative to the
#                 just-fetched source tree (where `generate` wrote it) rather
#                 than the installed gem.
#   test_deps     pure-Ruby gems the suite needs. Installed *without* RUBYCC:
#                 a Ruby test dependency has no C to compile and must not be
#                 dragged through the compiler under test.
#   test_dep_versions  exact versions for test_deps whose upstream suite has a
#                 compatibility pin; these are installed in preference to any
#                 incompatible version already cached in the scratch GEM_HOME.
#   force_ruby_platform  passes `--platform ruby` to `gem install`, for a gem
#                 that also publishes precompiled native-platform gems
#                 RubyGems would otherwise prefer over the source one (see
#                 install_args)
#   multi_extension_overwrites_gem_make_out  the gem's extensions list names
#                 more than one extension in the same ext directory, so
#                 RubyGems overwrites gem_make.out with the last one's
#                 transcript; skips the gem_make.out check in
#                 rubycc_build_evidence for this one gem rather than weakening
#                 it for every recipe (the Makefile check, still required,
#                 carries the proof instead)
#   extconf_args  arguments after `--` passed to the gem's extconf.rb
#   dep_load_paths  test_deps whose lib/ is put on the load path explicitly
#                 rather than left to RubyGems' require fallback
#   runner        :test_unit | :rspec | :ruby_files (see run_suite)
#   load_paths    -I entries, relative to the upstream tree
#   require_flags -r entries (the Rakefile's ruby_opts)
#   test_glob     which files make up the suite
#   exclude       globs subtracted from test_glob
#   bundle_gemfile :empty when the upstream helper requires bundler/setup but
#                 the suite should run without resolving the source Gemfile's
#                 development-only dependencies; bundle_gems lists the runtime
#                 and test gems that the synthetic file should activate
#   child_load_paths paths to export through RUBYLIB for subprocesses spawned by
#                 the suite (the parent gets -I flags, but children do not)
#   runner_args   arguments handed to the suite runner itself (the Rakefile's
#                 Rake::TestTask#options / rspec flags), e.g. an --ignore-name
#                 the gem's own task passes. Excluding such a test through
#                 `exclude` instead would drop the whole file it lives in.
#   sanity        { requires:, expr: } -- see check_sanity. MANDATORY.
# google-protobuf's generate step (below) reproduces ruby/Rakefile's
# well_known_protos list by hand -- protoc has to be run against each of these
# individually (plus compiler/plugin.proto, added separately below since its
# output lands in a different tmp/protoc-out subdirectory) because they are
# not covered by the tests/*.proto glob a `generate` step can express directly.
WELL_KNOWN_PROTOBUF_PROTOS = %w[
  any api descriptor duration empty field_mask source_context struct timestamp type wrappers
].freeze

RECIPES = {
  "json" => {
    version: "2.21.1",
    tarball: "https://github.com/ruby/json/archive/refs/tags/v2.21.1.tar.gz",
    sos: {
      "lib/json/ext/parser.so" => "lib/json/ext/parser.so",
      "lib/json/ext/generator.so" => "lib/json/ext/generator.so"
    },
    test_deps: %w[test-unit test-unit-ruby-core],
    runner: :test_unit,
    load_paths: %w[lib test],
    test_glob: "test/json/*_test.rb",
    # tools/m2_acceptance.rb's build_json has to set JSON_DISABLE_SIMD=1 because
    # it runs extconf.rb under the *host gcc*, whose SIMD probe succeeds and then
    # emits _mm_* intrinsics rubycc cannot compile. This tool never does that: the
    # install goes through the mkmf shim, so the probe's conftests are compiled by
    # rubycc, fail naturally, and the scalar path is selected (Step 60, and the
    # note already in data/verified_gems.json). Measured here: the install
    # succeeds with no JSON_DISABLE_SIMD in the environment, and the generated
    # Makefiles carry no SIMD define.
    sanity: {
      requires: %w[json],
      # JSON keeps a pure-Ruby generator for TruffleRuby and picks the extension
      # at require time, so the selected parser class is the honest proof.
      expr: 'JSON.parser.to_s == "JSON::Ext::Parser"'
    }
  },

  "msgpack" => {
    version: "1.8.3",
    tarball: "https://github.com/msgpack/msgpack-ruby/archive/refs/tags/v1.8.3.tar.gz",
    sos: { "lib/msgpack/msgpack.so" => "lib/msgpack/msgpack.so" },
    test_deps: %w[rspec],
    runner: :rspec,
    load_paths: %w[lib spec],
    # The Rakefile selects 'spec/{,cruby/}*_spec.rb' on MRI and
    # 'spec/{,jruby/}*_spec.rb' on JRuby: spec/jruby holds a JRuby-only extension
    # API and is not applicable here. Expressed as "everything but jruby" so the
    # exclusion is visible; measured to select the same files as the Rakefile's
    # MRI pattern at this tag (455 examples).
    test_glob: "spec/**/*_spec.rb",
    exclude: ["spec/jruby/**/*"],
    sanity: {
      requires: %w[msgpack],
      # msgpack has no pure-Ruby fallback on MRI (lib/msgpack.rb requires
      # msgpack/msgpack unconditionally), so there is no "wrong implementation"
      # constant to look at -- but there is a wrong *copy*: any other msgpack
      # installation on the load path. The generic proof (the injected .so is in
      # $LOADED_FEATURES) is exactly the one that catches that, so it stands alone.
      expr: "injected_so_loaded?"
    }
  },

  "bigdecimal" => {
    version: "4.1.2",
    tarball: "https://github.com/ruby/bigdecimal/archive/refs/tags/v4.1.2.tar.gz",
    sos: { "lib/bigdecimal.so" => "lib/bigdecimal.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    runner: :test_unit,
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    test_glob: "test/bigdecimal/**/test_*.rb",
    # BIGDECIMAL_USE_VP_TEST_METHODS is deliberately left unset: the 11 tests it
    # would enable are reported as omissions, which is the normal, recorded state
    # (Steps 93-97), not a failure.
    sanity: {
      requires: %w[bigdecimal],
      # bigdecimal ships as a default gem with the interpreter, so the real risk
      # is testing *that* copy instead of the rubycc-built one; the injected-.so
      # check is the proof that distinguishes them (a class/constant check cannot).
      expr: "injected_so_loaded?"
    }
  },

  "redcarpet" => {
    version: "3.6.1",
    tarball: "https://github.com/vmg/redcarpet/archive/refs/tags/v3.6.1.tar.gz",
    sos: { "lib/redcarpet.so" => "lib/redcarpet.so" },
    test_deps: %w[test-unit],
    runner: :test_unit,
    load_paths: %w[lib test],
    test_glob: "test/*_test.rb",
    sanity: {
      requires: %w[redcarpet],
      # lib/redcarpet.rb does `require 'redcarpet.so'` with no fallback, so there
      # is no pure-Ruby implementation to detect; the injected-.so check is what
      # proves the loaded object is ours.
      expr: "injected_so_loaded?"
    }
  },

  "racc" => {
    version: "1.8.1",
    tarball: "https://github.com/ruby/racc/archive/refs/tags/v1.8.1.tar.gz",
    sos: { "lib/racc/cparse.so" => "lib/racc/cparse.so" },
    # lib/racc/parser-text.rb is generated by the Rakefile (it embeds parser.rb as
    # a string) and is therefore absent from the upstream tarball but present in
    # the installed gem. test/test_parser_text.rb needs it. This is the manual
    # step the racc entry's notes already record.
    extra_copies: { "lib/racc/parser-text.rb" => "lib/racc/parser-text.rb" },
    test_deps: %w[test-unit test-unit-ruby-core],
    runner: :test_unit,
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[racc/parser],
      # racc/parser.rb rescues LoadError around `require 'racc/cparse'` and falls
      # back to a pure-Ruby runtime, recording which one won in this constant --
      # the suite passes either way, so this is the check that makes the record
      # truthful.
      expr: 'Racc::Parser::Racc_Runtime_Type == "c"'
    }
  },

  "date" => {
    version: "3.5.1",
    tarball: "https://github.com/ruby/date/archive/refs/tags/v3.5.1.tar.gz",
    sos: { "lib/date_core.so" => "lib/date_core.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    # test/lib/helper.rb does `require "core_assertions"`, which lives in
    # test-unit-ruby-core. Without it assert_ractor/assert_warning are missing and
    # three tests fail with NoMethodError -- not a gem failure. Measured: with the
    # gem installed in the scratch GEM_HOME, RubyGems' require fallback finds it
    # even without this entry; the explicit path removes that dependence.
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[date],
      # date is a default gem: `require "date"` resolves to the interpreter's own
      # date_core.so unless the injected one comes first on the load path. Only
      # the injected-.so check can tell those two apart.
      expr: "injected_so_loaded?"
    }
  },

  # The two recipes below were written in Step 146 while both gems still failed
  # to compile, and were kept as the re-verification harness for the six rubycc
  # gaps that run measured. Both now pass: nkf once incomplete-array composition
  # landed (Step 150, recorded Step 151) and stackprof once _POSIX_MONOTONIC_CLOCK
  # and __dso_handle did (Steps 149/152, recorded Step 153).
  "stackprof" => {
    version: "0.2.28",
    tarball: "https://github.com/tmm1/stackprof/archive/refs/tags/v0.2.28.tar.gz",
    # extconf.rb calls create_makefile('stackprof/stackprof'), so the built object
    # lands one directory down from lib/, both in the installed gem and in the
    # upstream tree the suite loads from.
    sos: { "lib/stackprof/stackprof.so" => "lib/stackprof/stackprof.so" },
    # The suite is minitest (the gemspec's only test-side development dependency).
    # minitest is a *bundled* gem, so it lives in the interpreter's gem dir and is
    # unreachable from the scratch GEM_HOME -- measured: requiring
    # minitest/autorun with GEM_PATH pointed at the scratch home raises LoadError.
    test_deps: %w[minitest],
    runner: :test_unit,
    load_paths: %w[lib test],
    # Same FileList the Rakefile's Rake::TestTask uses. test/test_truffleruby.rb is
    # kept rather than excluded: its whole body is inside `if RUBY_ENGINE ==
    # 'truffleruby'`, so on MRI it defines no test and contributes nothing.
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[stackprof],
      # lib/stackprof.rb requires "stackprof/truffleruby" only under TruffleRuby
      # and "stackprof/stackprof" unconditionally otherwise, so on MRI there is no
      # pure-Ruby fallback and no "which implementation won" constant to read --
      # the injected-.so check is the available proof. (StackProf::VERSION is
      # defined in the .rb file, not the extension, so it proves nothing.)
      expr: "injected_so_loaded?"
    }
  },

  "nkf" => {
    version: "0.3.0",
    tarball: "https://github.com/ruby/nkf/archive/refs/tags/v0.3.0.tar.gz",
    sos: { "lib/nkf.so" => "lib/nkf.so" },
    # test/nkf/test_nkf.rb requires "core_assertions", which lives in
    # test-unit-ruby-core (the same pair the gem's own Gemfile lists).
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    load_paths: %w[lib test],
    # The Rakefile's FileList. test_sig/ is a separate rbs-only task and is not
    # part of `rake test`, so the glob deliberately does not reach it.
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[nkf],
      # nkf ships with the interpreter (a bundled gem in Ruby 3.4), so the danger
      # is testing that copy instead of the rubycc-built one; lib/nkf.rb's only
      # alternative branch is the JRuby .jar, which cannot be reached here, so
      # there is no C-vs-Ruby switch to observe and the injected-.so check is the
      # proof that separates the two copies.
      expr: "injected_so_loaded?"
    }
  },

  # The three recipes below are default gems: `require "strscan"` resolves to the
  # interpreter's own strscan.so unless the injected one comes first on the load
  # path. Measured on this interpreter (ruby 3.4.5): none of the three is loaded
  # at startup, and each resolves to a separate .so under
  # <rubylibdir>/x86_64-linux/, so the injected-.so check really does separate the
  # two copies rather than being a formality.
  "strscan" => {
    version: "3.1.6",
    tarball: "https://github.com/ruby/strscan/archive/refs/tags/v3.1.6.tar.gz",
    sos: { "lib/strscan.so" => "lib/strscan.so" },
    # test/lib/helper.rb requires "core_assertions" (test-unit-ruby-core), the
    # same pair the gem's Gemfile lists.
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    # lib is needed twice over: for the injected strscan.so and for
    # lib/strscan/strscan.rb, which Init_strscan pulls in with
    # rb_require("strscan/strscan") and which defines StringScanner#scan_integer.
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    # run-test.rb (what the Rakefile's test task runs) requires test/lib/helper
    # and then globs test/strscan/**/*test_*.rb; both are expressed above.
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[strscan],
      # lib/strscan/strscan.rb only adds a method to the class the extension
      # defines, and the alternative implementation (ext/jruby) cannot be reached
      # on MRI, so there is no C-vs-Ruby switch to read: the injected-.so check is
      # the proof, and here it is doing the default-gem work described above.
      expr: "injected_so_loaded?"
    }
  },

  "stringio" => {
    version: "3.2.0",
    tarball: "https://github.com/ruby/stringio/archive/refs/tags/v3.2.0.tar.gz",
    sos: { "lib/stringio.so" => "lib/stringio.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    # The Rakefile's Rake::TestTask: libs = the built extension's dir + test/lib,
    # ruby_opts -rhelper, test_files FileList["test/**/test_*.rb"].
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    # test/ruby/ut_eof.rb is deliberately not matched: test_stringio.rb pulls it
    # in with require_relative, exactly as the Rakefile's FileList leaves it.
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[stringio],
      # The only non-C implementation is lib/java/stringio.rb, selected by the
      # gemspec's `java` platform and unreachable on MRI, so nothing in the loaded
      # code says "C or Ruby"; the injected-.so check is the available proof.
      expr: "injected_so_loaded?"
    }
  },

  # etc passes as of Step 162. It is kept annotated because the three rubycc gaps
  # it exposed are what Steps 158-161 fixed, and this recipe is the harness that
  # confirmed them. Measured in Step 157, each found by removing the one before it:
  #   1. rmake's recipe tokenizer does not do POSIX backslash removal, so mkmf's
  #      `-DSYSCONFDIR=\"...\"` reaches the compiler with its backslashes intact.
  #      GNU make + rubycc builds the same Makefile, and rmake + gcc fails the
  #      same way, so the gap is in Rubycc::Rmake::Executor#tokenize, not in the
  #      compiler or the gem.
  #   2. ruby.h defines HAVE_RUBY_ATOMIC_H, so etc.c includes ruby/atomic.h,
  #      whose HAVE_GCC_ATOMIC_BUILTINS branch needs __atomic_load_n / store_n /
  #      exchange_n / compare_exchange_n / fetch_add / fetch_sub / add_fetch /
  #      sub_fetch / or_fetch. rubycc implements none of them, and the header's
  #      fallback chain ends in `#error Unsupported platform`.
  #   3. the bundled unistd.h declares neither confstr, fpathconf nor getlogin,
  #      which mkmf's have_func probes cannot notice (they declare the function
  #      themselves), so HAVE_CONFSTR and friends get defined anyway.
  # With those three worked around by hand the translation unit compiles, but the
  # suite would still be quietly smaller than the gcc control's 18 tests: the
  # bundled unistd.h carries 11 of the 179 constants ext/etc/constdefs.h defines
  # under gcc, and test_etc.rb defines test_confstr / test_pathconf only
  # `if defined?(Etc::CS_PATH)` / `Etc::PC_PIPE_BUF`.
  "etc" => {
    version: "1.4.6",
    tarball: "https://github.com/ruby/etc/archive/refs/tags/v1.4.6.tar.gz",
    sos: { "lib/etc.so" => "lib/etc.so" },
    # test/etc/test_etc.rb calls assert_ractor, which comes from core_assertions
    # in test-unit-ruby-core.
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    test_glob: "test/**/test_*.rb",
    # ext/etc/constdefs.h is generated by ext/etc/mkconstants.rb, but extconf.rb
    # generates it itself when absent, so unlike racc's parser-text.rb there is
    # nothing to copy into the upstream tree: the suite only needs the .so.
    sanity: {
      requires: %w[etc],
      # etc has no Ruby implementation at all (the gem is the extension), so there
      # is no fallback to detect -- only the wrong *copy* to rule out, which is
      # what the injected-.so check does.
      expr: "injected_so_loaded?"
    }
  },

  "io-nonblock" => {
    version: "0.3.2",
    tarball: "https://github.com/ruby/io-nonblock/archive/refs/tags/v0.3.2.tar.gz",
    # create_makefile("io/nonblock"), so the installed gem puts the one extension
    # under lib/io/. The upstream tarball ships no lib/ at all (the Rakefile
    # builds into lib/<ruby version>/<platform>), so injecting here creates it.
    sos: { "lib/io/nonblock.so" => "lib/io/nonblock.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    # The Rakefile's Rake::TestTask: libs = the built extension's dir + test/lib,
    # ruby_opts -rhelper, test_files FileList["test/**/test_*.rb"].
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    test_glob: "test/**/test_*.rb",
    sanity: {
      # test_flush.rb wraps its own `require 'io/nonblock'` in a rescue LoadError
      # and then guards the whole class with `if IO.method_defined?(:nonblock)`,
      # so a suite that loaded nothing reports zero failures rather than an error.
      # Requiring it here, outside that rescue, is what turns that into a failure.
      requires: %w[io/nonblock],
      # io/nonblock ships with the interpreter and has no Ruby implementation to
      # fall back to, so the only wrong outcome to rule out is the interpreter's
      # own copy winning the require -- exactly what the injected-.so check sees.
      expr: "injected_so_loaded?"
    }
  },

  "io-wait" => {
    version: "0.4.0",
    tarball: "https://github.com/ruby/io-wait/archive/refs/tags/v0.4.0.tar.gz",
    # create_makefile("io/wait") with no probes at all -- extconf.rb is three
    # lines, so there is no configure-time branch for rubycc and gcc to disagree
    # about and the same translation unit is what both compile.
    sos: { "lib/io/wait.so" => "lib/io/wait.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    # The Rakefile's Rake::TestTask: libs = the built extension's dir + test/lib,
    # ruby_opts -rhelper, test_files FileList["test/**/test_*.rb"], and the
    # --ignore-name below.
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    test_glob: "test/**/test_*.rb",
    # Upstream's own task skips test_after_ungetc_in_text_wait_readable. It lives
    # in test_io_wait_uncommon.rb next to tests that do run, so `exclude` (which
    # drops whole files) would take those with it.
    runner_args: ["--ignore-name=/ungetc_in_text/"],
    sanity: {
      requires: %w[io/wait],
      # io/wait ships with the interpreter and has no pure-Ruby implementation on
      # MRI (ext/java/lib/io/wait.rb is the JRuby platform's), so the only wrong
      # outcome is the interpreter's own copy winning the require.
      expr: "injected_so_loaded?"
    }
  },

  "erb" => {
    version: "6.0.1.1",
    tarball: "https://github.com/ruby/erb/archive/refs/tags/v6.0.1.1.tar.gz",
    sos: { "lib/erb/escape.so" => "lib/erb/escape.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    # The Rakefile's Rake::TestTask appends 'test/lib' to the default libs
    # (["lib"]) and passes ruby_opts -rhelper.
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    test_glob: "test/**/test_*.rb",
    sanity: {
      # Plain 'erb', not 'erb/escape': lib/erb/util.rb is where the fallback
      # lives, and requiring the extension directly would step around the very
      # branch this check exists to observe.
      requires: %w[erb],
      # lib/erb/util.rb wraps `require 'erb/escape'` in a rescue LoadError and
      # defines a pure-Ruby ERB::Escape#html_escape over CGI.escapeHTML when it
      # fails, so this looked like the blindest of the fallback gems. Measured
      # instead (Step 166): corrupting the injected escape.so leaves 47 of 48
      # tests passing, and the one that fails is upstream's own
      # test_html_escape_extension, which asserts html_escape has no
      # source_location. So erb's suite *does* catch its own fallback -- the
      # second conjunct below only restates a test the suite already runs.
      # What upstream cannot see is the wrong *copy*: the interpreter ships
      # erb/escape.so too, and against that one all 48 pass. injected_so_loaded?
      # is the conjunct that earns its place here.
      expr: "injected_so_loaded? && ERB::Escape.instance_method(:html_escape).source_location.nil?"
    }
  },

  "io-console" => {
    version: "0.8.2",
    tarball: "https://github.com/ruby/io-console/archive/refs/tags/v0.8.2.tar.gz",
    sos: { "lib/io/console.so" => "lib/io/console.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    # The Rakefile's Rake::TestTask *replaces* libs with the built extension's
    # dir and then appends test/lib; ruby_opts -rhelper. Its --ignore-name is
    # guarded by RUBY_ENGINE == "jruby", so it does not apply here.
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[io/console],
      # io/console ships with the interpreter, and the gem also carries a pure
      # Ruby FFI implementation under lib/ffi/ for JRuby. Neither is what this
      # run is supposed to exercise; the injected-.so check rules out both.
      expr: "injected_so_loaded?"
    }
  },

  "digest" => {
    version: "3.2.1",
    tarball: "https://github.com/ruby/digest/archive/refs/tags/v3.2.1.tar.gz",
    # The first corpus gem with more than one extension: six extconf.rb under
    # ext/digest, each producing its own .so. ext/digest/digest.c holds the
    # framework the other five register their algorithms with.
    sos: {
      "lib/digest.so" => "lib/digest.so",
      "lib/digest/bubblebabble.so" => "lib/digest/bubblebabble.so",
      "lib/digest/md5.so" => "lib/digest/md5.so",
      "lib/digest/rmd160.so" => "lib/digest/rmd160.so",
      "lib/digest/sha1.so" => "lib/digest/sha1.so",
      "lib/digest/sha2.so" => "lib/digest/sha2.so"
    },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    # The Rakefile's Rake::TestTask: libs << test, test/lib, lib and (on MRI)
    # ext/digest/lib, which is where digest/loader.rb and digest/sha2/loader.rb
    # live in the source tree -- `gem install` copies them into lib/, the
    # upstream tarball does not. ruby_opts -rhelper.
    load_paths: %w[test test/lib lib ext/digest/lib],
    require_flags: %w[helper],
    test_glob: "test/**/test_*.rb",
    sanity: {
      # The sanity gate demands that *every* injected .so end up in
      # $LOADED_FEATURES, so all six are named here. Requiring only "digest"
      # would load two of them and leave the other four unproven: the algorithm
      # extensions are pulled in lazily by Digest's const_missing.
      requires: %w[digest digest/bubblebabble digest/md5 digest/rmd160 digest/sha1 digest/sha2],
      # digest ships with the interpreter and has no pure-Ruby implementation on
      # MRI (ext/java is JRuby's), so the wrong *copy* is the failure to rule out
      # -- and with six .so there are six chances to load the wrong one.
      expr: "injected_so_loaded?"
    }
  },

  "zlib" => {
    version: "3.2.3",
    tarball: "https://github.com/ruby/zlib/archive/refs/tags/v3.2.3.tar.gz",
    # The first corpus gem that links a *host* library. extconf.rb's
    # have_library('z', 'deflateReset(NULL)', 'zlib.h') is a try_link, so it only
    # succeeds if rubycc can both find the host's zlib.h and link against -lz;
    # failing it does not fail the build, it silently switches to the bundled-zlib
    # branch (which needs sources the gem does not ship), so what the probe chose
    # has to be read out of the generated Makefile rather than assumed.
    sos: { "lib/zlib.so" => "lib/zlib.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    # The Rakefile's Rake::TestTask appends test/lib to the default libs
    # (["lib"], where the built extension lands) and passes ruby_opts -rhelper.
    load_paths: %w[lib test/lib],
    require_flags: %w[helper],
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[zlib],
      # zlib ships with the interpreter and has no pure-Ruby fallback, so the
      # only wrong outcome is the interpreter's own copy winning the require.
      expr: "injected_so_loaded?"
    }
  },

  "psych" => {
    version: "5.3.1",
    tarball: "https://github.com/ruby/psych/archive/refs/tags/v5.3.1.tar.gz",
    # The second host-library gem, and the one that reaches rubycc's pkg-config
    # shim: extconf.rb tries pkg_config('yaml-0.1') first and only falls back to
    # find_header('yaml.h') + find_library('yaml', ...) when that comes up empty.
    # Both fallbacks abort the build outright when they fail, so unlike zlib there
    # is no silent second path to end up on -- but which of the two branches ran
    # still has to be read out of the transcript.
    sos: { "lib/psych.so" => "lib/psych.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    # The Rakefile's Rake::TestTask appends test/lib and test to the default libs
    # (["lib"]) and passes ruby_opts -rhelper.
    load_paths: %w[lib test/lib test],
    require_flags: %w[helper],
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[psych],
      # psych ships with the interpreter and has no pure-Ruby parser on MRI
      # (ext/java is JRuby's SnakeYAML binding), so the wrong copy is what the
      # injected-.so check has to rule out.
      expr: "injected_so_loaded?"
    }
  },

  "openssl" => {
    version: "4.0.2",
    tarball: "https://github.com/ruby/openssl/archive/refs/tags/v4.0.2.tar.gz",
    sos: { "lib/openssl.so" => "lib/openssl.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    load_paths: %w[lib test],
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[openssl],
      expr: "injected_so_loaded?"
    }
  },

  "syslog" => {
    version: "0.3.0",
    tarball: "https://github.com/ruby/syslog/archive/refs/tags/v0.3.0.tar.gz",
    sos: { "lib/syslog_ext.so" => "lib/syslog_ext.so" },
    test_deps: %w[test-unit],
    runner: :test_unit,
    load_paths: %w[lib test],
    test_glob: "test/**/test_*.rb",
    sanity: {
      requires: %w[syslog],
      expr: "injected_so_loaded?"
    }
  },

  "nio4r" => {
    version: "2.7.5",
    tarball: "https://github.com/socketry/nio4r/archive/refs/tags/v2.7.5.tar.gz",
    sos: { "lib/nio4r_ext.so" => "lib/nio4r_ext.so" },
    test_deps: %w[rspec],
    # libev is embedded in nio4r, so its API is intentionally private to the
    # extension. Its C11 memory fence is lowered by rubycc to the target's
    # machine barrier; EV_API_STATIC also keeps libev's initialized globals in
    # the same translation unit instead of relying on an `extern` definition.
    extconf_args: ["--with-cflags=-fPIC -DEV_API_STATIC"],
    runner: :rspec,
    load_paths: %w[lib spec],
    test_glob: "spec/**/*_spec.rb",
    sanity: {
      requires: %w[nio],
      expr: "injected_so_loaded?"
    }
  },

  "byebug" => {
    version: "13.0.0",
    tarball: "https://github.com/deivid-rodriguez/byebug/archive/refs/tags/v13.0.0.tar.gz",
    sos: { "lib/byebug/byebug.so" => "lib/byebug/byebug.so" },
    test_deps: %w[minitest pry],
    # The current minitest 6 release removed minitest/mock; byebug's upstream
    # Gemfile pins its development suite to ~> 5.25.
    test_dep_versions: { "minitest" => "5.25.5", "pry" => "0.15.2" },
    runner: :test_unit,
    load_paths: %w[lib test],
    require_flags: %w[minitest/autorun],
    test_glob: "test/**/*_test.rb",
    sanity: {
      # byebug.rb only installs Kernel#byebug; the extension itself is loaded
      # by byebug/core, which is what the upstream test helper requires too.
      requires: %w[byebug/core],
      expr: "injected_so_loaded?"
    }
  },

  "http_parser.rb" => {
    version: "0.8.1",
    tarball: "https://github.com/tmm1/http_parser.rb/archive/refs/tags/v0.8.1.tar.gz",
    sos: { "lib/ruby_http_parser.so" => "lib/ruby_http_parser.so" },
    test_deps: %w[rspec],
    runner: :rspec,
    load_paths: %w[lib spec],
    test_glob: "spec/**/*_spec.rb",
    sanity: {
      requires: %w[http_parser],
      expr: "injected_so_loaded?"
    }
  },

  "debug" => {
    version: "1.11.1",
    tarball: "https://github.com/ruby/debug/archive/refs/tags/v1.11.1.tar.gz",
    sos: { "lib/debug/debug.so" => "lib/debug/debug.so" },
    # test-unit-rr provides the "test/unit/rr" every console test requires; it is
    # a test dependency the .gem does not carry, and without it the suite dies at
    # load with a LoadError rather than running (measured, and identically so
    # under --control, which is what proved it was a missing gem rather than a
    # rubycc failure).
    test_deps: %w[test-unit test-unit-rr],
    runner: :test_unit,
    load_paths: %w[lib test],
    test_glob: "test/console/*_test.rb",
    sanity: {
      requires: %w[debug],
      expr: "injected_so_loaded?"
    }
  },

  "websocket-driver" => {
    version: "0.8.2",
    tarball: "https://github.com/faye/websocket-driver-ruby/archive/refs/tags/0.8.2.tar.gz",
    sos: { "lib/websocket_mask.so" => "lib/websocket_mask.so" },
    test_deps: %w[rspec],
    runner: :rspec,
    load_paths: %w[lib spec],
    bundle_gemfile: :empty,
    bundle_gems: %w[base64 websocket-extensions rspec],
    test_glob: "spec/**/*_spec.rb",
    sanity: {
      requires: %w[websocket/driver],
      expr: "injected_so_loaded?"
    }
  },

  "prism" => {
    version: "1.8.1",
    tarball: "https://github.com/ruby/prism/archive/refs/tags/v1.8.1.tar.gz",
    sos: { "lib/prism/prism.so" => "lib/prism/prism.so" },
    # The source archive leaves the generated Ruby API files out; they are
    # present in the packaged gem and are required by lib/prism.rb or its test
    # visitors before/after the extension loads.
    extra_copies: {
      "lib/prism/compiler.rb" => "lib/prism/compiler.rb",
      "lib/prism/dispatcher.rb" => "lib/prism/dispatcher.rb",
      "lib/prism/dot_visitor.rb" => "lib/prism/dot_visitor.rb",
      "lib/prism/dsl.rb" => "lib/prism/dsl.rb",
      "lib/prism/inspect_visitor.rb" => "lib/prism/inspect_visitor.rb",
      "lib/prism/mutation_compiler.rb" => "lib/prism/mutation_compiler.rb",
      "lib/prism/node.rb" => "lib/prism/node.rb",
      "lib/prism/reflection.rb" => "lib/prism/reflection.rb",
      "lib/prism/serialize.rb" => "lib/prism/serialize.rb",
      "lib/prism/visitor.rb" => "lib/prism/visitor.rb"
    },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    load_paths: %w[lib test/prism],
    test_glob: "test/prism/**/*_test.rb",
    sanity: {
      requires: %w[prism],
      expr: "injected_so_loaded?"
    }
  },

  "fiddle" => {
    version: "1.1.8",
    tarball: "https://github.com/ruby/fiddle/archive/refs/tags/v1.1.8.tar.gz",
    sos: { "lib/fiddle.so" => "lib/fiddle.so" },
    test_deps: %w[test-unit test-unit-ruby-core],
    dep_load_paths: %w[test-unit-ruby-core],
    runner: :test_unit,
    load_paths: %w[lib test/fiddle],
    test_glob: "test/fiddle/test_*.rb",
    sanity: {
      requires: %w[fiddle],
      expr: "injected_so_loaded?"
    }
  },

  "bootsnap" => {
    version: "1.24.6",
    tarball: "https://github.com/Shopify/bootsnap/archive/refs/tags/v1.24.6.tar.gz",
    sos: { "lib/bootsnap/bootsnap.so" => "lib/bootsnap/bootsnap.so" },
    test_deps: %w[minitest mocha],
    test_dep_versions: { "minitest" => "5.25.5" },
    runner: :test_unit,
    load_paths: %w[lib test],
    bundle_gemfile: :empty,
    bundle_gems: %w[msgpack bundler minitest mocha],
    child_load_paths: %w[lib test],
    test_glob: "test/**/*_test.rb",
    sanity: {
      # Init_bootsnap looks up UNCOMPILABLE, which the Ruby wrapper defines
      # before loading the .so. Requiring only the .so would be an invalid
      # sanity probe rather than a build failure.
      requires: %w[bootsnap/compile_cache bootsnap/bootsnap],
      expr: "injected_so_loaded?"
    }
  },

  "oj" => {
    version: "3.17.4",
    tarball: "https://github.com/ohler55/oj/archive/refs/tags/v3.17.4.tar.gz",
    sos: { "lib/oj/oj.so" => "lib/oj/oj.so" },
    test_deps: %w[minitest],
    test_dep_versions: { "minitest" => "5.25.5" },
    runner: :test_unit,
    load_paths: %w[lib test ext],
    test_glob: "test/test_*.rb",
    sanity: {
      requires: %w[oj],
      expr: "injected_so_loaded?"
    }
  },

  "yajl-ruby" => {
    version: "1.4.3",
    tarball: "https://github.com/brianmario/yajl-ruby/archive/refs/tags/1.4.3.tar.gz",
    sos: { "lib/yajl/yajl.so" => "lib/yajl/yajl.so" },
    test_deps: %w[rspec],
    runner: :rspec,
    load_paths: %w[lib spec],
    test_glob: "spec/**/*_spec.rb",
    sanity: {
      requires: %w[yajl],
      expr: "injected_so_loaded?"
    }
  },

  "puma" => {
    version: "8.0.2",
    tarball: "https://github.com/puma/puma/archive/refs/tags/v8.0.2.tar.gz",
    sos: { "lib/puma/puma_http11.so" => "lib/puma/puma_http11.so" },
    # minitest-proveit is required by puma's own test/helper.rb; like debug's
    # test-unit-rr it is absent from the .gem and its absence kills the suite at
    # load time, in the control run just as much as the rubycc one.
    # puma's test/helper.rb and its Gemfile name the whole set below; the .gem
    # carries none of them, and each missing one kills the suite at load rather
    # than failing a test. They were found one at a time by --control runs, which
    # is what proved every one of them was a missing gem and not a rubycc defect.
    test_deps: %w[minitest minitest-proveit minitest-stub-const
                  minitest-retry concurrent-ruby rack rackup localhost],
    # minitest must stay on the 5.x line: puma's helper.rb requires
    # "minitest/mock", which minitest 6 moved out into a separate gem that in
    # turn depends on minitest ~> 5 -- so a 6.x activation makes the require
    # unsatisfiable no matter which extra gems are installed. 5.27.0 is the
    # newest 5.x and satisfies the Gemfile's ">= 5.26".
    test_dep_versions: { "minitest" => "5.27.0" },
    runner: :test_unit,
    load_paths: %w[lib test],
    test_glob: "test/test_*.rb",
    sanity: {
      requires: %w[puma],
      expr: "injected_so_loaded?"
    }
  },

  "google-protobuf" => {
    version: "4.35.1",
    # protocolbuffers/protobuf tags its Ruby releases without the leading
    # major component: the gemspec this version installs reports 4.35.1, but
    # the upstream tag is "v35.1" (there is no "v4.35.1" tag). Measured
    # against the tag list at protocolbuffers/protobuf.
    tarball: "https://github.com/protocolbuffers/protobuf/archive/refs/tags/v35.1.tar.gz",
    # google-protobuf ships precompiled gems for several platforms; without
    # this, `gem install` picks one of those over the source gem and the
    # build never goes near rubycc at all. See install_args.
    force_ruby_platform: true,
    # The gemspec lists two extensions in ext/google/protobuf_c/ (extconf.rb,
    # then Rakefile); both build into the same directory, so RubyGems' second
    # (Rakefile-driven, FFI-variant-only) build overwrites the first's
    # gem_make.out on disk even though `gem install -V` shows the first one
    # genuinely invoked rubycc's exe/rmake (measured). See
    # multi_extension_overwrites_gem_make_out in rubycc_build_evidence.
    multi_extension_overwrites_gem_make_out: true,
    # ruby/Rakefile's :genproto task runs protoc against the repo's own
    # .proto files and copies the result into lib/google/protobuf and tests/;
    # none of that is in the source tarball (only the .proto inputs are), so
    # it is reproduced here with an external protoc instead of being copied
    # from anywhere. The well-known types need protoc run once per file
    # because their output lands in tmp/protoc-out/google/protobuf and is
    # picked up by generated_copies below; the test protos are handled with a
    # single `glob` step because their names do not matter beyond that.
    generate: [
      { chdir: "ruby", argv: ["mkdir", "-p", "tmp/protoc-out"] },
      *WELL_KNOWN_PROTOBUF_PROTOS.map do |proto|
        { chdir: "ruby",
          argv: ["protoc", "-I../src", "--ruby_out=tmp/protoc-out", "../src/google/protobuf/#{proto}.proto"] }
      end,
      { chdir: "ruby",
        argv: ["protoc", "-I../src", "--ruby_out=tmp/protoc-out", "../src/google/protobuf/compiler/plugin.proto"] },
      { chdir: "ruby", glob: "tests/*.proto",
        argv: ["protoc", "-I../src", "-I./tests", "--ruby_out=tests", :file] }
    ],
    # protoc mirrors each .proto's own path under tmp/protoc-out (so
    # compiler/plugin.proto lands at .../compiler/plugin_pb.rb), but the
    # Rakefile flattens every one of them into lib/google/protobuf -- matched
    # here file by file, rather than with a glob, so a proto that stops
    # generating shows up as "no such file" instead of a silently short suite.
    generated_copies: WELL_KNOWN_PROTOBUF_PROTOS.to_h { |proto|
      ["ruby/tmp/protoc-out/google/protobuf/#{proto}_pb.rb", "ruby/lib/google/protobuf/#{proto}_pb.rb"]
    }.merge(
      "ruby/tmp/protoc-out/google/protobuf/compiler/plugin_pb.rb" => "ruby/lib/google/protobuf/plugin_pb.rb"
    ),
    # ext/google/protobuf_c/extconf.rb calls create_makefile(ext_name) with
    # ext_name "google/protobuf_c", so the built object lands at
    # lib/google/protobuf_c.so both in the installed gem and in the upstream
    # tree the suite loads from.
    sos: { "lib/google/protobuf_c.so" => "ruby/lib/google/protobuf_c.so" },
    test_deps: %w[test-unit],
    runner: :test_unit,
    load_paths: %w[ruby/lib ruby/tests],
    # ruby/Rakefile:200's Rake::TestTask: FileList["tests/*.rb"].exclude(
    # "tests/gc_test.rb", "tests/common_tests.rb"). *_pb.rb is excluded on top
    # of that here: it is generate's own output (protoc-generated message
    # definitions), not a test file, and the Rakefile only gets away with
    # leaving it in the glob because loading one defines no test cases.
    test_glob: "ruby/tests/*.rb",
    exclude: %w[ruby/tests/gc_test.rb ruby/tests/common_tests.rb ruby/tests/*_pb.rb],
    sanity: {
      requires: %w[google/protobuf],
      # lib/google/protobuf.rb only switches to the pure-Ruby FFI
      # implementation when PROTOCOL_BUFFERS_RUBY_IMPLEMENTATION=ffi is set in
      # the environment, which this run never does, so it always takes the
      # NATIVE branch and requires the .so directly. The wrong *copy* -- not a
      # wrong implementation -- is therefore the only failure mode left for
      # the injected-.so check to rule out.
      expr: "injected_so_loaded?"
    }
  }
}.freeze

# fcntl (a corpus gem, and a default gem like the three above) has no recipe on
# purpose: ruby/fcntl ships no tests. Measured at tag v1.3.0 and on master --
# there is no test/ directory, the Rakefile defines no test task, and the CI
# workflow's "Run test" step is `bundle exec rake compile`. This tool can only
# produce the (d)-level evidence data/verified_gems.json accepts ("the gem's own
# suite passed"), so fcntl cannot be recorded from here no matter how well it
# builds; a recipe pointed at someone else's tests would not be that evidence.

# --- CLI --------------------------------------------------------------------

options = { gems: [], all: false, update: false, step: nil, notes: nil,
            data: Rubycc::Doctor::VerifiedGems::DEFAULT_PATH, list: false, control: false }

args = ARGV.dup
until args.empty?
  arg = args.shift
  case arg
  when "--all"     then options[:all] = true
  when "--update"  then options[:update] = true
  when "--list"    then options[:list] = true
  when "--control" then options[:control] = true
  when "--step"    then options[:step] = (args.shift || abort("--step needs a step number"))
  when "--notes"   then options[:notes] = (args.shift || abort("--notes needs text"))
  when "--data"    then options[:data] = (args.shift || abort("--data needs a path"))
  when "-h", "--help"
    # The file's own header comment is the usage text: skip the shebang and the
    # magic comment, then print the comment block that follows.
    body = File.readlines(__FILE__).drop(2).drop_while { |l| !l.start_with?("#") }
    puts body.take_while { |l| l.start_with?("#") }.map { |l| l.sub(/\A# ?/, "") }.join
    exit 0
  when /\A-/ then abort "unknown option #{arg.inspect} (see --help)"
  else options[:gems] << arg
  end
end

def step(msg)
  warn "==> #{msg}"
end

# --- process helpers --------------------------------------------------------

# Run a command that is a precondition for everything after it; abort the tool on
# failure (mirrors tools/m2_acceptance.rb's run!).
def run!(*cmd, chdir: nil, env: {})
  output, status = capture(cmd, chdir: chdir, env: env, timeout: BUILD_TIMEOUT)
  unless status
    warn "FAILED: #{cmd.join(' ')}  (in #{chdir || Dir.pwd})"
    warn output
    exit 1
  end
  output
end

# Run a command whose failure is a *result* to report, not a reason to stop.
def run(*cmd, chdir: nil, env: {}, timeout: TEST_TIMEOUT)
  capture(cmd, chdir: chdir, env: env, timeout: timeout)
end

def capture(cmd, chdir:, env:, timeout:)
  chdir ||= Dir.pwd
  output = +""
  status = nil
  Timeout.timeout(timeout) do
    # Empty stdin, never the terminal's: a `gem uninstall` that decides to ask a
    # question must hit EOF and give up rather than hang until the timeout.
    output, status = Open3.capture2e(CLEARED_ENV.merge(env), *cmd, chdir: chdir, stdin_data: "")
  end
  [output, status&.success? || false]
rescue Timeout::Error
  ["timed out after #{timeout}s", false]
end

def download(url, dest)
  return if File.exist?(dest)

  run!("curl", "-sL", "--fail", "-o", dest, url)
end

# --- scratch GEM_HOME -------------------------------------------------------
#
# A non-empty GEM_HOME is mandatory: `gem install` with an empty/unset GEM_HOME
# installs into the developer's real gem home (and, under bundler, can rewrite
# this repository's state). Everything below therefore threads an explicit
# --install-dir as well as GEM_HOME/GEM_PATH.
#
# --control uses a *second* scratch GEM_HOME (gemhome-control) rather than
# reusing the rubycc one: sharing it would leave both builds' .so files mixed
# together on disk with no way to tell, after the fact, which build produced
# what got tested.

def gem_home
  File.join(WORK_DIR, $control_mode ? "gemhome-control" : "gemhome")
end

def gem_env
  { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home, "RUBYCC" => "0" }
end

# The install command line every gem install shares, whichever cc ends up
# building it. Only the env passed alongside it (gem_env for --control,
# gem_env.merge("RUBYCC" => "1") for the rubycc path) decides which compiler
# runs -- and for --control, the rubycc gem is never installed into this
# scratch GEM_HOME at all (see install_through_control), so RUBYCC has no
# rubygems_plugin.rb to be read by in the first place.
def install_args(name, version, recipe)
  cached = cached_gem_path(name, version)
  args = ["gem", "install", cached || name]
  args.concat(["--version", version]) unless cached
  args.concat(["--install-dir", gem_home, "--no-document"])
  args << "--local" if cached
  # Some gems (google-protobuf among them) publish precompiled native-platform
  # gems alongside the source one; RubyGems prefers whichever matches the
  # running platform, which for the corpus environment means an install that
  # never calls extconf.rb at all -- and never touches rubycc (measured: a
  # plain `gem install google-protobuf --version 4.35.1` here installs
  # google-protobuf-4.35.1-x86_64-linux-gnu, with no ext/ and nothing for
  # rubycc_build_evidence to find). `--platform ruby` is RubyGems' own way to
  # ask for the source gem instead, so a recipe opts into it explicitly rather
  # than this being the default for every gem here (most never ship a native
  # platform gem to begin with).
  args.concat(["--platform", "ruby"]) if recipe[:force_ruby_platform] && !cached
  # `gem install /path/to/pkg.gem --local` resolves dependencies from the
  # local source index only; it does not use already-installed gems in the
  # scratch GEM_HOME. The cached packages are used specifically for an offline
  # retry, so dependency activation is still checked by the suite below while
  # the target package is installed without a registry lookup.
  args << "--ignore-dependencies" if cached
  extconf_args = Array(recipe[:extconf_args])
  args.concat(["--", *extconf_args]) unless extconf_args.empty?
  args
end

# Versions of +name+ present in the scratch GEM_HOME, newest last. The glob
# "test-unit-*" also matches test-unit-ruby-core, so what follows the name must
# really look like a version before the directory counts as this gem's.
def installed_versions(name)
  Dir.glob(File.join(gem_home, "specifications", "#{name}-*.gemspec")).filter_map do |path|
    suffix = File.basename(path, ".gemspec").delete_prefix("#{name}-")
    Gem::Version.new(suffix) if suffix.match?(/\A\d[\w.]*\z/)
  end.sort
end

def gem_installed?(name, version = nil)
  versions = installed_versions(name)
  version ? versions.include?(Gem::Version.new(version)) : versions.any?
end

# RubyGems stores every successfully downloaded package in GEM_HOME/cache. Use
# an exact cached package when it is available so a re-run remains useful during
# a network outage; the normal registry lookup remains the fallback for a cold
# cache. The exact filename is safe for gem names containing dots (for example
# http_parser.rb) because the version is already pinned by the recipe.
def cached_gem_path(name, version)
  filenames = if version
                ["#{name}-#{version}.gem"]
              else
                ["#{name}-*.gem"]
              end
  directories = [File.join(gem_home, "cache"), File.join(WORK_DIR, "packages")]
  paths = directories.flat_map { |dir| filenames.flat_map { |pattern| Dir.glob(File.join(dir, pattern)) } }
  paths.select! { |path| File.file?(path) }
  paths.max_by do |path|
    Gem::Version.new(File.basename(path, ".gem").delete_prefix("#{name}-"))
  end
end

# Build this checkout into a .gem and install it into the scratch GEM_HOME. That
# installed copy is what makes `RUBYCC=1 gem install <gem>` route through rubycc:
# RubyGems loads every installed gem's rubygems_plugin.rb before building an
# extension, and rubycc's plugin is what sets MAKE=rmake / CC=rubycc.
def install_rubycc!
  gem_file = File.join(WORK_DIR, "rubycc.gem")
  step "building rubycc from #{RUBYCC_ROOT}"
  run!("gem", "build", "rubycc.gemspec", "--output", gem_file, chdir: RUBYCC_ROOT, env: gem_env)

  step "installing rubycc into the scratch GEM_HOME (#{gem_home})"
  run!("gem", "install", gem_file, "--install-dir", gem_home, "--local", "--no-document",
       env: gem_env)
end

# Install a pure-Ruby test dependency. Never with RUBYCC=1: these gems are not
# what is under test, and routing them through rubycc would only add failure modes.
def ensure_test_dep(name, version = nil)
  if version
    requirement = Gem::Requirement.new("=#{version}")

    # RubyGems activates the newest installed version when a test does a plain
    # require, so an incompatible version merely *present* in this scratch
    # GEM_HOME defeats the pin. The sweep therefore runs on every call, not only
    # on the one that installs: the GEM_HOME is shared by every recipe in the
    # run, so a later recipe with an unpinned test_dep can drag a newer version
    # back in behind this one's back. Measured: puma pins minitest to the 5.x
    # line, byebug's unpinned `minitest` reinstalled 6.0.6 afterwards, and puma's
    # suite then died on `require "minitest/mock"` -- a load error that looks
    # nothing like the shared-environment problem it actually was.
    installed_versions(name).reject { |installed| requirement.satisfied_by?(installed) }.each do |installed|
      run("gem", "uninstall", name, "--version", installed.to_s, "--force",
          "--install-dir", gem_home, env: gem_env, timeout: BUILD_TIMEOUT)
    end
    return if installed_versions(name).any? { |installed| requirement.satisfied_by?(installed) }
  else
    return if gem_installed?(name)
  end

  step "installing test dependency #{name} (no RUBYCC)"
  cached = cached_gem_path(name, version)
  args = ["gem", "install", cached || name]
  args.concat(["--version", version]) if version && !cached
  args << "--local" if cached
  args << "--ignore-dependencies" if cached
  run!(*args, "--install-dir", gem_home, "--no-document", env: gem_env)
end

# The lib/ of an installed dependency, for recipes that put it on the load path
# explicitly instead of relying on RubyGems' require fallback.
def dep_lib_dir(name)
  version = installed_versions(name).last
  abort "#{name} is not installed in #{gem_home}; it must be listed in test_deps" unless version

  dir = File.join(gem_home, "gems", "#{name}-#{version}", "lib")
  abort "#{name} #{version} has no lib/ in #{gem_home}" unless File.directory?(dir)

  dir
end

# --- step 2/3: install through rubycc and prove it ---------------------------

def installed_gem_dir(name, version)
  File.join(gem_home, "gems", "#{name}-#{version}")
end

# Remove any previous copy so the transcripts inspected below are this run's.
def uninstall_gem(name, version)
  return unless gem_installed?(name, version)

  run("gem", "uninstall", name, "--version", version, "--executables", "--force",
      "--install-dir", gem_home, env: gem_env, timeout: BUILD_TIMEOUT)
end

def install_through_rubycc(name, version)
  uninstall_gem(name, version)
  step "RUBYCC=1 gem install #{name} #{version}"
  args = install_args(name, version, RECIPES.fetch(name))
  out, ok = run(*args, env: gem_env.merge("RUBYCC" => "1"), timeout: BUILD_TIMEOUT)
  [out, ok]
end

# The --control counterpart: same command line (install_args), same scratch-home
# machinery (gem_home already points at gemhome-control -- see $control_mode),
# but no rubycc gem is ever built or installed here (install_rubycc! is only
# called for the rubycc path -- see the bottom of the file), so there is no
# rubygems_plugin.rb in this GEM_HOME to route the build anywhere but the host's
# own cc/make. RUBYCC=0 on top of that is redundant insurance, not what does the
# work.
def install_through_control(name, version)
  uninstall_gem(name, version)
  step "gem install #{name} #{version} (control: host cc)"
  args = install_args(name, version, RECIPES.fetch(name))
  out, ok = run(*args, env: gem_env, timeout: BUILD_TIMEOUT)
  [out, ok]
end

# The evidence that the extension really was compiled by rubycc, read back from
# what the build left on disk:
#   * gem_make.out records every command RubyGems ran, so its $(MAKE) line names
#     rubycc's exe/rmake -- and rmake always substitutes rubycc for $(CC);
#   * the generated Makefile (kept in the installed gem's ext dir) has
#     `CC = <...>/exe/rubycc`, written by the mkmf shim;
#   * mkmf.log, when the extconf ran any probe at all, names exe/rubycc too
#     (redcarpet's extconf has no probes and writes no mkmf.log -- measured).
# The first two are required; mkmf.log is reported when present.
#
# google-protobuf's gemspec lists two extensions in the *same* ext directory
# (ext/google/protobuf_c/extconf.rb, then ext/google/protobuf_c/Rakefile), and
# RubyGems writes both builds' transcript to the one gem_make.out that
# directory gets -- so the second (a Rakefile that only orchestrates the
# optional FFI variant, not a C compile) overwrites the first's rmake trace on
# disk even though `gem install -V` shows rmake genuinely ran (measured).
# recipe[:multi_extension_overwrites_gem_make_out] is the opt-in for that one
# known case: the gem_make.out check is skipped rather than weakened for
# every recipe, and the Makefile check below -- still required -- is what
# carries the proof instead.
RUBYCC_RMAKE_RE = %r{gems/rubycc-[^/]+/exe/rmake}
RUBYCC_CC_RE = %r{gems/rubycc-[^/]+/exe/rubycc}

def rubycc_build_evidence(name, version, recipe)
  found = []
  missing = []

  make_outs = Dir.glob(File.join(gem_home, "extensions", "*", "*", "#{name}-#{version}", "gem_make.out"))
  if make_outs.any? { |f| File.read(f).match?(RUBYCC_RMAKE_RE) }
    found << "gem_make.out:rmake"
  elsif recipe[:multi_extension_overwrites_gem_make_out]
    found << "gem_make.out:rmake (skipped -- overwritten by a later extension, see recipe)"
  else
    missing << "gem_make.out naming rubycc's exe/rmake as $(MAKE)"
  end

  makefiles = Dir.glob(File.join(installed_gem_dir(name, version), "**", "Makefile"))
  if makefiles.any? { |f| File.readlines(f).grep(/\ACC\s*=/).any? { |l| l.match?(RUBYCC_CC_RE) } }
    found << "Makefile:CC=rubycc"
  else
    missing << "a generated Makefile with CC = <rubycc>"
  end

  mkmf_logs = Dir.glob(File.join(gem_home, "extensions", "*", "*", "#{name}-#{version}", "mkmf.log")) +
              Dir.glob(File.join(installed_gem_dir(name, version), "**", "mkmf.log"))
  found << "mkmf.log:rubycc" if mkmf_logs.any? { |f| File.read(f).match?(RUBYCC_CC_RE) }

  [found, missing]
end

# The --control mirror of the check above: instead of demanding rubycc's
# fingerprints, it demands their *absence*. A control run that quietly went
# through rubycc anyway (a stray rubycc gem left over in gemhome-control from
# an earlier bug, say) would make the comparison this flag exists for
# meaningless, and nothing about the gem's own test output would say so -- the
# suite would just look like it "passed under gcc" when it never ran under gcc
# at all. Same three transcripts as rubycc_build_evidence, same regexes, the
# opposite verdict.
def control_build_evidence(name, version)
  traces = []

  make_outs = Dir.glob(File.join(gem_home, "extensions", "*", "*", "#{name}-#{version}", "gem_make.out"))
  traces << "gem_make.out names rubycc's exe/rmake as $(MAKE)" if
    make_outs.any? { |f| File.read(f).match?(RUBYCC_RMAKE_RE) }

  makefiles = Dir.glob(File.join(installed_gem_dir(name, version), "**", "Makefile"))
  traces << "a generated Makefile has CC = <rubycc>" if
    makefiles.any? { |f| File.readlines(f).grep(/\ACC\s*=/).any? { |l| l.match?(RUBYCC_CC_RE) } }

  mkmf_logs = Dir.glob(File.join(gem_home, "extensions", "*", "*", "#{name}-#{version}", "mkmf.log")) +
              Dir.glob(File.join(installed_gem_dir(name, version), "**", "mkmf.log"))
  traces << "mkmf.log names rubycc" if mkmf_logs.any? { |f| File.read(f).match?(RUBYCC_CC_RE) }

  traces
end

# --- step 4/5: upstream source and .so injection -----------------------------

def source_dir(name, version)
  File.join(WORK_DIR, "src", "#{name}-#{version}")
end

def fetch_source(name, recipe)
  version = recipe.fetch(:version)
  dir = source_dir(name, version)
  sentinel = File.join(dir, ".verify_fetched")
  if File.exist?(sentinel)
    step "reusing upstream #{name} #{version} at #{dir}"
    return dir
  end

  step "fetching upstream #{name} #{version}"
  tarball = File.join(WORK_DIR, "#{name}-#{version}-src.tar.gz")
  download(recipe.fetch(:tarball), tarball)

  FileUtils.rm_rf(dir)
  FileUtils.mkdir_p(dir)
  run!("tar", "xzf", tarball, "--strip-components=1", "-C", dir)
  FileUtils.touch(sentinel)
  dir
end

# Copy the installed gem's build products into the upstream tree. Returns the
# absolute paths of the injected .so files (the sanity check needs them).
def inject_build_products(name, recipe, src_dir)
  version = recipe.fetch(:version)
  installed = installed_gem_dir(name, version)
  injected = []

  recipe.fetch(:sos).each do |from, to|
    source = File.join(installed, from)
    abort "#{name}: the install produced no #{from}" unless File.file?(source)

    dest = File.join(src_dir, to)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(source, dest)
    injected << File.realpath(dest)
  end

  recipe.fetch(:extra_copies, {}).each do |from, to|
    source = File.join(installed, from)
    abort "#{name}: the installed gem has no #{from} (extra_copies)" unless File.file?(source)

    dest = File.join(src_dir, to)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(source, dest)
  end

  step "injected #{injected.size} .so + #{recipe.fetch(:extra_copies, {}).size} generated file(s) into #{src_dir}"
  injected
end

# --- step 3.5 (optional): reproduce generated sources -------------------------
#
# A handful of gems' suites need something the packaged .gem carries but the
# upstream *source* tarball does not -- files a release-time tool (protoc, for
# google-protobuf) would have generated. Recipe field `generate` is the list
# of external commands that reproduce them; this is deliberately separate from
# `extra_copies`, which only ever moves a file that already exists somewhere
# (the installed gem). No shell is involved: each step is an argv array run
# directly, and the one place upstream's own Rakefile would use a shell `for`
# loop (protoc once per test .proto, whose names are not known until the
# tarball is unpacked) is expressed as `glob:` + a :file placeholder instead.

# The external tool(s) a recipe's `generate` steps need, deduplicated. Reading
# this before running anything means a recipe with a missing tool fails with
# one clear line instead of a protoc-shaped hole three steps further down
# turning into a baffling test failure.
def required_generate_tools(recipe)
  Array(recipe[:generate]).map { |g| g.fetch(:argv).first }.uniq
end

# A minimal, dependency-free PATH search -- this tool has no other reason to
# probe for an external command's presence, so it does not lean on a gem for
# the one line `which` would give it.
def find_on_path(cmd)
  return cmd if cmd.include?("/") && File.executable?(cmd) && !File.directory?(cmd)

  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
    candidate = File.join(dir, cmd)
    return candidate if File.executable?(candidate) && !File.directory?(candidate)
  end
  nil
end

def ensure_generate_tools!(name, recipe)
  missing = required_generate_tools(recipe).reject { |cmd| find_on_path(cmd) }
  return if missing.empty?

  abort "#{name}: the generate step needs #{missing.join(', ')} on PATH, but " \
        "#{missing.one? ? 'it was' : 'they were'} not found. Install " \
        "#{missing.join(', ')} and re-run."
end

# Runs every `generate` step against the just-fetched source tree, in order.
# Each step is either a literal argv (run once) or a `glob:` step (run once
# per file the glob matches inside `chdir`, with the symbol :file in argv
# replaced by that file's path). Every command is a hard precondition -- a
# generator that fails leaves the tree in a state the suite cannot honestly
# run against, so this aborts the whole tool rather than reporting a per-gem
# failure (mirrors run! elsewhere in this file).
#
# Idempotent by construction: `mkdir -p` tolerates re-runs, and protoc (or any
# similar generator) simply overwrites its own prior output, so re-verifying a
# gem whose work dir was kept from an earlier run regenerates the same files.
def run_generate_steps(name, recipe, src_dir)
  steps = Array(recipe[:generate])
  return if steps.empty?

  ensure_generate_tools!(name, recipe)

  steps.each do |gen|
    chdir = gen[:chdir] ? File.join(src_dir, gen[:chdir]) : src_dir
    argv_list =
      if gen[:glob]
        matches = Dir.glob(gen.fetch(:glob), base: chdir).sort
        abort "#{name}: generate glob #{gen.fetch(:glob).inspect} matched no files in #{chdir}" if matches.empty?

        matches.map { |file| gen.fetch(:argv).map { |token| token == :file ? file : token } }
      else
        [gen.fetch(:argv)]
      end

    argv_list.each do |argv|
      step "generate (#{name}): #{argv.join(' ')} (in #{gen[:chdir] || '.'})"
      run!(*argv, chdir: chdir)
    end
  end
end

# extra_copies' counterpart for what `generate` just produced: same { from =>
# to } shape, but `from` is resolved against the source tree itself (where the
# generator wrote it) rather than the installed gem. Kept as a distinct field
# instead of overloading extra_copies so a reader never has to work out which
# root a given `from` is relative to.
def copy_generated_files(name, recipe, src_dir)
  recipe.fetch(:generated_copies, {}).each do |from, to|
    source = File.join(src_dir, from)
    abort "#{name}: generate step produced no #{from} (generated_copies)" unless File.file?(source)

    dest = File.join(src_dir, to)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(source, dest)
  end
end

# --- step 6: sanity ----------------------------------------------------------

# A recipe with no sanity expression is refused rather than run: without it a
# suite that silently loaded a pure-Ruby fallback (or the interpreter's own copy
# of a default gem) would be recorded as "rubycc-verified", which is a lie the
# database must never contain. This is the tool's single most important gate.
def verify_recipe!(name, recipe)
  sanity = recipe[:sanity]
  abort "#{name}: recipe has no :sanity expression -- refusing to run (see verify_recipe!)" if sanity.nil?
  abort "#{name}: :sanity needs an :expr" if sanity[:expr].to_s.strip.empty?
  abort "#{name}: :sanity needs :requires" if Array(sanity[:requires]).empty?
  abort "#{name}: unknown runner #{recipe[:runner].inspect}" unless
    %i[test_unit rspec ruby_files].include?(recipe[:runner])
  Array(recipe[:generate]).each do |gen|
    abort "#{name}: a generate step needs :argv" if Array(gen[:argv]).empty?
  end
end

# Child-process script: require the gem the ordinary way, then check both that
# every injected .so is in $LOADED_FEATURES (proving *this* build is what got
# loaded, not another copy on the load path) and the recipe's own expression
# (proving a pure-Ruby fallback did not win). Both must hold.
SANITY_SCRIPT = <<~'RUBY'
  injected = ARGV.map { |p| File.realpath(p) }
  requires = ENV.fetch("VERIFY_REQUIRES").split(",")
  expr_src = ENV.fetch("VERIFY_EXPR")

  def loaded_paths
    $LOADED_FEATURES.map { |f| File.realpath(f) rescue f }
  end

  requires.each { |feature| require feature }

  missing = injected - loaded_paths
  unless missing.empty?
    warn "the injected extension was not loaded: #{missing.join(', ')}"
    warn "loaded .so files were:\n  #{loaded_paths.grep(/\.so\z/).join("\n  ")}"
    exit 1
  end

  # Recipes whose gem has no observable "C vs fallback" switch use this as their
  # expression; the check it names was already performed above.
  def injected_so_loaded?
    true
  end

  result = eval(expr_src) # rubocop:disable Security/Eval -- the expression comes from RECIPES
  unless result
    warn "sanity expression #{expr_src.inspect} evaluated to #{result.inspect}"
    exit 1
  end
  puts "sanity ok"
RUBY

def check_sanity(name, recipe, src_dir, injected, extra_load_paths)
  sanity = recipe.fetch(:sanity)
  cmd = [RbConfig.ruby, *load_path_flags(recipe, extra_load_paths), "-e", SANITY_SCRIPT, "--", *injected]
  env = gem_env.merge(
    "VERIFY_REQUIRES" => Array(sanity.fetch(:requires)).join(","),
    "VERIFY_EXPR" => sanity.fetch(:expr)
  )
  step "sanity check for #{name}: #{sanity.fetch(:expr)}"
  out, ok = run(*cmd, chdir: src_dir, env: env, timeout: BUILD_TIMEOUT)
  [ok, out]
end

# --- step 7: the suite -------------------------------------------------------

def load_path_flags(recipe, extra_load_paths)
  (Array(recipe[:load_paths]) + extra_load_paths).map { |p| "-I#{p}" }
end

def suite_files(recipe, src_dir)
  files = Dir.chdir(src_dir) { Dir.glob(recipe.fetch(:test_glob)).sort }
  Array(recipe[:exclude]).each do |pattern|
    excluded = Dir.chdir(src_dir) { Dir.glob(pattern) }
    files -= excluded
  end
  files
end

# The three runner shapes:
#   :test_unit  -- one ruby child that requires every suite file; the framework's
#                  own at_exit runner prints the summary, which must then be in
#                  the test-unit/minitest shape ("N tests|runs, ...").
#   :ruby_files -- the same child, but the summary may be in either shape, for a
#                  suite that picks its framework at run time. No recipe needs
#                  this today; it exists so a suite whose framework is not known
#                  in advance is reported honestly instead of being mis-parsed.
#   :rspec      -- the rspec binstub from the scratch GEM_HOME with an explicit
#                  file list (no reliance on rspec's default path or .rspec).
# The difference is deliberately in what each accepts as a summary: a runner that
# accepted any shape could read an unrelated line as the result.
def run_suite(name, recipe, src_dir, extra_load_paths)
  files = suite_files(recipe, src_dir)
  abort "#{name}: test_glob #{recipe.fetch(:test_glob).inspect} matched no files in #{src_dir}" if files.empty?

  flags = load_path_flags(recipe, extra_load_paths)
  requires = Array(recipe[:require_flags]).map { |f| "-r#{f}" }
  runner_args = Array(recipe[:runner_args])
  # ruby keeps parsing its own options past `-e SCRIPT`, so a bare --ignore-name
  # would be rejected by the interpreter before the suite ever saw it; `--` ends
  # that parsing and puts the rest in the child's ARGV, where test-unit's
  # autorunner reads its options from. Only added when there is something to pass.
  ruby_runner_args = runner_args.empty? ? [] : ["--", *runner_args]

  cmd =
    case recipe.fetch(:runner)
    when :rspec
      rspec = File.join(gem_home, "bin", "rspec")
      abort "#{name}: rspec is not installed in #{gem_home}" unless File.executable?(rspec)

      [rspec, *flags, "--no-color", *runner_args, *files]
    when :test_unit, :ruby_files
      loader = files.map { |f| "require #{File.join(src_dir, f).dump}" }.join("\n")
      [RbConfig.ruby, *flags, *requires, "-e", loader, *ruby_runner_args]
    end

  step "running #{name}'s suite (#{files.size} files, runner #{recipe.fetch(:runner)})"
  suite_env = gem_env.dup
  if recipe[:bundle_gemfile] == :empty
    empty_gemfile = File.join(src_dir, ".rubycc-empty-Gemfile")
    gems = Array(recipe[:bundle_gems])
    contents = "source \"https://rubygems.org\"\n" \
               "#{gems.map { |gem| %(gem \"#{gem}\") }.join("\n")}\n"
    File.write(empty_gemfile, contents)
    suite_env["BUNDLE_GEMFILE"] = empty_gemfile
  end
  child_load_paths = Array(recipe[:child_load_paths]).map { |path| File.expand_path(path, src_dir) }
  suite_env["RUBYLIB"] = (child_load_paths + extra_load_paths).join(File::PATH_SEPARATOR) unless child_load_paths.empty?
  out, ok = run(*cmd, chdir: src_dir, env: suite_env)
  [out, ok, files.size]
end

# --- summary parsing ---------------------------------------------------------
#
# Every regex here was written against output captured from these six suites on
# this machine, not from documentation:
#
#   test-unit  "136 tests, 206 assertions, 0 failures, 0 errors, 0 pendings,
#               0 omissions, 0 notifications"
#   minitest   "N runs, M assertions, F failures, E errors, S skips"
#   rspec      "455 examples, 0 failures, 1 pending"
#
# The rate line test-unit prints right after ("281.05 tests/s, 425.70
# assertions/s") deliberately does not match: the count must be an integer and
# the unit word must be followed by a comma, not "/s".
SUMMARY_LINE_RE = /^\s*\d+\s+(?:tests|runs|examples),/
COUNT_RE = /(\d+)\s+([a-z]+)/

# Labels normalised across frameworks. rspec says "1 pending" where test-unit
# says "0 pendings", so every label is pluralised before use. "Other" counts
# never make a run fail, but they are recorded whenever non-zero.
TOTAL_LABELS = %w[tests runs examples].freeze
OTHER_LABELS = %w[skips pendings omissions notifications].freeze
# Which total a runner's summary must report; a summary of the wrong shape is not
# this runner's result and is reported as unparsable rather than believed.
RUNNER_TOTALS = { test_unit: %w[tests runs], rspec: %w[examples], ruby_files: TOTAL_LABELS }.freeze

def pluralise(label)
  label.end_with?("s") ? label : "#{label}s"
end

def parse_summary(output, runner)
  line = output.lines.reverse.find { |l| l.match?(SUMMARY_LINE_RE) }
  return nil unless line

  counts = {}
  line.scan(COUNT_RE) { |value, label| counts[pluralise(label)] = Integer(value) }

  expected = RUNNER_TOTALS.fetch(runner)
  total_label = expected.find { |l| counts.key?(l) }
  return nil unless total_label

  {
    line: line.strip,
    tests: counts[total_label],
    assertions: counts["assertions"],
    failures: counts["failures"] || 0,
    errors: counts["errors"] || 0,
    other: OTHER_LABELS.filter_map { |l| [l, counts[l]] if counts[l].to_i.positive? }.to_h
  }
end

# --- one gem end to end ------------------------------------------------------

def verify_gem(name, recipe)
  version = recipe.fetch(:version)
  result = { name: name, version: version, runner: recipe.fetch(:runner),
             status: nil, reason: nil, summary: nil, sanity: nil, evidence: [], output: nil }

  install_out, install_ok =
    $control_mode ? install_through_control(name, version) : install_through_rubycc(name, version)
  unless install_ok
    result[:status] = :fail
    result[:reason] = "gem install failed"
    result[:output] = install_out
    return result
  end

  if $control_mode
    traces = control_build_evidence(name, version)
    result[:evidence] = traces.empty? ? ["no rubycc traces (host cc)"] : []
    unless traces.empty?
      # The install "succeeded" but is not the control it claims to be -- a
      # silent rubycc build here would make the whole comparison meaningless,
      # so it is a failure rather than a pass with a caveat.
      result[:status] = :fail
      result[:reason] = "not a control run: found rubycc traces: #{traces.join('; ')}"
      return result
    end
  else
    found, missing = rubycc_build_evidence(name, version, recipe)
    result[:evidence] = found
    unless missing.empty?
      # The install "succeeded" but not through rubycc -- recording that as verified
      # would be the same lie the sanity check guards against, so it is a failure.
      result[:status] = :fail
      result[:reason] = "no proof the build used rubycc: missing #{missing.join('; ')}"
      return result
    end
  end

  test_dep_versions = recipe.fetch(:test_dep_versions, {})
  Array(recipe[:test_deps]).each { |dep| ensure_test_dep(dep, test_dep_versions[dep]) }
  extra_load_paths = Array(recipe[:dep_load_paths]).map { |dep| dep_lib_dir(dep) }

  src_dir = fetch_source(name, recipe)
  run_generate_steps(name, recipe, src_dir)
  copy_generated_files(name, recipe, src_dir)
  injected = inject_build_products(name, recipe, src_dir)

  sanity_ok, sanity_out = check_sanity(name, recipe, src_dir, injected, extra_load_paths)
  result[:sanity] = sanity_ok
  unless sanity_ok
    # Do not run the suite: a suite that passes without the extension loaded is
    # exactly the false evidence this tool exists to prevent.
    result[:status] = :fail
    result[:reason] = "sanity check failed (suite not run)"
    result[:output] = sanity_out
    return result
  end

  out, exit_ok, file_count = run_suite(name, recipe, src_dir, extra_load_paths)
  result[:files] = file_count
  result[:output] = out
  summary = parse_summary(out, recipe.fetch(:runner))

  if summary.nil?
    # Never call this a pass on the strength of the exit status alone, and never
    # call it a failure either: the honest report is that the output could not be
    # read.
    result[:status] = :unparsable
    result[:reason] = "no #{recipe.fetch(:runner)} summary line found " \
                      "(child exited #{exit_ok ? 'successfully' : 'non-zero'})"
    return result
  end

  result[:summary] = summary
  if !summary[:failures].zero? || !summary[:errors].zero?
    result[:status] = :fail
    result[:reason] = "#{summary[:failures]} failures / #{summary[:errors]} errors"
  elsif !exit_ok
    # A clean summary from a child that still exited non-zero means something
    # outside the framework's accounting went wrong (a crash on the way out, an
    # explicit abort). Believing the summary over the exit status here would
    # record a verification the run did not actually earn.
    result[:status] = :fail
    result[:reason] = "summary reports no failures but the child exited non-zero"
  else
    result[:status] = :pass
  end
  result
end

# --- reporting ---------------------------------------------------------------

def print_table(title, headers, rows)
  puts
  puts title
  if rows.empty?
    puts "  (none)"
    return
  end

  widths = headers.each_with_index.map { |h, i| ([h] + rows.map { |r| r[i].to_s }).map(&:length).max }
  puts "  " + headers.each_with_index.map { |h, i| h.ljust(widths[i]) }.join(" | ")
  puts "  " + widths.map { |w| "-" * w }.join("-+-")
  rows.each { |row| puts "  " + row.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join(" | ") }
end

def humanize(number)
  return "—" if number.nil?

  number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end

# "11 omissions" / "1 pending" -- the labels are stored pluralised (frameworks
# disagree), so the singular is restored for a count of one.
def count_phrase(label, count)
  "#{count} #{count == 1 ? label.sub(/s\z/, '') : label}"
end

def other_counts(summary)
  return "—" if summary.nil? || summary[:other].empty?

  summary[:other].map { |label, count| count_phrase(label, count) }.join(", ")
end

def verdict(result)
  case result[:status]
  when :pass then "PASS"
  when :unparsable then "UNPARSABLE"
  else "FAIL"
  end
end

def report(results)
  puts "=" * 100
  puts "gem test-suite verification against rubycc-built extensions"
  puts "  mode      : #{$control_mode ? 'CONTROL (host cc, not rubycc)' : 'rubycc'}"
  puts "  work dir  : #{WORK_DIR}"
  puts "  gem home  : #{gem_home}"
  puts "  ruby      : #{RUBY_DESCRIPTION}"
  puts "  run at    : #{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}"
  puts "=" * 100

  print_table(
    "[1] results",
    ["gem", "version", "sanity", "runner", "files", "tests", "assertions", "failures", "errors",
     "other", "verdict"],
    results.map do |r|
      s = r[:summary]
      [r[:name], r[:version], r[:sanity].nil? ? "—" : (r[:sanity] ? "ok" : "FAILED"), r[:runner],
       r[:files] || "—", humanize(s && s[:tests]), humanize(s && s[:assertions]),
       humanize(s && s[:failures]), humanize(s && s[:errors]),
       other_counts(s), verdict(r)]
    end
  )

  print_table(
    $control_mode ? "[2] control build evidence (absence of rubycc)" : "[2] rubycc build evidence",
    %w[gem evidence],
    results.map { |r| [r[:name], r[:evidence].empty? ? "—" : r[:evidence].join(", ")] }
  )

  problems = results.reject { |r| r[:status] == :pass }
  unless problems.empty?
    puts
    puts "[3] problems"
    problems.each do |r|
      puts "  #{r[:name]} #{r[:version]}: #{verdict(r)} -- #{r[:reason]}"
      r[:output].to_s.lines.last(12).each { |l| puts "      #{l.chomp}" }
    end
  end

  passes = results.count { |r| r[:status] == :pass }
  mode_tag = $control_mode ? " (control: host cc)" : ""
  puts
  puts "-" * 100
  puts "summary: #{passes}/#{results.size} PASS#{mode_tag}"
  results.each do |r|
    s = r[:summary]
    detail = s ? s[:line] : (r[:reason] || "")
    puts "  #{verdict(r).ljust(10)} #{r[:name]} #{r[:version]}  #{detail}"
  end
  puts "-" * 100
end

# --- database update ---------------------------------------------------------

ENTRY_KEY_ORDER = %w[verifications notes].freeze
VERIFICATION_KEY_ORDER = %w[versions environment verified_at evidence].freeze

# data/verified_gems.json's exact house style: two-space indent, one key per
# line, and `versions` as a single-line inline array. JSON.pretty_generate would
# explode every array over three lines and rewrite every existing entry, so the
# file gets its own tiny emitter instead. The nesting is fixed (entry ->
# verifications -> record), so the indentation is hard-coded per level rather
# than made generic.
def emit_database(db)
  entries = db.map do |name, attrs|
    fields = ENTRY_KEY_ORDER.map do |key|
      rendered = key == "verifications" ? emit_verifications(Array(attrs[key])) : JSON.generate(attrs[key])
      "    #{JSON.generate(key)}: #{rendered}"
    end
    "  #{JSON.generate(name)}: {\n#{fields.join(",\n")}\n  }"
  end
  "{\n#{entries.join(",\n")}\n}\n"
end

# The `verifications` array of one entry, one record per brace block.
def emit_verifications(records)
  blocks = records.map do |record|
    fields = VERIFICATION_KEY_ORDER.map do |key|
      value = record[key]
      rendered =
        if key == "versions"
          "[#{Array(value).map { |v| JSON.generate(v) }.join(', ')}]"
        else
          JSON.generate(value)
        end
      "        #{JSON.generate(key)}: #{rendered}"
    end
    "      {\n#{fields.join(",\n")}\n      }"
  end
  "[\n#{blocks.join(",\n")}\n    ]"
end

# "glibc x86_64 / ruby 3.4.5" -- the shape the existing entries use. The libc is
# read from RbConfig's arch triplet, which is how MRI itself distinguishes a musl
# build ("x86_64-linux-musl") from a glibc one ("x86_64-linux").
def environment_string
  arch = RbConfig::CONFIG["arch"].to_s
  libc =
    if arch.include?("musl") then "musl"
    elsif arch.include?("linux") then "glibc"
    else arch.split("-").last
    end
  "#{libc} #{RbConfig::CONFIG['host_cpu']} / ruby #{RUBY_VERSION}"
end

def suite_label(runner)
  runner == :rspec ? "RSpec suite" : "test/unit suite"
end

def evidence_counts(result)
  summary = result.fetch(:summary)
  if result[:runner] == :rspec
    "#{humanize(summary[:tests])} examples / #{humanize(summary[:failures])} failures"
  else
    "#{humanize(summary[:tests])} tests / #{humanize(summary[:assertions])} assertions / " \
      "#{humanize(summary[:failures])} failures / #{humanize(summary[:errors])} errors"
  end
end

# An existing verification record's evidence is *appended to*, never replaced.
# (A record for an environment that has none yet starts from scratch instead:
# see update_database.) It accumulates the history of every step that confirmed
# the gem in that environment (json's names Steps 54, 61 and 64; msgpack's gained
# an H4 sentence in Step 138), and a run of this tool proves what it measured
# today -- not that the earlier confirmations never happened.
# Overwriting would silently destroy the part of the record no rerun can recover.
def evidence_string(result, step_number, existing = nil)
  counts = evidence_counts(result)
  if existing && !existing.empty?
    "#{existing.rstrip} Re-verified with tools/verify_gem_tests.rb (Step #{step_number}): " \
      "the gem's own #{suite_label(result[:runner])} passed #{counts}."
  else
    sos = RECIPES.fetch(result[:name]).fetch(:sos).keys.map { |p| File.basename(p) }.join(" + ")
    "RUBYCC=1 gem install #{result[:name]} succeeded (#{sos} built through rmake); " \
      "the gem's own #{suite_label(result[:runner])} passed #{counts} (Step #{step_number})."
  end
end

# Facts about non-failing-but-non-zero outcomes. These are measurements, so the
# tool owns them; everything else in `notes` is a human's job (see below).
def extras_sentence(summary)
  return nil if summary[:other].empty?

  parts = summary[:other].map { |label, count| count_phrase(label, count) }
  "The run reported #{parts.join(', ')} (not failures)."
end

# Whether existing prose already states this count, so the automatic sentence is
# not appended on top of a human's better wording (bigdecimal's "11 tests are
# omitted because ..." is the case that matters).
def mentions_extra?(notes, label, count)
  stem = label.sub(/s\z/, "").sub(/\Aomission\z/, "omi")
  notes.match?(/#{count}[^.]{0,60}#{Regexp.escape(stem)}/i)
end

def update_notes(existing, summary, cli_notes, new_entry)
  notes = existing
  if new_entry
    # The default is empty rather than a "not yet verified on X" caveat: an
    # environment with no verification record already says exactly that, and
    # repeating it in prose only creates a second copy that goes stale.
    notes = cli_notes || ""
    if cli_notes.nil?
      warn "NOTE: #{'-' * 60}"
      warn "NOTE: a new entry got the default notes. `notes` is the human's " \
           "responsibility: any caveat a machine cannot observe (a manual step, " \
           "a flag the build needed, a platform not covered) must be written in by hand."
    end
  end

  sentence = extras_sentence(summary)
  if sentence && !summary[:other].keys.all? { |label| mentions_extra?(notes, label, summary[:other][label]) }
    notes = notes.to_s.empty? ? sentence : "#{notes} #{sentence}"
  end
  notes
end

def update_database(results, path, step_number, cli_notes)
  passes = results.select { |r| r[:status] == :pass }
  if passes.empty?
    warn "nothing to record: no gem passed"
    return
  end

  db = JSON.parse(File.read(path))
  today = Time.now.strftime("%Y-%m-%d")

  environment = environment_string

  passes.each do |result|
    name = result[:name]
    existing = db[name]
    entry = existing ? existing.dup : {}
    verifications = Array(entry["verifications"]).map(&:dup)
    # A run only ever speaks for the environment it ran in, so it updates the
    # record for that environment and leaves every other one untouched.
    record = verifications.find { |v| v["environment"] == environment }

    if record
      record["versions"] = Array(record["versions"]) | [result[:version]]
      record["verified_at"] = today
      # Appended, not replaced: see evidence_string.
      record["evidence"] = evidence_string(result, step_number, record["evidence"].to_s)
      how = "updated #{environment}"
    else
      # First time in this environment. The evidence starts fresh -- carrying
      # over another environment's evidence would claim its measurements were
      # made here, which they were not.
      record = {
        "versions" => [result[:version]],
        "environment" => environment,
        "verified_at" => today,
        "evidence" => evidence_string(result, step_number, nil)
      }
      verifications << record
      how = existing ? "new environment #{environment}" : "new entry"
    end
    entry["verifications"] = verifications

    if existing && cli_notes
      warn "#{name}: --notes ignored -- an existing entry keeps its notes " \
           "(they may hold caveats no measurement can rediscover)"
    end
    entry["notes"] = update_notes(entry["notes"].to_s, result.fetch(:summary), cli_notes, existing.nil?)
    db[name] = entry
    puts "recorded #{name} #{result[:version]} (#{how})"
  end

  File.write(path, emit_database(db))
  puts "wrote #{path}"
  check_doctor_allowlist(db)
end

# test/test_doctor.rb pins the exact set of gems the database may contain. That
# gate is deliberate -- adding a gem must be a conscious edit -- so the tool only
# prints the replacement line and never edits the test.
DOCTOR_TEST = File.join(RUBYCC_ROOT, "test/test_doctor.rb")
# `\s*` rather than a literal space: the list outgrew one line at 12 gems and had
# to be wrapped, and a regex that only matched the one-line form would silently
# stop finding the gate exactly when the gate started mattering most.
ALLOWLIST_RE = /assert_equal %w\[([^\]]*)\],\s*raw\.keys\.sort/

# The paste-ready assertion, wrapped inside %w[] so no line passes 120 columns.
# The continuation indent lines the names up under the first one, which is what
# the test file itself does.
def allowlist_lines(names, limit: 120)
  head = "    assert_equal %w["
  cont = " " * head.length
  lines = [head.dup]
  names.each do |name|
    lines << cont.dup if lines.last.length + 1 + name.length > limit && lines.last != head
    lines.last << (lines.last.end_with?("[", " ") ? "" : " ") << name
  end
  lines.last << "],"
  lines << "                 raw.keys.sort"
end

def check_doctor_allowlist(db)
  return unless File.file?(DOCTOR_TEST)

  match = ALLOWLIST_RE.match(File.read(DOCTOR_TEST))
  unless match
    warn "could not find the allow-list assertion in #{DOCTOR_TEST}; check it by hand"
    return
  end

  allowed = match[1].split
  actual = db.keys.sort
  return if allowed == actual

  puts
  puts "ACTION REQUIRED: #{DOCTOR_TEST} still allows #{allowed.inspect}"
  puts "  the database now holds #{actual.inspect}."
  puts "  Update test_verified_gems_json_holds_only_confirmed_gems by hand with:"
  puts
  # Printed wrapped, because this is meant to be pasted as-is and the one-line
  # form outgrew the file's 120-column habit at 12 gems -- first the trailing
  # `raw.keys.sort`, then (at 14) the word list itself.
  puts allowlist_lines(actual)
  puts
  puts "  (this tool never edits the test: the allow-list is an intentional gate.)"
end

# --- main --------------------------------------------------------------------

# Read by gem_home and every install/evidence function below that has to tell
# the rubycc path from the control path apart. A CLI-parsed value rather than a
# parameter because both paths already share every function down to gem_home
# itself, and threading one more argument through all of them would be a much
# larger diff than this one flag deserves.
$control_mode = options[:control]

# Recording a control run as "verified" would defeat the reason this flag
# exists: the whole point is to compare the rubycc run against something that
# is deliberately *not* recorded, not to grow the database with host-cc runs.
abort "--control cannot be combined with --update" if options[:control] && options[:update]

if options[:list]
  print_table("recipes", %w[gem version runner sanity],
              RECIPES.map { |n, r| [n, r[:version], r[:runner], r.dig(:sanity, :expr)] })
  exit 0
end

selected = options[:all] ? RECIPES.keys : options[:gems]
if selected.empty?
  abort "no gems given. Pass gem names, or --all. Known: #{RECIPES.keys.join(', ')} (--help for usage)"
end

unknown = selected - RECIPES.keys
abort "no recipe for #{unknown.join(', ')} (known: #{RECIPES.keys.join(', ')})" unless unknown.empty?

# Validate every recipe before the first (slow) install, so a recipe missing its
# sanity gate stops the run instead of being discovered halfway through.
selected.each { |name| verify_recipe!(name, RECIPES.fetch(name)) }

abort "--step N is required with --update (it goes into the recorded evidence)" if
  options[:update] && options[:step].to_s.empty?
abort "--data #{options[:data]} does not exist" if options[:update] && !File.file?(options[:data])

step "verifying #{selected.join(', ')}#{$control_mode ? ' (control: host cc)' : ''}"
step "work dir: #{WORK_DIR} (kept and reused)"
FileUtils.mkdir_p(WORK_DIR)
# The control path never installs rubycc into its scratch GEM_HOME: rubycc
# itself is what is under test, and a control run exists precisely to show
# what happens without it.
install_rubycc! unless $control_mode

results = selected.map { |name| verify_gem(name, RECIPES.fetch(name)) }
report(results)

if options[:update]
  puts
  update_database(results, options[:data], options[:step], options[:notes])
end

exit(results.all? { |r| r[:status] == :pass } ? 0 : 1)
