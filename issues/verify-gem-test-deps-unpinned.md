---
status: open
kind: gap
opened: 2026-08-15
closed:
branch:
pr:
steps: []
---

# レシピのテスト依存の固定が、共有 GEM_HOME 越しに他の gem を壊す

## 課題

`tools/verify_gem_tests.rb` は全 gem で**同じスクラッチ GEM_HOME を共有**し、実行を
またいで再利用する。レシピは `test_dep_versions` でテスト依存の版を固定できるが、
**その固定は GEM_HOME 全体に効く** — 固定した gem が走った時点で、他の gem が使う版も
その版に変わる。

`racc` のレシピは `test-unit-ruby-core` を **1.0.5** に固定している(racc の Gemfile が
そう pin しているため。`tools/verify_gem_tests.rb` の当該コメント参照)。
これが GEM_HOME に入ると、**後に走る gem も 1.0.5 を使う**。

2026-08-15 の実測(同一ホスト・Ruby 3.4.5・同一 gem 版、15 分違いの 2 回):

| 実行 | date | etc | nkf | psych | 使われた helper |
|---|---|---|---|---|---|
| 1 回目 | PASS | PASS | PASS | PASS | 1.0.15(racc より**先に**走った) |
| 2 回目 | **FAIL** | **FAIL** | **FAIL** | **FAIL** | 1.0.5(1 回目の racc が残した) |

4 件とも同じ形で落ちる:

```
Error: test_ractor(TestNKF): NoMethodError: undefined method 'value' for an instance of Ractor
  gemhome/gems/test-unit-ruby-core-1.0.5/lib/core_assertions.rb:373:in 'assert_ractor'
```

`Ractor#value` は Ruby 3.5 で入ったメソッドで、このホストの 3.4.5 には無い。
**1.0.15 では起きない**(対照側の GEM_HOME は 1.0.15 のままで、4 件とも PASS した)。

**落ちているのは gem の C 拡張ではなくテストヘルパである。**

## 影響

**同じコードに対して、実行順序と前回の残留だけで合否が変わる。**
`data/verified_gems.json` は「その gem のテストスイートが rubycc ビルドの `.so` に対して
合格した」という証拠の台帳なので、合否が harness の状態に依存すると**台帳が測っている
ものが曖昧になる**。R10 の合格率(受け入れ条件で「下げてはならない」と定めた指標)にも
同じ影響が及ぶ。

`--control` 実行は別の GEM_HOME(`gemhome-control`)を使うため、**対照との比較でも
この差は打ち消せない** — 比較しているつもりの「コンパイラの違い」に、helper の版差が
混ざる。

## 受け入れ条件

- 1 つのレシピの `test_dep_versions` が、**他の gem の実行に影響しない**
  (gem ごとに GEM_HOME を分ける・実行前に版を揃える・固定を持つ gem を最後に回す、など。
  どれを採るかは実装時の判断)
- **rubycc 側と対照側の GEM_HOME が同じ版を使う**(比較がコンパイラの違いだけを写す)
- 上の 4 gem が**順序に関わらず**同じ判定になることを、順序を変えた 2 回の実行で確認する
- ホストの Ruby が上がったときに何を直せばよいかが分かる形になっている
  (`Ractor#value` のような版依存は今後も出る)

## 作業ログ

### 2026-08-15(起票)

`register-allocation` の受け入れ条件(コーパス合格率の再測)を実施中に判明。
**その場では直さず**切り出した。

切り分けの経過:

1. 2 回目の実行で date / etc / nkf / psych が FAIL。1 回目は全件 PASS
2. 4 件とも `assert_ractor` の `Ractor#value` で、**gem の C 拡張ではない**
3. 対照(gcc)実行では 4 件とも PASS。ただし対照は別 GEM_HOME で **1.0.15** を使っており、
   この比較だけでは「コンパイラの違い」を示さない
4. rubycc 側の GEM_HOME を 1.0.15 に戻して再実行 → 判定が戻ることを確認
   (**コンパイラは無関係**)
5. 版を 1.0.5 に落としているのは `racc` のレシピの `test_dep_versions` と特定

## 決着

(未着手)
