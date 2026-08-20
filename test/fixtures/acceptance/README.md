# acceptance fixture

このディレクトリは、`acceptance-fixture` profileが外部gemをリポジトリへ再配布せずに、
実際の `gem fetch` 相当の入力、`gem unpack`、`extconf.rb`、rubycc/rmakeによる
extension build、ロード確認まで実行するためのメタデータと期待結果を置く場所である。

gem archiveそのものはコミットしない。CIでは [`tools/ci_prepare_acceptance_fixtures.rb`](../../../tools/ci_prepare_acceptance_fixtures.rb)
がmanifestのHTTPS URLから一時的なActions cacheへ取得し、SHA-256を検証する。
期待するSHA-256は [`config/ci/acceptance_manifest.json`](../../../config/ci/acceptance_manifest.json)
にあり、期待するロード結果は [`expected-results.json`](expected-results.json)に置く。

更新時は次の順で行う。

1. manifestのname/version/platformとURLを更新する
2. 取得したarchiveのSHA-256をmanifestへ記録する
3. `expected-results.json`とCI cache準備処理の検査を実行する
4. `CI_NETWORK=fixture`かつネットワークを遮断したnamespace内でacceptance jobを確認する

CI cache準備後のfixture modeでは、fixture pathが明示されているローカルarchiveだけを
コピーする。acceptance実行中にネットワークURLへfallbackする経路は失敗させる。
