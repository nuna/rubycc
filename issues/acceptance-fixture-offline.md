---
status: done
kind: infra
opened: 2026-08-12
closed: 2026-08-21
branch: acceptance-fixture-offline
pr: 93
steps: [test-ci-implementation-5]
---

# ネットワーク受入れ経路を fixture 化して、遮断環境で実行する(TEST-PLAN 2B-1)

## 課題

`weekly.yml` の `acceptance-fixture` job は、以前は既存の mkmf / rmake テスト 2 件を
専用 profile で再実行しているだけだった。gem archive・checksum・期待結果がなく、
実際に skip が発生していた fetch / unpack / extconf / build の経路を network 遮断下で
実行できなかった(`docs/development/TEST-PLAN.md` の 2B-1、2026-08-10 時点の記述)。

つまり現状の fixture job は、live 受入れの代替になっていない。

## 影響

network を持たない環境(および live 受入れを回さない通常の PR)では、この経路が
**一度も実行されなかった**。`RMAKE_ACCEPTANCE=1` を付けない実行では該当テストが
skip され、skip は静かに緑になっていた。

## 受け入れ条件

- gem archive と期待結果を fixture 化し、リポジトリまたは CI キャッシュから供給できる
- **network を遮断した環境**(TEST-PLAN 2B-4)で fetch / unpack / extconf / build の経路が
  実際に実行され、skip されないことをログで確認できる
- `tools/ci_check_skips.rb` の skip 数が、その分だけ減ることを実測で示す

## 作業ログ

### 2026-08-12

`docs/development/TEST-PLAN.md` から移設。当時の記述をそのまま引き継いだだけで、
再確認の実測は行っていない。

### 2026-08-20

- `test/fixtures/acceptance/` に manifestのURL・SHA-256に対応する期待する version と round-trip 結果を追加した。
- `AcceptanceFetchHelper` に `CI_NETWORK=fixture` modeを追加した。fixture pathをmanifestから明示的に受け取り、archiveのdigestを検証してから unpack へ進む。欠落時は network fallback せず `:environment` failure とする。
- mkmf、rmake、gem install の実物経路を `weekly.yml` の `unshare --user --map-root-user --net` 内で実行し、7つの required IDとartifact reportを `acceptance-fixture` profileへ接続した。
- ローカルのnetwork namespaceで `mkmf` extconf、rmake parser build、json/msgpack gem installを実行し、各0 failure / 0 skipを確認した。fixture archiveのSHA-256と期待結果の単体検査も通過した。
- 作業ツリー分離のため、ブランチ `acceptance-fixture-offline` と専用worktreeで作業中。master反映とPR番号の確定待ち。

### 2026-08-21

PR [#93](https://github.com/nuna/rubycc/pull/93) を作成した。masterへマージ後に
`status: done` へ更新する。

外部gemの再配布を避けるため、リポジトリ内のgem archiveは削除した。manifestのURL・SHA-256
からActions cacheへCI実行時に取得し、検証後にnetwork namespace内のacceptanceへ渡す方式へ変更した。

## 決着

実装とローカル検証を完了し、PR [#93](https://github.com/nuna/rubycc/pull/93) として
masterへマージした(Merge commit `d5e4c26`)。gem archiveはリポジトリへ再配布せず、
manifestのURL・SHA-256からCI cacheへ取得する方式で決着した。
