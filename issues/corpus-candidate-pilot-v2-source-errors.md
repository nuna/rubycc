---
status: open
kind: infra
opened: 2026-08-16
closed:
branch:
pr:
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

未着手。pilot v2の2026-08-15実測で503件のv2 metadata 404を確認したため、source errorの分類と
候補分母の分離を次の作業対象として固定した。

## 決着

未着手。

このissueでは候補gemの正式追加を行わない。
