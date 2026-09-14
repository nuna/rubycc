---
status: open
kind: gap
opened: 2026-09-14
closed:
branch:
pr:
steps: []
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

## 決着

(未着手)
