---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-16
branch: gap-fixes-wave-6
pr: 154
steps: [sysv-padding-eightbyte-class-1]
---

# x86-64 で、後半が詰め物だけの構造体を可変長引数に渡すと、xmm を 1 つ余分に使う

## 課題

**`struct { float a, b; } __attribute__((aligned(16)))`(16 バイトで、後半の 8 バイトは詰め物だけ)を x86-64 の可変長引数に渡すと、
gcc は後半にレジスタを割り当てない(この構造体を 2 個渡すと `%al = 2`)。rubycc は後半も SSE に分類して xmm を 2 個使うので、
可変長の 2 個目を `va_arg` がずれた場所から読む。** 固定引数では一致する。2026-09-14 にこのホスト(WSL2 / gcc 13.3)で、
`aapcs64-aligned-attribute-aggregate-1` を実装したエージェントが測った。

System V の分類では、メンバの無い eightbyte は NO_CLASS になる(psABI 3.2.3)。rubycc の分類は、詰め物だけの eightbyte にも
クラスを付けているとみられる(未確認)。

## 影響

後半が詰め物だけになる整列の構造体を、可変長引数で gcc の関数とやり取りするコードで値がずれる。**実在の gem ではまだ見ていない。**

## 受け入れ条件

- 上の形を 2 個以上、可変長引数で渡したとき、rubycc → gcc と gcc → rubycc の両方向が gcc 同士と一致し、`%al` も gcc と同じになる
- 固定引数と戻り値でも同じ形が一致したまま
- `test/test_aapcs64_aligned_attribute_aggregate.rb` の x86-64 側から外した `f2_attr` の形を戻す
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

`aapcs64-aligned-attribute-aggregate-1` の測定行列で見つかった。テストの x86-64 側からは理由を書いて外した。

### 2026-09-16(実装)

どのフィールドも掛からない eightbyte(psABI の NO_CLASS)にピースを作らないようにした。起票時は可変長引数だけの食い違いと書いたが、
**固定引数でも 1 レジスタずれていた** — 既存のテストが集約の後に `long` しか置いていなかったため見えていなかった。集約の後に `double` を置くと出る。
測定の途中で、名前の無いビットフィールドが分類に数えられていないことも分かり、[`sysv-unnamed-bitfield-class`](sysv-unnamed-bitfield-class.md)(BV)に起票した。

## 決着

**解消した**(`sysv-padding-eightbyte-class-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 可変長引数で両方向が gcc と一致し、`%al` も同じ | `test/test_sysv_padding_eightbyte_class.rb`(11 形 × 前置き 9 通り、gcc の踏み台で `%al` を記録) |
| 固定引数と戻り値でも一致したまま | 同じテストで確認(固定引数のずれも直った) |
| `test_aapcs64_aligned_attribute_aggregate.rb` の `f2_attr` を戻す | 戻して 0 failures |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
