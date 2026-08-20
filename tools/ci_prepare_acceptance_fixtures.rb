# frozen_string_literal: true

require "fileutils"
require_relative "../test/support/acceptance_fetch_helper"
require_relative "../test/support/acceptance_manifest_helper"

# Download the pinned gem inputs into the CI-local cache before the acceptance
# tests enter their empty network namespace. The archives stay out of Git and
# are never uploaded as test artifacts; the acceptance tests consume only the
# verified local copies.
if AcceptanceFetchHelper.fixture_mode?
  abort "CI_NETWORK=fixture must not be set while preparing the fixture cache"
end

root = File.expand_path(
  ENV.fetch("CI_FIXTURE_ROOT", File.join(Dir.pwd, "tmp/ci/acceptance-fixtures"))
)
FileUtils.mkdir_p(root)

artifacts = AcceptanceManifestHelper.manifest.fetch("artifacts")
  .select { |artifact| artifact.fetch("kind") == "rubygems-gem" }
abort "no RubyGems artifacts are declared in the acceptance manifest" if artifacts.empty?

fetcher = AcceptanceFetchHelper::Fetcher.new(work_dir: root)
artifacts.each do |artifact|
  fixture = artifact.fetch("fixture")
  destination = File.expand_path(fixture, root)
  unless destination == root || destination.start_with?("#{root}#{File::SEPARATOR}")
    abort "fixture path escapes CI cache root: #{fixture}"
  end

  fetcher.fetch_url(
    url: artifact.fetch("url"),
    destination: fixture,
    expected_sha256: artifact.fetch("sha256"),
    artifact_id: artifact.fetch("id"),
    artifact_kind: artifact.fetch("kind"),
    artifact_url: artifact.fetch("url")
  )
  puts "prepared #{artifact.fetch('id')} at #{destination}"
end
