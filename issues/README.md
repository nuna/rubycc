# 作業課題(issues/)

**1 課題 = 1 ファイル = 1 PR。** 課題の内容・作業ログ・状態を 1 か所にまとめる。

## なぜ分けるのか

これまで未消化の作業は 4 か所に散っていた — `docs/development/GAPS.md`(未解消ギャップ)、
`ROADMAP.md`(計画)、`TEST-PLAN.md`(テストの未着手項目)、
`security-dos-review.md`(今後の課題)。どれも**文書の主題のついで**に課題を抱えていて、
**状態を持たない**ので、終わっても消し込まれずに残る。実測でそうなっていた:
`ROADMAP.md` の現在地は M4 完了後も「残項目」を掲げ、`RELEASE-CHECKLIST.md` は
3 か所が古い数値のままだった(`docs-audience-split-1`)。

`docs/` との境界は読み手で決まる(`docs/README.md`)。`issues/` はその第 3 の軸 —
**時間**である。

| 置き場 | 答える問い |
|---|---|
| `docs/reference/` | いま何ができるか |
| `docs/development/` | どうやってそこに至ったか |
| **`issues/`** | **いま何が終わっていないか、そして誰が何をどこまでやったか** |

## ファイルの構造

### 名前

`issues/<slug>.md`。`<slug>` は英小文字・数字・ハイフンで、**着手時のブランチ名と一致させる**
(ステップ ID が `<ブランチ名>-<連番>` なので、課題・ブランチ・ステップ・PR が 1 本の線で繋がる)。

**連番は使わない。** 並行作業で 2 回衝突した実績があり、ステップ ID の採番方式を
変えた理由でもある(`docs/development/STEPS.md` 冒頭)。

### 先頭の front matter(機械が読む)

```yaml
---
status: open          # open | in-progress | done | dropped
kind: gap             # gap | debt | feature | infra | docs
opened: 2026-08-12    # YYYY-MM-DD
closed:               # done / dropped のとき必須
branch:               # 着手したブランチ(in-progress 以降)
pr:                   # 完了 PR 番号(done のとき必須)
steps: []             # 対応する STEPS のステップ ID(複数可)
---
```

`status` の意味を固定する。**「終わったのに open のまま」を防ぐのがこの欄の全目的**である。

| status | 意味 |
|---|---|
| `open` | 誰も着手していない |
| `in-progress` | ブランチが切られている(`branch` 必須) |
| `done` | master に入った(`closed` と `pr` が必須。**PR を伴わない作業は `pr: none`** とし、決着節に何をもって完了としたかを書く — タグ push や `gem push` のようにリポジトリを変更しない操作がこれにあたる) |
| `dropped` | やらないと決めた。**理由を本文に残す**(消さない) |

### 本文の節

```markdown
# <題名。何を達成するかを 1 行で>

## 課題
事実を先に書く。測定値・最小再現・エラー出力。いつ・どこで測ったかを添える。

## 影響
誰が困るか。放置した場合に何が起きるか。ここは判断を書いてよいが、事実と混ぜない。

## 受け入れ条件
何が真になれば閉じるか。**検証可能な形で**書く(「テストが通る」ではなく
「`test/test_x.rb` が 0 failures で、gcc 対照と一致する」)。

## 作業ログ
日付ごとに追記する。**行き止まりも残す** — 次の人が同じ道を試すのを防ぐのが半分の価値。

## 決着
結果と、`docs/development/STEPS.md` の該当エントリへのリンク。
**設計判断の本文をここに書かない**(STEPS が本体。二重管理を作らない)。
```

## 粒度

**1 PR に収まること。** 収まらないと分かった時点で分割し、親には子へのリンクだけ残して
`dropped` ではなく `done`(分割で解消)にする。

「1 PR」の目安は、このリポジトリの実績で **1〜4 コミット、テストを含めて半日以内**である。
`gaps-s-t-u`(3 ステップ)は上限に近く、本来は 3 つの課題に分けるべきだった。

## 二重管理を作らない

- **設計判断は STEPS**、課題の状態は issues。issue の「決着」節は STEPS を指すだけにする
- **未解消ギャップは `GAPS.md`** が 1 行 1 件の索引であり続ける。`kind: gap` の issue は
  GAPS の該当行から**リンクされる**(逆は書かない)
- 現在値(合格率・件数)は**生成物を見る**。issue に書き写した数値は、書いた日付を添える

## 索引

`issues/` の一覧は `ls` で足りるので、索引ファイルは作らない
(`docs/README.md` のような索引は、更新漏れが起きる分だけ損になる)。
状態で絞るときは front matter を読む:

```sh
grep -l "^status: open" issues/*.md | grep -vE "(README|TEMPLATE)\.md"
```

(この 2 ファイルを除くのは、規約と雛形自身が front matter の書式を含むためである。
`test/test_issue_docs.rb` も同じ 2 件を対象外にしている。)

`test/test_issue_docs.rb` が、front matter の必須項目・`status` の語彙・
状態と項目の整合(`done` なら `pr` と `closed` がある、など)・本文の節の存在を検査する。
