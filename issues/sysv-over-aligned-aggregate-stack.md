---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-16
branch: gap-fixes-wave-6
pr: 154
steps: [sysv-over-aligned-aggregate-stack-1]
---

# x86-64 で 32 バイト整列の構造体を引数に渡すと、スタック上の置き場所が gcc とずれる

## 課題

**x86-64 で 32 バイト整列の集約(型属性 `aligned(32)` または `_Alignas(32)` のメンバ)を値で渡すと、gcc はスタックスロットを
32 バイト境界に置き、`va_arg` も 32 に切り上げる。rubycc は 16 バイトまでしか揃えない。** 2026-09-14 にこのホスト
(WSL2 / gcc 13.3)で、`aapcs64-aligned-attribute-aggregate-1` を実装したエージェントが測った(同ステップの測定行列の x86-64 側)。

rubycc の System V の置き方は、スタック上の集約を 16 バイト(`align16`)までしか揃えない。

## 影響

32 バイト整列の構造体を gcc でコンパイルした関数との間で値渡しするコードで、引数がずれる。**実在の gem ではまだ見ていない。**

## 受け入れ条件

- 型属性 `aligned(32)`・`_Alignas(32)` のメンバ・`aligned(64)` の形を、固定引数と可変長引数(呼び出し側と `va_arg`)で、
  rubycc → gcc と gcc → rubycc の両方向が gcc 同士と一致する(x86-64)
- `test/test_aapcs64_aligned_attribute_aggregate.rb` の x86-64 側から外した `attr32` / `alignas32` の形を戻す
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

`aapcs64-aligned-attribute-aggregate-1` の測定行列で見つかった。テストの x86-64 側からは理由を書いて外した。

### 2026-09-16(実装)

`AggregatePlan` と `ArgumentRequest` に `stack_alignment` を持たせ、System V は型の整列(8 未満は 8)をそこに入れる。スタック引数領域では、
境界に届くまで `:pad_stack` を最大 7 個続け、呼び出し側は `rsp` をその境界に切り上げてから積む(戻す値を 1 語保存する)。`va_arg` は
`overflow_arg_area` のアドレス自体を切り上げる。gcc の呼ばれ側に対して、集約より前にスタックへ積む long を 0〜3 個に変えた行列で、
固定引数と可変長引数のすべてのオフセットが一致した。AAPCS64 は領域の整列を常に 16 として扱い、振る舞いは変えていない。

## 決着

**解消した**(`sysv-over-aligned-aggregate-stack-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| `aligned(32)` / `_Alignas(32)` / `aligned(64)` が固定引数と可変長引数の両方向で gcc と一致する | `test/test_sysv_over_aligned_aggregate_stack.rb`(5 形 × 前置き 0〜3 個)。9e4d5d2 の `lib` に戻すと x86-64 の両方向が落ちることも確認 |
| `test_aapcs64_aligned_attribute_aggregate.rb` の `attr32` / `alignas32` を戻す | 戻した(BS と合わせて除外は 0 件になった) |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
