---
status: open
kind: infra
opened: 2026-08-12
closed:
branch:
pr:
steps: []
---

# ネットワーク受入れ経路を fixture 化して、遮断環境で実行する(TEST-PLAN 2B-1)

## 課題

`weekly.yml` の `acceptance-fixture` job は、**既存の mkmf / rmake テスト 2 件を専用
profile で再実行しているだけ**である。gem archive・checksum・期待結果の fixture 化は
行っておらず、**実際に skip が発生していた fetch / unpack / extconf / build の経路は
network 必須のまま**である(`docs/development/TEST-PLAN.md` の 2B-1、2026-08-10 時点の記述)。

つまり現状の fixture job は、live 受入れの代替になっていない。

## 影響

network を持たない環境(および live 受入れを回さない通常の PR)では、この経路が
**一度も実行されない**。`RMAKE_ACCEPTANCE=1` を付けない実行では該当テストが skip され、
skip は静かに緑になる。

## 受け入れ条件

- gem archive と期待結果を fixture 化し、リポジトリまたは CI キャッシュから供給できる
- **network を遮断した環境**(TEST-PLAN 2B-4)で fetch / unpack / extconf / build の経路が
  実際に実行され、skip されないことをログで確認できる
- `tools/ci_check_skips.rb` の skip 数が、その分だけ減ることを実測で示す

## 作業ログ

### 2026-08-12

`docs/development/TEST-PLAN.md` から移設。当時の記述をそのまま引き継いだだけで、
再確認の実測は行っていない。

## 決着

(未着手)
