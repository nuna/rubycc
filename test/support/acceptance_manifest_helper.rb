# frozen_string_literal: true

require_relative "../../tools/ci_check_acceptance"

# Lookup for pinned live artifacts. The manifest remains the single source of
# truth; callers must not silently fall back to an unpinned download.
module AcceptanceManifestHelper
  MANIFEST_PATH = File.expand_path("../../config/ci/acceptance_manifest.json", __dir__).freeze

  module_function

  def artifact(id)
    entry = manifest.fetch("artifacts").find { |candidate| candidate.fetch("id") == id }
    return entry if entry

    raise Rubycc::CIResult::Error, "acceptance artifact #{id.inspect} is not in the manifest"
  end

  def sha256(id)
    artifact(id).fetch("sha256")
  end

  def manifest
    @manifest ||= Rubycc::CICheckAcceptance.load_manifest(MANIFEST_PATH)
  end
end
