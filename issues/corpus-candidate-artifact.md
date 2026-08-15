---
status: open
kind: infra
opened: 2026-08-16
closed:
branch:
pr:
steps: []
---

# census 候補スキャンを再現可能な artifact として保存し、静的診断を強化する

## 課題

[corpus-candidate-discovery](corpus-candidate-discovery.md) は、RubyGems の期間指定 API から
候補 release を収集し、既存の人間向け分類へ流す経路を追加する。しかし人間向け表だけでは、
異なる日の結果や選択根拠を機械的に比較できない。download 数を含む API response は後から
変化しうるため、「同じ期間を再取得した」だけでも byte 単位の同一結果は保証できない。

静的検査にも、候補発見時に明示すべき境界が 2 つある。

1. gemspec の `extensions` が空なら現状は直ちに `no_ext` とする。`.gem` 内に
   `extconf.rb` や C/C++ source がある場合まで「C 拡張なし」と断定すると調査対象を失う
2. gemspec の `extensions` が `ext/` 外を指す場合、現状は note を付けるだけで R10 gate を
   続行する。しかし `test/corpus/census.rb` の source / C++ / extconf / include 走査は
   `ext/` 配下だけなので、その結果を通常の `[1]` 候補と同じ強さでは扱えない

この issue は `corpus-candidate-discovery` の完了を前提とする。期間 source 自体、release の
選択規則、既存 rank mode の互換性は先行 issue の責務とし、ここでは変更しない。完成した
artifact を使った発見方法の有効性評価は、後続の
[corpus-candidate-evaluation](corpus-candidate-evaluation.md) で行う。

## 影響

入力 response と取得物を識別できない候補一覧は、後日差分が出ても「RubyGems 側が変わった」
のか「scanner の判定が変わった」のか区別できない。また、走査範囲外の gem を通常候補へ混ぜると、
R10 gate を通過したという表示が実際より強い証拠に見える。

再現可能な JSON と review reason を追加すれば、候補の増減を入力と判定のどちらに由来するか
追跡できる。ただし artifact は調査材料であり、`test/corpus/gems.rb` や
`data/verified_gems.json` を自動編集する権限は持たせない。

## 受け入れ条件

- `tools/scan_popular_gems.rb` に schema version 付き JSON 出力を追加し、少なくとも次を記録する
  - source 名、正規化済み CLI 入力、source request、raw response の SHA-256
  - gem 名、version、platform、download 情報、選択・除外理由
  - `.gem` の SHA-256と、API が SHA を返す場合の照合結果
  - gemspec の `extensions` と `ext/` 外の extension directory
  - corpus 収載済みか、判定 status、machine-readable な reason、C/H file 数
  - 検出した system header と rubycc に未同梱の header
- JSON の決定性は「同じ正規化済み CLI 入力、保存済み raw response、`.gem`」を境界とする
  - key 順と record 順を固定する
  - 走査時刻や一時 directory の絶対 path を混ぜない
  - raw response を再利用可能な単位で cache し、内容 hash を artifact へ記録する
- API が提供する SHA-256 と取得した `.gem` の SHA-256 が一致しない場合は、note ではなく
  hard error とし、その gem の静的判定を信用しない
- gemspec の `extensions` が空でも archive 内に `extconf.rb` または C/C++ source があれば、
  `no_ext` と断定せず `undeclared_native_source` の review reason へ分離する
- `extensions` が `ext/` 外を指す gem は `extension_outside_census_root` の review reason とし、
  通常の `[1]` に入れない。既存の `[1b]` はアセンブリ専用という意味を維持する
- `Corpus::Census` の include 分類 loop を、source file 一覧と bundled header set を入力に取る
  副作用のない helper へ抽出し、scanner はその helper を利用する。R10 規則を複製しない
- popular / known / timeframe の各 source で同じ JSON schema を使い、source 固有で値が無い欄は
  schema 上の扱いを明示する
- fixture と golden file で key / record 順、raw response hash、SHA mismatch、
  undeclared native source、`ext/` 外 extension、system / gap header を検証する。
  `rake test` はネットワークへ接続せず 0 failures である
- 保存済み fixture を 2 回処理した JSON が byte 単位で一致することをテストする
- `test/corpus/README.md` と `.claude/skills/corpus-expansion/SKILL.md` に JSON の再生方法、
  review reason、「artifact は正式追加ではない」という境界を反映する

この PR では、次を受け入れ条件に含めない。

- `Corpus::Census` の走査 root を `ext/` 外へ拡張すること
- review 対象を自動で corpus に採用・除外すること
- 候補を download 数や header 新規性で自動採点すること
- weekly CI、artifact upload、保存期間の運用を追加すること
- 複数期間の候補収率、既存候補源との差分、試験ビルドから発見方法の採否を決めること
- `test/corpus/gems.rb`、header、gem 本体テスト、`data/verified_gems.json` の更新

## 実装計画

先行 issue の完了後、1 ステップを 1 コミットとして 3 ステップで完了させる。

1. `corpus-candidate-artifact-1`: JSON schema と入力 provenance を実装する
   - raw response cache、内容 hash、gem SHA、安定 sort、schema version を追加する
   - fixture の再生と byte 単位の決定性を golden test で固定する
2. `corpus-candidate-artifact-2`: review 分類と Census の静的分析を共通化する
   - undeclared native source と `ext/` 外 extension を通常候補から分離する
   - include 分類を純粋 helper に抽出し、C/H 件数、system / gap header を JSON へ追加する
   - `[1b]` と既存 R10 status の意味が変わらないことを回帰テストする
3. `corpus-candidate-artifact-3`: 全 source の回帰確認と利用手順を確定する
   - test-runner に golden test と全 `rake test` を委譲する
   - popular / known / timeframe の fixture で schema の共通性を確認する
   - 設計判断を STEPS に記録し、README、skill、ROADMAP、issue を更新する

## 批判的レビュー

- 「同じ期間なら同じ JSON」は成立しない。download 数や yanked 状態が変化するため、
  決定性の境界を保存済み raw response と `.gem` まで含める
- header 分析を scanner に再実装すると Census と規則がずれる。共有するのは副作用のない
  分類 helper に限定し、fetch や report 全体を無理に共通化しない
- `extensions` が空でも native file があることは「Ruby C extension である」証明ではない。
  自動候補へ昇格せず、人間が調べる review reason に留める
- `ext/` 外を Census の対象へ広げるには C++ / configure / include の全 gate を同じ root へ
  適用する設計が必要である。この issue では誤って通常候補にしないところまでに留める
- raw response cache は再現性を上げる一方で古い download 数を現在値に見せる危険がある。
  artifact には request と response hash を必須とし、cache の値を「最新」と表示しない
- JSON schema と診断共通化を同時に進めるため、3 ステップでも半日を超えると判明した時点で、
  診断部分をさらに独立 issue へ分ける
- JSON が決定的であることは候補源が有効であることを意味しない。候補の増分価値と導入可能性は、
  この PR の成功条件へ混ぜず、後続の対照評価と試験ビルドで判断する

## 作業ログ

### 2026-08-16

`corpus-candidate-discovery.md` の実装計画を批判的にレビューした。CLI の副作用分離、期間 API、
JSON provenance、未宣言 native source、Census include 分析までを 1 PR に入れると、
1〜4コミット・半日以内という issue 粒度を超える可能性が高い。

候補 source の有効性は JSON が無くても人間向け出力と live scan で先に測れるため、期間 source を
先行 issue に残し、機械比較と診断精度をこの後続 issue へ移した。特に yanked 確認は release
選択の正しさに必要なので先行側、raw response hash と決定的出力は比較可能性の問題なので
後続側、と責務を分けた。

artifact 自体の正しさと、発見方法が corpus を適切に増やせるかは別の問いである。後者を
`corpus-candidate-evaluation.md` へ分け、固定した複数 window、popular baseline、試験ビルドで
採用・条件付き採用・不採用を決める計画にした。

## 決着

(未着手)
