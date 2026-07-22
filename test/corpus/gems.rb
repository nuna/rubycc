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
      }
    ].freeze
  end
end
