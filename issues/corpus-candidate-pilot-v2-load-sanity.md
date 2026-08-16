---
status: in-progress
kind: infra
opened: 2026-08-16
closed:
branch: corpus-candidate-pilot-v2-load-sanity
pr:
steps:
  - corpus-candidate-pilot-v2-load-sanity-1
  - corpus-candidate-pilot-v2-load-sanity-2
---

# 候補gemごとのbuild/load sanity recipeを安全に扱う

## 課題

pilot v2の`graphql-c_parser 1.1.4`はrubycc build evidenceがpassし、native extensionのinstallも
成功したが、汎用のshared-object load sanityは`GraphQL::Language`未定義で失敗した。extensionを
直接requireするだけでは、gemのdocumented require entrypointやRuby側の初期化を再現できない場合が
ある。一方で任意のrequireやtest commandを受け入れると、候補skillの安全境界を壊す。

## 影響

genericな`.so` requireだけで判定すると、build成功をload失敗と誤認する候補や、純Ruby fallbackを
見落とす候補が混ざる。任意の候補コードを実行できるrecipeへ緩めると、安全な手動検証workflowの
境界と再現性を失うため、review済みentrypointを明示的に管理する必要がある。

## 受け入れ条件

- 候補ごとにname/version/platform/SHAと、review済みの固定load entrypointを紐付ける
- entrypointが無い候補は`recipe_missing`として停止し、任意commandへfallbackしない
- native extensionのinstall、rubycc build evidence、documented load sanity、純Ruby fallbackを
  別statusで記録する
- controlとrubyccの実行環境・GEM_HOMEを分離し、`data/verified_gems.json`を自動更新しない
- `graphql-c_parser`をfixtureまたは固定archiveで再現し、失敗理由がtool誤判定でないことを確認する

## 実装計画

1. `corpus-candidate-pilot-v2-load-sanity-1`: recipe schemaと安全なentrypoint検査を設計する
2. `corpus-candidate-pilot-v2-load-sanity-2`: 固定候補でhost control/rubyccを比較し、skillとworkflowの出力を更新する

## 作業ログ

`corpus_candidate_load_recipes.rb`にname/version/platform/SHAで固定するrecipe schemaを追加し、
`graphql/c_parser`、`graphql` 2.6.8、`graphql_c_parser` sanityをreview済みentrypointとして登録した。
recipeに任意commandやscriptを持たせず、未登録候補は`recipe_missing`で停止するようにした。

`verify_corpus_candidate.rb`と手動workflowにhost control/rubyccの分離実行を追加し、native extension
install、rubycc build evidence、documented loadを別statusで出力するようにした。固定候補を
Ruby 3.3.12で実測し、さらにGitHub Actions Ruby 4.0.6の[run 31950250084](https://github.com/nuna/rubycc/actions/runs/31950250084)
でhost/rubyccとも`documented_load_pass`、比較`pass`を確認した。raw artifactはignored領域へ保存し、
正式corpusとverified databaseは変更していない。

## 決着

実装・固定archiveの再検証・Actions比較まで完了した。PR作成後にstatusを`done`へ更新する。

このissueでは候補gemを正式corpusへ追加しない。
