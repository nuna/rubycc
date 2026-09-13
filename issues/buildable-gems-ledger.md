---
status: done
kind: infra
opened: 2026-09-12
closed: 2026-09-12
branch: buildable-gems-ledger
pr: 139
steps: [buildable-gems-ledger-1]
---

# 「ビルドできる」を、R10 の分母を壊さずに数える台帳

## 課題

ユーザ指示は「**ビルドできる gem を 100 件まで増やす**」である(2026-09-12)。
**いまの仕組みでは、これをそのまま実行すると R10 が壊れる。**

合格率の分母は「`test/corpus/gems.rb` にあってゲートを通った gem」で自動的に決まり、
分子は「`data/verified_gems.json` に (d) 水準の記録がある gem」である。
DESIGN R10 の目標は件数ではなく**率**で、**コーパスの 90% 以上が
「gem install 成功かつ各 gem 自身のテストスイートに合格」**であることを要求する。

| | 分母 | 分子 | 率 |
|---|---|---|---|
| 現状(2026-09-12) | 35 | 33 | 94.3% |
| **100 件を `gems.rb` に足して検証しない場合** | 94 | 33 | **35%** |
| 100 件で R10 を満たす場合 | 100 | **90** | 90% |

しかも「**合格率の低下は破壊的変更**」がこのプロジェクトの独自規則である
(README / CHANGELOG の冒頭)。**「ビルドできる」と「コーパスに入れる」を
同じ操作にしてはいけない。**

**費用も 1 桁違う**(2026-09-12 実測):

| 水準 | 内容 | 1 件あたり |
|---|---|---|
| build_load | install して `.so` がロードできる。`tools/verify_corpus_candidate.rb` がほぼ自動 | **1〜2 分** |
| (d) | 上流テストスイートの合格。レシピを書いて実走する | **20〜40 分**(`bindex` は minitest のピン特定で 3 回やり直した) |

## 影響

ユーザ判断は **A + C**(2026-09-12):

- **A**: コーパス(`gems.rb` = R10 の分母)に入れるものは**これまでどおり (d) 水準**
- **C**: 「ビルドできる」は**別の台帳**に持つ

この issue は C の器を作る。器が無いと、build_load まで通った gem の記録先が
**`gems.rb` しかなく、足した瞬間に分母が増える**。

## 受け入れ条件

- `data/buildable_gems.json` があり、**`data/verified_gems.json` と同じ入れ子構造**
  (1 gem = 1 エントリ、環境ごとの記録がその内側、`versions` / `environment` /
  `verified_at` / `evidence`)を持つ
- **ツールだけが書く**(手で編集しない)。`tools/verify_corpus_candidate.rb` の
  `build_load` 成功結果から追記できること
- **R10 の分母・分子に影響しない**ことがテストで固定されている
  (`test/corpus/include-census.md` の生成と `data/verified_gems.json` の読み取りが、
  この新しいファイルを一切参照しないこと)
- **主張の強さが混ざらないことがテストで固定されている** — この台帳の `evidence` は
  build_load 水準の事実だけを書き、「**テストスイートが合格した**」とは書かない。
  (d) 水準の主張は `verified_gems.json` にしか置けない
- `data/README.md` に 2 つの台帳の違い(何を証拠として受け付けるか)が書かれている
- `rubycc-doctor` が新しい台帳を読む場合、**(d) と build_load を区別して**表示する

## 着手前に確かめること

- **(d) 水準の gem も build_load は通っている。** 両方の台帳に載ることを許すか、
  `verified_gems.json` にあるものは除くかを決める。**許す方が素直**だと思われる —
  「安い証拠」と「高い証拠」は別の事実であり、後者があるからといって前者の記録が
  嘘になるわけではない
- **この台帳は「対象外」の置き場ではない。** ビルドできないと分かった gem は
  [OUT-OF-SCOPE-GEMS.md](../docs/reference/OUT-OF-SCOPE-GEMS.md) に基準つきで書く

## 作業ログ

### 2026-09-12(起票)

「ビルドできる gem を 100 件」の指示を受けて、いまの仕組みのまま進めると何が壊れるかを
数えたところ起票が必要になった。上の率の表はその計算である。

## 決着

**器を作った**(`buildable-gems-ledger-1`。設計判断の本文は
[STEPS.md](../docs/development/STEPS.md) の該当節)。**中身は空のまま入れた** —
器と中身を別の変更に分けるためで、記録は次の作業から始まる。

| 条件 | 結果 |
|---|---|
| `verified_gems.json` と同じ入れ子構造 | 同じ。ただし配列のキーは **`builds`**(主張が違うものに同じ名前を使わない) |
| ツールだけが書く | `tools/verify_corpus_candidate.rb --update`。**`build_load_pass` かつ `rubycc_build_evidence: pass`** のときだけ |
| R10 の分母・分子に影響しない | センサス生成と doctor の入力に現れないことを経路で検査。**census に読み込みを 1 行足すと落ちる**ことまで確認 |
| 主張の強さが混ざらない | `builds` の `evidence` に「テストスイート合格」系の語が現れないことをテストで固定 |
| `data/README.md` に 2 つの台帳の違い | 冒頭に比較表、末尾に schema 節 |

**着手前に確かめることの 2 点**: (d) 水準の gem も両方の台帳に載ってよい(安い証拠と高い証拠は
別の事実である)。ビルドできないと分かった gem は引き続き
[OUT-OF-SCOPE-GEMS.md](../docs/reference/OUT-OF-SCOPE-GEMS.md) に基準つきで書く。
