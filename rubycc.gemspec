# frozen_string_literal: true

require_relative "lib/rubycc/version"

Gem::Specification.new do |spec|
  spec.name = "rubycc"
  spec.version = Rubycc::VERSION
  spec.authors = ["DATE Ken"]
  spec.email = ["itacchi@gmail.com"]

  # summary は一覧・検索結果に、description は gem ページ本文に出る。同じ文字列を
  # 両方に置くと `gem build` が "description and summary are identical" を警告し、
  # ページ本文が一行要約のままになるので、役割どおりに書き分ける。
  # 文面は英語 — rubygems.org の読み手と README に合わせる。
  spec.summary = "Almost Pure Ruby C toolchain for building Ruby native extensions " \
                 "without gcc/binutils"
  spec.description = <<~DESCRIPTION
    rubycc builds Ruby C extensions on a machine that has no gcc, no binutils, no make
    and no shell. It is a C11-subset compiler, an assembler-free ELF writer, a linker,
    an ar, a make, a pkg-config shim and a preprocessor, written in Ruby, plus the libc
    headers a build needs -- so a distroless image with no libc development package
    still compiles ruby.h.

    Targets x86-64 and AArch64 Linux (ELF64) against glibc and musl. Generated code is
    unoptimized: the point is that the extension builds and its own test suite passes,
    which is the level at which every gem recorded in data/verified_gems.json was
    verified. See the README for the verified gems, the measured limits, and what is
    out of scope.
  DESCRIPTION
  spec.homepage = "https://github.com/nuna/rubycc"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  # rubygems.org が gem ページに出すリンク。**同じ URI を複数のキーに与えると最初の
  # 1 つしか表示されない**ので(`gem build` がそう警告する)、それぞれ別の宛先を指す。
  # `homepage_uri` は置かない — `spec.homepage` が同じ役割を果たすので、重複させると
  # まさにその警告になる。
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/master/README.md"
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
