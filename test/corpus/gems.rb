# frozen_string_literal: true

# Step 92 (M5 H3): curated corpus of Ruby gems whose C extensions are the input
# to `rake corpus:census`. This list is committed on purpose for reproducibility:
# re-running the census against the same names yields a comparable snapshot even
# as rubygems.org drifts. The initial members are the pure-C candidates named by
# docs/development/ROADMAP.md (§8, H3) and already exercised by tools/collect_mkmf_corpus.rb.
#
# Membership here is a *candidate* list, not a claim of R10 conformance. The real
# R10 gate (C++ usage / configure / mini_portile) is decided mechanically by
# test/corpus/census.rb, which excludes or warns per gem and records the reason
# in the generated report. Manual exclusions, if any, are commented with a reason.
#
# Each entry:
#   :name    — rubygems.org gem name (fetched with `gem fetch --platform=ruby`)
#   :version — pinned version string, or nil to fetch the latest release. Every
#              committed entry is pinned for reproducibility; nil stays
#              supported because it is convenient while adding a gem, but
#              leaving it in the committed list makes the census job fail on
#              upstream drift.
#   :note    — why this gem is in the corpus
#   :upstream_tests — false when the gem's upstream project ships no test suite
#                     at all, verified by inspecting the upstream repo/tag
#                     directly (not by "it fails to run here" or "no test
#                     environment is set up"). Defaults to true when absent.
#                     This is NOT a general-purpose exclusion switch: R10's
#                     "gem's own tests passed" evidence (verification level
#                     (d)) is impossible to obtain when no suite exists, so
#                     test/corpus/census.rb excludes such a gem from the R10
#                     denominator. A gem that has a suite but currently fails
#                     it for a reason nobody has measured, or one this project
#                     simply has not run yet, stays true and stays in the
#                     denominator.
#   :control_suite_passes — false when the gem's upstream suite does not pass
#                     with the *reference compiler* either. This is the second
#                     way (d)-level evidence becomes unobtainable, and it is a
#                     strictly stronger claim than "it fails here", so it may
#                     only be set from a measurement:
#
#                       ruby tools/verify_gem_tests.rb --control <gem>
#
#                     which repeats the entire verification with the host cc in
#                     place of rubycc, in a separate scratch GEM_HOME, and
#                     refuses to run if it finds any rubycc trace in the build.
#                     The measured control numbers belong in :note so the claim
#                     can be re-checked without re-deriving it.
#
#                     Setting this without that measurement is the failure mode
#                     the whole field exists to prevent: "the suite fails" and
#                     "the suite fails for reasons that have nothing to do with
#                     rubycc" look identical from the rubycc side alone, and
#                     nio4r is the standing counter-example -- it was recorded
#                     as environment-blocked with 44 failures and later passed
#                     with 0 after no rubycc change at all.
#
#                     Note what this does *not* license: a gem whose control run
#                     fails *differently* from its rubycc run is not covered.
#                     Differing numbers mean rubycc contributes failures of its
#                     own, which is a defect to chase, not a denominator to
#                     shrink.
#   :out_of_scope_dependency — a string naming a gem that `gem install`ing this
#                     one requires, and that DESIGN R10 already puts out of
#                     scope, together with the basis. This is not a new
#                     exclusion rule: R10 excludes C++ extensions, and a gem
#                     that cannot be installed without building one is excluded
#                     by that same rule reaching one level further out.
#
#                     The census's own C++ gate only reads the gem's *own* ext
#                     sources, so it cannot see this -- thin's parser is pure C
#                     and passes the machine gate while `gem install thin` still
#                     stops on eventmachine's .cpp files (measured,
#                     docs/development/STEPS.md atomic-type-9). The dependency named here
#                     must already appear in docs/reference/OUT-OF-SCOPE-GEMS.md with its
#                     basis, so this field points at a decision rather than
#                     making one.
#   :r10_profile — an explicit DESIGN-compatible install path when the raw
#                  extconf contains an unselected configure/mini_portile branch.
#                  It is required to be one of the profiles understood by
#                  census.rb; unknown profiles fail closed and remain excluded.
#                  The profile is part of the R10 identity and is recorded in
#                  the generated census and R10 candidate artifact. It is not
#                  itself an install or suite verification claim; a verification
#                  recipe must independently declare the same arguments before
#                  data/verified_gems.json can be updated.
#   :r10_extconf_args — exact arguments passed to extconf.rb for :r10_profile.
#                       An empty array means no extra argument. This is metadata,
#                       not a request to bypass the machine gate: census.rb checks
#                       both the arguments and the expected branch markers.
module Corpus
  module Gems
    LIST = [
      {
        name: "json",
        # Pinned to match tools/collect_mkmf_corpus.rb / tools/m2_acceptance.rb so
        # the census, the mkmf fixtures, and the M2 acceptance all describe the
        # same json build.
        version: "2.21.1",
        note: "Pure C parser/generator. SIMD paths are gated (JSON_DISABLE_SIMD); " \
              "census counts gated headers as gap candidates without judging the gate."
      },
      {
        name: "msgpack",
        version: "1.8.3", # Pinned to match the mkmf corpus.
        note: "Pure C packer/unpacker; single ext dir."
      },
      # These four were the last `version: nil` entries. They are pinned to the
      # versions data/verified_gems.json vouches for (Step 176), which are also
      # what `latest` already resolved to in the committed snapshot, so pinning
      # them changes the requested column and nothing else. Two reasons:
      # the census job fails on any diff, and with `latest` an upstream release
      # turns it red for a reason that is not rubycc's header coverage changing
      # (the only thing that job exists to catch); and a corpus that describes a
      # different version from the one the verification database vouches for
      # makes the two records disagree about what was measured.
      {
        name: "bigdecimal",
        version: "4.1.2",
        note: "Pure C arbitrary-precision decimal; default gem, widely depended on."
      },
      {
        name: "date",
        version: "3.5.1",
        note: "Pure C date/time core (ext/date); default gem."
      },
      {
        name: "racc",
        version: "1.8.1",
        note: "Pure C parser runtime (ext/racc/cparse); extconf.rb runs no probes."
      },
      {
        name: "redcarpet",
        version: "3.6.1",
        note: "Pure C Markdown renderer; extconf.rb runs no probes."
      },

      # Ruby 4.0.6 ships 46 default gems; 16 of them declare a non-empty
      # `extensions` in their gemspec (measured via
      # `Gem::Specification.default_stubs`). json and date are already above.
      # resolv is excluded (see the comment below) rather than added, so the
      # remaining 14 add 13 entries here. Default-gem C extensions are the
      # most basic corpus for R10's "build a gem with rubycc" goal: they ship
      # with every Ruby install and are exercised by the standard library
      # itself. Versions are pinned to the exact release bundled with Ruby
      # 4.0.6, matching the pinning rationale already used above: it fixes
      # the C source under test and keeps the census snapshot reproducible.
      #
      # Manual exclusion: resolv 0.7.0 is not added. Its only C extension is
      # ext/win32/resolv, which is Windows-only and is not built on Linux —
      # there is no C source to census on this platform.
      {
        name: "digest",
        version: "3.2.1",
        note: "Six extconf.rb in one gem (ext/digest plus bubblebabble, md5, " \
              "rmd160, sha1, sha2); first multi-ext gem in this corpus."
      },
      {
        name: "erb",
        version: "6.0.1.1",
        note: "Single ext dir (ext/erb/escape)."
      },
      {
        name: "etc",
        version: "1.4.6",
        note: "Single ext dir (ext/etc)."
      },
      {
        name: "fcntl",
        version: "1.3.0",
        upstream_tests: false,
        note: "Small single-file ext (ext/fcntl). Upstream ruby/fcntl carries no " \
              "test/ directory, no test task in its Rakefile, and no test step in " \
              "its CI (measured against v1.3.0 and master, docs/development/STEPS.md Step 157); " \
              "excluded from the R10 denominator because \"gem's own tests passed\" " \
              "evidence is impossible to obtain, not because rubycc fails it."
      },
      {
        name: "io-console",
        version: "0.8.2",
        note: "Single ext dir (ext/io/console)."
      },
      {
        name: "io-nonblock",
        version: "0.3.2",
        note: "Small single-file ext (ext/io/nonblock)."
      },
      {
        name: "io-wait",
        version: "0.4.0",
        note: "Small single-file ext (ext/io/wait)."
      },
      {
        name: "openssl",
        version: "4.0.2",
        note: "Depends on the system OpenSSL headers; DESIGN R10 names openssl " \
              "as an expected-in-scope system-library gem."
      },
      {
        name: "prism",
        version: "1.8.1",
        note: "Ruby's own parser; a large extension including generated C sources."
      },
      {
        name: "psych",
        version: "5.3.1",
        note: "Depends on the system libyaml; DESIGN R10 names psych as an " \
              "expected-in-scope system-library gem."
      },
      {
        name: "stringio",
        version: "3.2.0",
        note: "Single ext dir (ext/stringio)."
      },
      {
        name: "strscan",
        version: "3.1.6",
        note: "Single ext dir (ext/strscan)."
      },
      {
        name: "zlib",
        version: "3.2.3",
        note: "Depends on the system zlib headers; DESIGN R10 expects gems built " \
              "against a system library (e.g. sqlite3) to be in scope."
      },

      # Ruby 4.0.6 also ships bundled gems with C extensions. These are kept in
      # a separate group from the default gems above because they are not in
      # `Gem::Specification.default_stubs`; versions are pinned to the copies
      # shipped with Ruby 4.0.6. Windows-only win32ole is intentionally omitted.
      {
        name: "fiddle",
        version: "1.1.8",
        note: "Ruby 4.0 bundled gem; C extension backed by the system libffi " \
              "headers and library."
      },
      {
        name: "rbs",
        version: "3.10.0",
        note: "Ruby 4.0 bundled gem; pure C parser/type-signature extension."
      },
      {
        name: "syslog",
        version: "0.3.0",
        note: "Ruby 4.0 bundled gem; small pure C extension using the system " \
              "syslog API."
      },

      # rubygems.org's popular-gems corpus: all 100 gems on the first 10 pages
      # of https://rubygems.org/releases/popular were fetched (`.gem`, not just
      # the remote gemspec — `gem specification --remote <name> extensions`
      # always returns empty, because rubygems.org's quick index serves
      # `extensions`/`files` empty; this was confirmed even for nokogiri, so
      # any future refresh of this list must inspect the downloaded `.gem`,
      # not the remote index) and each gemspec's `extensions` was inspected.
      # 11 of the 100 declare a C extension. json, msgpack, and psych are
      # already in this corpus above. grpc and nokogiri are excluded per R10
      # (see the comments below); the remaining 6 are added here. These are
      # widely-used gems in real-world use, so building them with rubycc
      # speaks directly to R10's goal.
      #
      # Manual exclusion: grpc 1.83.0 is not added. Its ext/grpc has 3000+
      # `.cc` files and explicitly sets ENV['CXX']/ENV['LDXX'] to compile them
      # — a C++ extension, which DESIGN R10 places out of scope.
      #
      # Manual exclusion: nokogiri 1.19.4 is not added. It depends on
      # mini_portile2 (~> 2.8.2) to build vendored libxml2/libxslt/libiconv/
      # zlib from bundled source via autoconf `configure`
      # (`--use-system-libraries` switches to the system libraries instead).
      # DESIGN §3.3 explicitly names nokogiri's vendored build (mini_portile
      # running autoconf configure, which requires a shell) as out of scope.
      {
        name: "websocket-driver",
        version: "0.8.2",
        note: "Single ext dir (ext/websocket-driver); extconf.rb only calls " \
              "dir_config, no external library dependency, no C++."
      },
      {
        name: "puma",
        version: "8.0.2",
        note: "Single ext dir (ext/puma_http11). OpenSSL is an optional " \
              "dependency: extconf.rb only probes for it unless " \
              "PUMA_DISABLE_SSL is set, and the build continues without SSL " \
              "if it is not found. No C++, no mini_portile. DESIGN §3.1 " \
              "names puma among the expected-in-scope gems."
      },
      {
        name: "google-protobuf",
        version: "4.35.1",
        note: "ext/google/protobuf_c bundles ruby-upb.c (upb, a C " \
              "implementation despite the gem's C++-sounding name) and " \
              "utf8_range.c; the gem contains no .cc files. No mini_portile " \
              "dependency."
      },
      {
        name: "bootsnap",
        version: "1.24.6",
        note: "Single ext dir (ext/bootsnap); no external library " \
              "dependency, no C++."
      },
      {
        name: "oj",
        version: "3.17.4",
        note: "Single ext dir (ext/oj); no external library dependency, " \
              "no C++."
      },
      {
        name: "sqlite3",
        version: "2.9.5",
        r10_profile: "sqlite3-system-libraries",
        r10_extconf_args: ["--enable-system-libraries"],
        note: "Single ext dir (ext/sqlite3). The default builds the bundled " \
              "sqlite3 amalgamation through mini_portile2 and configure; the " \
              "R10 profile explicitly uses `--enable-system-libraries` to " \
              "select system libsqlite3 instead. No C++ either way (the " \
              "amalgamation is .c). DESIGN §3.1 names " \
              "\"sqlite3 (when using the system library)\" as expected in " \
              "scope. rubycc already compiles the sqlite3 amalgamation " \
              "(261,463 lines) standalone (docs/development/STEPS.md, Step 116), making " \
              "this gem a promising corpus candidate."
      },

      # Selected 2026-07-29. Download counts were fetched the same day from
      # rubygems.org's API (`https://rubygems.org/api/v1/gems/<name>.json`,
      # the `downloads` field). Unlike the popular-gems group above (Step
      # 119), this is not an exhaustive scan of a specific rank range of
      # https://rubygems.org/releases/popular — it is a candidate list of
      # gems already known to ship a C extension, filtered down by download
      # count. So this group cannot claim "every gem in ranks X..Y was
      # checked", only "every candidate gem with at least this many
      # downloads was checked".
      #
      # As with the group above, judgment was made by inspecting the
      # downloaded `.gem` directly, never the remote gemspec — `gem
      # specification --remote <name> extensions` always returns empty (see
      # the comment above this group). All 11 gems added below were
      # confirmed to declare exactly one `extensions` entry and to contain
      # zero C++ sources (`.cc`/`.cpp`/`.cxx`).
      #
      # Cutoff: download count >= 100,000,000.
      #
      # Manual exclusion: ffi 1.17.4 (1,058,902,013 downloads, the most of
      # any candidate considered here) is not added. Its ext/ffi_c/libffi
      # bundles 48 `.S` assembly files and requires an assembler to build;
      # rubycc has no assembler. The README's known limitations already
      # list ffi as out of scope for this reason.
      #
      # Manual exclusion: bcrypt 3.1.22 (403,015,687 downloads) is not
      # added. Its C sources alone look like they would build fine, but
      # ext/mri/extconf.rb explicitly lists `x86.o` in `$objs`, which is
      # produced from the bundled `x86.S` — so an assembler is required
      # here too, just less visibly than in ffi's case since it only shows
      # up by reading extconf.rb rather than the C sources themselves.
      {
        name: "nio4r",
        version: "2.7.5",
        note: "669,001,382 downloads. Single ext dir (ext/nio4r); extconf.rb " \
              "only calls dir_config. C 13 files / H 5 files. The I/O " \
              "selector behind Rails' ActionCable and puma."
      },
      {
        name: "byebug",
        version: "13.0.0",
        control_suite_passes: false,
        note: "470,544,259 downloads. Single ext dir (ext/byebug); extconf.rb " \
              "is 12 lines and only calls dir_config. C 5 files / H 1 file. " \
              "Out of the R10 denominator: the upstream suite does not pass " \
              "with the reference compiler either. Measured on 2026-08-07 with " \
              "tools/verify_gem_tests.rb, control and rubycc runs reporting the " \
              "same numbers to the digit — 535 runs, 776 assertions, 22 " \
              "failures, 6 errors, 2 skips (docs/development/STEPS.md atomic-type-8)."
      },
      {
        name: "pg",
        version: "1.6.3",
        r10_profile: "pg-native-source",
        r10_extconf_args: [],
        note: "458,822,794 downloads. Single ext dir (ext/); C 22 files / H 3 " \
              "files. Important note: extconf.rb references mini_portile2 " \
              "and `./configure`, but only inside the `--with-cross-build` " \
              "path (extconf.rb:26, `if gem_platform = " \
              "with_config(\"cross-build\")`), which is only taken when " \
              "building pre-built cross-platform binary gems. A normal " \
              "source install locates the system libpq via pg_config / " \
              "pkg-config instead. DESIGN R10 names pg as in scope. The " \
              "census profile selects this native source path, requires no " \
              "cross-build argument, and fails closed if the native branch " \
              "loses its pg_config/system-library markers."
      },
      {
        name: "mysql2",
        version: "0.5.7",
        note: "238,399,342 downloads. Single ext dir (ext/mysql2); C 5 files " \
              "/ H 8 files. Depends on the system libmysqlclient / " \
              "libmariadb headers via have_library, the same " \
              "system-library-dependent-but-in-scope shape as openssl and " \
              "zlib above."
      },
      {
        name: "thin",
        version: "2.0.1",
        out_of_scope_dependency: "eventmachine (C++ extension — " \
                                 "docs/reference/OUT-OF-SCOPE-GEMS.md basis A)",
        note: "207,539,292 downloads. Single ext dir (ext/thin_parser), a " \
              "Ragel-generated parser: C 2 files / H 2 files. thin's own " \
              "extension is pure C and passes the machine gate, but its " \
              "runtime dependency eventmachine is a C++ extension, so " \
              "`gem install thin` cannot complete without building one. " \
              "Measured on 2026-08-08: rubycc reaches eventmachine's nine " \
              ".cpp files and the build stops there (docs/development/STEPS.md " \
              "atomic-type-9). Out of the R10 denominator by R10's own C++ " \
              "exclusion, reaching one level past thin's own sources."
      },
      {
        name: "http_parser.rb",
        version: "0.8.1",
        note: "175,614,437 downloads. Single ext dir " \
              "(ext/ruby_http_parser); C 8 files / H 3 files. extconf.rb " \
              "only calls dir_config."
      },
      {
        name: "stackprof",
        version: "0.2.28",
        note: "153,037,422 downloads. Single ext dir (ext/stackprof); a " \
              "single C file — one of the smallest C extensions in this " \
              "corpus. extconf.rb is 16 lines but does carry four have_func " \
              "probes (rb_postponed_job_preregister and friends), measured " \
              "in Step 146; an earlier note here said \"no probes\", which " \
              "was wrong."
      },
      {
        name: "unicorn",
        version: "6.1.0",
        control_suite_passes: false,
        note: "118,284,401 downloads. Single ext dir (ext/unicorn_http); C 2 " \
              "files / H 5 files, extconf.rb has no probes. Note: its " \
              "dependencies kgio and raindrops are also C extensions, so " \
              "`gem install unicorn` additionally requires building those; " \
              "rubycc builds all three since atomic-type-6/7. Out of the R10 " \
              "denominator: the upstream suite does not pass with the reference " \
              "compiler either. Measured on 2026-08-07 by building both ways " \
              "and running the same 15 files, with identical results — " \
              "test_request.rb 10 errors, test_signals.rb 1 error, " \
              "test_util.rb 3 failures. unicorn 6.1.0 is the newest release and " \
              "announces at load that it was only tested up to MRI 3.0; the " \
              "failures are Ruby 3.4 incompatibilities in its Ruby code " \
              "(docs/development/STEPS.md atomic-type-7)."
      },
      {
        name: "debug",
        version: "1.11.1",
        control_suite_passes: false,
        note: "116,172,789 downloads. Single ext dir (ext/debug); C 2 " \
              "files, extconf.rb 27 lines with no probes. Ruby's standard " \
              "debugger. Out of the R10 denominator: the upstream suite does " \
              "not pass with the reference compiler either. Measured on " \
              "2026-08-07 with tools/verify_gem_tests.rb, control and rubycc " \
              "runs reporting the same numbers to the digit — 305 tests, 571 " \
              "assertions, 1 failure, 1 omission (docs/development/STEPS.md atomic-type-8)."
      },
      {
        name: "yajl-ruby",
        version: "1.4.3",
        note: "107,509,632 downloads. Single ext dir (ext/yajl); C 9 files " \
              "/ H 11 files, bundling the yajl C sources. extconf.rb 12 " \
              "lines with no probes."
      },
      {
        name: "nkf",
        version: "0.3.0",
        note: "105,204,704 downloads. Single ext dir (ext/nkf); C 3 files " \
              "/ H 3 files. extconf.rb is only 3 lines. Was formerly a " \
              "default gem, but is not in Ruby 4.0.6's default gem list, " \
              "so it was not part of the default gem group in Step 117."
      }
    ].freeze
  end
end
