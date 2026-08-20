# acceptance fixture

このディレクトリは、`acceptance-fixture` profileが外部ネットワークなしで
実際の `gem fetch` 相当の入力、`gem unpack`、`extconf.rb`、rubycc/rmakeによる
extension build、ロード確認まで実行するための固定入力である。

`.gem` はRubyGemsから取得した対象バージョンのアーカイブをそのまま保存する。
期待するSHA-256は [`config/ci/acceptance_manifest.json`](../../../config/ci/acceptance_manifest.json)
にあり、実行時にmanifestとfixtureの両方を照合する。期待するロード結果は
[`expected-results.json`](expected-results.json)に置く。

更新時は次の順で行う。

1. manifestのname/version/platformとURLを更新する
2. `.gem`を取得し、manifestへ実測SHA-256を記録する
3. `expected-results.json`とfixtureの検査を実行する
4. `CI_NETWORK=fixture`かつネットワークを遮断したnamespace内でacceptance jobを確認する

CIではfixture pathが明示されている場合だけアーカイブをコピーする。fixture modeで
ネットワークURLへfallbackする経路は失敗させる。
