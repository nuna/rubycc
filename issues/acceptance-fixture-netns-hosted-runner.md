---
status: done
kind: infra
opened: 2026-08-25
closed: 2026-08-26
branch: acceptance-fixture-netns-hosted-runner
pr: 108
steps: [acceptance-fixture-netns-hosted-runner-1]
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

### 2026-08-26(3 案のうち 2 案を実測し、後の方を採った)

**候補 1(sysctl)は通ったが、採らなかった。**
`sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` で制限を外せば、既存の
`unshare --user --map-root-user --net` がそのまま動く。実測でも `acceptance-fixture` は
success、必須 7 ID すべて pass、1.8 分だった
([run 32882636400](https://github.com/nuna/rubycc/actions/runs/32882636400))。
**採らなかったのは、カーネルの防御機構を 1 つ外す形だからである**(ユーザ判断)。
hosted・使い捨て・sudo が元から使える環境では実害はほぼ無いが、self-hosted ランナーを
導入したときや、同じ手順を開発機で真似したときに意味が変わる。

**候補 2(root が名前空間を作る)を採った。**

```sh
sudo -E env "PATH=$PATH" unshare --net -- \
  setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups --inh-caps=-all \
  bash -lc '...'
```

root は `CAP_SYS_ADMIN` を持つのでユーザ名前空間を必要とせず、**AppArmor の制限に触れない**。
`sudo` が環境変数を落とすので `PATH` は明示的に渡す。テストが root で走ると作業ツリーの
所有権が変わるため `setpriv` で元のユーザへ降ろし、capability は持ち越さない。

実測([run 32978860535](https://github.com/nuna/rubycc/actions/runs/32978860535)):
`acceptance-fixture` は **success**、必須 7 ID すべて `state: pass`、
5 回の呼び出しがいずれも **0 failures / 0 errors / 0 skips**、**1.8 分**(候補 1 と同じ)。

その後、5 か所に並んでいた前置きを `isolated` というシェル関数にまとめ、
**同じことをもう一度実測した**([run 32979807051](https://github.com/nuna/rubycc/actions/runs/32979807051)、
7 ID すべて pass / 0 skips)。渡す文字列は変えていないが、変えていないことを測って確かめた。

**候補 3(`ip netns` / firewall)は試していない。** 候補 2 で足りたためである。
なお firewall で全体を落とす形は使えない — Actions のランナー自身が状態報告と
ログ送信にネットワークを使うので、uid で絞る必要があり、そのために専用ユーザを
作ることになる。

遮断が効いていることの確認ステップも入れた。namespace の中から `rubygems.org` へ
**到達できたらジョブを落とす**。これが無いと、遮断が外れても緑になる。

## 決着

(未着手)
