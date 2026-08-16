---
status: open
kind: infra
opened: 2026-08-16
closed:
branch:
pr:
steps:
  - corpus-candidate-scan-runtime-1
  - corpus-candidate-scan-runtime-2
  - corpus-candidate-scan-runtime-3
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

## 実装計画

3タスク、各タスクを1コミットの目安とする。

1. `corpus-candidate-scan-runtime-1`: scannerのフェーズ別時間、転送量、cache hit、retryを
   決定的artifactと分離して記録する
2. `corpus-candidate-scan-runtime-2`: v2の固定gem URIからSHA検証付きで取得し、bounded
   concurrency、timeout、backoff、途中再開を実装する
3. `corpus-candidate-scan-runtime-3`: fixtureと固定UTC windowで回帰・比較計測を行い、利用手順と
   実測値を更新する

## 作業ログ

### 2026-08-16

1日分scanの作業directoryの生成時刻と最終出力時刻を2回分確認し、いずれも23分強だった。
1日109 archiveという規模に対して、静的解析より直列 `gem fetch` の待ち時間が大きいと判断した。
並列化だけでなく、フェーズ別計測、SHA検証、再開可能性を同じ変更の受け入れ条件にした。

### 2026-08-16 実装・固定window実測

3タスクを順に実装した。

- `corpus-candidate-scan-runtime-1`: 決定的artifactとは別のrun summaryに、非重複のフェーズ時間、
  source/archive request、byte数、cache hit、archive success/retry/failureを記録した。
- `corpus-candidate-scan-runtime-2`: v2のHTTPS `gem_uri`を必須化し、metadata SHA-256検証後に
  `.part`からatomic renameする直接取得を追加した。timeframeは既定2、設定範囲1〜4のworkerで
  boundedに取得し、429/408/5xxとtimeoutにRetry-After優先の指数backoffを適用する。rank scanは
  固定URIを持たないため、互換fallbackとして従来の`gem fetch`を残した。
- `corpus-candidate-scan-runtime-3`: malformed metadata、SHA不一致、partial、途中再開、429、
  timeout、worker上限と、直接経路/fallbackの同一fixture分類一致をhermetic testで固定した。

既存の変更前記録は、同じUTC windowの空cache scanが約23分強、109 archive、archive約50 MB、
work約83 MBだった。変更後は同じ `2026-08-15T00:00:00Z`〜`2026-08-16T00:00:00Z` を、
専用の空work/cacheと `fetch-concurrency=2` で実行し、次の値になった。

| 指標 | 変更前の記録 | 変更後の実測 |
| --- | ---: | ---: |
| wall time | 約23分強 | 399.407秒 (6分39.4秒) |
| version entries / v2 candidates / archives | 153 / 114 / 109 | 826 / 765 / 262 |
| archive取得 | 109件 / 約50 MB | 262件 / 113,236,992 bytes (約108.0 MiB) |
| work領域 | 約83 MB | 約424 MB (unpack込み) |
| archive success / retry / failure | 未計測 | 262 / 1 / 0 |

変更前後でlive APIの同一UTC windowの内容が変動し、入力規模が153 entries / 109 archiveから
826 entries / 262 archiveへ増えているため、wall timeの減少率を厳密なA/B効果とは扱わない。
それでも変更後のwall timeは15分目標を満たし、フェーズ別には pagination 1.472秒、release
正規化 0.035秒、v2 metadata 329.371秒、archive取得57.246秒、unpack/static11.227秒、
artifact書き出し0.023秒だった。source request 794、archive request 262、total 1,056、
cache hit 0、取得byte 114,657,144をsummaryに記録した。503件のv2 404は候補なしへ黙って
変換せず、[E]として残した。

Ruby 3.3.12でscanner targeted testは25 runs / 128 assertions、`rake test`は3,250 runs /
11,487 assertions / 41 skips、failures 0 / errors 0だった。日次workflow、gem build/test、
`test/corpus/gems.rb`の正式追加は行っていない。

## 決着

実装と固定window実測を完了した。設計判断と実測の要約は
[`corpus-candidate-scan-runtime-1〜3`](../docs/development/STEPS.md) に記録する。
