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
  spec.summary = "gcc・binutils なしで Ruby の C 拡張をビルドする、ほぼ純 Ruby の C ツールチェイン"
  spec.description = <<~DESCRIPTION
    rubycc は、gcc も binutils も make もシェルも無いマシンで Ruby の C 拡張をビルドします。
    C11 サブセットのコンパイラ、アセンブラを介さない ELF ライタ、リンカ、ar、make、
    pkg-config シム、プリプロセッサを Ruby で実装し、ビルドに必要な libc ヘッダも同梱するので、
    libc の開発パッケージを持たない distroless イメージでも ruby.h をコンパイルできます。

    対象は x86-64 と AArch64 の Linux(ELF64)で、glibc と musl の両方に対応します。
    生成コードは最適化しません。目的は「拡張がビルドでき、その gem 自身のテストが通る」ことで、
    data/verified_gems.json に記録された gem はすべてその水準で検証されています。
    検証済み gem の一覧・実測した制限・対象外の範囲は README を参照してください。
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
