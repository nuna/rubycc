---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-16
branch: gap-fixes-wave-6
pr: 154
steps: [aligned-attribute-member-typedef-1]
---

# メンバの宣言子と typedef 名に付けた `aligned` 属性を捨てる

## 課題

**構造体のメンバの宣言子に付けた `__attribute__((aligned(N)))` と、typedef 名に付けた同じ属性を、rubycc は黙って捨てる。**
構造体そのものに付けた属性と `_Alignas` は効く。2026-09-14 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
#include <stdio.h>
struct m { long a __attribute__((aligned(16))); long b; };
typedef long al16 __attribute__((aligned(16)));
struct t { al16 a; long b; };
int main(void) { printf("%zu %zu %zu %zu\n", _Alignof(struct m), sizeof(struct m), _Alignof(struct t), _Alignof(al16)); return 0; }
```

| | 出力(`_Alignof(struct m)` `sizeof(struct m)` `_Alignof(struct t)` `_Alignof(al16)`) |
|---|---|
| gcc 13.3 | `16 16 16 16` |
| rubycc | **`8 16 8 8`** |

(`sizeof(struct m)` が一致するのは、`long` 2 個でたまたま 16 バイトになるから。)

`aapcs64-aligned-attribute-aggregate-1` を実装したエージェントが、AArch64 の引数渡しの測定中に見つけた(メンバの宣言子の形は
gcc の整列 16 に対して rubycc は 8、両アーキ)。

## 影響

構造体の配置(メンバのオフセット・大きさ・整列)が gcc とずれ、gcc でコンパイルしたコードと構造体をやり取りすると壊れる。
SIMD やキャッシュラインに揃えるためにメンバや typedef へ `aligned` を付けるのはよくある書き方である。**実在の gem ではまだ見ていない。**
診断が出ないので、ずれに気づけない。

## 受け入れ条件

- 上の再現の出力が gcc と一致する(x86-64 と aarch64)
- メンバの宣言子・typedef 名・変数の宣言子に付けた `aligned(N)`(N = 8, 16, 32、N を省いた形)と `packed` との組み合わせで、
  `sizeof` / `_Alignof` / `offsetof` が gcc と一致する
- 引数渡し(`aapcs64-aligned-attribute-aggregate-1` で決めた AAPCS64 の自然な整列の規則を含む)が、両アーキで gcc と一致したまま
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

`aapcs64-aligned-attribute-aggregate-1` の統合時に、報告された形を最小再現で確かめて起票した。

### 2026-09-16(実装)

整列を `Type` に持たせると型の同一性が壊れるので、**宣言の属性として持ち回る**形にした(メンバの生の要素に基準境界を足し、typedef の束縛に境界を足す)。
AAPCS64 の `natural_alignment` はメンバ境界の最大値なので、呼び出し規約の側は変更していない。両 arch で測った行列は 1 行も違わず、
メンバ由来の整列は両 ABI が数え、typedef 名に付けた属性はどちらも数えない。局所オブジェクトの要求は型の境界のままにし、
プロローグでの再整列は [`overaligned-automatic-object`](overaligned-automatic-object.md)(BW)に起票した。

## 決着

**解消した**(`aligned-attribute-member-typedef-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 再現の出力が gcc と一致する(x86-64 と aarch64) | `test/test_aligned_attribute_member_typedef.rb` |
| メンバ・typedef・変数の宣言子の `aligned` と `packed` の組み合わせで `sizeof` / `_Alignof` / `offsetof` が gcc と一致する | 同じテスト(両 arch で 1 行も違わなかった) |
| 引数渡しが両方向・両 arch で gcc と一致したまま | `test/test_aapcs64_aligned_attribute_aggregate.rb` を 14 形から 19 形に増やして確認 |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
