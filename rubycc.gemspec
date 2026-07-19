# frozen_string_literal: true

require_relative "lib/rubycc/version"

Gem::Specification.new do |spec|
  spec.name = "rubycc"
  spec.version = Rubycc::VERSION
  spec.authors = ["itacchi"]
  spec.email = ["itacchi@gmail.com"]

  spec.summary = "Pure Ruby C toolchain for building Ruby native extensions " \
                 "without gcc/binutils"
  spec.description = "Pure Ruby C toolchain for building Ruby native extensions " \
                      "without gcc/binutils"
  spec.homepage = "https://github.com/itacchi/rubycc"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob("lib/**/*.rb") + Dir.glob("include/**/*.h") + Dir.glob("exe/*") +
               Dir.glob("data/*") + ["LICENSE.txt", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["rubycc", "rubycc-doctor"]
  spec.require_paths = ["lib"]
end
