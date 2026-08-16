---
status: open
kind: infra
opened: 2026-08-16
closed:
branch:
pr:
steps: []
---

# 日次 corpus 候補scanを計測可能にし、archive取得時間を短縮する

## 課題

[corpus-candidate-discovery](corpus-candidate-discovery.md) の1日分live scanは、2026-08-16の
同一UTC windowを空cacheで2回実行して、どちらも約23分を要した。114 gemから109個の
source gemを取得し、`.gem`は約50 MB、作業領域全体は約83 MBだった。gem生成間隔の中央値は
約12.6秒で、現在の `Corpus::Census.fetch_gem` が候補ごとに `gem fetch` subprocessを直列起動
する部分が支配的である。

現行artifactにはAPI requestと分類結果は残るが、release列挙、metadata確認、archive取得、
展開・静的検査、集計のフェーズ別時間と転送量がない。最適化前後や日ごとの変動を比較できず、
GitHub Actionsのtimeoutを根拠を持って決められない。

このissueは静的scanの計測と取得経路だけを扱う。定期workflowは
[corpus-candidate-daily-workflow](corpus-candidate-daily-workflow.md)、実運用でのp95判定は
[corpus-candidate-pilot-v2](corpus-candidate-pilot-v2.md)へ分ける。

## 影響

現行速度を線形に延ばすと、14日backfillは約5時間25分、28日は約10時間50分になる。
日次実行なら1回23分で済むが、再実行や欠落期間の回収が重く、ネットワーク障害時にどこまで
進んだかも分からない。逆に計測なしで並列数だけ増やすと、RubyGems.orgへの負荷と失敗率を
上げる可能性がある。

## 受け入れ条件

- JSON artifactに、少なくとも次のフェーズ別elapsed timeを追加する
  - timeframe paginationとrelease正規化
  - v2 metadata/source/yanked確認
  - archive取得
  - unpackと静的分類
  - rankingとartifact書き出し
- request数、取得byte数、archive cache hit数、成功・retry・失敗数を同じartifactへ記録する
- 実行時刻や絶対pathを決定的artifactへ混ぜない。時間計測値を含むrun summaryと、入力から
  再生成できる分類artifactを分離する
- v2 metadataの固定version `gem_uri`からsource gemを直接取得し、metadataのSHA-256と
  一致しないarchiveを展開・分類しない
- archive取得は設定可能なbounded concurrencyとし、既定2、最大4を超えない。
  timeout、`Retry-After`、指数backoffを実装し、失敗を「候補なし」へ変換しない
- 同じname/version/platform/SHAのarchiveは再利用し、途中失敗後に完了済みarchiveを
  再取得しない
- `gem fetch`互換経路を残す場合はfallback条件を明示し、同じfixtureで直接取得経路との
  name/version/platform/分類一致を検証する
- 固定した完了済みUTC 1日windowを、隔離した空cacheで変更前後それぞれ実測する。
  変更後の目標は15分以内とするが、外部要因で未達ならフェーズ別値と原因を記録し、結果を
  隠してissueを閉じない
- malformed metadata、SHA不一致、partial download、429、timeout、途中再開をhermetic testで
  検証し、`rake test`はネットワークアクセスなしで0 failuresとなる
- scannerの利用手順と計測項目を`test/corpus/README.md`へ反映する

このPRでは日次workflow、gemのbuild/test、corpusへの正式追加を行わない。

## 作業ログ

### 2026-08-16

1日分scanの作業directoryの生成時刻と最終出力時刻を2回分確認し、いずれも23分強だった。
1日109 archiveという規模に対して、静的解析より直列 `gem fetch` の待ち時間が大きいと判断した。
並列化だけでなく、フェーズ別計測、SHA検証、再開可能性を同じ変更の受け入れ条件にした。

## 決着

(完了時に記入。結果と`docs/development/STEPS.md`の該当エントリへのリンクを残す。)
