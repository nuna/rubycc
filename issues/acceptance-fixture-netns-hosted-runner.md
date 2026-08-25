---
status: in-progress
kind: infra
opened: 2026-08-25
closed:
branch: acceptance-fixture-netns-hosted-runner
pr:
steps: []
---

# hosted runner で `acceptance-fixture` の network 遮断が成立しない

## 課題

`weekly.yml` の `acceptance-fixture` job が、PR [#93](https://github.com/nuna/rubycc/pull/93)
マージ後の最初の週次実行(run
[32658611908](https://github.com/nuna/rubycc/actions/runs/32658611908)、2026-08-23 18:37 UTC)で
**42 秒で失敗**した。step 8「Run pinned acceptance fixtures without network access」の出力は
5 回の `unshare` 呼び出しすべてが同じエラーである:

```
unshare: write failed /proc/self/uid_map: Operation not permitted
##[error]Process completed with exit code 1
```

続く step 9 は結果ファイルそのものが無いと報告した:

```
ci_check_acceptance: cannot read result file tmp/ci/acceptance-fixture-results.json:
  No such file or directory @ rb_sysopen - tmp/ci/acceptance-fixture-results.json
##[error]Process completed with exit code 2
```

`unshare --user --map-root-user --net`(`.github/workflows/weekly.yml:174` 以降の 5 か所)が
GitHub-hosted の `ubuntu-24.04` で通らない。Ubuntu 24.04 は非特権 user namespace の作成を
AppArmor(`kernel.apparmor_restrict_unprivileged_userns=1`)で制限している。

cache の準備と検証(step 6・7、`test_acceptance_fixtures.rb` が 3 runs / 0 failures / 0 skips)は
成功しており、失敗しているのは遮断実行の部分だけである。

`acceptance-fixture-offline` の完了時に確認した「network namespace 内で 0 failure / 0 skip」は
ローカル(WSL2)での実測であり、hosted runner では再現しなかった。

## 影響

**新しい fixture 経路は CI で一度も緑になっていない。** manifest 固定 archive からの
fetch / unpack / extconf / build / gem install は、週次でも実行されていない。
直前の 2026-08-16 の実行(run 31965072086)が緑なのは、#93 以前の古い job 定義
(「Run deterministic mkmf and rmake fixtures」)だったためである。

`acceptance-fixture-required-job`(必須化するかの判断)は、この job が成立していることを
前提にしている。直るまでその判断は材料を持たない。

## 受け入れ条件

- `workflow_dispatch` の `only: acceptance` で `acceptance-fixture` job が緑になり、
  `tools/ci_check_acceptance.rb --strict` が必須 7 ID
  (`mkmf-fixture-probes` / `mkmf-msgpack-extconf` / `mkmf-json-extconf` /
  `rmake-fixture-build` / `rmake-json-parser` / `gem-install-json` / `gem-install-msgpack`)
  すべてを **実行済み・skip 無し・`inconclusive` 無し**として通す
- 遮断が効いていることをログで確認できる(遮断下で外向き接続が実際に失敗することを、
  job 内の 1 コマンドで示す)。遮断が外れたまま緑になる経路を残さない
- `test/test_weekly_workflow.rb` が、採用した遮断手段を job 定義の検査として含む
- `acceptance-fixture` job の実行時間を実測して記録する
  (`acceptance-fixture-required-job` の増分見積りがこの値を使う)

## 作業ログ

### 2026-08-25

run 32658611908 のログから原因を特定した。未検証の候補は次のとおり(いずれも実測していない):

- runner で `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` してから
  現行の `unshare` を使う
- `sudo unshare -n` で root の network namespace を作り、テストは元のユーザへ落として実行する
- user namespace を使わず、`sudo ip netns` か firewall 規則で遮断する

### 2026-08-26(実装と実測)

**sysctl 案(候補 1)で通った。** hosted の `ubuntu-24.04` で
`sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` を実行したうえで、
既存の `unshare --user --map-root-user --net` を変えずに使う。制限を外した直後に
`unshare ... -- true` を置き、**本番のテストの前に効いたことを確かめて落とす**形にした。

遮断が効いていることの確認ステップも足した。namespace の中から `rubygems.org` へ
**到達できたらジョブを落とす**。遮断が外れたまま緑になる経路を残さないため。

`workflow_dispatch`(`only: acceptance`)で実測
([run 32882636400](https://github.com/nuna/rubycc/actions/runs/32882636400)、
ブランチ `acceptance-fixture-netns-hosted-runner`):

| job | 結果 | 所要 |
| --- | --- | --- |
| `acceptance`(live) | success | 5.8 分 |
| `acceptance-fixture` | **success** | **1.8 分** |

必須 7 ID すべてが `state: pass`(`mkmf-fixture-probes` / `mkmf-json-extconf` /
`mkmf-msgpack-extconf` / `rmake-fixture-build` / `rmake-json-parser` /
`gem-install-json` / `gem-install-msgpack`)。5 回の呼び出しはいずれも
**0 failures / 0 errors / 0 skips**。

**候補 2・3(`sudo unshare -n` + 降格、`ip netns` / firewall)は試していない。**
候補 1 が通ったためである。ただし**候補 1 はカーネルの防御機構を 1 つ外す**という
性質を持つ(影響は使い捨てランナー 1 台・1 ジョブの間に限られる)。
防御機構を外さずに済ませたいなら候補 2 で、その場合は 5 か所の呼び出しを
書き換えることになる。**この選択は人間の判断に委ねる。**

## 決着

(未着手)
