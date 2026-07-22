# frozen_string_literal: true

require "date"
require "fileutils"
require "open3"
require "rubygems/package"
require "set"
require "tmpdir"

require_relative "gems"

# Step 92 (M5 H3, docs/ROADMAP.md §8): census of system (angle-bracket) #includes
# used by the C extensions of a curated gem corpus, classified against the headers
# rubycc bundles under include/. It answers "which not-yet-bundled headers does real
# gem code reach for?" so header work in H2/H4 is driven by measurement, not guessing.
#
# The module is split into two layers:
#   * pure helpers (no network, no gem fetch) — unit-tested by test_corpus_census.rb
#   * orchestration (gem fetch / unpack / report) — driven only by `rake corpus:census`
#
# Only the orchestration touches the network. `rake test` never loads the orchestration
# path, so the default test suite stays hermetic. Raw #include grepping over-counts:
# headers behind platform / SIMD / C++ gates are collected too. The census does not
# evaluate those gates; it only labels each header bundled / gap and annotates likely
# gate origins in the report (H3's acceptance is a first baseline, not a pass rate).
module Corpus
  module Census
    module_function

    # ------------------------------------------------------------------
    # Pure helpers (network-free): these are the unit-tested surface.
    # ------------------------------------------------------------------

    # A single #include <...> per line; angle brackets only. Quoted ("...")
    # includes are local headers and are intentionally not matched.
    ANGLE_INCLUDE_RE = /^[ \t]*#[ \t]*include[ \t]*<([^>]+)>/

    # Extract angle-bracket include spellings from C/H source text, in order.
    # No comment / #if-0 awareness on purpose: like a grep, this over-counts and
    # the caller classifies the results.
    def extract_angle_includes(source)
      source.each_line.filter_map do |line|
        m = ANGLE_INCLUDE_RE.match(line)
        m && m[1].strip
      end
    end

    # Compute the set of angle spellings rubycc bundles, from an include/ tree.
    # Freestanding headers (include/*.h) and libc headers (include/libc/**) both
    # contribute; the per-arch layer (include/libc/glibc/<arch>/...) is normalized
    # to its arch-independent spelling so both arches collapse to one entry.
    def bundled_headers(include_root)
      set = Set.new
      Dir.glob(File.join(include_root, "**", "*.h")).each do |path|
        rel = path.sub(/\A#{Regexp.escape(include_root)}\/?/, "")
        spelling = normalize_bundled_spelling(rel)
        set << spelling unless spelling.empty?
      end
      set
    end

    # Map a path relative to include/ to its angle spelling:
    #   "float.h"                       -> "float.h"        (freestanding)
    #   "libc/assert.h"                 -> "assert.h"
    #   "libc/sys/socket.h"             -> "sys/socket.h"
    #   "libc/glibc/x86_64/sys/stat.h"  -> "sys/stat.h"     (arch layer normalized)
    #   "libc/glibc/aarch64/ctype.h"    -> "ctype.h"
    def normalize_bundled_spelling(rel)
      s = rel.sub(%r{\Alibc/glibc/[^/]+/}, "") # strip the arch layer first
      s.sub(%r{\Alibc/}, "")                   # then the plain libc layer
    end

    # Classify one system include against the bundled set.
    def classify_include(spelling, bundled_set)
      bundled_set.include?(spelling) ? :bundled : :gap
    end

    # Headers resolved by ruby's hdrdir or by the extension's own directory are
    # not libc-gap candidates. Excluded from gap analysis (recorded separately).
    def ruby_or_self?(spelling, own_basenames)
      return true if spelling == "ruby.h"
      return true if spelling.start_with?("ruby/")
      return true if spelling.include?("rubycc")
      own_basenames.include?(File.basename(spelling))
    end

    # C++ translation units / headers. Presence excludes a gem under R10.
    CPP_SOURCE_EXTS = %w[.cpp .cc .cxx .c++ .hpp .hxx .hh].freeze

    def cpp_source?(path)
      CPP_SOURCE_EXTS.include?(File.extname(path).downcase)
    end

    # Detect a configure / mini_portile dependency in extconf text (R10 exclusion).
    # Conservative so the pure-C corpus is not falsely excluded: matches an
    # autoconf-style `configure` invocation via a shell call, or mini_portile.
    def configure_dependency?(text)
      return true if text =~ /mini_portile/i
      return true if text =~ /system\s*\([^)]*\bconfigure\b/
      return true if text =~ /`[^`]*\bconfigure\b[^`]*`/
      return true if text =~ /%x[\{\(\[\|][^\}\)\]\|]*\bconfigure\b/
      false
    end

    # Headers that only appear behind a SIMD / CPU-feature #ifdef. Bundled or not,
    # these are annotated so a gap does not imply a real portability requirement.
    SIMD_HEADERS = %w[
      x86intrin.h immintrin.h emmintrin.h xmmintrin.h pmmintrin.h tmmintrin.h
      smmintrin.h nmmintrin.h wmmintrin.h ammintrin.h mmintrin.h avxintrin.h
      avx2intrin.h cpuid.h arm_neon.h arm_acle.h arm_sve.h
    ].freeze

    # Headers that only appear behind a Windows / MSVC #ifdef.
    WINDOWS_HEADERS = %w[
      windows.h winsock2.h ws2tcpip.h intrin.h io.h direct.h process.h
      windef.h winbase.h
    ].freeze

    # A best-effort note about why a gap header may be unreachable in practice
    # (behind a gate). This does NOT decide the gate; it only flags likely cases
    # so the reviewer can judge whether a bundled header is actually required.
    def gate_hint(spelling)
      base = File.basename(spelling)
      return "SIMD/CPU-feature gate (arch/feature-conditional)" if SIMD_HEADERS.include?(base)
      return "Windows-only gate" if WINDOWS_HEADERS.include?(base)
      # C++ standard headers carry no filename extension (e.g. <cstdbool>, <vector>).
      return "C++-only (C++ standard header)" unless base.include?(".")
      return "C++-only (C++ header)" if base =~ /\.(hpp|hxx|hh)\z/
      "" # unknown origin — needs manual review
    end

    # ------------------------------------------------------------------
    # Orchestration (network / filesystem): driven only by `rake corpus:census`.
    # ------------------------------------------------------------------

    DEFAULT_CACHE_DIR = File.join(Dir.tmpdir, "rubycc_corpus_census")

    def default_repo_root
      File.expand_path("../..", __dir__)
    end

    def default_cache_dir
      File.expand_path(ENV["RUBYCC_CORPUS_CACHE"] || DEFAULT_CACHE_DIR)
    end

    def default_report_path
      File.expand_path("include-census.md", __dir__)
    end

    def log(msg)
      warn "==> #{msg}"
    end

    # Fetch <name> (optionally pinned to <version>) into cache_dir with
    # `gem fetch --platform=ruby`. Idempotent: a cached .gem is reused and the
    # network is not touched. Returns [gem_path, error_message]; on failure the
    # path is nil and the caller records the reason (the whole run continues).
    def fetch_gem(name, version, cache_dir)
      FileUtils.mkdir_p(cache_dir)
      cached = cached_gem_path(name, version, cache_dir)
      return [cached, nil] if cached

      cmd = ["gem", "fetch", name, "--platform=ruby"]
      cmd += ["--version", version] if version
      out, status = Open3.capture2e(*cmd, chdir: cache_dir)
      unless status.success?
        return [nil, out.strip]
      end

      path = cached_gem_path(name, version, cache_dir)
      path ? [path, nil] : [nil, "gem fetch reported success but no .gem appeared: #{out.strip}"]
    end

    # Locate a cached .gem: exact name-version.gem when pinned, else the highest
    # cached version of name-*.gem.
    def cached_gem_path(name, version, cache_dir)
      if version
        path = File.join(cache_dir, "#{name}-#{version}.gem")
        File.file?(path) ? path : nil
      else
        Dir.glob(File.join(cache_dir, "#{name}-*.gem"))
           .select { |p| version_from_gem(name, p) =~ /\A\d/ }
           .max_by { |p| safe_gem_version(version_from_gem(name, p)) }
      end
    end

    def version_from_gem(name, gem_path)
      File.basename(gem_path, ".gem").sub(/\A#{Regexp.escape(name)}-/, "")
    end

    def safe_gem_version(str)
      Gem::Version.new(str)
    rescue ArgumentError
      Gem::Version.new("0")
    end

    # Unpack a .gem (a tar wrapping data.tar.gz) into cache_dir/unpacked/<stem>.
    # Idempotent: an already-extracted, non-empty dir is reused. Returns its path.
    def unpack_gem(gem_path, cache_dir)
      dest = File.join(cache_dir, "unpacked", File.basename(gem_path, ".gem"))
      if !Dir.exist?(dest) || Dir.empty?(dest)
        FileUtils.mkdir_p(dest)
        Gem::Package.new(gem_path).extract_files(dest)
      end
      dest
    end

    def ext_source_files(root)
      Dir.glob(File.join(root, "ext", "**", "*.{c,h}")).sort
    end

    def ext_cpp_files(root)
      Dir.glob(File.join(root, "ext", "**", "*.{cpp,cc,cxx,c++,hpp,hxx,hh}")).sort
    end

    def read_extconf(root)
      Dir.glob(File.join(root, "ext", "**", "extconf.rb"))
         .map { |p| File.read(p, encoding: "BINARY") }
         .join("\n")
    end

    # Census one gem spec. Returns a result hash; never raises (fetch/unpack
    # failures and R10 exclusions are recorded so the run as a whole continues).
    def census_gem(spec, cache_dir, bundled_set)
      name = spec[:name]
      requested = spec[:version]
      result = {
        name: name, requested_version: requested, note: spec[:note],
        status: nil, reason: nil, version: nil, fetched_on: nil,
        includes: {}, ruby_self: [], ext_c_files: 0, ext_h_files: 0
      }

      gem_path, fetch_error = fetch_gem(name, requested, cache_dir)
      unless gem_path
        result[:status] = :skipped
        result[:reason] = "gem fetch failed: #{fetch_error}"
        return result
      end

      result[:version] = version_from_gem(name, gem_path)
      result[:fetched_on] = File.mtime(gem_path).utc.to_date.iso8601

      source_root = unpack_gem(gem_path, cache_dir)

      cpp = ext_cpp_files(source_root)
      unless cpp.empty?
        result[:status] = :excluded
        names = cpp.map { |p| File.basename(p) }.uniq.sort.join(", ")
        result[:reason] = "C++ sources present (#{names}) — R10 excludes C++ extensions"
        return result
      end

      if configure_dependency?(read_extconf(source_root))
        result[:status] = :excluded
        result[:reason] = "configure / mini_portile dependency in extconf.rb — R10 excludes configure-dependent gems"
        return result
      end

      files = ext_source_files(source_root)
      own_basenames = files.select { |p| p.end_with?(".h") }.map { |p| File.basename(p) }.to_set

      files.each do |path|
        path.end_with?(".h") ? (result[:ext_h_files] += 1) : (result[:ext_c_files] += 1)
        src = File.read(path, encoding: "BINARY")
        extract_angle_includes(src).each do |spelling|
          if ruby_or_self?(spelling, own_basenames)
            result[:ruby_self] << spelling
          else
            result[:includes][spelling] ||= classify_include(spelling, bundled_set)
          end
        end
      end
      result[:ruby_self] = result[:ruby_self].uniq.sort
      result[:status] = :ok
      result
    rescue StandardError => e
      result[:status] = :skipped
      result[:reason] = "error: #{e.class}: #{e.message}"
      result
    end

    # Run the full census and write the markdown snapshot. Returns report_path.
    def run_and_write_report(repo_root: default_repo_root,
                             cache_dir: default_cache_dir,
                             report_path: default_report_path)
      include_root = File.join(repo_root, "include")
      bundled = bundled_headers(include_root)

      results = Corpus::Gems::LIST.map do |spec|
        log("census: #{spec[:name]}#{spec[:version] ? " #{spec[:version]}" : " (latest)"}")
        census_gem(spec, cache_dir, bundled)
      end

      File.write(report_path, render_report(results, bundled))
      print_summary(results)
      report_path
    end

    # Aggregate gap candidates across the ok gems: header => sorted list of gems.
    def gap_candidates(results)
      candidates = Hash.new { |h, k| h[k] = [] }
      results.select { |r| r[:status] == :ok }.each do |r|
        r[:includes].each do |spelling, category|
          candidates[spelling] << r[:name] if category == :gap
        end
      end
      candidates.transform_values! { |gems| gems.uniq.sort }
      candidates
    end

    def print_summary(results)
      gaps = gap_candidates(results)
      warn "==> gap candidates (#{gaps.size}):"
      gaps.keys.sort.each do |h|
        hint = gate_hint(h)
        warn "      #{h}  <- #{gaps[h].join(', ')}#{hint.empty? ? '' : "  [#{hint}]"}"
      end
      excluded = results.select { |r| r[:status] == :excluded }
      skipped = results.select { |r| r[:status] == :skipped }
      warn "==> excluded: #{excluded.map { |r| r[:name] }.join(', ')}" unless excluded.empty?
      warn "==> skipped:  #{skipped.map { |r| r[:name] }.join(', ')}" unless skipped.empty?
    end

    # ------------------------------------------------------------------
    # Report rendering.
    # ------------------------------------------------------------------

    def render_report(results, bundled_set)
      ok = results.select { |r| r[:status] == :ok }
      excluded = results.select { |r| r[:status] == :excluded }
      skipped = results.select { |r| r[:status] == :skipped }
      gaps = gap_candidates(results)

      out = +""
      out << render_header(bundled_set)
      out << render_corpus_table(results)
      out << render_exclusions(excluded, skipped)
      out << render_matrix(ok)
      out << render_gap_candidates(gaps)
      out
    end

    def render_header(bundled_set)
      <<~MD
        # include-census — corpus C-extension `#include` census

        **Generated file. Do not hand-edit.** This is a snapshot produced by
        `rake corpus:census` (see `test/corpus/README.md`). Re-run that task to update
        it, then commit the result. The task requires network access; `rake test` does not.

        - Generated: #{Time.now.utc.iso8601}
        - Ruby: #{RUBY_DESCRIPTION}
        - Bundled header set: #{bundled_set.size} angle spellings computed from `include/`
          (freestanding `include/*.h` + `include/libc/**`, arch layer normalized).

        Angle-bracket (`#include <...>`) includes only; quoted local includes are ignored.
        `ruby.h`, `ruby/...`, `rubycc*`, and each extension's own headers are excluded from
        libc-gap analysis (they resolve via ruby's hdrdir or the ext directory). Raw include
        scanning over-counts: headers behind SIMD / Windows / C++ gates are listed as gap
        candidates with a note; the census does not evaluate the gate.

      MD
    end

    def render_corpus_table(results)
      out = +"## Corpus gems\n\n"
      out << "| gem | requested | resolved | fetched | status | ext .c/.h | note |\n"
      out << "|-----|-----------|----------|---------|--------|-----------|------|\n"
      results.each do |r|
        out << format(
          "| %s | %s | %s | %s | %s | %s | %s |\n",
          r[:name],
          r[:requested_version] || "latest",
          r[:version] || "—",
          r[:fetched_on] || "—",
          r[:status],
          r[:status] == :ok ? "#{r[:ext_c_files]}/#{r[:ext_h_files]}" : "—",
          (r[:note] || "").gsub("|", "\\|")
        )
      end
      out << "\n"
      out
    end

    def render_exclusions(excluded, skipped)
      out = +"## Excluded / skipped\n\n"
      if excluded.empty? && skipped.empty?
        out << "None. All corpus gems were fetched and passed the R10 machine gate.\n\n"
        return out
      end
      out << "| gem | outcome | reason |\n|-----|---------|--------|\n"
      (excluded + skipped).each do |r|
        out << format("| %s | %s | %s |\n", r[:name], r[:status], (r[:reason] || "").gsub("|", "\\|"))
      end
      out << "\n"
      out
    end

    # Matrix rows = system headers, columns = ok gems, cell = "x" when used.
    # A per-header class column marks bundled / gap.
    def render_matrix(ok_results)
      out = +"## gem × system header matrix\n\n"
      if ok_results.empty?
        out << "No gems reached the census stage (all excluded or skipped).\n\n"
        return out
      end

      headers = ok_results.flat_map { |r| r[:includes].keys }.uniq.sort
      if headers.empty?
        out << "No system (non-ruby, non-self) angle includes were found.\n\n"
        return out
      end

      gem_names = ok_results.map { |r| r[:name] }
      class_of = {}
      ok_results.each { |r| r[:includes].each { |h, c| class_of[h] = c } }

      out << "| header | class | #{gem_names.join(' | ')} |\n"
      out << "|--------|-------|#{gem_names.map { '---' }.join('|')}|\n"
      headers.each do |h|
        cells = ok_results.map { |r| r[:includes].key?(h) ? "x" : "" }
        out << "| `#{h}` | #{class_of[h]} | #{cells.join(' | ')} |\n"
      end
      out << "\n"
      out
    end

    def render_gap_candidates(gaps)
      out = +"## Gap candidates (not bundled, used by ≥1 corpus gem)\n\n"
      if gaps.empty?
        out << "None. Every system header referenced by the corpus is already bundled.\n\n"
        return out
      end
      out << "| header | used by | likely gate | verdict |\n"
      out << "|--------|---------|-------------|---------|\n"
      gaps.keys.sort.each do |h|
        hint = gate_hint(h)
        out << format(
          "| `%s` | %s | %s | %s |\n",
          h, gaps[h].join(", "),
          hint.empty? ? "—" : hint,
          hint.empty? ? "review" : "gated (likely not required)"
        )
      end
      out << "\n"
      out
    end
  end
end
