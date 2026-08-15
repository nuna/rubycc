---
status: in-progress
kind: infra
opened: 2026-08-16
closed:
branch: corpus-candidate-discovery
pr:
steps:
  - corpus-candidate-discovery-1
  - corpus-candidate-discovery-2
  - corpus-candidate-discovery-3
---

# RubyGems の更新履歴から、census 候補になる C 拡張 gem を発見する

## 課題

2026-08-16 時点の corpus は 39 gem、R10 machine gate の分母は 34 gem である
(`README.md`、一次情報は `test/corpus/include-census.md`)。候補は次の 3 系統から選ばれている。

- Ruby 4.0.6 の default / bundled C 拡張 gem
- rubygems.org の popular 上位 100 gem の全走査
- C 拡張を持つことが既知の候補から、2026-07-29 時点の累積 download 数
  100,000,000 以上を選んだリスト

人気ランキングから `.gem` を取得し、実 gemspec の `extensions`、C++、
configure / mini_portile、アセンブリ要否を検査する手順は
`tools/scan_popular_gems.rb` として機械化済みである。R10 gate は
`test/corpus/census.rb` に委譲し、アセンブリは `.S` / `.s` の走査と
`$objs` に対応する `.c` が無いケースの 2 系統で検出する。

ただし現在の候補源は累積人気に偏っている。新しく公開された gem や、最近 C 拡張を
追加した gem は、累積 download 数が閾値へ届くまで候補にならない。

RubyGems.org の公式 API は、指定期間に追加された version を列挙する
`/api/v1/timeframe_versions.json` を提供している。期間は最大 7 日で結果は page 単位なので、
明示した `from` / `to` と全 page を入力にすれば、週ごとの新規・更新 gem を人気順位とは
独立に収集できる。一方、文書化された timeframe response には `yanked` が無いため、
候補確定には v2 version API で source gem の存在と yanked 状態を別途確認する必要がある。

この issue は期間指定 source の導入と、通信・分類経路が動くことの smoke test だけを扱う。
決定的 JSON、入力の provenance、未宣言 native source、`ext/` 外 extension、include header の
分析は [corpus-candidate-artifact](corpus-candidate-artifact.md) に分離する。その artifact を使って
この発見方法が corpus を適切に増やせるか判断する実験は、
[corpus-candidate-evaluation](corpus-candidate-evaluation.md) で行う。

## 影響

累積人気だけで corpus を拡張すると、長く使われている同型の拡張へ偏りやすく、
新しいヘッダ面・mkmf の形・生成 C・システムライブラリ依存を早期に見つけられない。
その結果、「実 gem で実害が出た項目を優先する」という corpus 駆動の入力が古くなる。

発見した gem を自動で `test/corpus/gems.rb` に追加してはいけない。追加は R10 の分母を変え、
version の固定理由、手動除外、上流テストの有無、検証レシピまで責任を持つ操作である。
この課題で自動化するのは**候補の収集と既存の人間向け分類まで**とし、正式追加は
`.claude/skills/corpus-expansion/SKILL.md` の既存フローに残す。

## 受け入れ条件

- `tools/scan_popular_gems.rb` を `require` しても ARGV の解釈、HTTP 通信、`exit` が起きず、
  fixture と偽 HTTP client で source と inspector をテストできる
- 既存の位置引数 `[first_page] [last_page]`、環境変数、終了 status、
  `[0]` / `[1]` / `[1b]` / `[2]` / `[3]` / `[E]` の意味を維持する
- `--source timeframe --from YYYY-MM-DD --to YYYY-MM-DD` で期間指定できる
  - CLI の期間は UTC の半開区間 `[from 00:00, to 00:00)` とする
  - `from < to` でない指定と 7 日を超える指定は API へ送る前に拒否する
  - page が空になるまで取得し、response が配列でない、必須 key が無い、同じ page が
    反復する場合は、黙って打ち切らずエラーにする
- API entry を `name` / `version` / `platform` / `created_at` と出所を持つ内部 record へ
  正規化する。同じ gem 名は次の規則で 1 件へ畳み、除外した release と理由も人間向け出力に残す
  1. prerelease を通常候補から除く
  2. `created_at` の新しい順、同値なら `Gem::Version` の大きい順に調べる
  3. v2 version API で `platform=ruby` の同 version が存在し、yanked でない最初の release を選ぶ
  4. source gem を選べない gem は黙って捨てず、理由付きで `[E]` または専用の非候補欄へ出す
- 選んだ release は version と `platform=ruby` を固定して取得する。取得した gemspec の
  name / version / platform が選択結果と一致しない場合は検査せずエラーにする
- R10 判定は引き続き `Corpus::Census` に委譲し、スキャナ内へ複製しない
- timeframe API、pagination、重複、prerelease、yanked、native-platform-only、取得物の
  spec 不一致を fixture で検証する hermetic test を追加する。`rake test` はネットワークへ
  接続せず 0 failures である
- 完了済みの UTC 1 日分を 1 回 live scan し、取得 version 数、重複排除後の gem 数、
  C 拡張候補数、各除外数、API request 数を作業ログと `docs/development/STEPS.md` に実測で記録する。
  これは通信・pagination・分類経路の smoke test であり、候補発見方法の有効性の証明とは扱わない
- `test/corpus/README.md` と `.claude/skills/corpus-expansion/SKILL.md` に期間指定モードと、
  「候補発見は正式追加ではない」という境界を反映する

この PR では、次を受け入れ条件に含めない。

- JSON 出力、raw API response の保存や hash、`.gem` の SHA-256 記録
- gemspec で未宣言の native source と `ext/` 外 extension の新しい review 分類
- system header、rubycc に未同梱の header、C/H file 数の追加分析
- 複数期間と既存候補源を比較し、corpus を適切に増やせるか判定する評価実験
- reverse dependencies や実アプリの `Gemfile.lock` を新しい候補源にすること
- download 数・header 新規性・検証コストへ重みを付けた自動 score / set-cover 選択
- 候補走査を weekly CI に追加すること
- 発見した gem の `test/corpus/gems.rb` への追加、header 実装、gem 本体テスト、
  `data/verified_gems.json` の更新

## 実装計画

1 ステップを 1 コミットとし、3 ステップで完了させる。

1. `corpus-candidate-discovery-1`: scanner の library / CLI 境界を分離する
   - option parsing、HTTP、cache、main の依存を注入可能にする
   - require 時に副作用が無いことと既存 rank mode の互換性をテストする
2. `corpus-candidate-discovery-2`: timeframe source と正確な release 選択を追加する
   - UTC 期間検証、pagination guard、entry 正規化、重複排除を実装する
   - v2 による source / yanked 確認と、version 固定 fetch / gemspec 照合を実装する
   - API と gem を fixture 化し、異常系を含む hermetic test を追加する
3. `corpus-candidate-discovery-3`: live scan と利用手順を確定する
   - test-runner に hermetic test、全 `rake test`、完了済み UTC 1 日の live scan を委譲する
   - 実測値と設計判断を STEPS に記録し、README、skill、ROADMAP、issue を更新する

## 批判的レビュー

- RubyGems API v1/v2 は変更されうる外部境界である。成功 response でも schema を検証し、
  不明な欠落を「候補なし」に変換してはならない
- timeframe response だけでは yanked を判定できない。v2 確認を省く実装は受け入れない
- `tools/scan_popular_gems.rb` は現在トップレベル実行と通信が密結合している。source 追加と
  同時に場当たり的な stub を置かず、最初のステップで副作用の境界を作る
- 1 日の live scan の件数は API の将来状態で変わり、季節性もあるため、発見方法の有効性は
  判定できない。ここでは欠落なく走査した根拠だけを成功条件にし、複数期間の対照評価は
  `corpus-candidate-evaluation.md` に委ねる
- この issue の human-readable report は日をまたいだ機械比較を解決しない。それは既知の
  制約として後続 issue で解決し、ここへ JSON 設計を戻さない

## 作業ログ

### 2026-08-16

人気ランキング以外の候補源として、default / bundled gems、RubyGems の activity、
reverse dependencies、実アプリの lockfile を比較した。

初回実装には `activity/latest` / `activity/just_updated` ではなく、期間と pagination を
入力として固定できる `timeframe_versions` を選んだ。前者は直近 50 件の窓なので、更新が
多い期間に取りこぼした事実を検出できない。後者も最大 7 日という制限はあるが、週次 window と
全 page を明示できる。

当初は期間 source、決定的 JSON、native source の追加診断、Census include 分析を 1 issue に
含めていた。批判的レビューの結果、CLI リファクタを含めると半日・1〜4コミットの目安を
超える可能性が高いと判断した。候補収集経路を先に完成できるよう、この issue を
3 ステップへ絞り、artifact と高度な診断を `corpus-candidate-artifact.md` へ分割した。

さらに、1 日の live scan だけでは「候補が返る」ことしか確認できず、既存 corpus に対する
増分価値を判定できないというレビューを反映した。発見方法の採否は、artifact 完成後に複数の
固定 window、既存 popular source、試験ビルドを比較する `corpus-candidate-evaluation.md` で決める。

外部 API の仕様根拠:

- <https://guides.rubygems.org/rubygems-org-api/>
- <https://guides.rubygems.org/rubygems-org-rate-limits/>

#### `corpus-candidate-discovery-1`

scanner を require 可能な library / CLI 境界へ分離した。HTTP client、sleep、出力先、
cache を注入でき、従来の rank source と終了 status は維持した。

#### `corpus-candidate-discovery-2`

timeframe source、全 page 走査、同一 page の反復検出、prerelease / yanked / native-platform-only
の除外、v2 の `platform=ruby` 確認、version 固定 fetch と gemspec 照合を実装した。
fixture を使う hermetic test で API schema、pagination、release 選択、不一致を検証した。

#### `corpus-candidate-discovery-3`

対象期間 `2026-08-15T00:00:00Z` ～ `2026-08-16T00:00:00Z` を live scan した。

- timeframe API: 7 page、153 version
- 重複排除後: 114 gem
- gem fetch: 109 試行 / 109 成功
- 分類: `[1]` 8、`[1b]` 0、`[2]` 0、`[3]` 0、`[E]` 5、`[0]` 0
- `[1]`候補: `atomic-ruby`, `classifier`, `hx_ruby`, `ironpress`, `page_print`, `pgn2`, `udb`, `wreq`
- 直接 API request: timeframe 7 + v2 114 = 121

初回実行では、RubyGems が read-only な HOME 配下の compact-index cache を使おうとして
全 fetch が失敗した。この環境依存を再現可能な失敗として扱い、`Corpus::Census.fetch_gem`
が `SCAN_WORK/gem_spec_cache` を `GEM_SPEC_CACHE` に設定するよう修正した。再実行では
指定した writable work directory 内に spec cache 110 ファイルと `.gem` 109 ファイルが
生成され、終了 status 0 になった。候補を `test/corpus/gems.rb` へ自動追加していないため、
この smoke test は「候補経路が走査・分類できる」ことのみを示し、corpus を適切に増やせる
ことの証明や正式追加の決定とはしない。

## 決着

実装ブランチで A1〜A3 と live smoke test まで完了。PR 作成後、planning issue の
`corpus-candidate-issues` への積み上げレビュー待ち。PR が master に取り込まれるまでは
issue を `done` にしない。
