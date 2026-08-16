---
status: in-progress
kind: infra
opened: 2026-08-16
closed:
branch: corpus-candidate-evaluation
pr:
steps:
  - corpus-candidate-evaluation-1
  - corpus-candidate-evaluation-2
  - corpus-candidate-evaluation-3
---

# RubyGems 更新履歴による候補発見が corpus を適切に増やせるか検証する

## 課題

[corpus-candidate-discovery](corpus-candidate-discovery.md) で期間指定の候補源を実装し、
[corpus-candidate-artifact](corpus-candidate-artifact.md) で入力 provenance と静的診断を
記録できても、それだけでは発見方法が有効だとは言えない。

1 日の live scan で候補が返ることは、通信・pagination・分類経路の smoke test にすぎない。
更新頻度には期間差があり、既存 corpus または累積人気 scan ですでに見つかる gem ばかりなら、
新しい候補源としての増分価値は小さい。また、静的に `[1]` でも実際の rubycc build が直ちに
破綻し、再現可能な新規 gap も示さないなら、corpus の継続拡張経路として review コストに
見合わない。

「適切に増やせる」は、候補数だけでなく次の 3 条件に分けて評価する必要がある。

1. **増分性**: 既存 corpus と既存の popular 候補源に無い gem を発見する
2. **適格性**: source gem、非 yanked、非 prerelease、R10、非 assembly、review reason 無しを満たす
3. **実用性**: 固定 version を rubycc で試験ビルドできるか、失敗しても新しい再現可能な
   header / compiler gap を示す

この issue は先行 2 issue の完了を前提とする。評価前に期間や成功基準を固定し、結果を見てから
都合のよい window や候補を選ばない。

## 影響

候補件数だけを見て定期運用へ進むと、既知 gem の更新通知を大量に再確認するだけの仕組みや、
実際には corpus へ採用できない候補を生む仕組みを維持することになる。逆に、1 日だけ候補が
無かったことを理由に捨てると、低頻度だが新しい実需を拾う経路を過小評価する。

複数の固定 window と既存候補源を同じ規則で比較し、少数の候補を試験ビルドすれば、候補収率、
review 負荷、既存 corpus への増分価値を分けて判断できる。

## 受け入れ条件

- 実験結果を見る前に、実行日直前までに完了した UTC 7 日 window を新しい順に 4 個固定し、
  exact `from` / `to`、CLI、scanner revision を作業ログへ記録する
- 4 window の全 release 選択は `--selection-only` で網羅し、`.gem` の静的検査と試験ビルドは
  事前規則で選んだ最大 3 gem に限定する。1,000 gem 超を4 window分ダウンロードすることを
  「適切な評価」と取り違えず、全体の増分性と代表候補の適格性・実用性を分けて測る
- 同じ scanner revision で次を取得し、`corpus-candidate-artifact` の JSON と response hash を残す
  - 固定した 4 個の timeframe window
  - 比較対照となる rubygems.org popular 上位 100
  - 上位 100 を超える既存運用を比較する場合は、範囲と bestgems source を実験前に固定する
- version entry 数だけでなく、少なくとも次の値を window 別と合計で実測する
  - unique gem 数、既存 corpus 数、`[1]`、`[1b]`、`[2]`、review、`[E]`
  - source gem 不在、prerelease、yanked、重複で除外した数
  - API request 数と、人手確認が必要だった gem 数
- `[1]` 候補について、既存 corpus と対照 scan の候補名との差集合を出す。期間 source 固有の
  候補を、version 違いだけで別 gem と数えない
- 期間 source 固有の適格候補ごとに、現在の corpus 全体との差分として次を記録する
  - 新しい system header spelling と、新しい gap header spelling
  - extension directory、C/H file 数、R10 判定理由
  - 既存候補と同じ header 集合しか持たない場合も、その事実を省略しない
- 期間 source 固有の適格候補から最大 3 gem を、結果を見た後の恣意性を減らすため次の順で選ぶ
  1. 新しい gap header を持つ
  2. 新しい system header を持つ
  3. `created_at` が新しい
  4. gem 名の辞書順
- 選んだ各 gem は version と `platform=ruby` を固定し、一時 manifest / cache で次を実行する
  - `Corpus::Census` の R10・include 分析を再実行し、artifact の判定と一致するか確認する
  - `RUBYCC=1 gem install <name> -v <version> --platform ruby` 相当の試験ビルドを行う
  - 成功、既知制限による失敗、新しい再現可能な header / compiler gap、環境不足を区別する
- 「適切に増やせるか」を次の事前規則で決着する
  - **採用**: 4 window から期間 source 固有の適格候補が 1 件以上見つかり、そのうち 1 件以上が
    試験ビルド成功、または corpus に残す価値のある新しい再現可能な gap を示す
  - **条件付き採用**: 適格候補はあるが popular 対照との差分が無い、または全件が環境不足で
    実用性を判定できない。window、実行頻度、追加 filter の変更案を別 issue にする
  - **不採用**: 4 window に期間 source 固有の適格候補が無い、または試験対象がすべて
    既知情報の重複で corpus の増分を示さない。自動・定期運用へ進めない
- 数値、候補名、build 結果、採否と根拠を作業ログと `docs/development/STEPS.md` に記録する。
  推測値や、実行していない gem の build 可否を混ぜない
- 採用または条件付き採用で正式追加に進む場合、候補ごとに独立した corpus 追加 issue を作る。
  この評価 PR では `test/corpus/gems.rb` を変更しない
- test-runner に実験コマンドと全 `rake test` を委譲し、ネットワーク実験と hermetic suite の
  結果を分けて記録する

この PR では、次を受け入れ条件に含めない。

- 候補 gem の正式な corpus 追加
- header や compiler gap の修正
- gem 本体テストによる `data/verified_gems.json` への記録
- download 数・header 新規性・検証コストを合成した自動 score
- weekly CI や定期実行の導入

## 実装計画

1 ステップを 1 コミットとし、3 ステップで完了させる。

1. `corpus-candidate-evaluation-1`: 実験入力を固定し、対照 scan を収集する
   - 4 個の UTC window、popular 範囲、scanner revision、コマンドを結果を見る前に記録する
   - timeframe と popular の JSON artifact を生成し、分類別件数と差集合を集計する
2. `corpus-candidate-evaluation-2`: 増分候補を試験する
   - 事前規則で最大 3 gem を選び、Census 再判定と rubycc 試験ビルドを行う
   - build 成否だけでなく、新規 header / compiler gap と環境不足を分離して記録する
3. `corpus-candidate-evaluation-3`: 発見方法の採否を決着する
   - 事前規則に従って採用・条件付き採用・不採用を決める
   - STEPS、ROADMAP、issue を更新し、必要なら gem 単位または運用改善の follow-up issue を作る
   - test-runner に全 `rake test` を委譲する

## 批判的レビュー

- 4 window は実用性を調べる探索的評価であり、長期の候補収率や季節性を証明しない。
  採用となっても weekly CI の妥当性までは主張しない
- 「1 件以上」は統計的有意性ではなく、継続利用へ進む最低限の方針値である。件数を性能指標に
  見せず、増分候補の内容と試験結果を併記する
- 新しい gap が見つかることと、その header を rubycc へ追加すべきことは同義ではない。
  platform 分岐、host library、SIMD gate などを corpus-expansion の分類規則で別途確認する
- build 成功だけでは gem の正しさを証明しない。上流 test suite と sanity を伴う検証は
  corpus-expansion フェーズ 2 の別 issue で行う
- popular 上位 100 は完全な対照群ではない。期間 source の価値を「既存経路に対する増分」として
  評価するための運用上の baseline であり、RubyGems 全体との比較とは表現しない
- 候補が無い window を除外したり、候補選択順を結果確認後に変えたりすると評価が歪む。
  exact window と選択規則を最初のコミットで固定する

## 作業ログ

### 2026-08-16

期間 source の実装計画に 1 日の live scan は含まれていたが、それだけでは候補経路が動くことしか
確認できず、corpus を適切に増やせるかは検証できないとレビューした。

有効性評価を discovery PR に戻すと、CLI リファクタ、API 実装、複数期間のネットワーク実験、
試験ビルドが 1 PR に混在する。artifact が無い段階では入力差分と判定差分も区別できないため、
先行 2 issue の完了を依存条件とする独立 issue にした。評価は候補件数ではなく、増分性・適格性・
実用性の 3 軸で行い、結果が不採用でも測定と決着が完了していればこの issue は完了とする。

#### `corpus-candidate-evaluation-1`

実験結果を見る前に、対象期間を次の UTC 7 日 window へ固定した。いずれも半開区間で、同じ
scanner revision `corpus-candidate-evaluation-2`（commit `ac9f149a55036dd3057db67d643405734a331b47`）を
使う。比較対照は rubygems.org popular rank 1〜100 (`tools/scan_popular_gems.rb 1 10`) とする。

1. `2026-08-09T00:00:00Z` — `2026-08-16T00:00:00Z`
2. `2026-08-02T00:00:00Z` — `2026-08-09T00:00:00Z`
3. `2026-07-26T00:00:00Z` — `2026-08-02T00:00:00Z`
4. `2026-07-19T00:00:00Z` — `2026-07-26T00:00:00Z`

各 window は次の形で実行し、同じ `SCAN_WORK` の raw response / gem cache と artifact path を
保存する。結果を見る前に期間、対照範囲、候補選択順を変更しない。

```sh
SCAN_WORK=/path/to/window-work \
  ruby tools/scan_popular_gems.rb --source timeframe \
  --from FROM --to TO --artifact /path/to/artifact.json
SCAN_WORK=/path/to/popular-work \
  ruby tools/scan_popular_gems.rb 1 10 --artifact /path/to/popular.json
```

保存した artifact を `tools/summarize_corpus_candidate_artifacts.rb` で集計し、version entry 数、
unique gem 数、既存 corpus、分類、選択除外理由、API request 数を記録する。

4 window は各々 1,000 gem を超える規模になり得るため、全 release の pagination / v2 source
選択を `--selection-only` で走査し、gem archive の取得は静的検査・試験ビルドの最大3件へ
限定する。この二段階化は測定前に決めた資源上の境界であり、selection-only の `uninspected` を
`[1]` 候補と数えない。

#### `corpus-candidate-evaluation-2`

同じ scanner revision `ac9f149a55036dd3057db67d643405734a331b47` で、4 window と popular
rank 1〜100 を実行した。timeframe はページングと選定だけを測る `--selection-only` なので、
全選択 release の v2 `platform=ruby` / yanked 検証と archive fetch は静的サンプルへ延期した。
各 artifact の `source_requests` には URL、cache key、response SHA-256 を保存し、raw response
cache は再集計用に実験環境へ残した。

| window (UTC, 半開区間) | version entries | pages | unique gems | corpus `[3]` | `[1]` | `[1b]` | `[2]` | `[R]` | `[E]` | 新規 uninspected | API requests |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 08-09 — 08-16 | 2,954 | 100 | 1,355 | 4 | 0 | 0 | 0 | 0 | 33 | 1,318 | 100 |
| 08-02 — 08-09 | 3,245 | 110 | 1,541 | 4 | 0 | 0 | 0 | 0 | 37 | 1,500 | 110 |
| 07-26 — 08-02 | 3,192 | 108 | 1,334 | 4 | 0 | 0 | 0 | 0 | 25 | 1,305 | 108 |
| 07-19 — 07-26 | 3,438 | 116 | 1,417 | 1 | 0 | 0 | 0 | 0 | 68 | 1,348 | 116 |
| 合計 | 12,829 | 434 | 5,647 | 13 | 0 | 0 | 0 | 0 | 163 | 5,471 | 434 |

選定で除外した release entry は、duplicate release 5,409 件、prerelease 512 件、yanked
0 件だった。selection-only では v2 source/yanked 検証を実行していないため、source gem 不在・
yanked の全体値は未計測 (`deferred`) であり、`[E]` 163 件は「非 prerelease の候補 release を
選べなかった」選定エラーである。これは source gem が無いことの証明ではない。

対照の popular rank 1〜100 は 100 gem、API request 110、`[1]` 相当の status 7 件だったが、
7 件すべて既存 corpus で、新規 `[1]` は 0 件だった。`[2]` は nokogiri 1 件、`[R]` は grpc
1 件、既存 corpus の sqlite3 は `[2]` status、no-ext は 90 件だった。timeframe の
`uninspected` は全 window の名前 union が 3,889 件（うち既存 corpus 8、新規未検査 3,881 件）
で、popular の新規 `[1]` との差集合を「適格候補」とは数えない。前者は静的検査前の名前集合
だからである。

#### `corpus-candidate-evaluation-3`

候補選択規則を結果確認前に固定し、4 window の選定 union から `created_at` 降順、gem 名順で
最大3件を選んだ。selection-only では新しい gap / system header を観測できないため、実際の
tie-break は `created_at` と名前に進み、次を静的サンプルにした。

| gem | version | platform | static status | C/H | bundled/gap | SHA-256一致 | rubycc target build |
|---|---|---|---|---:|---|---|---|
| DhanHQ | 3.4.0 | ruby | no_ext | 0/0 | none/none | yes | not run (no C extension) |
| phronomy | 0.19.0 | ruby | no_ext | 0/0 | none/none | yes | not run (no C extension) |
| security | 0.2.0 | ruby | no_ext | 0/0 | none/none | yes | not run (no C extension) |

3件とも v2 metadata は HTTP 200、`platform=ruby`、`yanked=false` で、archive SHA は API
SHA と一致した。rubycc 自身の `gem build` と scratch GEM_HOME への install は成功したが、
対象3 gem は C extension が無いため、事前規則に従って `RUBYCC=1 gem install` 相当の C 拡張
build 対象から除外した。新規 extension、header、gap、review reason は 0 件である。

ネットワーク実験には再試行も記録した。07-26 window は page 9 の `Net::OpenTimeout` 後に
retry-1 が完了し、07-19 window は初回 DNS failure、retry-1 の page 99 `ENETUNREACH` 後に
retry-2 が完了した。成功 artifact は固定名へ正規化して保存し、失敗試行を成功として数えない。

この結果、現在の bounded 実装を corpus へ増やす自動・定期経路としては **不採用** とする。
理由は、観測された期間 source 固有の静的 `[1]` が 0 件、popular 対照の新規 `[1]` も 0 件、
静的サンプル3件もすべて no-ext で、実用的な build 成功・新規 gap・review 解消を1件も示さな
かったためである。なお、3,881 件の未検査名がすべて純 Ruby だと結論したわけではない。
selection-only のままでは source/yanked と archive の適格性を全件確認できず、この不確実性を
含む状態で「適切に増やせる」とは判定できない。追加の metadata prefilter か、より大きな
事前固定静的サンプルを設計する follow-up が必要であり、今回の PR では corpus を変更しない。

## 決着

**不採用（現行 bounded route の自動・定期運用）**。

- 4 window の選定・除外・request provenance と popular 対照を保存した
- selection-only の `uninspected` と静的 `[1]` を分離して集計した
- 最大3件の固定静的サンプルはすべて no-ext、new header/gap/review は 0 件だった
- `test/corpus/gems.rb`、header、compiler gap、`data/verified_gems.json` は変更していない
- source/yanked の全件検証は deferred であり、未検査 3,881 件の不存在を主張しない
- 最終 test-runner の `rake test` は 3,242 runs / 11,549 assertions / 41 skips / 0 failures / 0 errors で終了した
