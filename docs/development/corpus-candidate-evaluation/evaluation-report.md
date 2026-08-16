# Corpus candidate evaluation report

実験は scanner revision `ac9f149a55036dd3057db67d643405734a331b47` で、結果を見る前に固定した
UTC 7 日 window 4 個と rubygems.org popular rank 1〜100 を比較した。timeframe 全体は
`--selection-only` で pagination と release 選定を測り、archive の静的検査は事前規則で最大3件に
限定した。各 JSON artifact の `source_requests` に URL、cache key、response SHA-256 がある。
JSON artifactとraw cacheは再生成可能な作業ファイルなのでcommitせず、固定入力は
`manifest.json`、集計値は`metrics.json`、結論はこのreportに残す。

## 結果

| source | entries / gems | corpus | `[1]` | `[1b]` | `[2]` | `[R]` | `[E]` | API requests |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| timeframe 合計 | 12,829 / 5,647 | 13 | 0 | 0 | 0 | 0 | 163 | 434 |
| popular 1–100 | — / 100 | 8 | 0 new | 0 | 1 | 1 | 0 | 110 |

timeframe の selection rejection は duplicate release 5,409、prerelease 512。source gem 不在、
yanked、v2 `platform=ruby` は全件検証を延期したため未計測である。`uninspected` の名前 union は
3,889（既存 corpus 8、新規未検査 3,881）だが、これは `[1]` 候補ではない。

popular の `[1]` status 7件は bootsnap、google-protobuf、io-console、json、msgpack、oj、
websocket-driver で、すべて既存 corpus だった。したがって期間 source 固有の新規 `[1]` と
popular 対照との差集合は、検査済み候補としては 0 件である。

## 固定静的サンプル

selection-only で header 優先順位を観測できなかったため、`created_at` 降順、gem 名順で次の
3件を固定した。

| gem/version | platform | status | C/H | headers | archive/API SHA |
|---|---|---|---:|---|---|
| DhanHQ 3.4.0 | ruby | no_ext | 0/0 | bundled 0, gap 0 | match |
| phronomy 0.19.0 | ruby | no_ext | 0/0 | bundled 0, gap 0 | match |
| security 0.2.0 | ruby | no_ext | 0/0 | bundled 0, gap 0 | match |

3件とも v2 metadata HTTP 200、`yanked=false`。rubycc の package build/install は成功したが、
対象に C extension がないため target build は事前規則に従い実行していない。

## 決定

現行の bounded route は **不採用**（corpus の自動・定期拡張には進めない）。観測できた静的
`[1]`、新規 header/gap、build 成功、review 解消がゼロで、selection-only の 3,881 未検査名を
適格候補とみなすこともできないためである。これは未検査名がすべて純 Rubyだという主張ではない。
次の改善では、source/yanked を安価に先行検証する metadata prefilter、またはより大きな事前固定
静的サンプルを別 issue として設計する。今回 `test/corpus/gems.rb` は変更していない。
