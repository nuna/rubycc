# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

require_relative "corpus/gems"
require_relative "corpus/census"

# Step 92 (M5 H3): hermetic checks for the corpus include-census tooling. This
# test NEVER touches the network: `gem fetch` lives in the orchestration layer of
# census.rb and is not exercised here. Only the pure, network-free helpers and the
# committed artifacts (gems.rb, include-census.md) are verified.
class TestCorpusCensus < Minitest::Test
  CORPUS_DIR = File.expand_path("corpus", __dir__)
  CENSUS = Corpus::Census

  # ---- committed artifacts ----

  def test_gems_list_is_well_formed
    list = Corpus::Gems::LIST
    assert_kind_of Array, list
    refute_empty list, "corpus gem list is empty"

    list.each do |entry|
      assert_kind_of Hash, entry
      assert entry.key?(:name), "gem entry missing :name: #{entry.inspect}"
      assert_kind_of String, entry[:name]
      refute_empty entry[:name], "gem entry has blank :name: #{entry.inspect}"
      # :version is optional (nil = latest); when present it must be a String.
      assert_kind_of String, entry[:version] if entry.key?(:version) && !entry[:version].nil?
      # :upstream_tests is optional (absent = true); when present it must be false
      # (the only meaningful declared value — see the field comment in gems.rb).
      if entry.key?(:upstream_tests)
        assert_equal false, entry[:upstream_tests],
                     "gem entry #{entry[:name]} declares upstream_tests other than false: " \
                     "#{entry[:upstream_tests].inspect}"
      end
      # :control_suite_passes is the same shape: absent means "not claimed", and
      # false is the only value that says anything.
      if entry.key?(:control_suite_passes)
        assert_equal false, entry[:control_suite_passes],
                     "gem entry #{entry[:name]} declares control_suite_passes other than " \
                     "false: #{entry[:control_suite_passes].inspect}"
      end
      # :out_of_scope_dependency names the blocking gem *and* its basis, so it
      # must be a non-empty String rather than a bare flag.
      if entry.key?(:out_of_scope_dependency)
        assert_kind_of String, entry[:out_of_scope_dependency]
        refute_empty entry[:out_of_scope_dependency],
                     "gem entry #{entry[:name]} declares a blank out_of_scope_dependency"
      end
    end

    names = list.map { |e| e[:name] }
    assert_equal names, names.uniq, "duplicate gem names in corpus list"
  end

  def test_fcntl_declares_no_upstream_tests
    fcntl = Corpus::Gems::LIST.find { |e| e[:name] == "fcntl" }
    refute_nil fcntl, "fcntl entry missing from corpus list"
    assert_equal false, fcntl[:upstream_tests],
                 "fcntl must declare upstream_tests: false (docs/STEPS.md Step 157: " \
                 "upstream ships no test suite)"
  end

  def test_snapshot_report_is_present_and_non_empty
    report = File.join(CORPUS_DIR, "include-census.md")
    assert File.file?(report), "missing committed snapshot #{report} (run `rake corpus:census`)"
    assert_operator File.size(report), :>, 0, "snapshot #{report} is empty"
    body = File.read(report)
    assert_includes body, "Do not hand-edit", "snapshot is missing its generated-file banner"
  end

  # ---- angle-include extraction ----

  def test_extract_angle_includes_takes_angle_only
    src = <<~C
      #include <stdio.h>
      #include <sys/socket.h>
      #include "local.h"
      # include <ruby.h>
      #include<stdlib.h>
      int x; // #include <not_a_real.h>
    C
    got = CENSUS.extract_angle_includes(src)
    # Quoted includes are excluded; angle ones (even oddly spaced) are kept in order.
    assert_equal ["stdio.h", "sys/socket.h", "ruby.h", "stdlib.h"], got
  end

  # ---- bundled header set from an include/ tree ----

  def test_normalize_bundled_spelling
    assert_equal "float.h", CENSUS.normalize_bundled_spelling("float.h")
    assert_equal "assert.h", CENSUS.normalize_bundled_spelling("libc/assert.h")
    assert_equal "sys/socket.h", CENSUS.normalize_bundled_spelling("libc/sys/socket.h")
    assert_equal "sys/stat.h", CENSUS.normalize_bundled_spelling("libc/glibc/x86_64/sys/stat.h")
    assert_equal "ctype.h", CENSUS.normalize_bundled_spelling("libc/glibc/aarch64/ctype.h")
  end

  def test_bundled_headers_from_synthetic_tree
    Dir.mktmpdir do |root|
      make_header(root, "stdbool.h")               # freestanding
      make_header(root, "libc/assert.h")           # plain libc
      make_header(root, "libc/sys/socket.h")       # libc subdir
      make_header(root, "libc/glibc/x86_64/sys/stat.h")  # arch layer
      make_header(root, "libc/glibc/aarch64/sys/stat.h") # same spelling, other arch

      bundled = CENSUS.bundled_headers(root)
      assert_includes bundled, "stdbool.h"
      assert_includes bundled, "assert.h"
      assert_includes bundled, "sys/socket.h"
      assert_includes bundled, "sys/stat.h"
      # Both arch copies collapse to a single normalized spelling.
      assert_equal 4, bundled.size, "expected exactly 4 distinct spellings, got #{bundled.to_a.sort.inspect}"
    end
  end

  def test_bundled_headers_matches_real_include_tree
    include_root = File.expand_path("../include", __dir__)
    bundled = CENSUS.bundled_headers(include_root)
    # Sanity anchors across all three layers.
    assert_includes bundled, "stdbool.h",   "freestanding stdbool.h should be bundled"
    assert_includes bundled, "sys/socket.h", "libc sys/socket.h should be bundled"
    assert_includes bundled, "sys/stat.h",   "arch-layer sys/stat.h should normalize into bundled set"
    assert_includes bundled, "stdint.h",     "arch-layer stdint.h should normalize into bundled set"
  end

  # ---- bundled / gap classification ----

  def test_classify_include
    bundled = Set.new(%w[stdio.h sys/socket.h])
    assert_equal :bundled, CENSUS.classify_include("stdio.h", bundled)
    assert_equal :bundled, CENSUS.classify_include("sys/socket.h", bundled)
    assert_equal :gap, CENSUS.classify_include("cpuid.h", bundled)
    assert_equal :gap, CENSUS.classify_include("arm_neon.h", bundled)
  end

  def test_ruby_or_self_detection
    own = Set.new(%w[parser.h generator.h])
    assert CENSUS.ruby_or_self?("ruby.h", own)
    assert CENSUS.ruby_or_self?("ruby/encoding.h", own)
    assert CENSUS.ruby_or_self?("rubycc/foo.h", own)
    assert CENSUS.ruby_or_self?("parser.h", own), "extension's own header should be treated as self"
    refute CENSUS.ruby_or_self?("stdio.h", own)
    refute CENSUS.ruby_or_self?("cpuid.h", own)
  end

  # ---- R10 machine gate helpers ----

  def test_cpp_source_detection
    assert CENSUS.cpp_source?("ext/foo/bar.cpp")
    assert CENSUS.cpp_source?("ext/foo/bar.cc")
    assert CENSUS.cpp_source?("ext/foo/bar.hpp")
    refute CENSUS.cpp_source?("ext/foo/bar.c")
    refute CENSUS.cpp_source?("ext/foo/bar.h")
  end

  def test_configure_dependency_detection
    assert CENSUS.configure_dependency?("require 'mini_portile2'\nMiniPortile.new(...)")
    assert CENSUS.configure_dependency?('system("./configure --prefix=/opt/foo")')
    assert CENSUS.configure_dependency?("`sh configure`")
    refute CENSUS.configure_dependency?("create_makefile('json/ext/parser')")
    refute CENSUS.configure_dependency?("have_header('ruby.h')\nhave_func('rb_str_new')")
  end

  def test_excluded_by_upstream_tests_detection
    assert CENSUS.excluded_by_upstream_tests?({ upstream_tests: false })
    refute CENSUS.excluded_by_upstream_tests?({ upstream_tests: true })
    refute CENSUS.excluded_by_upstream_tests?({}), "absent field must default to not-excluded"
  end

  def test_excluded_by_out_of_scope_dependency_detection
    assert CENSUS.excluded_by_out_of_scope_dependency({ out_of_scope_dependency: "eventmachine (C++)" })
    assert_nil CENSUS.excluded_by_out_of_scope_dependency({}),
               "absent field must default to not-excluded"
  end

  # The point of the field is that it *points at* an existing decision rather
  # than making a new one, so every gem it names must already be recorded in
  # docs/OUT-OF-SCOPE-GEMS.md. A name that appears nowhere else would be an
  # exclusion invented here, which is what this test exists to prevent.
  def test_out_of_scope_dependencies_are_already_recorded_as_out_of_scope
    doc = File.read(File.expand_path("../docs/OUT-OF-SCOPE-GEMS.md", __dir__))
    Corpus::Gems::LIST.filter_map { |e| [e[:name], e[:out_of_scope_dependency]] if e[:out_of_scope_dependency] }
                      .each do |name, blocker|
      gem_name = blocker[/\A[a-z0-9_.-]+/]
      assert_includes doc, "**#{gem_name}**",
                      "#{name} is excluded because of #{gem_name}, but docs/OUT-OF-SCOPE-GEMS.md " \
                      "does not record #{gem_name} as out of scope"
    end
  end

  def test_excluded_by_control_suite_detection
    assert CENSUS.excluded_by_control_suite?({ control_suite_passes: false })
    refute CENSUS.excluded_by_control_suite?({ control_suite_passes: true })
    refute CENSUS.excluded_by_control_suite?({}), "absent field must default to not-excluded"
  end

  # Every control_suite_passes: false is a claim that a --control run was made
  # and matched, and the numbers that back it belong in the note (see the field
  # documentation in gems.rb). A bare `control_suite_passes: false` with nothing
  # to re-check is exactly the unfalsifiable exclusion the field must not become.
  def test_control_suite_exclusions_cite_their_measurement
    Corpus::Gems::LIST.select { |e| e[:control_suite_passes] == false }.each do |entry|
      note = entry[:note].to_s
      assert_includes note, "reference compiler",
                      "#{entry[:name]} excludes itself from the R10 denominator without saying " \
                      "the claim is about the reference compiler"
      assert_match(/Measured on \d{4}-\d{2}-\d{2}/, note,
                   "#{entry[:name]} excludes itself from the R10 denominator without dating the " \
                   "measurement that backs it")
    end
  end

  # census_gem's upstream_tests exclusion is checked right after a cached .gem
  # is located, before unpacking — so a stub cache entry is enough to exercise
  # it without touching the network (fetch_gem returns early on a cache hit).
  def test_census_gem_excludes_gem_with_upstream_tests_false
    Dir.mktmpdir do |cache_dir|
      File.write(File.join(cache_dir, "examplegem-1.0.0.gem"), "not a real gem")
      spec = { name: "examplegem", version: "1.0.0", note: "sample", upstream_tests: false }

      result = CENSUS.census_gem(spec, cache_dir, Set.new)

      assert_equal :excluded, result[:status]
      assert_match(/no test suite/, result[:reason])
      assert_equal "1.0.0", result[:version], "version should still resolve from the cache hit"
    end
  end

  def test_census_gem_defaults_upstream_tests_to_not_excluded
    refute CENSUS.excluded_by_upstream_tests?({ name: "examplegem" }),
           "a spec without :upstream_tests must not be excluded by this gate"
  end

  # ---- R10 pass-rate summary ----

  def test_r10_summary_counts_and_rate
    r10 = CENSUS.r10_summary(%w[a b c d], Set.new(%w[a b]))
    assert_equal 4, r10[:denominator]
    assert_equal 2, r10[:numerator]
    assert_in_delta 50.0, r10[:rate], 0.001
  end

  def test_r10_summary_remaining_to_90
    # 25/37 verified: needs 9 more to reach ceil(0.9*37)=34.
    r10 = CENSUS.r10_summary((1..37).map(&:to_s), Set.new((1..25).map(&:to_s)))
    assert_equal 37, r10[:denominator]
    assert_equal 25, r10[:numerator]
    assert_equal 9, r10[:remaining_to_90]
  end

  def test_r10_summary_remaining_is_zero_once_at_target
    r10 = CENSUS.r10_summary(%w[a b c d e f g h i j], Set.new(%w[a b c d e f g h i]))
    assert_equal 0, r10[:remaining_to_90], "9/10 already meets the 90% target"
  end

  def test_r10_summary_handles_empty_denominator
    r10 = CENSUS.r10_summary([], Set.new)
    assert_equal 0, r10[:denominator]
    assert_equal 0, r10[:numerator]
    assert_equal 0.0, r10[:rate]
    assert_equal 0, r10[:remaining_to_90]
  end

  def test_gate_hint_annotations
    assert_match(/SIMD/, CENSUS.gate_hint("cpuid.h"))
    assert_match(/SIMD/, CENSUS.gate_hint("arm_neon.h"))
    assert_match(/Windows/, CENSUS.gate_hint("intrin.h"))
    assert_match(/C\+\+/, CENSUS.gate_hint("cstdbool"))
    assert_equal "", CENSUS.gate_hint("sys/random.h"), "unknown header should carry no gate hint"
  end

  # ---- report rendering is deterministic (no timestamps / interpreter version) ----

  def test_render_report_is_deterministic_across_runs
    results = sample_results
    bundled = Set.new(%w[stdio.h sys/socket.h])

    first = CENSUS.render_report(results, bundled, sample_verified_names)
    second = CENSUS.render_report(results, bundled, sample_verified_names)

    assert_equal first, second, "render_report must be a pure function of its inputs"
  end

  def test_render_report_has_no_date_like_strings
    body = CENSUS.render_report(sample_results, Set.new(%w[stdio.h]), sample_verified_names)
    refute_match(/\d{4}-\d{2}-\d{2}/, body, "snapshot must not embed a run-specific date")
  end

  def test_render_report_does_not_embed_ruby_description
    body = CENSUS.render_report(sample_results, Set.new(%w[stdio.h]), sample_verified_names)
    refute_includes body, RUBY_DESCRIPTION, "snapshot must not embed the interpreter version"
  end

  def test_render_report_includes_r10_pass_rate_section
    body = CENSUS.render_report(sample_results, Set.new(%w[stdio.h]), sample_verified_names)
    assert_includes body, "## R10 pass rate"
    # sample_results has exactly one :ok gem ("examplegem"), which is in sample_verified_names.
    assert_includes body, "| 1 | 1 | 100.0% | 0 |"
  end

  private

  def sample_verified_names
    Set.new(%w[examplegem])
  end

  def sample_results
    [
      {
        name: "examplegem", requested_version: "1.2.3", note: "sample",
        status: :ok, reason: nil, version: "1.2.3",
        includes: { "stdio.h" => :bundled, "cpuid.h" => :gap },
        ruby_self: ["ruby.h"], ext_c_files: 2, ext_h_files: 1
      },
      {
        name: "othergem", requested_version: nil, note: nil,
        status: :excluded, reason: "C++ sources present", version: nil,
        includes: {}, ruby_self: [], ext_c_files: 0, ext_h_files: 0
      }
    ]
  end

  def make_header(root, rel)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "/* #{rel} */\n")
  end
end
