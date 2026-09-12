---
status: open
kind: infra
opened: 2026-09-11
closed:
branch:
pr:
steps: []
---

# master にブランチ保護をかけ、必須チェックを指定する

## 課題

**`master` にブランチ保護がかかっていない。** 2026-09-11 に実測した:

```sh
$ gh api repos/nuna/rubycc/branches/master/protection
{"message":"Branch not protected", ... "status":"404"}
```

つまり **GitHub の意味での必須チェックは 1 つも無い**。Tier A が赤でも merge でき、
`master` への直接 push も止まらない。いま守られているのは**運用規律だけ**である
(`CLAUDE.md` の「リモートへの push は必ず PR 経由」)。

`acceptance-fixture-required-job` の判断で `acceptance-fixture` を
**PR ごとに走らせる**ところまでは実装した(`acceptance-fixture-required-1`)。
**走ることと、落ちたら merge できないことは別である。** 後者はリポジトリ設定であり、
コードの変更では実現できないので分けた。

## 影響

**検査は増えたが、強制はされていない。** 2026-09-07〜11 に #121〜#132 のうち **11 本**を merge しており(#128 だけ open のまま残った)、
そのすべてで CI の緑と `headSha` の一致を手で確かめている。**人間(またはエージェント)が
確かめ忘れた 1 回**で、赤いまま master に入る。

放置しても普段は壊れない。壊れるのは「急いでいるとき」「別の作業者が入ったとき」
「自動化が判断を誤ったとき」で、**そこだけを守るのがブランチ保護である**。

## 受け入れ条件

- `master` にブランチ保護が有効になっている(`gh api .../branches/master/protection` が 200 を返す)
- **必須ステータスチェックに次の 3 つが指定されている**。名前は**実際の run から確認した綴り**を使う
  (推測で書かない — GitHub は指定した文字列と一致するチェックしか見ない):
  - `test (3.3)`
  - `test (4.0)`
  - `acceptance-fixture`
- **直接 push が禁止**されている(PR 経由のみ)
- 次の 2 つを**決めて記録する**:
  - 管理者のバイパスを許すか(`enforce_admins`)
  - 「最新の master に追随していること」を必須にするか(`strict`)。必須にすると
    master が動くたびに再実行が要る
- 設定内容と**その根拠が `docs/internals/CI.md` に記録されている**

## 着手前に確かめること

- **必須チェックの名前は、`paths-ignore` で走らなかった場合に「永久に pending」になる。**
  `test.yml` と `acceptance-fixture.yml` はどちらも `pull_request` に `paths-ignore` を
  付けていないので現状は該当しないが、**後から付けると docs だけの PR が merge 不能になる**。
  この罠を CI.md にも書くこと
- **ジョブ名を変えると、必須チェックは黙って外れる**(指定した文字列と一致しなくなるため)。
  ワークフローのジョブ名を変えるときは保護設定も直す、と CI.md に書くこと
- fork からの PR は Actions cache を読めないので `acceptance-fixture` の前提が変わる。
  現状このリポジトリは単独所有なので実害は無いが、外部からの PR を受けるようになったら再評価する

## 作業ログ

### 2026-09-11(起票)

`acceptance-fixture-required-job` の実装中に、**必須化の半分がリポジトリ設定側にある**ことが
分かったので分離した。ユーザ判断で「ブランチ保護を設定する issue を立てる」となった。

**設定変更は外向きの操作**なので、実行するときは内容(どのチェックを必須にするか、
管理者バイパスを許すか)を確認してから行うこと。

## 決着

(未着手)
