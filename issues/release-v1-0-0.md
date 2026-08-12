---
status: done
kind: infra
opened: 2026-08-12
closed: 2026-08-13
branch: release-v1-0-0
pr: none
steps: [release-tag-record-1, release-close-1]
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

タグを打つ前に **`examples/distroless/Dockerfile` のビルドを確認**したところ、
`gem build` が `["CHANGELOG.md"] are not files` で**失敗した**。README が新規利用者に
案内する経路であり、CI では検出できない(Docker を要する)。PR #41 で修正し、
再発防止の検査も入れた。修正後はビルド完走・`rubycc distroless sample: PASS`。

**タグ `v1.0.0`(`a9e04bf`)を一度打ち、Tier C は全ジョブ success だった**
([run 31607452987](https://github.com/nuna/rubycc/actions/runs/31607452987):
Ruby 3.3 / 4.0 の全スイートと、タグ・`Rubycc::VERSION` の一致、`SOURCE_DATE_EPOCH`
固定の再現ビルド)。

そのビルドで `gem build` が**警告 2 件**を出していた —
`description and summary are identical` と、`homepage_uri` / `source_code_uri` に
同じ URI を与えたことによる `Only the first one will be shown on rubygems.org`。
どちらも gem の動作ではなく **rubygems.org の表示**の問題だが、
**`gem push` 後は同じバージョンを差し替えられない**ので、公開前に直すことにした。
**タグは削除した**(内容に紐づくため、修正後に打ち直す)。

修正後に `v1.0.0`(`cbeed4b`)を打ち直したが、**summary / description を英語に戻す**
判断があったため(ユーザ指示)、**もう一度削除して打ち直す**。タグはコミットに紐づくので、
同梱物の文面を変えるたびに打ち直しになる — **リリース物の文面は、タグを打つ前に確定させる**。

## 決着

**タグ `v1.0.0` を確定させた**(`dca836f`、内容は master の `99dad94`。2026-08-12)。
Tier C は全ジョブ success —
[run 31610051259](https://github.com/nuna/rubycc/actions/runs/31610051259)。
Ruby 3.3 / 4.0 の全スイートに加えて、`package` ジョブが
**タグと `Rubycc::VERSION` の一致**と **`SOURCE_DATE_EPOCH` 固定での再現ビルド
(バイト一致)** を検証している。

**`gem push` はリポジトリ所有者が実施した(2026-08-13)。** rubygems.org の API で
公開を確認した — `rubycc 1.0.0`、ライセンス MIT、`.gem` の SHA-256 は
`7d8fa901...c38e593`、メタデータは `source_code_uri` / `changelog_uri` /
`bug_tracker_uri` / `documentation_uri` / `rubygems_mfa_required` の 5 キーが登録され、
description も本文として入っている(公開前に潰した 2 つの警告の効果がここで確認できる)。

`pr:` が `none` なのは、タグ push と `gem push` が**リポジトリを変更しない操作**だから
である(規約どおり)。この issue に紐づく PR は #40 / #41 / #42 / #43 / #44 で、
いずれも公開前の準備を直したものである。

タグに至るまでに 3 回打ち、2 回削除した。経緯は上の作業ログにあるが、要点は
**「同梱物の文面はタグを打つ前に確定させる」**である。タグはコミットに紐づくので、
README・CHANGELOG・gemspec のいずれかを直すたびに打ち直しになる。
