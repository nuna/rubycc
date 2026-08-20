# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "rubygems/package"

# The committed gem archives are the material input for the network-free
# acceptance profile. Keep their identity tied to the same manifest used by
# live acceptance, and keep the observable smoke results in a reviewable text
# fixture rather than hiding them in test code.
class TestAcceptanceFixtures < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FIXTURE_ROOT = File.join(ROOT, "test/fixtures/acceptance")
  MANIFEST_PATH = File.join(ROOT, "config/ci/acceptance_manifest.json")
  EXPECTED_PATH = File.join(FIXTURE_ROOT, "expected-results.json")

  def manifest
    @manifest ||= JSON.parse(File.read(MANIFEST_PATH))
  end

  def expected
    @expected ||= JSON.parse(File.read(EXPECTED_PATH))
  end

  def gem_artifacts
    manifest.fetch("artifacts").select { |artifact| artifact.fetch("kind") == "rubygems-gem" }
  end

  def test_pinned_gem_archives_match_the_manifest
    refute_empty gem_artifacts

    gem_artifacts.each do |artifact|
      fixture = artifact.fetch("fixture")
      path = File.join(ROOT, fixture)
      assert File.file?(path), "missing acceptance fixture #{fixture}"
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
