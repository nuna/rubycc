# frozen_string_literal: true

require_relative "test_helper"
require "rubygems"

# examples/distroless/Dockerfile builds the rubycc gem from a deliberately
# minimal copy of the checkout -- only what the gemspec packages, so the sample
# also demonstrates what a consumer actually needs. That minimalism is a
# duplicate of rubycc.gemspec's `files` list living in another file, and the two
# drifted apart: CHANGELOG.md joined the gemspec during release preparation and
# the COPY line did not follow.
#
# `gem build` does not warn about that. It raises:
#
#   ERROR:  While executing gem ... (Gem::InvalidSpecificationException)
#       ["CHANGELOG.md"] are not files
#
# measured 2026-08-12, one commit before v1.0.0 would have been tagged. The
# sample is what README points a new user at, and CI cannot catch it because
# building it needs Docker. Comparing the two lists is pure text, though, so
# that part runs here on every suite.
class TestDistrolessExample < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DOCKERFILE = File.join(ROOT, "examples/distroless/Dockerfile")

  def gemspec
    @gemspec ||= Dir.chdir(ROOT) { Gem::Specification.load(File.join(ROOT, "rubycc.gemspec")) }
  end

  # Every COPY source token in the file, with the destination and the flags
  # dropped. Both build stages are read: a token only has to appear somewhere,
  # since this asserts presence rather than which stage does the copying.
  def copy_sources
    File.readlines(DOCKERFILE).grep(/^COPY\s/).flat_map do |line|
      tokens = line.split[1..] || []
      tokens.reject! { |t| t.start_with?("--") }
      tokens[0..-2] || []
    end
  end

  def test_the_sample_copies_every_packaged_root_file
    root_files = gemspec.files.reject { |path| path.include?("/") }
    refute_empty root_files, "the gemspec should package files at the repository root"

    missing = root_files - copy_sources
    assert_empty missing,
                 "examples/distroless/Dockerfile must COPY every root file rubycc.gemspec packages " \
                 "(`gem build` fails with \"are not files\" otherwise): #{missing.join(", ")}"
  end

  def test_the_sample_copies_every_packaged_directory
    directories = gemspec.files.filter_map { |path| path.split("/").first if path.include?("/") }.uniq
    refute_empty directories

    missing = directories - copy_sources
    assert_empty missing,
                 "examples/distroless/Dockerfile must COPY every directory rubycc.gemspec packages: " \
                 "#{missing.join(", ")}"
  end
end
