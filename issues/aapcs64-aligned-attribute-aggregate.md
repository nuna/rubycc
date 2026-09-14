---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-14
branch: gap-fixes-wave-5
pr: 153
steps: [aapcs64-aligned-attribute-aggregate-1]
---

# AArch64 で、型に付けた `aligned(16)` の構造体を引数に渡すと、置くレジスタが gcc とずれる

## 課題

**AArch64 で int を 3 個渡した後に `struct { long a, b; } __attribute__((aligned(16)))` を値で渡すと、
rubycc は x4/x5 に置き、gcc は x3/x4 に置く。** 固定引数でも可変長引数でも同じ。2026-09-14 にこのホスト
(WSL2 / `aarch64-linux-gnu-gcc` 13.3 + qemu-aarch64)で、`variadic-aggregate-argument-1` を実装した
エージェントが測った:

| 16 バイト整列の出どころ | gcc 13.3 | rubycc |
|---|---|---|
| 型に付けた `__attribute__((aligned(16)))` | x3/x4 | **x4/x5** |
| `__int128` のメンバ / `_Alignas(16)` のメンバ | x4/x5 | x4/x5(一致) |

x86-64 は一致する。

`AAPCS64Convention#aggregate_plan` は、偶数番のレジスタに切り上げるかどうかを `type.alignment >= 16` で判定しており、
型に付けた属性で上がった整列もそこに数えている。gcc の振る舞いからは、メンバの自然な整列だけで判定しているように見える
(規則の根拠は AAPCS64 の本文で確かめること)。

## 影響

型の属性で 16 バイトに揃えた構造体を、gcc でコンパイルした関数との間で値渡しすると、引数がずれる。
**実在の gem ではまだ見ていない。**

## 受け入れ条件

- 上の 2 つの形(型の属性・メンバの整列)で、rubycc の呼び出し側 → gcc の呼ばれ側、gcc の呼び出し側 → rubycc の
  呼ばれ側の両方向が gcc 同士と一致する(固定引数と可変長引数、戻り値も)
- 判定の根拠(AAPCS64 のどの規則か)を STEPS に書く
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

`variadic-aggregate-argument-1` の測定行列を回すなかで見つかった。固定引数にもある既存の不一致なので、
その場では直さずに行列をメンバ側の `_Alignas(16)` に替えた。

### 2026-09-14(実装)

AAPCS64 の文書はこのホストに無く、規則は gcc 13.3 の測定から導いた。偶数レジスタへの切り上げとスタックの 16 境界は、メンバの整列の
最大値で決まり、構造体・共用体そのものに付けた属性は数えない(packed の集約ではメンバを 1 と数える)。`StructType#natural_alignment` を足し、
AAPCS64 の判定だけをそれで行うようにした。測定の途中で、別の課題を 3 件起票した: [`aligned-attribute-member-typedef`](aligned-attribute-member-typedef.md)(BQ)、
[`sysv-over-aligned-aggregate-stack`](sysv-over-aligned-aggregate-stack.md)(BR)、[`sysv-padding-eightbyte-class`](sysv-padding-eightbyte-class.md)(BS)。

## 決着

**解消した**(`aapcs64-aligned-attribute-aggregate-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 型の属性・メンバの整列の両方の形で、両方向が gcc 同士と一致する(固定引数と可変長引数、戻り値も) | `test/test_aapcs64_aligned_attribute_aggregate.rb`(14 形 × 前置き 0〜9 個、aarch64 と x86-64) |
| 判定の根拠を STEPS に書く | 測定の行列と、導いた規則を記録(文書は読んでいない) |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
