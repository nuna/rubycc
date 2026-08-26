---
status: open
kind: infra
opened: 2026-08-12
closed:
branch:
pr:
steps: []
---

# fixture 受入れを PR 必須にするかを決める(TEST-PLAN 2B-3)

## 課題

`acceptance-fixture` job は `weekly.yml`(Tier B)にあり、`test.yml`(PR 必須の Tier A)には
無い(`docs/development/TEST-PLAN.md` の 2B-3、2026-08-10 時点)。

**この課題は [`acceptance-fixture-offline`](acceptance-fixture-offline.md) の完了が前提**である。
fixture が live の代替として成立していない段階で必須化しても、守るものが無い。

## 影響

現状、受入れ経路の退行は**週次まで発覚しない**。逆に、成立していない fixture を必須化すると、
PR ごとに意味の薄い時間を払うことになる(Tier A は Ruby 1 本あたり 60 分の上限を持ち、
GitHub Free の 2,000 分/月に収める設計)。

## 受け入れ条件

- fixture が live 経路の代替として成立していること(前提課題の完了)を確認したうえで、
  **必須化するか Tier A の既存範囲で足りるかを判断し、その根拠を `CI.md` に記録する**
- 必須化する場合は、Tier A の実行時間の増分を実測して記録する

## 作業ログ

### 2026-08-12

`docs/development/TEST-PLAN.md` から移設。判断そのものが課題であり、実装は判断の後になる。

### 2026-08-25

判断の前提が成立していないことが分かった。`acceptance-fixture` job は #93 マージ後の
最初の週次実行(run [32658611908](https://github.com/nuna/rubycc/actions/runs/32658611908)、
2026-08-23)で 42 秒で失敗している(hosted runner で `unshare --user --net` が不可)。
別課題 [`acceptance-fixture-netns-hosted-runner`](acceptance-fixture-netns-hosted-runner.md)
として切り出した。**その完了までこの判断は保留する。**

判断に使える材料として、同日に次を実測した:

- **Tier A は必須 7 ID のうち 5 件を skip する**。走るのは `mkmf-fixture-probes`
  (`test/test_mkmf_conftest.rb:74`)と `rmake-fixture-build`(`test/test_rmake_tools.rb:93`)の
  2 件だけで、extconf 2 件・`rmake-json-parser`・gem install 2 件は
  `RMAKE_ACCEPTANCE` / strict のガードで skip する
  (`test/test_mkmf_conftest.rb:368`、`test/test_rmake_tools.rb:434`、`test/test_gem_install.rb:280`)。
  `docs/internals/CI.md:189` の「実行しているテスト本体は Tier A の `rake test` に含まれる」は
  この 5 件については成り立たない。判断と同時に直す
- **Tier A の実行時間**は 1 push あたり Ruby 3.3 が 4.3 分、4.0 が 3.9 分
  (run 32794774465 ほか、2026-08-25)。fixture job の増分は、新実装が CI で一度も成功して
  いないため未実測(#93 以前の旧 job は 53 秒 / run 31965072086)
- **リポジトリは現在 public** である(`gh api /repos/nuna/rubycc --jq .private` → `false`)。
  public リポジトリの Actions は無料枠を消費しないので、「PR ごとに意味の薄い時間を払う」の
  根拠だった `docs/internals/CI.md:271` の 2,000 分/月の枠は、いまは効かない。
  残るコストは分数ではなく PR のレイテンシである。CI.md のこの節も更新対象

### 2026-08-26(前提が解消し、増分が測れた)

[acceptance-fixture-netns-hosted-runner](acceptance-fixture-netns-hosted-runner.md) が
解消し、**`acceptance-fixture` job は hosted runner で緑になった**
([run 32978860535](https://github.com/nuna/rubycc/actions/runs/32978860535))。
必須 7 ID すべてが pass、0 skips。これで判断の前提が揃った。

**判断に必要な数値は出そろっている。**

| | 実測 |
| --- | --- |
| `acceptance-fixture` job | **1.8 分**(2026-08-26) |
| Tier A(Ruby 3.3 / 4.0) | 4.3 分 / 3.9 分(2026-08-25) |
| Tier A が skip する必須 ID | **7 件中 5 件** |
| 無料枠の制約 | **無い**(リポジトリは public) |

必須化した場合の増分は PR あたり約 1.8 分で、いまの Tier A(2 本で約 8 分)に対して
**2 割強**である。分数の予算は効かないので、費用はレイテンシだけになる。

**判断そのものは人間に委ねる**(この issue の主題がその判断であるため)。

## 決着

(未着手)
