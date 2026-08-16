# corpus-candidate-pilot-v2 実測レビュー

## 固定入力

結果を見る前に固定したmanifestは[`pilot-v2-manifest.json`](pilot-v2-manifest.json)、正式14日分の
Actions runは[`pilot-v2-runs.json`](pilot-v2-runs.json)に記録した。正式計測に使ったscanner revision
は`66a20d76314e93f342f3618da25e3bcaf62ee3be`である。計測項目を追加する前の先行14runは、release
entry数と作業領域を持たないため、結論の分母から除外した。windowの入れ替えや失敗日の除外はしていない。

raw response、`.gem`、unpack tree、scan logは`docs/development/corpus-candidate-evaluation/artifacts/`
配下のignored workに保存し、commitしたのはregistry、metrics、検査要約だけである。

## 日別実測

`unique gems`はそのUTC日で選択された名前数、`error`はその日のclassification record数である。

| UTC window | release entries | unique gems | archive success | candidate | error | wall time (s) | peak work (GiB) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2026-08-02 | 384 | 235 | 223 | 11 | 12 | 55.808 | 1.06 |
| 2026-08-03 | 451 | 286 | 267 | 10 | 19 | 93.083 | 1.61 |
| 2026-08-04 | 523 | 284 | 265 | 12 | 19 | 43.190 | 1.21 |
| 2026-08-05 | 751 | 527 | 500 | 19 | 27 | 81.929 | 1.70 |
| 2026-08-06 | 364 | 224 | 213 | 6 | 11 | 58.803 | 1.24 |
| 2026-08-07 | 441 | 252 | 236 | 15 | 16 | 72.408 | 1.65 |
| 2026-08-08 | 331 | 188 | 179 | 12 | 9 | 34.314 | 0.69 |
| 2026-08-09 | 360 | 229 | 217 | 7 | 13 | 42.317 | 0.41 |
| 2026-08-10 | 438 | 272 | 253 | 15 | 19 | 72.190 | 1.25 |
| 2026-08-11 | 587 | 338 | 323 | 13 | 15 | 99.579 | 1.89 |
| 2026-08-12 | 494 | 320 | 298 | 3 | 22 | 42.450 | 0.76 |
| 2026-08-13 | 453 | 286 | 272 | 7 | 14 | 63.209 | 1.04 |
| 2026-08-14 | 455 | 288 | 278 | 9 | 10 | 74.348 | 0.74 |
| 2026-08-15 | 826 | 765 | 262 | 119 | 503 | 50.201 | 0.36 |

2026-08-11のwall timeはsummary実測値`99.579秒`である（表の桁落ちを避けるため、metricsの値を正とする）。

合計はrelease entry `6,858`、日別unique gem occurrences `4,494`、source pages `251`、archive
inspection `3,786`件で、archive取得は成功`3,786`、retry `0`、失敗`0`、転送`4,107,296,256`
bytes（約3.83 GiB）だった。classification statusは`no_ext 3,419`、`candidate 258`、`error 709`、
`review 74`、`needs_review 5`、`excluded 29`である。

## 増分価値と候補収率

既存`include-census.md`のgem×header matrixをbaselineとし、観測済みの既存集合はbundled
`55` spelling、gap `70` spellingだった。全static recordからは新規bundled/system spellingが
`alloca.h`、`endian.h`、`stdalign.h`、`sys/un.h`の4件、新規gap spellingが101件得られた。
既存corpusに無く、popular rank 1〜100 controlにも無いcandidateに限定すると、新規systemは3件、
新規gapは88件である。header集合が既存corpus gemのいずれかと完全一致した候補occurrenceは204/251件。

candidate statusからpopular controlとの重複7 occurrenceを除くと、eligibleは251 occurrence、
200 unique gem namesだった。日をまたぐ重複は51 occurrence、cross-window duplicate rateは
`20.3187%`である。build shapeはsingle-extconf 239、multi-extconf 6、cargo 2、rake 2、
declared-mkrf_conf.rb 2で、既存corpusの既知shape以外にcargo、rake、mkrf_conf entrypointを観測した。

popular rank 1〜100 controlは100 gemで、candidate 7（すべて既存corpusに含まれる名前）、no-ext 90、
excluded 2、review 1だった。新規popular candidateは0件である。

## 上位3件の固定検査

固定priority（new gap、new system、new build shape、version downloads、release日時、gem名）で、
次の3つを選んだ。各候補のidentity、静的結果、Actions結果は
[`pilot-v2-inspections.json`](pilot-v2-inspections.json)に記録した。

| candidate | new system | new gap | local skill | manual Actions build/load |
| --- | --- | --- | --- | --- |
| rbtrace 0.5.5 | `sys/un.h` | `env.h`, `msgpack.h`, `node.h`, `st.h`, `sys/ipc.h`, `sys/msg.h` | identity一致、static candidate | `build_failed`: extconfがbundled msgpackのconfigure/make installで停止 ([run](https://github.com/nuna/rubycc/actions/runs/31940359185)) |
| graphql-c_parser 1.1.4 | `alloca.h` | `libintl.h`, `malloc.h` | identity一致、static candidate | build evidenceはpass、load sanityは`GraphQL::Language` NameErrorで`fallback_or_not_loaded` ([run](https://github.com/nuna/rubycc/actions/runs/31940399889)) |
| roaring 0.4.1 | `endian.h` | SIMD/CPU関連を含む新規gap | identity一致、static candidate | `build_failed`: `roaring.h`の`#warning`をrubyccがinvalid preprocessing directiveとして拒否 ([run](https://github.com/nuna/rubycc/actions/runs/31940431681)) |

3件ともarchive SHAとgemspecのname/version/platformが一致した。upstream testはrecipeを実行していない。
roaringの`#warning`失敗は再現可能な新規rubycc gapとして有用だが、3件にbuild/load passは無い。
人手review時間は今回のpilotでは計時していないため、維持費の実測値は未確定である。

## 運用判定

- daily wall time p50は`58.803327秒`、p95は`99.579438秒`、目標900秒（15分）を満たした
- timeout windowは`0/14`、workflow final failureは`0/14`、archive failureは`0/3,786`
- ただしclassification record errorは`709/4,494 = 15.7766%`で、目標としている最終失敗率と
  混同しないよう別指標として扱う。特に8/15は503件がv2 metadata 404で、候補の増分ではなく
  timeframe sourceとmetadataの不整合が支配している
- 新規header/gapと新しいbuild shapeは再現した。roaringでは新規rubycc gapも再現したが、build/load
  成功候補と人手review時間は未確認である
- 14日でeligible候補は0ではないため、事前規則の28日延長は実施しない

以上から結論は **条件付き採用** とする。全静的scanの日次経路は15分目標、timeout、workflow
failureを満たし、候補の増分価値も検出できる。一方、source error率が高い日をそのまま運用へ
持ち込めず、候補ごとのload sanityと人手review時間も未確定なので、現時点でcorpus自動拡張を
有効化しない。今回の評価では`test/corpus/gems.rb`、header、compiler、`data/verified_gems.json`
を変更していない。

## follow-up

- [corpus-candidate-pilot-v2-source-errors](../../../issues/corpus-candidate-pilot-v2-source-errors.md):
  timeframeとv2 metadataのstale release/404を候補errorと分離する
- [corpus-candidate-pilot-v2-load-sanity](../../../issues/corpus-candidate-pilot-v2-load-sanity.md):
  候補ごとのreview済みload entrypointを安全に扱う

正式追加に進める候補はまだ無い。roaringはcompiler gap対応を別途判断し、rbtraceとgraphql-c_parserは
それぞれのfollow-upで再現性を確認してから、1 gem = 1 issueの追加判断へ進む。
