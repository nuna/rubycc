---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# `typeof`(GNU 拡張、C23 で標準化)を受け付けない

## 課題

**`typeof(式)` を、rubycc は関数呼び出しとして読む。** gcc は通す。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
int f(void) { int *d = 0; return (int)sizeof(typeof(d)); }
```

| | 結果 |
|---|---|
| gcc(既定の `-std=gnu17`) | ok |
| rubycc | **`error: implicit declaration of function 'typeof'`** |

`typeof` は長く GNU 拡張で、**C23 で標準の演算子になった**(`typeof` / `typeof_unqual`)。
DESIGN R7 の「それでも必要な最小限の拡張」の一覧には無い。

**診断が原因を伝えていない。** 型を取る演算子が、未宣言の関数として報告される。

## 影響

**実在の gem が落ちる。** コーパス候補 `algorithms` 1.1.0 は
`ext/algorithms/string/string.c:29` で `d = xmalloc(sizeof(typeof(d)) * s1_len * s2_len);` と書いている。
**対照の gcc はビルドとロードに成功する**(2026-09-13 実測、buildable-gems-batch-3)。

## 受け入れ条件

**先に方針を決める**(実装するか、対象外にするか)。どちらでも、診断は直す。

- (実装する場合)`typeof(式)` と `typeof(型名)` の両方が、宣言・`sizeof`・キャストの位置で gcc と
  同じ型になる。`__typeof__` の綴りも受け付ける。`algorithms` 1.1.0 が rubycc でビルドできる
- (対象外にする場合)ROADMAP §3 に行を足し、診断を「`typeof` は非対応」と分かる文言にし、
  `docs/reference/OUT-OF-SCOPE-GEMS.md` に `algorithms` を基準 H で載せる
- どちらの場合も `rake test` が 0 failures

## 着手前に確かめること

- `typeof` を使う gem がコーパス候補に何件あるかを数える。**マクロの中で使われることが多い**
  (型を問わない `MAX` など)ので、ソースの文字列検索で数えること

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-3 で、rubycc だけが落ちて対照は通った 1 件。

## 決着

(未着手)
