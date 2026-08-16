---
status: open
kind: infra
opened: 2026-08-16
closed:
branch:
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

未着手。pilot v2のgraphql-c_parser 1.1.4でbuild evidenceとgeneric load sanityの結果が分かれた
ため、固定entrypointを持つrecipeへ分離する作業対象として記録した。

## 決着

未着手。

このissueでは候補gemを正式corpusへ追加しない。
