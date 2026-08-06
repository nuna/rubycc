# frozen_string_literal: true

require_relative "test_helper"

# Guards against a specific, recurring shape of losing differential
# discipline: hard-coding the name of a piece of the *current* host's
# environment as if it were true of every host, instead of asking the host.
# This project has fallen into exactly this trap four times (docs/GAPS.md
# gap I; docs/STEPS.md Steps 194, 197, 206) -- two of which were "an
# environment-specific name was written into the test source": a probe that
# printed a glibc-only version macro (which musl's own gcc cannot even
# compile), and assertions that hard-coded glibc's libc SONAME where musl's
# is spelled differently.
#
# The literals checked here are narrowed to *libc identity* only -- glibc's
# "libc.so.6", musl's "libc.musl-<arch>.so.1", and the __GLIBC__ family of
# feature-test macros -- not every host-specific literal in the suite. A
# broader sweep (a cross toolchain's program name like
# "aarch64-linux-gnu-gcc", a multiarch path like
# "/usr/lib/x86_64-linux-gnu") turns up 60+ hits, almost all legitimate (a
# cross toolchain's name really is that on every host that has it; a
# multiarch path really is what it is) -- widening the check to those would
# bury it in suppression comments until nobody read it. libc identity is the
# narrow slice that has actually caused repeat, silent breakage.
class TestPlatformLiterals < Minitest::Test
  PATTERNS = [
    "libc.so.6",
    "libc.musl-",
    "__GLIBC__",
    "__GLIBC_MINOR__",
    "__GLIBC_PREREQ"
  ].freeze

  # A hit is allowed when the same line, or the contiguous comment block
  # directly above it, carries a `# platform-literal: <reason>` comment with a
  # non-empty reason -- forcing a reason to be written down, not blocking every
  # use. The whole block counts, not just the line immediately above: a reason
  # worth writing is often longer than one line, and a check that only accepted
  # one-line reasons would push people toward shorter, worse ones. The guard
  # must not make the honest path harder than the dishonest one.
  ANNOTATION = /#\s*platform-literal:\s*(\S.*)/

  def test_no_unannotated_host_libc_identity_literals
    violations = []

    test_source_files.each do |path|
      lines = File.readlines(path)
      lines.each_with_index do |line, index|
        next unless PATTERNS.any? { |pattern| line.include?(pattern) }
        next if annotated?(lines, index)

        violations << "#{path}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty violations,
                 "host-specific libc identity literals must be read from the host, not " \
                 "hard-coded (docs/GAPS.md gap I; docs/STEPS.md Steps 194/197/206), or " \
                 "annotated with a non-empty '# platform-literal: <reason>' comment on the " \
                 "same line or in the comment block above it:\n#{violations.join("\n")}"
  end

  private

  # Every test source file except this one: scanning this file's own PATTERNS
  # list and examples would trivially flag itself.
  def test_source_files
    Dir.glob(File.join(__dir__, "**", "*.rb")).reject { |path| File.expand_path(path) == File.expand_path(__FILE__) }
  end

  def annotated?(lines, index)
    return true if reasoned?(lines[index])

    # Walk up through the comment block immediately above the hit, stopping at
    # the first line that is not a comment.
    cursor = index - 1
    while cursor >= 0 && lines[cursor].lstrip.start_with?("#")
      return true if reasoned?(lines[cursor])

      cursor -= 1
    end
    false
  end

  def reasoned?(line)
    return false if line.nil?

    match = line.match(ANNOTATION)
    !!(match && !match[1].strip.empty?)
  end
end
