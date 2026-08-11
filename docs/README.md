# ドキュメントの置き場所と書き方

## 2 つのディレクトリ

**読み手が違う文書を混ぜない。** 混ぜると、利用者が開発の途中経過を仕様と読み違え、
開発者が「現在値」を探して 1 万行の作業ログを遡ることになる。

| ディレクトリ | 読み手 | 中身 | 古くなったら |
|---|---|---|---|
| [`reference/`](reference/) | **利用者**(rubycc でビルドする人) | **現時点**の仕様・対応範囲・制限・由来 | **直す**。過去の記述は残さない |
| [`development/`](development/) | **開発者**(この処理系を作る人) | 作業ログ・調査記録・計画・レビュー | **残す**。日付を添えて、現在値の在処を指す |

判断に迷ったら、次の問いで分ける。

> **その文書は「いま何ができるか」を答えるか、「どうやってそこに至ったか」を答えるか。**

前者は `reference/`、後者は `development/`。**両方を答える文書は分割する**か、
`reference/` 側に事実だけを置いて `development/` の記録へリンクする。

## 事実と判断を分ける

**同じ段落に混ぜない。** どちらも必要だが、混ざると読み手が検証できなくなる。

- **事実**: 測った値、観測した挙動、実行したコマンドとその出力。**いつ・どこで測ったか**を
  添える(「2026-08-12、glibc x86-64 / Ruby 3.4.5 で 3,109 runs / 0 failures」)。
- **判断**: 許容する/しない、優先順位、設計の選択、見立て。**なぜそう決めたか**を書く。
  「速い」「十分」のような評価語は、根拠の数値と併記されていなければ判断であって事実ではない。

`reference/` は**事実を主**にする。制限を書くときは、それが**測定されたもの**か
**仕様上そうなっている**のかを区別する。判断(「v1.0 では許容する」など)は
`development/` に置き、必要ならリンクする。

`development/` は判断を書いてよい — むしろそれが価値である。ただし
**事実と判断が同じ文に混ざらないように**書く。

## 生成物は手で編集しない

`reference/`・`development/` には生成物が混ざる(`development/R10-CORPUS-SCAN.md` など)。
冒頭に **Generated artifact** と再生成コマンドを持つ文書は、**必ず再生成して更新する**。
手で直すと、次の再生成で黙って消える。

**現在値が欲しいときは、生成物を見る。** 散文に書き写した数値は必ず古くなる — 実際、
R10 の合格率は 3 つの文書に書き写されていて、そのうち 2 つが古かった
(`docs-audience-split-1` で是正)。

## 索引

### `reference/` — 利用者向け(現時点の仕様)

| 文書 | 内容 |
|---|---|
| [C11-COVERAGE.md](reference/C11-COVERAGE.md) | ISO C11(N1570)の条項別の対応状況 |
| [GCC-EXTENSIONS.md](reference/GCC-EXTENSIONS.md) | 実装した GCC 拡張と、その実装の程度 |
| [OUT-OF-SCOPE-GEMS.md](reference/OUT-OF-SCOPE-GEMS.md) | 対応しないと判断した gem と、その根拠 |
| [HEADER-LICENSING.md](reference/HEADER-LICENSING.md) | 同梱ヘッダの由来台帳(再配布の判断に要る) |

利用者向けの入口は**リポジトリ直下の [README.md](../README.md)** で、対応範囲・既知の制限・
動作要件はそちらに要約がある。上の 4 文書はその詳細である。

### `development/` — 開発者向け(作業ログ・計画・調査)

| 文書 | 内容 |
|---|---|
| [DESIGN.md](development/DESIGN.md) | 要件(R1〜R11・N1〜N7)とアーキテクチャ選定の根拠 |
| [ROADMAP.md](development/ROADMAP.md) | 現在地・実装規約と不変条件・既知の負債・今後の計画 |
| [STEPS.md](development/STEPS.md) | 完了したステップの設計判断と実測(作業ログの本体) |
| [GAPS.md](development/GAPS.md) | **未解消**のギャップ(解消したら消し、経緯は STEPS へ) |
| [IR.md](development/IR.md) | 中間表現の仕様(命令一覧・値表現規約) |
| [CI.md](development/CI.md) | CI の三層構成と、各層が何を保証するか |
| [TEST-PLAN.md](development/TEST-PLAN.md) / [TEST-REVIEW.md](development/TEST-REVIEW.md) | テスト計画と、その批判的レビューの記録 |
| [BENCHMARKS.md](development/BENCHMARKS.md) / [THROUGHPUT.md](development/THROUGHPUT.md) | 実行速度・コンパイル速度の実測記録と方法論 |
| [RELEASE-CHECKLIST.md](development/RELEASE-CHECKLIST.md) | v1.0 の非機能要件チェックリストとリリース手順 |
| [R10-CORPUS-SCAN.md](development/R10-CORPUS-SCAN.md) | **生成物**。コーパスの機械ゲートと provenance |
| [R10-MANUAL-CLASSIFICATION.md](development/R10-MANUAL-CLASSIFICATION.md) | **生成物**。R10 の手動分類台帳 |
| [VARIADIC-SCAN.md](development/VARIADIC-SCAN.md) | 可変長引数の候補スキャンの記録 |
| [security-dos-review.md](development/security-dos-review.md) | DoS フェイルセーフの設計と上限値の根拠 |

ベンチマークを `development/` に置いているのは、**方法論と再現手順が主**で、利用者が知りたい
数値(コンパイル速度・生成コードの速度)は README の「既知の制限」に要約があるためである。
