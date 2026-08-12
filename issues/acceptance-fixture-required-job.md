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

## 決着

(未着手)
