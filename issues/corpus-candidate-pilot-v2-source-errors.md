---
status: done
kind: infra
opened: 2026-08-16
closed: 2026-08-16
branch: corpus-candidate-pilot-v2-source-errors
pr: https://github.com/nuna/rubycc/pull/74
steps:
  - corpus-candidate-pilot-v2-source-errors-1
  - corpus-candidate-pilot-v2-source-errors-2
---

# timeframe sourceの不整合releaseを候補errorとして扱う

## 課題

`corpus-candidate-pilot-v2`の2026-08-15 windowでは、765 unique gem recordのうち503件が
Rubygems v2 metadataの404でerrorになった。名前とversionの組み合わせがtimeframe APIに残る一方で
source metadataから消える不整合が大量に発生しており、候補収率とscan error率を歪める。errorを
候補なしへ変換することは避ける必要があるが、現在は全errorが同じ`error` bucketで、source障害と
候補固有の検査失敗を分離できない。

## 影響

sourceの一時的不整合を候補収率や失敗率へ混ぜると、日次scanの継続可否と候補の増分価値を誤判定する。
反対に404を黙って捨てると、欠測を成功扱いにしてしまうため、source errorを可視化したまま候補分母
から分離する必要がある。

## 受け入れ条件

- stale release、v2 metadata 404、rate limit、network failure、archive SHA不一致を別statusで
  記録し、候補statusへ昇格しない
- 固定fixtureで404を再現し、release entry、error、候補分母、window failureを別々に集計する
- 同じintervalを再実行したとき、欠測やsource errorを成功候補として補完しない
- 14日集計でsource error rateとwindow final failure rateを分けて報告し、運用目標を判定できる
- API response、raw cache、gem archiveはignored workに限定し、corpusやverified databaseを変更しない

## 実装計画

1. `corpus-candidate-pilot-v2-source-errors-1`: source errorの分類・summary schema・fixtureを追加する
2. `corpus-candidate-pilot-v2-source-errors-2`: 固定window replayとerror budget判定を更新する

## 作業ログ

pilot v2の2026-08-15実測で503件のv2 metadata 404を確認したため、source errorの分類と候補分母の
分離を実装対象として固定した。

### 2026-08-16 — source error taxonomyとsummary schema

`stale_release`、`v2_metadata_404`、`rate_limited`、`network_failure`、
`archive_sha_mismatch`を候補・`no_ext`とは別statusとして扱う実装を開始した。artifactにはkind、
stage、HTTP status、reasonを保存し、run summaryにはkind/stage別件数を保存する。集計toolはsource
error rateとwindow failure rateを別々に扱い、失敗・欠測windowを成功分母へ混ぜない。

404、rate limit、network failure、archive SHA不一致、yanked releaseのhermetic fixtureを追加し、
scanner targeted testは28 runs / 144 assertions、pilot summary testは4 runs / 25 assertionsで
failures 0 / errors 0だった。

### 2026-08-16 — 固定14日replayと実測report

scanner revision `5f6fc6d40a68aca89fc37ad1c530eeaeb41a7c48`で2026-08-02〜08-15の1日windowを
14本再実行し、14/14成功、window failure 0、timeout 0、wall-time p95 129.751秒を確認した。
raw artifactは`docs/development/corpus-candidate-evaluation/artifacts/`以下に限定し、追跡対象は
replay manifest、run registry、metrics、reportだけとした。途中で試した2日windowとキャンセルrunは
registryおよび分母から除外した。

4,494 recordのうちsource errorは575件 (12.7948%)で全件`v2_metadata_404`、通常のrecord
processing errorは134件 (2.9818%)だった。従来の`error` 709件 (15.7766%)をsource errorと処理
errorに分離でき、source errorをcandidate、`no_ext`、処理errorの成功分母へ混ぜないことを実測で
確認した。2026-08-15の501件集中はupstream metadata availabilityの監視対象として残した。

固定corpus/popular control適用後は251 eligible occurrences / 200 unique namesとなり、静的選定は
`rbtrace`、`graphql-c_parser`、`roaring`の3件を得た。候補プールがsource error分離後も維持される
ことを確認したが、正式追加やverified database更新は行っていない。詳細は
`docs/development/corpus-candidate-evaluation/source-errors-replay-report.md`に記録した。

## 決着

完了。source errorを候補分母から分離し、window failureとは別の指標として14日実測を固定した。

このissueでは候補gemの正式追加を行わない。
