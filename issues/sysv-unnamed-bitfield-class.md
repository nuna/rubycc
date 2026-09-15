---
status: open
kind: gap
opened: 2026-09-16
closed:
branch:
pr:
steps: []
---

# x86-64 の分類が、名前の無いビットフィールドの記憶域を数えない

## 課題

**x86-64 で、名前の無いビットフィールドを含む構造体を値で渡すと、rubycc は gcc と違うレジスタに置く。**
2026-09-16 にこのホスト(WSL2 / gcc 13.3)で、呼ばれ側を gcc、呼び出し側を rubycc にして測った:

```c
/* 呼ばれ側(gcc)と呼び出し側(rubycc)で同じ宣言 */
struct b { float f; int : 8; };
void tb(struct b v, double d);   /* printf("b %g %g\n", (double)v.f, d) */
int main(void) { struct b y; y.f = 1.5f; tb(y, 3.5); return 0; }
```

| 呼び出し側 | 出力 |
|---|---|
| gcc | `b 1.5 3.5` |
| rubycc | **`b 7.17316e-06 5.28427e-315`**(どちらの引数も壊れる) |

gcc は最初の eightbyte を INTEGER に分類する(名前の無いビットフィールドも記憶域を占める)。rubycc は
`Type#place_bitfield` が名前の無いビットフィールドの `Member` を作らないので、分類がその記憶域を見ず、SSE に分類する。

`sysv-padding-eightbyte-class-1`(BS)を実装したエージェントが、測定行列の途中で見つけた。
`struct { int : 8; } __attribute__((aligned(8)))` も、gcc は edi、rubycc はスタックで食い違う(同エージェントの測定)。
**BS の修正の前からある食い違いで、BS では直していない。**

## 影響

名前の無いビットフィールドを詰め物や予約領域に使う構造体を、gcc でコンパイルしたコードと値でやり取りすると壊れる。
**実在の gem ではまだ見ていない。**

## 受け入れ条件

- 上の再現が両方向(rubycc 呼び出し → gcc 呼ばれ側、gcc 呼び出し → rubycc 呼ばれ側)で gcc 同士と一致する
- 名前の無いビットフィールドだけの構造体、`float` や `double` のメンバと混ざる形、幅 0 のビットフィールド(`int : 0;`)を
  固定引数・可変長引数・戻り値で測り、すべて gcc と一致する
- AArch64 でも同じ形を測り、一致する(AAPCS64 は HFA の判定に関わる)
- `rake test` が 0 failures

## 着手前に確かめること

- `sizeof` / `_Alignof` は既に gcc と一致しているか(レイアウトは合っていて分類だけがずれているのか)を先に測る
- [`sysv-padding-eightbyte-class`](sysv-padding-eightbyte-class.md)(BS)が入れた「どのフィールドも掛からない eightbyte は
  レジスタを取らない」規則と矛盾しないこと。名前の無いビットフィールドは**記憶域を占める**ので、詰め物とは別物である

## 作業ログ

### 2026-09-16(起票)

BS の統合時に、報告された形を最小再現(2 翻訳単位)で確かめて起票した。

## 決着

(未着手)
