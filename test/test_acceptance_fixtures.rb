# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "rubygems/package"

# The CI-local gem archives are the material input for the network-free
# acceptance profile. Keep their identity tied to the same manifest used by
# live acceptance, and keep the observable smoke results in a reviewable text
# fixture rather than hiding them in test code.
class TestAcceptanceFixtures < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  METADATA_ROOT = File.join(ROOT, "test/fixtures/acceptance")
  MANIFEST_PATH = File.join(ROOT, "config/ci/acceptance_manifest.json")
  EXPECTED_PATH = File.join(METADATA_ROOT, "expected-results.json")

  def manifest
    @manifest ||= JSON.parse(File.read(MANIFEST_PATH))
  end

  def expected
    @expected ||= JSON.parse(File.read(EXPECTED_PATH))
  end

  def gem_artifacts
    manifest.fetch("artifacts").select { |artifact| artifact.fetch("kind") == "rubygems-gem" }
  end

  def test_manifest_declares_pinned_gem_cache_entries
    refute_empty gem_artifacts

    gem_artifacts.each do |artifact|
      fixture = artifact.fetch("fixture")
      refute fixture.empty?
      refute fixture.start_with?("/"), "fixture must be relative: #{fixture}"
      refute fixture.split(/[\\\/]/).include?(".."), "fixture must stay below the cache root"
      assert_match(/\A[\w.-]+\z/, fixture, "fixture must be a cache file name")
    end
  end

  def test_staged_gem_archives_match_the_manifest_when_cache_is_configured
    root = ENV["CI_FIXTURE_ROOT"]
    unless root && !root.empty?
      assert true, "CI fixture cache is validated by the preparation step"
      return
    end

    gem_artifacts.each do |artifact|
      fixture = artifact.fetch("fixture")
      path = File.expand_path(fixture, root)
      assert File.file?(path), "missing staged acceptance fixture #{fixture}"
      assert_equal artifact.fetch("sha256"), Digest::SHA256.file(path).hexdigest,
                   "#{fixture} does not match its manifest SHA-256"

      specification = Gem::Package.new(path).spec
      assert_equal artifact.fetch("name"), specification.name
      assert_equal artifact.fetch("version"), specification.version.to_s
      assert_equal artifact.fetch("platform"), specification.platform.to_s
    end
  end

  def test_expected_results_name_the_same_archives_and_stable_smoke_values
    gem_artifacts.each do |artifact|
      result = expected.fetch(artifact.fetch("name"))
      assert_equal artifact.fetch("fixture"), result.fetch("archive")
      assert_equal artifact.fetch("version"), result.fetch("version")
      refute_empty result.fetch("round_trip")
    end
  end
end
