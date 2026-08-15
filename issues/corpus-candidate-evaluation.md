---
status: open
kind: infra
opened: 2026-08-16
closed:
branch:
pr:
steps: []
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

## 決着

(未着手)
