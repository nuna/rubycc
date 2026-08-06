# frozen_string_literal: true

require_relative "lib/rubycc/version"

Gem::Specification.new do |spec|
  spec.name = "rubycc"
  spec.version = Rubycc::VERSION
  spec.authors = ["DATE Ken"]
  spec.email = ["itacchi@gmail.com"]

  spec.summary = "Almost Pure Ruby C toolchain for building Ruby native extensions " \
                 "without gcc/binutils"
  spec.description = "Almost Pure Ruby C toolchain for building Ruby native extensions " \
                      "without gcc/binutils"
  spec.homepage = "https://github.com/nuna/rubycc"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  # rubygems.org の gem ページに "Source Code" リンクを表示するための標準メタデータ
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob("lib/**/*.rb") + Dir.glob("include/**/*.h") + Dir.glob("exe/*") +
               Dir.glob("data/*") + ["LICENSE.txt", "NOTICE", "README.md", "CHANGELOG.md"]
  spec.bindir = "exe"
  # `gem install` builds work without bin stubs (the plugin points MAKE/PKG_CONFIG at
  # gem-internal absolute paths), but rmake/rubycc-ar/rubycc-pkgconf are also tools
  # users reach for directly when building by hand or investigating, and README
  # documents all five as bundled commands, so all five get bin stubs.
  spec.executables = ["rmake", "rubycc", "rubycc-ar", "rubycc-doctor", "rubycc-pkgconf"]
  spec.require_paths = ["lib"]
end
