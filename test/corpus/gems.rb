# frozen_string_literal: true

# Step 92 (M5 H3): curated corpus of Ruby gems whose C extensions are the input
# to `rake corpus:census`. This list is committed on purpose for reproducibility:
# re-running the census against the same names yields a comparable snapshot even
# as rubygems.org drifts. The initial members are the pure-C candidates named by
# docs/ROADMAP.md (§8, H3) and already exercised by tools/collect_mkmf_corpus.rb.
#
# Membership here is a *candidate* list, not a claim of R10 conformance. The real
# R10 gate (C++ usage / configure / mini_portile) is decided mechanically by
# test/corpus/census.rb, which excludes or warns per gem and records the reason
# in the generated report. Manual exclusions, if any, are commented with a reason.
#
# Each entry:
#   :name    — rubygems.org gem name (fetched with `gem fetch --platform=ruby`)
#   :version — pinned version string, or nil to fetch the latest release
#   :note    — why this gem is in the corpus
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
      {
        name: "bigdecimal",
        version: nil,
        note: "Pure C arbitrary-precision decimal; default gem, widely depended on."
      },
      {
        name: "date",
        version: nil,
        note: "Pure C date/time core (ext/date); default gem."
      },
      {
        name: "racc",
        version: nil,
        note: "Pure C parser runtime (ext/racc/cparse); extconf.rb runs no probes."
      },
      {
        name: "redcarpet",
        version: nil,
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
        note: "Small single-file ext (ext/fcntl)."
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
      }
    ].freeze
  end
end
