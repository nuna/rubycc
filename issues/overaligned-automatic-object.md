---
status: open
kind: gap
opened: 2026-09-16
closed:
branch:
pr:
steps: []
---

# フレームの境界を超えて整列した自動記憶域のオブジェクトを拒否する

## 課題

**関数の中で、フレームが与える境界(スタックオブジェクトは 16、スカラーのスロットは 8)より強く整列したオブジェクトを
宣言すると、rubycc はエラーにする。** gcc はプロローグでスタックを整列し直して通す。2026-09-16 にこのホスト
(WSL2 / gcc 13.3)で測った:

```c
#include <stdio.h>
int main(void) {
  _Alignas(32) long x = 1;
  struct s { long a, b; } __attribute__((aligned(32))) y;
  y.a = 2;
  printf("%d %d %ld %ld\n", (int)((unsigned long)&x % 32 == 0), (int)((unsigned long)&y % 32 == 0), x, y.a);
  return 0;
}
```

| | 結果 |
|---|---|
| gcc 13.3 | `1 1 1 2`(どちらも 32 バイト境界) |
| rubycc | **`error: requested alignment 32 for 'x' exceeds the 8 bytes an automatic object is laid out on`** |

診断は `Generator#reject_overaligned_automatic` が出す。静的記憶域と引数渡しは、32 / 64 バイト整列でも gcc と一致する
(`sysv-over-aligned-aggregate-stack-1`)。**足りないのは、プロローグで `rsp` / `sp` を整列し直して局所オブジェクトを置く仕組み**である。

`aligned-attribute-member-typedef-1` は、typedef の境界を局所宣言の要求に持ち上げると `t16 x;` のような普通の宣言まで
この診断に当たるため、**局所オブジェクトの要求は型の境界のままにした**。そのぶん、gcc と違うのはこの形だけになっている。

## 影響

SIMD やキャッシュラインに合わせて局所バッファを整列する拡張がビルドできない。**実在の gem ではまだ見ていない**
(ベクトル組み込み関数を使う gem は基準 G で対象外にしているものが多い)。

## 受け入れ条件

- 上の再現が通り、出力が gcc と一致する(x86-64 と aarch64)
- 16 / 32 / 64 バイト整列の局所オブジェクト(スカラー・構造体・配列)、可変長引数を持つ関数、`alloca` を含む関数、
  末尾呼び出しの無い / ある形で、アドレスが要求どおりの境界にあり、値が gcc と一致する
- 整列し直したフレームでも、既存のスタックオブジェクト・引数領域・`va_list` の読み書きが壊れない
- `rake test` が 0 failures

## 着手前に確かめること

- gcc が何をしているかを先に測る(`andq $-32, %rsp` と、元の `rsp` を保存する語、フレームポインタの扱い)
- `sysv-over-aligned-aggregate-stack-1` が呼び出し側の引数領域で行っている切り上げと、同じ仕組みに寄せられるか

## 作業ログ

### 2026-09-16(起票)

`aligned-attribute-member-typedef-1` の統合時に、最小再現で確かめて起票した。

## 決着

(未着手)
