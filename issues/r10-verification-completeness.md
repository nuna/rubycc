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

## 決着

(未着手)
