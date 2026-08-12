---
status: in-progress
kind: infra
opened: 2026-08-12
closed:
branch: release-v1-0-0
pr:
steps: []
---

# v1.0.0 をタグ付けして公開する

## 課題

リリース準備は完了しており、残るのは**リポジトリを変更しない 2 つの操作**である
(`docs/development/RELEASE-CHECKLIST.md` §5)。

| 操作 | 状態 |
|---|---|
| タグ `v1.0.0` を打つ | 未実施 |
| `gem push` | 未実施 |

準備側は済んでいる: `lib/rubycc/version.rb` は `1.0.0`、`CHANGELOG.md` の 1.0.0 エントリ
(gemspec の `files` にも追加済み)、gem の再現ビルド(`SOURCE_DATE_EPOCH` 固定で 2 回ビルドし
バイト一致)、同梱物の確認。

前提となる受け入れも満たしている(2026-08-12 時点):

- R10 コーパス **31/34 = 91.2%**(要求は 90%)
- M4 の受け入れ 4 項目すべて完了
- 全スイート 3,112 runs / 0 failures / 41 skips、CI(Ruby 3.3 / 4.0)緑

## 影響

未公開のままでは利用者が入手できない。逆に、公開後は**バージョニング方針
(セマンティックバージョニング + 「コーパス合格率の回帰は破壊的変更」)に縛られる**ので、
公開前に既知の制限の記載が正しいことを確かめておく必要がある。

## 受け入れ条件

- タグ `v1.0.0` を push し、**Tier C(`release.yml`)が green** になる
  (タグと `Rubycc::VERSION` の一致・`SOURCE_DATE_EPOCH` 固定の再現ビルドを検証する)
- `gem push` 後、`gem install rubycc` で入手できることを確認する
- README / CHANGELOG の「既知の制限」が公開時点の実態と一致していることを、公開直前に再確認する

## 作業ログ

### 2026-08-12

`docs/development/RELEASE-CHECKLIST.md` から移設。

**この 2 操作は意図的に自動化しない**(アカウント保有者の操作である。`docs/internals/CI.md`)。

タグを打つ直前の確認で、**`CHANGELOG.md` の見出しが `## 1.0.0 (unreleased)` のまま**
だったことが分かった。CHANGELOG は gemspec の `files` に入る**同梱物**なので、
この状態でタグを打つと「未リリース」と書かれた成果物を配ることになる。
日付に直してからタグを打つ(この issue の `pr:` はその PR を指す)。

`gem push` は認証がこのセッションから行えないため、リポジトリ所有者の操作として残る。

## 決着

(タグ push と Tier C の結果を記入する。`gem push` の完了もここに書く。)
