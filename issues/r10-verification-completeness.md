---
status: open
kind: debt
opened: 2026-08-12
closed:
branch:
pr:
steps: []
---

# R10 台帳の証拠を実測で埋め、第三者に完了性をレビューさせる(TEST-PLAN R10-4〜R10-7)

## 課題

R10 の手動分類台帳(`docs/development/R10-MANUAL-CLASSIFICATION.md`)は R10-3 まで到達し、
34 件の候補 128 件を一対一でレビュー済みである。**R10-4〜R10-7 は未着手**
(`docs/development/TEST-PLAN.md`、2026-08-10 時点):

- **R10-4**: source selection を実 Makefile / preprocessor 出力で確認する
- **R10-5**: extension load と upstream suite の実測を台帳へ反映する
- **R10-6**: 第三者による完了性レビュー
- **R10-7**: 指摘後の再実測

台帳の `zero review` 欄には `c`(要追加確認)が 8 件残っており、**pass として数えていない**。

## 影響

R10 の合格率(2026-08-12 時点で 31/34 = 91.2%)は `data/verified_gems.json` の実走記録から
出しており、この台帳とは別の証拠系統である。したがって**合格率が下がることはない**が、
「struct を可変長引数へ渡す gem がコーパスに無い」という主張の**証拠の質**が、
台帳側では c の 8 件ぶん不完全なままになる。

## 受け入れ条件

- 台帳の `c`(要追加確認)8 件が、実測に基づいて `a0` / `b0` / 実使用のいずれかに解決している
- source selection が、実 Makefile または preprocessor 出力で確認されている
- 第三者(このリポジトリの scanner を書いた系統とは別)の完了性レビューを受け、
  指摘があれば再実測している
- 台帳は生成物なので、**再生成して差分が空になる**ことを確認する

## 作業ログ

### 2026-08-12

`docs/development/TEST-PLAN.md` から移設。R10-3 までの到達点は
`test-ci-implementation-8`(別系統によるクロスレビューを台帳へ追加)に記録がある。

**粒度の注意**: R10-4〜R10-7 は 1 PR に収まらない可能性が高い。着手時に
R10-4/5(実測)と R10-6/7(レビューと再実測)へ分割することを想定している。

### 2026-09-08 — 残っている `c` 8 件が何を待っているのかを確定させた

**着手はしていない。** 次に入る人が「何を測れば `c` が解けるか」から始めなくて済むように、
台帳と `data/r10_manual_classification.json` を読んで内訳だけ確定させた。

**`c` は検証欄(control / rubycc / extension load / upstream suite)の結果ではない。**
prism・psych・fiddle は**4 欄すべて pass なのに `c`** である。判定は
`zero_finding_review` — 「候補 0 件という走査結果が、実際にビルドされる範囲を
覆っているか」の評価であって、ビルドやテストの成否とは別系統である。
**最初にこの区別を取り違えたので、記録しておく。**

`data/r10_manual_classification.json` の各 `zero_finding_review` には
`rationale` / `source_evidence` / `follow_up.next_action` が入っており、
**やるべき測定はすでに書かれている**。8 件は理由で 2 つに分かれる:

| 分類 | gem | 待っているもの |
|---|---|---|
| **走査した集合が、実際に選ばれる集合と違う** | prism / rbs / nio4r | 走査は `ext/` だけを見たが、`extconf.rb` は root の `src` も選ぶ(nio4r は `libev/ev.c` の textual include)。**台帳の `selected_build_path.translation_units` には正しい集合が既に入っている** |
| **プロファイル(外部ライブラリ・生成物)が固定されていない** | openssl / psych / fiddle / pg / puma | リンクした OpenSSL / libyaml / libffi / libpq の同一性、Ragel 生成物の出所、`extconf.h` / `DT_NEEDED` が記録されていない |

**upstream suite の実走は R10-4 の要件ではない。** 必要なのは
「選ばれた翻訳単位を control / rubycc で前処理して走査し直す」ことで、
`rubycc -E` が出せるものである。gem のソース取得(ネットワーク)は要るが、
gem 本体テストの実走まで要るのは R10-5 の一部だけである。

**8 件の `follow_up.due` はいずれも 2026-08-24 で、既に過ぎている。**
着手時に期限を引き直すこと。

## 決着

(未着手)
